# Prepared native startup and login

Firebase remains the default. `CLRS_APP_BACKEND=timeweb` selects a separate
runtime only with `CLRS_TIMEWEB_AUTH_ENABLED=true`, a valid public HTTPS
`CLRS_TIMEWEB_API_ORIGIN`, and the reviewed 64-hex
`CLRS_TIMEWEB_SOURCE_SNAPSHOT` pin. No release flags were enabled by this change.
The Android Keystore bridge is the only production token-store implementation;
other platforms fail closed rather than use preferences/plaintext fallback.

`AppBackend.initialize` owns one `TimewebAppRuntime`, one native auth client,
one real `AppSession.timeweb` and a stable, non-secret install device ID. Native
Dart startup bypasses explicit Firebase initialization, Firestore, FirebaseAuth, Crashlytics,
Messaging, presence and old notification navigation. The background FCM entry
point also rejects native mode. Android SDK auto-initialization/providers have
not been inspected or proven disabled by this Dart change. Email signup/reset are bound to that same owner,
with their existing separate enable gates still false by default.

The existing LoginPage retains its design. Only the Firebase branch creates
AuthService. Native login preserves the original email/password bytes, shares
the original pending attempt and opens only TimewebSessionGate after confirmed
identity. It never creates a Firebase User or enters Firebase SessionGate/Home.
A terminal unknown login has no receipt lookup route: the screen does not
automatically repeat that POST or report successful login.

Native remember selection uses separate `timeweb_remember_me`/`timeweb_email`
preferences. Neither stores credentials. A serialized policy layer delegates
all actual token IO to the protected store. With remember=false, prior disk
tokens are cleared and login/refresh tokens stay only in the existing client's
memory. Cold start cannot silently restore that temporary session. Unknown
policy clearing stops that owner and prevents a new login. Runtime stop awaits
the actual original auth/store drain, including a pending facade result, and
preserves remembered credentials. Screen disposal and backgrounding do not
log out the runtime; app teardown uses stop, never destructive client.close.

The gate calls the real pinned `/v1/me/full-profile` through both native and
facade leases. Its complete typed historical DTO supplies registration/test/
search onboarding state. Missing or corrupt fields are not converted to success.
The DTO explicitly declares `immutable-reviewed-snapshot`, `readOnly=true` and
`mediaReady=false`: it is not hydrated into SessionService/current Home data.
The UI uses existing localized unavailable/retry/logout text and exposes no
source pin, provider labels or implementation details.

## Remaining cutover work

- The full historical own-profile fields and stage already exist; this is not
  the old six-field profile gap. Current `/v1/runtime/me/profile` supplies eight
  editable fields, two saved/completed flags and a CAS stamp, but deliberately
  cannot create/finish onboarding, set geography, promote photos/main-photo,
  complete the questionnaire or establish its current group. Signup creates an
  empty canonical profile with both onboarding flags false.
- Native registration/test/search destinations need those current capabilities
  and complete native Home service binding before this gate can open them.
  Existing Firebase widgets cannot be used as a shortcut.
- Protected-store restart/false-remember/unknown-clear/actual pending-drain and
  LoginPage pending/late-A-after-B behavior were checked with synthetic HTTP and
  a fake platform driving the real Dart protected-store adapter. Real Android
  device/Keystore restart, deployed auth/SMTP, final consistent source sync and
  production cutover are not proven by these tests. No APK was built.
