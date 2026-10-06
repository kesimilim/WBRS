#!/usr/bin/env node
import { open, readFile, realpath, lstat } from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { privateInput, privateMediaConfig } from './import-cli-common.mjs';
import { privateMysqlConfig } from './apply-mysql84-schema.mjs';
import { createBoundedMysql84Client } from './bounded-mysql84-client.mjs';
import { EncryptedArchiveWriter, readEncryptedArchive } from './encrypted-archive.mjs';
import { MEDIA_PROMOTION_PINS, prepareMediaPromotion, mediaPromotionSummary,
  verifyMediaReadbackAcknowledgement, mediaPromotionChunk } from './media-promotion-core.mjs';
import { stageMediaPromotion, verifyMediaPromotion, verifyAllMediaPromotions,
  checkMediaPromotionHistory } from './media-promotion-mysql84.mjs';
import { createMediaPromotionPrivacy, timewebPromotionBucketState } from './media-promotion-privacy.mjs';

const repository = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const allowed = new Set(['--mode', '--audit-file', '--hmac-key-file', '--project', '--database', '--bucket',
  '--confirm-archive-sha256', '--confirm-manifest-sha256', '--confirm-plan-sha256', '--confirm-target-db',
  '--config-file', '--ca-file', '--readback-proof-file', '--confirm-readback-proof-sha256',
  '--receipt-file', '--receipt-key-file', '--target-media-bucket', '--confirm-private-bucket',
  '--timeweb-bucket-id', '--expected-owner', '--chunk-index', '--history-file', '--verification-file', '--complete-ack-file']);
const sha = (x) => typeof x === 'string' && /^[a-f0-9]{64}$/.test(x);
export function parseMediaPromotionArgs(args) {
  const values = new Map();
  for (let i = 0; i < args.length; i += 2) {
    if (!allowed.has(args[i]) || typeof args[i + 1] !== 'string' || !args[i + 1] || values.has(args[i])) throw new Error('Invalid media promotion arguments');
    values.set(args[i], args[i + 1]);
  }
  const mode = values.get('--mode') ?? 'dry-run';
  if (!['dry-run', 'stage', 'verify', 'verify-all'].includes(mode)
      || ['--audit-file', '--hmac-key-file', '--project', '--database', '--bucket'].some((name) => !values.has(name))
      || values.get('--confirm-archive-sha256') !== MEDIA_PROMOTION_PINS.archiveSha256
      || values.get('--confirm-manifest-sha256') !== MEDIA_PROMOTION_PINS.inventoryManifestSha256
      || values.get('--confirm-plan-sha256') !== MEDIA_PROMOTION_PINS.planSha256) throw new Error('Exact reviewed full source and plan pins required');
  if (mode !== 'dry-run' && (values.get('--confirm-target-db') !== 'clrs_staging'
      || ['--config-file', '--ca-file', '--readback-proof-file', '--receipt-key-file'].some((name) => !values.has(name))
      || !sha(values.get('--confirm-readback-proof-sha256')))) throw new Error('Private readback evidence, staging TLS and receipt required');
  if (['stage', 'verify-all'].includes(mode) && ['--target-media-bucket', '--confirm-private-bucket', '--timeweb-bucket-id', '--expected-owner']
    .some((name) => !values.has(name))) throw new Error('Actual read-only S3/Timeweb privacy gate required');
  if (['stage', 'verify'].includes(mode) && (!/^(0|[1-9]\d*)$/.test(values.get('--chunk-index') ?? '')
      || Number(values.get('--chunk-index')) > 25 || !values.has('--receipt-file')
      || (Number(values.get('--chunk-index')) > 0 && !values.has('--history-file')))) throw new Error('Exact reviewed chunk/receipt/history required');
  if (mode === 'verify' && !values.has('--verification-file')) throw new Error('Durable fresh verification proof required');
  if (mode === 'verify-all' && (!values.has('--history-file') || !values.has('--complete-ack-file'))) throw new Error('Complete verified receipt chain required');
  return { values, mode };
}
async function input(value, label, maxBytes) {
  if (typeof value !== 'string' || !isAbsolute(value) || value.includes('.partial')) throw new Error('Completed absolute private input required');
  const original = await lstat(value);
  if (!original.isFile() || original.isSymbolicLink()) throw new Error('Private input cannot be a link');
  const file = await privateInput(value, label), info = await lstat(file);
  if ((info.mode & 0o777) !== 0o600 || info.uid !== process.getuid() || info.size > maxBytes) throw new Error('Same-owner 0600 bounded input required');
  return file;
}
async function output(value, inputs) {
  if (typeof value !== 'string' || !isAbsolute(value) || value.includes('.partial')) throw new Error('Private absolute receipt required');
  const parent = await realpath(dirname(value)), portion = relative(await realpath(repository), parent), info = await lstat(parent);
  if (!(portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion)) || !info.isDirectory()
      || (info.mode & 0o777) !== 0o700 || info.uid !== process.getuid()) throw new Error('Same-owner 0700 receipt directory outside Git required');
  const file = resolve(parent, basename(value));
  if (inputs.includes(file)) throw new Error('Receipt cannot replace an input');
  try { await lstat(file); } catch (error) { if (error.code === 'ENOENT') return file; throw error; }
  throw new Error('Receipt exists; verify it using a fresh connection before any retry');
}
export async function writeMediaPromotionReceipt(file, key, receipt) {
  const writer = await EncryptedArchiveWriter.create(file, key);
  try {
    await writer.writeJson(receipt); await writer.finish({ receiptRecords: 1 });
    const directory = await open(dirname(file), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } catch (error) { await writer.abort().catch(() => {}); throw error; }
}
export async function readMediaPromotionReceipt(file, key, kind = 'clrs-media-promotion-receipt') {
  let receipt, complete = false;
  for await (const frame of readEncryptedArchive(await input(file, 'Promotion receipt', 1048576), key)) {
    if (frame.type !== 'json') throw new Error('Invalid receipt frame');
    if (!receipt && !complete && frame.record.kind === kind) receipt = frame.record;
    else if (receipt && !complete && frame.record.kind === 'end' && frame.record.summary?.receiptRecords === 1) complete = true;
    else throw new Error('Invalid receipt ordering');
  }
  if (!receipt || !complete) throw new Error('Incomplete receipt'); return receipt;
}
export async function mainMediaPromotion(args = process.argv.slice(2), env = process.env) {
  const { values, mode } = parseMediaPromotionArgs(args); const keys = []; let client, s3;
  try {
    const auditPath = await input(values.get('--audit-file'), 'Authenticated media audit', 100000000);
    const hmacPath = await input(values.get('--hmac-key-file'), 'Audit HMAC key', 32);
    if (auditPath === hmacPath) throw new Error('Separate private input required');
    const hmacKey = await readFile(hmacPath); keys.push(hmacKey);
    if (hmacKey.length !== 32) throw new Error('HMAC key requires 32 bytes');
    const rootPlan = prepareMediaPromotion({ auditBytes: await readFile(auditPath), hmacKey,
      expectedSource: { project: values.get('--project'), database: values.get('--database'), bucket: values.get('--bucket') } });
    if (mode === 'dry-run') return { mode, ...mediaPromotionSummary(rootPlan), chunkSize: 200, chunks: 26 };
    const plan = mode === 'verify-all' ? rootPlan : mediaPromotionChunk(rootPlan, Number(values.get('--chunk-index')));
    const proofPath = await input(values.get('--readback-proof-file'), 'Reviewed full readback proof', 65536);
    const acknowledgement = verifyMediaReadbackAcknowledgement(rootPlan, await readFile(proofPath), hmacKey,
      values.get('--confirm-readback-proof-sha256'));
    const receiptKeyPath = await input(values.get('--receipt-key-file'), 'Separate receipt key', 32);
    const receiptKey = await readFile(receiptKeyPath); keys.push(receiptKey);
    const inputs = [auditPath, hmacPath, proofPath, receiptKeyPath];
    if (new Set(inputs).size !== inputs.length || receiptKey.length !== 32 || receiptKey.equals(hmacKey)) throw new Error('Separate 32-byte receipt key required');
    const history = [];
    if (values.has('--history-file')) {
      const historyPath = await input(values.get('--history-file'), 'Verified receipt history', 65536); inputs.push(historyPath);
      const index = JSON.parse(await readFile(historyPath, 'utf8'));
      if (index?.kind !== 'clrs-media-promotion-history' || index.version !== 1 || !Array.isArray(index.entries)
          || index.entries.length > 26 || Object.keys(index).sort().join(',') !== 'entries,kind,version') throw new Error('Invalid receipt history');
      for (const entry of index.entries) {
        if (!entry || Object.keys(entry).sort().join(',') !== 'receiptFile,verificationFile') throw new Error('Invalid receipt history entry');
        const receiptFile = await input(entry.receiptFile, 'Historical encrypted receipt', 1048576);
        const verificationFile = await input(entry.verificationFile, 'Historical encrypted verification', 1048576);
        inputs.push(receiptFile, verificationFile);
        history.push({ receipt: await readMediaPromotionReceipt(receiptFile, receiptKey),
          verification: await readMediaPromotionReceipt(verificationFile, receiptKey, 'clrs-media-promotion-chunk-verification') });
      }
    }
    if (new Set(inputs).size !== inputs.length) throw new Error('Receipt history cannot alias inputs');
    checkMediaPromotionHistory(plan, acknowledgement, history, receiptKey, { requireFresh: mode === 'stage' });
    let receiptPath, receipt, privacy, verificationPath, completePath;
    if (mode === 'stage') receiptPath = await output(values.get('--receipt-file'), inputs);
    else if (mode === 'verify') {
      const currentReceiptPath = await input(values.get('--receipt-file'), 'Current encrypted receipt', 1048576);
      if (inputs.includes(currentReceiptPath)) throw new Error('Current receipt cannot alias history');
      inputs.push(currentReceiptPath); receipt = await readMediaPromotionReceipt(currentReceiptPath, receiptKey);
      verificationPath = await output(values.get('--verification-file'), inputs);
    } else completePath = await output(values.get('--complete-ack-file'), inputs);
    const configPath = await input(values.get('--config-file'), 'MySQL private config', 65536);
    const caPath = await input(values.get('--ca-file'), 'MySQL CA', 65536);
    if (inputs.includes(configPath) || inputs.includes(caPath) || configPath === caPath
        || [configPath, caPath].some((path) => [receiptPath, verificationPath, completePath].includes(path))) throw new Error('Config/CA/receipt inputs must be separate');
    const config = await privateMysqlConfig(values);
    if (['stage', 'verify-all'].includes(mode)) {
      const settings = privateMediaConfig(values, env);
      if (settings.mediaBucket !== acknowledgement.targetBucket || values.get('--expected-owner') !== acknowledgement.expectedOwner) throw new Error('Exact readback target/owner confirmation required');
      const { S3Client } = await import('@aws-sdk/client-s3');
      s3 = new S3Client({ endpoint: settings.endpoint, region: settings.region, forcePathStyle: true,
        maxAttempts: 1, credentials: { accessKeyId: env.AWS_ACCESS_KEY_ID, secretAccessKey: env.AWS_SECRET_ACCESS_KEY },
        requestHandler: { connectionTimeout: 3000, requestTimeout: 5000, socketTimeout: 5000, throwOnRequestTimeout: true } });
      privacy = createMediaPromotionPrivacy({ client: s3, bucket: settings.mediaBucket, expectedOwner: acknowledgement.expectedOwner,
        bucketState: timewebPromotionBucketState({ bucket: settings.mediaBucket, bucketId: settings.timewebBucketId, token: settings.timewebToken }) });
    }
    // All offline source/acknowledgement/TLS/output gates precede connections.
    // No S3 operation is a mutation; no runtime credential/settings are changed.
    const mysql = await import('mysql2/promise');
    client = createBoundedMysql84Client(await mysql.createConnection(config));
    if (mode === 'stage') return await stageMediaPromotion(client, plan, acknowledgement,
      { privacy, receiptKey, history, persistReceipt: (record) => writeMediaPromotionReceipt(receiptPath, receiptKey, record) });
    if (mode === 'verify-all') return await verifyAllMediaPromotions(client, rootPlan, acknowledgement, history,
      receiptKey, privacy, (record) => writeMediaPromotionReceipt(completePath, receiptKey, record));
    const { verification, ...result } = await verifyMediaPromotion(client, plan, acknowledgement, receipt, receiptKey, history);
    await writeMediaPromotionReceipt(verificationPath, receiptKey, verification); return { ...result, verificationProofSaved: true };
  } finally { await client?.end().catch(() => {}); s3?.destroy(); keys.forEach((key) => key.fill(0)); }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  mainMediaPromotion().then((result) => process.stdout.write(`${JSON.stringify(result)}\n`)).catch((error) => {
    if (error?.commitOutcomeUnknown) process.stderr.write('Media promotion COMMIT unknown: verify the preserved receipt using a fresh connection before retry.\n');
    else process.stderr.write('Media promotion refused or failed; no source values are printed. Preserve any receipt for verification.\n');
    process.exitCode = 1;
  });
}
