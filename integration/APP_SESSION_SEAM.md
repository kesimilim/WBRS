# Provider-neutral session seam

This seam is implemented and locally checked, but **not installed in UI or
AppBackend**. The current APK still uses Firebase. It does not authorize a
Timeweb cutover or make incomplete native signup/reset/admin APIs available.

`AppSession` defaults to `AppSessionBackend.firebase` and requires an adapter
with the same backend. For the existing provider, construct
`FirebaseAppSessionAdapter(auth: firebaseAuth,
signOut: AuthService(auth: firebaseAuth).signOut)` and pass
`SessionService.clearLocal` as the facade's `clearLocal` callback. The Firebase
bridge maps real SDK User objects to immutable identities. It does not invent
a Firebase User, retrieve administrator claims or alter the existing globals.

`AppSession.timeweb(client: nativeClient, clearLocal: ...)` selects only the
reviewed native client. Tokens remain in its protected store/transport. Native
identity has no email/name or administrator authority in the current response;
administrator state remains `unknown` and `isAdministrator` is false.

Consumers read `state` when subscribing to the broadcast `states` stream. Only
`state.authenticated`/`currentUid` authorize account-specific UI. They must not
use `FirebaseAuth.currentUser`, saved preferences or a second provider as a
fallback after selecting Timeweb. Use `captureLease().requireCurrent()` around
screen work or `runAuthenticated((lease) async { ... })` for provider reads;
the latter also detects native token invalidation that has no SDK event stream.
Keep one application-scoped facade. `close()` intentionally clears credentials;
normal widget/application disposal, process/engine shutdown, restart, navigation,
or backgrounding must not call it. `stop()` is the separate remembered-session
teardown: it immediately invalidates this owner and its leases, blocks new work,
cancels actual native read/media requests and detaches Firebase subscriptions.
It does not initiate protected-store clearing, Firebase signOut or remote logout.
Backgrounding alone need not stop an application-scoped owner; a stopped owner
cannot resume and must be replaced only after its actual `settled` drain.

Already started login/refresh and actual protected-store writes drain before
handoff. A successful rotating refresh is saved even after runtime teardown,
while its old identity cannot be adopted. Existing auth failure invalidation
is preserved: an unknown refresh may clear unsafe tokens and require a new
login, without retrying the old refresh. `stop` returning `remoteUnknown` must
not be described as confirmed remote authentication or logout. A failed stop
with `secureStore` is not safe handoff; do not construct a replacement owner or
silently read old credentials until the protected-store problem is resolved.
The store interface has no durable unknown-state marker, so an unsuccessful
handoff must not be bypassed. `close()` remains explicitly destructive.

`restore`, `login`, `refresh`, `logout`, `stop`, and `close` return `AppSessionResult`.
A UI deadline returns `pending` with `settled` pointing to the original
operation. The operation remains serialized; late A cannot become B's data.
Duplicate taps for the same email/device share the original login. Unknown
native POST outcomes remain `remoteUnknown`; nothing retries a login POST.
Logout immediately revokes the facade lease and starts queued local clearing.
The next identity is exposed only after preceding clears finish successfully.
Inspect `logout.remoteConfirmed` separately from local clearing: Firebase SDK
signOut confirms only local logout, and cannot confirm logout of all devices.

Focused session tests cover pending/unknown auth, actual native-client mapping,
failed secure clearing, shared refresh, duplicate taps, bootstrap events,
overlapping clears, logout/close during login, and A -> B -> A isolation. Source
analysis also includes the real Firebase SDK adapter. Its Firebase A/B behavior
is source-reviewed only; no offline FirebaseAuth fake or live Firebase runtime
test was run for that bridge. Live old-password success is also a separate check,
not claimed by these tests. After switching only the three new test imports to
the already-declared `flutter_test` dependency, the actual main-project Flutter
runner passed all 36 session, mutation and current-read cases with `--no-pub`.
This confirms these tests run in the checkout; it does not install the seam
in the UI or prove a live Timeweb user session.

Five additional focused scenarios exercise lifecycle stop with the real native
client and injected in-memory protected-store/HTTP fakes: replacement restore
without a login POST, retained DTO invalidation and actual GET cancellation,
stop during a started login and blocked store write, successful/unknown refresh
drain without replay, unreadable-store handoff refusal, and `stop -> close ->
stop` rejecting a cached safe result after destructive clearing begins. These checks do not
prove OS protected-store persistence across a real killed Android process or
Firebase SDK restart behavior; UI lifecycle wiring and device proof remain
separate steps.

The prepared `readProfileForEdit(TimewebProfileEditorRequest.own())` client
reads only `/v1/runtime/me/profile` under the existing default-off runtime flag.
Its typed snapshot preserves the 11 nullable historical fields and exact UTC
microsecond CAS stamp; every retained field getter checks the current account
and epoch. It accepts no UID, URL, query or full profile/admin/financial map.
Eight focused tests passed in the main Flutter runner, including deduplication,
stream cancellation, malformed/foreign DTOs, ABA, and stop during pre-read
refresh. Runtime reads become stale immediately while successful already-started
token rotation drains to protected storage. UI installation and real device
protected-store persistence are still separate work.
