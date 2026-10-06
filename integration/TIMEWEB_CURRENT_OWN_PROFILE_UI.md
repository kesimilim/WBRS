# Current native own profile UI

The native runtime has a separate current own-profile destination over
`GET /v1/runtime/me/full-profile`. It uses the current SQL contract documented in
`TIMEWEB_CURRENT_OWN_PROFILE.md`. The old reviewed snapshot DTO/read route is
not used by this enabled destination, and no current profile is hydrated into
legacy Firebase globals or financial state.

## Selection and reachability

`CLRS_TIMEWEB_OWN_PROFILE_ENABLED` defaults to false. `AppBackend` passes it as
`TimewebAppRuntime.currentOwnProfileEnabled`; the runtime also requires the
existing current-reads/runtime-writes client gates. The client does not enable
any server gate. Native auth selection still requires the existing configuration,
public API origin, protected token store, device metadata and source pin.

When this destination is enabled, `TimewebSessionGate` loads the current own
profile and displays `TimewebOwnProfilePage` as its actual signed-in page. A
failed read stays on this native page with retry. A missing row stays visibly
missing. It cannot enter Firebase Home/Search/Test or the old snapshot gate.

When their separate gates are enabled, the profile has both an existing native
editor action and a current-chats action. The editor is obtained through
`runtime.openProfileEditor()` only when opened. Every return from the editor
obtains a fresh current full-profile GET; a receipt or immutable import snapshot
is not reused as the full displayed profile. Chats open the existing
`TimewebChatsPage` over a freshly authorized current read.

## Data and visible states

The client accepts only the exact six-key envelope and eighteen-key profile,
matching the canonical authority, authenticated UID and onboarding decision.
Text preserves original Unicode and whitespace. It enforces the SQL source
character/UTF-8 bounds, age 0..130, height 0..300, nullable booleans, and the
existing microsecond UTC stamp. Historical zero/short/null fields do not become
new-edit defaults. The legacy onboarding fallback trims only the full name;
nonempty pol/about/hobbi retain their exact source meaning. Secondary or unknown
primary groups cannot assert completed onboarding.

The page reuses `ClrsScaffold`, `ClrsLogo`, `ClrsMotto`, `ClrsPanel`, `GroupRing`,
`LrsTheme`, the 14 px profile margins/section spacing and `ClrsValuesFooter` from
the approved profile treatment. The unavailable photo has a visible placeholder;
there is no fake gallery, online/offline claim, balance, gifts or unsupported
native action. Nullable children remain “Не указано”; false is displayed as
“Нет”. Missing/incomplete/test-required profiles have distinct truthful messages.
The screen does not create a profile or save registration. Test completion now
has a separate default-off native flow documented in
`TIMEWEB_NATIVE_TEMPERAMENT_UI.md`. User fields render as plain current text
without a Firebase translation request.

## Ownership and bounded transport

The fixed own GET accepts no caller UID/query/body. It shares the native client
bearer, refresh owner, four-slot HTTP budget and hard request deadline. Redirect,
public cache, invalid encoding/length/body and non-JSON responses are rejected;
the entire payload is bounded to 65536 bytes. Duplicate reads in the same client
epoch share one flight. Logout/relogin/stop immediately abort stale reads; the
real stream cleanup retains the transport slot until it settles.

Both the envelope and nested profile getters carry the native client guard and
`AppSessionLease`. This revokes retained A data at the new login intent, before a
potentially delayed local clear can call the client adapter. The page also checks
its facade epoch before displaying/opening routes/adopting a read. Invalidation
clears its DTO and editor reference; the existing editor closes its fields/route.
Disposal revokes local adoption and does not assert server cancellation.

## Focused local evidence

Seven focused checks in `test/timeweb_current_own_profile_test.dart` passed:

- Current exact GET, preserved source values/null/zero, missing profile and all
  onboarding decisions, including whitespace historical fallback; default off.
- Exact shape/authority/UID/type/group/size/stamp refusal and disabled transport.
- Shared read, logout/relogin A/B, nested DTO revocation and late A response.
- Hard deadline/abort plus 64 KiB, public-cache and redirect refusal.
- Delayed local clear proves facade intent revokes every retained field before
  the client changes account.
- Actual native gate → own profile → existing editor → one confirmed save →
  fresh full-profile read, with profile/chats actions together and no Firebase.
- 360 px layout, long name and keyboard; late A/B read cannot display A, and a
  new same-account login intent clears/closes an already open editor.

The first six passed together; the final layout scenario passed independently
after correcting its test scroll to reach a lazily built action. No broader
suite or APK build was run for this block. Scoped analysis found no new errors or
warnings; three pre-existing curly-brace info findings remain in the shared auth
client. HTTP fixtures are synthetic; the editor journal uses a temporary real
local directory. `Firebase.apps` remains empty in the UI checks.

```sh
# cwd: work/wbrs_github_dev_review
../toolchains/flutter-3.32.5/bin/flutter test --no-pub --reporter expanded \
  test/timeweb_current_own_profile_test.dart
```

This is source and focused local evidence only. It adds no live/cloud/API/SQL
write, deployment, flag activation or paid resource. The previously built
1.0.25-43 APK predates the new profile/chat source, so it does not contain or
prove this implementation. Final source synchronization/cutover, native profile
creation/registration, current media and device/live acceptance remain separate
unfinished migration work. Test completion has separate source-only evidence and
is still disabled until final synchronization and controlled live acceptance.

The current profile UI reuses existing bundled messages where their meaning
matches. Seven short missing field/state labels are supplied manually in all
23 bundled catalogs; the combined own-profile/native-test UI uses 41 catalog
messages and the local key-presence check found no missing values. This check
confirms coverage, not device acceptance or professional linguistic review.
