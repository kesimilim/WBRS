# Current native chat updates

The existing current chat list and dialog now consume bounded own events from
`GET /v1/runtime/events` through their actual native client and account lease.
The normal interval is eight seconds, one second while catching up a full page,
with exponential failure backoff capped at sixty seconds. These are foreground
updates, not background push notifications or a WebSocket delivery claim.

Only the visible route polls. Opening a dialog pauses its parent list; closing
it refreshes that list. Background/inactive application lifecycle pauses requests,
and foreground resume checks again. A single original poll Future coalesces
overlapping ticks. Each page contains at most 100 events and 64KiB, using the
server-minted in-memory account-bound cursor; no raw checkpoint is persisted.

Events trigger canonical rereads rather than fabricated message bodies. Dialog
updates merge the newest page into the loaded history, retaining complete texts,
older continuation and the draft. The window remains bounded at 300 messages.
A busy send/history read or failed reread does not advance the event checkpoint,
so an arrival during a pending send is checked again. Polling cannot resend an
uncertain write or overwrite its original operation ID. Own read markers are
submitted only when the visible reversed message list is at its newest edge;
peer-read evidence is not invented from these markers.

Pause, route disposal, logout and account replacement discard late results.
The pump never enters Firestore, creates a Firebase identity, or exposes events
from a previous account. Existing native chat flags remain off by default.

Two scoped checks passed: a controlled HTTP/real private-journal scenario covers
busy/failure checkpoint retention, coalescing, paused late results, account stop,
and merging existing older history. The existing 360px/keyboard native route
scenario now additionally receives an incoming event while typing, confirms its
canonical message is displayed and the draft is unchanged. Its original send
ACK, pending send/history exclusion and late A-to-B result checks also pass.
Focused analysis checks only the four modified Dart paths. These use synthetic
HTTP and do not claim deployed live delivery or an Android device acceptance.

This source is newer than review APK43. A complete Timeweb APK still requires
the remaining native services, final source synchronization, enabled backend
authority, and controlled live acceptance. No paid resource was introduced.
