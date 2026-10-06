import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { payloadHash, targetObjectKey } from './import-core.mjs';

export const MEDIA_PROMOTION_PINS = Object.freeze({
  archiveSha256: 'b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e',
  inventoryManifestSha256: '82352a0bb8a172fc33034204be2a3a752bcac69cc971f0feeb9a177ebcb3a341',
  planSha256: 'c9b8279bada1f8442dd9d8f97792f45d7f0eb56e9bba2f71968c052e8fe46f0b',
});
const trusted = new WeakSet();
const acknowledged = new WeakMap();
const chunkParents = new WeakMap();
export const MEDIA_PROMOTION_CHUNK_SIZE = 200;
const sha = (x) => typeof x === 'string' && /^[a-f0-9]{64}$/.test(x);
const object = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);
const fail = () => { throw new Error('Authenticated media promotion binding required'); };
const uid = (x) => typeof x === 'string' && x && [...x].length <= 191
  && !/[\u0000-\u001f\u007f/]/u.test(x) && !['.', '..'].includes(x)
  && Buffer.from(x).toString('utf8') === x;
const sort = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const freeze = (x) => { if (object(x) || Array.isArray(x)) { Object.values(x).forEach(freeze); Object.freeze(x); } return x; };
const mac = (key, domain, digest) => createHmac('sha256', key).update(`${domain}\0`).update(digest).digest('hex');
function checkMac(key, domain, digest, supplied) {
  if (!Buffer.isBuffer(key) || key.length !== 32 || !sha(supplied)
      || !timingSafeEqual(Buffer.from(mac(key, domain, digest), 'hex'), Buffer.from(supplied, 'hex'))) fail();
}
const exact = (x, keys) => object(x) && isDeepStrictEqual(Object.keys(x).sort(), [...keys].sort());
export const MEDIA_ROW_COLUMNS = Object.freeze(['media_id', 'owner_uid', 'purpose', 'object_key',
  'thumbnail_key', 'mime_type', 'byte_size', 'thumbnail_byte_size', 'sha256', 'status', 'legacy_storage_path']);

// expectedPins is an explicit library review binding, useful for synthetic
// fixtures. The executable CLI accepts only MEDIA_PROMOTION_PINS, never a flag
// or environment override. An authenticated audit is NOT a privacy proof.
export function prepareMediaPromotion({ auditBytes, hmacKey, expectedSource,
  expectedPins = MEDIA_PROMOTION_PINS }) {
  if (!Buffer.isBuffer(auditBytes) || auditBytes.length > 100_000_000
      || !exact(expectedPins, Object.keys(MEDIA_PROMOTION_PINS))
      || Object.values(expectedPins).some((x) => !sha(x))) fail();
  const audit = JSON.parse(auditBytes.toString('utf8'));
  const { planSha256, planHmacSha256, ...body } = audit;
  if (payloadHash(body) !== planSha256) fail();
  checkMac(hmacKey, 'clrs-media-audit-v1', planSha256, planHmacSha256);
  if (!Object.entries(expectedPins).every(([key, value]) => audit[key] === value)
      || audit.kind !== 'clrs-private-media-audit' || audit.schemaVersion !== 1
      || audit.completeFullSource !== true || audit.promotionsPerformed !== 0
      || audit.promotionMode !== 'reviewed-immutable-object-alias'
      || audit.fullRawReadbackRequired !== true || audit.separatePrivateS3ReadRoleRequired !== true
      || audit.liveBucketPrivacyReviewRequired !== true
      || !['project', 'database', 'bucket'].every((k) => typeof expectedSource?.[k] === 'string'
        && expectedSource[k] && [...expectedSource[k]].length <= 191 && audit.source?.[k] === expectedSource[k])
      || !Array.isArray(audit.objects) || audit.objects.length > 10_000
      || !Array.isArray(audit.missingReferences) || audit.missingReferences.length > 500_000) fail();
  const names = new Set(), keys = new Set(), owners = new Set(), documentHashes = new Map(), authHashes = new Map();
  const rows = []; let byteSize = 0, referenceCount = 0, referenced = 0, quarantined = 0;
  for (const item of audit.objects) {
    if (!object(item) || typeof item.sourcePath !== 'string' || Buffer.byteLength(item.sourcePath) > 1024
        || names.has(item.sourcePath) || keys.has(item.targetKey) || item.sourceBucket !== expectedSource.bucket
        || item.targetKey !== targetObjectKey(expectedSource.project, expectedSource.bucket, item.sourcePath)
        || !sha(item.contentSha256) || !sha(item.sourceMetadataSha256)
        || !Number.isSafeInteger(item.byteSize) || item.byteSize < 0 || item.byteSize > 64_000_000
        || !Array.isArray(item.references) || item.references.length !== item.referenceCount
        || !Array.isArray(item.reasonCodes) || !Array.isArray(item.owners) || !Array.isArray(item.purposes)) fail();
    names.add(item.sourcePath); keys.add(item.targetKey); byteSize += item.byteSize;
    referenceCount += item.referenceCount; if (item.referenceCount) referenced++;
    if (item.disposition === 'retain_quarantine') {
      quarantined++; if (item.proposedMediaRow !== null || !item.reasonCodes.length) fail(); continue;
    }
    const row = item.proposedMediaRow;
    if (item.disposition !== 'review_candidate' || item.reasonCodes.length || item.owners.length !== 1
        || !uid(item.owners[0]) || item.purposes.length !== 1
        || !['profile', 'message', 'meeting'].includes(item.purposes[0])
        || !exact(row, MEDIA_ROW_COLUMNS.filter((k) => k !== 'thumbnail_byte_size'))
        || row.owner_uid !== item.owners[0] || row.purpose !== item.purposes[0]
        || row.object_key !== item.targetKey || row.byte_size !== item.byteSize
        || row.sha256 !== item.contentSha256 || row.legacy_storage_path !== item.sourcePath
        || row.media_id !== `legacy-media-${item.targetKey.split('/').at(-1)}`
        || row.status !== 'ready' || row.thumbnail_key !== null
        || !['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(row.mime_type)
        || item.ownedReferenceCount < 1) fail();
    let owned = 0;
    for (const reference of item.references) {
      if (!object(reference) || reference.name !== item.sourcePath || !sha(reference.documentSha256)) fail();
      if (reference.validContext === true) { owned++; if (reference.owner !== row.owner_uid || reference.purpose !== row.purpose) fail(); }
      const collection = reference.documentPath === null ? authHashes : documentHashes;
      const identity = reference.documentPath === null ? reference.owner : reference.documentPath;
      if (typeof identity !== 'string' || !identity || Buffer.byteLength(identity) > 8192
          || (collection.has(identity) && collection.get(identity) !== reference.documentSha256)) fail();
      collection.set(identity, reference.documentSha256);
    }
    if (owned !== item.ownedReferenceCount) fail();
    owners.add(row.owner_uid); rows.push({ ...row, thumbnail_byte_size: null });
  }
  const summary = audit.summary;
  if (summary?.sourceObjects !== names.size || summary.sourceBytes !== byteSize
      || summary.referencedObjects !== referenced || summary.unreferencedObjects !== names.size - referenced
      || summary.reviewCandidates !== rows.length || summary.retainedQuarantine !== quarantined
      || summary.sourceReferences !== referenceCount + audit.missingReferences.length
      || summary.referencesToMissingObjects !== audit.missingReferences.length
      || audit.sourceCounts?.storageObjects !== names.size || audit.sourceCounts.storageBytes !== byteSize
      || !Number.isSafeInteger(audit.sourceCounts.authUsers) || audit.sourceCounts.authUsers < 1
      || !Number.isSafeInteger(audit.sourceCounts.firestoreDocuments) || audit.sourceCounts.firestoreDocuments < 1) fail();
  rows.sort((a, b) => sort(a.media_id, b.media_id));
  const plan = freeze({ source: { ...expectedSource }, pins: { ...expectedPins }, auditFileSha256: hash(auditBytes),
    sourceCounts: { ...audit.sourceCounts }, summary: { ...summary }, objects: audit.objects,
    rows, owners: [...owners].sort(sort), references: [...documentHashes].sort(([a], [b]) => sort(a, b)),
    authReferences: [...authHashes].sort(([a], [b]) => sort(a, b)), rowsSha256: payloadHash(rows) });
  trusted.add(plan); return plan;
}
export function assertPreparedMediaPromotion(plan) { if (!trusted.has(plan)) fail(); }
export function mediaPromotionChunk(root, index) {
  assertPreparedMediaPromotion(root);
  if (chunkParents.has(root) || !Number.isSafeInteger(index) || index < 0
      || index >= Math.ceil(root.rows.length / MEDIA_PROMOTION_CHUNK_SIZE)) fail();
  const rows = root.rows.slice(index * MEDIA_PROMOTION_CHUNK_SIZE, (index + 1) * MEDIA_PROMOTION_CHUNK_SIZE);
  const names = new Set(rows.map((row) => row.legacy_storage_path));
  const objects = root.objects.filter((item) => names.has(item.sourcePath));
  const documents = new Map(), auth = new Map();
  for (const item of objects) for (const ref of item.references) {
    (ref.documentPath === null ? auth : documents).set(ref.documentPath === null ? ref.owner : ref.documentPath, ref.documentSha256);
  }
  const child = freeze({ ...root, objects, rows, owners: [...new Set(rows.map((x) => x.owner_uid))].sort(sort),
    references: [...documents].sort(([a], [b]) => sort(a, b)), authReferences: [...auth].sort(([a], [b]) => sort(a, b)),
    rowsSha256: payloadHash(rows), fullRowsSha256: root.rowsSha256,
    chunk: { index, size: MEDIA_PROMOTION_CHUNK_SIZE, total: Math.ceil(root.rows.length / MEDIA_PROMOTION_CHUNK_SIZE),
      candidates: rows.length, totalCandidates: root.rows.length } });
  trusted.add(child); chunkParents.set(child, root); return child;
}
export function mediaPromotionRoot(plan) { assertPreparedMediaPromotion(plan); return chunkParents.get(plan) ?? plan; }
export function mediaPromotionSummary(plan) {
  assertPreparedMediaPromotion(plan);
  return { ...plan.pins, sourceObjects: plan.summary.sourceObjects, reviewCandidates: plan.rows.length,
    retainedQuarantine: plan.summary.retainedQuarantine, promotionsPerformed: 0, httpEnabled: false,
    readyToStageByAuditAlone: false, targetRowsSha256: plan.rowsSha256 };
}

// Produced ONLY after reviewing an actual completed FULL SQL/S3 readback.
// This signs the operator's evidence binding, it does not perform a readback.
export function signMediaReadbackAcknowledgement(body, hmacKey) {
  const digest = payloadHash(body);
  return { ...body, proofSha256: digest, proofHmacSha256: mac(hmacKey, 'clrs-media-full-readback-v1', digest) };
}
export function verifyMediaReadbackAcknowledgement(plan, bytes, hmacKey, expectedFileSha256) {
  assertPreparedMediaPromotion(plan);
  if (!Buffer.isBuffer(bytes) || bytes.length > 65536 || hash(bytes) !== expectedFileSha256) fail();
  const { proofSha256, proofHmacSha256, ...body } = JSON.parse(bytes.toString('utf8'));
  if (payloadHash(body) !== proofSha256) fail();
  checkMac(hmacKey, 'clrs-media-full-readback-v1', proofSha256, proofHmacSha256);
  if (!exact(body, ['kind', 'version', 'state', 'pins', 'source', 'counts', 'targetBucket', 'expectedOwner',
    'completedAt', 'rawVerifyResultSha256', 'rawVerifyStatusSha256'])
      || body.kind !== 'clrs-media-full-readback-acknowledgement' || body.version !== 1
      || body.state !== 'reviewed_verified_full_raw_sql_s3' || !isDeepStrictEqual(body.pins, plan.pins)
      || !isDeepStrictEqual(body.source, plan.source) || !isDeepStrictEqual(body.counts, plan.sourceCounts)
      || !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(body.targetBucket ?? '')
      || !/^[A-Za-z0-9_-]{1,191}$/.test(body.expectedOwner ?? '')
      || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(body.completedAt ?? '')
      || !Number.isFinite(Date.parse(body.completedAt))
      || !sha(body.rawVerifyResultSha256) || !sha(body.rawVerifyStatusSha256)) fail();
  const result = freeze({ ...body, proofFileSha256: expectedFileSha256, proofSha256 });
  acknowledged.set(result, plan); return result;
}
export function assertMediaReadbackAcknowledgement(plan, acknowledgement) {
  assertPreparedMediaPromotion(plan); if (acknowledged.get(acknowledgement) !== mediaPromotionRoot(plan)) fail();
}
export function signMediaPromotionReceipt(body, key) {
  return { ...body, receiptHmacSha256: mac(key, 'clrs-media-promotion-receipt-v1', payloadHash(body)) };
}
export function verifyMediaPromotionReceiptHmac(receipt, key) {
  const { receiptHmacSha256, ...body } = receipt ?? {};
  checkMac(key, 'clrs-media-promotion-receipt-v1', payloadHash(body), receiptHmacSha256);
}
