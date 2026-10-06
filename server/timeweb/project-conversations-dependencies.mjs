import { mysqlTimestamp } from './project-profiles-core.mjs';
import { projectProfileDetails } from './project-profile-details.mjs';

// Deliberately matches the existing profile projection contract. This module
// never creates dependencies; it describes the exact account/identity/profile
// rows that must already exist before conversation staging can begin.
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
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


export function conversationDependencies(authRecords, rootDocuments) {
  const byUid = new Map(rootDocuments.map((record) => [record.documentId, record]));
  const accountIds = new Set(authRecords.map((record) => record.uid));
  const accounts = []; const identities = []; const profiles = [];
  const emails = new Set(); const subjects = new Set();
  try {
    for (const record of authRecords) {
      const document = byUid.get(record.uid);
      const profile = document ? projectedProfile(document, record.uid) : null;
      const auth = projectedAuth(record, profile?.lifecycle ?? 'active');
      if (auth.account.email_normalized !== null) {
        if (emails.has(auth.account.email_normalized)) throw new Error('Duplicate dependency email');
        emails.add(auth.account.email_normalized);
      }
      for (const identity of auth.identities) {
        const key = JSON.stringify([identity.provider, identity.provider_subject]);
        if (subjects.has(key)) throw new Error('Duplicate dependency identity');
        subjects.add(key);
      }
      accounts.push(auth.account); identities.push(...auth.identities);
      if (profile) profiles.push(profile.row);
    }
    return { ready: true, accounts, identities, profiles,
      counts: { accounts: accounts.length, identities: identities.length,
        profiles: profiles.length, rootDocuments: rootDocuments.length,
        orphanProfiles: rootDocuments.filter((record) => !accountIds.has(record.documentId)).length,
        accountsWithoutProfile: accounts.length - profiles.length } };
  } catch {
    // Preserve business-row/raw classifications for inspection. SQL fails
    // before connection instead of pretending unsupported dependencies exist.
    return { ready: false, reason: 'source_account_projection_unavailable',
      accounts: [], identities: [], profiles: [],
      counts: { sourceAuthUsers: authRecords.length, rootDocuments: rootDocuments.length } };
  }
}
