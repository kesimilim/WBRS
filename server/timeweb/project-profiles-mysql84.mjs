import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { payloadHash } from './import-core.mjs';
import { assertPreparedProfilePlan, assertProjectionConfirmations } from './project-profiles-core.mjs';
import { PROFILE_DETAILS_COLUMNS } from './project-profile-details.mjs';

const DATABASE = 'clrs_staging';
const BATCH = 100;
const hash = (value) => createHash('sha256').update(value, 'utf8').digest('hex');
const json = (value) => typeof value === 'string' || Buffer.isBuffer(value)
  ? JSON.parse(value.toString()) : value;
const accountColumns = ['uid', 'email_normalized', 'email_verified', 'disabled',
  'lifecycle', 'token_version', 'firebase_created_at', 'firebase_last_login_at', 'legacy_claims'];
const profileColumns = ['uid', 'full_name', 'country', 'city', 'primary_group',
  ...PROFILE_DETAILS_COLUMNS, 'updated_at', 'legacy_raw'];
const identityColumns = ['uid', 'provider', 'provider_subject', 'provider_email', 'legacy_raw'];
const profileUnusedColumns = ['invisible_until', 'last_online_at'];
const timestampColumns = new Set(['firebase_created_at', 'firebase_last_login_at',
  'updated_at', 'created_at']);
const jsonColumns = new Set(['legacy_claims', 'legacy_raw']);
const numericColumns = new Set(['email_verified', 'disabled', 'token_version',
  'profile_details_saved', 'registration_complete', 'age', 'height_cm', 'has_children']);
const batches = function* (records) {
  for (let index = 0; index < records.length; index += BATCH) yield records.slice(index, index + BATCH);
};

async function rows(client, sql, params = []) {
  const [result] = await client.execute(sql, params);
  if (!Array.isArray(result)) throw new Error('Expected MySQL projection rows');
  return result;
}

function count(value) {
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result < 0) throw new Error('Invalid projection count');
  return result;
}

function selectColumns(columns) {
  return columns.map((name) => timestampColumns.has(name)
    ? `DATE_FORMAT(${name}, '%Y-%m-%d %H:%i:%s.%f') AS ${name}` : name).join(', ');
}

function normalize(row, columns) {
  return Object.fromEntries(columns.map((name) => [name,
    jsonColumns.has(name) ? json(row[name])
      : numericColumns.has(name) && row[name] !== null ? count(row[name]) : row[name]]));
}

function sameRow(row, expected, columns) {
  return isDeepStrictEqual(normalize(row, columns), expected);
}

async function targetPreflight(client) {
  const result = await rows(client, `SELECT DATABASE() AS target_database,
    VERSION() AS mysql_version, @@SESSION.sql_mode AS sql_mode,
    @@character_set_connection AS character_set_connection,
    @@max_allowed_packet AS max_allowed_packet`);
  const target = result[0];
  if (result.length !== 1 || target.target_database !== DATABASE
      || !/^8\.4\./.test(target.mysql_version ?? '')
      || target.character_set_connection !== 'utf8mb4'
      || !/(^|,)(STRICT_TRANS_TABLES|STRICT_ALL_TABLES)(,|$)/.test(target.sql_mode ?? '')) {
    throw new Error('Projection target must be strict MySQL 8.4 clrs_staging');
  }
  const migrations = await rows(client, 'SELECT version FROM clrs_staging.schema_migrations ORDER BY version');
  if (migrations.length !== 1 || Number(migrations[0].version) !== 1) {
    throw new Error('Projection requires existing schema version 1');
  }
  const packetBytes = count(target.max_allowed_packet);
  if (packetBytes < 1024) throw new Error('Target packet limit is unavailable or too small');
  // Leave half the negotiated limit unused for prepared-protocol overhead,
  // result encodings and driver/server differences. It is never increased.
  return { packetBudget: Math.floor(packetBytes / 2) };
}

async function sourcePreflight(client, plan, forUpdate) {
  const lock = forUpdate ? ' FOR UPDATE' : '';
  const source = await rows(client, `SELECT source_project, source_database, source_bucket
    FROM clrs_staging.legacy_source WHERE singleton = 1${lock}`);
  if (source.length !== 1 || source[0].source_project !== plan.source.project
      || source[0].source_database !== plan.source.database
      || source[0].source_bucket !== plan.source.bucket) {
    throw new Error('Projection legacy source mismatch');
  }
  const totals = await rows(client, `SELECT
    (SELECT COUNT(*) FROM clrs_staging.legacy_auth_users) AS auth_users,
    (SELECT COUNT(*) FROM clrs_staging.legacy_documents
      WHERE collection_path_sha256 = UNHEX(?) AND collection_path = ?) AS root_profiles`,
  [hash('users'), 'users']);
  if (totals.length !== 1 || count(totals[0].auth_users) !== plan.counts.sourceAuthUsers
      || count(totals[0].root_profiles) !== plan.counts.sourceRootProfiles) {
    throw new Error('Projection legacy source count mismatch');
  }
  // Compare the original ID/path and canonical payload as well as its hash.
  // A matching generated hash alone never authorizes a profile association.
  for (const batch of batches(plan.authRecords)) {
    const stored = await rows(client, `SELECT uid, encoded_payload,
      HEX(payload_sha256) AS payload_hash FROM clrs_staging.legacy_auth_users
      WHERE uid_sha256 IN (${batch.map(() => 'UNHEX(?)').join(', ')})${lock}`,
    batch.map((record) => hash(record.uid)));
    const byUid = new Map(stored.map((row) => [row.uid, row]));
    if (stored.length !== batch.length || byUid.size !== batch.length
        || batch.some((record) => !sameRaw(byUid.get(record.uid), record))) {
      throw new Error('Projection Auth archive/legacy mismatch');
    }
  }
  for (const batch of batches(plan.rootDocuments)) {
    const stored = await rows(client, `SELECT firebase_path, encoded_payload,
      HEX(payload_sha256) AS payload_hash FROM clrs_staging.legacy_documents
      WHERE firebase_path_sha256 IN (${batch.map(() => 'UNHEX(?)').join(', ')})${lock}`,
    batch.map((record) => hash(record.firebasePath)));
    const byPath = new Map(stored.map((row) => [row.firebase_path, row]));
    if (stored.length !== batch.length || byPath.size !== batch.length
        || batch.some((record) => !sameRaw(byPath.get(record.firebasePath), record))) {
      throw new Error('Projection Firestore archive/legacy mismatch');
    }
  }
}

function sameRaw(row, record) {
  if (!row || row.payload_hash?.toLowerCase() !== record.sha256) return false;
  const payload = json(row.encoded_payload);
  return payloadHash(payload) === record.sha256 && isDeepStrictEqual(payload, record.encodedPayload);
}

async function tableCounts(client) {
  const result = await rows(client, `SELECT
    (SELECT COUNT(*) FROM clrs_staging.accounts) AS accounts,
    (SELECT COUNT(*) FROM clrs_staging.profiles) AS profiles,
    (SELECT COUNT(*) FROM clrs_staging.auth_identities) AS identities`);
  if (result.length !== 1) throw new Error('Invalid projection table counts');
  return { accounts: count(result[0].accounts), profiles: count(result[0].profiles),
    identities: count(result[0].identities) };
}

function parameterValue(record, name) {
  return jsonColumns.has(name) ? JSON.stringify(record[name]) : record[name];
}

export function* profileInsertBatches(columns, records, packetBudget) {
  if (!Number.isSafeInteger(packetBudget) || packetBudget < 512) {
    throw new Error('Invalid projection packet budget');
  }
  // Fixed allowance includes the longest constant INSERT prefix and value
  // placeholders; per-parameter allowance includes binary length encodings.
  const fixedBytes = 512;
  let batch = [];
  let bytes = fixedBytes;
  for (const record of records) {
    const recordBytes = columns.reduce((total, name) => {
      const value = parameterValue(record, name);
      return total + 16 + (value === null ? 0 : Buffer.byteLength(String(value), 'utf8'));
    }, 32);
    if (recordBytes + fixedBytes > packetBudget) {
      throw new Error('A projection row exceeds the guarded server packet budget');
    }
    if (batch.length && (batch.length === BATCH || bytes + recordBytes > packetBudget)) {
      yield batch;
      batch = [];
      bytes = fixedBytes;
    }
    batch.push(record);
    bytes += recordBytes;
  }
  if (batch.length) yield batch;
}

async function insertRows(client, table, columns, records, packetBudget) {
  for (const batch of profileInsertBatches(columns, records, packetBudget)) {
    // Identifiers come only from constants in this module. All source values,
    // even quotes/newlines/SQL-like text, are sent via mysql2 placeholders.
    const sql = `INSERT INTO clrs_staging.${table} (${columns.join(', ')}) VALUES `
      + batch.map(() => `(${columns.map(() => '?').join(', ')})`).join(', ');
    const params = batch.flatMap((record) => columns.map((name) => parameterValue(record, name)));
    const [result] = await client.execute(sql, params);
    if (result.affectedRows !== batch.length) throw new Error('Projection insert count mismatch');
  }
}

async function verifyRows(client, plan, { forUpdate = false, projectionTime } = {}) {
  const actual = await tableCounts(client);
  if (['accounts', 'profiles', 'identities'].some((name) => actual[name] !== plan.counts[name])) {
    throw new Error('Normalized projection count mismatch');
  }
  const lock = forUpdate ? ' FOR UPDATE' : '';
  const accountFields = projectionTime ? [...accountColumns, 'created_at', 'updated_at'] : accountColumns;
  for (const batch of batches(plan.accounts)) {
    const stored = await rows(client, `SELECT ${selectColumns(accountFields)} FROM clrs_staging.accounts
      WHERE uid IN (${batch.map(() => '?').join(', ')})${lock}`, batch.map((row) => row.uid));
    const byUid = new Map(stored.map((row) => [row.uid, row]));
    if (stored.length !== batch.length || byUid.size !== batch.length || batch.some((expected) => {
      const complete = projectionTime ? { ...expected, created_at: projectionTime, updated_at: projectionTime } : expected;
      return !byUid.has(expected.uid) || !sameRow(byUid.get(expected.uid), complete, accountFields);
    })) throw new Error('Normalized account mismatch');
  }
  for (const batch of batches(plan.profiles)) {
    const stored = await rows(client, `SELECT ${selectColumns(profileColumns)},
      ${profileUnusedColumns.join(', ')}, test_result FROM clrs_staging.profiles
      WHERE uid IN (${batch.map(() => '?').join(', ')})${lock}`, batch.map((row) => row.uid));
    const byUid = new Map(stored.map((row) => [row.uid, row]));
    if (stored.length !== batch.length || byUid.size !== batch.length || batch.some((expected) => {
      const row = byUid.get(expected.uid);
      return !row || !sameRow(row, expected, profileColumns)
        // This narrow projection deliberately has no mapping for these fields.
        // If a later service changed them, rollback must refuse to erase it.
        || profileUnusedColumns.some((name) => row[name] !== null)
        || !isDeepStrictEqual(json(row.test_result), {});
    })) throw new Error('Normalized profile mismatch or later modification');
  }
  for (const batch of batches(plan.identities)) {
    const stored = await rows(client, `SELECT ${identityColumns.join(', ')} FROM clrs_staging.auth_identities
      WHERE ${batch.map(() => '(provider = ? AND provider_subject = ?)').join(' OR ')}${lock}`,
    batch.flatMap((row) => [row.provider, row.provider_subject]));
    const key = (row) => JSON.stringify([row.provider, row.provider_subject]);
    const byKey = new Map(stored.map((row) => [key(row), row]));
    if (stored.length !== batch.length || byKey.size !== batch.length
        || batch.some((expected) => !byKey.has(key(expected))
          || !sameRow(byKey.get(key(expected)), expected, identityColumns))) {
      throw new Error('Normalized identity mismatch');
    }
  }
  return actual;
}

function rollbackReceipt(plan, projectionTime) {
  return { kind: 'clrs-profile-projection-receipt', version: 1,
    targetDatabase: DATABASE, archiveSha256: plan.archiveSha256,
    projectionSha256: plan.projectionSha256, projectionTime,
    counts: { accounts: plan.counts.accounts, profiles: plan.counts.profiles,
      identities: plan.counts.identities },
    // Published before COMMIT: after a connection loss this receipt describes
    // a prepared/possibly committed transaction, not proof that it committed.
    state: 'prepared' };
}

export function checkProjectionReceipt(plan, receipt) {
  assertPreparedProfilePlan(plan);
  if (!receipt || receipt.kind !== 'clrs-profile-projection-receipt' || receipt.version !== 1
      || receipt.targetDatabase !== DATABASE || receipt.archiveSha256 !== plan.archiveSha256
      || receipt.projectionSha256 !== plan.projectionSha256 || receipt.state !== 'prepared'
      || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}$/.test(receipt.projectionTime ?? '')
      || !isDeepStrictEqual(receipt.counts, { accounts: plan.counts.accounts,
        profiles: plan.counts.profiles, identities: plan.counts.identities })) {
    throw new Error('Rollback receipt does not match the authenticated projection');
  }
}

async function begin(client, readOnly) {
  await client.query("SET SESSION time_zone = '+00:00'");
  await client.query("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'");
  await client.query(`SET TRANSACTION ISOLATION LEVEL ${readOnly ? 'REPEATABLE READ' : 'SERIALIZABLE'}`);
  await client.query(`START TRANSACTION${readOnly ? ' READ ONLY' : ''}`);
}

async function withTransaction(client, readOnly, action) {
  let opened = false;
  try {
    await begin(client, readOnly);
    opened = true;
    const target = await targetPreflight(client);
    const result = await action(target);
    await client.query('COMMIT');
    opened = false;
    return result;
  } catch (error) {
    if (opened) await client.query('ROLLBACK').catch(() => {});
    throw error;
  }
}

export async function stageProfileProjection(client, plan, confirmations, persistReceipt) {
  assertProjectionConfirmations(plan, confirmations);
  if (typeof persistReceipt !== 'function') throw new Error('A durable encrypted rollback receipt is required');
  return withTransaction(client, false, async ({ packetBudget }) => {
    await sourcePreflight(client, plan, true);
    const current = await tableCounts(client);
    if (Object.values(current).some((value) => value !== 0)) {
      throw new Error('Projection stage requires empty normalized tables; verify an existing projection instead');
    }
    const now = await rows(client, "SELECT DATE_FORMAT(UTC_TIMESTAMP(6), '%Y-%m-%d %H:%i:%s.%f') AS projection_time");
    const projectionTime = now[0]?.projection_time;
    const receipt = rollbackReceipt(plan, projectionTime);
    checkProjectionReceipt(plan, receipt);
    const plannedInserts = [
      ['accounts', [...accountColumns, 'created_at', 'updated_at'],
        plan.accounts.map((row) => ({ ...row, created_at: projectionTime, updated_at: projectionTime }))],
      ['profiles', profileColumns, plan.profiles],
      ['auth_identities', identityColumns, plan.identities],
    ];
    // Validate every row before the first INSERT, including unprojected but
    // retained legacy_raw JSON. A count-only dry-run cannot prove this bound.
    for (const [, columns, records] of plannedInserts) {
      for (const ignored of profileInsertBatches(columns, records, packetBudget)) void ignored;
    }
    for (const [table, columns, records] of plannedInserts) {
      await insertRows(client, table, columns, records, packetBudget);
    }
    const counts = await verifyRows(client, plan, { forUpdate: true, projectionTime });
    // Failure to publish/sync the encrypted receipt aborts this transaction.
    await persistReceipt(receipt);
    return { mode: 'stage', counts, archiveSha256: plan.archiveSha256,
      projectionSha256: plan.projectionSha256, databaseCommitted: true };
  });
}

export async function verifyProfileProjection(client, plan, targetDatabase, receipt) {
  assertPreparedProfilePlan(plan);
  if (targetDatabase !== DATABASE) throw new Error('Explicit clrs_staging confirmation is required');
  if (receipt) checkProjectionReceipt(plan, receipt);
  return withTransaction(client, true, async () => {
    await sourcePreflight(client, plan, false);
    const counts = await verifyRows(client, plan, { projectionTime: receipt?.projectionTime });
    return { mode: 'verify', counts, archiveSha256: plan.archiveSha256,
      projectionSha256: plan.projectionSha256, databaseWrites: 0 };
  });
}

export async function rollbackProfileProjection(client, plan, confirmations, receipt) {
  assertProjectionConfirmations(plan, confirmations);
  checkProjectionReceipt(plan, receipt);
  if (confirmations.rollbackArchiveSha256 !== plan.archiveSha256) {
    throw new Error('Explicit rollback archive confirmation is required');
  }
  await assertRollbackDeleteGrants(client);
  return withTransaction(client, false, async () => {
    await sourcePreflight(client, plan, true);
    // Check every retained value, exact counts and insertion timestamps first.
    // Any added/modified row or downstream FK stops rollback atomically.
    await verifyRows(client, plan, { forUpdate: true, projectionTime: receipt.projectionTime });
    for (const [table, records, expected] of [
      ['auth_identities', plan.accounts, plan.counts.identities],
      ['profiles', plan.profiles, plan.counts.profiles],
      ['accounts', plan.accounts, plan.counts.accounts],
    ]) {
      let deleted = 0;
      for (const batch of batches(records)) {
        const [result] = await client.execute(`DELETE FROM clrs_staging.${table}
          WHERE uid IN (${batch.map(() => '?').join(', ')})`, batch.map((row) => row.uid));
        deleted += result.affectedRows;
      }
      if (deleted !== expected) throw new Error('Projection rollback delete count mismatch');
    }
    const remaining = await tableCounts(client);
    if (Object.values(remaining).some((value) => value !== 0)) throw new Error('Projection rollback retained unexpected rows');
    return { mode: 'rollback', counts: remaining, legacyArchivesRetained: true, databaseCommitted: true };
  });
}

export async function assertRollbackDeleteGrants(client) {
  const [grants] = await client.query('SHOW GRANTS');
  if (!Array.isArray(grants) || !grants.length) throw new Error('Rollback grants unavailable');
  const permittedTables = new Set();
  for (const row of grants) {
    const values = Object.values(row);
    const grant = values.length === 1 ? values[0] : null;
    const match = typeof grant === 'string' && /^GRANT ([A-Z ,]+) ON (\*\.\*|`clrs_staging`\.\*|`clrs_staging`\.`(accounts|profiles|auth_identities)`) TO (?:`[^`]+`|'[^']+')@(?:`[^`]+`|'[^']+')$/.exec(grant);
    if (!match) throw new Error('Rollback needs explicit direct staging grants');
    const privileges = match[1].split(',').map((value) => value.trim());
    if (match[2] === '*.*') {
      if (privileges.length !== 1 || privileges[0] !== 'USAGE') {
        throw new Error('Global rollback privileges are forbidden');
      }
    } else if (privileges.includes('DELETE')) {
      if (match[2] === '`clrs_staging`.*') {
        ['accounts', 'profiles', 'auth_identities'].forEach((table) => permittedTables.add(table));
      } else permittedTables.add(match[3]);
    }
  }
  if (permittedTables.size !== 3) {
    throw new Error('Committed rollback requires separate DELETE privileges on its three staging tables');
  }
}
