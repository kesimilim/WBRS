# Native profile-photo HTTP: default-off adapter and application seam

This stage adds `runtime_profile_photos_http.py`, focused HTTP/application tests
and a small optional `create_app(profile_photos_http=None)` seam. The default
module-level application does not inject a photo adapter. No environment flag,
production media factory, shared runtime-read route, legacy authorization,
client, grant, database change, deployment or activation is introduced.

The source service's original/provenance/visibility/size contract remains
[TIMEWEB_NATIVE_PROFILE_PHOTOS.md](TIMEWEB_NATIVE_PROFILE_PHOTOS.md). In
particular, these endpoints do not make an arbitrary ready or quarantine object
a profile photo, and do not support a guessed native upload provenance.

## Exact routes and input

| Method and route | Allowed query | Successful response |
| --- | --- | --- |
| `GET /v1/runtime/people/{uid}/photos` | Optional `limit` 1–30, default 30; optional opaque `cursor` | Explicit bounded JSON descriptor page |
| `GET /v1/runtime/people/{uid}/photos/content` | Exactly one opaque `reference` | Fully verified original bytes |

The target is one exact UID path component. WSGI has already URL-decoded the
path; the adapter handles its UTF-8 transport representation without unquoting
again, trimming, changing case or Unicode normalization. Embedded slash,
backslash, residual percent escapes, dot/dot-dot, control/surrogate or invalid
identifier values cannot select another UID. Trailing slashes, additional path
components, `/v1/media/...` and other public-profile routes do not match this
adapter. The independent existing routes retain their owners.

Only GET is supported; HEAD and mutations return 405 on a matched enabled route.
No request body or transfer encoding is accepted. Range and If-Range are
rejected whenever the corresponding WSGI header key is present, including an
empty value or differently cased key. There are no partial responses, range
headers, 304 handling or caller-selected content types.

Query parsing is strict UTF-8, at most 8,192 ASCII encoded characters, at most
two fields for a descriptor and one for content. Duplicate/unknown/blank opaque
parameters, malformed escapes and invalid limits return 400 before native
authorization or the lazy reader factory. Opaque cursor/reference values use
the bounded base64url alphabet with at most 4,096 characters. Their actual AEAD
actor/target/context/purpose/limit/expiry binding remains the service's job on
every current authenticated SQL read.

## Explicit injection and current authority

Constructing `RuntimeProfilePhotosHttp(env, service_factory=None)` is pure and
default-off. An adapter is enabled only with an explicitly supplied callable
factory **and** the already existing canonical runtime gates
`CLRS_RUNTIME_WRITES_ENABLED=1` and
`CLRS_RUNTIME_MEMBERSHIP_AUTHORITY=canonical-current-v1`. These gates are not
changed by this patch and do not turn on the default application's missing
injection. There is no fallback factory or fake production service.

The future private caller owns constructing the genuine
`RuntimeProfilePhotosService` from the current shared runtime store, completed
authenticated source capability, verified media-promotion acknowledgement,
private S3 bucket/owner/transport, reviewed gallery order policy, cursor key and
private spool. This adapter deliberately does not load or manufacture those
capabilities or credentials. That live factory/injection is a separate reviewed
step, not proved here.

For each matched enabled GET, validate input first, then authorize only a
`Bearer na1.` native access token with the application's current native service.
The result must be exactly `NativeIdentity`. Firebase JWTs, refresh tokens,
legacy identities, email and client claims have no authorization path. The
service then uses the same current session/account pre/post verifier inside its
fresh READ ONLY transactions.

The reader factory is invoked lazily, once, only after matching/gates/GET/input
and native authentication pass. For content, a valid authenticated media request
budget must also pass before the factory. Construction failure is unavailable
and has no automatic retry. A concurrent initialization cannot publish a second
service. Closing during initialization immediately marks the adapter closed;
the late service is closed rather than retained or used. A late descriptor or
lease after adapter closure is suppressed.

`app.py` consults only an explicitly injected adapter inside the API block,
after the existing operator preview guard and before the unrelated dispatchers.
An unauthorized preview request cannot invoke native auth, the photo factory
or the photo reader. The application close owner also closes the injected
adapter; the adapter closes its photo service/leases and does not own or close
the shared mutation pool. The existing pool owner still handles that pool.

## Response boundaries and pre-200 guard

The descriptor adapter validates the exact page/item allowlist again, exact
target UID, original MIME/size, ordered ordinal/primary types, limit, opaque
continuation and the 65,536-byte JSON budget. It forwards no raw source, storage
key, URL, role, email, content hash, session or private diagnostic fields. An
authorized empty relation stays an explicit empty descriptor page.

For content, `clrs.media_request_budget` must be supplied by the existing
`http_runtime` server. It is extended only after native authentication and must
return a finite future monotonic deadline no later than 60 seconds plus a live
`threading.Event`. The server already bounds eight request workers, two media
workers, socket inactivity at ten seconds and the total media request at sixty
seconds; its disconnect monitor cancels the same event. This patch reuses that
contract without changing its server implementation.

`open_photo` has completed its first two fresh SQL proofs and verified the
entire original spool before the HTTP adapter accepts its exact `_PhotoLease`.
The new media reply then primes one block, at most 64 KiB, by advancing
`lease.iter_bytes()` **before** calling `start_response("200 OK", ...)`. This
runs the service's third fresh current-session/target/relation proof before
headers. A failed first-byte guard can therefore still return a normal JSON
400/401/404/503 without claiming 200 or emitting any image byte. Empty iteration,
zero/oversized length and invalid MIME do not produce a healthy 200.

After that guard, headers are constructed from a fixed allowlist:
`Content-Type` is one of JPEG/PNG/WebP/GIF, `Content-Length` is the exact verified
original length of 1 through 8 MiB, `Cache-Control: private, no-store`,
`X-Content-Type-Options: nosniff`, `Content-Disposition: attachment;
filename=media`, and `Referrer-Policy: no-referrer`. There is no Location,
presigned URL, public/quarantine URL or Accept-Ranges header.

The response holds only one prefetched block and the verified anonymous spool;
it yields at most 64 KiB per block, checks cancellation/deadline/closed ownership
before each block and enforces the declared total length. WSGI response close,
disconnect, end/failure and start-response failure all close the iterator and
lease. The service's hard expiry/close registry also releases an unconsumed
lease. A start-response failure propagates after cleanup without attempting a
second JSON response. A failure after 200 terminates the stream; it never
appends an error JSON object to an image. This does not claim instantaneous
database revocation within a stream whose first-byte proof already passed.

## Error and remaining permission boundary

| Condition | HTTP result | Bearer challenge |
| --- | --- | --- |
| Default off / missing injection or gates | 404 | No |
| Current target hidden/disabled/missing or original provenance unsupported | 404 | No |
| Invalid input or stale/wrong-bound AEAD resource/cursor | 400 | No |
| Current native identity/session rejected | 401 with Bearer challenge | Yes |
| Native rate limit | 429 with Retry-After | No |
| Missing media budget, required SELECT, schema, private storage/spool or cancellation failure | 503 | No |

All error bodies contain only a fixed `error` code. Target unavailability must
not be mistaken for a broken healthy native session. The source service's
strict-role SELECT gap is unchanged: `profile_photos`, `media_objects`,
`legacy_source`, `legacy_documents`, `legacy_storage_objects` need a separately
reviewed exact permission-model extension if `strict-tables-v1` is used.
The existing provider role has broad rights; it is not described as narrow.
Nothing here changes grants or activates the currently closed private adapter.

## Focused evidence

`test_runtime_profile_photos_http.py`: **15 focused tests pass**. They use the
real current native READ ONLY store and real private S3 verifier with synthetic
SQL and GET transports. They cover descriptor options/lazy factory, default
off, exact/aliased/trailing paths, input/Range/UTF-8 refusal, native-only identity
and rate limits, authenticated budget refusal, full verified bytes and the
third proof before 200, hidden/revoked first-byte refusal, empty bytes/metadata,
failed start_response, valid B-session refusal of A's reference without a healthy
session challenge, early response close/disconnect, late post-close/factory
results, storage/DTO redaction, operator guard ordering and the unchanged
existing own-profile route.

No TCP, live database/S3, cloud, grants, DDL, deployment, flag change, APK/build
or broad test suite is used by this evidence. Existing source-service tests are
separate evidence and were not repeated by this stage. Real storage capabilities,
permission verification, deployed HTTP and client photo behavior remain
unproved/unenabled.
