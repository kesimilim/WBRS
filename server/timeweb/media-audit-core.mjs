import { createHash, createHmac } from 'node:crypto';
import { payloadHash, scanImportArchive, targetObjectKey } from './import-core.mjs';
import { verifyExportManifest } from './verify-export-manifest.mjs';

const trusted = new WeakSet();
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const sha = (value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const byteSort = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const allowedMime = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/gif']);
const supportedPurposes = new Set(['profile', 'message', 'meeting']);
const MAX_OBJECT = 64_000_000;
const MAX_DOCUMENT = 131_072;
const MAX_REFERENCES = 500_000;
const MAX_RETAINED = 100_000_000;

function uid(value) {
  return typeof value === 'string' && value && [...value].length <= 191
    && value !== '.' && value !== '..'
    && !/[\u0000-\u001f\u007f/]/u.test(value)
    && Buffer.from(value).toString('utf8') === value;
}
function path(value) {
  return typeof value === 'string' && value && Buffer.byteLength(value) <= 1024
    && !/[\u0000-\u001f\u007f]/u.test(value)
    && Buffer.from(value).toString('utf8') === value
    && value.split('/').every((part) => part && part !== '.' && part !== '..');
}
function typedString(fields, name) {
  const value = fields[name];
  if (value === undefined || (object(value) && Object.keys(value).length === 1 && 'nullValue' in value)) return null;
  if (!object(value) || Object.keys(value).length !== 1 || typeof value.stringValue !== 'string') return undefined;
  return value.stringValue;
}
function profileState(fields, profileUid) {
  const saved = typedString(fields, 'uid');
  const status = typedString(fields, 'status');
  const registration = typedString(fields, 'registrationStatus');
  const deleted = fields.deleted;
  if (saved === undefined || (saved !== null && saved !== profileUid) || status === undefined
      || registration === undefined || (deleted !== undefined && (!object(deleted)
        || Object.keys(deleted).length !== 1 || typeof deleted.booleanValue !== 'boolean'))) return 'malformed';
  if (status === 'deleted' || registration === 'deleted' || deleted?.booleanValue === true) return 'deleted';
  if (status === 'blocked') return 'blocked';
  if (status !== null && status !== 'active') return 'malformed';
  return 'active';
}

// A restricted whole-value URL parser. It never searches a message for a URL,
// accepts an arbitrary host, or retains query/download-token values.
export function auditedStoragePath(value, bucket) {
  if (typeof value !== 'string' || [...value].length > 4096) return null;
  const match = /^([a-z]+):\/\/([^/?#]*)([^?#]*)(?:\?[^#]*)?$/.exec(value);
  if (!match || match[2].includes('@') || match[2].includes(':')) return null;
  let raw;
  if (match[1] === 'gs' && match[2] === bucket) raw = match[3].replace(/^\//, '');
  else if (match[1] === 'https' && match[2] === 'firebasestorage.googleapis.com') {
    const prefix = `/v0/b/${bucket}/o/`;
    if (match[3].startsWith(prefix)) raw = match[3].slice(prefix.length);
  } else if (match[1] === 'https' && match[2] === 'storage.googleapis.com') {
    const prefix = `/${bucket}/`;
    if (match[3].startsWith(prefix)) raw = match[3].slice(prefix.length);
  }
  try {
    const decoded = typeof raw === 'string' ? decodeURIComponent(raw) : null;
    return path(decoded) ? decoded : null;
  } catch { return null; }
}

function locationClaim(documentPath, fields, pointer) {
  const parts = documentPath.split('/');
  const direct = pointer.length === 1 ? pointer[0] : null;
  if (parts.length === 2 && parts[0] === 'users' && ['profilePic', 'profilePicThumb'].includes(direct)) {
    return { owner: parts[1], purpose: 'profile', context: 'profile_avatar' };
  }
  if (parts.length === 4 && parts[0] === 'users' && parts[2] === 'images'
      && ['url', 'thumbnailUrl'].includes(direct)) {
    return { owner: parts[1], purpose: 'profile', context: 'profile_gallery' };
  }
  if (parts.length === 2 && parts[0] === 'chats' && ['user1_image', 'user2_image'].includes(direct)) {
    return { owner: typedString(fields, direct === 'user1_image' ? 'user1' : 'user2'), purpose: 'profile', context: 'chat_avatar_snapshot' };
  }
  if (direct === 'image' && ((parts.length === 4 && parts[0] === 'chats' && parts[2] === 'chats')
      || (parts.length === 4 && parts[0] === 'meets' && parts[2] === 'messages')
      || (parts.length === 6 && parts[0] === 'users' && parts[2] === 'removed_meets' && parts[4] === 'messages'))) {
    return { owner: typedString(fields, parts[0] === 'chats' ? 'sendByID' : 'sender'), purpose: 'message', context: 'outer_message_image' };
  }
  if (parts.length === 2 && parts[0] === 'meets' && ['imageUrl', 'meetingImageUrl'].includes(direct)) {
    return { owner: typedString(fields, 'admin'), purpose: 'meeting', context: 'meeting_image' };
  }
  if (((parts.length === 2 && parts[0] === 'posts')
      || (parts.length === 4 && parts[0] === 'posts' && parts[2] === 'comments'))
      && ['imageUrl', 'authorPhoto'].includes(direct)) {
    return { owner: typedString(fields, 'authorUid'), purpose: direct === 'authorPhoto' ? 'profile'
      : parts.length === 2 ? 'post' : 'comment', context: direct === 'authorPhoto' ? 'author_avatar_snapshot' : 'wall_image' };
  }
  return null;
}

// These exact prefixes are evidenced by the current upload call sites. No
// basename/substring/first-directory guess is a source ownership statement.
function uploadPathClaim(name) {
  const p = name.split('/');
  if (!p.at(-1)?.endsWith('.jpg')) return null;
  if (p[0] === 'profile_images' && (p.length === 5 || (p.length === 6 && p[4] === 'thumbs'))
      && p[2] === 'registration') return { owner: p[1], purpose: 'profile' };
  if (p[0] === 'users' && (p.length === 4 || (p.length === 5 && p[3] === 'thumbs')) && p[2] === 'photos') return { owner: p[1], purpose: 'profile' };
  if (p.length === 3 && ['feed_posts', 'feed_comments'].includes(p[0])) return { owner: p[1], purpose: p[0] === 'feed_posts' ? 'post' : 'comment' };
  return null;
}

function freeze(value) {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}

export class MediaAuditCollector {
  constructor() {
    this.auth = new Map(); this.profiles = new Map(); this.objects = [];
    this.references = []; this.referenceCount = 0; this.retainedBytes = 0;
    this.boundedTraversalDocuments = 0;
  }
  retain(value) {
    this.retainedBytes += Buffer.byteLength(JSON.stringify(value));
    if (this.retainedBytes > MAX_RETAINED) throw new Error('Media audit retained-data bound reached');
    return value;
  }
  authRecord(record, bucket) {
    const user = record.encodedPayload;
    this.auth.set(record.uid, { valid: uid(record.uid) && typeof user.disabled === 'boolean', disabled: user.disabled });
    const name = auditedStoragePath(user.photoURL, bucket);
    if (name !== null) this.reference({ name, documentPath: null, field: 'Auth.photoURL', documentSha256: record.sha256,
      owner: record.uid, purpose: 'profile', context: 'auth_avatar', validContext: true });
  }
  reference(value) {
    if (++this.referenceCount > MAX_REFERENCES) throw new Error('Media reference bound reached');
    this.references.push(this.retain(value));
  }
  documentRecord(record, bucket) {
    const fields = record.encodedPayload.fields; const parts = record.firebasePath.split('/');
    const oversized = Buffer.byteLength(JSON.stringify(record.encodedPayload)) > MAX_DOCUMENT;
    if (parts.length === 2 && parts[0] === 'users') this.profiles.set(parts[1], profileState(fields, parts[1]));
    let nodes = 0; let bounded = false; const start = this.references.length;
    const visit = (value, pointer, depth) => {
      if (bounded || ++nodes > 10000 || depth > 32) { bounded = true; return; }
      if (!object(value)) return;
      if (typeof value.stringValue === 'string') {
        const name = auditedStoragePath(value.stringValue, bucket);
        if (name !== null) {
          const claim = locationClaim(record.firebasePath, fields, pointer);
          this.reference({ name, documentPath: record.firebasePath, field: pointer.join('/'), documentSha256: record.sha256,
            owner: claim?.owner ?? null, purpose: claim?.purpose ?? null, context: claim?.context ?? 'unsupported_reference_location',
            validContext: !oversized && Object.keys(value).length === 1 && claim !== null });
        }
      }
      if (object(value.mapValue) && object(value.mapValue.fields)) {
        for (const [name, child] of Object.entries(value.mapValue.fields)) visit(child, [...pointer, name], depth + 1);
      }
      if (object(value.arrayValue) && Array.isArray(value.arrayValue.values)) {
        value.arrayValue.values.forEach((child, index) => visit(child, [...pointer, String(index)], depth + 1));
      }
    };
    for (const [name, value] of Object.entries(fields)) visit(value, [name], 0);
    if (bounded) {
      this.boundedTraversalDocuments++;
      for (const ref of this.references.slice(start)) ref.validContext = false;
    }
  }
  objectRecord(record) {
    this.objects.push(this.retain({ name: record.name, size: record.size, sha256: record.sha256,
      metadataSha256: payloadHash(record.metadata), contentType: record.metadata.contentType ?? null,
      metadataBucket: record.metadata.bucket ?? null, targetKey: record.targetKey }));
  }
}

export function buildMediaAuditMapping(collector, binding) {
  const refs = new Map(); const names = new Set(); const reasonCounts = {};
  for (const ref of collector.references) {
    if (!refs.has(ref.name)) refs.set(ref.name, []);
    refs.get(ref.name).push(ref);
  }
  const objects = [...collector.objects].sort((a, b) => byteSort(a.name, b.name)).map((item) => {
    if (names.has(item.name)) throw new Error('Duplicate audited object');
    names.add(item.name);
    const references = (refs.get(item.name) ?? []).sort((a, b) => byteSort(`${a.documentPath ?? ''}\0${a.field}`, `${b.documentPath ?? ''}\0${b.field}`));
    const known = references.filter((ref) => ref.validContext);
    const upload = uploadPathClaim(item.name);
    const claims = [...known, ...(upload ? [{ ...upload, context: 'exact_known_upload_path' }] : [])];
    const owners = [...new Set(claims.filter((claim) => uid(claim.owner)).map((claim) => claim.owner))].sort(byteSort);
    const purposes = [...new Set(claims.map((claim) => claim.purpose).filter(Boolean))].sort(byteSort);
    const reasons = [];
    if (!path(item.name)) reasons.push('unsafe_source_path');
    if (!Number.isSafeInteger(item.size) || item.size < 0 || item.size > MAX_OBJECT) reasons.push('object_size_out_of_bound');
    if (!sha(item.sha256) || item.targetKey !== targetObjectKey(binding.source.project, binding.source.bucket, item.name)) reasons.push('source_key_or_hash_mismatch');
    if (item.metadataBucket !== null && item.metadataBucket !== binding.source.bucket) reasons.push('metadata_bucket_mismatch');
    if (!allowedMime.has(item.contentType)) reasons.push('unsupported_image_mime');
    if (!known.length) reasons.push('no_supported_owned_reference');
    if (claims.some((claim) => !uid(claim.owner))) reasons.push('malformed_or_missing_owner_reference');
    if (owners.length === 0) reasons.push('unattributed_object');
    if (owners.length > 1) reasons.push('ambiguous_owner');
    if (purposes.length !== 1) reasons.push('ambiguous_or_missing_purpose');
    if (purposes.some((purpose) => !supportedPurposes.has(purpose))) reasons.push('unsupported_runtime_purpose');
    if (owners.some((owner) => !collector.auth.has(owner))) reasons.push('owner_absent_auth');
    if (owners.some((owner) => collector.auth.has(owner) && !collector.auth.get(owner).valid)) reasons.push('malformed_auth_owner');
    if (owners.some((owner) => collector.auth.get(owner)?.disabled)) reasons.push('disabled_auth_owner');
    if (owners.some((owner) => ['deleted', 'blocked', 'malformed'].includes(collector.profiles.get(owner)))) reasons.push('unavailable_owner_profile');
    for (const reason of reasons) reasonCounts[reason] = (reasonCounts[reason] ?? 0) + 1;
    const candidate = reasons.length === 0;
    return { sourceBucket: binding.source.bucket, sourcePath: item.name, sourceMetadataSha256: item.metadataSha256,
      byteSize: item.size, contentSha256: item.sha256, targetKey: item.targetKey,
      disposition: candidate ? 'review_candidate' : 'retain_quarantine', reasonCodes: reasons,
      owners, purposes, referenceCount: references.length, ownedReferenceCount: known.length,
      sourcePathClaim: upload, references,
      proposedMediaRow: candidate ? { media_id: 'legacy-media-' + item.targetKey.slice(item.targetKey.lastIndexOf('/') + 1),
        owner_uid: owners[0], purpose: purposes[0], object_key: item.targetKey, thumbnail_key: null,
        mime_type: item.contentType, byte_size: item.size, sha256: item.sha256,
        status: 'ready', legacy_storage_path: item.name } : null };
  });
  const missingReferences = collector.references.filter((ref) => !names.has(ref.name));
  const summary = { sourceObjects: objects.length, sourceBytes: objects.reduce((sum, item) => sum + item.byteSize, 0),
    referencedObjects: objects.filter((item) => item.referenceCount > 0).length,
    unreferencedObjects: objects.filter((item) => item.referenceCount === 0).length,
    reviewCandidates: objects.filter((item) => item.disposition === 'review_candidate').length,
    retainedQuarantine: objects.filter((item) => item.disposition === 'retain_quarantine').length,
    sourceReferences: collector.references.length, referencesToMissingObjects: missingReferences.length,
    boundedTraversalDocuments: collector.boundedTraversalDocuments,
    reasonCounts: Object.fromEntries(Object.entries(reasonCounts).sort(([a], [b]) => byteSort(a, b))) };
  return { kind: 'clrs-private-media-audit', schemaVersion: 1, completeFullSource: true, ...binding,
    promotionMode: 'reviewed-immutable-object-alias', fullRawReadbackRequired: true,
    separatePrivateS3ReadRoleRequired: true, liveBucketPrivacyReviewRequired: true,
    promotionsPerformed: 0, summary, objects, missingReferences };
}

export async function prepareMediaAudit({ archivePath, key, manifestBytes, hmacKey,
    expectedSource, expectedArchiveSha256, expectedManifestSha256, limits }) {
  if (!sha(expectedArchiveSha256) || !sha(expectedManifestSha256) || !Buffer.isBuffer(manifestBytes)
      || manifestBytes.length > 64_000_000 || createHash('sha256').update(manifestBytes).digest('hex') !== expectedManifestSha256) {
    throw new Error('Exact completed full-source and manifest SHA confirmations required');
  }
  const collector = new MediaAuditCollector(); let scanned;
  const verification = await verifyExportManifest({ archivePath, archiveKey: key,
    manifest: JSON.parse(manifestBytes.toString('utf8')), hmacKey,
    scanArchive: async (arguments_) => {
      // The actual full scanner is fixed here. A caller cannot inject records
      // or a forged successful scan; every object byte is decrypted and hashed.
      let bucket;
      const selector = (await import('./encrypted-archive.mjs')).readEncryptedArchive(archivePath, key);
      try { bucket = (await selector.next()).value?.record?.bucket; } finally { await selector.return(); }
      scanned = await scanImportArchive({ ...arguments_, limits,
        onAuth: async (record) => { collector.authRecord(record, bucket); await arguments_.onAuth(record); },
        onDocument: async (record) => { collector.documentRecord(record, bucket); await arguments_.onDocument(record); },
        onObject: async (record) => { collector.objectRecord(record); await arguments_.onObject(record); } });
      return scanned;
    } });
  if (!verification.equalToInventory || verification.archiveSha256 !== expectedArchiveSha256
      || !object(expectedSource) || !['project', 'database', 'bucket'].every((name) =>
        typeof expectedSource[name] === 'string' && expectedSource[name] && expectedSource[name] === scanned.source[name])) {
    throw new Error('Full source/inventory confirmation mismatch');
  }
  const plan = buildMediaAuditMapping(collector, { source: { project: scanned.source.project,
    database: scanned.source.database, bucket: scanned.source.bucket }, archiveSha256: verification.archiveSha256,
    inventoryManifestSha256: expectedManifestSha256, sourceCounts: verification.counts });
  if (plan.summary.sourceObjects !== verification.counts.storageObjects || plan.summary.sourceBytes !== verification.counts.storageBytes) {
    throw new Error('Complete Storage coverage mismatch');
  }
  plan.planSha256 = payloadHash(plan);
  plan.planHmacSha256 = createHmac('sha256', hmacKey).update('clrs-media-audit-v1\0').update(plan.planSha256).digest('hex');
  trusted.add(plan); return freeze(plan);
}

export function assertPreparedMediaAudit(plan) {
  if (!trusted.has(plan) || plan.kind !== 'clrs-private-media-audit' || plan.completeFullSource !== true) throw new Error('Authenticated completed full media audit required');
}
export function mediaAuditSummary(plan) {
  assertPreparedMediaAudit(plan);
  return { archiveSha256: plan.archiveSha256, inventoryManifestSha256: plan.inventoryManifestSha256,
    planSha256: plan.planSha256, ...plan.summary, promotionsPerformed: 0,
    livePrivacyGatePassed: false, stageAllowedByAuditAlone: false };
}
