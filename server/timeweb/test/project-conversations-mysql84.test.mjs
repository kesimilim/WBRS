import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { prepareConversationProjection, conversationProjectionSummary } from '../project-conversations-core.mjs';
import { prepareProfileProjection } from '../project-profiles-core.mjs';
import { CONVERSATION_TABLES, assertConversationConfirmations, conversationBatches,
  stageConversationProjection, verifyConversationProjection } from '../project-conversations-mysql84.mjs';
import { mainConversationProjection, parseConversationArgs, readConversationReceipt,
  writeConversationReceipt } from '../project-conversations-cli.mjs';

const hash = (value) => createHash('sha256').update(value).digest('hex');
const clone = (value) => structuredClone(value);
const source = { kind: 'source', format: 2, scope: 'all', completeSource: true,
  passwordHashesIncluded: false, storagePrefix: '', project: 'synthetic-projection',
  database: '(default)', bucket: 'synthetic-projection.appspot.com' };
const expectedSource = { project: source.project, database: source.database, bucket: source.bucket };
const s = (stringValue) => ({ stringValue });
const ts = (timestampValue) => ({ timestampValue });
const arr = (...items) => ({ arrayValue: { values: items.map(s) } });
const doc = (path, fields) => ({ kind: 'firestore-document', path, fields,
  createTime: '2026-10-01T00:00:00.123456789Z', updateTime: '2026-10-01T00:00:01.123456789Z' });
const fixtureDocuments = () => [
  doc('users/Synthetic-A', { fullName: s('Synthetic name'), status: s('blocked'),
    age: { stringValue: '28' }, rost: s('180'), about: s(' Short '), hobbi: s(''),
    deti: { booleanValue: false }, pol: s('мужской'), region: s('Регион'), countryCode: s('RU'),
    languageCode: s('ru'), secondaryGroup: s('белая') }),
  doc('users/synthetic-a', { country: s('Synthetic country') }),
  doc('chats/CaseChat', { user1: s('Synthetic-A'), user2: s('synthetic-a') }),
  doc('chats/CaseChat/chats/CaseMessage', { sendByID: s('Synthetic-A'),
    message: s('Синтетический текст "кавычки", \\ и \n'), ts: ts('2026-10-01T00:00:02.987654321Z') }),
  doc('meets/CaseMeeting', { admin: s('Synthetic-A'), type: s('групповая'), name: s('Synthetic meeting'),
    description: s('Synthetic description'), users: arr('Synthetic-A', 'synthetic-a'), datetime: s('01.10.2026 12:30') }),
  doc('meets/CaseMeeting/messages/CaseMeetMessage', { sender: s('synthetic-a'), message: s('Synthetic group message'),
    time: ts('2026-10-01T00:00:03.000000001Z') }),
  doc('users/Synthetic-A/removed_meets/CaseMeeting/messages/CaseMeetMessage', { sender: s('synthetic-a'), message: s('Synthetic group message'),
    time: ts('2026-10-01T00:00:03.000000001Z') }),
  doc('meets/LegacyIndividual', { admin: s('Synthetic-A'), type: s('индивидуальная'), users: arr('Synthetic-A') }),
  doc('users/orphan', { fullName: s('Synthetic orphan') }),
  doc('TOKENS/synthetic', { token: s('Synthetic placeholder, never a real token') }),
];
async function fixture(t, { metadata = false, documents = fixtureDocuments(), invalidDependency = false, storage = false } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'clrs-conversation-stage-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const archivePath = join(directory, 'full.clrsenc'); const key = randomBytes(32);
  const keyPath = join(directory, 'archive.key'); await writeFile(keyPath, key, { mode: 0o600 });
  const writer = await EncryptedArchiveWriter.create(archivePath, key);
  await writer.writeJson(metadata ? { ...source, scope: 'metadata', completeSource: false } : source);
  for (const [index, uid] of ['Synthetic-A', 'synthetic-a', 'Ä'].entries()) {
    await writer.writeJson({ kind: 'auth-user', user: { uid, disabled: index === 0,
      emailVerified: true, email: `synthetic-${index}@example.invalid`,
      ...(invalidDependency && index === 0 ? { tenantId: 'unsupported-synthetic-tenant' } : {}),
      metadata: { creationTime: '2026-09-30T00:00:00Z', lastSignInTime: '2026-10-01T00:00:00Z' },
      customClaims: index === 0 ? { admin: true } : {},
      providerData: [{ providerId: 'password', uid: `synthetic-${index}@example.invalid`, email: `synthetic-${index}@example.invalid` }] } });
  }
  for (const record of documents) await writer.writeJson(record);
  const bytes = Buffer.from('Synthetic object fixture');
  if (storage) {
    await writer.writeJson({ kind: 'storage-object', name: 'Synthetic/Снимок.png',
      metadata: { name: 'Synthetic/Снимок.png', generation: '1', size: String(bytes.length) } });
    await writer.writeBytes(bytes);
    await writer.writeJson({ kind: 'storage-sha256', name: 'Synthetic/Снимок.png', sha256: hash(bytes) });
  }
  await writer.finish({ authUsers: 3, authListPages: 1, firestoreDocuments: documents.length,
    firestoreMissingParents: 0, firestoreReferences: documents.length, firestoreCollections: 6,
    firestoreListPages: 6, storageObjects: storage ? 1 : 0, storageBytes: storage ? bytes.length : 0,
    storageListPages: storage ? 1 : 0 });
  const inputs = { archivePath, key, expectedSource };
  const plan = await prepareConversationProjection(inputs);
  return { ...inputs, plan, directory, keyPath,
    cliArgs: ['--archive', archivePath, '--key-file', keyPath, '--project', source.project,
      '--database', source.database, '--bucket', source.bucket] };
}
const confirmation = (plan) => ({ targetDatabase: 'clrs_staging', archiveSha256: plan.archiveSha256,
  projectionSha256: plan.projectionSha256, dependencySha256: plan.dependencySha256,
  rawOnlyDocuments: plan.rawOnlyAcknowledgement.documents,
  rawOnlyParticipantEntries: plan.rawOnlyAcknowledgement.participantEntries,
  rawOnlyReasonDigest: plan.rawOnlyAcknowledgement.reasonDigest });
const schemaNames = [...(await readFile(new URL('../db/001_initial_mysql84.sql', import.meta.url), 'utf8'))
  .matchAll(/CREATE TABLE clrs_staging\.([a-z_]+) \(/g)].map((match) => match[1]);
const jsonFields = new Set(['legacy_raw', 'legacy_claims', 'test_result']);

class Database {
  constructor(plan, options = {}, state) {
    this.plan = plan; this.options = options; this.trace = []; this.insertCount = 0;
    this.tables = state ?? Object.fromEntries([
      ['accounts', clone(plan.dependencies.accounts)], ['auth_identities', clone(plan.dependencies.identities)],
      ['profiles', plan.dependencies.profiles.map((row) => ({ ...clone(row),
        invisible_until: null, last_online_at: null, test_result: {} }))],
      ...CONVERSATION_TABLES.map((spec) => [spec.table, []]),
    ]);
  }
  async query(sql) {
    this.trace.push(sql);
    if (sql === 'SHOW GRANTS') return [[{ grant: 'GRANT USAGE ON *.* TO `synthetic`@`%`' },
      { grant: `GRANT CREATE, INSERT, REFERENCES, SELECT, UPDATE${this.options.excessGrant ? ', DELETE' : ''} ON \`clrs_staging\`.* TO \`synthetic\`@\`%\`` }]];
    if (sql === 'USE default_db') {
      if (this.options.legacyAllowed) return [[]];
      const denied = new Error('Synthetic denied'); denied.code = 'ER_DBACCESS_DENIED_ERROR'; denied.errno = 1044; throw denied;
    }
    if (sql.includes('Ssl_cipher')) return [[{ Value: this.options.noTls ? '' : 'TLS_AES_256_GCM_SHA384' }]];
    if (sql.startsWith('START TRANSACTION')) { this.snapshot = clone(this.tables); this.readOnly = sql.endsWith('READ ONLY'); }
    if (sql === 'ROLLBACK' && this.snapshot) { this.tables = this.snapshot; this.snapshot = null; }
    if (sql === 'COMMIT') {
      if (this.options.lostCommit === 'before') throw new Error('Synthetic disconnect before acknowledgement');
      this.snapshot = null;
      if (this.options.lostCommit === 'after') throw new Error('Synthetic disconnect after commit');
    }
    return [[]];
  }
  async execute(sql, params = []) {
    this.trace.push(sql);
    if (sql.includes('VERSION()')) return [[{ target_database: this.options.target ?? 'clrs_staging', mysql_version: '8.4.7',
      page_size: 16384, sql_mode: 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION', charset: 'utf8mb4',
      max_allowed_packet: this.options.packet ?? 1_000_000 }]];
    if (sql.includes('schema_migrations')) return [[{ version: 1 }]];
    if (sql.includes('information_schema.tables')) return [schemaNames.slice(0, this.options.tableCount ?? 42)
      .map((name) => ({ name, engine: 'InnoDB', collation: 'utf8mb4_0900_bin', format: 'Dynamic' }))];
    if (sql.includes('referential_constraints')) return [[{ total: this.options.fkCount ?? 66 }]];
    if (sql.includes('legacy_source')) return [[{ source_project: this.options.sourceMismatch ? 'wrong-synthetic-source' : source.project,
      source_database: source.database, source_bucket: source.bucket }]];
    if (sql.includes('AS auth_users')) return [[{ auth_users: this.plan.authRecords.length,
      documents: this.plan.sourceDocuments.length + (this.options.extraRawDocument ? 1 : 0), storage_objects: this.plan.storageRecords.length }]];
    if (sql.includes('FROM clrs_staging.legacy_auth_users')) return [this.plan.authRecords.filter((row) => params.includes(hash(row.uid)))
      .map((row) => ({ uid: row.uid, encoded_payload: clone(row.encodedPayload), payload_hash: row.sha256.toUpperCase() }))];
    if (sql.includes('FROM clrs_staging.legacy_documents')) return [this.plan.sourceDocuments.filter((row) => params.includes(hash(row.firebasePath)))
      .map((row) => {
        const parts = row.firebasePath.split('/');
        return { firebase_path: row.firebasePath, encoded_payload: this.options.rawPayloadMismatch && parts[0] === 'TOKENS'
          ? { ...clone(row.encodedPayload), fields: {} } : clone(row.encodedPayload), payload_hash: row.sha256.toUpperCase(),
        parent_path: parts.length > 2 ? parts.slice(0, -2).join('/') : null,
        collection_path: parts.slice(0, -1).join('/'), document_id: parts.at(-1) };
      })];
    if (sql.includes('FROM clrs_staging.legacy_storage_objects')) return [this.plan.storageRecords.filter((row) => params.includes(hash(row.name)))
      .map((row) => ({ source_bucket: row.bucket, source_path: row.name, source_metadata: clone(row.metadata), source_size: row.size,
        source_hash: row.sha256.toUpperCase(), target_hash: this.options.storageHashMismatch ? '0'.repeat(64) : row.sha256.toUpperCase(),
        target_key: row.targetKey, copied_at: this.options.storageNotCopied ? null : '2026-10-01 00:00:00.000000' }))];
    const table = /(?:FROM|INTO) clrs_staging\.([a-z_]+)/.exec(sql)?.[1];
    if (!table || !Object.hasOwn(this.tables, table)) throw new Error('Unexpected synthetic SQL');
    if (sql.startsWith('INSERT INTO')) {
      assert.equal(this.readOnly, false);
      this.insertCount++;
      if (this.options.failInsert === table) throw new Error('Synthetic insert failure');
      const columns = /\((.*?)\) VALUES/.exec(sql)[1].split(', ');
      for (let index = 0; index < params.length; index += columns.length) {
        const row = Object.fromEntries(columns.map((key, offset) => [key, jsonFields.has(key) ? JSON.parse(params[index + offset]) : params[index + offset]]));
        if (this.options.corruptInserted === table) row.legacy_raw = {};
        this.tables[table].push(row);
      }
      return [{ affectedRows: params.length / columns.length }];
    }
    if (sql.startsWith('SELECT COUNT')) return [[{ total: this.tables[table].length }]];
    if (sql.includes('LIMIT 1')) return [this.tables[table].slice(0, 1)];
    const keys = /WHERE \(([^)]+)\) IN/.exec(sql)[1].split(', ');
    const wanted = [];
    for (let index = 0; index < params.length; index += keys.length) wanted.push(JSON.stringify(params.slice(index, index + keys.length)));
    let found = this.tables[table].filter((row) => wanted.includes(JSON.stringify(keys.map((key) => row[key]))));
    if (this.options.caseCollationAlias && table === 'chat_messages' && found.length) {
      found = found.map((row) => ({ ...row, message_id: row.message_id.toLowerCase() }));
    }
    return [clone(found)];
  }
}

test('completed FULL stage binds raw/account source, inserts seven tables and syncs encrypted receipt before COMMIT', async (t) => {
  const f = await fixture(t); const db = new Database(f.plan);
  const receiptKey = randomBytes(32); const path = join(f.directory, 'receipt.clrsenc');
  const result = await stageConversationProjection(db, f.plan, confirmation(f.plan), async (record) => {
    await writeConversationReceipt(path, receiptKey, record); db.trace.push('RECEIPT_SYNC');
  });
  assert.equal(result.databaseCommitted, true); assert.equal(result.compatibilityApiReady, false);
  assert.equal(db.insertCount, 7);
  const receipt = await readConversationReceipt(path, receiptKey);
  assert.deepEqual(receipt.rawOnlyAcknowledgement, f.plan.rawOnlyAcknowledgement);
  assert.equal((await stat(path)).mode & 0o077, 0);
  assert.ok(db.trace.indexOf('RECEIPT_SYNC') < db.trace.indexOf('COMMIT'));
  assert.ok(db.trace.some((sql) => sql.includes('SERIALIZABLE')));
  assert.equal(JSON.stringify(receipt).includes('Synthetic-A'), false);
  assert.equal((await readFile(path)).includes(Buffer.from('clrs-conversation-projection-receipt')), false);
  assert.deepEqual(db.tables.chat_messages[0], f.plan.chatMessages[0]);
  const checked = await verifyConversationProjection(new Database(f.plan, {}, db.tables), f.plan, confirmation(f.plan), receipt);
  assert.equal(checked.outcome, 'present_verified'); assert.equal(checked.databaseWrites, 0);
});

test('account/profile dependency matches the existing projection exactly, retaining disable/block/claims and byte-exact UIDs', async (t) => {
  const f = await fixture(t); const profile = await prepareProfileProjection(f);
  for (const key of ['accounts', 'profiles', 'identities']) assert.deepEqual(f.plan.dependencies[key], profile[key]);
  assert.equal(f.plan.dependencies.counts.orphanProfiles, 1);
  assert.equal(f.plan.dependencies.counts.accountsWithoutProfile, 1);
  assert.equal(f.plan.dependencies.accounts[0].disabled, 1);
  assert.equal(f.plan.dependencies.accounts[0].lifecycle, 'blocked');
  assert.deepEqual(f.plan.dependencies.accounts[0].legacy_claims, { admin: true });
  assert.deepEqual(f.plan.authRecords.map((row) => row.uid), ['Synthetic-A', 'synthetic-a', 'Ä']);
  assert.equal(f.plan.dependencies.profiles[0].age, 28);
  assert.equal(f.plan.dependencies.profiles[0].height_cm, 180);
  assert.equal(f.plan.dependencies.profiles[0].region, 'Регион');
  assert.equal(f.plan.dependencies.profiles[0].has_children, 0);
});

test('metadata, unsupported account dependencies and changed exact acknowledgements fail before SQL', async (t) => {
  const metadata = await fixture(t, { metadata: true });
  const invalid = await fixture(t, { invalidDependency: true });
  const valid = await fixture(t);
  for (const [plan, values] of [[metadata.plan, confirmation(metadata.plan)], [invalid.plan, confirmation(invalid.plan)],
    [valid.plan, { ...confirmation(valid.plan), rawOnlyDocuments: 0 }],
    [valid.plan, { ...confirmation(valid.plan), rawOnlyReasonDigest: '0'.repeat(64) }],
    [valid.plan, { ...confirmation(valid.plan), dependencySha256: '0'.repeat(64) }],
    [valid.plan, { ...confirmation(valid.plan), archiveSha256: '0'.repeat(64) }]]) {
    const db = new Database(plan);
    await assert.rejects(stageConversationProjection(db, plan, values, async () => {}));
    assert.equal(db.trace.length, 0);
  }
  assert.equal(invalid.plan.dependencies.ready, false);
  assert.ok(invalid.plan.rawRecords.length > 0);
  assert.throws(() => assertConversationConfirmations({ ...valid.plan }, confirmation(valid.plan)), /Authenticated/);
});

test('excess grants, default_db access, TLS absence, wrong target and schema mismatch cause no INSERT', async (t) => {
  const f = await fixture(t);
  for (const options of [{ excessGrant: true }, { legacyAllowed: true }, { noTls: true },
    { target: 'default_db' }, { tableCount: 41 }, { fkCount: 65 }]) {
    const db = new Database(f.plan, options);
    await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => {}));
    assert.equal(db.insertCount, 0); assert.equal(db.trace.includes('COMMIT'), false);
  }
});

test('source mismatch, extra raw documents and altered untargeted typed payload fail without INSERT', async (t) => {
  const f = await fixture(t);
  for (const options of [{ sourceMismatch: true }, { extraRawDocument: true }, { rawPayloadMismatch: true }]) {
    const db = new Database(f.plan, options);
    await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => {}));
    assert.equal(db.insertCount, 0); assert.ok(db.trace.includes('ROLLBACK'));
  }
});

test('missing/extra/reassigned dependency accounts, identity JSON and profile values fail before INSERT', async (t) => {
  const f = await fixture(t);
  for (const mutate of [
    (db) => db.tables.accounts.pop(),
    (db) => db.tables.accounts.push({ ...db.tables.accounts[0], uid: 'Synthetic-extra' }),
    (db) => { db.tables.accounts[0].token_version = 1; },
    (db) => { db.tables.auth_identities[0].uid = 'synthetic-a'; },
    (db) => { db.tables.profiles[0].legacy_raw.fields.fullName.stringValue = 'Changed synthetic name'; },
    (db) => { db.tables.profiles[0].about_text = 'Unexpected normalized value'; },
  ]) {
    const db = new Database(f.plan); mutate(db);
    await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => {}));
    assert.equal(db.insertCount, 0);
  }
});

test('each of seven nonempty canonical targets is rejected without overwrite or DELETE', async (t) => {
  const f = await fixture(t);
  for (const spec of CONVERSATION_TABLES) {
    const db = new Database(f.plan); db.tables[spec.table].push(clone(f.plan[spec.property][0]));
    await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => {}), /must be empty/);
    assert.equal(db.insertCount, 0);
    assert.equal(db.trace.some((sql) => /^(DELETE|UPDATE|DROP|ALTER)\b/.test(sql)), false);
  }
});

test('completed Storage descriptor/hash/copy binding is required without retaining or serving decrypted media', async (t) => {
  const f = await fixture(t, { storage: true });
  assert.equal(f.plan.storageRecords.length, 1);
  assert.equal(Object.hasOwn(f.plan.storageRecords[0], 'bytes'), false);
  for (const options of [{ storageHashMismatch: true }, { storageNotCopied: true }]) {
    const db = new Database(f.plan, options);
    await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => {}), /Storage/);
    assert.equal(db.insertCount, 0);
  }
  const result = await stageConversationProjection(new Database(f.plan), f.plan, confirmation(f.plan), async () => {});
  assert.equal(result.databaseCommitted, true);
});

test('readback JSON or byte-exact key mismatch rolls back every INSERT and prevents receipt/COMMIT', async (t) => {
  const f = await fixture(t);
  for (const options of [{ corruptInserted: 'meeting_messages' }, { caseCollationAlias: true }, { failInsert: 'meeting_members' }]) {
    const db = new Database(f.plan, options); let receiptWritten = false;
    await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => { receiptWritten = true; }));
    assert.equal(receiptWritten, false); assert.equal(db.trace.includes('COMMIT'), false);
    assert.ok(CONVERSATION_TABLES.every((spec) => db.tables[spec.table].length === 0));
  }
});

test('receipt durability failure rolls back and never sends COMMIT', async (t) => {
  const f = await fixture(t); const db = new Database(f.plan);
  await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => { throw new Error('Synthetic fsync failure'); }));
  assert.equal(db.trace.includes('COMMIT'), false);
  assert.ok(CONVERSATION_TABLES.every((spec) => db.tables[spec.table].length === 0));
});

test('unknown COMMIT is poisoned and a fresh receipt-bound read distinguishes committed and not-committed outcomes', async (t) => {
  const f = await fixture(t);
  for (const outcome of ['before', 'after']) {
    const db = new Database(f.plan, { lostCommit: outcome }); let receipt;
    await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async (value) => { receipt = clone(value); }),
      { code: 'CONVERSATION_COMMIT_OUTCOME_UNKNOWN' });
    assert.ok(receipt);
    await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => {}), /Fresh connection/);
    const fresh = new Database(f.plan, {}, db.tables);
    const checked = await verifyConversationProjection(fresh, f.plan, confirmation(f.plan), receipt);
    assert.equal(checked.outcome, outcome === 'after' ? 'present_verified' : 'not_committed_verified');
    assert.ok(fresh.trace.includes('START TRANSACTION READ ONLY')); assert.equal(fresh.insertCount, 0);
  }
});

test('receipt verification rejects partial data, same-count altered rows, extras and wrong receipt binding', async (t) => {
  const f = await fixture(t); const staged = new Database(f.plan); let receipt;
  await stageConversationProjection(staged, f.plan, confirmation(f.plan), async (value) => { receipt = clone(value); });
  for (const mutate of [
    (tables) => { tables.meeting_members.pop(); },
    (tables) => { tables.chat_messages[0].body = 'Changed synthetic body'; },
    (tables) => { tables.meetings.push({ ...tables.meetings[0], meeting_id: 'Synthetic-extra-meeting' }); },
  ]) {
    const tables = clone(staged.tables); mutate(tables);
    await assert.rejects(verifyConversationProjection(new Database(f.plan, {}, tables), f.plan, confirmation(f.plan), receipt));
  }
  const db = new Database(f.plan, {}, staged.tables);
  await assert.rejects(verifyConversationProjection(db, f.plan, confirmation(f.plan), { ...receipt, targetRowsSha256: '0'.repeat(64) }));
  assert.equal(db.trace.length, 0);
});

test('bounded batches account for actual UTF-8/escaping and validate oversized raw rows before INSERT', async (t) => {
  const records = Array.from({ length: 203 }, (_, i) => ({ uid: `Synthetic-${i}`, body: '😀\\"'.repeat(15), legacy_raw: { fields: {} } }));
  const batches = [...conversationBatches(records, 5000)];
  assert.deepEqual(batches.flat(), records); assert.ok(batches.every((batch) => batch.length <= 100));
  for (const batch of batches) assert.ok(2048 + batch.reduce((sum, row) => sum + 128 + 32 * Object.keys(row).length
    + 2 * Buffer.byteLength(JSON.stringify(row)), 0) <= 5000);
  assert.throws(() => [...conversationBatches([{ body: '😀'.repeat(2000) }], 5000)], /exceeds/);
  const f = await fixture(t, { documents: [...fixtureDocuments(), doc('TOKENS/oversized', { text: s('😀'.repeat(2000)) })] });
  const db = new Database(f.plan, { packet: 10_000 });
  await assert.rejects(stageConversationProjection(db, f.plan, confirmation(f.plan), async () => {}), /exceeds/);
  assert.equal(db.insertCount, 0); assert.equal(db.trace.some((sql) => sql.startsWith('START TRANSACTION')), false);
});

test('CLI dry-run is FULL-only and outputs aggregate fingerprints without source values or network writes', async (t) => {
  const f = await fixture(t);
  const result = await mainConversationProjection(f.cliArgs);
  assert.equal(result.completeSource, true); assert.equal(result.databaseWrites, 0); assert.equal(result.dependencyReady, true);
  assert.equal(JSON.stringify(result).includes('Synthetic-A'), false);
  assert.deepEqual(result, conversationProjectionSummary(f.plan));
  const metadata = await fixture(t, { metadata: true });
  await assert.rejects(mainConversationProjection(metadata.cliArgs), /planning-only/);
  assert.throws(() => parseConversationArgs([...f.cliArgs, '--mode', 'stage']), /acknowledgements/);
  assert.throws(() => parseConversationArgs([...f.cliArgs, '--mode', 'dry-run', '--mode', 'verify']), /Invalid/);
  assert.throws(() => parseConversationArgs([...f.cliArgs, '--max-storage-bytes', '-1']), /bound/);
});

test('CLI preserves an existing encrypted receipt and rejects tamper/truncation', async (t) => {
  const f = await fixture(t); const key = randomBytes(32); const path = join(f.directory, 'receipt.clrsenc');
  const keyPath = join(f.directory, 'receipt.key'); await writeFile(keyPath, key, { mode: 0o600 });
  let receipt; await stageConversationProjection(new Database(f.plan), f.plan, confirmation(f.plan), async (value) => { receipt = value; });
  await writeConversationReceipt(path, key, receipt);
  const args = [...f.cliArgs, '--mode', 'stage', '--config-file', '/synthetic-unused-config', '--ca-file', '/synthetic-unused-ca',
    '--receipt-file', path, '--receipt-key-file', keyPath, '--confirm-target-db', 'clrs_staging',
    '--confirm-archive-sha256', f.plan.archiveSha256, '--confirm-projection-sha256', f.plan.projectionSha256,
    '--confirm-dependency-sha256', f.plan.dependencySha256,
    '--ack-raw-only-documents', String(f.plan.rawOnlyAcknowledgement.documents),
    '--ack-raw-only-participant-entries', String(f.plan.rawOnlyAcknowledgement.participantEntries),
    '--ack-raw-only-reason-digest', f.plan.rawOnlyAcknowledgement.reasonDigest];
  const before = await readFile(path);
  await assert.rejects(mainConversationProjection(args), /already exists/);
  assert.deepEqual(await readFile(path), before);
  const bad = join(f.directory, 'bad-receipt.clrsenc'); await writeFile(bad, before.subarray(0, before.length - 1), { mode: 0o600 });
  await assert.rejects(readConversationReceipt(bad, key));
  const tampered = Buffer.from(before); tampered[Math.floor(tampered.length / 2)] ^= 1;
  await writeFile(bad, tampered); await assert.rejects(readConversationReceipt(bad, key));
});
