// Additive repair for the original profile-details omission. This module has
// no CLI, credentials, DDL, endpoints or automatic retries. Callers must review
// a fresh aggregate plan and explicitly confirm it before calling stage.
import { createHash, randomBytes } from 'node:crypto';
import { open, realpath, stat } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { EncryptedArchiveWriter, readEncryptedArchive } from './encrypted-archive.mjs';
import { payloadHash } from './import-core.mjs';
import { mysqlTimestamp } from './project-profiles-core.mjs';
import { PROFILE_DETAILS_COLUMNS, ProfileDetailsProjectionError, projectProfileDetails } from './project-profile-details.mjs';

const DATABASE = 'clrs_staging';
export const PROFILE_DETAILS_BACKFILL_BATCH = 100;
export const PROFILE_DETAILS_BACKFILL_ROW_BYTES = 65536;
export const PROFILE_DETAILS_BACKFILL_COLUMNS = Object.freeze(PROFILE_DETAILS_COLUMNS.slice(0, 11));
const FLAGS = ['profile_details_saved', 'registration_complete'];
const CORE = ['full_name', 'country', 'city', 'primary_group'];
const UNUSED = ['invisible_until', 'last_online_at'];
const SNAPSHOT = ['uid', ...CORE, ...PROFILE_DETAILS_BACKFILL_COLUMNS, ...FLAGS,
  ...UNUSED, 'test_result', 'updated_at'];
const trustedPlans = new WeakSet();
const attemptedPlans = new WeakSet();
const trustedReceipts = new WeakSet();
const attemptedRollbacks = new WeakSet();
const hash = (text) => createHash('sha256').update(text, 'utf8').digest('hex');
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const json = (value) => typeof value === 'string' || Buffer.isBuffer(value) ? JSON.parse(value.toString()) : value;
const snapshot = (row) => Object.fromEntries(SNAPSHOT.map((key) => [key, key === 'test_result' ? json(row[key]) : row[key]]));
const stamp = (value) => typeof value === 'string' && /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}$/.test(value);
const bounded = (value) => Buffer.byteLength(JSON.stringify(value), 'utf8') <= PROFILE_DETAILS_BACKFILL_ROW_BYTES;
const validUid = (uid) => typeof uid === 'string' && uid.length > 0 && [...uid].length <= 191
  && !uid.includes('/') && !/[\uD800-\uDFFF]/u.test([...uid].filter((c) => c.length === 1).join(''));

function freeze(value) {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}

function sourceConfirmation(source, archiveSha256) {
  if (!object(source) || Object.keys(source).length !== 3
      || !['project', 'database', 'bucket'].every((key) => typeof source[key] === 'string'
        && source[key].length > 0 && [...source[key]].length <= 191)
      || !/^[a-f0-9]{64}$/.test(archiveSha256 ?? '')) throw new Error('Backfill source confirmation required');
}

function originalString(fields, key, maximum = 191) {
  if (!Object.hasOwn(fields, key)) return null;
  const typed = fields[key];
  if (!object(typed) || Object.keys(typed).length !== 1) throw new Error('source_core_unsupported');
  if (Object.hasOwn(typed, 'nullValue')) return null;
  const value = typed.stringValue;
  if (!Object.hasOwn(typed, 'stringValue') || typeof value !== 'string'
      || [...value].length > maximum || Buffer.byteLength(value, 'utf8') > maximum * 4) {
    throw new Error('source_core_unsupported');
  }
  return value;
}

function assess(profile, source) {
  if (!validUid(profile?.uid)) return { reason: 'invalid_profile_identity' };
  if (!source) return { reason: 'source_missing' };
  const path = `users/${profile.uid}`;
  if (source.firebase_path !== path || source.collection_path !== 'users'
      || source.document_id !== profile.uid || source.firebase_path_hash?.toLowerCase() !== hash(path)) {
    return { reason: 'source_identity_mismatch' };
  }
  let raw, original;
  try { raw = json(profile.legacy_raw); original = json(source.encoded_payload); }
  catch { return { reason: 'source_invalid_json' }; }
  if (!object(raw) || !object(original) || !object(original.fields)) return { reason: 'source_row_bound_or_shape' };
  if (!bounded(raw) || !bounded(original) || !bounded(snapshot(profile))) return { reason: 'row_byte_bound' };
  const sourceSha256 = source.payload_hash?.toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(sourceSha256 ?? '') || payloadHash(original) !== sourceSha256
      || payloadHash(raw) !== sourceSha256 || !isDeepStrictEqual(raw, original)) {
    return { reason: 'source_payload_mismatch' };
  }
  let details;
  try { details = projectProfileDetails(original.fields); }
  catch (error) {
    if (error instanceof ProfileDetailsProjectionError) return { reason: `unsupported:${error.field}:${error.reason}` };
    throw new Error('Backfill projector contract failed');
  }
  let baseline;
  try {
    const savedUid = originalString(original.fields, 'uid');
    if (savedUid !== null && savedUid !== profile.uid) return { reason: 'source_identity_mismatch' };
    const fullName = originalString(original.fields, 'fullName', 65535);
    if (fullName !== null && Buffer.byteLength(fullName, 'utf8') > 65535) return { reason: 'source_core_unsupported' };
    baseline = { full_name: fullName, country: originalString(original.fields, 'country'),
      city: originalString(original.fields, 'city'), primary_group: originalString(original.fields, 'группа'),
      profile_details_saved: details.profile_details_saved, registration_complete: details.registration_complete,
      updated_at: mysqlTimestamp(original.updateTime) };
  } catch { return { reason: 'source_core_unsupported' }; }
  if (!stamp(baseline.updated_at)) return { reason: 'source_timestamp_unsupported' };
  if (PROFILE_DETAILS_BACKFILL_COLUMNS.some((key) => profile[key] !== null)) return { reason: 'target_already_populated' };
  if ([...CORE, ...FLAGS, 'updated_at'].some((key) => profile[key] !== baseline[key])
      || UNUSED.some((key) => profile[key] !== null) || !isDeepStrictEqual(json(profile.test_result), {})) {
    return { reason: 'later_profile_modification' };
  }
  const patch = Object.fromEntries(PROFILE_DETAILS_BACKFILL_COLUMNS.map((key) => [key, details[key]]));
  if (Object.values(patch).every((value) => value === null)) return { reason: 'nothing_to_fill' };
  return { entry: { uid: profile.uid, firebasePath: path, sourceSha256,
    before: structuredClone(snapshot(profile)), patch, sourcePayload: structuredClone(original) } };
}

export function prepareProfileDetailsBackfillBatch({ profiles, sources, expectedSource, archiveSha256 }) {
  sourceConfirmation(expectedSource, archiveSha256);
  if (!Array.isArray(profiles) || !Array.isArray(sources) || profiles.length > PROFILE_DETAILS_BACKFILL_BATCH
      || sources.length > PROFILE_DETAILS_BACKFILL_BATCH || new Set(profiles.map((row) => row.uid)).size !== profiles.length) {
    throw new Error('Backfill requires a unique bounded batch');
  }
  const byPath = new Map(sources.map((row) => [row.firebase_path, row]));
  if (byPath.size !== sources.length) throw new Error('Backfill duplicate source path');
  const counts = { scanned: profiles.length, eligible: 0, skipped: 0, reasons: {} };
  const entries = [];
  for (const row of profiles) {
    const result = assess(row, byPath.get(`users/${row.uid}`));
    if (result.entry) { entries.push(result.entry); counts.eligible += 1; }
    else { counts.skipped += 1; counts.reasons[result.reason] = (counts.reasons[result.reason] ?? 0) + 1; }
  }
  entries.sort((a, b) => Buffer.compare(Buffer.from(a.uid), Buffer.from(b.uid)));
  const plan = { kind: 'clrs-profile-details-backfill-plan', version: 1,
    targetDatabase: DATABASE, archiveSha256, source: structuredClone(expectedSource), counts, entries };
  plan.planSha256 = payloadHash(plan);
  freeze(plan); trustedPlans.add(plan);
  return plan;
}

export function profileDetailsBackfillSummary(plan) {
  if (!trustedPlans.has(plan)) throw new Error('Backfill prepared plan required');
  return { counts: plan.counts, archiveSha256: plan.archiveSha256, planSha256: plan.planSha256,
    databaseWrites: 0, batchRowLimit: PROFILE_DETAILS_BACKFILL_BATCH, rowByteBound: PROFILE_DETAILS_BACKFILL_ROW_BYTES };
}

async function rows(client, sql, parameters = []) {
  const [result] = await client.execute(sql, parameters);
  if (!Array.isArray(result)) throw new Error('Backfill expected rows');
  return result;
}

async function preflight(client, source, lock) {
  const targets = await rows(client, `SELECT DATABASE() AS target_database, VERSION() AS mysql_version,
    @@SESSION.sql_mode AS sql_mode, @@character_set_connection AS character_set_connection`);
  const target = targets[0];
  if (targets.length !== 1 || target.target_database !== DATABASE || !/^8\.4\./.test(target.mysql_version ?? '')
      || target.character_set_connection !== 'utf8mb4'
      || !/(^|,)(STRICT_TRANS_TABLES|STRICT_ALL_TABLES)(,|$)/.test(target.sql_mode ?? '')) {
    throw new Error('Backfill requires strict MySQL 8.4 clrs_staging');
  }
  const stored = await rows(client, `SELECT source_project, source_database, source_bucket
    FROM clrs_staging.legacy_source WHERE singleton = 1${lock ? ' FOR UPDATE' : ''}`);
  if (stored.length !== 1 || stored[0].source_project !== source.project
      || stored[0].source_database !== source.database || stored[0].source_bucket !== source.bucket) {
    throw new Error('Backfill source confirmation mismatch');
  }
}

// Bound the entire returned profile JSON, including current LONGTEXT/test
// values. Truncating just legacy_raw could still transfer a later huge edit.
const profileJson = `JSON_OBJECT(${[...SNAPSHOT, 'legacy_raw'].flatMap((key) => [`'${key}'`,
  key === 'updated_at' || UNUSED.includes(key)
    ? `DATE_FORMAT(${key}, '%Y-%m-%d %H:%i:%s.%f')` : key]).join(', ')})`;
const profileSelection = `uid, CASE WHEN OCTET_LENGTH(CAST(${profileJson} AS CHAR CHARACTER SET utf8mb4))
  <= ${PROFILE_DETAILS_BACKFILL_ROW_BYTES} THEN ${profileJson} ELSE NULL END AS profile_row`;

function decodeProfiles(result) {
  return result.map((row) => {
    if (row.profile_row === null) return { uid: row.uid, legacy_raw: null };
    const profile = json(row.profile_row);
    if (!object(profile) || row.uid !== profile.uid || !bounded(profile)) throw new Error('Backfill profile row transport bound failed');
    return profile;
  });
}

async function readProfiles(client, uids, lock) {
  if (!uids.length) return [];
  const result = decodeProfiles(await rows(client, `SELECT ${profileSelection} FROM clrs_staging.profiles
    WHERE uid IN (${uids.map(() => '?').join(', ')}) ORDER BY CAST(uid AS BINARY)${lock ? ' FOR UPDATE' : ''}`, uids));
  if (result.length !== uids.length || new Set(result.map((row) => row.uid)).size !== uids.length
      || result.some((row) => !uids.includes(row.uid))) throw new Error('Backfill profile set changed');
  return result;
}

async function readSources(client, uids, lock) {
  if (!uids.length) return [];
  return rows(client, `SELECT firebase_path, HEX(firebase_path_sha256) AS firebase_path_hash,
    collection_path, document_id, HEX(payload_sha256) AS payload_hash,
    CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= ${PROFILE_DETAILS_BACKFILL_ROW_BYTES}
      THEN encoded_payload ELSE NULL END AS encoded_payload
    FROM clrs_staging.legacy_documents
    WHERE firebase_path_sha256 IN (${uids.map(() => 'UNHEX(?)').join(', ')})
    ORDER BY CAST(firebase_path AS BINARY)${lock ? ' FOR UPDATE' : ''}`, uids.map((uid) => hash(`users/${uid}`)));
}

export async function inspectProfileDetailsBackfillBatch(client, { expectedSource, archiveSha256, offset = 0 }) {
  sourceConfirmation(expectedSource, archiveSha256);
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error('Backfill offset must be bounded');
  let started = false;
  try {
    await client.query("SET SESSION time_zone = '+00:00'");
    await client.query('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ');
    await client.query('START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY'); started = true;
    await preflight(client, expectedSource, false);
    const profiles = decodeProfiles(await rows(client, `SELECT ${profileSelection} FROM clrs_staging.profiles
      ORDER BY CAST(uid AS BINARY) LIMIT 100 OFFSET ?`, [offset]));
    const sources = await readSources(client, profiles.map((row) => row.uid), false);
    const plan = prepareProfileDetailsBackfillBatch({ profiles, sources, expectedSource, archiveSha256 });
    await client.query('ROLLBACK'); started = false;
    return plan;
  } catch {
    if (started) await client.query('ROLLBACK').catch(() => {});
    throw new Error('Backfill inspection failed; no values are disclosed');
  }
}

function confirmations(plan, confirmed) {
  if (!trustedPlans.has(plan) || confirmed?.targetDatabase !== DATABASE
      || confirmed.archiveSha256 !== plan.archiveSha256 || confirmed.planSha256 !== plan.planSha256
      || confirmed.eligible !== plan.counts.eligible || plan.counts.eligible < 1) {
    throw new Error('Backfill nonempty reviewed batch confirmation required');
  }
}

async function privateReceiptPath(path, key) {
  if (!isAbsolute(path ?? '') || path.includes('.partial-') || !Buffer.isBuffer(key) || key.length !== 32) {
    throw new Error('Backfill private encrypted receipt required');
  }
  const folder = await realpath(dirname(path));
  const repository = await realpath(dirname(dirname(dirname(fileURLToPath(import.meta.url)))));
  const portion = relative(repository, folder);
  const info = await stat(folder);
  if (!(portion === '..' || portion.startsWith(`..${sep}`) || isAbsolute(portion))
      || !info.isDirectory() || (info.mode & 0o077) !== 0) throw new Error('Backfill receipt directory must be private and outside repository');
  const target = resolve(folder, path.slice(path.lastIndexOf(sep) + 1));
  try { await stat(target); } catch (error) { if (error.code === 'ENOENT') return target; throw error; }
  throw new Error('Backfill receipt exists; reconcile the prepared outcome before retry');
}

async function persistReceipt(path, key, receipt) {
  const writer = await EncryptedArchiveWriter.create(path, key);
  try {
    const { entries, ...header } = receipt;
    await writer.writeJson(header);
    for (const entry of entries) await writer.writeJson({ kind: 'clrs-profile-details-backfill-row', ...entry });
    await writer.finish({ backfillRows: entries.length });
    const directory = await open(dirname(path), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } catch { await writer.abort().catch(() => {}); throw new Error('Backfill durable receipt publication failed'); }
}

export class ProfileDetailsBackfillCommitUnknownError extends Error {
  constructor(operation = 'fill') { super('Backfill COMMIT outcome unknown; reconcile the prepared encrypted receipt on a fresh connection before retry');
    this.name = 'ProfileDetailsBackfillCommitUnknownError'; this.commitOutcomeUnknown = true; this.operation = operation; }
}

export async function stageProfileDetailsBackfillBatch(client, plan, confirmed, { receiptPath, key } = {}) {
  confirmations(plan, confirmed);
  if (attemptedPlans.has(plan)) throw new Error('Backfill batch was already attempted; inspect and reconcile before retry');
  const path = await privateReceiptPath(receiptPath, key);
  attemptedPlans.add(plan);
  let started = false, commitAttempted = false;
  try {
    await client.query("SET SESSION time_zone = '+00:00'");
    await client.query('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
    await client.query('START TRANSACTION'); started = true;
    await preflight(client, plan.source, true);
    const uids = plan.entries.map((entry) => entry.uid);
    const sources = await readSources(client, uids, true);
    const current = await readProfiles(client, uids, true);
    const fresh = prepareProfileDetailsBackfillBatch({ profiles: current, sources,
      expectedSource: plan.source, archiveSha256: plan.archiveSha256 });
    if (fresh.counts.eligible !== plan.counts.eligible || !isDeepStrictEqual(fresh.entries, plan.entries)) {
      throw new Error('Backfill original source or profile changed after review');
    }
    for (const entry of plan.entries) {
      const [result] = await client.execute(`UPDATE clrs_staging.profiles SET
        ${PROFILE_DETAILS_BACKFILL_COLUMNS.map((column) => `${column} = ?`).join(', ')},
        updated_at = GREATEST(UTC_TIMESTAMP(6), updated_at + INTERVAL 1 MICROSECOND)
        WHERE uid = ? AND CAST(uid AS BINARY) = CAST(? AS BINARY)
          AND updated_at = CAST(? AS DATETIME(6))
          AND ${PROFILE_DETAILS_BACKFILL_COLUMNS.map((column) => `${column} IS NULL`).join(' AND ')}`,
      [...PROFILE_DETAILS_BACKFILL_COLUMNS.map((column) => entry.patch[column]), entry.uid, entry.uid, entry.before.updated_at]);
      if (result.affectedRows !== 1) throw new Error('Backfill column CAS failed');
    }
    const afterByUid = new Map((await readProfiles(client, uids, true)).map((row) => [row.uid, row]));
    const afterEntries = [];
    for (const entry of plan.entries) {
      const after = afterByUid.get(entry.uid);
      const expected = { ...entry.before, ...entry.patch, updated_at: after.updated_at };
      if (!stamp(after.updated_at) || after.updated_at <= entry.before.updated_at
          || !isDeepStrictEqual(snapshot(after), expected)
          || !isDeepStrictEqual(json(after.legacy_raw), entry.sourcePayload)
          || payloadHash(json(after.legacy_raw)) !== entry.sourceSha256) throw new Error('Backfill verification failed');
      afterEntries.push({ uid: entry.uid, firebasePath: entry.firebasePath, sourceSha256: entry.sourceSha256,
        before: entry.before, after: expected });
    }
    const receipt = { kind: 'clrs-profile-details-backfill-receipt', version: 1, state: 'prepared',
      operation: 'fill',
      operationId: randomBytes(16).toString('hex'), targetDatabase: DATABASE,
      archiveSha256: plan.archiveSha256, planSha256: plan.planSha256, source: plan.source,
      counts: plan.counts, entries: afterEntries };
    await persistReceipt(path, key, receipt);
    commitAttempted = true;
    await client.query('COMMIT'); started = false;
    return { mode: 'stage', counts: plan.counts, databaseCommitted: true, columnsChanged: PROFILE_DETAILS_BACKFILL_COLUMNS,
      encryptedReceiptPrepared: true, planSha256: plan.planSha256 };
  } catch {
    if (started) await client.query('ROLLBACK').catch(() => {});
    if (commitAttempted) throw new ProfileDetailsBackfillCommitUnknownError();
    throw new Error('Backfill stage failed; no values are disclosed; transaction was not committed');
  }
}

export async function readProfileDetailsBackfillReceipt(path, key) {
  let header, complete = false;
  const entries = [];
  const info = await stat(path);
  if (!info.isFile() || (info.mode & 0o077) !== 0) throw new Error('Backfill receipt must be private');
  for await (const frame of readEncryptedArchive(path, key)) {
    const record = frame.record;
    if (frame.type !== 'json' || !object(record) || complete) throw new Error('Backfill receipt ordering invalid');
    if (!header && record.kind === 'clrs-profile-details-backfill-receipt') header = record;
    else if (header && record.kind === 'clrs-profile-details-backfill-row' && entries.length < PROFILE_DETAILS_BACKFILL_BATCH) {
      const { kind, ...entry } = record; entries.push(entry);
    } else if (header && record.kind === 'end' && record.summary?.backfillRows === entries.length) complete = true;
    else throw new Error('Backfill receipt ordering invalid');
  }
  if (!complete || !header || header.version !== 1 || header.state !== 'prepared'
      || !['fill', 'restore'].includes(header.operation)
      || header.targetDatabase !== DATABASE || !/^[a-f0-9]{64}$/.test(header.planSha256 ?? '')
      || !/^[a-f0-9]{32}$/.test(header.operationId ?? '') || header.counts?.eligible !== entries.length
      || entries.length < 1 || new Set(entries.map((entry) => entry.uid)).size !== entries.length
      || entries.some((entry) => !validUid(entry.uid) || entry.firebasePath !== `users/${entry.uid}`
        || !/^[a-f0-9]{64}$/.test(entry.sourceSha256 ?? '')
        || ![entry.before, entry.after].every((row) => object(row)
          && isDeepStrictEqual(Object.keys(row).sort(), [...SNAPSHOT].sort())
          && row.uid === entry.uid && stamp(row.updated_at) && bounded(row))
        || entry.after.updated_at <= entry.before.updated_at
        || [...CORE, ...FLAGS, ...UNUSED, 'test_result'].some((column) =>
          !isDeepStrictEqual(entry.before[column], entry.after[column]))
        || PROFILE_DETAILS_BACKFILL_COLUMNS.some((column) =>
          (header.operation === 'fill' ? entry.before : entry.after)[column] !== null))) {
    throw new Error('Backfill receipt incomplete');
  }
  sourceConfirmation(header.source, header.archiveSha256);
  const receipt = freeze({ ...header, entries });
  trustedReceipts.add(receipt);
  return receipt;
}

export async function verifyProfileDetailsBackfillReceipt(client, receipt) {
  if (!trustedReceipts.has(receipt) || receipt?.kind !== 'clrs-profile-details-backfill-receipt' || receipt.targetDatabase !== DATABASE
      || receipt.state !== 'prepared' || !Array.isArray(receipt.entries)
      || receipt.entries.length > PROFILE_DETAILS_BACKFILL_BATCH) throw new Error('Backfill prepared receipt required');
  let started = false;
  try {
    await client.query("SET SESSION time_zone = '+00:00'");
    await client.query('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ');
    await client.query('START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY'); started = true;
    await preflight(client, receipt.source, false);
    const uids = receipt.entries.map((entry) => entry.uid);
    const sources = await readSources(client, uids, false);
    const profiles = await readProfiles(client, uids, false);
    const byPath = new Map(sources.map((source) => [source.firebase_path, source]));
    const byUid = new Map(profiles.map((profile) => [profile.uid, profile]));
    let before = 0, after = 0;
    for (const entry of receipt.entries) {
      const profile = byUid.get(entry.uid), source = byPath.get(entry.firebasePath);
      const original = json(source?.encoded_payload), raw = json(profile?.legacy_raw);
      if (!source || source.firebase_path !== `users/${entry.uid}` || source.collection_path !== 'users'
          || source.document_id !== entry.uid || source.firebase_path_hash?.toLowerCase() !== hash(entry.firebasePath)
          || source.payload_hash?.toLowerCase() !== entry.sourceSha256 || payloadHash(original) !== entry.sourceSha256
          || payloadHash(raw) !== entry.sourceSha256 || !isDeepStrictEqual(raw, original)) {
        throw new Error('Backfill receipt source changed');
      }
      if (isDeepStrictEqual(snapshot(profile), entry.before)) before += 1;
      else if (isDeepStrictEqual(snapshot(profile), entry.after)) after += 1;
      else throw new Error('Backfill receipt later profile modification');
    }
    if (before && after) throw new Error('Backfill receipt mixed transaction outcome');
    await client.query('ROLLBACK'); started = false;
    return { mode: 'verify', outcome: after ? 'committed_verified' : 'not_committed_verified',
      profiles: receipt.entries.length, databaseWrites: 0, planSha256: receipt.planSha256 };
  } catch {
    if (started) await client.query('ROLLBACK').catch(() => {});
    throw new Error('Backfill outcome cannot be reconciled; manual review required');
  }
}

export async function rollbackProfileDetailsBackfillBatch(client, receipt, confirmed, { receiptPath, key } = {}) {
  if (!trustedReceipts.has(receipt) || receipt.operation !== 'fill'
      || confirmed?.targetDatabase !== DATABASE || confirmed.archiveSha256 !== receipt.archiveSha256
      || confirmed.planSha256 !== receipt.planSha256 || confirmed.receiptOperationId !== receipt.operationId
      || confirmed.eligible !== receipt.entries.length) throw new Error('Backfill reviewed encrypted rollback confirmation required');
  if (attemptedRollbacks.has(receipt)) throw new Error('Backfill rollback was already attempted; reconcile its prepared outcome before retry');
  const path = await privateReceiptPath(receiptPath, key);
  attemptedRollbacks.add(receipt);
  let started = false, commitAttempted = false;
  try {
    await client.query("SET SESSION time_zone = '+00:00'");
    await client.query('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
    await client.query('START TRANSACTION'); started = true;
    await preflight(client, receipt.source, true);
    const uids = receipt.entries.map((entry) => entry.uid);
    const sources = await readSources(client, uids, true);
    const profiles = await readProfiles(client, uids, true);
    const byPath = new Map(sources.map((source) => [source.firebase_path, source]));
    const byUid = new Map(profiles.map((profile) => [profile.uid, profile]));
    // Validate every row before the first UPDATE. A single later edit refuses
    // the whole batch, including unchanged rows earlier in receipt order.
    for (const entry of receipt.entries) {
      const source = byPath.get(entry.firebasePath), profile = byUid.get(entry.uid);
      const original = json(source?.encoded_payload), raw = json(profile?.legacy_raw);
      if (!source || source.firebase_path !== `users/${entry.uid}` || source.collection_path !== 'users'
          || source.document_id !== entry.uid || source.firebase_path_hash?.toLowerCase() !== hash(entry.firebasePath)
          || source.payload_hash?.toLowerCase() !== entry.sourceSha256 || payloadHash(original) !== entry.sourceSha256
          || payloadHash(raw) !== entry.sourceSha256 || !isDeepStrictEqual(raw, original)
          || !isDeepStrictEqual(snapshot(profile), entry.after)) throw new Error('Backfill rollback later modification or source mismatch');
    }
    for (const entry of receipt.entries) {
      const [result] = await client.execute(`UPDATE clrs_staging.profiles SET
        ${PROFILE_DETAILS_BACKFILL_COLUMNS.map((column) => `${column} = ?`).join(', ')},
        updated_at = GREATEST(UTC_TIMESTAMP(6), updated_at + INTERVAL 1 MICROSECOND)
        WHERE uid = ? AND CAST(uid AS BINARY) = CAST(? AS BINARY)
          AND updated_at = CAST(? AS DATETIME(6))
          AND ${PROFILE_DETAILS_BACKFILL_COLUMNS.map((column) => `${column} <=> ?`).join(' AND ')}`,
      [...PROFILE_DETAILS_BACKFILL_COLUMNS.map((column) => entry.before[column]), entry.uid, entry.uid, entry.after.updated_at,
        ...PROFILE_DETAILS_BACKFILL_COLUMNS.map((column) => entry.after[column])]);
      if (result.affectedRows !== 1) throw new Error('Backfill rollback column CAS failed');
    }
    const afterByUid = new Map((await readProfiles(client, uids, true)).map((row) => [row.uid, row]));
    const restored = [];
    for (const entry of receipt.entries) {
      const after = afterByUid.get(entry.uid);
      const expected = { ...entry.before, updated_at: after.updated_at };
      const original = json(byPath.get(entry.firebasePath).encoded_payload);
      if (!stamp(after.updated_at) || after.updated_at <= entry.after.updated_at
          || !isDeepStrictEqual(snapshot(after), expected)
          || !isDeepStrictEqual(json(after.legacy_raw), original)
          || payloadHash(json(after.legacy_raw)) !== entry.sourceSha256) throw new Error('Backfill rollback verification failed');
      restored.push({ uid: entry.uid, firebasePath: entry.firebasePath, sourceSha256: entry.sourceSha256,
        before: entry.after, after: expected });
    }
    const rollbackReceipt = { kind: 'clrs-profile-details-backfill-receipt', version: 1, state: 'prepared',
      operation: 'restore', operationId: randomBytes(16).toString('hex'), targetDatabase: DATABASE,
      archiveSha256: receipt.archiveSha256, planSha256: receipt.planSha256, source: receipt.source,
      counts: receipt.counts, originalOperationId: receipt.operationId, entries: restored };
    await persistReceipt(path, key, rollbackReceipt);
    commitAttempted = true;
    await client.query('COMMIT'); started = false;
    return { mode: 'rollback', profiles: restored.length, databaseCommitted: true,
      columnsChanged: PROFILE_DETAILS_BACKFILL_COLUMNS, encryptedReceiptPrepared: true,
      freshCasTimestamps: true, planSha256: receipt.planSha256 };
  } catch {
    if (started) await client.query('ROLLBACK').catch(() => {});
    if (commitAttempted) throw new ProfileDetailsBackfillCommitUnknownError('restore');
    throw new Error('Backfill rollback failed; no values are disclosed; transaction was not committed');
  }
}
