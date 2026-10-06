import { createHash, randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { payloadHash } from './import-core.mjs';
import { assertMigrationGrants } from './mysql84-schema-core.mjs';
import { assertPreparedConversationPlan } from './project-conversations-core.mjs';
import { PROFILE_DETAILS_COLUMNS } from './project-profile-details.mjs';

const DATABASE = 'clrs_staging';
const poisoned = new WeakSet();
const hash = (value) => createHash('sha256').update(value, 'utf8').digest('hex');
const json = (value) => typeof value === 'string' || Buffer.isBuffer(value)
  ? JSON.parse(value.toString('utf8')) : value;
const fail = (message = 'Conversation projection validation failed') => { throw new Error(message); };
const count = (value) => {
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result < 0) fail();
  return result;
};
const dates = new Set(['created_at', 'updated_at', 'starts_at', 'archived_at', 'edited_at',
  'deleted_at', 'joined_at', 'left_at', 'kicked_at', 'firebase_created_at', 'firebase_last_login_at']);
const numbers = new Set(['last_sequence', 'revision', 'sequence', 'source_sequence', 'read_through_sequence',
  'notifications_enabled', 'membership_revision', 'email_verified', 'disabled', 'token_version',
  'profile_details_saved', 'registration_complete', 'age', 'height_cm', 'has_children']);
const jsonFields = new Set(['legacy_raw', 'legacy_claims', 'test_result']);
const contract = (table, property, keys, columns) => Object.freeze({ table, property, keys, columns });
export const CONVERSATION_TABLES = Object.freeze([
  contract('chats', 'chats', ['chat_id'], ['chat_id', 'uid_low', 'uid_high', 'created_at', 'updated_at', 'last_sequence', 'revision', 'legacy_raw']),
  contract('chat_members', 'chatMembers', ['chat_id', 'uid'], ['chat_id', 'uid', 'read_through_sequence', 'notifications_enabled', 'archived_at']),
  contract('chat_messages', 'chatMessages', ['chat_id', 'message_id'], ['chat_id', 'message_id', 'sequence', 'sender_uid', 'body', 'media_id', 'reply_to_id', 'gift_notice_id', 'created_at', 'edited_at', 'deleted_at', 'legacy_raw']),
  contract('meetings', 'meetings', ['meeting_id'], ['meeting_id', 'organizer_uid', 'invited_uid', 'kind', 'title', 'description', 'country_code', 'region', 'starts_at', 'created_at', 'updated_at', 'media_id', 'creation_request_id', 'revision', 'deleted_at', 'legacy_raw']),
  contract('meeting_members', 'meetingMembers', ['meeting_id', 'uid'], ['meeting_id', 'uid', 'joined_at', 'left_at', 'kicked_at', 'membership_revision', 'legacy_raw']),
  contract('meeting_messages', 'meetingMessages', ['meeting_id', 'message_id'], ['meeting_id', 'message_id', 'sequence', 'sender_uid', 'body', 'media_id', 'created_at', 'legacy_raw']),
  contract('removed_meeting_messages', 'removedMeetingMessages', ['owner_uid', 'meeting_id', 'message_id'], ['owner_uid', 'meeting_id', 'message_id', 'source_sequence', 'archived_at', 'legacy_raw']),
]);
for (const spec of CONVERSATION_TABLES) { Object.freeze(spec.keys); Object.freeze(spec.columns); }
const accountColumns = ['uid', 'email_normalized', 'email_verified', 'disabled', 'lifecycle', 'token_version',
  'firebase_created_at', 'firebase_last_login_at', 'legacy_claims'];
const profileColumns = ['uid', 'full_name', 'country', 'city', 'primary_group',
  ...PROFILE_DETAILS_COLUMNS, 'updated_at', 'legacy_raw'];
const profileUnused = ['invisible_until', 'last_online_at'];
const identityColumns = ['uid', 'provider', 'provider_subject', 'provider_email', 'legacy_raw'];

export function assertConversationConfirmations(plan, values) {
  assertPreparedConversationPlan(plan);
  if (!plan.dependencies.ready) fail('Account/profile source projection must be available first');
  if (values?.targetDatabase !== DATABASE || values.archiveSha256 !== plan.archiveSha256
      || values.projectionSha256 !== plan.projectionSha256 || values.dependencySha256 !== plan.dependencySha256
      || values.rawOnlyDocuments !== plan.rawOnlyAcknowledgement.documents
      || values.rawOnlyParticipantEntries !== plan.rawOnlyAcknowledgement.participantEntries
      || values.rawOnlyReasonDigest !== plan.rawOnlyAcknowledgement.reasonDigest) {
    fail('Explicit source, dependency, mapping and raw-only acknowledgements required');
  }
}

// Worst-case escaping is included even though mysql2 uses binary placeholders.
// Bounds apply to requests and expected result JSON, not UTF-16 text.length.
export function* conversationBatches(records, packetBudget) {
  if (!Number.isSafeInteger(packetBudget) || packetBudget < 4096) fail('Insufficient guarded packet budget');
  let batch = []; let bytes = 2048;
  for (const record of records) {
    const amount = 128 + 32 * Object.keys(record).length + 2 * Buffer.byteLength(JSON.stringify(record), 'utf8');
    if (amount + 2048 > packetBudget) fail('Conversation/source row exceeds guarded packet budget');
    if (batch.length && (batch.length === 100 || bytes + amount > packetBudget)) {
      yield batch; batch = []; bytes = 2048;
    }
    batch.push(record); bytes += amount;
  }
  if (batch.length) yield batch;
}
async function rows(client, sql, params = []) {
  const [result] = await client.execute(sql, params);
  if (!Array.isArray(result)) fail();
  return result;
}
function selectColumns(columns) {
  return columns.map((name) => dates.has(name)
    ? `DATE_FORMAT(${name}, '%Y-%m-%d %H:%i:%s.%f') AS ${name}` : name).join(', ');
}
function normalize(row, columns) {
  return Object.fromEntries(columns.map((name) => [name, jsonFields.has(name) ? json(row[name])
    : numbers.has(name) && row[name] !== null ? count(row[name]) : row[name]]));
}
const rowKey = (row, keys) => JSON.stringify(keys.map((key) => row[key]));

async function preflight(client) {
  if (poisoned.has(client)) fail('Fresh connection and receipt-bound verification required');
  const [grants] = await client.query('SHOW GRANTS');
  assertMigrationGrants(grants);
  let denied = false;
  try { await client.query('USE default_db'); }
  catch (error) { if (error?.errno === 1044 && error?.code === 'ER_DBACCESS_DENIED_ERROR') denied = true; else fail(); }
  if (!denied) fail('Legacy database must remain inaccessible');
  await client.query("SET SESSION time_zone = '+00:00'");
  await client.query("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'");
  const server = await rows(client, `SELECT DATABASE() AS target_database, VERSION() AS mysql_version,
    @@innodb_page_size AS page_size, @@session.sql_mode AS sql_mode,
    @@character_set_connection AS charset, @@max_allowed_packet AS max_allowed_packet`);
  const current = server[0];
  if (server.length !== 1 || current.target_database !== DATABASE || !/^8\.4\./.test(current.mysql_version ?? '')
      || Number(current.page_size) !== 16384 || current.charset !== 'utf8mb4'
      || !/(^|,)STRICT_TRANS_TABLES(,|$)/.test(current.sql_mode ?? '')
      || count(current.max_allowed_packet) < 8192) fail('Strict MySQL 8.4 staging target required');
  const [tls] = await client.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'");
  if (!Array.isArray(tls) || tls.length !== 1 || !tls[0].Value) fail('Database TLS required');
  const migrations = await rows(client, 'SELECT version FROM clrs_staging.schema_migrations ORDER BY version');
  const tables = await rows(client, `SELECT table_name AS name, engine AS engine,
    table_collation AS collation, row_format AS format FROM information_schema.tables WHERE table_schema = ?`, [DATABASE]);
  const constraints = await rows(client,
    'SELECT COUNT(*) AS total FROM information_schema.referential_constraints WHERE constraint_schema = ?', [DATABASE]);
  if (migrations.length !== 1 || Number(migrations[0].version) !== 1 || tables.length !== 42
      || tables.some((row) => row.engine !== 'InnoDB' || row.collation !== 'utf8mb4_0900_bin' || row.format !== 'Dynamic')
      || constraints.length !== 1 || count(constraints[0].total) !== 66) fail('Reviewed schema 42 tables/66 foreign keys required');
  return Math.floor(count(current.max_allowed_packet) / 2);
}

async function verifyCanonical(client, spec, expected, packetBudget, lock = false) {
  const total = await rows(client, `SELECT COUNT(*) AS total FROM clrs_staging.${spec.table}`);
  if (total.length !== 1 || count(total[0].total) !== expected.length) fail('Canonical projection count mismatch');
  for (const batch of conversationBatches(expected, packetBudget)) {
    const found = await rows(client, `SELECT ${selectColumns(spec.columns)} FROM clrs_staging.${spec.table}
      WHERE (${spec.keys.join(', ')}) IN (${batch.map(() => `(${spec.keys.map(() => '?').join(', ')})`).join(', ')})${lock ? ' FOR UPDATE' : ''}`,
    batch.flatMap((row) => spec.keys.map((key) => row[key])));
    const byKey = new Map(found.map((row) => [rowKey(row, spec.keys), row]));
    if (found.length !== batch.length || byKey.size !== batch.length || batch.some((row) => {
      const actual = byKey.get(rowKey(row, spec.keys));
      return !actual || !isDeepStrictEqual(normalize(actual, spec.columns), row);
    })) fail('Canonical row keys, values or JSON mismatch');
  }
}

async function sourcePreflight(client, plan, packetBudget, lock) {
  const suffix = lock ? ' FOR UPDATE' : '';
  const source = await rows(client, `SELECT source_project, source_database, source_bucket
    FROM clrs_staging.legacy_source WHERE singleton = 1${suffix}`);
  if (source.length !== 1 || source[0].source_project !== plan.source.project
      || source[0].source_database !== plan.source.database || source[0].source_bucket !== plan.source.bucket) fail('Staged source mismatch');
  const totals = await rows(client, `SELECT
    (SELECT COUNT(*) FROM clrs_staging.legacy_auth_users) AS auth_users,
    (SELECT COUNT(*) FROM clrs_staging.legacy_documents) AS documents,
    (SELECT COUNT(*) FROM clrs_staging.legacy_storage_objects) AS storage_objects`);
  if (totals.length !== 1 || count(totals[0].auth_users) !== plan.authRecords.length
      || count(totals[0].documents) !== plan.sourceDocuments.length
      || count(totals[0].storage_objects) !== plan.storageRecords.length) fail('Staged complete raw source counts mismatch');
  for (const [table, field, index, records] of [
    ['legacy_auth_users', 'uid', 'uid_sha256', plan.authRecords],
    ['legacy_documents', 'firebase_path', 'firebase_path_sha256', plan.sourceDocuments],
  ]) {
    for (const batch of conversationBatches(records, packetBudget)) {
      const ids = batch.map((record) => field === 'uid' ? record.uid : record.firebasePath);
      const extra = field === 'firebase_path' ? ', parent_path, collection_path, document_id' : '';
      const found = await rows(client, `SELECT ${field}, encoded_payload, HEX(payload_sha256) AS payload_hash${extra}
        FROM clrs_staging.${table} WHERE ${index} IN (${batch.map(() => 'UNHEX(?)').join(', ')})${suffix}`, ids.map(hash));
      const byId = new Map(found.map((row) => [row[field], row]));
      if (found.length !== batch.length || byId.size !== batch.length || batch.some((record, i) => {
        const row = byId.get(ids[i]);
        if (!row || row.payload_hash?.toLowerCase() !== record.sha256
            || payloadHash(json(row.encoded_payload)) !== record.sha256
            || !isDeepStrictEqual(json(row.encoded_payload), record.encodedPayload)) return true;
        if (field === 'firebase_path') {
          const parts = ids[i].split('/');
          return row.document_id !== parts.at(-1) || row.collection_path !== parts.slice(0, -1).join('/')
            || row.parent_path !== (parts.length > 2 ? parts.slice(0, -2).join('/') : null);
        }
        return false;
      })) fail('Staged raw keys and typed payloads do not match completed source');
    }
  }
  for (const batch of conversationBatches(plan.storageRecords, packetBudget)) {
    const found = await rows(client, `SELECT source_bucket, source_path, source_metadata, source_size,
      HEX(source_sha256) AS source_hash, target_key, HEX(target_sha256) AS target_hash, copied_at
      FROM clrs_staging.legacy_storage_objects WHERE source_bucket = ? AND source_path_sha256
      IN (${batch.map(() => 'UNHEX(?)').join(', ')})${suffix}`, [plan.source.bucket, ...batch.map((record) => hash(record.name))]);
    const byName = new Map(found.map((row) => [row.source_path, row]));
    if (found.length !== batch.length || byName.size !== batch.length || batch.some((record) => {
      const row = byName.get(record.name);
      return !row || row.source_bucket !== record.bucket || count(row.source_size) !== record.size
        || !isDeepStrictEqual(json(row.source_metadata), record.metadata)
        || row.source_hash?.toLowerCase() !== record.sha256 || row.target_hash?.toLowerCase() !== record.sha256
        || row.target_key !== record.targetKey || !row.copied_at;
    })) fail('Staged Storage metadata/hash/copy binding mismatch');
  }
  // Check all dependency rows, not just referenced UIDs, so missing/extra
  // accounts and identity/profile reassignment cannot silently pass a subset.
  await verifyCanonical(client, contract('accounts', null, ['uid'], accountColumns), plan.dependencies.accounts, packetBudget, lock);
  await verifyCanonical(client, contract('auth_identities', null, ['provider', 'provider_subject'], identityColumns), plan.dependencies.identities, packetBudget, lock);
  const profiles = plan.dependencies.profiles.map((row) => ({ ...row,
    ...Object.fromEntries(profileUnused.map((key) => [key, null])), test_result: {} }));
  await verifyCanonical(client, contract('profiles', null, ['uid'], [...profileColumns, ...profileUnused, 'test_result']), profiles, packetBudget, lock);
}

async function tableCounts(client) {
  const result = {};
  for (const spec of CONVERSATION_TABLES) {
    const found = await rows(client, `SELECT COUNT(*) AS total FROM clrs_staging.${spec.table}`);
    if (found.length !== 1) fail();
    result[spec.property] = count(found[0].total);
  }
  return result;
}
function rowDigest(plan) {
  return payloadHash(CONVERSATION_TABLES.map((spec) => ({ table: spec.table, rows: plan[spec.property]
    .slice().sort((a, b) => Buffer.compare(Buffer.from(rowKey(a, spec.keys)), Buffer.from(rowKey(b, spec.keys)))) })));
}
function receiptBinding(plan) {
  return { targetDatabase: DATABASE,
    source: { project: plan.source.project, database: plan.source.database, bucket: plan.source.bucket },
    archiveSha256: plan.archiveSha256, projectionSha256: plan.projectionSha256,
    dependencySha256: plan.dependencySha256, rawOnlyAcknowledgement: plan.rawOnlyAcknowledgement,
    counts: plan.counts.normalized, targetRowsSha256: rowDigest(plan), emptyTarget: true };
}
export function checkConversationReceipt(plan, receipt) {
  assertPreparedConversationPlan(plan);
  const binding = receiptBinding(plan);
  if (receipt?.kind !== 'clrs-conversation-projection-receipt' || receipt.version !== 1 || receipt.state !== 'prepared'
      || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(receipt.operationId ?? '')
      || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(receipt.preparedAt ?? '')
      || !Object.entries(binding).every(([key, value]) => isDeepStrictEqual(receipt[key], value))) fail('Encrypted receipt binding mismatch');
}
async function begin(client, readOnly) {
  await client.query(`SET TRANSACTION ISOLATION LEVEL ${readOnly ? 'REPEATABLE READ' : 'SERIALIZABLE'}`);
  await client.query(`START TRANSACTION${readOnly ? ' READ ONLY' : ''}`);
}

export async function stageConversationProjection(client, plan, values, persistReceipt) {
  assertConversationConfirmations(plan, values);
  if (typeof persistReceipt !== 'function') fail('Durable encrypted receipt required before COMMIT');
  const packetBudget = await preflight(client);
  // Validate every request/result and every target row before the first INSERT.
  for (const records of [plan.authRecords, plan.sourceDocuments, plan.storageRecords,
    plan.dependencies.accounts, plan.dependencies.identities, plan.dependencies.profiles,
    ...CONVERSATION_TABLES.map((spec) => plan[spec.property])]) {
    for (const ignored of conversationBatches(records, packetBudget)) void ignored;
  }
  let opened = false; let commitSent = false;
  try {
    await begin(client, false); opened = true;
    await sourcePreflight(client, plan, packetBudget, true);
    for (const spec of CONVERSATION_TABLES) {
      const found = await rows(client, `SELECT ${spec.keys.join(', ')} FROM clrs_staging.${spec.table} LIMIT 1 FOR UPDATE`);
      if (found.length) fail('All seven canonical tables must be empty; verify an existing receipt before retry');
    }
    const before = await tableCounts(client);
    if (Object.values(before).some((value) => value !== 0)) fail('Canonical target changed before staging');
    for (const spec of CONVERSATION_TABLES) {
      for (const batch of conversationBatches(plan[spec.property], packetBudget)) {
        const sql = `INSERT INTO clrs_staging.${spec.table} (${spec.columns.join(', ')}) VALUES `
          + batch.map(() => `(${spec.columns.map(() => '?').join(', ')})`).join(', ');
        const params = batch.flatMap((row) => spec.columns.map((name) => jsonFields.has(name) ? JSON.stringify(row[name]) : row[name]));
        const [result] = await client.execute(sql, params);
        if (count(result.affectedRows) !== batch.length) fail('Conversation INSERT count mismatch');
      }
    }
    for (const spec of CONVERSATION_TABLES) await verifyCanonical(client, spec, plan[spec.property], packetBudget, true);
    const receipt = { kind: 'clrs-conversation-projection-receipt', version: 1, state: 'prepared',
      operationId: randomUUID(), preparedAt: new Date().toISOString(), ...receiptBinding(plan) };
    checkConversationReceipt(plan, receipt);
    await persistReceipt(receipt);
    commitSent = true;
    await client.query('COMMIT'); opened = false;
    return { mode: 'stage', counts: plan.counts.normalized, archiveSha256: plan.archiveSha256,
      projectionSha256: plan.projectionSha256, databaseCommitted: true, compatibilityApiReady: false };
  } catch (error) {
    if (opened) await client.query('ROLLBACK').catch(() => {});
    if (commitSent) {
      poisoned.add(client);
      const unknown = new Error('COMMIT outcome unknown; reconcile durable receipt using a fresh connection before any retry');
      unknown.code = 'CONVERSATION_COMMIT_OUTCOME_UNKNOWN'; throw unknown;
    }
    throw error;
  }
}

export async function verifyConversationProjection(client, plan, values, receipt) {
  assertConversationConfirmations(plan, values); checkConversationReceipt(plan, receipt);
  const packetBudget = await preflight(client);
  let opened = false;
  try {
    await begin(client, true); opened = true;
    await sourcePreflight(client, plan, packetBudget, false);
    const actual = await tableCounts(client);
    const allEmpty = Object.values(actual).every((value) => value === 0);
    const expectedEmpty = Object.values(plan.counts.normalized).every((value) => value === 0);
    let outcome;
    if (allEmpty && !expectedEmpty) outcome = 'not_committed_verified';
    else {
      for (const spec of CONVERSATION_TABLES) await verifyCanonical(client, spec, plan[spec.property], packetBudget);
      outcome = expectedEmpty ? 'empty_no_row_effect_verified' : 'present_verified';
    }
    await client.query('COMMIT'); opened = false;
    return { mode: 'verify', outcome, counts: actual, archiveSha256: plan.archiveSha256,
      projectionSha256: plan.projectionSha256, databaseWrites: 0, compatibilityApiReady: false };
  } catch (error) { if (opened) await client.query('ROLLBACK').catch(() => {}); throw error; }
}
