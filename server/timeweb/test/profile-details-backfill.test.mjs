import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { chmod, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { payloadHash } from '../import-core.mjs';
import { mysqlTimestamp } from '../project-profiles-core.mjs';
import { projectProfileDetails } from '../project-profile-details.mjs';
import { PROFILE_DETAILS_BACKFILL_COLUMNS, ProfileDetailsBackfillCommitUnknownError,
  inspectProfileDetailsBackfillBatch, prepareProfileDetailsBackfillBatch,
  profileDetailsBackfillSummary, readProfileDetailsBackfillReceipt,
  rollbackProfileDetailsBackfillBatch, stageProfileDetailsBackfillBatch,
  verifyProfileDetailsBackfillReceipt } from '../profile-details-backfill.mjs';

const source = { project: 'clrs-synthetic', database: '(default)', bucket: 'clrs-synthetic.appspot.com' };
const archiveSha256 = 'a'.repeat(64);
const hash = (text) => createHash('sha256').update(text).digest('hex');
const s = (stringValue) => ({ stringValue });
const privateText = "Synthetic private text: quote'; DROP TABLE profiles;\n  exact spaces  ";

function inputs(size = 1) {
  const profiles = [], sources = [];
  for (let index = 0; index < size; index += 1) {
    const uid = `SyntheticProfile-${index}-20261002`;
    const raw = { fields: { uid: { nullValue: null }, fullName: s('  Synthetic name  '),
      country: s('ru'), city: s('Synthetic city'), 'группа': s('бело-красная'),
      age: { integerValue: '028' }, rost: s('00180'), about: s(privateText), hobbi: s(''),
      deti: { booleanValue: false }, pol: s(' male '), relationStatus: s('single'),
      countryCode: s('ru'), region: s('Synthetic region'), languageCode: s('ru'), secondaryGroup: s('синяя'),
      profileDetailsSaved: { booleanValue: true }, isRegistrationEnd: { booleanValue: false },
      isUnVisible: { booleanValue: true }, unvisibleEnd: { timestampValue: '2027-01-01T00:00:00Z' },
      balance: { integerValue: '9007199254740993' }, status: s('blocked') },
    createTime: '2026-06-01T01:02:03Z', updateTime: '2026-09-30T01:02:03.123456789Z' };
    profiles.push({ uid, full_name: raw.fields.fullName.stringValue, country: 'ru', city: 'Synthetic city',
      primary_group: 'бело-красная', ...Object.fromEntries(PROFILE_DETAILS_BACKFILL_COLUMNS.map((key) => [key, null])),
      profile_details_saved: 1, registration_complete: 0, invisible_until: null, last_online_at: null,
      test_result: {}, updated_at: mysqlTimestamp(raw.updateTime), legacy_raw: structuredClone(raw) });
    sources.push({ firebase_path: `users/${uid}`, firebase_path_hash: hash(`users/${uid}`),
      collection_path: 'users', document_id: uid, payload_hash: payloadHash(raw), encoded_payload: raw });
  }
  return { profiles, sources, expectedSource: source, archiveSha256 };
}

function confirmed(plan) {
  return { targetDatabase: 'clrs_staging', archiveSha256, planSha256: plan.planSha256, eligible: plan.counts.eligible };
}

function confirmedRollback(receipt) {
  return { targetDatabase: 'clrs_staging', archiveSha256, planSha256: receipt.planSha256,
    receiptOperationId: receipt.operationId, eligible: receipt.entries.length };
}

async function files(t) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-profile-details-backfill-'));
  await chmod(directory, 0o700);
  t.after(() => rm(directory, { recursive: true, force: true }));
  return { directory, key: randomBytes(32), receiptPath: join(directory, 'prepared-fill.clrsenc'),
    rollbackPath: join(directory, 'prepared-restore.clrsenc') };
}

// A transaction-aware SQL seam. All records are synthetic; no credentials,
// network or live database are used by these focused tests.
function client(input, options = {}) {
  const shared = options.shared ?? { data: structuredClone(input) };
  let working, readOnly = false, sequence = 0;
  const calls = [];
  const api = {
    calls, shared,
    async query(sql) {
      calls.push({ sql });
      if (sql.startsWith('SET ')) return [[], []];
      if (sql.startsWith('START TRANSACTION')) {
        assert.equal(working, undefined); working = structuredClone(shared.data);
        readOnly = sql.includes('READ ONLY'); return [[], []];
      }
      if (sql === 'ROLLBACK') { working = undefined; return [[], []]; }
      if (sql === 'COMMIT') {
        assert.ok(working); await options.beforeCommit?.();
        if (!readOnly && !options.commitLostWithoutCommit) shared.data = working;
        working = undefined;
        if (options.commitLost || options.commitLostWithoutCommit) throw new Error('Synthetic response lost');
        return [[], []];
      }
      throw new Error('Unexpected synthetic query');
    },
    async execute(sql, parameters = []) {
      calls.push({ sql, parameters }); assert.ok(working);
      if (sql.includes('SELECT DATABASE()')) return [[{ target_database: options.database ?? 'clrs_staging',
        mysql_version: '8.4.4-4', sql_mode: 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION', character_set_connection: 'utf8mb4' }], []];
      if (sql.includes('FROM clrs_staging.legacy_source')) return [[{ source_project: source.project,
        source_database: source.database, source_bucket: source.bucket }], []];
      if (sql.includes('FROM clrs_staging.legacy_documents')) {
        const found = working.sources.filter((row) => parameters.includes(row.firebase_path_hash));
        return [structuredClone(found), []];
      }
      if (sql.startsWith('UPDATE clrs_staging.profiles')) {
        assert.equal(readOnly, false);
        const set = sql.split(' SET')[1].split('WHERE')[0];
        assert.deepEqual([...set.matchAll(/\b([a-z_]+)\s*=/g)].map((match) => match[1]),
          [...PROFILE_DETAILS_BACKFILL_COLUMNS, 'updated_at']);
        assert.equal(parameters.length, sql.includes('<=>') ? 25 : 14);
        const uid = parameters[11], profile = working.profiles.find((row) => row.uid === uid);
        assert.equal(parameters[12], uid);
        await options.beforeUpdate?.(profile, working);
        const sameColumns = sql.includes('<=>')
          ? PROFILE_DETAILS_BACKFILL_COLUMNS.every((key, index) => profile[key] === parameters[14 + index])
          : PROFILE_DETAILS_BACKFILL_COLUMNS.every((key) => profile[key] === null);
        if (!profile || profile.updated_at !== parameters[13] || !sameColumns) return [{ affectedRows: 0 }, []];
        for (const [index, key] of PROFILE_DETAILS_BACKFILL_COLUMNS.entries()) profile[key] = parameters[index];
        sequence += 1;
        profile.updated_at = `2026-10-02 19:00:00.${String(sequence).padStart(6, '0')}`;
        await options.afterUpdate?.(profile, working);
        return [{ affectedRows: 1 }, []];
      }
      if (sql.includes('FROM clrs_staging.profiles')) {
        const found = sql.includes('OFFSET ?')
          ? working.profiles.slice(parameters[0], parameters[0] + 100)
          : working.profiles.filter((row) => parameters.includes(row.uid));
        assert.ok(sql.includes('CASE WHEN OCTET_LENGTH') && sql.includes('65536'));
        return [found.map((row) => ({ uid: row.uid, profile_row: JSON.stringify(row) })), []];
      }
      throw new Error('Unexpected synthetic execute');
    },
  };
  return api;
}

test('pure plan reuses the 13-field projector but changes only 11 omitted columns', () => {
  const input = inputs(); const unchanged = structuredClone(input);
  const plan = prepareProfileDetailsBackfillBatch(input);
  assert.equal(plan.counts.eligible, 1);
  assert.deepEqual(plan.entries[0].patch, Object.fromEntries(PROFILE_DETAILS_BACKFILL_COLUMNS.map(
    (key) => [key, projectProfileDetails(input.sources[0].encoded_payload.fields)[key]])));
  assert.deepEqual(input, unchanged);
  assert.equal(Object.isFrozen(plan.entries[0].before), true);
  const summary = JSON.stringify(profileDetailsBackfillSummary(plan));
  for (const privateValue of [input.profiles[0].uid, privateText, 'Synthetic city']) assert.equal(summary.includes(privateValue), false);
  assert.throws(() => profileDetailsBackfillSummary({}), /prepared plan/);
});

test('wrong identity/hash, unsupported source and every later modification skip without coercion', () => {
  const cases = [
    [(input) => { input.sources[0].firebase_path_hash = 'b'.repeat(64); }, 'source_identity_mismatch'],
    [(input) => { input.sources[0].document_id = 'OtherSynthetic'; }, 'source_identity_mismatch'],
    [(input) => { input.sources[0].payload_hash = 'b'.repeat(64); }, 'source_payload_mismatch'],
    [(input) => { input.profiles[0].legacy_raw.fields.balance.integerValue = '3'; }, 'source_payload_mismatch'],
    [(input) => { input.profiles[0].age = 28; }, 'target_already_populated'],
    [(input) => { input.profiles[0].updated_at = '2026-10-01 01:00:00.000000'; }, 'later_profile_modification'],
    [(input) => { input.profiles[0].full_name = 'Later synthetic name'; }, 'later_profile_modification'],
    [(input) => { input.profiles[0].profile_details_saved = 0; }, 'later_profile_modification'],
    [(input) => { input.profiles[0].registration_complete = 1; }, 'later_profile_modification'],
    [(input) => { input.profiles[0].test_result = { changed: true }; }, 'later_profile_modification'],
    [(input) => { input.profiles[0].invisible_until = '2026-10-03 00:00:00.000000'; }, 'later_profile_modification'],
    [(input) => { input.profiles[0].last_online_at = '2026-10-02 00:00:00.000000'; }, 'later_profile_modification'],
    [(input) => {
      const raw = input.sources[0].encoded_payload; raw.fields.rost = s('180 cm');
      input.profiles[0].legacy_raw = structuredClone(raw); input.sources[0].payload_hash = payloadHash(raw);
    }, 'unsupported:rost:expected_integer_string'],
    [(input) => { input.sources.length = 0; }, 'source_missing'],
    [(input) => { input.profiles[0].legacy_raw = null; }, 'source_row_bound_or_shape'],
  ];
  for (const [mutate, reason] of cases) {
    const input = inputs(); mutate(input);
    const before = structuredClone(input), plan = prepareProfileDetailsBackfillBatch(input);
    assert.equal(plan.counts.eligible, 0); assert.deepEqual(plan.counts.reasons, { [reason]: 1 });
    assert.deepEqual(input, before);
  }
  assert.throws(() => prepareProfileDetailsBackfillBatch(inputs(101)), /bounded batch/);
});

test('inspection stays READ ONLY, bounded and returns an aggregate summary', async () => {
  const db = client(inputs());
  const plan = await inspectProfileDetailsBackfillBatch(db, { expectedSource: source, archiveSha256 });
  assert.equal(plan.counts.eligible, 1);
  assert.ok(db.calls.some((call) => call.sql.includes('WITH CONSISTENT SNAPSHOT, READ ONLY')));
  assert.ok(db.calls.some((call) => call.sql.includes('LIMIT 100 OFFSET ?')));
  assert.equal(db.calls.some((call) => /UPDATE|COMMIT|FOR UPDATE/.test(call.sql)), false);
  assert.equal(db.calls.at(-1).sql, 'ROLLBACK');
});

test('stage locks source/profile, preserves all untouched values, publishes encrypted receipt before COMMIT', async (t) => {
  const input = inputs(), plan = prepareProfileDetailsBackfillBatch(input), output = await files(t);
  let prepared;
  const db = client(input, { beforeCommit: async () => {
    const bytes = await readFile(output.receiptPath);
    assert.equal(bytes.includes(Buffer.from(privateText)), false);
    assert.equal(bytes.includes(Buffer.from(input.profiles[0].uid)), false);
    prepared = await readProfileDetailsBackfillReceipt(output.receiptPath, output.key);
    assert.equal(prepared.state, 'prepared'); assert.equal(prepared.operation, 'fill');
  } });
  const result = await stageProfileDetailsBackfillBatch(db, plan, confirmed(plan), output);
  assert.equal(result.databaseCommitted, true);
  const actual = db.shared.data.profiles[0], expected = { ...input.profiles[0], ...plan.entries[0].patch, updated_at: actual.updated_at };
  assert.deepEqual(actual, expected);
  assert.ok(actual.updated_at > input.profiles[0].updated_at);
  assert.equal(actual.legacy_raw.updateTime, input.profiles[0].legacy_raw.updateTime);
  assert.equal(actual.legacy_raw.fields.balance.integerValue, '9007199254740993');
  assert.equal(actual.invisible_until, null);
  const sourceLock = db.calls.findIndex((call) => call.sql.includes('FROM clrs_staging.legacy_documents'));
  const profileLock = db.calls.findIndex((call) => call.sql.includes('FROM clrs_staging.profiles'));
  assert.ok(sourceLock < profileLock && db.calls[sourceLock].sql.includes('FOR UPDATE') && db.calls[profileLock].sql.includes('FOR UPDATE'));
  assert.equal((await verifyProfileDetailsBackfillReceipt(client(input, { shared: db.shared }), prepared)).outcome, 'committed_verified');
  assert.equal(db.calls.filter((call) => call.sql.startsWith('UPDATE')).length, 1);
  assert.equal(db.calls.some((call) => /INSERT|DELETE|ALTER|CREATE|GRANT/.test(call.sql)), false);
});

test('review-to-stage change refuses before any UPDATE; column CAS race aborts', async (t) => {
  for (const type of ['later-edit', 'column-race']) {
    const input = inputs(), plan = prepareProfileDetailsBackfillBatch(input), output = await files(t);
    if (type === 'later-edit') input.profiles[0].registration_complete = 1;
    const db = client(input, type === 'column-race' ? { beforeUpdate(profile) { profile.age = 30; } } : {});
    await assert.rejects(stageProfileDetailsBackfillBatch(db, plan, confirmed(plan), output), /stage failed/);
    assert.equal(db.calls.some((call) => call.sql === 'COMMIT'), false);
    if (type === 'later-edit') assert.equal(db.calls.some((call) => call.sql.startsWith('UPDATE')), false);
    assert.deepEqual(db.shared.data, input);
    await assert.rejects(readFile(output.receiptPath), { code: 'ENOENT' });
  }
});

test('lost COMMIT acknowledgment is unknown, never retries, and fresh verify distinguishes outcomes', async (t) => {
  for (const lostButCommitted of [true, false]) {
    const input = inputs(), plan = prepareProfileDetailsBackfillBatch(input), output = await files(t);
    const db = client(input, lostButCommitted ? { commitLost: true } : { commitLostWithoutCommit: true });
    await assert.rejects(stageProfileDetailsBackfillBatch(db, plan, confirmed(plan), output), ProfileDetailsBackfillCommitUnknownError);
    const count = db.calls.length;
    await assert.rejects(stageProfileDetailsBackfillBatch(db, plan, confirmed(plan), output), /already attempted/);
    assert.equal(db.calls.length, count);
    const receipt = await readProfileDetailsBackfillReceipt(output.receiptPath, output.key);
    const result = await verifyProfileDetailsBackfillReceipt(client(input, { shared: db.shared }), receipt);
    assert.equal(result.outcome, lostButCommitted ? 'committed_verified' : 'not_committed_verified');
    assert.equal(result.databaseWrites, 0);
  }
});

test('receipt publication failure rolls back the whole batch before COMMIT', async (t) => {
  const input = inputs(), plan = prepareProfileDetailsBackfillBatch(input), output = await files(t);
  const db = client(input, { afterUpdate: async () => rm(output.directory, { recursive: true }) });
  await assert.rejects(stageProfileDetailsBackfillBatch(db, plan, confirmed(plan), output), /stage failed/);
  assert.deepEqual(db.shared.data, input);
  assert.equal(db.calls.some((call) => call.sql === 'COMMIT'), false);
});

test('guarded rollback restores eleven fields, advances CAS stamp and writes a separate prepared receipt', async (t) => {
  const input = inputs(2), plan = prepareProfileDetailsBackfillBatch(input), output = await files(t), db = client(input);
  await stageProfileDetailsBackfillBatch(db, plan, confirmed(plan), output);
  const receipt = await readProfileDetailsBackfillReceipt(output.receiptPath, output.key);
  const filledStamp = db.shared.data.profiles[0].updated_at;
  const first = db.calls.length;
  const result = await rollbackProfileDetailsBackfillBatch(db, receipt, confirmedRollback(receipt),
    { receiptPath: output.rollbackPath, key: output.key });
  assert.equal(result.databaseCommitted, true);
  const actual = db.shared.data.profiles[0];
  assert.deepEqual(actual, { ...input.profiles[0], updated_at: actual.updated_at });
  assert.ok(actual.updated_at > filledStamp);
  assert.equal(db.calls.slice(first).filter((call) => call.sql.includes('FROM clrs_staging.profiles')).length, 2);
  const rollbackCalls = db.calls.slice(first);
  assert.ok(rollbackCalls.findLastIndex((call) => call.sql.includes('FROM clrs_staging.profiles'))
    > rollbackCalls.findLastIndex((call) => call.sql.startsWith('UPDATE')));
  const restore = await readProfileDetailsBackfillReceipt(output.rollbackPath, output.key);
  assert.equal(restore.operation, 'restore'); assert.equal(restore.originalOperationId, receipt.operationId);
  assert.equal((await verifyProfileDetailsBackfillReceipt(client(input, { shared: db.shared }), restore)).outcome, 'committed_verified');
  const count = db.calls.length;
  await assert.rejects(rollbackProfileDetailsBackfillBatch(db, receipt, confirmedRollback(receipt),
    { receiptPath: output.rollbackPath, key: output.key }), /already attempted/);
  assert.equal(db.calls.length, count);
});

test('any later edit refuses the entire rollback before its first UPDATE', async (t) => {
  const input = inputs(2), plan = prepareProfileDetailsBackfillBatch(input), output = await files(t), db = client(input);
  await stageProfileDetailsBackfillBatch(db, plan, confirmed(plan), output);
  assert.equal(db.calls.filter((call) => call.sql.includes('FROM clrs_staging.profiles')).length, 2);
  const receipt = await readProfileDetailsBackfillReceipt(output.receiptPath, output.key);
  db.shared.data.profiles[1].test_result = { later: true };
  const before = structuredClone(db.shared.data), first = db.calls.length;
  await assert.rejects(rollbackProfileDetailsBackfillBatch(db, receipt, confirmedRollback(receipt),
    { receiptPath: output.rollbackPath, key: output.key }), /rollback failed/);
  assert.deepEqual(db.shared.data, before);
  assert.equal(db.calls.slice(first).some((call) => call.sql.startsWith('UPDATE') || call.sql === 'COMMIT'), false);
  await assert.rejects(verifyProfileDetailsBackfillReceipt(client(input, { shared: db.shared }), receipt), /manual review/);
});

test('lost rollback COMMIT uses its own prepared receipt and fresh reconciliation', async (t) => {
  const input = inputs(), plan = prepareProfileDetailsBackfillBatch(input), output = await files(t), fill = client(input);
  await stageProfileDetailsBackfillBatch(fill, plan, confirmed(plan), output);
  const receipt = await readProfileDetailsBackfillReceipt(output.receiptPath, output.key);
  const db = client(input, { shared: fill.shared, commitLost: true,
    afterUpdate(profile) { profile.updated_at = '2026-10-02 19:00:01.000001'; } });
  await assert.rejects(rollbackProfileDetailsBackfillBatch(db, receipt, confirmedRollback(receipt),
    { receiptPath: output.rollbackPath, key: output.key }), (error) => error instanceof ProfileDetailsBackfillCommitUnknownError
      && error.operation === 'restore');
  const restore = await readProfileDetailsBackfillReceipt(output.rollbackPath, output.key);
  assert.equal((await verifyProfileDetailsBackfillReceipt(client(input, { shared: db.shared }), restore)).outcome, 'committed_verified');
});

test('wrong target and unreviewed plans cannot change rows', async (t) => {
  const input = inputs(), plan = prepareProfileDetailsBackfillBatch(input), output = await files(t), db = client(input, { database: 'synthetic_other_db' });
  await assert.rejects(stageProfileDetailsBackfillBatch(db, {}, confirmed(plan), output), /confirmation/);
  assert.equal(db.calls.length, 0);
  await assert.rejects(stageProfileDetailsBackfillBatch(db, plan, confirmed(plan), output), /stage failed/);
  assert.equal(db.calls.some((call) => call.sql.startsWith('UPDATE')), false);
  assert.deepEqual(db.shared.data, input);
});
