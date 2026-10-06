# Current native profile fields

The native current editor now saves the existing editable profile's name, age,
height, children, interests and description. Their order follows
`ProfilePageEdit`: name, age, height, children, interests, description. The
existing CLRS scaffold, background, panel and form treatment are reused. Age,
height and children use existing localization keys; no labels or enum values
were added to the catalogs.

`TimewebProfileEditFlow.save` and `hasChanges` retain their original three
required text arguments. New optional `age`, `rost`, `deti`, `pol` and
`relationStatus` arguments use the existing `TimewebProfileChanges` transport
contract. Only changed, non-null optional fields are sent. The UI exposes age,
height and children; gender and relationship status remain unchanged by this
form. Existing gender/status values are neither normalized nor replaced.

Changed age must be an integer from 18 to 100; changed height must be an integer
from 1 to 300, matching the reviewed native mutation bounds. Empty/malformed
changed numbers are refused in the form. Imported null/0/older ages, nullable
children and short/null descriptions are preserved when untouched. Children
starts with no selection when the current value is null: selecting Yes or No
explicitly sends a boolean. This contract does not clear an existing value to
null. Changed descriptions retain the existing 20-character validation and
original entered text is preserved.

The private journal still uses version 1 and its exact eight-key envelope. Old
three-text-field intents remain readable with their original UUID, CAS stamp
and hash. Its allowed change map now contains at most the eight reviewed fields:
strings for name/about/interests/gender/status, integers for age/height and a
boolean for children. Nulls, numeric strings, doubles, coerced booleans,
unsupported fields, invalid bounds or invalid hashes fail closed. Reads and
writes retain the 64 KiB bound and immutable unresolved-entry rule.

The exact typed input, owner/origin, UUID, current revision and request hash are
flushed before POST. Duplicate saves observe the same operation. Lost ACK and
restart retain the original operation, and checking uses its receipt GET only.
A `not_found` result keeps the journal and cannot start a replacement POST.
Matching acknowledgement retires only that journal. Existing owner/session
leases and A/B/ABA invalidation behavior remain in force. Journals contain
profile data, not credentials; this change makes no claim about OS encryption
or device backup behavior.

Focused local checks:

- Eight-field mixed string/int/bool POST, real disk persistence before POST,
  duplicate save, lost ACK, restarted flow, matching original UUID/hash lookup,
  `not_found` retention and eventual acknowledgement.
- Hand-built old version-1 text intent; exact-type, field and size refusals
  before any mutation or receipt lookup.
- Original three-field save preserving imported age 0, nullable height/children,
  short about text, null interests and historical gender/status.
- Actual 360-pixel form: nullable children, invalid age/height blocking POST,
  mixed name/age/height/children save, busy field locks and acknowledged close.
- Existing profile editor regression checks: CAS refusal, restart, digest and
  real IO draining; gate-to-editor save and pending A-to-B invalidation.

Validation commands (installed Flutter 3.32.5, no dependency installation):

```sh
../toolchains/flutter-3.32.5/bin/flutter test --no-pub --reporter expanded \
  test/timeweb_profile_fields_test.dart test/timeweb_profile_edit_flow_test.dart
../toolchains/flutter-3.32.5/bin/cache/dart-sdk/bin/dart analyze \
  lib/service/timeweb_profile_edit_flow.dart \
  lib/presentation/screens/edit_profile/timeweb_profile_edit_page.dart \
  test/timeweb_profile_fields_test.dart
```

Result on 2026-10-02: all six focused tests passed, and scoped analysis reported
`No issues found!` for the three listed Dart paths.

These checks use synthetic HTTP with a real temporary private journal. They do
not establish a deployed Timeweb service or device acceptance. Geography,
photos, registration completion, test/group, backend activation and the
three-photo requirement for a new registration are outside this change.

## Optional current-geography navigation hook

`TimewebProfileEditPage` accepts an optional
`Future<bool?> Function(BuildContext context)? onEditLocation` callback. When
supplied, an existing localized `Выберите страну и регион.` button appears after
height and before children, at the existing editor's geography position. The
default constructor continues to show no geography control.

The button is disabled while the editor is busy, pending reconciliation,
requires a reread, has a stale session, or has any unsaved name, age, height,
description, interests or children change. Draft comparison uses original raw
numeric text without parsing invalid input or discarding it. Source comparisons
are short-circuited for a pending/revoked flow. Text controller changes update
the button immediately.

The editor invokes the original callback once and blocks its other controls
through its lifetime. The interactive route has no selection timeout; the
geography page/flow owns network deadlines. A false/null result keeps this same
editor and its values. A true result means a geography save was confirmed and
closes the editor with `pop(true)` so its caller can reread the new profile
revision instead of continuing with stale CAS. Disposal, route/session checks
prevent adopting a result into a different owner or route. Callback errors use
the existing localized unavailable-section message.

One new 360-pixel widget check passed: default absence, all five text/numeric
drafts and children disabling navigation, null/false cancellation preserving
the form, busy controls after 30 seconds of selection, and confirmed closure
without a profile POST. Existing six field/regression checks were not rerun for
this navigation-only follow-up. Scoped analysis of the changed editor and test
reported `No issues found!`.

```sh
../toolchains/flutter-3.32.5/bin/flutter test --no-pub --reporter expanded \
  test/timeweb_profile_fields_test.dart --plain-name \
  '360px location hook hides by default, blocks drafts, preserves cancel and closes on confirmed save'
../toolchains/flutter-3.32.5/bin/cache/dart-sdk/bin/dart analyze \
  lib/presentation/screens/edit_profile/timeweb_profile_edit_page.dart \
  test/timeweb_profile_fields_test.dart
```

This hook does not implement the geography transport or enable its production
configuration. Its callback must return true only after confirmed native save.
