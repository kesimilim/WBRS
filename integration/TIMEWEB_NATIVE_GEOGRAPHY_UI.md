# Native geography client, durable flow and UI

The existing `CLRS_TIMEWEB_PROFILE_EDITOR_ENABLED` release-off gate controls
`TimewebAppRuntime.openGeography(currentSnapshot)`. The runtime additionally
requires its existing runtime-write client gate. No source change enables flags,
server routes or a deployed environment. The exact server contract is documented
in `TIMEWEB_NATIVE_GEOGRAPHY.md`.

## Exact pair and canonical receipt

`TimewebGeographyChanges.fromCatalog()` accepts only both `countryCode` and
`region`, validates the bytes of the approved local `assets/geo_catalog.json`
against SHA-256
`6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05`, and accepts
only exact membership. It preserves the original case/Unicode/whitespace; empty,
unknown, lower-case or padded replacements cannot silently normalize. The asset
has 56 countries, each with a nonempty region list. No external catalog request
or caller-supplied country text is used.

The typed mutation is `profile.edit-geography.v1`, fixed POST
`/v1/runtime/me/geography`, body `{operationId, expectedUpdatedAt,
changes: {countryCode, region}}`. The existing canonical hash excludes
operationId and includes the original revision/pair. The client accepts only a
null-revision success receipt with the six exact result fields
`uid/country/countryCode/region/updatedAt/profileAuthority`. It checks owner,
canonical authority, exact selected pair and the server-derived country name
against the approved catalog. No city/language/media/financial/registration field
is accepted. No-op server results may retain the original revision.

Typed committed refusals are `profile_changed` with updatedAt (409),
`profile_not_ready` (409), and `profile_not_found` (404). They retire the settled
original request and require a fresh current profile before another attempt.
The client never infers successful write completion from local selected values.

## Durable original request and ownership

`TimewebGeographyFlow` opens from the current native owner/session lease and
canonical full-profile DTO. Fresh edits require completed/recognized onboarding
or saved profile details with a real name, age, gender and nonempty descriptions,
matching the backend geography boundary. A blank registration is rejected; this
flow does not complete registration or satisfy photo requirements. A retained
journal may still be looked up when the current row is no longer eligible.

Before POST, `TimewebGeographyJournal` atomically flushes and renames the exact
pair, original UUID/hash/revision/owner/origin into an application-private owner
file. The compact exact JSON is bounded to 8192 bytes, rejects duplicates and
unexpected fields, and revalidates the pinned pair/hash on recovery. It contains
no credential, email or token. Duplicate taps share the original Future.
Restored requests are lookup-only; not_found and malformed lookup receipts retain
the journal and never authorize a resend/new UUID. Stop drains local journal IO.

The snapshot, flow and retained success DTO are guarded by current owner/epoch
and local lifetime. Closing the screen revokes adoption, while an unresolved
request stays durable. Account B cannot adopt A fields or acknowledge A's
pending journal. Route disposal does not claim to cancel a server commit.

## Existing UI and integrated hook

`TimewebGeographyPage` uses the existing `MeetingLocationFields`, `ClrsScaffold`,
CLRS logo/panels/footer and existing localized Save/Check-result messages. The
same approved country/region dropdowns are used; changing country clears an
incompatible region. Controls are disabled while saving or checking an original
request. The nested Navigator contains only this form and its dropdown popups;
ordinary back closes a popup first. On invalidation the page removes only its
own outer route, so a newer unrelated B route is preserved.

The editor hook is integrated separately by the root agent: the own-profile
page obtains a fresh snapshot, opens this geography flow and pushes the page
from the live editor context. Confirmed true closes the old editor and causes a
fresh current full-profile GET; this prevents using its old CAS revision.
Unsaved editor drafts and unresolved edits disable the geography action.
Cancel preserves the existing editor. No Firebase call or global hydration is
involved. A pending geography operation remains reachable through this action
after restart. The flow/page introduce no new translation keys: all 67 unique
UI/country/region-label messages are present in all 23 bundled catalogs. Region
values display their approved source spelling.

## Focused local evidence

Five scenarios in `test/timeweb_geography_test.dart` passed with workspace
Flutter 3.32.5, in targeted 3-flow / 1-popup / 1-integrated-UI invocations:

- Exact approved country/region selection, durable-before-POST record and one
  shared duplicate Future; canonical derived country receipt; invalid pairs and
  blank registration refused; all three typed server refusal receipts settle.
- Lost ACK/restart restores exact original UUID/hash/pair and performs lookup
  only. not_found and forged country receipt retain the journal/no extra POST;
  damaged hash, duplicate JSON keys and oversized journal are refused.
- Login A→B while acknowledgement waits on journal IO revokes A field access
  and retains A's original journal; B gets its own current fields.
- A region popup→B intent→new unrelated B route before the next frame removes
  A's page/popup while preserving B's route. No write or Firebase is invoked.
- Actual gate→own profile→editor→geography, real dropdown taps at 360 px,
  one durable POST/receipt, disabled pending controls, closed old editor and
  fresh full-profile read displaying the new country/region. Firebase.apps is
  empty and layout has no exception.

```sh
# cwd: work/wbrs_github_dev_review
../toolchains/flutter-3.32.5/bin/flutter test --no-pub --reporter expanded \
  test/timeweb_geography_test.dart
```

Scoped analysis of the eight client/flow/runtime/page/hook/test files found
no errors or warnings. Sixteen pre-existing curly-brace info statements in the
shared client/mutations are unchanged HEAD lines; no new info was introduced.
`git diff --check` is clean.

Fixtures are synthetic HTTP; journals use temporary real directories. This
source evidence does not establish deployment or live/device acceptance. No
build/APK, Git commit/push, flag activation, schema change, live API/SQL write,
cloud service or paid resource was performed by this client block. Previously
built APK 1.0.25-43 predates this code. Final synchronization and controlled
live/device acceptance remain necessary.
