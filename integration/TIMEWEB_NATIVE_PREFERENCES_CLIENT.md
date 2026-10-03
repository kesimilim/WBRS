# Native notification preferences

Settings now reads the current owner's exact `native-preferences` DTO from
`GET /v1/runtime/me/preferences`. Its messages/meetings/sound switches preserve
actual server booleans; there are no client defaults. The server's absent-row
revision 0/updatedAt null remains distinct from a saved positive revision with
an exact UTC timestamp. Each read uses the existing native four-slot bounded
transport, current token, owner/epoch cancellation and 64KiB response decoder.

Changing a switch creates a RAM draft. “Сохранить настройки” saves all three
booleans together with the current expected revision. `profile.preferences.v1`
uses the existing mutation facade and generic original receipt lookup. The
private per-origin/UID journal fsyncs the original UUID, hash and four exact
payload fields before the first POST. It contains no token, cursor, media URL or
binary. Duplicate submissions share one Future. Short errors, malformed or
unmatched responses, timeout and lookup not_found cannot ACK or authorize a new
POST. Closing the screen/owner clears RAM, retains that original journal and
restore offers only “Проверить результат”.

Only the exact matching committed 200 result (original three booleans,
expectedRevision+1, same entityRevision) or committed 409 preferences_changed
receipt may retire an intent. ACK completes before the UI uses confirmation.
After confirmation, Settings performs a fresh current GET: an old original
receipt can precede a later change from another device. On conflict it also
reads the current source before enabling another draft. A failed fresh read
closes controls and offers retry; it does not resend the acknowledged action.

The same captured account lease protects preferences and the existing account
facade. A→B, logout, stop and a late ACK cannot hydrate another account's controls.
Runtime stop drains the new journal along with existing native journals. No
Firebase preference writes, global feature flags or fake notification list were
added. Native read_events remains chat delta data, not a user notification center.

One focused actual Settings widget/service case passed at 360px/2× text:
actual GET booleans → three switches → lost POST ACK → remembered restart →
original not_found lookup with zero new POST → confirmed original ACK/fresh GET →
second explicit action/late A ACK during B login → original owner restoration
and lookup. Exact flat POST keys, original IDs/hashes, disabled pending controls,
journal removal after ACK, protected DTO invalidation and no Firebase init were
asserted. The affected case also passed after the fresh-GET boundary was added;
no old modules were rerun.

Scoped analysis of seven changed Dart paths: zero errors/warnings/new info;
15 old curly-brace info entries are retained in unchanged auth/mutation code.
All used labels already exist in the 23 bundled catalogs. Source/patch hashes and
logs are bound by private `native-preferences-client-20261003/preferences-source-freeze.json`.

This verifies client source and synthetic scenarios. SQL table creation,
backend publishing/enabling, live email/push delivery and APK are separate work.
