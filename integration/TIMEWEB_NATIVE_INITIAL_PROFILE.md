# Native initial own profile finish — isolated source

This operation updates the existing canonical own profile created atomically by
native registration. It creates no profile, media or association rows and does
not modify `legacy_raw`, group/test values, completion, city or language.
No credentials, permissions, public flags or cloud state are changed.

## Exact wire

`POST /v1/runtime/me/registration`, operation `profile.finish-registration.v1`.
Body: `operationId`, `expectedUpdatedAt`, `changes`, `geography`, `photos` only.
`changes` has exactly the existing eight edit fields: fullName, age, rost, about,
hobbi, deti, pol, relationStatus. Existing `validate_profile_edit` normalizes and
validates those values; the receipt hashes the bounded original input first.
`geography` is exact `{countryCode,region}` from the pinned local catalog; country
is derived on the server. `photos` has exactly three distinct pointers, each
`{mediaId,prepareOperationId,commitOperationId}`. UUIDs use the existing lower-case
canonical version 1..8/RFC variant validator. No owner, URLs, raw or origins.

Success HTTP 200 / committed receipt / entityRevision null, exact result:
`{uid,profileDetailsSaved:true,onboarding:'test',updatedAt,profileAuthority:'canonical-current-v1'}`.
Declared committed 404: profile_not_found, photo_not_found.
Declared committed 409: photo_not_ready; profile_changed,
registration_already_saved and registration_already_completed include updatedAt.
A missing/lost target during receipt proof gives short 404 registration_unavailable
without native logout. Other short/unreceipted failures do not confirm an intent.
Original reconciliation remains `GET /v1/runtime/operations/profile.finish-registration.v1/{originalUUID}?requestHash={originalHash}`.

## Atomic authority and proof

The shared store checks current native account/session before and after the
transaction. Only exact owning profile flags saved=0/completed=0 are eligible;
recognized/completed group and already-saved profiles refuse. Nullable flags are
not accepted as evidence of a native blank profile. Exact updated-at CAS protects
another device's edits. One UPDATE writes validated eight fields/geography and
saved=1, preserves every other profile field, and advances the timestamp.

Three current owner ready media/association rows must have server-derived native
IDs/keys. The existing photo SQL core checks all required bounded unique indexes,
owner/purpose, no legacy path/thumbnail, original prepare receipt and immutable
metadata. Finish also checks each original commit UUID/hash, HTTP 200/entity null,
ready result, ordinal/primary/current association and receipt stamp. Proofs are
rechecked after UPDATE. This is SQL proof of the previously verified upload; it
performs no S3 call and does not turn an arbitrary ready row into a photo proof.

One photo service instance is reused per shared runtime store; its writer is None.
The factory creates this service only under the existing provider permission model;
strict-table runtime services remain unchanged and finish is unavailable there.
The outer runtime closes the one store/transaction pool; finish owns no extra IO
worker/pool, lease or S3 flight. Photo routes and serving are not mounted here.

Original success lookup checks current owner/profile and all three photo proofs.
It returns the historical result after later legitimate edits/test completion,
without resetting onboarding or replaying an UPDATE. Lost COMMIT is original
lookup only; not_found does not initiate another operation.

## Local evidence and next boundary

`python3 -B -m unittest test_runtime_initial_profile -v`: five focused scenario
groups PASS first run, 0.177s. The fixture runs the actual mutation store/photo SQL
core with synthetic MySQL/S3 data; no real provider object or SQL state is touched.
Cases cover one CAS/hash/owner, historical result, unknown COMMIT, changed UUID/hash,
three receipt/pending/owner/index/flag refusals, revocation and post-UPDATE/receipt
rollback, bounded query count, wire/catalog validation and closed shared factory.
No old test modules are run; their fixture helpers alone are imported.

Existing `RuntimeProfileService.complete_test` was read, not changed or executed:
for raw={} with saved=false it requires retained legacy details proof and refuses.
After this operation sets saved=true with validated real details, that legacy-proof
branch is skipped. This confirms the source eligibility path only, not an executed
native questionnaire/registration flow or live rollout. The next client work is
initial form + three actual uploads + finish/current reread on the same native
owner. Provider conditional PUT/checksum/privacy evidence, serving and production
activation remain separate required work; no final migration/cutover claim.
