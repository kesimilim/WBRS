import { GetBucketAclCommand, GetBucketPolicyCommand, GetObjectAclCommand } from '@aws-sdk/client-s3';
import { assertPreparedMediaPromotion } from './media-promotion-core.mjs';

export const MEDIA_PRIVACY_LIMITS = Object.freeze({ concurrency: 4, operationMs: 5000,
  preflightMs: 120000, objectProofMaxAgeMs: 120000 });
const fail = () => { throw new Error('Fresh read-only media privacy proof unavailable'); };
function ownerOnly(acl, owner) {
  return acl?.Owner?.ID === owner && Array.isArray(acl.Grants) && acl.Grants.length === 1
    && acl.Grants[0]?.Permission === 'FULL_CONTROL'
    && acl.Grants[0]?.Grantee?.Type === 'CanonicalUser' && acl.Grants[0]?.Grantee?.ID === owner;
}
export function createMediaPromotionPrivacy({ client, bucket, expectedOwner, bucketState,
  clock = () => performance.now() }) {
  if (!client || typeof client.send !== 'function' || typeof bucketState !== 'function'
      || !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket ?? '')
      || !/^[A-Za-z0-9_-]{1,191}$/.test(expectedOwner ?? '')) fail();
  const proofs = new WeakSet();
  async function send(command, signal) {
    // Only these three GET commands exist here. No probe PUT/DELETE, object
    // write, presign, public URL, redirect or content download is performed.
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), MEDIA_PRIVACY_LIMITS.operationMs);
    const signalCombined = signal ? AbortSignal.any([signal, abort.signal]) : abort.signal;
    let stop;
    const expired = new Promise((_, reject) => {
      stop = () => reject(new Error('Private media read deadline exceeded'));
      if (signalCombined.aborted) stop(); else signalCombined.addEventListener('abort', stop, { once: true });
    });
    try {
      return await Promise.race([expired, Promise.resolve().then(() => {
        if (signalCombined.aborted) fail();
        return client.send(command, { abortSignal: signalCombined });
      })]);
    } finally { clearTimeout(timer); signalCombined.removeEventListener('abort', stop); }
  }
  async function checkBucket(signal) {
    const abort = new AbortController();
    const stateSignal = signal ? AbortSignal.any([signal, abort.signal]) : abort.signal;
    let stop;
    const stateDeadline = new Promise((_, reject) => {
      stop = () => reject(new Error('Private bucket state deadline exceeded'));
      if (stateSignal.aborted) stop(); else stateSignal.addEventListener('abort', stop, { once: true });
    });
    const timer = setTimeout(() => abort.abort(), MEDIA_PRIVACY_LIMITS.operationMs);
    let state;
    try { state = await Promise.race([stateDeadline, Promise.resolve().then(() => bucketState(stateSignal))]); }
    finally { clearTimeout(timer); stateSignal.removeEventListener('abort', stop); }
    if (state?.bucket !== bucket || state.type !== 'private' || state.websiteEnabled !== false) fail();
    const acl = await send(new GetBucketAclCommand({ Bucket: bucket }), signal);
    if (!ownerOnly(acl, expectedOwner)) fail();
    try {
      const policy = await send(new GetBucketPolicyCommand({ Bucket: bucket }), signal);
      if (typeof policy?.Policy !== 'string' || policy.Policy.length > 65536) fail();
      const parsed = JSON.parse(policy.Policy);
      if (parsed?.Version !== '2012-10-17' || Object.keys(parsed).length !== 2
          || !Array.isArray(parsed.Statement) || parsed.Statement.length) fail();
    } catch (error) { if (error?.name !== 'NoSuchBucketPolicy') throw error; }
  }
  return Object.freeze({
    async beforeTransaction(plan, acknowledgement) {
      assertPreparedMediaPromotion(plan);
      if (acknowledgement.targetBucket !== bucket || acknowledgement.expectedOwner !== expectedOwner) fail();
      const abort = new AbortController();
      const timer = setTimeout(() => abort.abort(), MEDIA_PRIVACY_LIMITS.preflightMs);
      const start = clock(); let next = 0, oldest = Infinity, done = 0;
      try {
        await checkBucket(abort.signal);
        const workers = Array.from({ length: Math.min(MEDIA_PRIVACY_LIMITS.concurrency, plan.rows.length) }, async () => {
          while (!abort.signal.aborted) {
            const index = next++; if (index >= plan.rows.length) return;
            const acl = await send(new GetObjectAclCommand({ Bucket: bucket, Key: plan.rows[index].object_key }), abort.signal);
            if (!ownerOnly(acl, expectedOwner)) fail();
            oldest = Math.min(oldest, clock()); done++;
          }
          fail();
        });
        const settled = await Promise.allSettled(workers.map((worker) => worker.catch((error) => { abort.abort(); throw error; })));
        if (settled.some((entry) => entry.status === 'rejected') || abort.signal.aborted
            || done !== plan.rows.length || clock() - start >= MEDIA_PRIVACY_LIMITS.preflightMs) fail();
        await checkBucket(abort.signal);
        const proof = Object.freeze({ plan, bucket, expectedOwner, oldest: done ? oldest : clock(), count: done });
        proofs.add(proof); return proof;
      } finally { clearTimeout(timer); abort.abort(); }
    },
    async beforeCommit(plan, proof) {
      assertPreparedMediaPromotion(plan);
      if (!proofs.has(proof) || proof.plan !== plan || proof.count !== plan.rows.length
          || clock() - proof.oldest >= MEDIA_PRIVACY_LIMITS.objectProofMaxAgeMs) fail();
      // Three bounded global GETs only while SQL locks are held. No 5k object
      // checks are scheduled under the transaction. Expired per-object proof
      // refuses COMMIT; operators cannot extend the reviewed bound by a flag.
      await checkBucket();
      if (clock() - proof.oldest >= MEDIA_PRIVACY_LIMITS.objectProofMaxAgeMs) fail();
    },
  });
}

export function timewebPromotionBucketState({ bucket, bucketId, token, fetchImpl = fetch }) {
  if (!Number.isSafeInteger(bucketId) || bucketId < 1 || typeof token !== 'string' || !token) fail();
  return async (outerSignal) => {
    const signal = outerSignal ? AbortSignal.any([outerSignal, AbortSignal.timeout(5000)]) : AbortSignal.timeout(5000);
    const response = await fetchImpl(`https://api.timeweb.cloud/api/v1/storages/buckets/${bucketId}`,
      { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' }, signal, redirect: 'error' });
    if (!response.ok || !response.body) fail();
    const reader = response.body.getReader(); const chunks = []; let bytes = 0;
    try {
      while (true) { const entry = await reader.read(); if (entry.done) break;
        bytes += entry.value.byteLength; if (bytes > 65536) fail(); chunks.push(Buffer.from(entry.value)); }
      const found = JSON.parse(Buffer.concat(chunks).toString('utf8'))?.bucket;
      if (Number(found?.id) !== bucketId || found?.name !== bucket || found?.type !== 'private'
          || found?.website_config?.enabled === true) fail();
      return { bucket, type: 'private', websiteEnabled: false };
    } finally { await reader.cancel().catch(() => {}); }
  };
}
