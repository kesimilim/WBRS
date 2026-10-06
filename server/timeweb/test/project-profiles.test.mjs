import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { appendFile, chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { payloadHash } from '../import-core.mjs';
import { PROFILE_DETAILS_COLUMNS, projectProfileDetails } from '../project-profile-details.mjs';
import { prepareProfileProjection, profileProjectionSummary } from '../project-profiles-core.mjs';
import { mainProfileProjection, parseProfileProjectionArgs, readProfileProjectionReceipt } from '../project-profiles-cli.mjs';
import { profileInsertBatches, rollbackProfileProjection, stageProfileProjection,
  verifyProfileProjection } from '../project-profiles-mysql84.mjs';

const source = { kind: 'source', format: 2, project: 'clrs-synthetic', database: '(default)',
  bucket: 'clrs-synthetic.appspot.com', scope: 'metadata', storagePrefix: '',
  completeSource: false, passwordHashesIncluded: false, snapshotConsistent: false };
const expectedSource = { project: source.project, database: source.database, bucket: source.bucket };
const textField = (value) => ({ stringValue: value });
const exampleName = "О'Коннор; DROP TABLE accounts;\nВторая строка";
const sha = (value) => createHash('sha256').update(value).digest('hex');

function users() {
  return [
    { uid: 'u1', email: ' USER1@EXAMPLE.INVALID ', emailVerified: true, disabled: false,
      metadata: { creationTime: 'Mon, 01 Jun 2026 01:02:03 GMT', lastSignInTime: null },
      providerData: [{ providerId: 'password', uid: 'user1@example.invalid', email: 'USER1@EXAMPLE.INVALID' }] },
    { uid: 'u2', email: 'user2@example.invalid', emailVerified: false, disabled: true,
      providerData: [{ providerId: 'google.com', uid: 'provider-u2', email: 'user2@example.invalid' }] },
    { uid: 'u3', emailVerified: false, disabled: false, providerData: [], customClaims: { admin: true, custom: 'preserved' } },
  ];
}

function documents() {
  return [
    { kind: 'firestore-document', path: 'users/u1', fields: {
      uid: { nullValue: null }, fullName: textField(exampleName), city: textField('Пермь'),
      'группа': textField('бело-красная'), status: textField('active'),
      isRegistrationEnd: { booleanValue: true },
      // These remain byte-for-byte in legacy_raw, with no payment/gift mapping.
      balance: { integerValue: '9007199254740993' }, gifts: { mapValue: { fields: { gift: { integerValue: '2' } } } },
    }, createTime: '2026-06-01T01:02:03Z', updateTime: '2026-09-30T01:02:03.123456789Z' },
    { kind: 'firestore-document', path: 'users/u2', fields: {
      uid: textField('u2'), fullName: textField(''), country: textField('Россия'), city: textField(''),
      'группа': textField(''), status: textField('blocked'), profileDetailsSaved: { booleanValue: true },
    }, createTime: '2026-06-01T01:02:03Z', updateTime: '2026-09-30T01:02:03Z' },
    { kind: 'firestore-document', path: 'users/orphan', fields: {
      uid: textField('orphan'), fullName: textField('Orphan'), status: textField('deleted'),
    }, createTime: '2026-06-01T01:02:03Z', updateTime: '2026-09-30T01:02:03Z' },
    { kind: 'firestore-document', path: 'users/u1/chats/chat1', fields: { untouched: textField('message') },
      createTime: '2026-06-01T01:02:03Z', updateTime: '2026-09-30T01:02:03Z' },
  ];
}

async function fixture(t, { auth = users(), docs = documents(), full = false, summaryOverride = {},
  extra = [], storageSha } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-profile-projection-'));
  await chmod(directory, 0o700);
  t.after(() => rm(directory, { recursive: true, force: true }));
  const key = randomBytes(32);
  const archivePath = join(directory, 'source.clrsenc');
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  await writer.writeJson(full ? { ...source, scope: 'all', completeSource: true } : source);
  for (const user of auth) await writer.writeJson({ kind: 'auth-user', user });
  for (const document of docs) await writer.writeJson(document);
  for (const record of extra) await writer.writeJson(record);
  const bytes = Buffer.from('synthetic image bytes');
  if (full) {
    await writer.writeJson({ kind: 'storage-object', name: 'users/u1/photos/p1.jpg',
      metadata: { size: String(bytes.length), generation: '1' } });
    await writer.writeBytes(bytes);
    await writer.writeJson({ kind: 'storage-sha256', name: 'users/u1/photos/p1.jpg', sha256: storageSha ?? sha(bytes) });
  }
  await writer.finish({ authUsers: auth.length, authListPages: 1, firestoreDocuments: docs.length,
    firestoreMissingParents: 0, firestoreReferences: docs.length, firestoreCollections: 2, firestoreListPages: 2,
    storageObjects: full ? 1 : 0, storageBytes: full ? bytes.length : 0,
    storageListPages: full ? 1 : 0, ...summaryOverride });
  return { archivePath, key, expectedSource, directory };
}

function confirmations(plan) {
  return { targetDatabase: 'clrs_staging', archiveSha256: plan.archiveSha256,
    orphanProfiles: plan.counts.orphanProfiles, accountsWithoutProfile: plan.counts.accountsWithoutProfile,
    rollbackArchiveSha256: plan.archiveSha256 };
}

const unusedProfileColumns = ['invisible_until', 'last_online_at'];

// A transaction-aware mysql2-shaped double tests parameterization, immutable
// source joins, state changes and rollback. It does not replace a real MySQL
// integration run and makes no network calls.
function fakeMySql(plan, { database = 'clrs_staging', version = '8.4.6',
  failAccountDelete = false, failCommitOnce = false, deletePrivilege = true,
  maxPacket = 64 * 1024 * 1024 } = {}) {
  const rootRows = plan.rootDocuments.map((record) => ({ firebase_path: record.firebasePath,
    encoded_payload: JSON.stringify(record.encodedPayload), payload_hash: record.sha256.toUpperCase() }));
  const authRows = plan.authRecords.map((record) => ({ uid: record.uid,
    encoded_payload: JSON.stringify(record.encodedPayload), payload_hash: record.sha256.toUpperCase() }));
  let committed = { accounts: [], profiles: [], identities: [] };
  let working;
  let readOnly;
  const calls = [];
  const client = {
    calls, authRows, rootRows,
    get data() { return committed; },
    async query(sql) {
      calls.push({ sql });
      if (sql === 'SHOW GRANTS') return [[
        { grant: 'GRANT USAGE ON *.* TO `synthetic`@`%`' },
        { grant: 'GRANT CREATE, INSERT, REFERENCES, SELECT, UPDATE ON `clrs_staging`.* TO `synthetic`@`%`' },
        ...(deletePrivilege ? ['accounts', 'profiles', 'auth_identities'].map((table) => ({
          grant: `GRANT DELETE ON \`clrs_staging\`.\`${table}\` TO \`synthetic\`@\`%\``,
        })) : []),
      ], []];
      if (sql.startsWith('SET ')) return [[], []];
      if (sql.startsWith('START TRANSACTION')) {
        assert.equal(working, undefined);
        working = structuredClone(committed);
        readOnly = sql.includes('READ ONLY');
        return [[], []];
      }
      if (sql === 'COMMIT') {
        assert.ok(working);
        if (!readOnly) committed = working;
        working = undefined;
        if (failCommitOnce) { failCommitOnce = false; throw new Error('Synthetic commit response lost'); }
        return [[], []];
      }
      if (sql === 'ROLLBACK') { working = undefined; return [[], []]; }
      throw new Error('Unexpected synthetic query');
    },
    async execute(sql, params = []) {
      calls.push({ sql, params });
      assert.ok(working, 'All SQL must remain inside one transaction');
      if (sql.includes('SELECT DATABASE()')) return [[{ target_database: database, mysql_version: version,
        sql_mode: 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION', character_set_connection: 'utf8mb4',
        max_allowed_packet: maxPacket }], []];
      if (sql.includes('schema_migrations')) return [[{ version: 1 }], []];
      if (sql.includes('FROM clrs_staging.legacy_source')) return [[{ source_project: plan.source.project,
        source_database: plan.source.database, source_bucket: plan.source.bucket }], []];
      if (sql.includes('AS auth_users')) return [[{ auth_users: String(authRows.length), root_profiles: String(rootRows.length) }], []];
      if (sql.includes('FROM clrs_staging.legacy_auth_users')) return [authRows.filter((row) => params.includes(sha(row.uid))), []];
      if (sql.includes('FROM clrs_staging.legacy_documents')) return [rootRows.filter((row) => params.includes(sha(row.firebase_path))), []];
      if (sql.includes('AS accounts')) return [[{ accounts: String(working.accounts.length), profiles: String(working.profiles.length),
        identities: String(working.identities.length) }], []];
      if (sql.includes('AS projection_time')) return [[{ projection_time: '2026-09-30 21:01:02.123456' }], []];
      const insert = /^INSERT INTO clrs_staging\.(accounts|profiles|auth_identities) \(([^)]+)\)/.exec(sql);
      if (insert) {
        assert.equal(readOnly, false);
        const table = insert[1] === 'auth_identities' ? 'identities' : insert[1];
        const columns = insert[2].split(', ');
        assert.equal(params.length % columns.length, 0);
        let inserted = 0;
        for (let offset = 0; offset < params.length; offset += columns.length) {
          const row = Object.fromEntries(columns.map((name, index) => [name, params[offset + index]]));
          if (table === 'profiles') {
            Object.assign(row, Object.fromEntries(unusedProfileColumns.map((name) => [name, null])));
            row.test_result = '{}';
          }
          assert.ok(!working[table].some((old) => table === 'identities'
            ? old.provider === row.provider && old.provider_subject === row.provider_subject : old.uid === row.uid));
          working[table].push(row);
          inserted++;
        }
        return [{ affectedRows: inserted }, []];
      }
      for (const [sqlTable, table] of [['auth_identities', 'identities'], ['profiles', 'profiles'], ['accounts', 'accounts']]) {
        if (sql.includes(`FROM clrs_staging.${sqlTable}`)) {
          if (sql.startsWith('DELETE')) {
            assert.equal(readOnly, false);
            if (failAccountDelete && table === 'accounts') throw new Error('Synthetic downstream FK');
            const before = working[table].length;
            working[table] = working[table].filter((row) => !params.includes(row.uid));
            return [{ affectedRows: before - working[table].length }, []];
          }
          const found = working[table].filter((row) => table === 'identities'
            ? params.some((parameter, index) => index % 2 === 0 && parameter === row.provider && params[index + 1] === row.provider_subject)
            : params.includes(row.uid));
          return [found, []];
        }
      }
      throw new Error('Unexpected synthetic SQL');
    },
  };
  return client;
}

test('authenticated metadata projection preserves UID, null country, combined group, claims and source payload', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  assert.deepEqual(plan.counts, { sourceAuthUsers: 3, sourceRootProfiles: 3, accounts: 3,
    identities: 2, profiles: 2, orphanProfiles: 1, accountsWithoutProfile: 1,
    disabledAccounts: 1, blockedAccounts: 1, deletedAccounts: 0, adminClaims: 1,
    profilesWithoutCountry: 1, profilesWithoutName: 0, profilesWithEmptyName: 1 });
  assert.equal(plan.profiles[0].uid, 'u1');
  assert.equal(plan.profiles[0].full_name, exampleName);
  assert.equal(plan.profiles[0].country, null);
  assert.equal(plan.profiles[0].primary_group, 'бело-красная');
  assert.equal(plan.profiles[0].secondary_group, null);
  assert.equal(plan.profiles[0].updated_at, '2026-09-30 01:02:03.123456');
  assert.equal(plan.profiles[0].legacy_raw.updateTime, '2026-09-30T01:02:03.123456789Z');
  assert.deepEqual(plan.profiles[0].legacy_raw.fields.uid, { nullValue: null });
  assert.equal(plan.accounts[0].email_normalized, 'user1@example.invalid');
  assert.equal(plan.accounts[0].firebase_created_at, '2026-06-01 01:02:03.000000');
  assert.equal(plan.accounts[2].legacy_claims.admin, true);
  assert.equal(plan.profiles.some((row) => row.uid === 'orphan'), false);
  assert.equal(plan.profiles.some((row) => row.uid === 'u3'), false);
  const summary = JSON.stringify(profileProjectionSummary(plan));
  for (const value of [exampleName, 'user1@example.invalid', 'provider-u2']) assert.equal(summary.includes(value), false);
  assert.throws(() => { plan.accounts[0].disabled = 1; }, TypeError);
});

test('full archive authenticates all Storage bytes before accepting this narrow projection', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t, { full: true }));
  assert.equal(plan.source.completeSource, true);
  assert.equal(plan.counts.profiles, 2);
  await assert.rejects(prepareProfileProjection(await fixture(t, { full: true, storageSha: '0'.repeat(64) })), /checksum/);
});

test('truncated, tampered, trailing and wrong-summary archives cannot authorize any SQL', async (t) => {
  for (const kind of ['truncated', 'tampered', 'trailing']) {
    const inputs = await fixture(t);
    const bytes = await readFile(inputs.archivePath);
    if (kind === 'truncated') await writeFile(inputs.archivePath, bytes.subarray(0, bytes.length - 10));
    if (kind === 'tampered') { bytes[bytes.length - 1] ^= 1; await writeFile(inputs.archivePath, bytes); }
    if (kind === 'trailing') await appendFile(inputs.archivePath, Buffer.from([0]));
    await assert.rejects(prepareProfileProjection(inputs));
  }
  await assert.rejects(prepareProfileProjection(await fixture(t, { summaryOverride: { authUsers: 2 } })), /completion count/);
  const client = { calls: [], query: async () => { throw new Error('Must not query'); } };
  await assert.rejects(stageProfileProjection(client, {}, {}, async () => {}), /authenticated/);
});

test('projection refuses source mismatch, limits, password material and unsupported credential records', async (t) => {
  const inputs = await fixture(t);
  await assert.rejects(prepareProfileProjection({ ...inputs, expectedSource: { ...expectedSource, project: 'different-project' } }), /source confirmation/);
  await assert.rejects(prepareProfileProjection({ ...inputs, limits: { maxAuthUsers: 2 } }), /limit/);
  const auth = users(); auth[0].passwordHash = 'synthetic-forbidden';
  await assert.rejects(prepareProfileProjection(await fixture(t, { auth })), /Auth record/);
  await assert.rejects(prepareProfileProjection(await fixture(t, { extra: [{ kind: 'auth-credential', uid: 'u1' }] })), /record order/);
});

test('unknown lifecycle, foreign profile UID, duplicate email/provider and tenant cannot be silently remapped', async (t) => {
  for (const kind of ['status', 'uid', 'email', 'provider', 'tenant', 'country', 'provider-length']) {
    const auth = users(); const docs = documents();
    if (kind === 'status') docs[0].fields.status = textField('unknown-status');
    if (kind === 'uid') docs[0].fields.uid = textField('u2');
    if (kind === 'email') auth[1].email = 'user1@example.invalid';
    if (kind === 'provider') auth[1].providerData = auth[0].providerData;
    if (kind === 'tenant') auth[0].tenantId = 'tenant-1';
    if (kind === 'country') docs[0].fields.country = { integerValue: '1' };
    if (kind === 'provider-length') auth[0].providerData[0].uid = 'x'.repeat(192);
    await assert.rejects(prepareProfileProjection(await fixture(t, { auth, docs })));
  }
});

test('stage binds exact legacy rows and performs parameterized, insert-only SQL with a durable receipt', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  const client = fakeMySql(plan);
  let receipt;
  const result = await stageProfileProjection(client, plan, confirmations(plan), async (value) => { receipt = value; });
  assert.equal(result.databaseCommitted, true);
  assert.equal(client.data.accounts.length, 3);
  assert.equal(client.data.profiles.length, 2);
  assert.equal(client.data.identities.length, 2);
  assert.equal(receipt.archiveSha256, plan.archiveSha256);
  assert.equal(client.calls.some((call) => call.sql.includes(exampleName)), false);
  assert.equal(client.calls.some((call) => call.params?.includes(exampleName)), true);
  assert.equal(client.calls.some((call) => /\b(CREATE|ALTER|DROP|UPDATE|TRUNCATE)\b/.test(call.sql.replaceAll('FOR UPDATE', ''))), false);
  const query = await verifyProfileProjection(client, plan, 'clrs_staging', receipt);
  assert.equal(query.databaseWrites, 0);
  assert.deepEqual(query.counts, { accounts: 3, profiles: 2, identities: 2 });
  await assert.rejects(stageProfileProjection(client, plan, confirmations(plan), async () => {}), /empty normalized/);
});

test('profile details initial INSERT and expected-row proof preserve original typed source and refuse later edits', async (t) => {
  const docs = documents();
  Object.assign(docs[0].fields, { age: { doubleValue: 28.0 }, rost: textField('180'),
    about: textField(' Короткое описание\n'), hobbi: textField('Хобби'), deti: { booleanValue: false },
    pol: textField('мужской'), relationStatus: textField('свободен'), countryCode: textField('RU'),
    region: textField('Регион'), languageCode: textField('ru'), secondaryGroup: textField('белая'),
    profileDetailsSaved: { booleanValue: true } });
  const original = structuredClone(docs[0]);
  const plan = await prepareProfileProjection(await fixture(t, { docs }));
  const expected = projectProfileDetails(original.fields);
  assert.deepEqual(Object.fromEntries(PROFILE_DETAILS_COLUMNS.map((key) => [key, plan.profiles[0][key]])), expected);
  assert.deepEqual(plan.profiles[0].legacy_raw.fields, original.fields);
  assert.equal(plan.rootDocuments[0].sha256, payloadHash(plan.rootDocuments[0].encodedPayload));
  assert.equal(plan.profiles[0].updated_at, '2026-09-30 01:02:03.123456');
  assert.deepEqual(docs[0], original);
  const client = fakeMySql(plan); let receipt;
  await stageProfileProjection(client, plan, confirmations(plan), async (value) => { receipt = value; });
  await verifyProfileProjection(client, plan, 'clrs_staging', receipt);
  for (const column of PROFILE_DETAILS_COLUMNS) assert.equal(client.data.profiles[0][column], expected[column]);
  const insert = client.calls.find((call) => call.sql.startsWith('INSERT INTO clrs_staging.profiles'));
  for (const column of PROFILE_DETAILS_COLUMNS) assert.ok(insert.sql.includes(column));
  assert.equal(client.data.profiles[0].invisible_until, null);
  assert.equal(client.data.profiles[0].last_online_at, null);
  client.data.profiles[0].about_text = 'Native later edit';
  const changed = structuredClone(client.data);
  await assert.rejects(verifyProfileProjection(client, plan, 'clrs_staging', receipt), /profile mismatch/);
  await assert.rejects(stageProfileProjection(client, plan, confirmations(plan), async () => {}), /empty normalized/);
  assert.deepEqual(client.data, changed);
});

test('explicit confirmations and target/version checks stop stage before INSERT', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  for (const patch of [{ targetDatabase: 'LRS' }, { archiveSha256: '0'.repeat(64) },
    { orphanProfiles: 0 }, { accountsWithoutProfile: 0 }]) {
    const client = fakeMySql(plan);
    await assert.rejects(stageProfileProjection(client, plan, { ...confirmations(plan), ...patch }, async () => {}), /confirmations/);
    assert.equal(client.calls.length, 0);
  }
  for (const options of [{ database: 'LRS' }, { version: '8.0.40' }]) {
    const client = fakeMySql(plan, options);
    await assert.rejects(stageProfileProjection(client, plan, confirmations(plan), async () => {}), /target/);
    assert.equal(client.calls.some((call) => call.sql.startsWith('INSERT')), false);
    assert.equal(client.calls.at(-1).sql, 'ROLLBACK');
  }
});

test('raw UID hash collision, changed payload and missing orphan archive row all block promotion', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  for (const kind of ['auth-payload', 'root-payload', 'missing-orphan']) {
    const client = fakeMySql(plan);
    if (kind === 'auth-payload') client.authRows[0].encoded_payload = JSON.stringify({ ...users()[0], disabled: true });
    if (kind === 'root-payload') client.rootRows[0].encoded_payload = '{}';
    if (kind === 'missing-orphan') client.rootRows.pop();
    await assert.rejects(stageProfileProjection(client, plan, confirmations(plan), async () => {}), /legacy.*mismatch/);
    assert.equal(client.calls.some((call) => call.sql.startsWith('INSERT')), false);
  }
});

test('failed receipt publication rolls back all normalized inserts', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  const client = fakeMySql(plan);
  await assert.rejects(stageProfileProjection(client, plan, confirmations(plan), async () => { throw new Error('Synthetic receipt failure'); }));
  assert.deepEqual(client.data, { accounts: [], profiles: [], identities: [] });
  assert.equal(client.calls.at(-1).sql, 'ROLLBACK');
});

test('packet batches are bounded by UTF-8/JSON bytes and reject oversized legacy_raw before any INSERT', async (t) => {
  const records = Array.from({ length: 220 }, (_, index) => ({ uid: `u${index}`,
    legacy_raw: { fields: { about: textField('😀'.repeat(350)) } } }));
  const columns = ['uid', 'legacy_raw'];
  const budget = 6000;
  const actual = [...profileInsertBatches(columns, records, budget)];
  assert.equal(actual.flat().length, 220);
  assert.ok(actual.length > 3, 'Byte limit must split well before the 100-row limit');
  for (const batch of actual) {
    const payloadBytes = batch.reduce((total, row) => total + Buffer.byteLength(row.uid, 'utf8')
      + Buffer.byteLength(JSON.stringify(row.legacy_raw), 'utf8'), 0);
    assert.ok(payloadBytes < budget);
    assert.ok(batch.length <= 100);
  }
  const docs = documents();
  docs[0].fields.about = textField('я'.repeat(100_000));
  const plan = await prepareProfileProjection(await fixture(t, { docs }));
  const client = fakeMySql(plan, { maxPacket: 128 * 1024 });
  await assert.rejects(stageProfileProjection(client, plan, confirmations(plan), async () => {}), /packet budget/);
  assert.equal(client.calls.some((call) => call.sql.startsWith('INSERT')), false);
  assert.deepEqual(client.data, { accounts: [], profiles: [], identities: [] });
});

test('lost COMMIT response remains verifiable and cannot trigger a duplicate stage', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  const client = fakeMySql(plan, { failCommitOnce: true });
  let receipt;
  await assert.rejects(stageProfileProjection(client, plan, confirmations(plan), async (value) => { receipt = value; }), /commit response lost/);
  assert.equal(client.data.accounts.length, 3);
  assert.equal((await verifyProfileProjection(client, plan, 'clrs_staging', receipt)).counts.accounts, 3);
  await assert.rejects(stageProfileProjection(client, plan, confirmations(plan), async () => {}), /empty normalized/);
});

test('rollback removes only an unchanged receipt-bound projection and retains raw archives', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  const client = fakeMySql(plan);
  let receipt;
  await stageProfileProjection(client, plan, confirmations(plan), async (value) => { receipt = value; });
  const result = await rollbackProfileProjection(client, plan, confirmations(plan), receipt);
  assert.equal(result.legacyArchivesRetained, true);
  assert.deepEqual(client.data, { accounts: [], profiles: [], identities: [] });
  assert.equal(client.authRows.length, 3);
  assert.equal(client.rootRows.length, 3);
  assert.equal(client.calls.some((call) => call.sql.startsWith('DELETE') && call.sql.includes('legacy_')), false);
});

test('current five migration privileges cannot run a post-commit DELETE rollback', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  const client = fakeMySql(plan, { deletePrivilege: false });
  let receipt;
  await stageProfileProjection(client, plan, confirmations(plan), async (value) => { receipt = value; });
  const before = structuredClone(client.data);
  const priorCallCount = client.calls.length;
  await assert.rejects(rollbackProfileProjection(client, plan, confirmations(plan), receipt), /DELETE privileges/);
  assert.deepEqual(client.data, before);
  assert.deepEqual(client.calls.slice(priorCallCount).map((call) => call.sql), ['SHOW GRANTS']);
});

test('rollback refuses newer rows, modified columns, altered claims, different receipt and later downstream data', async (t) => {
  const plan = await prepareProfileProjection(await fixture(t));
  for (const kind of ['new-row', 'name', 'profile-age', 'claims', 'stamp', 'receipt', 'fk']) {
    const client = fakeMySql(plan, { failAccountDelete: kind === 'fk' });
    let receipt;
    await stageProfileProjection(client, plan, confirmations(plan), async (value) => { receipt = value; });
    if (kind === 'new-row') client.data.accounts.push({ uid: 'new' });
    if (kind === 'name') client.data.profiles[0].full_name = 'Later edit';
    if (kind === 'profile-age') client.data.profiles[0].age = 32;
    if (kind === 'claims') client.data.accounts[0].legacy_claims = JSON.stringify({ admin: true });
    if (kind === 'stamp') client.data.accounts[0].updated_at = '2026-09-30 22:01:02.123456';
    if (kind === 'receipt') receipt = { ...receipt, projectionSha256: '0'.repeat(64) };
    const before = structuredClone(client.data);
    await assert.rejects(rollbackProfileProjection(client, plan, confirmations(plan), receipt));
    assert.deepEqual(client.data, before);
  }
});

test('CLI defaults to dry-run, rejects missing rollback confirmations and authenticates encrypted receipt', async (t) => {
  const inputs = await fixture(t);
  const args = ['--archive', inputs.archivePath, '--key-file', join(inputs.directory, 'key'),
    '--project', source.project, '--database', source.database, '--bucket', source.bucket];
  assert.equal(parseProfileProjectionArgs(args).mode, 'dry-run');
  await writeFile(join(inputs.directory, 'key'), inputs.key, { mode: 0o600 });
  const dryRun = await mainProfileProjection(args);
  assert.equal(dryRun.databaseWrites, 0);
  assert.equal(dryRun.counts.profiles, 2);
  assert.throws(() => parseProfileProjectionArgs([...args, '--mode', 'stage']), /target database/);
  assert.throws(() => parseProfileProjectionArgs([...args, '--password', 'forbidden']), /arguments/);
  const plan = await prepareProfileProjection(inputs);
  const client = fakeMySql(plan);
  let receipt;
  await stageProfileProjection(client, plan, confirmations(plan), async (value) => { receipt = value; });
  const path = join(inputs.directory, 'rollback.clrsenc');
  const writer = await EncryptedArchiveWriter.create(path, inputs.key);
  await writer.writeJson(receipt);
  await writer.finish({ receiptRecords: 1 });
  assert.deepEqual(await readProfileProjectionReceipt(path, inputs.key), receipt);
  await appendFile(path, Buffer.from([0]));
  await assert.rejects(readProfileProjectionReceipt(path, inputs.key), /trailing/);
});
