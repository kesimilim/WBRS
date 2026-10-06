# Default-off private legacy image reads

## Closed preview before cutover

The live Firebase source remains writable. An imported snapshot cannot act as
current production membership or password-revocation authority. While testing
this snapshot, set `CLRS_PREVIEW_GUARD_ENABLED=1` and supply a separate protected
32-byte `CLRS_PREVIEW_ACCESS_KEY_B64`. Every data/auth route additionally requires
`X-Clrs-Preview-Proof` with that canonical base64 key. Never embed it in Flutter,
an APK, a query string, source or logs. Only controlled operator probes use it.
Wrong/missing proof returns 404 before body reads, authorization, database work
or dependency factories. Invalid guard configuration returns 503. Health and
readiness expose no user data; preview readiness does not query the database.
The guard is an interim closed testing boundary, not production authentication.
Remove it only after current authority, complete client behavior and final delta
have been verified. A final release must not use this shared operator proof.

This is default-off server preparation, not an enabled media endpoint or a
complete Firebase Storage cutover. `legacy_private_media.py` accepts only a verified server
identity and an existing authenticated opaque media reference. It does not
create promotions, expose a route, change grants, update raw rows, sign a URL,
copy an S3 object, or use a Firebase download-token fallback.

## Explicit reviewed alias boundary

`import-core.mjs` says that raw import quarantine must not be served or signed
automatically. The original importer and its immutable receipts keep that
contract. This separate, default-off service is a deliberate reviewed promotion
boundary: a `media_objects` row with `status = 'ready'` may refer to the **same
private immutable object** under `clrs-import-quarantine/` only after completed
SQL/S3 import and full readback have been accepted. It is not an automatic change
from quarantine to ready. No second copy or new paid bucket is required.

The existing key is exactly:

```
clrs-import-quarantine/ + SHA256(project + NUL + sourceBucket + NUL + sourcePath)
```

The suffix identifies the source object; it is not the content checksum. Raw
`legacy_storage_objects.target_key`, source/target SHA256 and archived paths
remain unchanged. Any later promotion tool must produce its own reviewed
receipt and preserve the raw import receipts; no such tool or live promotion is
performed by this service. Merely finding a raw row never grants byte access.

Each permitted promotion must bind an existing active Auth owner, exact source
path, supported purpose, key, MIME type, size and full content SHA256. Do not
guess owners from a display label or manufacture accounts for orphan source
records. Source ownership and purpose require review before writing a ready
row. The schema has one unique object-key row and one purpose; cross-purpose
reuse that cannot satisfy that exact row remains unavailable until separately
reviewed. A historical sender without an active account is retained raw but is
not made an invented media owner.

## Authorizations and scopes

The service opens AES-GCM media references with the same existing 32-byte cursor
key. Exact shape, current UID, full source SHA256, source bucket, safe source
path, version and five-minute expiry are checked before SQL. A reference for A
cannot be used by B; client JSON UIDs cannot act as identities.

Supported source contexts are:

- Personal-message outer `image`: exact `chats/{id}` parent hash and explicit
  `user1`/`user2` membership; fresh exact message and its hash, image path,
  `sendByID` owner, and deleted-for flags.
- Meeting-message outer `image`: exact `meets/{id}` hash, explicit `users`
  membership and no `kicked` membership; the organizer is not implicitly made a
  message participant. Fresh exact message image, hash and `sender` owner.
- Own removed-meeting message: only
  `users/{verifiedUID}/removed_meets/{id}/messages/{message}`. Sparse archive
  parents are allowed, but no other owner's namespace is accepted.
- Participant avatar: exact meeting parent hash, current member or organizer
  and not kicked; avatar owner is a listed member or organizer; exact profile
  hash and thumbnail-first source image.
- Own-chat discovery avatar: fresh exact own pair with that profile owner.
- Own-meeting discovery organizer avatar: fresh exact organizer/current
  member-or-organizer relation and no kicked access.
- Meeting-details/discovery image: exact meeting hash, current member or
  organizer and not kicked; exact organizer owner and source image.
- Own full-profile avatar: exact `users/{verifiedUID}` document hash, current
  active owner and the exact `profilePic` or `profilePicThumb` field bound by
  the full-profile response. A different thumbnail does not replace the
  requested original, and a reference for A cannot load B's own avatar.

Discovery avatar references issued by the existing reader do not contain an
individual conversation ID/hash. They contain a profile hash and a common
discovery binding. This service therefore rechecks all matching own relations
(at most 50), verifies each full parent path/payload hash, and compares their
aggregate digest before and after downloading. It authorizes an avatar while
there is at least one current valid own relation; it does not claim a binding to
a specific conversation at original issuance. Malformed or over-limit parent
candidates fail closed.

Deleted/disabled/missing owners, deleted or blocked profiles and hidden messages
are refused. Arbitrary profile/gallery requests, wall/shared-post images,
quoted images and arbitrary object-key requests have no authorization route
here. Only outer message `image` may authorize a message file; a shared wall
image never borrows its surrounding message's authority. Bundle gift assets
remain client assets and do not become S3 reads.

All membership authority is still the reviewed immutable import snapshot.
This is not a current join/leave authority after mutable cutover. Fresh SQL
transactions catch later account disablement, profile/parent changes and ready
row withdrawal during the download. Session revocation is checked by the HTTP
identity verifier on entry; this core has no raw bearer token or extra session
table grant and does not claim immediate mid-response logout revocation.

## Exact SQL and storage readback

Both authorization transactions use the existing `ssl.CERT_REQUIRED` and
hostname verification, `clrs_staging`, MySQL 8.4, a TLS cipher, UTC,
REPEATABLE READ/READ ONLY, source-project/database/bucket pin, current active
account, bounded statement/socket/absolute read deadlines and rollback/close.
No SQL mutation, COMMIT, retry or DDL occurs.

The role must have **only** global USAGE (optional exact `REQUIRE SSL`) and SELECT
on these five tables:

```
clrs_staging.accounts
clrs_staging.legacy_source
clrs_staging.legacy_documents
clrs_staging.legacy_storage_objects
clrs_staging.media_objects
```

It is a separate media role; do not expand the existing three-table legacy read
validator or assign migration permissions. Missing/extra tables, schema/global
SELECT, write rights, grant option or other role/SSL clauses fail closed. No
runtime grant has been created here.

Where the provider exposes only database-level rights, an explicit separate
`CLRS_LEGACY_MEDIA_PERMISSION_MODEL=provider-database-v1` permits exactly
global USAGE plus SELECT on `clrs_staging.*`, using the existing read-only
database validator. It rejects global/other-database SELECT, writes, role
grants, GRANT OPTION and mixed table/database grants. This grants broader
database reads than the five-table model and must be explicitly selected;
the legacy read flag cannot silently select it for media. Do not use the
migration or native-write role. Actual TLS and role checks remain mandatory.

Storage lookup uses the indexed source-path SHA256 and then compares exact
bucket/path, copied marker, source size and source/target content hashes. JSON
source metadata is capped at 64 KiB in SQL and parsed with duplicate-key
rejection. Images are restricted to JPEG, PNG, WebP and GIF. A ready lookup uses
the indexed exact target-key SHA256 and requires matching owner, purpose, key,
MIME type, size, content hash, ready status and original path. Collation matches
do not substitute for the final exact Python string/byte comparisons.

No source content-SHA pin exists in `legacy_source` itself. Runtime construction
must use `LegacyPrivateMediaService.from_env`: it verifies the encrypted completed
promotion acknowledgement before configuration, SQL or media access. Environment
source/review strings alone cannot satisfy this gate. The direct constructor
remains available for synthetic injected tests, not production HTTP construction.

The bounded server-only `media_promotion_acknowledgement.py` consumer requires
exactly two authenticated CLRSX2 JSON frames, authenticated `end` with
`receiptRecords: 1`, and EOF. It checks the ciphertext SHA256 and the
`clrs-media-promotion-receipt-v1` HMAC over the canonical body hash. The completed
version/state, 26 distinct chunk-receipt digests, 5,191 candidates, 1,287 retained
quarantine objects, full archive/manifest/audit-plan/audit-file/media-row/readback
pins, source identity and configured target bucket/owner must match exactly.
Duplicate or unknown JSON keys, incomplete receipts, unexpected frames and
key reuse with the cursor key are refused. Total encrypted input is at most
16,384 bytes; the receipt key must be a separate 32-byte server secret.

`startedAt` and `verifiedAt` must use UTC timestamps with milliseconds, be ordered,
and `verifiedAt` must not exceed server time by more than 60 seconds. This durable
completed-migration acknowledgement has no age expiry. It is not fresh runtime
privacy, authorization or membership proof: every request still requires the
existing current SQL ownership/membership checks and fresh ACL, privacy and full
object SHA checks. It does not claim an atomic SQL/S3 snapshot or enable HTTP.

## File and response limits

`LegacyPrivateMediaService.open_media(identity, reference)` returns a
`VerifiedMediaLease`. Construction finishes the entire private S3 download,
checksum verification, an independent full spool SHA256 check, and a new SQL
authorization before returning any response bytes. On any failure the file is
closed and no body lease is returned. The adapter rechecks fresh bucket privacy
and owner-only ACLs before and after the object.

Limits per process:

- 64,000,000 bytes per object; two media slots, held through response close.
- Anonymous/unlinked 0600 temporary file in an existing same-owner 0700 spool
  directory; no original filename, token or Storage path is exposed.
- 60-second total lease deadline; at most 50 seconds for S3 download; inherited
  SQL read deadline is eight seconds and individual network/SQL operations are
  also bounded. Expiry/deadline are checked between response chunks.
- 64 KiB chunks with caller pull/backpressure; no full-object RAM copy.
- 30 media attempts per UID/minute and 120 per process/minute before AES/SQL,
  with HMAC keys and fixed bounded limiter state; inherited SQL limits also
  apply to each of the two authorization reads.
- A timer sets cancellation, but does not release a slot while an actual
  synchronous download is still running. A lost/hung operation cannot spawn
  replacement work past the concurrency cap. Limits are per process, so the
  deployment must multiply them by its configured worker count.

The HTTP adapter owns the lease, stops iteration on disconnect, closes it on
every outcome (including close before the first body chunk), and applies a
deadline to socket writes.
Calling `iter_bytes()` twice is refused. The lease supplies only Content-Length,
the restricted Content-Type, `private, no-store`, `nosniff` and a fixed attachment
name. It returns no raw key/path, URL, token, ACL or source metadata. Access logs
must not record authorization tokens or full opaque-reference values. This
core alone does not implement a client image loader.

## Prepared HTTP route and request lifecycle

`app.py` dispatches `GET /v1/media/{opaqueReference}` through
`legacy_private_media_http.py` only in API mode and with
`CLRS_LEGACY_MEDIA_ENABLED=1`. Missing/invalid service configuration fails closed.
There is no query string, Range response, request body, arbitrary object key,
public link or fallback Google URL. The path reference is the existing opaque
base64url value, at most 4096 characters. Native access tokens are authorized
by the same native service; Firebase tokens use the same typed identity verifier
as legacy reads. Refresh tokens are never accepted as access identities. The
media core still checks the exact UID/source/field/current reviewed parent,
ready row and full object checksums.

The WSGI server starts every request with its existing absolute 10-second
budget. Only after successful typed authentication may the media adapter ask
`http_runtime.py` for the separate media budget, at most 60 seconds from the
original request start. Two HTTP media slots and the existing two media-core
slots are held until the actual handler/I/O finishes. Other requests retain
their original deadline. The socket inactivity timeout remains 10 seconds.
During pre-response download, a socket EOF/reset, absolute deadline or server
shutdown sets the same cancellation event used by the S3 adapter. Cancellation
does not release a slot while the actual synchronous operation is unfinished.

The response begins only after `open_media` returns its fully verified spool,
including its second SQL authorization. A final lease expiry/cancel check runs
before headers. Body iteration pulls at most 64 KiB per chunk; the WSGI body
owns and closes the spool on success, write failure, timeout, early close or
disconnect. Servers that do not supply the bounded media-budget callback fail
closed rather than silently adopting an unbounded request lifetime. The quiet
runtime does not log request paths, bearer values or opaque references.

## Default-off configuration and remaining proof

All existing `CLRS_LEGACY_READ_*` review/source/membership flags still apply.
Additional operator gates are:

```
CLRS_LEGACY_MEDIA_ENABLED=1
CLRS_LEGACY_MEDIA_PROMOTION_REVIEWED=1
CLRS_LEGACY_MEDIA_PROMOTION_MODE=reviewed-immutable-object-alias
CLRS_LEGACY_MEDIA_S3_USER_MODE=dedicated-read-only
CLRS_LEGACY_MEDIA_FULL_READBACK_SOURCE_SHA256=<same verified full source SHA256>
CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64=<canonical padded base64 of completed CLRSX2 receipt>
CLRS_LEGACY_MEDIA_PROMOTION_ACK_SHA256=<exact encrypted receipt SHA256>
CLRS_LEGACY_MEDIA_PROMOTION_RECEIPT_KEY_B64=<separate protected server-only 32-byte key>
CLRS_LEGACY_MEDIA_TARGET_BUCKET=<exact acknowledged private bucket>
CLRS_LEGACY_MEDIA_EXPECTED_OWNER=<exact acknowledged owner ID>
CLRS_LEGACY_MEDIA_DB_URL=<private TLS verify-full URL for exact five-table role>
CLRS_LEGACY_MEDIA_S3_ACCESS_KEY=<dedicated Get-only S3 access key>
CLRS_LEGACY_MEDIA_S3_SECRET_KEY=<its protected secret, never the import key>
CLRS_LEGACY_MEDIA_S3_REGION=<existing bucket signing region>
CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID=<canonical positive decimal bucket ID>
CLRS_LEGACY_MEDIA_CONTROL_TOKEN=<separate narrow GET-only control-plane token>
```

`CLRS_LEGACY_MEDIA_DB_CA_FILE` is optional when absent: the same
`profile_store.BUNDLED_CA_FILE` from the deployed module is used with
`CERT_REQUIRED` and hostname checking. An explicitly empty, relative or missing
CA path is rejected. No guessed `/app` path is configured.

`CLRS_LEGACY_MEDIA_SPOOL_DIR` is also optional when absent. Only after the
completed acknowledgement and DB/TLS configuration pass, the factory creates
an owned 0700 `TemporaryDirectory` in the platform's real temporary directory.
The service owns its lifetime and `app.close`/`server_close` cleans it; a failed
factory cleans it too. Files remain unlinked 0600 spools. An explicitly supplied
path must remain absolute, existing, same-owner and 0700; empty/bad paths do not
silently default. Feature-off creates no directory. The S3/control secrets are
kept by their private adapters and are removed from the service's copied env;
the caller's original environment is not modified.

The existing `CLRS_LEGACY_CURSOR_KEY_B64` is still required and must differ from
the promotion receipt key. Receipt bytes and keys must never enter an APK, Git,
logs or public responses. The factory removes the raw receipt and its key from
the service's copied configuration after verification; it also checks that the
injected private S3 adapter uses exactly the acknowledged bucket and owner.
Missing material fails closed, and a disabled media feature returns no service.
The consumer itself performs no network access, grant, promotion or deployment.

The separate `PrivateMediaS3` adapter accepts server-created exact
`{key,size,sha256,content_type}` records. Its S3 user needs only GetObject and
GetObjectAcl for the existing quarantine prefix, plus GetBucketAcl and
GetBucketPolicy for the existing bucket. No List, PUT, DELETE, presign, public
policy or second bucket is needed. Migration credentials must not be assigned
to the HTTP process. Fresh Timeweb private-bucket state needs a separate GET-only
control-plane credential; credentials and expected owner ID remain outside Git
and APK. Policy is a review template, not a created user or proven live policy.

Before enable: complete SQL+S3 readback; review logical-promotion receipts and
source ownership; provision the two narrow read roles/control-plane scope;
verify actual MySQL query syntax and Timeweb S3 signing/ACL/privacy with a
controlled object; integrate bounded HTTP streaming and controlled A/B client
reads. Fresh delta/final synchronization is also required before production
cutover. Current offline tests do not prove any of these live gates.

Offline tests in `test_legacy_private_media.py` cover alias/source/owner/purpose,
full hashes, malformed references, A/B and expiry, current membership and
hidden/deleted rows, profile thumbnail/digests, discovery relation changes,
bounded parents, own removed history, readonly exact grants/TLS, full download
before body, spool cleanup, response/backpressure slots, real timer cancellation
while injected I/O remains blocked, and malformed-reference rate limits.
`test_media_promotion_acknowledgement.py` additionally uses an actual synthetic
Node signer/CLRSX2 writer fixture and checks ciphertext/HMAC/end verification,
incomplete/corrupt/foreign receipts, timestamp and input bounds, secret separation,
and factory refusal before SQL. `test_legacy_private_media_http.py` covers typed
native/Firebase authorization before budget extension, default-off and malformed
requests, full verification before headers, generic denied/hash-failure replies,
spool close before/after iteration, loopback disconnect/timeout/shutdown
cancellation, and two media transport slots retained until actual I/O ends.
These offline checks do not mint a real completed
acknowledgement or satisfy the remaining live enable/cutover gates.
