import { createHash } from 'node:crypto';
import { readEncryptedArchive } from './encrypted-archive.mjs';
import { DEFAULT_IMPORT_LIMITS, payloadHash, scanImportArchive } from './import-core.mjs';
import { projectProfileDetails } from './project-profile-details.mjs';

const trustedPlans = new WeakSet();
const summaryFields = ['authUsers', 'authListPages', 'firestoreDocuments',
  'firestoreMissingParents', 'firestoreReferences', 'firestoreCollections',
  'firestoreListPages', 'storageObjects', 'storageBytes', 'storageListPages'];
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const nonnegative = (value) => Number.isSafeInteger(value) && value >= 0;

function deepFreeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(deepFreeze);
    Object.freeze(value);
  }
  return value;
}

function sourceMatches(source, expected) {
  if (!object(expected) || !['project', 'database', 'bucket'].every((field) =>
    typeof expected[field] === 'string' && expected[field]
      && [...expected[field]].length <= 191 && source[field] === expected[field])) {
    throw new Error('Projection source confirmation mismatch');
  }
}

function checkMetadataSource(source) {
  if (!object(source) || source.kind !== 'source' || source.format !== 2
      || source.scope !== 'metadata' || source.completeSource !== false
      || source.storagePrefix !== '' || source.passwordHashesIncluded !== false) {
    throw new Error('Projection requires a complete metadata or full CLRSX2 archive');
  }
}

// The metadata export intentionally omits Storage. Its Auth and Firestore
// sections must still finish and agree with the authenticated end counters.
async function scanMetadata({ archivePath, key, limits, onAuth, onDocument }) {
  const cap = { ...DEFAULT_IMPORT_LIMITS, ...limits };
  for (const value of Object.values(cap)) {
    if (!Number.isSafeInteger(value) || value < 1) throw new Error('Invalid projection limit');
  }
  const hash = createHash('sha256');
  const authIds = new Set();
  const paths = new Set();
  let source;
  let summary;
  let section = 'source';
  for await (const frame of readEncryptedArchive(archivePath, key, {
    onCiphertext: (bytes) => hash.update(bytes),
  })) {
    if (frame.type !== 'json' || !object(frame.record)) {
      throw new Error('Unexpected metadata archive frame');
    }
    const record = frame.record;
    if (section === 'source') {
      checkMetadataSource(record);
      source = record;
      section = 'auth';
    } else if (record.kind === 'auth-user' && section === 'auth') {
      const user = record.user;
      if (!object(user) || typeof user.uid !== 'string' || !user.uid
          || 'passwordHash' in user || 'passwordSalt' in user || authIds.has(user.uid)) {
        throw new Error('Invalid or duplicate projection Auth record');
      }
      authIds.add(user.uid);
      if (authIds.size > cap.maxAuthUsers) throw new Error('Projection Auth limit reached');
      onAuth({ uid: user.uid, encodedPayload: user, sha256: payloadHash(user) });
    } else if (record.kind === 'firestore-document' && ['auth', 'documents'].includes(section)) {
      section = 'documents';
      const parts = typeof record.path === 'string' ? record.path.split('/') : [];
      if (parts.length < 2 || parts.length % 2 !== 0 || parts.some((part) => !part)
          || !object(record.fields) || typeof record.createTime !== 'string'
          || typeof record.updateTime !== 'string' || paths.has(record.path)) {
        throw new Error('Invalid or duplicate projection Firestore record');
      }
      paths.add(record.path);
      if (paths.size > cap.maxFirestoreDocuments) throw new Error('Projection document limit reached');
      const encodedPayload = { fields: record.fields,
        createTime: record.createTime, updateTime: record.updateTime };
      onDocument({ firebasePath: record.path, documentId: parts.at(-1),
        encodedPayload, sha256: payloadHash(encodedPayload) });
    } else if (record.kind === 'end' && section !== 'end') {
      summary = record.summary;
      if (!object(summary) || !summaryFields.every((name) => nonnegative(summary[name]))
          || summary.authUsers !== authIds.size || summary.firestoreDocuments !== paths.size
          || summary.firestoreDocuments + summary.firestoreMissingParents !== summary.firestoreReferences
          || summary.storageObjects !== 0 || summary.storageBytes !== 0
          || summary.storageListPages !== 0) {
        throw new Error('Projection metadata completion count mismatch');
      }
      section = 'end';
    } else {
      throw new Error('Unexpected projection metadata record order');
    }
  }
  if (section !== 'end') throw new Error('Incomplete projection metadata archive');
  return { source, summary, archiveSha256: hash.digest('hex') };
}

function string(value, max, optional = false) {
  if (optional && (value === undefined || value === null)) return null;
  if (typeof value !== 'string' || [...value].length > max || (!optional && !value)) {
    throw new Error('Projection string does not fit target schema');
  }
  return value;
}

function flag(value) {
  if (typeof value !== 'boolean') throw new Error('Invalid projection Auth boolean');
  return value ? 1 : 0;
}

// Preserve the six fractional digits MySQL supports. The complete timestamp
// remains unchanged in legacy_raw, including Firestore nanoseconds.
export function mysqlTimestamp(value) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string') throw new Error('Invalid source timestamp');
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$/.exec(value);
  const date = new Date(match ? `${match[1]}Z` : value);
  if (!Number.isFinite(date.getTime()) || date.getUTCFullYear() < 1000
      || date.getUTCFullYear() > 9999) throw new Error('Source timestamp does not fit MySQL');
  const iso = date.toISOString();
  if (match && iso.slice(0, 19) !== match[1]) throw new Error('Invalid source calendar timestamp');
  const fraction = match ? (match[2] ?? '').padEnd(6, '0').slice(0, 6) : `${iso.slice(20, 23)}000`;
  return `${iso.slice(0, 19).replace('T', ' ')}.${fraction}`;
}

function field(fields, name, max = 191) {
  if (!Object.hasOwn(fields, name)) return null;
  const value = fields[name];
  if (!object(value) || Object.keys(value).length !== 1) throw new Error('Invalid typed profile field');
  if (Object.hasOwn(value, 'nullValue')) return null;
  if (!Object.hasOwn(value, 'stringValue')) throw new Error('Expected typed profile string');
  return string(value.stringValue, max, true);
}

function projectedProfile(record, uid) {
  const fields = record.encodedPayload.fields;
  // The Firestore document ID is authoritative. A nullable/missing legacy uid
  // is retained verbatim; a different non-null UID blocks the entire plan.
  const savedUid = field(fields, 'uid');
  if (savedUid !== null && savedUid !== uid) throw new Error('Profile UID conflicts with document ID');
  const status = field(fields, 'status');
  if (status !== null && !['active', 'blocked', 'deleted'].includes(status)) {
    throw new Error('Unsupported profile lifecycle; do not activate it by guessing');
  }
  const fullName = field(fields, 'fullName', 65_535);
  if (fullName !== null && Buffer.byteLength(fullName, 'utf8') > 65_535) {
    throw new Error('Profile name does not fit MySQL TEXT');
  }
  return { lifecycle: status ?? 'active', row: {
    uid, full_name: fullName,
    country: field(fields, 'country'), city: field(fields, 'city'),
    // The Flutter value is one of 16 combined groups. Splitting it would alter
    // the meaning returned by /v1/me/profile; preserve the exact source string.
    primary_group: field(fields, 'группа'), ...projectProfileDetails(fields),
    updated_at: mysqlTimestamp(record.encodedPayload.updateTime),
    legacy_raw: record.encodedPayload,
  } };
}

function projectedAuth(record, lifecycle) {
  const user = record.encodedPayload;
  const uid = string(user.uid, 191);
  if (user.tenantId !== undefined && user.tenantId !== null && user.tenantId !== '') {
    throw new Error('Tenant-scoped identities require a separate reviewed mapping');
  }
  const email = string(user.email, 320, true);
  const emailNormalized = email === null || !email.trim() ? null : email.trim().toLowerCase();
  string(emailNormalized, 320, true);
  if (user.customClaims !== undefined && !object(user.customClaims)) {
    throw new Error('Invalid source claims');
  }
  if (user.metadata !== undefined && !object(user.metadata)) throw new Error('Invalid Auth metadata');
  const providers = user.providerData ?? [];
  if (!Array.isArray(providers)) throw new Error('Invalid source providers');
  const identities = providers.map((provider) => {
    if (!object(provider)) throw new Error('Invalid source identity');
    return { uid, provider: string(provider.providerId, 191),
      provider_subject: string(provider.uid, 191),
      provider_email: string(provider.email, 320, true), legacy_raw: provider };
  });
  return { account: { uid, email_normalized: emailNormalized,
    email_verified: flag(user.emailVerified), disabled: flag(user.disabled),
    lifecycle, token_version: 0,
    firebase_created_at: mysqlTimestamp(user.metadata?.creationTime),
    firebase_last_login_at: mysqlTimestamp(user.metadata?.lastSignInTime),
    legacy_claims: user.customClaims ?? {},
  }, identities };
}

export async function prepareProfileProjection(inputs) {
  // Inspect only the format selector before a full authenticated scan. This
  // first frame alone never authorizes SQL or creates an accepted plan.
  const selector = readEncryptedArchive(inputs.archivePath, inputs.key);
  let first;
  try { first = (await selector.next()).value; } finally { await selector.return(); }
  const scope = first?.record?.scope;
  const authRecords = [];
  const rootDocuments = [];
  const callbacks = {
    ...inputs,
    onAuth: (record) => { authRecords.push(record); },
    onDocument: (record) => {
      if (/^users\/[^/]+$/.test(record.firebasePath)) rootDocuments.push(record);
    },
  };
  const scanned = scope === 'all' ? await scanImportArchive(callbacks) : await scanMetadata(callbacks);
  sourceMatches(scanned.source, inputs.expectedSource);
  const byUid = new Map(rootDocuments.map((record) => [record.documentId, record]));
  const accountIds = new Set(authRecords.map((record) => record.uid));
  const accounts = [];
  const profiles = [];
  const identities = [];
  const emails = new Set();
  const providerSubjects = new Set();
  for (const record of authRecords) {
    const document = byUid.get(record.uid);
    const profile = document ? projectedProfile(document, record.uid) : null;
    const auth = projectedAuth(record, profile?.lifecycle ?? 'active');
    if (auth.account.email_normalized !== null) {
      if (emails.has(auth.account.email_normalized)) throw new Error('Duplicate normalized source email');
      emails.add(auth.account.email_normalized);
    }
    for (const identity of auth.identities) {
      const key = JSON.stringify([identity.provider, identity.provider_subject]);
      if (providerSubjects.has(key)) throw new Error('Duplicate source provider identity');
      providerSubjects.add(key);
    }
    accounts.push(auth.account);
    identities.push(...auth.identities);
    if (profile) profiles.push(profile.row);
  }
  // Orphans are retained in legacy_documents and never assigned to another
  // account, even when a stored email/name happens to look similar.
  const orphanProfiles = rootDocuments.filter((record) => !accountIds.has(record.documentId)).length;
  const counts = {
    sourceAuthUsers: authRecords.length, sourceRootProfiles: rootDocuments.length,
    accounts: accounts.length, identities: identities.length, profiles: profiles.length,
    orphanProfiles, accountsWithoutProfile: accounts.length - profiles.length,
    disabledAccounts: accounts.filter((row) => row.disabled === 1).length,
    blockedAccounts: accounts.filter((row) => row.lifecycle === 'blocked').length,
    deletedAccounts: accounts.filter((row) => row.lifecycle === 'deleted').length,
    adminClaims: accounts.filter((row) => row.legacy_claims.admin === true).length,
    profilesWithoutCountry: profiles.filter((row) => row.country === null).length,
    profilesWithoutName: profiles.filter((row) => row.full_name === null).length,
    profilesWithEmptyName: profiles.filter((row) => row.full_name === '').length,
  };
  const plan = { source: scanned.source, archiveSha256: scanned.archiveSha256,
    counts, authRecords, rootDocuments, accounts, profiles, identities };
  plan.projectionSha256 = payloadHash({ version: 1, source: inputs.expectedSource,
    archiveSha256: plan.archiveSha256, accounts, profiles, identities });
  deepFreeze(plan);
  trustedPlans.add(plan);
  return plan;
}

export function assertPreparedProfilePlan(plan) {
  if (!trustedPlans.has(plan)) throw new Error('A fully authenticated projection plan is required');
}

export function profileProjectionSummary(plan) {
  assertPreparedProfilePlan(plan);
  return { projectionVersion: 1, targetDatabase: 'clrs_staging',
    sourceScope: plan.source.scope, completeSource: plan.source.completeSource,
    archiveSha256: plan.archiveSha256, projectionSha256: plan.projectionSha256,
    counts: plan.counts, passwordMaterialRead: false, databaseWrites: 0 };
}

export function assertProjectionConfirmations(plan, { targetDatabase, archiveSha256,
  orphanProfiles, accountsWithoutProfile }) {
  assertPreparedProfilePlan(plan);
  if (targetDatabase !== 'clrs_staging' || archiveSha256 !== plan.archiveSha256
      || !nonnegative(orphanProfiles) || orphanProfiles !== plan.counts.orphanProfiles
      || !nonnegative(accountsWithoutProfile) || accountsWithoutProfile !== plan.counts.accountsWithoutProfile) {
    throw new Error('Explicit projection target, archive and absence confirmations are required');
  }
}
