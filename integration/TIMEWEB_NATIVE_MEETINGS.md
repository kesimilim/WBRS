# Native meetings on Timeweb

The integration branch includes native meeting creation, self-only joining,
list/detail/participants and member-only text discussion with their Flutter routes. The server is deployed
to existing Timeweb stand 5179, GitLab commit
`a34ab681e6782fa1aa3e812cf255ecad93367646`.
The operator preview guard remains enabled; the main app deployment is stopped.
The deployed archive route returns404 without the operator proof and401 with proof
but without a native bearer. These refusals are deployment/guard evidence,
not a successful real-user creation, join, message, old-password login or full cutover.
Native release flags remain false. Permissions, schema and imported rows were
not changed by these patches.

## Current authority

The app factory explicitly injects `reviewed-native-marker-v1` into the existing
RuntimeMeetingsService. Default adapters without trusted injection stay closed.
The shared RuntimeMutationStore owns native bearer/current-account checks,
TLS/grant validation, bounded transactions, row locks, deadlines and receipts.
Firebase identity or retained source is not a serving fallback.

Readers accept only the exact server-built meeting marker
`{origin:'clrs-native-meeting-v1',localDatetime:'03.10.2026 19:15'}` and member
marker `{origin:'clrs-native-meeting-member-v1'}` with a real server joined time
or its exact reviewed archiveWindow extension described below. Unreviewed
extra keys, malformed markers, old empty raw and typed imported Firestore roots
are excluded. The existing155 imported meetings are retained and excluded;
their unknown historical joined times are not overwritten.

Current canonical title, description and geography must validate. Names remain
byte-for-byte bounded1000 characters/4000UTF8 bytes, descriptions4096/16384;
empty descriptions are allowed. Geography uses the unchanged pinned catalog
`6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05`.
Local meeting time is exact `dd.MM.yyyy HH:mm` with a real calendar date.
`starts_at` stays NULL; no timezone or calendar ordering is guessed.

Current deleted/disabled accounts, hidden foreign organizers, ineligible people,
untrusted rows and kicked actors are denied. Group metadata is public to eligible
native actors. Individual metadata is restricted to its exact organizer/invitee;
individual participants require the organizer or an active invited membership.
Foreign roster rows must pass current public profile eligibility; an active actor
can see its own exact membership. No count, online state, email, balance, raw
source or unreviewed media URL is returned.

## HTTP contract

`GET /v1/runtime/meetings` accepts scope `group` or `individual`, limit1..30,
optional exact countryCode and matching region, and an opaque cursor.
`GET /v1/runtime/meetings/{meetingId}` returns current detail.
`GET /v1/runtime/meetings/{meetingId}/participants` accepts limit1..30/cursor.

Pages have kind `canonical-current`, exact typed items, nextCursor and
mediaReady:false. Meeting items expose meetingId, organizerUid, invitedUid, kind,
title, description, countryCode, region, startsAt, localDatetime, createdAt,
updatedAt, revision, media:null and mediaReady:false. Participant items expose
uid, fullName, primaryGroup, joinedAt, membershipRevision, avatar:null and
mediaReady:false. The native policy requires localDatetime/nonblank title and a
valid geography pair. Nullable current roster names stay honestly null.

Reads use the existing frozen browse/member indexes, no OFFSET or source scan.
At most128 source rows are considered per request, foreign profiles are batched,
and the shared64-statement/64KiB budgets remain. Meeting order is NULL-first
starts_at/meetingId; roster order is binary UID. The encrypted cursor binds actor,
resource, filters, limit, purpose and the original five-minute expiry. Empty sparse
pages retain an explicit next-page control; clients do not automatically loop.
This is bounded source/fixture evidence, not a measured production latency claim.

`POST /v1/runtime/meetings`, operation `meeting.create.v1`, accepts exactly
operationId, name, description, countryCode, region, datetime, type; an individual
also requires invitedUid. Type is exactly `групповая` or `индивидуальная`.
Clients cannot supply organizer, members, raw/origin, media, server timestamps or
legacy copies of country/city/person names. The current actor profile must be
ready for search. Individual invitations require a current eligible other user.

Creation atomically inserts the meeting, creator-only membership and original
receipt. The actor plus original operation UUID determine meetingId. Success201
has result `{meetingId,created:true,meetingRevision:0,localDatetime}` and
entityRevision0. Matching committed errors are404profile_not_found,
409profile_not_ready and404person_unavailable. Receipt replay validates the
original UUID-derived meetingId and row creation_request_id, current native
marker and active creator membership; another same-owner meeting cannot confirm
an unresolved original operation.

`POST /v1/runtime/meetings/join`, operation `meeting.join.v1`, accepts exactly
operationId and meetingId. It joins only the current actor, with no client-supplied
member list. New group membership requires current eligible meeting authority;
new individual membership requires the exact current invited UID. Existing active
trusted membership returns an honest no-op and preserves joined_at. An explicit
new join may reactivate trusted voluntary-left membership after rechecking current
eligibility; it increments membershipRevision and preserves original joined_at.
Kicked or untrusted memberships remain refused; readers do not reactivate them.

Success200 has result `{meetingId,joined:true,alreadyMember,membershipRevision}`;
entityRevision equals membershipRevision. Matching committed errors are
404meeting_not_found/profile_not_found and409meeting_unavailable/profile_not_ready.
Join INSERT or voluntary rejoin UPDATE and receipt are atomic. Receipt lookup
binds the original meetingId and current active self membership with a revision
at least the recorded revision; it cannot confirm a future revision or grant access
after another exit. Changed access returns a short404 without
logging out a healthy actor. Revoked native authority still returns401.

Meeting writers require the already-supported provider-database permission model
and existing exact indexes; denied configuration fails closed. No grants, DDL,
source rewriting, unrelated profile updates or imported membership history are
introduced. Unknown COMMIT is reconciled by original receipt lookup only.

## Flutter behavior

TimewebAppRuntime uses existing current-profile/read/write gates. The native
MeetingForm branch is chosen before the legacy State can construct Firebase
services. Native edit/delete remains unavailable. Invitees come from current
native people DTOs; the request contains only the typed six fields and optional
exact UID. List, detail and participants use current native readers and bounded
manual pagination; there is no legacy query/media fallback.

Creation and joining persist the immutable original UUID/hash/fields before POST
in application-private journals bound to endpoint/UID and, for join, meetingId.
Double taps share one pending operation. Restart and uncertain replies offer only
original lookup; not_found does not authorize a resend. Every short/nonreceipt
response preserves UNKNOWN. Final confirmation/rejection requires the exact
matching committed envelope and allowed result. Durable ACK completes before
navigation or participant refresh. A newly refused lookup cannot reuse an earlier
cached confirmation.

DTO getters and cursors retain UID/session-epoch guards. Account changes clear
cached meetings, participants, form fields, picked names, pending RAM receipts
and owned dialogs; late A responses cannot render in B. The original disk intent
is retained for its original account. Network cancellation/drain and the existing
common four-request budget are reused.

The native list follows Dmitry's supplied layout: family background and visible
hero, logo/slogan with heart, title/Create in one row,75% transparent Create,
horizontal geography filters, metadata/roster panels on the left two-thirds.
The same approved meeting guide is reused with legacy navigation disabled;
its dialogs stay inside the owned native navigator. The participants link is
`Участники встречи`. Discussion opens only after a fresh member-authorized
message read; no fabricated meeting image is shown. Push and imported-meeting serving remain separate cutover work. Native owner
archives use the separate read-only contract below.

## Current member-only text discussion

`GET/POST /v1/runtime/meetings/{meetingId}/messages` use the same reviewed native
meeting, current profile and active trusted self-membership checks. An invitation
alone grants no message access. Imported meetings remain excluded. Pages contain
whole messages in descending sequence order, with a maximum of 30 items/64KiB.
The opaque cursor binds the UID, meeting, limit, initial sequence/revision and
original 300-second expiry; later messages do not change its page boundary.

The POST body is exactly `{operationId,text}`. Operation `meeting.send-text.v1`
hashes the original `{meetingId,text}`. A 201 receipt contains
`meetingId,messageId,sequence,senderUid,text,createdAt,chatRevision`;
`entityRevision=chatRevision`. Text is limited to 4096 code points/16384 UTF-8
bytes and remains unchanged. Message IDs derive from the meeting, actor and
original UUID; timestamps are explicit server UTC with six fractional digits.
Under the meeting lock, the indexed message tail allocates the next sequence,
and the message, shared meeting revision and receipt commit atomically. A later
message may increase the revision without invalidating an earlier exact receipt.

The Flutter flow persists its original UUID/hash/text before the single POST.
Restart and unknown COMMIT use lookup only. It acknowledges the exact durable
intent before confirmation, then obtains displayed messages through a current
GET. Short errors cannot acknowledge an unresolved send. Target denial clears
RAM and held message authority while retaining the pending journal and healthy
account session. The shared four-request budget and account leases are reused.

The discussion uses the approved family-back background, left two-thirds metadata
and native participant navigation. Available roster names and honest initials
are used; photos, presence and participant totals are not invented. Translation
is manual through a scoped ML Kit service tied to the native UID/epoch, with no
Firebase singleton, literal shortcut or remote fallback. Unsupported/device
failure keeps the original. Real SDK translation and phone acceptance are not
proven by the injected local widget fixture. Quotes, media, push and read markers
remain unsupported by this message contract.

## Native membership actions

`POST /v1/runtime/meetings/leave` and `/kick` retain original operation receipts.
Leave uses `{operationId,meetingId}`; kick adds exact targetUid. Only the current
native organizer may kick another participant. An organizer can voluntarily leave
without deleting the meeting or organizer relation. Absent leave is an honest
no-op with membershipRevision/leftAt/entityRevision all null; no membership is
invented. Already-left/kicked rows preserve existing timestamps. Active changes
lock the meeting and exact member, update by the recorded member revision and
commit the receipt atomically. Original joinedAt and all message rows remain.

Leave success is exactly `{meetingId,left:true,alreadyLeft,membershipRevision,
leftAt}`. Kick success is exactly `{meetingId,targetUid,kicked:true,alreadyKicked,
membershipRevision,kickedAt,leftAt}`. entityRevision matches membershipRevision.
Four existing declared errors remain, with kick-specific participant_not_found
(404), organizer_required and cannot_kick_self (409). All unreceipted responses
remain UNKNOWN on the client. A retained minimal original leave/kick receipt may
be checked after membership loss; it confirms the past action and never grants
current message or roster access. Active readers retain their membership checks.

The client restores each original action by endpoint/UID/meeting/action without
requiring a member-only message GET. This permits checking a lost reply to an
already-committed exit after restart. Kick target is retained inside the original.
Exact disk readback/ACK precedes local meeting-read generation retirement: held
items, cursors, empty pages and late reads become unavailable, while the healthy
native account and minimal owner-bound receipt remain. Personal chat is unchanged.
The discussion restores leave before member actions and offers original-only
Check after UNKNOWN. Confirmed leave clears the held discussion before returning
to fresh detail; declared rejection clears refused data without claiming an exit.
Only a fresh canonical organizer may kick a non-self roster target. A pending
original locks other targets; ACK clears child and ancestor cached reads before
fresh detail/roster. Back after an uncertain exit restores its disk original
without a member message GET. Stale ancestor pages can refresh with the healthy
actor's lease, and opening participants first purges the hidden chat.

## Native owner archive

An active voluntary leave captures the exact validated native message tail under
the meeting lock, atomically with membership update and the original receipt.
The existing member raw marker accepts only its original one-key form or the
exact server-only archiveWindow: throughSequence, capturedAt, operationId and
membershipRevision. Rejoin and kick retain an existing window; kick never creates
one. Old absent/already-left rows are not backfilled from timestamps or later
messages. There is no new table, permission, copying or source rewrite.

`GET /v1/runtime/meetings/{meetingId}/archived-messages` checks the current owner
account, profile existence, native window and exact original owner leave receipt
inside the authenticated read transaction. It does not require live membership or
search visibility and does not grant message/roster capabilities. The response
contains kind, meetingId, archiveWindow, ordering, items, nextCursor and
mediaReady:false. Only immutable native text rows at or below throughSequence
are returned, with existing 30-row/64KiB bounds. The cursor pins the owner,
meeting, all four window fields, limit and original five-minute expiry; replacement
windows reject old cursors. Unavailable history returns a short 404 without
logging out a healthy account. Imported meetings remain excluded.

The separate read-only Flutter flow opens only this archive endpoint. Its bounded
300-message rolling cache discards newest rows when loading older pages and
preserves the server cursor, so the memory bound does not truncate older history.
Held window/messages and late responses retain account and read-generation
guards. The detail screen offers Saved history only after pending leave/kick originals
are resolved. A fresh owner archive read precedes the separate owned route; the
page has no composer, protected roster, participant avatars or live chat reads.
Manual translation retains the same scoped ML Kit policy. Back/reopen obtains
a fresh first page; owner changes and rejected late reads purge the route.
Native release flags remain false.

## Focused evidence and limits

Server evidence:29 focused creator/reader/HTTP cases, then4 targeted join cases
including replay/no-op, individual eligibility, left/kick/import refusal,
revocation, atomic rollback and unknown COMMIT. Only affected fixture cases were
repaired/rerun. There was no broad server suite or live fake-account write.

Client evidence:9 transport cases, one creation flow case,2 creation/read widget
cases,4 join client/flow cases and one join widget case. Scoped analyzers report
No issues. These cover exact receipt identity/status/fields, sparse continuation,
original-only lookup, A-to-B cleanup, cancellation/drain, no Firebase init in the
native form and ACK before detail/roster reads. Text discussion adds 4 focused
server cases, 6 client/flow cases and one focused widget scenario. Earlier suites
were not repeated. The widget covers preserving an oversized draft before POST,
original-only checking after an unknown send, ACK before readback, denied-target
cleanup, late translation after an actor change and quiet stale first opening.
The 360px native-list and discussion renders were compared with Dmitry's concepts;
these are local fixture images, not screenshots from a user's phone. Discussion
metadata and message bubbles occupy at most the left/right two-thirds; names and
honest initials sit outside bubbles, manual translation below, and the composer
is full width. Real avatar, notification, attachment and bottom-navigation
readiness is not claimed. Root changed only the earlier participants link text
after frozen join UI verification.

Membership actions add six targeted backend cases (five new cases and the one
affected join refusal case) plus five new client scenario groups. These cover
creator exit/kick, voluntary rejoin and kick refusal, timestamp/no-op preservation,
current ownership, unknown COMMIT, original-only lookup, disk ACK and read
authority retirement. Scoped client analysis has no errors or warnings; 27
pre-existing style information entries were left unchanged. Only brace lint fixes
and the original closed-flow getter behavior changed after the focused client run;
the final source hashes received independent backend peer acceptance.

Membership UI adds one expanded focused widget scenario covering UNKNOWN Back
and original Check, ACK before purge/refresh, organizer/self/target restrictions,
synchronous hidden-chat cleanup, declared refusal and A-to-B late responses.
Scoped analysis of the three changed paths reports No issues. Archive adds eight
aggregate backend cases (six new and two affected membership cases) and four
client groups; the one rolling-cache correction alone was rerun with 330 rows,
11 pages and oldest sequence1 reached, at most300 in memory and no extra request
after terminal cursor. The archive UI adds one focused widget case covering original Check priority,
ACK before archive opening, 330 rows/11 manual pages, bounded RAM, fresh reopen,
A-to-B purge and unavailable history with a healthy account. Scoped analysis of
three UI paths reports No issues. Root corrected only one static description to
state that messages were saved at the time of exit. No old full suites or
live-user writes were repeated.

Frozen patches were independently reviewed, applied in order and matched their
source manifests. Credentials remain outside source/APK. Full source hashes,
local logs, guarded deployment proof and remaining work are retained in the
private migration checkpoint. This implementation does not prove all historical
meetings/photos recovered, SMTP delivery, old-password sign-in, device acceptance
or completed migration. Public activation requires those remaining cutover steps.
