# Native social client — source only, 2026-10-03

Native Home now mounts five existing current-owner destinations: feed, people, chats, meetings and own profile. Feed, author walls and comments use the same TimewebAppRuntime/UID/epoch; no Firebase feed or identity fallback is constructed. Default compile-time gates remain unchanged. The backend social gate is separate and was not activated by this change.

The social client accepts the exact current feed/comment envelopes, nullable text/media/time, actual liked booleans and bounded counters. Requests use shared four-flight cancellation/deadline/64 KiB transport. Pagination preserves the original 300-second cursor lifetime and query/owner scope; there is no automatic load loop. Lists retain at most 90 displayed rows.

Publish/comment/react/report/hide-comment retain their original immutable payload, UUID and hash in one bounded private journal per origin/UID before POST. UNKNOWN, short refusals, missing receipts and not_found lookups retain that original intent. Reopening performs only original receipt lookup. Only the exact matched committed success is acknowledged. Cached receipt fallback and automatic POST replay are absent. Shared mutation HTTP reads 403 bodies only for the social opt-in; a healthy social-access denial clears protected UI while preserving the unresolved journal.

The page reuses CLRS family background, logo/motto, group avatar and 80% glass cards. Actual author names/groups come from current own/public profile reads; an unavailable name uses the existing localized unknown label. Author taps open their native wall. Inline publication/comment input, reply target, actual reactions, report and role-gated comment hide are wired to native actions. Translation uses an owner/epoch-scoped existing on-device translator with no Firebase token or global translator. Local translation source is not proof of deployed remote translation.

Media IDs are retained, but media delivery is not implemented here: the honest unavailable-photo label is manually present in all 23 bundled catalogs. Existing keys are reused for other labels. No image URL, avatar, share/gift/push action or date is fabricated. Nullable feed timestamps are omitted; present timestamps use explicit UTC. No .now() or timezone guess is used.

A narrow meeting compatibility change accepts a retained source document ID only in GET message/archive decoding. The native send receipt still requires its derived tw-meet-msg ID and exact original UUID binding; createdAt remains required exact UTC6Z. Imported authority was not activated.

Validation: seven focused scenarios passed, including exact five social actions, persist-before-POST/duplicate taps, original lookup after lost ACK/not_found/denial, A→B late receipt isolation, strict pagination/nulls/malformed HTTP, retained GET ID versus spoofed native receipt, five actual Home tabs and the actual 360px/2x-text feed with keyboard/comments/moderation. Four passed in the initial scoped run; only three failing scenarios were rerun after the concrete transport or harness correction. The final UI case passed in 4 seconds. No old suites or builds were run.

Scoped analysis of all 11 Dart paths had zero errors/warnings; 27 existing informational lints remain in the unchanged legacy-style auth/mutation/meeting code. Final four new paths have no issues. Catalog validation found no missing visible page labels across 23 catalogs.

Exact source SHA-256 values, patch and test/analyzer log hashes are frozen in private_migration_20260930/native-social-client-20261003/social-source-freeze.json. This is local source/mock/widget evidence; no device, cloud deployment, SQL acceptance or final migration claim is made.
