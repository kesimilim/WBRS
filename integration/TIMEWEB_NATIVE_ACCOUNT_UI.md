# Native account navigation

The existing native Home Profile tab and direct native own-profile route now
open Settings through the `timeweb-profile-settings` action. Every account route
captures the original `AppSessionLease` before navigation and passes it unchanged
to About, Help, legal content and the native password form. Logout, A→B, stop and
late route construction cannot acquire another owner's lease. Cleanup removes
only that route, including when a newer route is above it.

Personal data returns to the existing own-profile `_edit()` path. Its current
initial-registration / original-pending-finish checks still apply. Settings does
not construct another editor, writer, photo flow or Firebase destination.

Settings reuses the approved house photograph, small logo/tagline and peach glass
panels. Settings and Help keep a left 76% panel; About keeps the approved
`family_main.jpg` crop (1.42), 64% legal panels, 86% detail panels, outline hearts
and compact values footer. At large text sizes panels expand and content scrolls.
All 20 visible static labels reuse the 23 existing bundled catalogs; the existing
`Язык` label replaces the uncatalogued `Язык интерфейса` wording.

About/Help open the existing actual `assets/offer.txt`, `assets/agreement.txt` and
`rules_content.dart` content. The existing privacy screen truthfully states that
an approved privacy policy is not supplied; this patch does not invent one.
Support opens the existing `mailto:supp.lrs@ya.ru`; if no mail handler opens, the
same public address is selectable/copyable. Native password reset uses only the
existing `TimewebEmailLifecycleForm` and this runtime's lifecycle client. Its
unavailable state does not claim a sent email or changed password. Logout calls
this same runtime's native session.

Notification preferences now use the separate genuine current preferences
client and atomic three-switch CAS operation; see TIMEWEB_NATIVE_PREFERENCES_CLIENT.md.
The old Firebase source reads `users.notificationPreferences.messages`, `meetings`,
`sound`, with `value != false` (default true). Native `read_events` currently carries
message/read deltas and is not a notification-center projection.

Focused verification, using the existing Flutter 3.32.5 cache:

```sh
flutter test --no-pub test/timeweb_account_widget_test.dart --reporter expanded
flutter analyze --no-pub lib/presentation/screens/settings/timeweb_account_page.dart lib/presentation/screens/profile/timeweb_own_profile_page.dart test/timeweb_account_widget_test.dart
```

One cohesive widget case passed: actual profile entry/navigation/documents/editor,
360px and 2× text, native password disabled state, A→B with a newer route before
old-route cleanup, and actual native logout. No Firebase app was initialized.
Three scoped Dart paths: no issues. No old test modules, APK build, flags,
credentials, server publishing or live account calls were performed.

Exact source hashes and command logs are saved in the private
`native-account-ui-20261003/account-source-freeze.json` manifest. This is source
and synthetic widget evidence, not a device or production email delivery claim.
