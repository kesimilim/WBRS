#!/usr/bin/env node
import { randomBytes } from 'node:crypto';
import { link, open, readFile, realpath, stat, unlink } from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { privateInput } from './import-cli-common.mjs';
import { assertPreparedMediaAudit, mediaAuditSummary, prepareMediaAudit } from './media-audit-core.mjs';

const repository = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const options = new Set(['--archive', '--key-file', '--manifest', '--hmac-key-file',
  '--project', '--database', '--bucket', '--confirm-archive-sha256', '--confirm-manifest-sha256', '--output']);

export function parseMediaAuditArgs(args) {
  const values = new Map();
  for (let i = 0; i < args.length; i += 2) {
    if (!options.has(args[i]) || typeof args[i + 1] !== 'string' || !args[i + 1] || values.has(args[i])) throw new Error('Invalid media audit arguments');
    values.set(args[i], args[i + 1]);
  }
  if ([...options].some((name) => !values.has(name))) throw new Error('All private full-source audit inputs required');
  for (const name of ['--confirm-archive-sha256', '--confirm-manifest-sha256']) {
    if (!/^[a-f0-9]{64}$/.test(values.get(name))) throw new Error('Exact completed source SHA confirmation required');
  }
  return values;
}

async function privateAuditOutput(value, inputs) {
  if (!isAbsolute(value) || value.includes('.partial')) throw new Error('Private absolute audit output required');
  const parent = await realpath(dirname(value));
  const portion = relative(await realpath(repository), parent);
  const info = await stat(parent);
  if (!(portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion))
      || !info.isDirectory() || (info.mode & 0o777) !== 0o700
      || (process.getuid && info.uid !== process.getuid())) throw new Error('Audit output requires same-owner private directory outside Git');
  const output = resolve(parent, basename(value));
  if (inputs.includes(output)) throw new Error('Audit cannot replace source or keys');
  try { await stat(output); } catch (error) { if (error.code === 'ENOENT') return output; throw error; }
  throw new Error('Existing audit output is never overwritten');
}

export async function writePrivateMediaAudit(output, plan) {
  assertPreparedMediaAudit(plan);
  const partial = `${output}.partial-${randomBytes(8).toString('hex')}`;
  let file;
  try {
    file = await open(partial, 'wx', 0o600);
    await file.writeFile(JSON.stringify(plan)); await file.sync(); await file.close(); file = undefined;
    await link(partial, output); await unlink(partial);
    const directory = await open(dirname(output), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } catch (error) {
    await file?.close().catch(() => {}); await unlink(partial).catch(() => {});
    throw error;
  }
}

export async function mainMediaAudit(args = process.argv.slice(2)) {
  const values = parseMediaAuditArgs(args); const keys = [];
  try {
    const names = ['--archive', '--key-file', '--manifest', '--hmac-key-file'];
    const inputs = [];
    for (const name of names) {
      if (values.get(name).includes('.partial')) throw new Error('Partial source refused');
      inputs.push(await privateInput(values.get(name), 'Protected media audit input'));
    }
    if (new Set(inputs).size !== inputs.length) throw new Error('Separate source/manifest/key inputs required');
    const output = await privateAuditOutput(values.get('--output'), inputs);
    const key = await readFile(inputs[1]); const hmacKey = await readFile(inputs[3]); keys.push(key, hmacKey);
    if (key.length !== 32 || hmacKey.length !== 32 || key.equals(hmacKey)) throw new Error('Separate 32-byte protected keys required');
    if ((await stat(inputs[2])).size > 64_000_000) throw new Error('Manifest exceeds reviewed bound');
    const manifestBytes = await readFile(inputs[2]);
    const plan = await prepareMediaAudit({ archivePath: inputs[0], key, manifestBytes, hmacKey,
      expectedSource: { project: values.get('--project'), database: values.get('--database'), bucket: values.get('--bucket') },
      expectedArchiveSha256: values.get('--confirm-archive-sha256'), expectedManifestSha256: values.get('--confirm-manifest-sha256') });
    await writePrivateMediaAudit(output, plan);
    return mediaAuditSummary(plan);
  } finally { keys.forEach((key) => key.fill(0)); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  mainMediaAudit().then((result) => process.stdout.write(`${JSON.stringify(result)}\n`)).catch(() => {
    process.stderr.write('Private media audit failed; no partial plan is eligible for promotion. No source values are printed.\n');
    process.exitCode = 1;
  });
}
