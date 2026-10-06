import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { appendFile, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { credentialRecord } from '../auth-credentials-core.mjs';
import { EncryptedArchiveWriter } from '../encrypted-archive.mjs';
import { createFinalDeltaPlan, runFinalDeltaCli } from '../final-delta-plan.mjs';
import { collectArchiveManifest } from '../manifest-from-archive.mjs';
import { fingerprint } from '../manifest.mjs';
import { storageShardIdentity } from '../sealed-archive-reader.mjs';

const source = { project: 'synthetic-project', database: '(default)', bucket: 'synthetic-bucket' };
const startedAt = '2026-09-30T10:00:00Z';
const user = (id = 'private-uid-A', changes = {}) => ({ uid: id, disabled: false,
  emailVerified: false, email: `${id}@example.invalid`, providerData: [{ providerId: 'password' }],
  tokensValidAfterTime: startedAt, ...changes });
const doc = (path = 'users/private-uid-A', fields = {}, changes = {}) => ({
  path, fields, createTime: startedAt, updateTime: startedAt, ...changes });
const image = (name = 'private/photos/A.jpg', text = 'synthetic image', changes = {}) => ({
  name, bytes: Buffer.from(text), metadata: { generation: '1', metageneration: '1', ...changes } });
const string = (value) => ({ stringValue: value });
const uidId = (f, id) => fingerprint(f.hmacKey, 'uid', id);
const docId = (f, path) => fingerprint(f.hmacKey, 'document', path);
const failure = { message: 'Final delta validation failed.' };

async function fixtures(t) {
  const dir = await mkdtemp(join(tmpdir(), 'clrs-final-delta-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const archiveKey = randomBytes(32); const hmacKey = randomBytes(32);
  let generation = 0;
  const sha = async (path) => createHash('sha256').update(await readFile(path)).digest('hex');
  async function archive({ users = [user()], docs = [doc()], objects = [],
    missingParents = 0, sourceOverride = {}, manifestOverride, badStorageSha = false } = {}) {
    const archivePath = join(dir, `${++generation}.clrsenc`);
    const writer = await EncryptedArchiveWriter.create(archivePath, archiveKey);
    await writer.writeJson({ kind: 'source', format: 2, ...source, scope: 'all',
      storagePrefix: '', completeSource: true, passwordHashesIncluded: false,
      snapshotConsistent: false, finalSyncRequired: true, startedAt, ...sourceOverride });
    for (const value of users) await writer.writeJson({ kind: 'auth-user', user: value });
    for (const value of docs) await writer.writeJson({ kind: 'firestore-document', ...value });
    let bytes = 0;
    for (const value of objects) {
      bytes += value.bytes.length;
      await writer.writeJson({ kind: 'storage-object', name: value.name,
        metadata: { ...value.metadata, size: String(value.bytes.length) } });
      await writer.writeBytes(value.bytes);
      await writer.writeJson({ kind: 'storage-sha256', name: value.name,
        sha256: badStorageSha ? '0'.repeat(64) : createHash('sha256').update(value.bytes).digest('hex') });
    }
    await writer.finish({ authUsers: users.length, authListPages: 1,
      firestoreDocuments: docs.length, firestoreMissingParents: missingParents,
      firestoreReferences: docs.length + missingParents, firestoreCollections: docs.length,
      firestoreListPages: 1, storageObjects: objects.length, storageBytes: bytes, storageListPages: 1 });
    const manifest = manifestOverride ?? (await collectArchiveManifest({ archivePath, archiveKey, hmacKey })).manifest;
    return { archivePath, archiveKey, archiveSha256: await sha(archivePath), manifest };
  }
  async function credentialArchive({ users = [user()], config = { algorithm: 'BCRYPT' },
    hash = 'c3ludGhldGljLWhhc2g=', salt = 'cw==', validSince, missing = false } = {}) {
    const archivePath = join(dir, `${++generation}-credentials.clrsenc`);
    const writer = await EncryptedArchiveWriter.create(archivePath, archiveKey);
    await writer.writeJson({ kind: 'auth-credential-source', format: 1, project: source.project,
      scope: 'auth-credentials-only', completeSource: true, snapshotConsistent: false,
      standaloneLoginVerified: false, startedAt });
    await writer.writeJson({ kind: 'auth-hash-config', hashConfig: config });
    const summary = { authUsers: 0, passwordAccounts: 0, materialAvailable: 0,
      unavailablePasswordAccounts: 0, nonPasswordAccounts: 0, hashVersions: {},
      projectAlgorithm: config.algorithm, standaloneLoginVerified: false };
    for (const value of users.slice(0, missing ? 0 : undefined)) {
      const record = credentialRecord({ localId: value.uid, providerUserInfo: value.providerData,
        disabled: value.disabled, emailVerified: value.emailVerified,
        validSince: validSince ?? String(Date.parse(value.tokensValidAfterTime) / 1000),
        passwordHash: hash, salt, version: 0 }, config.algorithm);
      summary.authUsers++;
      if (record.passwordAccount) {
        summary.passwordAccounts++;
        if (record.materialAvailable) summary.materialAvailable++;
        else summary.unavailablePasswordAccounts++;
        summary.hashVersions['0'] = (summary.hashVersions['0'] ?? 0) + 1;
      } else summary.nonPasswordAccounts++;
      await writer.writeJson(record);
    }
    await writer.finish(summary);
    return { archivePath, archiveKey, archiveSha256: await sha(archivePath) };
  }
  async function bundle() {
    const directory = join(dir, `bundle-${++generation}`); await mkdir(directory, { mode: 0o700 });
    const fullSource = { kind: 'source', format: 2, ...source, scope: 'all',
      completeSource: true, passwordHashesIncluded: false, storagePrefix: '',
      snapshotConsistent: false, finalSyncRequired: true, startedAt };
    const shardCounts = (authUsers, firestoreDocuments, storageObjects, storageBytes) => ({
      authUsers, authListPages: authUsers ? 1 : 0, firestoreDocuments,
      firestoreMissingParents: 0, firestoreReferences: firestoreDocuments,
      firestoreCollections: firestoreDocuments, firestoreListPages: firestoreDocuments ? 1 : 0,
      storageObjects, storageBytes, storageListPages: storageObjects ? 1 : 0 });
    const item = image(); const metadata = { ...item.metadata, size: String(item.bytes.length) };
    const objectIdentity = storageShardIdentity(archiveKey, fullSource, item.name, metadata);
    const shards = [];
    for (const [scope, file] of [['metadata', 'metadata.clrsenc'], ['storage', `storage-${objectIdentity}.clrsenc`]]) {
      const path = join(directory, file); const writer = await EncryptedArchiveWriter.create(path, archiveKey);
      await writer.writeJson({ ...fullSource, scope, completeSource: false });
      if (scope === 'metadata') {
        await writer.writeJson({ kind: 'auth-user', user: user() });
        await writer.writeJson({ kind: 'firestore-document', ...doc(undefined,
          { avatar: string(`gs://${source.bucket}/${item.name}`) }) });
      } else {
        await writer.writeJson({ kind: 'storage-object', name: item.name, metadata });
        await writer.writeBytes(item.bytes);
        await writer.writeJson({ kind: 'storage-sha256', name: item.name,
          sha256: createHash('sha256').update(item.bytes).digest('hex') });
      }
      await writer.finish(scope === 'metadata' ? shardCounts(1, 1, 0, 0) : shardCounts(0, 0, 1, item.bytes.length));
      shards.push({ scope, file, ciphertextBytes: (await stat(path)).size, ciphertextSha256: await sha(path),
        ...(scope === 'storage' ? { objectIdentity } : {}) });
    }
    const archivePath = join(directory, 'full.clrsenc'); const writer = await EncryptedArchiveWriter.create(archivePath, archiveKey);
    await writer.writeJson({ kind: 'archive-bundle', format: 1, source: fullSource,
      summary: shardCounts(1, 1, 1, item.bytes.length), shards });
    await writer.finish({ indexShards: shards.length });
    const proof = await collectArchiveManifest({ archivePath, archiveKey, hmacKey });
    return { archivePath, archiveKey, archiveSha256: proof.archiveSha256, manifest: proof.manifest,
      ciphertextBytes: (await stat(archivePath)).size + shards.reduce((sum, shard) => sum + shard.ciphertextBytes, 0) };
  }
  const args = (before, after, extra = {}) => ({ before, after, hmacKey, expectedSource: source,
    expectedHmacKeyId: fingerprint(hmacKey, 'manifest-key', 'CLRS manifest v2'), ...extra });
  return { dir, archiveKey, hmacKey, archive, credentialArchive, bundle, sha, args };
}

test('authenticated generations produce deterministic exact typed and account/media deltas without PII', async (t) => {
  const f = await fixtures(t);
  const before = await f.archive({ users: [user(), user('private-uid-removed')],
    docs: [doc('users/private-uid-A', { status: string('active'),
      amount: { integerValue: '9007199254740992' }, avatar: string(`gs://${source.bucket}/private/photos/A.jpg`) }),
    doc('privatePosts/private-document-removed', { text: string('private-message-text') })],
    objects: [image(), image('private/photos/removed.jpg')] });
  const after = await f.archive({ users: [user(undefined, { disabled: true,
    tokensValidAfterTime: '2026-09-30T10:01:00Z' }), user('private-uid-new')],
    docs: [doc('users/private-uid-A', { status: string('blocked'),
      amount: { integerValue: '9007199254740993' }, photo: string(`gs://${source.bucket}/private/photos/A.jpg`) },
    { updateTime: '2026-09-30T10:01:00Z' }), doc('privatePosts/private-document-new')],
    objects: [image(undefined, 'new synthetic image', { metageneration: '2', firebaseStorageDownloadTokens: 'private-download-token' }),
      image('private/photos/new.jpg')] });
  // Schema-v2's SDK Number normalization cannot see this int64 increment.
  const plan = await createFinalDeltaPlan(f.args(before, after));
  assert.deepEqual(plan, await createFinalDeltaPlan(f.args(before, after)));
  assert.deepEqual(plan.changes.auth.counts, { create: 1, update: 1, missingCandidate: 1, unchanged: 0 });
  assert.deepEqual(plan.changes.firestore.counts, { create: 1, update: 1, missingCandidate: 1, unchanged: 0 });
  assert.deepEqual(plan.changes.storage.counts, { create: 1, update: 1, missingCandidate: 1, unchanged: 0 });
  const account = plan.changes.auth.entries.find((row) => row.id === uidId(f, 'private-uid-A'));
  assert.ok(account.reasons.includes('accountDisabled'));
  assert.ok(account.reasons.includes('tokenRevocationChanged'));
  const profile = plan.changes.firestore.entries.find((row) => row.id === docId(f, 'users/private-uid-A'));
  for (const flag of ['typedContentChanged', 'mediaBindingsChanged', 'accountLifecycleChanged', 'updateTimeChanged']) {
    assert.ok(profile.reasons.includes(flag), flag);
  }
  assert.equal(plan.changes.password.status, 'unknown');
  assert.ok(plan.blockers.includes('credentials_unknown'));
  assert.equal(plan.cutoverReady, false); assert.equal(plan.automaticApply, false);
  for (const section of Object.values(plan.changes)) {
    for (const row of section.entries.filter((row) => row.change === 'missingCandidate')) assert.equal(row.deletionAuthorized, false);
  }
  const json = JSON.stringify(plan);
  for (const secret of [source.project, source.bucket, 'private-uid', 'privatePosts', 'private/photos',
    'private-message-text', 'example.invalid', 'private-download-token', f.archiveKey.toString('hex'), f.hmacKey.toString('hex')]) {
    assert.equal(json.includes(secret), false, secret);
  }
});

test('an absent parent never removes an independently present descendant; consistent labels cannot authorize cutover', async (t) => {
  const f = await fixtures(t); const descendant = doc('privatePosts/private-parent/comments/private-child', { text: string('still present') });
  const before = await f.archive({ docs: [doc('privatePosts/private-parent'), descendant] });
  const after = await f.archive({ docs: [descendant], missingParents: 1,
    sourceOverride: { snapshotConsistent: true, finalSyncRequired: false } });
  const plan = await createFinalDeltaPlan(f.args(before, after));
  assert.equal(plan.changes.firestore.counts.unchanged, 1);
  assert.deepEqual(plan.changes.firestore.entries.map((row) => row.id), [docId(f, 'privatePosts/private-parent')]);
  assert.equal(plan.deletionAuthorized, false); assert.equal(plan.cutoverReady, false);
  assert.ok(plan.blockers.includes('source_write_barrier_unproven'));
  assert.ok(plan.blockers.includes('final_consistent_coverage_unproven'));
  assert.equal(plan.prerequisites.sourceWriteBarrier, 'external_trusted_proof_required');
});

test('paired credential archives detect verifier/config changes while preserving disabled/revocation generation checks', async (t) => {
  const f = await fixtures(t);
  const a = user(); const b = user(undefined, { disabled: true, tokensValidAfterTime: '2026-09-30T10:01:00Z' });
  const before = await f.archive({ users: [a] }); const after = await f.archive({ users: [b] });
  before.credentials = await f.credentialArchive({ users: [a] });
  after.credentials = await f.credentialArchive({ users: [b], config: { algorithm: 'BCRYPT', privateConfigMarker: 'private-config-value' },
    hash: 'Y2hhbmdlZC1zeW50aGV0aWMtaGFzaA==' });
  const plan = await createFinalDeltaPlan(f.args(before, after));
  assert.equal(plan.changes.password.status, 'compared');
  assert.equal(plan.changes.password.hashConfigurationChanged, true);
  assert.ok(plan.changes.password.entries[0].reasons.includes('passwordVerifierChanged'));
  assert.ok(plan.blockers.includes('password_configuration_changed'));
  assert.equal(plan.blockers.includes('credentials_unknown'), false);
  assert.equal(JSON.stringify(plan).includes('private-config-value'), false);
  assert.equal(JSON.stringify(plan).includes('Y2hhbmdlZC1zeW50aGV0aWMtaGFzaA=='), false);
  for (const invalid of [await f.credentialArchive({ users: [a] }),
    await f.credentialArchive({ users: [b], validSince: '1' }),
    await f.credentialArchive({ users: [b], missing: true })]) {
    await assert.rejects(createFinalDeltaPlan(f.args(before, { ...after, credentials: invalid })), failure);
  }
  await assert.rejects(createFinalDeltaPlan(f.args(before, { ...after, credentials: undefined })), failure);
  const epoch = user(undefined, { tokensValidAfterTime: '1970-01-01T00:00:00Z' });
  const epochBefore = await f.archive({ users: [epoch] }); const epochAfter = await f.archive({ users: [epoch] });
  epochBefore.credentials = await f.credentialArchive({ users: [epoch] });
  epochAfter.credentials = await f.credentialArchive({ users: [epoch] });
  assert.equal((await createFinalDeltaPlan(f.args(epochBefore, epochAfter))).changes.password.counts.unchanged, 1);
});

test('missing password material and unresolved media bindings remain explicit blockers', async (t) => {
  const f = await fixtures(t); const before = await f.archive();
  const after = await f.archive({ docs: [doc(undefined, { avatar: string(`gs://${source.bucket}/private/photos/absent.jpg`) })] });
  before.credentials = await f.credentialArchive();
  after.credentials = await f.credentialArchive({ hash: Buffer.from('REDACTED').toString('base64') });
  const plan = await createFinalDeltaPlan(f.args(before, after));
  assert.ok(plan.blockers.includes('password_material_unavailable'));
  assert.ok(plan.blockers.includes('unresolved_media_bindings'));
  assert.deepEqual(plan.mediaBindings, { unresolvedBefore: 0, unresolvedAfter: 1 });
});

test('partial, mismatched, modified and unpinned generations are rejected without exposing private paths', async (t) => {
  const f = await fixtures(t); const before = await f.archive(); const after = await f.archive();
  for (const sourceOverride of [{ scope: 'metadata', completeSource: false },
    { completeSource: false }, { project: 'different-project' }]) {
    const invalid = await f.archive({ sourceOverride, manifestOverride: after.manifest });
    await assert.rejects(createFinalDeltaPlan(f.args(before, invalid)), failure);
  }
  await assert.rejects(createFinalDeltaPlan(f.args(before, { ...after, archiveSha256: '0'.repeat(64) })), failure);
  await assert.rejects(createFinalDeltaPlan(f.args(before, after, { hmacKey: randomBytes(32) })), failure);
  const changedManifest = structuredClone(after.manifest);
  changedManifest.firestore.documents[0].content = '0'.repeat(64);
  await assert.rejects(createFinalDeltaPlan(f.args(before, { ...after, manifest: changedManifest })), failure);
  const changedAuth = structuredClone(after.manifest); changedAuth.auth.users[0].disabled = true;
  await assert.rejects(createFinalDeltaPlan(f.args(before, { ...after, manifest: changedAuth })), failure);
  const corrupt = await f.archive({ objects: [image()], manifestOverride: after.manifest, badStorageSha: true });
  await assert.rejects(createFinalDeltaPlan(f.args(before, corrupt)), failure);
  await appendFile(after.archivePath, Buffer.from('trailing private input'));
  await assert.rejects(createFinalDeltaPlan(f.args(before, after)), failure);
  await assert.rejects(createFinalDeltaPlan(f.args(before, { ...after, archivePath: join(f.dir, 'private-missing-file') })), failure);
});

test('bounded counts, metadata, index, ciphertext, objects and plan limits fail closed', async (t) => {
  const f = await fixtures(t); const before = await f.archive({ users: [user(), user('private-uid-B')] });
  const after = await f.archive({ users: [user(), user('private-uid-B')],
    docs: [doc(undefined, { text: string('changed text') })], objects: [image()] });
  for (const limits of [{ maxAuthUsers: 1 }, { maxMetadataBytes: 16 }, { maxIndexBytes: 16 },
    { maxArchiveCipherBytes: 16 }, { maxObjectBytes: 1 }, { maxPlanBytes: 16 }, { maxChanges: 1 },
    { maxArchiveCipherBytes: 9_000_000_001 }, { unknownLimit: 1 }]) {
    await assert.rejects(createFinalDeltaPlan(f.args(before, after, { limits })), failure);
  }
  const deep = {}; let next = deep;
  for (let index = 0; index < 70; index++) { next.child = {}; next = next.child; }
  await assert.rejects(createFinalDeltaPlan(f.args(before, { ...after, manifest: deep })), failure);
});

test('sealed bundle uses authenticated composite SHA and enforces the combined ciphertext cap before shard reads', async (t) => {
  const f = await fixtures(t); const before = await f.archive(); const after = await f.bundle();
  assert.notEqual(after.archiveSha256, await f.sha(after.archivePath));
  const plan = await createFinalDeltaPlan(f.args(before, after));
  assert.equal(plan.generations.after.archiveSha256, after.archiveSha256);
  assert.equal(plan.mediaBindings.unresolvedAfter, 0);
  assert.ok(plan.blockers.includes('source_final_sync_required'));
  const cap = Math.max((await stat(before.archivePath)).size, (await stat(after.archivePath)).size);
  assert.ok(cap < after.ciphertextBytes);
  await assert.rejects(createFinalDeltaPlan(f.args(before, after, { limits: { maxArchiveCipherBytes: cap } })), failure);
  await assert.rejects(createFinalDeltaPlan(f.args(before, { ...after, archiveSha256: await f.sha(after.archivePath) })), failure);
});

test('CLI publishes only a complete new 0600 redacted file, never overwriting sources or an existing plan', async (t) => {
  const f = await fixtures(t); const before = await f.archive();
  const after = await f.archive({ users: [user(undefined, { disabled: true })] });
  const keyFile = join(f.dir, 'archive.key'); const hmacKeyFile = join(f.dir, 'hmac.key');
  await writeFile(keyFile, f.archiveKey, { mode: 0o600 }); await writeFile(hmacKeyFile, f.hmacKey, { mode: 0o600 });
  const config = { format: 1, expectedSource: source,
    expectedHmacKeyId: fingerprint(f.hmacKey, 'manifest-key', 'CLRS manifest v2'), hmacKeyFile };
  for (const [name, value] of Object.entries({ before, after })) {
    const manifestFile = join(f.dir, `${name}-manifest.json`);
    await writeFile(manifestFile, JSON.stringify(value.manifest), { mode: 0o600 });
    config[name] = { archivePath: value.archivePath, archiveSha256: value.archiveSha256, keyFile, manifestFile };
  }
  const configFile = join(f.dir, 'config.json'); const out = join(f.dir, 'delta-plan.json');
  await writeFile(configFile, JSON.stringify(config), { mode: 0o600 });
  const originalBefore = await readFile(before.archivePath);
  const summary = await runFinalDeltaCli(['--config', configFile, '--out', out]);
  const output = await readFile(out); const plan = JSON.parse(output);
  assert.equal((await stat(out)).mode & 0o777, 0o600);
  assert.equal(plan.planSha256, summary.planSha256); assert.equal(summary.cutoverReady, false);
  await assert.rejects(runFinalDeltaCli(['--config', configFile, '--out', out]), failure);
  assert.deepEqual(await readFile(out), output);
  await assert.rejects(runFinalDeltaCli(['--config', configFile, '--out', before.archivePath]), failure);
  assert.deepEqual(await readFile(before.archivePath), originalBefore);
  assert.equal((await readdir(f.dir)).some((name) => name.includes('.partial-')), false);
  await assert.rejects(runFinalDeltaCli(['--config', join(f.dir, 'private-missing-config'), '--out', out]), failure);
});
