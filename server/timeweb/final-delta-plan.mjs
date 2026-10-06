#!/usr/bin/env node
// Local dry-run only. No SDK, SQL connection, target write or cutover switch.
import { createHash, randomBytes } from 'node:crypto';
import { link, open, readFile, stat, unlink } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { credentialRecord, validateHashConfig } from './auth-credentials-core.mjs';
import { readEncryptedArchive, readPhysicalEncryptedArchive } from './encrypted-archive.mjs';
import { validateExportPaths } from './export-paths.mjs';
import { privateInput } from './import-cli-common.mjs';
import { payloadHash, scanImportArchive } from './import-core.mjs';
import { decodeArchiveFields } from './manifest-from-archive.mjs';
import { firebaseStorageObject, fingerprint, validateManifest } from './manifest.mjs';
import { verifyExportManifest } from './verify-export-manifest.mjs';

const ERROR = 'Final delta validation failed.';
const HASH = /^[a-f0-9]{64}$/;
const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const integer = (value) => Number.isSafeInteger(value) && value >= 0;

export const FINAL_DELTA_LIMITS = Object.freeze({
  maxAuthUsers: 10_000, maxFirestoreDocuments: 100_000,
  maxStorageObjects: 10_000, maxStorageBytes: 7_200_000_000,
  maxObjectBytes: 64_000_000, maxArchiveCipherBytes: 9_000_000_000,
  maxMetadataBytes: 256_000_000, maxIndexBytes: 64_000_000,
  maxManifestBytes: 32_000_000, maxCredentialBytes: 20_000_000,
  maxReferences: 150_000, maxChanges: 150_000, maxPlanBytes: 64_000_000,
});

function limits(input = {}) {
  if (!object(input)) throw new Error(ERROR);
  const result = { ...FINAL_DELTA_LIMITS };
  for (const [name, value] of Object.entries(input)) {
    if (!(name in FINAL_DELTA_LIMITS) || !Number.isSafeInteger(value)
        || value < 1 || value > FINAL_DELTA_LIMITS[name]) throw new Error(ERROR);
    result[name] = value;
  }
  return result;
}

// Check depth and a conservative byte budget before recursion/JSON.stringify.
// Frames themselves are already capped at 4 MiB by the shared archive reader.
function boundedJson(value, maximum) {
  const stack = [[value, 0]];
  const seen = new Set();
  let budget = 0;
  while (stack.length) {
    const [item, depth] = stack.pop();
    if (depth > 64) throw new Error(ERROR);
    if (item !== null && typeof item === 'object') {
      if (seen.has(item)) throw new Error(ERROR);
      seen.add(item); budget += 2;
      for (const [name, child] of Object.entries(item)) {
        budget += Buffer.byteLength(name) + 4;
        stack.push([child, depth + 1]);
      }
    } else if (typeof item === 'string') budget += Buffer.byteLength(item) + 2;
    else if (item === null || ['number', 'boolean'].includes(typeof item)) budget += 24;
    else throw new Error(ERROR);
    if (budget > maximum) throw new Error(ERROR);
  }
  const json = JSON.stringify(value);
  if (Buffer.byteLength(json) > maximum) throw new Error(ERROR);
  return json;
}

function uid(value) {
  if (typeof value !== 'string' || !value || value.includes('\0')
      || Buffer.byteLength(value) > 191) throw new Error(ERROR);
}

function timestamp(value) {
  if (typeof value !== 'string' || value.length > 64 || !Number.isFinite(Date.parse(value))) {
    throw new Error(ERROR);
  }
  return value;
}

function revocation(value, credential = false) {
  if (value === null || value === undefined || (credential && (value === 0 || value === '0'))) {
    return null;
  }
  const seconds = credential && ((typeof value === 'string' && /^\d{1,16}$/.test(value))
    || integer(value)) ? Number(value) : !credential && typeof value === 'string'
      ? Date.parse(value) / 1000 : NaN;
  if (!Number.isSafeInteger(seconds) || seconds < 0) throw new Error(ERROR);
  return seconds === 0 ? null : seconds;
}

// Schema-v2 manifest compatibility only. Delta content uses exact typed payloads
// separately, so int64 changes never disappear through this Number conversion.
function manifestValue(value) {
  if (value === null || value === undefined) return value ?? null;
  if (Buffer.isBuffer(value)) return { type: 'bytes', value: value.toString('base64') };
  if (Array.isArray(value)) return value.map(manifestValue);
  if (typeof value === 'number' && !Number.isFinite(value)) return { type: 'number', value: String(value) };
  if (typeof value !== 'object') return value;
  if (Number.isInteger(value.seconds) && Number.isInteger(value.nanoseconds)
      && typeof value.toDate === 'function') {
    return { type: 'timestamp', seconds: value.seconds, nanoseconds: value.nanoseconds };
  }
  if (typeof value.latitude === 'number' && typeof value.longitude === 'number') {
    return { type: 'geopoint', latitude: value.latitude, longitude: value.longitude };
  }
  if (typeof value.path === 'string' && value.firestore) return { type: 'reference', path: value.path };
  return Object.fromEntries(Object.keys(value).sort().map((name) => [name, manifestValue(value[name])]));
}

function mediaBindings(data, bucket, key, cap) {
  const bindings = new Set();
  const references = new Set();
  const stack = [[data, []]];
  while (stack.length) {
    const [value, location] = stack.pop();
    if (typeof value === 'string') {
      const name = firebaseStorageObject(value, bucket);
      if (name !== null) {
        const objectId = fingerprint(key, 'object', name);
        references.add(objectId);
        bindings.add(fingerprint(key, 'media-binding', JSON.stringify([location, objectId])));
        if (bindings.size > cap.maxReferences) throw new Error(ERROR);
      }
    } else if (Array.isArray(value)) value.forEach((item, index) => stack.push([item, [...location, index]]));
    else if (value && typeof value === 'object' && !Buffer.isBuffer(value)
        && !value.firestore && typeof value.toDate !== 'function') {
      for (const [name, item] of Object.entries(value)) stack.push([item, [...location, name]]);
    }
  }
  return { bindings: [...bindings].sort(), references };
}

async function boundedFile(path, maximum) {
  const safe = await privateInput(path, 'Input');
  const info = await stat(safe);
  if (info.size > maximum) throw new Error(ERROR);
  return safe;
}

async function preflightArchive(path, key, maximum) {
  const safe = await boundedFile(path, maximum);
  // The existing importer exposes a composite digest but no ciphertext byte
  // counter. Authenticate the small sealed index before accepting shard sizes.
  const frames = readPhysicalEncryptedArchive(safe, key);
  try {
    const first = await frames.next();
    if (first.done || first.value.type !== 'json') throw new Error(ERROR);
    const descriptor = first.value.record;
    if (descriptor.kind === 'archive-bundle') {
      if (!Array.isArray(descriptor.shards) || descriptor.shards.length > 10001) throw new Error(ERROR);
      let bytes = (await stat(safe)).size;
      for (const shard of descriptor.shards) {
        if (!integer(shard.ciphertextBytes) || shard.ciphertextBytes < 16) throw new Error(ERROR);
        bytes += shard.ciphertextBytes;
        if (!Number.isSafeInteger(bytes) || bytes > maximum) throw new Error(ERROR);
      }
      const end = await frames.next();
      if (end.done || end.value.type !== 'json' || end.value.record?.kind !== 'end'
          || !(await frames.next()).done) throw new Error(ERROR);
    }
  } finally { await frames.return(); }
  return safe;
}

async function snapshot(input, expectedSource, hmacKey, expectedHmacKeyId, cap) {
  if (!object(input) || !HASH.test(input.archiveSha256)
      || !Buffer.isBuffer(input.archiveKey) || input.archiveKey.length !== 32) throw new Error(ERROR);
  const archiveKey = Buffer.from(input.archiveKey);
  try {
    const archivePath = await preflightArchive(input.archivePath, archiveKey, cap.maxArchiveCipherBytes);
    const manifest = JSON.parse(boundedJson(input.manifest, cap.maxManifestBytes));
    validateManifest(manifest);
    if (manifest.hmacKeyId !== expectedHmacKeyId
        || manifest.auth.count > cap.maxAuthUsers || manifest.firestore.count > cap.maxFirestoreDocuments
        || manifest.storage.count > cap.maxStorageObjects || manifest.storage.bytes > cap.maxStorageBytes) {
      throw new Error(ERROR);
    }
    const authRows = new Map(manifest.auth.users.map((row) => [row.uid, row]));
    const docRows = new Map(manifest.firestore.documents.map((row) => [row.path, row]));
    const result = { auth: new Map(), firestore: new Map(), storage: new Map(),
      references: new Set(), source: null, summary: null, archiveSha256: null };
    let metadataBytes = 0;
    let indexBytes = 0;
    function metadata(value) {
      metadataBytes += Buffer.byteLength(boundedJson(value, cap.maxMetadataBytes));
      if (metadataBytes > cap.maxMetadataBytes) throw new Error(ERROR);
    }
    function put(section, id, value) {
      indexBytes += Buffer.byteLength(JSON.stringify({ id, ...value }));
      if (indexBytes > cap.maxIndexBytes) throw new Error(ERROR);
      result[section].set(id, value);
    }
    const verified = await verifyExportManifest({ archivePath, archiveKey, manifest, hmacKey,
      scanArchive: async (callbacks) => {
        const scanned = await scanImportArchive({ ...callbacks, limits: {
          maxAuthUsers: cap.maxAuthUsers, maxFirestoreDocuments: cap.maxFirestoreDocuments,
          maxStorageObjects: cap.maxStorageObjects, maxStorageBytes: cap.maxStorageBytes,
          maxObjectBytes: cap.maxObjectBytes,
        }, onAuth: async (row) => {
          metadata(row.encodedPayload); uid(row.uid);
          const user = row.encodedPayload;
          if (typeof user.disabled !== 'boolean' || typeof user.emailVerified !== 'boolean'
              || !Array.isArray(user.providerData ?? [])) throw new Error(ERROR);
          const providers = (user.providerData ?? []).map((provider) => {
            if (!object(provider) || typeof provider.providerId !== 'string' || !provider.providerId) {
              throw new Error(ERROR);
            }
            return provider.providerId;
          }).sort();
          if (new Set(providers).size !== providers.length
              || (user.email !== undefined && typeof user.email !== 'string')) throw new Error(ERROR);
          const id = fingerprint(hmacKey, 'uid', row.uid);
          const claims = fingerprint(hmacKey, 'claims', JSON.stringify(manifestValue(user.customClaims ?? {})));
          const email = user.email ? fingerprint(hmacKey, 'email', user.email.trim().toLowerCase()) : null;
          const expected = authRows.get(id);
          if (!expected || !isDeepStrictEqual({ uid: id, email,
            disabled: user.disabled, emailVerified: user.emailVerified, providers, claims },
          { uid: expected.uid, email: expected.email, disabled: expected.disabled,
            emailVerified: expected.emailVerified, providers: expected.providers, claims: expected.claims })) {
            throw new Error(ERROR);
          }
          put('auth', id, { digest: fingerprint(hmacKey, 'auth-payload', row.sha256),
            disabled: user.disabled, emailVerified: user.emailVerified,
            providers: fingerprint(hmacKey, 'providers', JSON.stringify(providers)),
            claims, email, revocation: revocation(user.tokensValidAfterTime) });
          await callbacks.onAuth?.(row);
        }, onDocument: async (row) => {
          metadata(row.encodedPayload);
          timestamp(row.encodedPayload.createTime); timestamp(row.encodedPayload.updateTime);
          const data = decodeArchiveFields(row.encodedPayload.fields);
          const id = fingerprint(hmacKey, 'document', row.firebasePath);
          if (fingerprint(hmacKey, 'document-content', JSON.stringify(manifestValue(data)))
              !== docRows.get(id)?.content) throw new Error(ERROR);
          const media = mediaBindings(data, expectedSource.bucket, hmacKey, cap);
          for (const binding of media.references) {
            if (!result.references.has(binding)) {
              indexBytes += 64; result.references.add(binding);
              if (indexBytes > cap.maxIndexBytes || result.references.size > cap.maxReferences) throw new Error(ERROR);
            }
          }
          const parts = row.firebasePath.split('/');
          const profile = parts.length === 2 && parts[0] === 'users';
          if (profile) uid(parts[1]);
          put('firestore', id, { digest: fingerprint(hmacKey, 'document-payload', row.sha256),
            content: fingerprint(hmacKey, 'typed-content', payloadHash(row.encodedPayload.fields)),
            created: fingerprint(hmacKey, 'created', row.encodedPayload.createTime),
            updated: fingerprint(hmacKey, 'updated', row.encodedPayload.updateTime),
            bindings: fingerprint(hmacKey, 'bindings', JSON.stringify(media.bindings)),
            lifecycle: profile ? fingerprint(hmacKey, 'lifecycle', payloadHash(row.encodedPayload.fields.status ?? null)) : null });
          await callbacks.onDocument?.(row);
        }, onObject: async (row) => {
          metadata(row.metadata);
          const id = fingerprint(hmacKey, 'object', row.name);
          put('storage', id, { content: fingerprint(hmacKey, 'object-bytes', row.sha256),
            metadata: fingerprint(hmacKey, 'object-metadata', payloadHash(row.metadata)) });
          await callbacks.onObject?.(row);
        } });
        if (['project', 'database', 'bucket'].some((name) => scanned.source[name] !== expectedSource[name])
            || scanned.summary.firestoreReferences > cap.maxReferences) throw new Error(ERROR);
        metadata(scanned.source); metadata(scanned.summary);
        result.source = { snapshotConsistent: scanned.source.snapshotConsistent === true,
          finalSyncRequired: scanned.source.finalSyncRequired !== false };
        result.summary = scanned.counts;
        return scanned;
      } });
    if (!verified.equalToInventory || verified.archiveSha256 !== input.archiveSha256) throw new Error(ERROR);
    result.archiveSha256 = verified.archiveSha256;
    return result;
  } finally { archiveKey.fill(0); }
}

async function credentials(input, generation, project, hmacKey, cap) {
  if (!object(input) || !HASH.test(input.archiveSha256)
      || !Buffer.isBuffer(input.archiveKey) || input.archiveKey.length !== 32) throw new Error(ERROR);
  const archiveKey = Buffer.from(input.archiveKey);
  try {
    const archivePath = await boundedFile(input.archivePath, cap.maxCredentialBytes);
    const cipher = createHash('sha256');
    const users = new Map();
    let state = 'source'; let configDigest; let summary; let indexBytes = 0; let decodedBytes = 0;
    for await (const frame of readEncryptedArchive(archivePath, archiveKey, {
      onCiphertext: (bytes) => cipher.update(bytes),
    })) {
      if (frame.type !== 'json') throw new Error(ERROR);
      const record = frame.record;
      decodedBytes += Buffer.byteLength(boundedJson(record, cap.maxCredentialBytes));
      if (decodedBytes > cap.maxCredentialBytes) throw new Error(ERROR);
      if (state === 'source') {
        if (record.kind !== 'auth-credential-source' || record.format !== 1
            || record.scope !== 'auth-credentials-only' || record.project !== project
            || record.completeSource !== true || record.standaloneLoginVerified !== false) throw new Error(ERROR);
        state = 'config';
      } else if (state === 'config') {
        if (record.kind !== 'auth-hash-config') throw new Error(ERROR);
        const config = validateHashConfig(record.hashConfig);
        configDigest = fingerprint(hmacKey, 'password-config', payloadHash(config));
        summary = { authUsers: 0, passwordAccounts: 0, materialAvailable: 0,
          unavailablePasswordAccounts: 0, nonPasswordAccounts: 0, hashVersions: {},
          projectAlgorithm: config.algorithm, standaloneLoginVerified: false };
        state = 'users';
      } else if (state === 'users' && record.kind === 'auth-credential') {
        uid(record.uid);
        const rebuilt = credentialRecord({ localId: record.uid,
          providerUserInfo: record.providers?.map((providerId) => ({ providerId })),
          passwordHash: record.material?.passwordHash ?? undefined,
          salt: record.material?.passwordSalt ?? undefined,
          version: record.material?.passwordVersion ?? undefined, disabled: record.disabled,
          emailVerified: record.emailVerified, validSince: record.validSince }, summary.projectAlgorithm);
        const id = fingerprint(hmacKey, 'uid', record.uid);
        const account = generation.auth.get(id);
        if (!isDeepStrictEqual(record, rebuilt) || users.has(id) || !account
            || ++summary.authUsers > cap.maxAuthUsers || account.disabled !== record.disabled
            || account.emailVerified !== record.emailVerified
            || account.providers !== fingerprint(hmacKey, 'providers', JSON.stringify([...record.providers].sort()))
            || account.revocation !== revocation(record.validSince, true)) throw new Error(ERROR);
        if (record.passwordAccount) {
          summary.passwordAccounts++;
          if (record.materialAvailable) summary.materialAvailable++;
          else summary.unavailablePasswordAccounts++;
          const version = record.material.passwordVersion === null ? 'unknown' : String(record.material.passwordVersion);
          summary.hashVersions[version] = (summary.hashVersions[version] ?? 0) + 1;
        } else summary.nonPasswordAccounts++;
        const value = { material: fingerprint(hmacKey, 'password-material', payloadHash(record.material)),
          passwordAccount: record.passwordAccount, materialAvailable: record.materialAvailable };
        indexBytes += Buffer.byteLength(JSON.stringify({ id, ...value }));
        if (indexBytes > cap.maxIndexBytes) throw new Error(ERROR);
        users.set(id, value);
      } else if (state === 'users' && record.kind === 'end') {
        if (!isDeepStrictEqual(record.summary, summary) || users.size !== generation.auth.size) throw new Error(ERROR);
        state = 'complete';
      } else throw new Error(ERROR);
    }
    if (state !== 'complete' || cipher.digest('hex') !== input.archiveSha256) throw new Error(ERROR);
    return { users, configDigest, archiveSha256: input.archiveSha256,
      unavailablePasswordAccounts: summary.unavailablePasswordAccounts };
  } finally { archiveKey.fill(0); }
}

function compare(before, after, reasons, cap) {
  const entries = []; const counts = { create: 0, update: 0, missingCandidate: 0, unchanged: 0 };
  for (const id of [...new Set([...before.keys(), ...after.keys()])].sort()) {
    const previous = before.get(id); const next = after.get(id);
    if (!previous || !next) {
      const change = previous ? 'missingCandidate' : 'create'; counts[change]++;
      entries.push({ id, change, reasons: [], ...(previous ? { deletionAuthorized: false } : {}) });
    } else {
      const changes = reasons(previous, next).sort();
      if (changes.length) { counts.update++; entries.push({ id, change: 'update', reasons: changes }); }
      else counts.unchanged++;
    }
    if (entries.length > cap.maxChanges) throw new Error(ERROR);
  }
  return { counts, entries };
}

const changed = (before, after, fields) => fields.filter(([field]) => before[field] !== after[field]).map(([, reason]) => reason);

/** Validate both immutable generations; return a redacted, non-executable plan. */
export async function createFinalDeltaPlan({ before, after, expectedSource,
  hmacKey, expectedHmacKeyId, limits: requestedLimits } = {}) {
  let localHmac;
  try {
    const cap = limits(requestedLimits);
    if (!object(expectedSource) || ['project', 'database', 'bucket'].some((name) =>
      typeof expectedSource[name] !== 'string' || !expectedSource[name] || expectedSource[name].length > 1024)
      || !Buffer.isBuffer(hmacKey) || hmacKey.length < 32 || hmacKey.length > 4096
      || !HASH.test(expectedHmacKeyId) || !object(before) || !object(after)
      || before.archiveSha256 === after.archiveSha256 || (!!before.credentials !== !!after.credentials)) throw new Error(ERROR);
    const source = { project: expectedSource.project, database: expectedSource.database, bucket: expectedSource.bucket };
    localHmac = Buffer.from(hmacKey);
    if (fingerprint(localHmac, 'manifest-key', 'CLRS manifest v2') !== expectedHmacKeyId) throw new Error(ERROR);
    const previous = await snapshot(before, source, localHmac, expectedHmacKeyId, cap);
    const next = await snapshot(after, source, localHmac, expectedHmacKeyId, cap);
    let previousCredentials; let nextCredentials;
    if (before.credentials) {
      previousCredentials = await credentials(before.credentials, previous, source.project, localHmac, cap);
      nextCredentials = await credentials(after.credentials, next, source.project, localHmac, cap);
    }
    const auth = compare(previous.auth, next.auth, (a, b) => changed(a, b, [
      ['digest', 'authMetadataChanged'], ['disabled', b.disabled ? 'accountDisabled' : 'accountEnabled'],
      ['emailVerified', 'emailVerificationChanged'], ['providers', 'providersChanged'],
      ['claims', 'claimsChanged'], ['email', 'emailChanged'], ['revocation', 'tokenRevocationChanged'],
    ]), cap);
    const firestore = compare(previous.firestore, next.firestore, (a, b) => changed(a, b, [
      ['digest', 'documentPayloadChanged'], ['content', 'typedContentChanged'],
      ['created', 'createTimeChanged'], ['updated', 'updateTimeChanged'],
      ['bindings', 'mediaBindingsChanged'], ['lifecycle', 'accountLifecycleChanged'],
    ]), cap);
    const storage = compare(previous.storage, next.storage, (a, b) => changed(a, b, [
      ['content', 'objectBytesChanged'], ['metadata', 'objectMetadataChanged'],
    ]), cap);
    const password = previousCredentials ? {
      status: 'compared', hashConfigurationChanged: previousCredentials.configDigest !== nextCredentials.configDigest,
      ...compare(previousCredentials.users, nextCredentials.users, (a, b) => changed(a, b, [
        ['material', 'passwordVerifierChanged'], ['passwordAccount', 'passwordAccountChanged'],
        ['materialAvailable', 'passwordMaterialAvailabilityChanged'],
      ]), cap),
    } : { status: 'unknown', hashConfigurationChanged: null, counts: null, entries: [] };
    if ([auth, firestore, storage, password].reduce((sum, section) => sum + section.entries.length, 0) > cap.maxChanges) {
      throw new Error(ERROR);
    }
    const blockers = ['source_write_barrier_unproven', 'final_consistent_coverage_unproven',
      'reviewed_delta_application_required', 'target_reconciliation_required'];
    if (!previousCredentials) blockers.push('credentials_unknown');
    else {
      if (password.hashConfigurationChanged) blockers.push('password_configuration_changed');
      if (nextCredentials.unavailablePasswordAccounts) blockers.push('password_material_unavailable');
    }
    if (!next.source.snapshotConsistent || next.source.finalSyncRequired) blockers.push('source_final_sync_required');
    if ([auth, firestore, storage].some((section) => section.counts.missingCandidate > 0)) blockers.push('absence_requires_independent_review');
    const unresolvedBefore = [...previous.references].filter((id) => !previous.storage.has(id)).length;
    const unresolvedAfter = [...next.references].filter((id) => !next.storage.has(id)).length;
    if (unresolvedAfter) blockers.push('unresolved_media_bindings');
    const plan = { format: 1, kind: 'clrs-final-delta-dry-run', automaticApply: false,
      cutoverReady: false, deletionAuthorized: false, hmacKeyId: expectedHmacKeyId,
      source: Object.fromEntries(Object.entries(source).map(([name, value]) => [name, fingerprint(localHmac, name, value)])),
      generations: { before: { archiveSha256: previous.archiveSha256, counts: previous.summary,
        labels: previous.source, credentialsArchiveSha256: previousCredentials?.archiveSha256 ?? null },
      after: { archiveSha256: next.archiveSha256, counts: next.summary,
        labels: next.source, credentialsArchiveSha256: nextCredentials?.archiveSha256 ?? null } },
      prerequisites: { sourceWriteBarrier: 'external_trusted_proof_required',
        finalConsistentCoverage: 'external_trusted_proof_required',
        deltaApplication: 'separate_reviewed_implementation_required',
        targetReconciliation: 'independent_verification_required' },
      blockers: blockers.sort(), changes: { auth, firestore, storage, password },
      mediaBindings: { unresolvedBefore, unresolvedAfter } };
    // No raw payload hash, identifier, source path or verifier leaves this API.
    const json = boundedJson(plan, cap.maxPlanBytes);
    const completed = { ...plan, planSha256: createHash('sha256').update(json).digest('hex') };
    if (Buffer.byteLength(boundedJson(completed, cap.maxPlanBytes)) + 1 > cap.maxPlanBytes) throw new Error(ERROR);
    return completed;
  } catch { throw new Error(ERROR); }
  finally { localHmac?.fill(0); }
}

async function fileJson(path, maximum) {
  const safe = await boundedFile(path, maximum);
  return JSON.parse((await readFile(safe)).toString('utf8'));
}

async function fileKey(path, maximum = 32) {
  const safe = await boundedFile(path, maximum);
  const key = await readFile(safe);
  if (maximum === 32 && key.length !== 32) throw new Error(ERROR);
  return key;
}

export async function runFinalDeltaCli(args) {
  const loadedKeys = [];
  try {
    if (!Array.isArray(args) || args.length !== 4) throw new Error(ERROR);
    const values = new Map();
    for (let index = 0; index < 4; index += 2) {
      if (!['--config', '--out'].includes(args[index]) || !args[index + 1] || values.has(args[index])) throw new Error(ERROR);
      values.set(args[index], args[index + 1]);
    }
    if (values.size !== 2) throw new Error(ERROR);
    const config = await fileJson(values.get('--config'), 64_000);
    if (config.format !== 1) throw new Error(ERROR);
    const cap = limits(config.limits);
    const { output } = await validateExportPaths(REPO, values.get('--out'), config.hmacKeyFile);
    const hmacKey = await fileKey(config.hmacKeyFile, 4096); loadedKeys.push(hmacKey);
    async function generation(value) {
      if (!object(value)) throw new Error(ERROR);
      const archiveKey = await fileKey(value.keyFile); loadedKeys.push(archiveKey);
      const result = { archivePath: value.archivePath, archiveSha256: value.archiveSha256,
        archiveKey, manifest: await fileJson(value.manifestFile, cap.maxManifestBytes) };
      if (value.credentials) {
        const key = await fileKey(value.credentials.keyFile); loadedKeys.push(key);
        result.credentials = { archivePath: value.credentials.archivePath,
          archiveSha256: value.credentials.archiveSha256, archiveKey: key };
      }
      return result;
    }
    const plan = await createFinalDeltaPlan({ before: await generation(config.before),
      after: await generation(config.after), expectedSource: config.expectedSource,
      expectedHmacKeyId: config.expectedHmacKeyId, hmacKey, limits: config.limits });
    const partial = `${output}.partial-${randomBytes(8).toString('hex')}`;
    let file;
    try {
      file = await open(partial, 'wx', 0o600);
      await file.writeFile(JSON.stringify(plan) + '\n'); await file.sync();
      await file.close(); file = null;
      await link(partial, output); // Publishes only a complete new file; never replaces one.
    } finally { await file?.close(); await unlink(partial).catch((error) => { if (error.code !== 'ENOENT') throw error; }); }
    return { planSha256: plan.planSha256, cutoverReady: false, automaticApply: false,
      counts: Object.fromEntries(Object.entries(plan.changes).map(([name, section]) => [name, section.counts])) };
  } catch { throw new Error(ERROR); }
  finally { for (const key of loadedKeys) key.fill(0); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  runFinalDeltaCli(process.argv.slice(2)).then((summary) => {
    process.stdout.write(JSON.stringify(summary) + '\n');
  }).catch(() => { process.stderr.write(ERROR + '\n'); process.exitCode = 1; });
}
