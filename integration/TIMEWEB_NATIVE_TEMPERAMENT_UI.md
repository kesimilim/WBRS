# Native temperament UI and durable completion

`CLRS_TIMEWEB_TEMPERAMENT_ENABLED` defaults to false. The runtime also requires
its current own-profile destination and the existing current-read/runtime-write
client gates. Source does not activate server gates. The server mutation contract
is documented in `TIMEWEB_NATIVE_TEMPERAMENT.md`.

## Actual questionnaire and return

For a saved current profile with `onboarding: test`, `TimewebOwnProfilePage`
opens `TimewebTemperamentPage`, a thin native wrapper of the existing
`FirstGroupRed` 80-question screen. It retains the existing question wording,
minimum-20-selection instruction, CLRS design and count rules. Existing Firebase
callers keep their default submit path. Native submit returns before Firebase,
legacy globals, local group classification or Firebase SessionGate navigation.

The displayed questions alternate ten questions from brown/red/blue/white, then
repeat those four colors. The durable answer vector uses four canonical blocks
of twenty, in brown/red/blue/white order. Native submit counts that vector and
sends only the current profile revision plus the four scores. The success receipt
contains the authoritative server group; no scores or local guessed group are
adopted. On confirmed receipt the wrapper returns to the native own profile,
which performs a fresh current full-profile GET and displays the current fields.

## Original operation and account ownership

`TimewebTemperamentFlow` creates one original UUID and typed
`profile.complete-test.v1` request. Before POST it persists the 80 exact answers,
owner/origin, original revision, UUID and request hash in an application-private
journal. The additional answer-vector hash detects changes that keep equal score
counts. Journal loading rejects oversized, malformed, extra/duplicate-key or
hash-mismatched records. It persists no bearer, refresh token, email or password.

Duplicate submission shares the original Future. While posting/checking, the
screen disables interaction; an unresolved operation freezes its original
answers and exposes “Проверить результат”. A restored journal binds the original
UUID/hash/owner and may only perform receipt lookup. A lookup `not_found` retains
the journal and never resends or invents another operation. The profile also
looks for a pending journal when a fresh read already says `search`, so a lost
ACK followed by a server commit still has a reachable recovery action.

Confirmed receipts and committed refusals retire the matching journal under
current owner/epoch checks. `profile_changed`, `test_already_completed`,
`profile_incomplete` and `profile_not_found` require a fresh profile read before
another attempt. Logout/new login/disposal revoke local adoption and close the
route/fields; late A completion cannot appear or acknowledge a journal for B.
The UI retains a pending journal if closing a screen precedes receipt adoption;
closing a route does not assert server cancellation.

## Focused local evidence

Five focused tests passed together with workspace Flutter 3.32.5:

- Correct score vector, durable-before-POST record, shared duplicate Future and
  authoritative success receipt; invalid counts and answer length are refused.
- Lost ACK/restart with already-completed profile preserves the original answer
  vector and uses lookup only; `not_found` never resends; malformed or changed
  journal data is refused.
- All four typed server refusal receipts settle once and require reload.
- A/B login during journal acknowledgement revokes the old A completion and
  retains the original durable answers.
- Actual native gate → own profile → existing 80-question screen → minimum 20
  selections → equal 5/5/5/5 scores → server-selected group → fresh native full
  profile. One POST, journal removal, empty `Firebase.apps` and 360 px layout
  are checked. The question layout contains no keyboard input and was unchanged.

```sh
# cwd: work/wbrs_github_dev_review
../toolchains/flutter-3.32.5/bin/flutter test --no-pub --reporter expanded \
  test/timeweb_temperament_flow_test.dart test/timeweb_temperament_ui_test.dart
```

The tests use synthetic HTTP fixtures and a temporary real private-directory
journal. Current profile labels use existing translations when meaningful;
seven missing short field/state labels are manually present in all 23 bundled
catalogs. The local presence audit covers all 41 own-profile/native-test UI
messages. No paid provider or automatic cloud translation was requested.

This is source and focused local evidence. No APK/build, live API/SQL write,
deployment, flag activation, cloud operation or paid resource was used. APK
1.0.25-43 predates this source and cannot prove it. Final source synchronization,
controlled device/live acceptance, native profile creation/registration and
current media remain separate migration work.
