# Current native chats

This block connects the real native runtime owner to existing canonical chats.
It remains disabled: `CLRS_AUTH_BACKEND` still defaults to Firebase and
`CLRS_TIMEWEB_CHATS_ENABLED` defaults to false. Enabling the chat flag also
enables current reads and reviewed runtime mutations for that native owner; it
does not enable the independent profile editor or open Firebase Home.

An authenticated native gate first reads `GET /v1/runtime/chats`. Only a valid
current response makes its Chats button available. The list opens the existing
chat with `GET /v1/runtime/chats/{chatId}/messages`; the server checks membership.
The historic conversation client and immutable source snapshot are not used.
No Firebase user, Firestore service, profile hydration or client-supplied owner
authority is introduced. Current names are shown; absent avatars, ages, online
status, previews and peer-read evidence are not invented. The New filter uses
the caller's own read position without displaying a purported unread count.

The pages reuse ClrsScaffold, the approved background, ClrsBrandHeader,
ClrsMotto and translucent ClrsPanel controls. Messages and quoted text wrap
without truncation. A null current text remains neutral, without claiming it
was deleted or is a photo. The chat list preserves the first 300 rows in the
server's newest-to-oldest order and stops paging at that bound. The messages
window is bounded to 300 rows; older continuation and a manual refresh of the
newest page are available. Refresh is explicit in this block.

Before each text POST the small app-private journal flushes the original UUID,
request hash, origin, actual owner UID, chat ID and exact original payload to
disk. No token or password is stored there. Duplicate taps share the original
future. Send and own-read journals are independent, so an uncertain own-read
marker cannot block sending. Once an outcome is unknown, every subsequent
check—including after a runtime restart—uses the existing receipt lookup.
`not_found` does not permit replaying the POST. Only a declared rejection or a
matching committed receipt retires that exact journal. The UI clears submitted
text only after confirmed success; it does not create an optimistic fake
message. A committed message is displayed by rereading the current API. Manual
history reads and send controls are mutually guarded; the required confirmed
send refresh bypasses only that UI guard. Draft typing remains available while
history loads. Uncertain own-read markers still do not block sending.

Account changes, logout and stop revoke the facade and native DTO leases.
Their old routes close and wipe the composer. A late A result cannot appear in
B, retire the retained A send journal or start another POST. Runtime stop
awaits actual serialized journal IO before the owner can be replaced. Leaving
a chat page closes its view but does not log the account out. The reviewed
client still owns bounded transport, cleanup, refresh and receipt parsing.

Two focused local tests cover disk-before-POST, duplicate taps, independent
unknown read, older typed continuation, lost ACK/restart/not-found/confirmed
lookup, actual stop/disk drain, and Gate → list → chat → confirmed send at
360px with an open keyboard and a long untruncated quote. The widget scenario
also checks the newest 300-row bound, A→B route/composer isolation, retained
late A intent and absence of Firebase callbacks/apps. Synthetic transport and
fake protected storage are used. They are not live backend, Android restart or
visual acceptance proof for a newly enabled Timeweb APK.

Remaining for complete chat delivery: live event polling/push, actual media
and gift operations, new-chat creation and the other native destinations.
Their controls remain inactive here. Final source delta/write barrier,
full native service/onboarding cutover, deployed flag enablement, device
proof and live acceptance remain separate prerequisites. APK43 was built
before this block with Firebase/default-off flags; this work does not mean the
application or its users have completed the Timeweb cutover.
