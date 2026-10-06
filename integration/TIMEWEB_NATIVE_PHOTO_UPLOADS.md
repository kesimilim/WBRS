# Isolated native profile-photo upload core

Prepared for source review only. The app does not mount this adapter, no flag is
activated, no credential/grant/schema/object/account is changed. Imported photo
readers, their fourteen pinned sources and import receipts are unchanged.

The existing `media_objects`, `profile_photos`, profile PK, photo ordinal/primary
unique keys and `idempotency_receipts` support this flow with SELECT/INSERT/UPDATE.
This core requires the existing `provider-database-v1` permission model and checks
eight exact index parts before access. Strict-table legacy grants fail closed.
Current native token/account/session are checked by the SAME mutation store before
and after each SQL transaction; profile existence is required, completed/search
onboarding is not. New empty native profiles can prepare photos.

## Exact wire

`GET /v1/runtime/profile/photos/upload-availability` has an empty query/body and
uses the current native bearer and own-account transaction. A completed profile
with native origin (`legacy_raw` is an empty JSON object) and an exact native
gallery of 3..20 ready photos returns `{canAppend,photoCount,photoLimit:20,
profileAuthority:'canonical-current-v1'}`. At the limit `canAppend` is false.
Incomplete, transitional or imported/mixed galleries return target 404 without
logging out a healthy actor. Missing writer/service remains 503. The UI checks
availability again before choosing a new image; an unresolved original upload
keeps its receipt recovery independently of this availability read.

Prepare, lease and commit recheck an exact `(0,0)` initial or `(1,1)` completed
flag pair, native origin and the current native gallery. A completed profile
requires at least three ready native photos; an empty initial profile remains
eligible for its first upload. Appending after completion preserves
all original ordinals and the first primary photo; it does not reopen initial
registration. Imported/mixed gallery append, reorder and deletion are separate
operations and remain unsupported. The writer release fingerprint includes the
upload HTTP adapter as well as its core, so a previous nine-file release binding
cannot enable this changed ten-file source.

`POST /v1/runtime/profile/photos/prepare`, operation `profile.photo.prepare.v1`:

```
{operationId, sha256, byteSize, mimeType}
```

Lowercase canonical original UUID (versions 1..8), lowercase SHA256 hex, integer
byteSize 1..5242880, MIME `image/jpeg|image/png|image/webp`; unknown keys rejected.
Hash retains exact `{sha256,byteSize,mimeType}`. HTTP201 matching receipt result:

```
{mediaId, sha256, byteSize, mimeType, status:'pending', profileAuthority:'canonical-current-v1'}
```

`entityRevision:null`. The server derives digest SHA256 of domain bytes
`clrs-native-profile-photo-v1\0` plus canonical JSON array `[actorUid,originalPrepareUUID]`.
Media ID is `tw-profile-photo-<digest>` and key `clrs-native-profile/<digest>`.
The client cannot provide owner, key, raw/origin, association or URL.

`GET /v1/runtime/profile/photos/uploads/{mediaId}/lease?prepareOperationId={UUID}`:
empty body, exact single query. Fresh owner, original prepare receipt and still
pending row checked before and after signing. HTTP200 exact result:

```
{mediaId,method:'PUT',url,headers,expiresAt,byteSize,mimeType,sha256}
```

Expiry exact UTC six fractional digits and Z, 0..60 seconds in the future. URL is
ephemeral: never in SQL receipts or a durable client journal. Fixed S3 host,
server key and exact five headers: `Content-Type`, `Content-Length`,
`If-None-Match:*`, `x-amz-checksum-sha256:<base64digest>`,
`x-amz-content-sha256:<hex>`. No `x-amz-acl`/PutObjectAcl: owner-only privacy is
proved through actual object ACL and private bucket checks by the adapter.

`POST /v1/runtime/profile/photos/commit`, operation `profile.photo.commit.v1`:

```
{operationId,prepareOperationId,mediaId}
```

Hash exact body without operationId. HTTP200 matching receipt result:

```
{mediaId,ready:true,ordinal,isPrimary,updatedAt,profileAuthority:'canonical-current-v1'}
```

`entityRevision:null`; ordinal 0..19, isPrimary exactly ordinal==0; updatedAt UTC6Z.
Actual S3 verification runs outside SQL. Then a new native-authenticated transaction
locks profile, exact prepared media and bounded photo rows; rechecks original
prepare receipt and unexpired opaque verified evidence before/after the write;
atomically pending→ready, append association, advance profile updatedAt, original
commit receipt. Existing fields/registration flags/raw remain untouched. Missing
capability, expired proof, revocation, failure or rollback never establishes ready.
Association limit is 20; no thumbnail, reorder, replacement, DELETE or cleanup here.
Abandoned/failed pending objects stay pending; their rows are not silently removed.

Fresh replay lookup uses the existing operations route and exact requestHash.
Unknown COMMIT is lookup-only with the original UUID/hash; never a new automatic
POST. Original successful commit lookup proves its existing ready association;
a different commit UUID for an already-ready intent is `photo_unavailable`, never
a second association/S3 verification. Original prepare remains historical pending
intent even after commit; no new PUT lease after readiness.

Matching committed errors: prepare `404 profile_not_found`,
`409 photo_limit_reached`; commit `404 profile_not_found|photo_not_found`,
`409 photo_limit_reached|photo_verification_failed|photo_unavailable`.
Any thin/nonreceipt response is UNKNOWN to the client. Short target rejection is
404 `photo_unavailable` without logout; unhealthy native actor is 401. Malformed
request is400, receipt hash conflict409, absent service/writer/proof503; uncertain
SQL COMMIT503 `outcome_unknown`. All public JSON is bounded by the existing64KiB
body/store contract; PUT itself is a separate fixed-size private request.

## Trusted writer interface, closed production

`RuntimeProfilePhotoUploadsService(store,writer=None)` is the default. Prepare can
record only pending; lease/commit cannot reach ready without the trusted port.
The separate HTTP adapter also defaults service=None and is unmounted.

The trusted injected port accepts exact `{key,size,sha256,content_type}`:

* `prepare_put(record,*,deadline,cancel)` → exact `{url,headers,expiresAt}`.
* `verify_ready(record,*,deadline,cancel)` → opaque same-port evidence after actual
  complete-object size/SHA/MIME, full bounded raster decode and pre/post private
  bucket/object ACL checks.
* `require_verified(evidence,record)` → throws unless genuine, current and exact.

Only `PhotoUploadVerificationFailed` represents a proved status200 actual-content
mismatch; privacy/network/unsupported capability/deadline errors remain unknown.
No environment Boolean or caller JSON can manufacture the provider/image proof.
Synthetic writer injection is test evidence, not production S3 acceptance.

[AWS PutObject documentation](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
describes conditional `If-None-Match:*` and checksums. Root's review of the
[Timeweb S3 guide](https://timeweb.cloud/docs/s3-storage/manage-storage/s3-guide)
did not explicitly establish that both work on the chosen provider endpoint.
The first controlled Timeweb pilot actually observed PUT200, duplicate PUT412,
and incorrect-checksum PUT200. Its v1 producer refused and issued no proof;
the intent and both synthetic objects were retained without automatic replay.
The separately signed v2 contract records `checksum_validation:false` with
`checksum_not_enforced`, original and incorrect-header object byte readback
hashes, and an explicit different sent checksum. V1 retains its strict previous
shape/domain and BadDigest requirement. Neither version replaces the complete
server size/SHA/MIME/raster and private pre/post checks before READY. Production
stays closed until genuine endpoint/bucket-bound provider and final source/config
release evidence exists. A separately frozen bounded real raster-decoder port is now
available and exercised in the integrated synthetic scenario below. No ObjectLock,
versioning, ACL/public bucket or broad credential workaround is included.

Native serving and registration completion are separate followups. This core does
not bypass the source-bound existing photo reader or set profile_details_saved
after three claimed URLs/PUT ACKs. The future completion step must consume three
actually ready owner associations, canonical profile data and geography.

## Focused checks

Python3.12 bundled runtime, one new unittest class only. First module run: 5PASS
and one fixture assertion error (JSON tuple keys), no production error. Corrected
that assertion only; the stopped success/receipt case rerun PASS. Aggregate6/6:
blank native owner, pending/lease/verified append, original receipt/unknown COMMIT,
owner/B and post-sign revocation, SHA/size/MIME mismatch, privacy/missing/default
closed, atomic association/revocation/expired-evidence rollback, payload/index/cap.
Saved `upload-test.log` and `upload-test-repair.log` beside the isolated mirror.
No old suite, TCP/S3/SQL/cloud/account call, install, APK or actual repository edit.

Root's integration review found that the v1 core cancelled the writer scope
before its SQL evidence checks. The repaired core keeps the cancel event unset
and retains its two-slot budget through the entire atomic mutation; final cleanup
cancels/releases only after it returns or raises. One NEW integrated unittest
uses the real NativePhotoUploadS3, real bounded Pillow worker, synthetic HTTPS and
the real RuntimeMutationStore: successful commit plus post-write expired/cancelled
proof rollback all PASS first run (1 method/3 subcases,0.172s). Existing6 cases
were not rerun. `upload-integration-test.log` and dependency hashes bind this check.
Fake authenticated provider witness remains synthetic, not Timeweb acceptance.
