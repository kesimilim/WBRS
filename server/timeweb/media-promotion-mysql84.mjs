import { createHash, randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { payloadHash } from './import-core.mjs';
import { assertMigrationGrants } from './mysql84-schema-core.mjs';
import { conversationBatches } from './project-conversations-mysql84.mjs';
import { assertPreparedMediaPromotion, assertMediaReadbackAcknowledgement, MEDIA_ROW_COLUMNS, signMediaPromotionReceipt,
  verifyMediaPromotionReceiptHmac, mediaPromotionChunk, mediaPromotionRoot } from './media-promotion-core.mjs';

const poisoned = new WeakSet();
const fail = (message = 'Media promotion validation failed') => { throw new Error(message); };
const hash = (x) => createHash('sha256').update(x).digest('hex');
const json = (x) => typeof x === 'string' || Buffer.isBuffer(x) ? JSON.parse(x.toString('utf8')) : x;
const count = (x) => { const v = Number(x); if (!Number.isSafeInteger(v) || v < 0) fail(); return v; };
const date = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}$/;
const timestamp = (iso) => iso.replace('T', ' ').replace('Z', '000');
const byteOrder = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const checkedRows = async (client, sql, params = []) => {
  const [rows] = await client.execute(sql, params); if (!Array.isArray(rows)) fail(); return rows;
};
function* readBatches(items, budget, maxResultBytes) {
  const limit = Math.min(100, Math.floor((budget - 2048) / (2 * maxResultBytes + 1024)));
  if (limit < 1 && items.length) fail('Insufficient bounded readback packet budget');
  for (let i = 0; i < items.length; i += limit) yield items.slice(i, i + limit);
}
export function mediaSqlRows(plan, promotedAt) {
  assertPreparedMediaPromotion(plan);
  if (typeof promotedAt !== 'string' || !date.test(promotedAt)) fail();
  return plan.rows.map((row) => ({ ...row, created_at: promotedAt, updated_at: promotedAt }));
}
export function normalizeMediaSqlRow(row) {
  return Object.fromEntries([...MEDIA_ROW_COLUMNS, 'created_at', 'updated_at'].map((name) => [name,
    ['byte_size', 'thumbnail_byte_size'].includes(name) && row[name] !== null ? count(row[name])
      : name === 'sha256' && typeof row.sha256 === 'string' ? row.sha256.toLowerCase() : row[name]]));
}
async function preflight(client) {
  if (poisoned.has(client)) fail('Fresh connection and existing receipt verification required');
  const [grants] = await client.query('SHOW GRANTS'); assertMigrationGrants(grants);
  let denied = false;
  try { await client.query('USE default_db'); }
  catch (error) { if (error?.code === 'ER_DBACCESS_DENIED_ERROR' && error.errno === 1044) denied = true; else fail(); }
  if (!denied) fail('Legacy default_db access must remain denied');
  await client.query("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'");
  await client.query("SET SESSION time_zone = '+00:00'");
  const server = await checkedRows(client, `SELECT DATABASE() AS target_database, VERSION() AS mysql_version,
    @@innodb_page_size AS page_size, @@session.sql_mode AS sql_mode,
    @@character_set_connection AS charset, @@max_allowed_packet AS max_allowed_packet`);
  const current = server[0];
  if (server.length !== 1 || current.target_database !== 'clrs_staging' || !/^8\.4\./.test(current.mysql_version ?? '')
      || count(current.page_size) !== 16384 || current.charset !== 'utf8mb4'
      || !/(^|,)STRICT_TRANS_TABLES(,|$)/.test(current.sql_mode ?? '') || count(current.max_allowed_packet) < 8192) fail();
  const [tls] = await client.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'");
  if (!Array.isArray(tls) || tls.length !== 1 || !tls[0].Value) fail('Verified target TLS required');
  const markers = await checkedRows(client, 'SELECT version FROM clrs_staging.schema_migrations ORDER BY version');
  const tables = await checkedRows(client, `SELECT table_name AS name, engine AS engine, table_collation AS collation,
    row_format AS format FROM information_schema.tables WHERE table_schema = ?`, ['clrs_staging']);
  const fk = await checkedRows(client, 'SELECT COUNT(*) AS total FROM information_schema.referential_constraints WHERE constraint_schema = ?', ['clrs_staging']);
  if (markers.length !== 1 || count(markers[0].version) !== 1 || tables.length !== 42
      || new Set(tables.map((x) => x.name)).size !== 42
      || tables.some((x) => x.engine !== 'InnoDB' || x.collation !== 'utf8mb4_0900_bin' || x.format !== 'Dynamic')
      || fk.length !== 1 || count(fk[0].total) !== 66) fail('Reviewed schema 42 tables/66 foreign keys required');
  return Math.floor(count(current.max_allowed_packet) / 2);
}
function typed(fields, key) {
  const value = fields[key]; if (value === undefined) return null;
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 1) fail();
  if ('nullValue' in value && [null, 'NULL_VALUE'].includes(value.nullValue)) return null;
  if (typeof value.stringValue === 'string') return value.stringValue;
  fail();
}
function activeProfile(fields, uid) {
  if (!fields || typeof fields !== 'object' || Array.isArray(fields)) fail();
  const saved = typed(fields, 'uid'), status = typed(fields, 'status'), registration = typed(fields, 'registrationStatus');
  if ((saved !== null && saved !== uid) || (status !== null && status !== 'active')
      || ['blocked', 'deleted'].includes(registration)) fail('Owner profile is unavailable');
  if (fields.deleted !== undefined && (!fields.deleted || Object.keys(fields.deleted).length !== 1
      || fields.deleted.booleanValue !== false)) fail('Owner profile is unavailable');
}
async function sourceAndOwners(client, plan, budget, lock) {
  const suffix = lock ? ' FOR UPDATE' : '';
  const source = await checkedRows(client, `SELECT source_project, source_database, source_bucket FROM clrs_staging.legacy_source WHERE singleton = 1${suffix}`);
  if (source.length !== 1 || source[0].source_project !== plan.source.project
      || source[0].source_database !== plan.source.database || source[0].source_bucket !== plan.source.bucket) fail();
  const totals = await checkedRows(client, `SELECT (SELECT COUNT(*) FROM clrs_staging.legacy_auth_users) AS authUsers,
    (SELECT COUNT(*) FROM clrs_staging.legacy_documents) AS firestoreDocuments,
    (SELECT COUNT(*) FROM clrs_staging.legacy_storage_objects) AS storageObjects,
    (SELECT COALESCE(SUM(source_size),0) FROM clrs_staging.legacy_storage_objects) AS storageBytes`);
  if (totals.length !== 1 || !Object.entries(plan.sourceCounts).every(([k, v]) => count(totals[0][k]) === v)) fail('Completed raw source count binding mismatch');
  for (const batch of readBatches(plan.objects, budget, 65536 + 2048)) {
    const found = await checkedRows(client, `SELECT source_bucket, source_path, source_metadata, source_size,
      HEX(source_sha256) AS source_hash, target_key, HEX(target_sha256) AS target_hash,
      DATE_FORMAT(copied_at, '%Y-%m-%d %H:%i:%s.%f') AS copied_at
      FROM clrs_staging.legacy_storage_objects WHERE source_bucket = ? AND source_path_sha256 IN
      (${batch.map(() => 'UNHEX(?)').join(',')}) AND OCTET_LENGTH(CAST(source_metadata AS CHAR CHARACTER SET utf8mb4)) <= 65536${suffix}`,
    [plan.source.bucket, ...batch.map((x) => hash(x.sourcePath))]);
    const actual = new Map(found.map((x) => [x.source_path, x]));
    if (actual.size !== batch.length || found.length !== batch.length) fail();
    for (const expected of batch) {
      const row = actual.get(expected.sourcePath), metadata = json(row?.source_metadata);
      if (!row || row.source_bucket !== plan.source.bucket || !metadata || Array.isArray(metadata)
          || payloadHash(metadata) !== expected.sourceMetadataSha256 || count(row.source_size) !== expected.byteSize
          || row.source_hash?.toLowerCase() !== expected.contentSha256 || row.target_hash?.toLowerCase() !== expected.contentSha256
          || row.target_key !== expected.targetKey || !date.test(row.copied_at ?? '')
          || (metadata.bucket !== undefined && metadata.bucket !== plan.source.bucket)
          || (expected.proposedMediaRow && metadata.contentType !== expected.proposedMediaRow.mime_type)) fail('Exact raw Storage binding mismatch');
    }
  }
  const authReferences = new Map(plan.authReferences);
  const allAuth = [...new Set([...plan.owners, ...authReferences.keys()])].sort(byteOrder);
  for (const batch of readBatches(allAuth, budget, 131072 + 1024)) {
    const found = await checkedRows(client, `SELECT uid, encoded_payload, HEX(payload_sha256) AS payload_hash
      FROM clrs_staging.legacy_auth_users WHERE uid_sha256 IN (${batch.map(() => 'UNHEX(?)').join(',')})
      AND OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= 131072${suffix}`, batch.map(hash));
    const actual = new Map(found.map((x) => [x.uid, x]));
    if (found.length !== batch.length || actual.size !== batch.length) fail();
    for (const uid of batch) {
      const row = actual.get(uid), data = json(row?.encoded_payload);
      if (!row || data?.uid !== uid || payloadHash(data) !== row.payload_hash?.toLowerCase()
          || (authReferences.has(uid) && row.payload_hash.toLowerCase() !== authReferences.get(uid))
          || (plan.owners.includes(uid) && data.disabled !== false)) fail('Owner source Auth binding mismatch');
    }
    const owned = batch.filter((uid) => plan.owners.includes(uid));
    if (!owned.length) continue;
    const accounts = await checkedRows(client, `SELECT uid, disabled, lifecycle, token_version FROM clrs_staging.accounts
      WHERE uid IN (${owned.map(() => '?').join(',')})${suffix}`, owned);
    const byUid = new Map(accounts.map((x) => [x.uid, x]));
    if (accounts.length !== owned.length || byUid.size !== owned.length
        || owned.some((uid) => !byUid.has(uid) || count(byUid.get(uid).disabled) !== 0
          || byUid.get(uid).lifecycle !== 'active' || !Number.isSafeInteger(Number(byUid.get(uid).token_version))
          || Number(byUid.get(uid).token_version) < 0)) fail('Canonical media owner must be active');
  }
  const references = new Map(plan.references);
  const profiles = new Map(plan.owners.map((uid) => [`users/${uid}`, uid]));
  const paths = [...new Set([...references.keys(), ...profiles.keys()])].sort(byteOrder);
  for (const batch of readBatches(paths, budget, 131072 + 8192)) {
    const existing = await checkedRows(client, `SELECT firebase_path FROM clrs_staging.legacy_documents
      WHERE firebase_path_sha256 IN (${batch.map(() => 'UNHEX(?)').join(',')})${suffix}`, batch.map(hash));
    const found = await checkedRows(client, `SELECT firebase_path, encoded_payload, HEX(payload_sha256) AS payload_hash
      FROM clrs_staging.legacy_documents WHERE firebase_path_sha256 IN (${batch.map(() => 'UNHEX(?)').join(',')})
      AND OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= 131072${suffix}`, batch.map(hash));
    const actual = new Map(found.map((x) => [x.firebase_path, x]));
    if (actual.size !== found.length || existing.length !== found.length
        || new Set(existing.map((x) => x.firebase_path)).size !== found.length
        || existing.some((x) => !actual.has(x.firebase_path)) || found.some((x) => !batch.includes(x.firebase_path))) fail();
    for (const path of batch) {
      const row = actual.get(path); if (!row) { if (references.has(path)) fail(); continue; }
      const data = json(row.encoded_payload);
      if (payloadHash(data) !== row.payload_hash?.toLowerCase()
          || (references.has(path) && row.payload_hash.toLowerCase() !== references.get(path))) fail('Source media reference changed');
      if (profiles.has(path)) activeProfile(data?.fields, profiles.get(path));
    }
  }
}
async function mediaCount(client) {
  const rows = await checkedRows(client, 'SELECT COUNT(*) AS total FROM clrs_staging.media_objects');
  if (rows.length !== 1) fail(); return count(rows[0].total);
}
async function verifyMediaRows(client, expected, budget, lock, expectedTotal = expected.length) {
  if (await mediaCount(client) !== expectedTotal) fail('Media target missing/extra rows');
  for (const batch of conversationBatches(expected, budget)) {
    const found = await checkedRows(client, `SELECT ${MEDIA_ROW_COLUMNS.map((name) => name === 'sha256' ? 'HEX(sha256) AS sha256' : name).join(',')},
      DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s.%f') AS created_at,
      DATE_FORMAT(updated_at, '%Y-%m-%d %H:%i:%s.%f') AS updated_at,
      HEX(object_key_sha256) AS object_hash, HEX(thumbnail_key_sha256) AS thumbnail_hash
      FROM clrs_staging.media_objects WHERE media_id IN (${batch.map(() => '?').join(',')})${lock ? ' FOR UPDATE' : ''}`, batch.map((x) => x.media_id));
    const actual = new Map(found.map((x) => [x.media_id, x]));
    if (found.length !== batch.length || actual.size !== batch.length || batch.some((row) => {
      const stored = actual.get(row.media_id);
      return !stored || stored.object_hash?.toLowerCase() !== hash(row.object_key) || stored.thumbnail_hash !== null
        || !isDeepStrictEqual(normalizeMediaSqlRow(stored), row);
    })) fail('Full media records/key/checksum binding mismatch');
  }
}
function receiptBinding(plan, acknowledgement, promotedAt, previousReceipts) {
  return { targetDatabase: 'clrs_staging', pins: plan.pins, source: plan.source,
    auditFileSha256: plan.auditFileSha256, targetRowsSha256: plan.rowsSha256,
    fullTargetRowsSha256: plan.fullRowsSha256, chunk: plan.chunk,
    priorReceiptDigests: previousReceipts.map(payloadHash),
    rawReadbackProofSha256: acknowledgement.proofFileSha256, targetBucket: acknowledgement.targetBucket,
    expectedOwner: acknowledgement.expectedOwner, candidates: plan.rows.length,
    retainedQuarantine: plan.summary.retainedQuarantine, promotedAt, emptyChunkTarget: true };
}
function checkReceipt(plan, acknowledgement, receipt, key, previousReceipts) {
  verifyMediaPromotionReceiptHmac(receipt, key);
  if (receipt.kind !== 'clrs-media-promotion-receipt' || receipt.version !== 1 || receipt.state !== 'prepared'
      || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(receipt.operationId ?? '')
      || !date.test(receipt.promotedAt ?? '')
      || !Object.entries(receiptBinding(plan, acknowledgement, receipt.promotedAt, previousReceipts)).every(([k, v]) => isDeepStrictEqual(receipt[k], v))) fail('Promotion receipt binding mismatch');
}
export function checkMediaPromotionHistory(plan, acknowledgement, history, key, { requireFresh = false } = {}) {
  assertMediaReadbackAcknowledgement(plan, acknowledgement);
  const root = mediaPromotionRoot(plan), length = plan.chunk?.index ?? Math.ceil(root.rows.length / 200);
  if (!Number.isSafeInteger(length) || !Array.isArray(history) || history.length !== length) fail('Exact verified previous chunk chain required');
  const expected = [], previousReceipts = [];
  for (let index = 0; index < history.length; index++) {
    const { receipt, verification } = history[index] ?? {};
    const prior = mediaPromotionChunk(root, index);
    checkReceipt(prior, acknowledgement, receipt, key, previousReceipts);
    expected.push(...mediaSqlRows(prior, receipt.promotedAt));
    verifyMediaPromotionReceiptHmac(verification, key);
    if (verification.kind !== 'clrs-media-promotion-chunk-verification' || verification.version !== 1
        || verification.state !== 'present_verified' || verification.receiptSha256 !== payloadHash(receipt)
        || !isDeepStrictEqual(verification.chunk, prior.chunk) || verification.prefixRows !== expected.length
        || verification.prefixRowsSha256 !== payloadHash(expected)
        || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(verification.verifiedAt ?? '')
        || !Number.isFinite(Date.parse(verification.verifiedAt))) fail('Prepared receipt alone cannot authorize resume');
    previousReceipts.push(receipt);
  }
  if (requireFresh && history.length) {
    const age = Date.now() - Date.parse(history.at(-1).verification.verifiedAt);
    if (age < 0 || age >= 300000) fail('Fresh last-chunk verification required before resume');
  }
  return { expected, previousReceipts };
}
async function transaction(client, readOnly, task) {
  let opened = false, commitSent = false;
  const timer = setTimeout(() => client.destroy?.(), 60000);
  try {
    await client.query(`SET TRANSACTION ISOLATION LEVEL ${readOnly ? 'REPEATABLE READ' : 'SERIALIZABLE'}`);
    await client.query(`START TRANSACTION${readOnly ? ' READ ONLY' : ''}`); opened = true;
    const result = await task(() => { commitSent = true; });
    if (readOnly) await client.query('ROLLBACK'); else await client.query('COMMIT'); opened = false;
    return result;
  } catch (error) {
    if (opened) await client.query('ROLLBACK').catch(() => {});
    if (!readOnly && commitSent) {
      poisoned.add(client); const unknown = new Error('Media COMMIT outcome unknown; verify existing receipt using a fresh connection');
      unknown.code = 'MEDIA_PROMOTION_COMMIT_OUTCOME_UNKNOWN'; unknown.commitOutcomeUnknown = true;
      unknown.requiresVerification = true; throw unknown;
    }
    throw error;
  } finally { clearTimeout(timer); }
}
export async function stageMediaPromotion(client, plan, acknowledgement, { privacy, persistReceipt, receiptKey, history = [] }) {
  assertMediaReadbackAcknowledgement(plan, acknowledgement);
  if (!privacy?.beforeTransaction || !privacy.beforeCommit || typeof persistReceipt !== 'function') fail('Privacy and durable encrypted receipt required');
  if (!Buffer.isBuffer(receiptKey) || receiptKey.length !== 32) fail('Separate protected receipt key required');
  const prior = checkMediaPromotionHistory(plan, acknowledgement, history, receiptKey, { requireFresh: true });
  // Thousands of object ACL GETs are OUTSIDE the transaction. The finite proof
  // expires; only three fresh global GETs are allowed before COMMIT.
  const proof = await privacy.beforeTransaction(plan, acknowledgement);
  const budget = await preflight(client);
  const promotedAt = timestamp(new Date().toISOString());
  const insertedRows = mediaSqlRows(plan, promotedAt), expected = [...prior.expected, ...insertedRows];
  for (const ignored of conversationBatches(expected, budget)) void ignored;
  return transaction(client, false, async (commit) => {
    await sourceAndOwners(client, plan, budget, true);
    // Exact previous prefix must already be present. Any current-chunk row,
    // extra row or conflict refuses writes; unknown outcomes use verify first.
    await verifyMediaRows(client, prior.expected, budget, true);
    for (const batch of conversationBatches(insertedRows, budget)) {
      const columns = [...MEDIA_ROW_COLUMNS, 'created_at', 'updated_at'];
      const [inserted] = await client.execute(`INSERT INTO clrs_staging.media_objects (${columns.join(',')}) VALUES `
        + batch.map(() => `(${columns.map((name) => name === 'sha256' ? 'UNHEX(?)' : '?').join(',')})`).join(','),
      batch.flatMap((row) => columns.map((name) => row[name])));
      if (count(inserted.affectedRows) !== batch.length) fail();
    }
    await verifyMediaRows(client, expected, budget, true);
    const receipt = signMediaPromotionReceipt({ kind: 'clrs-media-promotion-receipt', version: 1,
      state: 'prepared', operationId: randomUUID(), ...receiptBinding(plan, acknowledgement, promotedAt, prior.previousReceipts) }, receiptKey);
    checkReceipt(plan, acknowledgement, receipt, receiptKey, prior.previousReceipts);
    await persistReceipt(receipt);
    // Receipt/fsync time also counts against privacy freshness. Only one final
    // bounded global check occurs while locks are held; no per-object GETs.
    await privacy.beforeCommit(plan, proof);
    commit();
    return { mode: 'stage', candidates: plan.rows.length, retainedQuarantine: plan.summary.retainedQuarantine,
      chunk: plan.chunk.index, totalChunks: plan.chunk.total,
      databaseCommitted: true, freshReceiptVerificationRequired: true, httpEnabled: false };
  });
}
export async function verifyMediaPromotion(client, plan, acknowledgement, receipt, receiptKey, history = []) {
  assertMediaReadbackAcknowledgement(plan, acknowledgement);
  const prior = checkMediaPromotionHistory(plan, acknowledgement, history, receiptKey);
  checkReceipt(plan, acknowledgement, receipt, receiptKey, prior.previousReceipts);
  const budget = await preflight(client);
  return transaction(client, true, async () => {
    await sourceAndOwners(client, plan, budget, false);
    const total = await mediaCount(client); let outcome;
    let expected;
    if (total === prior.expected.length && plan.rows.length) {
      await verifyMediaRows(client, prior.expected, budget, false); outcome = 'not_committed_verified'; expected = prior.expected;
    } else {
      expected = [...prior.expected, ...mediaSqlRows(plan, receipt.promotedAt)];
      await verifyMediaRows(client, expected, budget, false); outcome = 'present_verified';
    }
    const verification = signMediaPromotionReceipt({ kind: 'clrs-media-promotion-chunk-verification', version: 1,
      state: outcome, receiptSha256: payloadHash(receipt), chunk: plan.chunk,
      prefixRows: expected.length, prefixRowsSha256: payloadHash(expected), verifiedAt: new Date().toISOString() }, receiptKey);
    return { mode: 'verify', outcome, candidates: plan.rows.length, actualMediaRows: total,
      retainedQuarantine: plan.summary.retainedQuarantine, databaseWrites: 0, httpEnabled: false, verification };
  });
}
export async function verifyAllMediaPromotions(client, root, acknowledgement, history, receiptKey, privacy, persistCompleteAcknowledgement) {
  assertMediaReadbackAcknowledgement(root, acknowledgement);
  if (root.chunk || !privacy?.beforeTransaction || !privacy.beforeCommit
      || typeof persistCompleteAcknowledgement !== 'function') fail('Full reviewed plan and durable complete acknowledgement required');
  const checked = checkMediaPromotionHistory(root, acknowledgement, history, receiptKey);
  const budget = await preflight(client), startedAt = new Date().toISOString();
  let lastPlan, lastProof;
  for (let index = 0; index < history.length; index++) {
    const chunk = mediaPromotionChunk(root, index);
    const proof = await privacy.beforeTransaction(chunk, acknowledgement);
    await transaction(client, true, async () => {
      await sourceAndOwners(client, chunk, budget, false);
      await verifyMediaRows(client, mediaSqlRows(chunk, history[index].receipt.promotedAt), budget, false, root.rows.length);
      await privacy.beforeCommit(chunk, proof);
    });
    lastPlan = chunk; lastProof = proof;
  }
  // Final exact COUNT/full-record readback and all source/owner checks use one
  // fresh SQL snapshot. S3 privacy is deliberately sequential per chunk, not
  // claimed to be an atomic cross-service snapshot. HTTP still rechecks ACL,
  // current authorization and full GET SHA before any bytes can be returned.
  await transaction(client, true, async () => {
    await sourceAndOwners(client, root, budget, false);
    await verifyMediaRows(client, checked.expected, budget, false);
    await privacy.beforeCommit(lastPlan, lastProof);
  });
  const complete = signMediaPromotionReceipt({ kind: 'clrs-media-promotion-complete-acknowledgement', version: 1,
    state: 'sequential_privacy_chunks_and_final_sql_verified', pins: root.pins,
    source: root.source, auditFileSha256: root.auditFileSha256, targetRowsSha256: root.rowsSha256,
    receiptDigests: checked.previousReceipts.map(payloadHash), rawReadbackProofSha256: acknowledgement.proofFileSha256,
    targetBucket: acknowledgement.targetBucket, expectedOwner: acknowledgement.expectedOwner,
    candidates: root.rows.length, retainedQuarantine: root.summary.retainedQuarantine,
    startedAt, verifiedAt: new Date().toISOString(), atomicCrossServiceSnapshot: false, httpEnabled: false }, receiptKey);
  await persistCompleteAcknowledgement(complete);
  return { mode: 'verify-all', actualMediaRows: root.rows.length, chunksVerified: history.length,
    retainedQuarantine: root.summary.retainedQuarantine, databaseWrites: 0,
    completeAcknowledgementSaved: true, atomicCrossServiceSnapshot: false, httpEnabled: false };
}
