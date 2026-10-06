import assert from 'node:assert/strict';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { payloadHash, targetObjectKey } from '../import-core.mjs';
import { prepareMediaPromotion, MEDIA_PROMOTION_PINS, mediaPromotionChunk, mediaPromotionSummary,
  signMediaReadbackAcknowledgement, verifyMediaReadbackAcknowledgement, signMediaPromotionReceipt } from '../media-promotion-core.mjs';
import { stageMediaPromotion, verifyMediaPromotion, verifyAllMediaPromotions } from '../media-promotion-mysql84.mjs';
import { createMediaPromotionPrivacy, timewebPromotionBucketState } from '../media-promotion-privacy.mjs';
import { parseMediaPromotionArgs, writeMediaPromotionReceipt, readMediaPromotionReceipt } from '../media-promotion-cli.mjs';

const hash = (value) => createHash('sha256').update(value).digest('hex');
const source = { project: 'synthetic-media', database: '(default)', bucket: 'synthetic-media.appspot.com' };
const owner = 'SyntheticOwner', bucket = 'synthetic-private-bucket';
const hmacKey = randomBytes(32), receiptKey = randomBytes(32);
const clones = (x) => structuredClone(x);
const acl = (id = owner) => ({ Owner: { ID: id }, Grants: [{ Permission: 'FULL_CONTROL', Grantee: { Type: 'CanonicalUser', ID: id } }] });
function fixture(amount = 2, change = () => {}) {
  const uids = ['Synthetic-A', 'synthetic-a'];
  const auth = uids.map((uid) => ({ uid, disabled: false }));
  const docs = new Map(uids.map((uid) => [`users/${uid}`, { fields: { uid: { stringValue: uid }, status: { stringValue: 'active' } } }]));
  const storage = new Map();
  const objects = Array.from({ length: amount + 1 }, (_, i) => {
    const sourcePath = `synthetic-images/file-${i}.jpg`, targetKey = targetObjectKey(source.project, source.bucket, sourcePath);
    const metadata = { bucket: source.bucket, name: sourcePath, contentType: 'image/jpeg', size: '5' };
    const digest = hash(`synthetic-bytes-${i}`), uid = uids[i % 2], path = `chats/Synthetic/chats/Message-${i}`;
    const document = { fields: { image: { stringValue: `gs://${source.bucket}/${sourcePath}` }, sendByID: { stringValue: uid } } };
    docs.set(path, document); storage.set(sourcePath, metadata);
    const candidate = i < amount;
    return { sourceBucket: source.bucket, sourcePath, sourceMetadataSha256: payloadHash(metadata), byteSize: 5,
      contentSha256: digest, targetKey, disposition: candidate ? 'review_candidate' : 'retain_quarantine',
      reasonCodes: candidate ? [] : ['ambiguous_owner'], owners: candidate ? [uid] : uids,
      purposes: ['message'], referenceCount: 1, ownedReferenceCount: 1, sourcePathClaim: null,
      references: [{ name: sourcePath, documentPath: path, field: 'image', documentSha256: payloadHash(document),
        owner: uid, purpose: 'message', context: 'outer_message_image', validContext: true }],
      proposedMediaRow: candidate ? { media_id: `legacy-media-${targetKey.split('/').at(-1)}`, owner_uid: uid,
        purpose: 'message', object_key: targetKey, thumbnail_key: null, mime_type: 'image/jpeg', byte_size: 5,
        sha256: digest, status: 'ready', legacy_storage_path: sourcePath } : null };
  });
  const body = { kind: 'clrs-private-media-audit', schemaVersion: 1, completeFullSource: true, source,
    archiveSha256: hash('synthetic-full-archive'), inventoryManifestSha256: hash('synthetic-manifest'),
    sourceCounts: { authUsers: 2, firestoreDocuments: docs.size, storageObjects: objects.length, storageBytes: objects.length * 5 },
    promotionMode: 'reviewed-immutable-object-alias', fullRawReadbackRequired: true,
    separatePrivateS3ReadRoleRequired: true, liveBucketPrivacyReviewRequired: true, promotionsPerformed: 0,
    summary: { sourceObjects: objects.length, sourceBytes: objects.length * 5, referencedObjects: objects.length,
      unreferencedObjects: 0, reviewCandidates: amount, retainedQuarantine: 1, sourceReferences: objects.length,
      referencesToMissingObjects: 0, boundedTraversalDocuments: 0, reasonCounts: { ambiguous_owner: 1 } }, objects, missingReferences: [] };
  change(body); const planSha256 = payloadHash(body);
  const planHmacSha256 = createHmac('sha256', hmacKey).update('clrs-media-audit-v1\0').update(planSha256).digest('hex');
  const auditBytes = Buffer.from(JSON.stringify({ ...body, planSha256, planHmacSha256 }));
  const pins = { archiveSha256: body.archiveSha256, inventoryManifestSha256: body.inventoryManifestSha256, planSha256 };
  const root = prepareMediaPromotion({ auditBytes, hmacKey, expectedSource: source, expectedPins: pins });
  const acknowledgementBody = { kind: 'clrs-media-full-readback-acknowledgement', version: 1,
    state: 'reviewed_verified_full_raw_sql_s3', pins, source, counts: root.sourceCounts,
    targetBucket: bucket, expectedOwner: owner, completedAt: new Date().toISOString(),
    rawVerifyResultSha256: hash('synthetic-actual-readback-result'), rawVerifyStatusSha256: hash('synthetic-actual-readback-status') };
  const proofBytes = Buffer.from(JSON.stringify(signMediaReadbackAcknowledgement(acknowledgementBody, hmacKey)));
  const acknowledgement = verifyMediaReadbackAcknowledgement(root, proofBytes, hmacKey, hash(proofBytes));
  return { root, plan: mediaPromotionChunk(root, 0), auditBytes, pins, acknowledgement, auth, docs, storage };
}
class Database {
  constructor(f, options = {}, media = []) { this.f = f; this.options = options; this.media = clones(media); this.trace = []; this.inserts = 0; }
  async query(sql) {
    this.trace.push(sql);
    if (sql === 'SHOW GRANTS') return [[{ g: 'GRANT USAGE ON *.* TO `synthetic`@`%`' },
      { g: `GRANT CREATE, REFERENCES, SELECT, INSERT, UPDATE${this.options.extraGrant ? ', DELETE' : ''} ON \`clrs_staging\`.* TO \`synthetic\`@\`%\`` }]];
    if (sql === 'USE default_db') throw Object.assign(new Error('Synthetic denial'), { code: 'ER_DBACCESS_DENIED_ERROR', errno: 1044 });
    if (sql.startsWith('SHOW SESSION STATUS')) return [[{ Value: 'SyntheticTLSCipher' }]];
    if (sql.startsWith('START TRANSACTION')) { this.before = clones(this.media); return [[]]; }
    if (sql === 'ROLLBACK') { if (this.before) this.media = this.before; this.before = undefined; return [[]]; }
    if (sql === 'COMMIT') {
      if (this.options.commit === 'applied') { this.before = undefined; throw new Error('Synthetic acknowledgement lost'); }
      if (this.options.commit === 'not_applied') throw new Error('Synthetic acknowledgement lost');
      this.before = undefined; return [[]];
    }
    return [[]];
  }
  async execute(sql, params = []) {
    this.trace.push(sql);
    if (sql.startsWith('SELECT DATABASE()')) return [[{ target_database: 'clrs_staging', mysql_version: '8.4.4', page_size: 16384,
      sql_mode: 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION', charset: 'utf8mb4', max_allowed_packet: this.options.packet ?? 16777216 }]];
    if (sql.includes('FROM clrs_staging.schema_migrations')) return [[{ version: 1 }]];
    if (sql.includes('FROM information_schema.tables')) return [Array.from({ length: 42 }, (_, i) => ({ name: `synthetic_table_${i}`, engine: 'InnoDB', collation: 'utf8mb4_0900_bin', format: 'Dynamic' }))];
    if (sql.includes('information_schema.referential_constraints')) return [[{ total: 66 }]];
    if (sql.includes('FROM clrs_staging.legacy_source')) return [[{ source_project: source.project, source_database: source.database, source_bucket: source.bucket }]];
    if (sql.includes('AS authUsers')) return [[this.f.root.sourceCounts]];
    if (sql.includes('FROM clrs_staging.legacy_storage_objects')) return [this.f.root.objects.filter((x) => params.slice(1).includes(hash(x.sourcePath))).map((x) => ({
      source_bucket: x.sourceBucket, source_path: x.sourcePath, source_metadata: JSON.stringify(this.f.storage.get(x.sourcePath)),
      source_size: x.byteSize, source_hash: x.contentSha256, target_key: this.options.keyConflict ? 'synthetic-conflicting-key' : x.targetKey,
      target_hash: x.contentSha256, copied_at: this.options.notCopied ? null : '2026-10-01 00:00:00.000000' }))];
    if (sql.includes('FROM clrs_staging.legacy_auth_users')) return [this.f.auth.filter((x) => params.includes(hash(x.uid))).map((x) => ({
      uid: x.uid, encoded_payload: JSON.stringify({ ...x, disabled: this.options.disabledAuth ?? x.disabled }),
      payload_hash: payloadHash({ ...x, disabled: this.options.disabledAuth ?? x.disabled }) }))];
    if (sql.includes('FROM clrs_staging.accounts')) return [params.map((uid) => ({ uid, disabled: 0, lifecycle: this.options.lifecycle ?? 'active', token_version: 0 }))];
    if (sql.includes('FROM clrs_staging.legacy_documents')) return [[...this.f.docs].filter(([path]) => params.includes(hash(path))).map(([path, document]) => {
      const payload = clones(document);
      if (path.startsWith('users/') && this.options.registration) payload.fields.registrationStatus = { stringValue: this.options.registration };
      return sql.startsWith('SELECT firebase_path FROM') ? { firebase_path: path }
        : { firebase_path: path, encoded_payload: JSON.stringify(payload), payload_hash: payloadHash(payload) };
    })];
    if (sql.startsWith('SELECT COUNT(*) AS total FROM clrs_staging.media_objects')) return [[{ total: this.media.length }]];
    if (sql.includes('FROM clrs_staging.media_objects WHERE media_id')) return [this.media.filter((x) => params.includes(x.media_id)).map((x) => ({ ...clones(x), object_hash: hash(x.object_key), thumbnail_hash: null }))];
    if (sql.startsWith('INSERT INTO clrs_staging.media_objects')) {
      const columns = /\(([^)]+)\) VALUES/.exec(sql)[1].split(',');
      const batch = []; for (let i = 0; i < params.length; i += columns.length) batch.push(Object.fromEntries(columns.map((c, n) => [c, params[i + n]])));
      this.inserts += batch.length; this.media.push(...batch); return [{ affectedRows: batch.length }];
    }
    throw new Error('Unexpected synthetic SQL');
  }
  destroy() { this.destroyed = true; }
}
function privacy(f, options = {}) {
  let active = 0, max = 0, calls = 0; const trace = [];
  const port = createMediaPromotionPrivacy({ bucket, expectedOwner: owner,
    bucketState: async () => ({ bucket, type: options.publicBucket ? 'public' : 'private', websiteEnabled: false }),
    clock: options.clock,
    client: { async send(command) {
      trace.push(command.constructor.name);
      if (command.constructor.name === 'GetBucketPolicyCommand') return { Policy: JSON.stringify({ Version: '2012-10-17', Statement: [] }) };
      if (command.constructor.name === 'GetObjectAclCommand') {
        active++; max = Math.max(max, active); calls++; await new Promise((resolve) => setTimeout(resolve, 1)); active--;
      }
      return acl(options.foreignOwner ? 'SyntheticForeignOwner' : owner);
    } } });
  return { ...port, trace, stats: () => ({ max, calls }) };
}
async function stage(f, database = new Database(f), history = [], plan = f.plan, extra = {}) {
  let receipt;
  const result = await stageMediaPromotion(database, plan, f.acknowledgement, { privacy: privacy(f), receiptKey, history,
    persistReceipt: async (value) => { receipt = value; database.trace.push('DURABLE_RECEIPT'); }, ...extra });
  return { result, receipt, database };
}
test('HMAC, exact reviewed pins and summary refuse tampered inputs', () => {
  const f = fixture();
  assert.throws(() => prepareMediaPromotion({ auditBytes: f.auditBytes, hmacKey, expectedSource: source }));
  const bytes = Buffer.from(f.auditBytes); bytes[10] ^= 1;
  assert.throws(() => prepareMediaPromotion({ auditBytes: bytes, hmacKey, expectedSource: source, expectedPins: f.pins }));
  assert.throws(() => fixture(2, (body) => { body.summary.sourceObjects++; }));
  assert.throws(() => fixture(2, (body) => { body.objects[0].owners.push('SyntheticOther'); }));
});
test('candidate-only deterministic chunks retain every quarantine object without promotion', () => {
  const f = fixture(201), second = mediaPromotionChunk(f.root, 1);
  assert.equal(f.plan.rows.length, 200); assert.equal(second.rows.length, 1);
  assert.equal(mediaPromotionSummary(f.root).promotionsPerformed, 0);
  assert.equal(mediaPromotionSummary(f.root).retainedQuarantine, 1);
  assert.equal(new Set([...f.plan.rows, ...second.rows].map((x) => x.media_id)).size, 201);
});
test('source storage binding, canonical inactive owner and grants stop before INSERT', async () => {
  for (const options of [{ keyConflict: true }, { notCopied: true }, { lifecycle: 'blocked' }, { disabledAuth: true }, { extraGrant: true }, { packet: 8192 }]) {
    const f = fixture(), db = new Database(f, options); await assert.rejects(stage(f, db)); assert.equal(db.inserts, 0);
  }
});
test('registrationStatus blocked/deleted refuses even when status remains active', async () => {
  for (const registration of ['blocked', 'deleted']) { const f = fixture(), db = new Database(f, { registration });
    await assert.rejects(stage(f, db)); assert.equal(db.inserts, 0); }
});
test('chunk INSERT is bounded, receipt fsynced before COMMIT, raw rows are never written', async () => {
  const f = fixture(201), completed = await stage(f);
  assert.equal(completed.database.inserts, 200);
  assert(completed.database.trace.indexOf('DURABLE_RECEIPT') < completed.database.trace.lastIndexOf('COMMIT'));
  assert(completed.database.trace.filter((x) => /^(INSERT|UPDATE|DELETE|CREATE|GRANT|ALTER)/.test(x)).every((x) => x.startsWith('INSERT INTO clrs_staging.media_objects')));
  assert.equal(completed.result.httpEnabled, false);
});
test('fresh receipt-bound verify permits next exact chunk, then final all-row verification', async () => {
  const f = fixture(201), first = await stage(f);
  const verified = await verifyMediaPromotion(new Database(f, {}, first.database.media), f.plan, f.acknowledgement, first.receipt, receiptKey);
  assert.equal(verified.outcome, 'present_verified');
  const history = [{ receipt: first.receipt, verification: verified.verification }], secondPlan = mediaPromotionChunk(f.root, 1);
  const second = await stage(f, new Database(f, {}, first.database.media), history, secondPlan);
  assert.equal(second.database.media.length, 201); assert.equal(second.database.inserts, 1);
  const secondVerify = await verifyMediaPromotion(new Database(f, {}, second.database.media), secondPlan, f.acknowledgement, second.receipt, receiptKey, history);
  history.push({ receipt: second.receipt, verification: secondVerify.verification });
  let complete;
  const final = await verifyAllMediaPromotions(new Database(f, {}, second.database.media), f.root, f.acknowledgement, history,
    receiptKey, privacy(f), async (value) => { complete = value; });
  assert.equal(final.actualMediaRows, 201); assert.equal(complete.atomicCrossServiceSnapshot, false); assert.equal(complete.httpEnabled, false);
});
test('unknown COMMIT applied/not applied requires fresh reconciliation, never a replay', async () => {
  for (const commit of ['applied', 'not_applied']) {
    const f = fixture(); const db = new Database(f, { commit }); let receipt;
    await assert.rejects(stage(f, db, [], f.plan, { persistReceipt: async (x) => { receipt = x; } }), (e) => e.commitOutcomeUnknown === true);
    await assert.rejects(verifyMediaPromotion(db, f.plan, f.acknowledgement, receipt, receiptKey));
    const result = await verifyMediaPromotion(new Database(f, {}, db.media), f.plan, f.acknowledgement, receipt, receiptKey);
    assert.equal(result.outcome, commit === 'applied' ? 'present_verified' : 'not_committed_verified');
    assert.equal(db.inserts, 2);
  }
});
test('conflicting/extra rows refuse stage and do not overwrite', async () => {
  const f = fixture(), db = new Database(f, {}, [{ media_id: 'SyntheticForeign', owner_uid: 'Synthetic-A' }]);
  await assert.rejects(stage(f, db)); assert.equal(db.inserts, 0);
});
test('receipt persistence failure rolls back, mismatched receipt HMAC refuses verification before SQL', async () => {
  const f = fixture(), db = new Database(f);
  await assert.rejects(stage(f, db, [], f.plan, { persistReceipt: async () => { throw new Error('Synthetic fsync error'); } }));
  assert.equal(db.media.length, 0); assert(!db.trace.includes('COMMIT'));
  const first = await stage(f), verifyDb = new Database(f, {}, first.database.media);
  await assert.rejects(verifyMediaPromotion(verifyDb, f.plan, f.acknowledgement, { ...first.receipt, candidates: 9 }, receiptKey));
  assert.equal(verifyDb.trace.length, 0);
});
test('encrypted receipt survives private roundtrip and rejects a wrong encryption key', async (t) => {
  const f = fixture(), first = await stage(f), directory = await mkdtemp(join(tmpdir(), 'clrs-media-receipt-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = join(directory, 'receipt.clrsenc');
  await writeMediaPromotionReceipt(file, receiptKey, first.receipt);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.deepEqual(await readMediaPromotionReceipt(file, receiptKey), first.receipt);
  await assert.rejects(readMediaPromotionReceipt(file, randomBytes(32)));
  await assert.rejects(writeMediaPromotionReceipt(file, receiptKey, first.receipt));
});
test('prepared-only history, wrong verification identity and stale proof cannot resume', async () => {
  const f = fixture(201), first = await stage(f), second = mediaPromotionChunk(f.root, 1);
  const verified = await verifyMediaPromotion(new Database(f, {}, first.database.media), f.plan, f.acknowledgement, first.receipt, receiptKey);
  const { receiptHmacSha256, ...body } = verified.verification;
  const stale = signMediaPromotionReceipt({ ...body, verifiedAt: '2020-01-01T00:00:00.000Z' }, receiptKey);
  for (const verification of [undefined, { ...verified.verification, receiptSha256: hash('synthetic-wrong-receipt') }, stale]) {
    const db = new Database(f, {}, first.database.media);
    await assert.rejects(stage(f, db, [{ receipt: first.receipt, verification }], second)); assert.equal(db.trace.length, 0);
  }
});
test('readonly privacy cap4 verifies only GETs, foreign owner/private state and old proof refuse', async () => {
  const f = fixture(20), port = privacy(f); const proof = await port.beforeTransaction(f.plan, f.acknowledgement);
  assert.equal(port.stats().calls, 20); assert.equal(port.stats().max, 4);
  assert(port.trace.every((x) => ['GetBucketAclCommand', 'GetBucketPolicyCommand', 'GetObjectAclCommand'].includes(x)));
  await port.beforeCommit(f.plan, proof);
  await assert.rejects(privacy(f, { foreignOwner: true }).beforeTransaction(f.plan, f.acknowledgement));
  await assert.rejects(privacy(f, { publicBucket: true }).beforeTransaction(f.plan, f.acknowledgement));
  let now = 0; const old = privacy(f, { clock: () => now }), oldProof = await old.beforeTransaction(f.plan, f.acknowledgement);
  now = 120000; await assert.rejects(old.beforeCommit(f.plan, oldProof));
});
test('privacy proof from another port is rejected before network calls', async () => {
  const f = fixture(), sourcePort = privacy(f);
  const proof = await sourcePort.beforeTransaction(f.plan, f.acknowledgement);
  let stateCalls = 0, s3Calls = 0;
  const targetPort = createMediaPromotionPrivacy({ bucket, expectedOwner: owner,
    bucketState: async () => { stateCalls++; return { bucket, type: 'private', websiteEnabled: false }; },
    client: { async send(command) { s3Calls++;
      return command.constructor.name === 'GetBucketPolicyCommand'
        ? { Policy: JSON.stringify({ Version: '2012-10-17', Statement: [] }) } : acl(); } } });
  await assert.rejects(targetPort.beforeCommit(f.plan, proof));
  assert.equal(stateCalls, 0); assert.equal(s3Calls, 0);
  await sourcePort.beforeCommit(f.plan, proof);
});
test('concrete control-plane GET is bounded and checks exact private bucket identity', async () => {
  let options;
  const state = timewebPromotionBucketState({ bucket, bucketId: 123, token: 'synthetic-not-a-real-token',
    fetchImpl: async (_url, value) => { options = value; return new Response(JSON.stringify({ bucket: { id: 123, name: bucket, type: 'private' } })); } });
  assert.deepEqual(await state(), { bucket, type: 'private', websiteEnabled: false }); assert.equal(options.redirect, 'error');
  const wrong = timewebPromotionBucketState({ bucket, bucketId: 123, token: 'synthetic-not-a-real-token',
    fetchImpl: async () => new Response(JSON.stringify({ bucket: { id: 124, name: bucket, type: 'private' } })) });
  await assert.rejects(wrong());
});
test('CLI pins cannot be overridden, source/staging/receipt arguments are explicit', () => {
  const args = ['--audit-file', '/synthetic/audit.json', '--hmac-key-file', '/synthetic/hmac.key',
    '--project', source.project, '--database', source.database, '--bucket', source.bucket,
    '--confirm-archive-sha256', MEDIA_PROMOTION_PINS.archiveSha256,
    '--confirm-manifest-sha256', MEDIA_PROMOTION_PINS.inventoryManifestSha256,
    '--confirm-plan-sha256', MEDIA_PROMOTION_PINS.planSha256];
  assert.equal(parseMediaPromotionArgs(args).mode, 'dry-run');
  assert.throws(() => parseMediaPromotionArgs([...args, '--mode', 'stage']));
  assert.throws(() => parseMediaPromotionArgs([...args.slice(0, -1), hash('synthetic-other-plan')]));
  assert.throws(() => parseMediaPromotionArgs([...args, '--mode', 'unreviewed']));
});
