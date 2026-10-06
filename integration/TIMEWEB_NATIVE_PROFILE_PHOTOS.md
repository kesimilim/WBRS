# Native current-profile photo reads: independent source contract

`server/timeweb/python-stand/runtime_profile_photos.py` adds a bounded read
service for the actor's own profile and currently visible public profiles. It
has no HTTP route, environment factory, upload operation, grant change, DDL,
client integration or activation. Existing public profile DTOs remain unchanged.
This source implementation does not establish a deployed photo feature or a
completed migration/cutover.

## Authority and original provenance

Every call uses the existing `RuntimeMutationStore.read_authenticated` pool.
The store verifies the exact current native access token/session/account before
and after the service callback in a fresh SERIALIZABLE READ ONLY transaction;
the connection is rolled back and closed. An unverified legacy token, client
claim, email lookup or native boolean cannot select the actor.

The service locks the current exact UID account/profile pair and the complete
current `profile_photos` set with `FOR SHARE`. The account/profile join retains
the indexed equality and an additional binary equality. The caller supplies the
target UID on both descriptor and bytes requests. Another user's target must
pass the frozen `profile_visibility.evaluate_profile_visibility` using current
canonical fields and trusted retained source. The active actor may read their
own hidden/incomplete profile; this exception does not permit reading another
hidden profile. Disabled, deleted, missing or malformed targets fail closed.

For a nonempty relation, all of the following are mandatory:

- No more than 50 rows, distinct media/source image IDs, dense explicit ordinal
  order starting at zero, and exactly the first photo marked primary.
- A completed authenticated archival import/readback capability minted by
  `verify_source_snapshot`, not a constructed dataclass or a SQL-only claim.
- The exact pinned `legacy_source` identity, `users/{uid}` archived path/hash,
  root document payload digest and exact canonical `profiles.legacy_raw` digest.
- A completed bounded `users/{uid}/images` source set and the trusted caller's
  mandatory `gallery_order_policy=reviewed-source-document-id-binary-asc-v1`.
  This matches the separately reviewed projector policy: all source IDs in
  exact binary ascending order go into the pure plan, and the resulting plan's
  original ordinals must equal every current persisted relation row. The policy
  is committed by the reference context, not inferred from the association IDs.
- Exact ready `media_objects` owner, purpose `profile`, media ID, internal object
  key, MIME, byte length/hash and source storage path; exact matching storage
  metadata/copy marker/key/hash/length. The pure `profile_photo_review` validator
  supplies these original-reference/provenance rules.
- A current `VerifiedMediaPromotion` acknowledgement and the actual
  `PrivateMediaS3` adapter pinned to the separately trusted target bucket/owner.

The entire expected original association set must equal the current relation.
An original that also appears once in the gallery remains one primary photo
with that source gallery ID; duplicate gallery paths remain an ambiguous-source
refusal under the existing pure reviewer.
The root `profilePic` original is the primary; `profilePicThumb`, an auth photo,
an arbitrary owned ready object and a quarantine URL never supply a fallback.
Thumbnails are not mapped. Native stored raw `{}` with a nonempty relation has
no supported original-source provenance and is refused. An authorized empty
relation returns an honest empty list, even if other ready objects exist.

The archival proof explicitly records `consistent=false`; it proves the
completed retained import/readback, not an atomic cross-system snapshot or a
current Firestore cutover. This reader does not import later Firebase edits or
create photo associations. A separate reviewed native upload provenance
contract is still needed for new native photos.

## Descriptors and opaque references

`photos(identity, target_uid, access_token=..., limit=30, cursor=None)` checks
all current associations/provenance before returning one page. A page contains
at most 30 items and at most 65,536 UTF-8 JSON bytes. The item fields are exactly
`ordinal`, `isPrimary`, `contentType`, `byteSize`, `reference`; the page adds
`kind=canonical-profile-photos`, `targetUid`, `ordering=ordinal_asc`, `items`,
`nextCursor`. No URL, internal object/storage key, raw source, email, account
role, content hash or session value is public. The descriptor reports the actual
original's declared MIME and exact verified metadata size; it is not image data.

AES-GCM references use the separate
`clrs-runtime-current-profile-photos-v1` key domain. Every resource binds exact
SHA-256 hashes of the current actor UID and caller's target UID, media ID,
ordinal, primary marker, complete current association/provenance context and an
expiry of at most 60 seconds. The context also commits current lifecycle,
visibility fields, canonical raw digest and profile timestamp. A bytes request
must supply the same target UID and freshly prove its own current session.

The continuation uses a separate AEAD purpose and page kind, and binds actor,
target, complete context, limit and last ordinal with the same 60-second maximum.
A changed profile/relation/provenance, expired token, different actor/target or
different page limit rejects the continuation. No automatic page draining or
logging of names, UIDs, raw values, URLs or references is introduced.

## Original bytes, first-byte guard and lifetime

`open_photo(identity, target_uid, reference, access_token=...,
request_cancel=..., request_deadline=...)` performs three fresh authoritative
reads:

1. Before the private storage fetch, validate the current session/actor, current
   target visibility and complete exact photo/source/ready relation against the
   opaque reference.
2. After `PrivateMediaS3.get_verified_to_file` has fully downloaded, verified
   length/hash and rechecked bucket/object privacy, repeat the current SQL proof
   in a new transaction and require the identical resource/context.
3. Immediately when the returned lease starts `iter_bytes`, repeat the proof in
   another new transaction before yielding the first byte. Entering a lease or
   obtaining it earlier does not consume this guard.

Only JPEG, PNG, WebP and GIF originals of 1 through 8 MiB are supported. The
existing legacy upload source compresses picker images but establishes no
universal original byte-size ceiling; 8 MiB is an explicit new read limit.
Larger originals are unavailable, not truncated or replaced by a thumbnail.
One unsupported or oversized original conservatively refuses the whole
nonempty set; it does not silently remove that photo from a valid-looking page.
This is not an image transcode or a claimed pixel-decoder validation.

The actual private adapter uses authenticated GET-only storage operations;
private bucket state, bucket ACL/policy and object owner ACL remain its required
checks. No presigned URL or public/quarantine URL is returned. SQL transactions
end before network I/O. Source/media text and JSON reads have explicit bounds;
gallery and association queries use `LIMIT 51` to refuse sets over 50 rather
than authorize a partial set. Source collection/hash indexes and media primary
keys select the narrow candidates.

The sink is an anonymous private temporary file in an absolute, current-owner
0700 directory. The service independently verifies its final size and SHA-256
again before constructing a `VerifiedMediaLease` subclass. At most two spools
are outstanding per service. The total request/lease deadline is at most 60
seconds, the download deadline at most 50 seconds, and expiry/cancellation is
checked during verification and each output chunk of at most 64 KiB.
The effective timer also ends at the opaque reference's remaining expiry.
After handoff the timer hard-closes an unconsumed lease and releases its slot;
the service keeps returned leases in a registry and closes all of them on
`close()`. Lease close/release is idempotent across consumer/timer/close races.
During synchronous S3 setup a timer cancels the adapter, and the setup owner
cleans up after it has stopped, without closing its sink underneath the fetch.

The eventual HTTP adapter must use the lease as a context manager, iterate it
once, bound socket writes, cancel on disconnect, and always close it. `close()`
on the service prevents new reads, cancels outstanding setup and closes returned
leases; it does not
close the shared mutation store. The guards establish current authority before
the first byte; they do not claim instantaneous database revocation during an
already started stream. No stream sends an unverified prefix before a final
hash failure.

## Permission and HTTP integration boundary

The read callback needs `SELECT` on exactly these data tables, plus the store's
existing current-session/grant/TLS checks:

| Table | Purpose |
| --- | --- |
| `accounts`, `profiles` | Current actor/target and visibility/raw provenance |
| `device_sessions` | Existing native current-session verifier |
| `profile_photos` | Current exact ordered/primary relation |
| `media_objects` | Ready owner/purpose/object metadata |
| `legacy_source` | Exact imported source identity |
| `legacy_documents` | Exact retained root and bounded gallery |
| `legacy_storage_objects` | Original storage/copy/hash provenance |

The existing default `strict-tables-v1` runtime role/map does **not** include
photo/media/source table SELECT permissions. Missing SELECT, an incompatible
schema or a transport failure is `RuntimeUnavailable` and returns no descriptor
or bytes. Simply adding grants is insufficient: the store's strict grant
allowlist rejects unknown extra table grants. A separately reviewed minimal
permission-model extension would need exactly `SELECT` on `profile_photos`,
`media_objects`, `legacy_source`, `legacy_documents`,
`legacy_storage_objects`; existing account/profile/session rights stay as they
are. This task changes neither grants nor that map.

The accepted existing `provider-database-v1` model has broad database
SELECT/INSERT/UPDATE rights. This source does not claim that role is narrow;
the store nevertheless runs this callback in READ ONLY mode, permits no writes,
and rolls back. No actual capability/grant/live connection is proved by these
tests. The existing production private-media adapter remains closed and has not
been enabled by adding this service.

For a future adapter: `RuntimeProfilePhotoNotFound` maps current missing/hidden
or unsupported proven resources to 404 without logging out a valid session;
current native identity rejection remains 401. Malformed/stale AEAD values are
`RuntimeInvalidRequest`, unavailable SQL/storage/spool/cancellation is 503. Do
not register routes, instantiate a factory on unmatched/off requests, or expose
reference-derived private fields without a separate HTTP review. All shared
HTTP files are unchanged in this stage.

## Focused local evidence

`test_runtime_profile_photos.py`: 17 focused tests pass through the real current
native transaction verifier and real `PrivateMediaS3` using synthetic SQL and
GET transports. Cases cover own/public visibility, hidden/disabled/missing
targets, stored native raw `{}`, explicit order/50-row refusal, 30-item/64 KiB
pages with maximum Unicode IDs, expiry/purpose/target/limit binding, current
session A-to-B/revoke/post-check, exact source/media/relation mismatch, 8 MiB
refusal, corrupt hash/length, pre-first-byte changes, missing SELECT, invalid
capabilities/private spool, cancellation, two outstanding leases, unused-lease
deadline/close cleanup and primary/gallery aliases with duplicate refusal.

Every synthetic connection is READ ONLY, rolls back/closes and commits zero
times. These checks make no TCP, SQL server, S3, cloud, grant, deploy, flag,
APK/build or broad-suite calls. They establish source behavior, not production
transport, deployed HTTP, real migrated association counts or application UI
acceptance.
