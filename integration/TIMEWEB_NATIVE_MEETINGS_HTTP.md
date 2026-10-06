# Native meeting HTTP: bounded default-closed adapter

Status: source adapter/dispatcher seam and targeted synthetic HTTP checks passed
locally. No deploy, SQL/schema/grant change, cloud call, new pool, write, client
page, APK or public flag activation is included. This does not enable imported
meetings or prove production cutover.

## Integration and current authority

`RuntimeMeetingsHttp(env, store, service_factory=None)` uses the existing
caller-owned `RuntimeMutationStore`. The small `RuntimeReadHttp` seam adds the
optional `meetings_factory`, dispatches matching meeting routes to this adapter
and closes its references when the read dispatcher closes. Existing runtime
mutation/app dispatch already delegates to `RuntimeReadHttp`; no top-level
mutation/app code was changed. Existing chat/people/admin parsing, mutation
handoff and store ownership remain the same.

Reader construction is lazy, at most once per adapter, after a matching enabled
GET has passed strict input/header checks and native authorization. The injected
trusted factory receives that same store and a copied environment. The adapter
does not construct or close a SQL pool, does not persist identity/cursor/token,
and does not supply/infer a visibility policy. Close drops its reader and rejects
a result completed after close; actual active SQL cancellation/drain and final
pool close remain with the existing parent store owner.

The normal factory is frozen `RuntimeMeetingsService.from_env(store, env)` with
**no trusted_policy argument**. It returns None by default. An environment
variable containing a policy label, canonical row or empty `legacy_raw={}` does
not change that. Under the existing enabled runtime gates, unavailable/None/
failed factory or missing store returns 503; disabled runtime gates return 404 for
a valid meeting route. There is no new public flag or origin/visibility
classification in this adapter, and no Firebase/legacy fallback.

A future independently reviewed integration can inject a reader factory only
after acquiring real native/imported provenance and permissions proof. Frozen
native projection authority, audience rules, bounded indexed SQL and current
token checks are documented in `TIMEWEB_NATIVE_MEETINGS.md`. Imported review
proposals in `TIMEWEB_IMPORTED_MEETING_REVIEW.md` retain nonempty source and are
not consumed by this factory. No trusted imported cap is obtained or inferred
by HTTP. Factory failures/None stay unavailable for that adapter instance;
there is no automatic alternative authority or repeated pool initialization.

## Routes and input boundaries

| GET path | Allowed query | Current reader method |
| --- | --- | --- |
| `/v1/runtime/meetings` | `scope`, `limit`, `cursor`, `countryCode`, `region` | `meetings` |
| `/v1/runtime/meetings/{id}` | none | `meeting` |
| `/v1/runtime/meetings/{id}/participants` | `limit`, `cursor` | `participants` |

Scope defaults group and accepts exactly group/individual. Limit defaults 30 and
must be canonical decimal 1..30, with no sign/leading zero/blank. List geography
uses the existing pinned catalog validation: exact uppercase country code,
region requires country and exact membership, no trim/case/name rewrite. No
caller-selected actor, organizer, invitee, audience or trusted policy is allowed.

Query string is ASCII transport text at most 8192 characters, strict percent
syntax/UTF8 decoding, no duplicate/unknown parameters, at most five list/two
roster/zero detail fields. Cursor is nonempty base64url-style opaque text at
most 4096 characters. The adapter validates transport syntax only; the frozen
current service decrypts and verifies actual actor, scope, exact filters, limit,
resource, purpose and the original five-minute window on every continuation.
No plaintext anchor/cursor secret or journal is introduced.

PATH_INFO is bounded 1000 characters, interpreted as already URL-decoded WSGI
UTF8 (or trusted decoded Unicode) and never percent-decoded again. Resource ID
uses the same bounded canonical UID/ID validator, with no slash/dot traversal,
C0/DEL/surrogates or second-escape/backslash/query/fragment alias. Invalid paths
within the meeting namespace return 400; unrelated paths return None to preserve
existing dispatcher handoff. This is a GET-only adapter: other methods on its
valid routes return 405 and no request body is read.

Any transfer-encoding header, or Content-Length other than absent/empty/exact 0,
is400. Header must be exact `Bearer na1.<session>.<signature>`, bounded 135
characters, no token whitespace/comma/extra suffix and valid canonical native
token encoding. The existing native authorization facade must be configured and
return exact `NativeIdentity`; Firebase credentials/legacy identity never qualify.
The same original token is passed to the frozen reader, whose existing shared
store validates current native account/session before **and after** actual SQL.
Wrong identity returned by a broken native facade is unavailable, not a fallback
or invented current actor.

## Output and errors

The payloads are exactly the frozen current projection envelopes in
`TIMEWEB_NATIVE_MEETINGS.md`: list `kind/ordering/scope/items/nextCursor/mediaReady`,
detail `kind/meeting/mediaReady`, roster
`kind/meetingId/ordering/items/nextCursor/mediaReady`.
Every exact item allowlist is revalidated before HTTP 200, including requested
resource/scope/filter match, ascending keyset order/unique IDs, item count≤limit,
bounded nullable strings/timestamps, nonnegative integer revision, media/avatar
NULL and mediaReady false. Unknown/private keys, malformed/wrong-target output,
incorrect order, repeated output cursor or an oversized envelope fail 503 with no
partial data. Raw, email, role, balance, URL and source blobs cannot be forwarded.

JSON is validated at≤65536 bytes. The current service packs complete fields
within this limit; HTTP never truncates fields. Empty sparse list/roster pages
with a valid nonnull cursor are accepted. They need an explicit client Load more
control and do not mean there are no matches; no automatic sparse-page loop is
implemented here. HTTP does not reopen a cursor or renew its window.

| Condition | Status/body | Authentication effect |
| --- | --- | --- |
| Current hidden/deleted/kicked/private/missing target (`RuntimeReadRejected`) |404 `not_found` | No authenticate flag; healthy actor remains signed in |
| Bad native header/token/current actor/session (`NativeRejected`/`RuntimeRejected`) |401 `unauthorized` | Authenticate flag true |
| Invalid input/cursor binding or expiry |400 `invalid_request` | No authenticate flag |
| Valid non-GET route |405 `method_not_allowed` | No authenticate flag |
| Native rate limit |429 `rate_limited` | Retry flag true |
| Missing/unreviewed authority, unavailable service, malformed output or closed adapter |503 `service_unavailable` | No authenticate flag |
| Existing runtime gates disabled, valid meeting route |404 `not_found` | No authenticate flag |

Only bounded generic product errors are returned; internal exceptions do not
include UID/path/raw/token or source diagnostics. The existing app JSON responder
already supplies no-store, nosniff and no-referrer headers, WWW-Authenticate only
for the authenticate flag and Retry-After only for retry. That responder was not
changed or production-tested by this patch.

## Targeted evidence

Ten distinct new `test_runtime_meetings_http` scenarios passed. Synthetic cases
use the actual frozen `RuntimeMeetingsService` and actual
`RuntimeMutationStore.read_authenticated` with MySQL-shaped read-only fixtures,
native tokens and A/B sessions, without TCP/cloud/current users:

- default policy/factory unavailable even for empty raw, disabled gates and lazy
  factory/store ownership;
- real list/detail/participants, Unicode WSGI path, exact geo and nullable bytes;
- duplicate/unknown/oversized/invalid query, body and path rejection before auth;
- native-only header/method/identity/rate-limit failures;
- current hidden/deleted/kicked/private/imported target 404 without healthy logout;
- real opaque actor/scope/filter/limit/resource/purpose/expiry checks;
- sparse empty continuation and complete real text envelope≤64KiB;
- malformed/private/mismatched/oversized injected reader output rejection;
- revocation during the real read and dropping late result after close, without
  closing the caller-owned pool;
- actual read dispatcher injection, existing chat GET and unrelated POST handoff.

Initial targeted run had eight passing cases and two test-fixture mistakes;
only those corrected cases were rerun and passed. Separately, only the two
existing affected read-dispatcher tests for POST handoff/method rules and shared
close ownership were run; both passed. Total: 12 distinct targeted cases confirmed,
no repeat of the frozen meeting projection/import review suites or broad tests.
Scoped Python compilation and whitespace checks passed.

Remaining: reviewed production factory/provenance/current source caps, meeting
SELECT permissions and actual SQL proof, optional top-level reviewed injection,
client pages/cursor continuation, approved imported local date/historical join
display, deployment and controlled native A/B/live acceptance. This source
adapter deliberately remains unavailable until those authority prerequisites
are explicitly handled.

## Source binding

| Source | SHA-256 |
| --- | --- |
| `server/timeweb/python-stand/runtime_meetings_http.py` | `370d7218a6b29fee57ec925d25903bba2ee50bf5e67e786e4b52fe068ae78ece` |
| `server/timeweb/python-stand/test_runtime_meetings_http.py` | `84620ef2ba2b0b25d5edd7282ab07e90fc29abb4cc8f9d387deb7cdee950f464` |
| `server/timeweb/python-stand/runtime_read_http.py` | `8783de8d1193d49e91ce1a86dfd901d10a999855a51697ee13bff58ffb8e9b48` |

Sorted compact JSON source manifest SHA-256: `6e29a759a2fdf74ad8050129c2c9a6deff46033c595747080e5481e5209f29e0`.
