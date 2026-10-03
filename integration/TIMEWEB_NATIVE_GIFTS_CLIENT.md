# Native gift client — source only, 2026-10-03

The current own-profile action opens TimewebGiftsPage with the same TimewebAppRuntime/current actor. The page reuses the approved italic shop CLRS logo, family background, phrase/heart, glass panels and local existing gift assets. Legacy ShopPage, Firebase globals and payment callbacks are not imported. There is no top-up/advertising/invisibility placeholder. Normal compile-time flags remain unchanged.

GET mine accepts the exact native-gifts envelope, bounded 64-item inventory/catalog, existing assets/gifts/1..64.png identifiers, identical assetPath, nonnegative 63-bit counts/balance/revision and nullable server price. Null/zero price does not permit a free purchase. Displayed balance/prices come from the server; the client never writes them. The two tabs show the catalog and owned/received gifts. Sending is enabled only for owned quantity, not received history.

Buy/send use the exact server payload/operation/hash and original UUID. Receipt IDs bind canonical [ownerUID,originalUUID]; send additionally validates original chat, derived gift-notice message, target UID and positive sequence. Success HTTP201 and the four declared HTTP409 failures have exact result/revision shapes. Only matched committed receipts (including declared failure) can ACK. Short 403/400/401/404/409/429/503, not_found or malformed replies preserve the original intent as UNKNOWN. No cached-receipt fallback or automatic new POST is used.

A bounded private journal per origin/UID fsyncs the immutable payload before POST. Duplicate active taps share one Future. Reopen offers only original lookup; disk ACK precedes clearing RAM. Session/epoch invalidation drops visible balance/catalog/recipient data and late A results cannot acknowledge A or enter B. Runtime stop drains the journal and the existing shared HTTP lifetime. No token, cursor, image bytes, local path or URL is stored.

Recipient choices are actual current native personal chats, preserving the existing read order and explicit manual continuation. At most 90 displayed choices are retained. No invented recipient/chat creation is performed; server pair/target eligibility is rechecked by the action. The profile route and shop remain current-owner guarded.

Four new focused scenario groups verified: exact buy/send persistence/duplicate Future/native IDs/four committed refusals/spoof rejection; lost-ACK original-only restore/not_found/healthy403/late A→B; strict local catalog/null price/count/body bounds; actual 360px/2x-text shop buy→current recipient→send→restart original check, with Firebase uninitialized. Three units passed in the first module run. The affected actual-widget case exposed and fixed real header overflow; only that case was rerun and passed in 3 seconds.

Scoped eight-path analyzer has zero errors/warnings; 15 existing informational auth/mutation lints remain. New files have no issues. All 23 visible page labels exist in each of the 23 catalogs; no gift catalog rewrite/new translation key was needed. Exact paths/source hashes/patch/log hashes are in private_migration_20260930/native-gifts-client-20261003/gift-source-freeze.json.

This is source/mock/widget evidence. Server gift activation, live wallet/inventory projection, account acceptance and release are parent tasks. No live purchase, cloud change, APK or final cutover claim is made.
