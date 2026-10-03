# Native push client

Source baseline: `5b43554`; native feature flags are unchanged. Firebase Core/Messaging supplies the physical FCM token only. Native startup uses no Firebase Auth/Firestore identity, TOKENS collection, presence writes, old notification destination or push language synchronizer. No native delivery/provider or device proof is claimed by these local checks.

## Wire and ownership

- `POST /v1/runtime/me/push-token/register`: exact `{operationId,token}`. ASCII token length 20..4096. Durable hash input is exact `{sessionId,tokenHash}`; tokenHash is lower SHA256 of original UTF-8 token. SID is the canonical base64url 24-byte public component of an authenticated `na1` access token, 32 characters.
- `POST /v1/runtime/me/push-token/revoke`: exact `{operationId}`; hash input `{sessionId}`. Explicit revoke is exposed by `runtime.openPush()` and `TimewebPushAction.revoke`; runtime teardown is not remote revoke or logout.
- Original generic lookup is `/v1/runtime/operations/{operation}/{UUID}?requestHash=...`. Exact committed200 result is `{kind:'canonical-native-push',sessionId:<originalSID>,registered:true}` or `revoked:true`; entityRevision must be null. Register committed409 accepts only `{error:'token_in_use'}` or `{error:'device_limit'}`. Revoke has no declared errors. Any short/malformed/nonmatching refusal remains UNKNOWN and cannot acknowledge the intent. Historical same-UID receipts acknowledge their original SID; they do not prove current delivery registration.

`TimewebPushFlow` serializes one unresolved original action per endpoint/current UID. Its bounded private journal retains origin, UID, original SID, digest, UUID and original request hash. It fsyncs before POST; no raw FCM token, bearer, URL or device key is persisted. Closing clears the action's raw token; restored registration actions cannot produce POST. Restart and not-found perform lookup only. Acknowledged original metadata remains as a bounded memo so restart in the same SID/digest performs original lookup without another automatic POST. Only an acknowledged memo may be replaced by a new current-SID/digest action.

`TimewebPushCoordinator` shares the exact runtime/session lease. Platform token reads and token-refresh events are attached to that lease. Logout/account switch clears RAM token, flow and usable memo; late A completions cannot acknowledge A's journal or affect B. Normal native session refresh emits a nonsecret signal: server rotation transfers the existing encrypted token atomically, then client confirms any prior original and registers the current SID. Access freshness is established before creating the digest; POST checks that its SID is still exact after shared auth refresh. If another refresh supersedes the original before POST, it fails closed and retains original lookup intent. There is no timer/retry loop that resends an unknown POST.

Native main startup creates existing `wbrs` and `wbrs_silent` channels, requests OS permission and starts the coordinator only with genuine Firebase Messaging infrastructure. App resume checks originals/current token. Native message rendering and destination navigation are not routed to the old Firebase handler. Delivery/notification-center behavior awaits the separately provisioned native provider and reviewed current-target routing.

## Focused check

`flutter test --no-pub test/timeweb_push_test.dart --reporter expanded`: one cohesive case PASS, including actual fsync-before-POST, independent SID/hash assertion, same Future for duplicate tap, lost ACK → restart → not-found → original lookup, acknowledged same-SID restart without duplicate POST, native session refresh/new SID, token refresh with held A reply → logout → B, late A journal stays unresolved, explicit native revoke and no Firebase app initialization. The fixture models server logout/rotation hooks; it is not a live FCM or provider proof.

Scoped analyze: eight Dart paths, no errors/warnings or newly introduced info. Existing 24 info entries were checked against baseline source lines in the private freeze evidence. No previous test suite, release build, credential, flag, cloud or database operation was run.
