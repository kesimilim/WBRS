# Imported meeting review: private pure proposals

Status: pure source review and 13 focused synthetic scenarios passed locally.
There is no SQL reader/writer, apply path, HTTP endpoint, migration execution,
cloud call, production user scan, flag activation or APK change in this patch.
The successful state is `ready_for_review`; `applyAllowed` and public serving
remain false. This is a proposal for a later reviewed importer/current read
consumer, not live meeting migration or cutover evidence.

Narrow subsequent source-contract correction: `recentMessageTime` is an actual
private last-message display cache. `lib/service/chat_submission.dart:165-167`
writes the submitted DateTime's `toString()` for meetings; the earlier
`lib/service/database_service.dart:334` writes message `time.toString()`.
No current meeting reader uses it as creation, schedule or membership chronology.
The optional field accepts only exact nonnull `stringValue`, <=191 characters/
764 UTF8bytes without C0/DEL/surrogates, and remains in original private raw.
No parsing, trim, rewrite, UTC conversion or timestamp fallback is performed.
One added substantive synthetic case passed, along with the affected existing
unknown-field/kicked policy case; the earlier 13-case suite was not repeated.
Total distinct scenarios previously/newly confirmed: 14.

Changing this decoder changes its code hash. A previous private current-root
receipt remains an original observation but cannot silently satisfy the helper's
new code binding; root must obtain/review new evidence for the corrected decoder.

## Audited source facts

Source files were read locally at repository HEAD
`69adb9fc5b03ae3c2ce7805e67f31a99138d17cd`; their hashes appear below. No archived
user document or live database was opened for this review.

1. `MeetingWriteService.create` writes root `meets/{id}` with organizer `admin`,
   active `users`, exact Russian `type`, optional individual `invitedUid`, name,
   description, geography and date fields. Its creator initially belongs to
   `users`. `creationRequestId` is the original write identity. It does not write
   a meeting `deleted`, `status`, private or hide flag, or an initial `kicked`.
2. `MeetingWriteService.delete` physically deletes the root. An old archive row
   cannot prove the root still exists. There is no invented `deleted=false`
   default from archived source.
3. `MeetingMembershipService` joins/removes UID in `users`; a leave receipt may
   exist in a separate child collection, but the root has no leave/join event
   timestamp. This module does not scan or claim complete receipt history.
4. `ChatPage._kick` atomically removes UID from `users` and adds it to `kicked`.
   Kicked UID is deny evidence, not a missing-member/no-kick inference. Absence
   from both lists means only not currently a member at the reviewed snapshot;
   it does not prove a past leave or an accepted invitation.
5. Existing legacy discovery checks exact root path/payload hash, requires typed
   `users` and `admin`, and treats absent `kicked` as empty. That read fallback is
   not automatically promoted to imported current authority. Explicit complete
   root and omission-semantics review are required here.
6. The form writes local `datetime` as `dd.MM.yyyy HH:mm`, with no timezone.
   Current meeting list/chat readers also accept Firestore Timestamp. Therefore
   an exact typed timestamp can populate UTC `starts_at`; a local string remains
   original private local evidence with canonical `starts_at=NULL`. `timeStamp`
   is creation/order source, not scheduled start. Canonical created/updated times
   come from the actual archived document metadata, with their raw origin kept.
7. Country code and region come from the approved geography catalog; the list
   also supports an exact source country name. `city` is not a region fallback.
   Frozen SQL currently declares `meeting_members.joined_at DATETIME(6) NULL`
   at line 257. No live schema was inspected. The proposal still requires the
   reviewed observed timestamp described below and can represent a nonnull
   membership timestamp without inventing a historical join date.

## Trusted inputs and fail-closed boundary

`review_imported_meeting(record, pin, people, catalog_bytes=...)` is pure. It does
not obtain or authenticate its own archive/current evidence. The future trusted
server caller must independently reread/verify those inputs and exact pins;
none can come from a public request as an authorization override.

`SourceMeetingDocument` contains exact root `firebase_path`, original typed
Firestore `encoded_payload`, canonical `payload_sha256`, archive SHA256 and the
confirmed source namespace `chatapp-4e347/(default)`. Only `meets/{id}` is accepted,
with ID representable in canonical VARCHAR(191)/764 UTF8bytes. Nested messages,
removed-meeting paths, other roots/case/namespace and digest mismatch are refused.
The existing decoder verifies a bounded 131072-byte exact typed document with
unique JSON keys and its original create/update metadata. The existing
`payload_digest` uses the same canonical hash as the import adapter. A private
deep copy is sealed before hash checking, so changes to the caller's dictionary
after that check cannot change the retained proposal.

`MeetingSourceReviewPin` must bind the same root, payload and archive hashes,
the exact trusted `source_contract='reviewed-imported-meets-v1'`, an explicitly
complete root, independently confirmed current root existence, the current root
payload hash and `member_observed_at`. Completeness defaults false, existence
defaults unknown, current hash/observed timestamp default unavailable. Missing,
false or changed proof returns a refusal, never a ready partial plan. Hashes or
the mere archived root's existence do not authenticate current live presence.

Absent `kicked` is refused unless the pinned review explicitly sets
`missing_kicked_reviewed_as_empty=True` after confirming complete root/writer
semantics. This field defaults false. Typed present empty `kicked` is direct
source evidence. Missing `users`, wrong array/tag/null/element types, duplicate
UIDs, users/kicked overlap, invalid IDs and lists over 1000 are refused, not
deduplicated, coerced or guessed. Actual source fields outside the audited root
allowlist are refused in full, including `deleted`, `status`, private, hide or
future unknown fields. Their meaning is not guessed to widen visibility.

Group source type must be exactly `групповая` and cannot carry an invitee,
including an empty invitee string silently rewritten to NULL. Individual must
be exactly `индивидуальная`, have a distinct nonempty invitee, and have no
users/kicked UID outside the exact organizer/invitee pair. Missing historical
type or individual recipient is review-required, never guessed as public group.

`people` is a bounded private map of `CurrentMeetingPerson` values obtained by a
future trusted current canonical read. Every organizer, invitee and active source
member requires exact current account UID, disabled=0/lifecycle active, matching
canonical profile UID and exact UTC profile updated timestamp. An absent,
disabled, deleted, blocked, mistyped or mismatched current row refuses the plan.
The map has at most 1002 entries. Past kicked UIDs do not become active SQL member
rows and are retained as deny evidence even when no current profile is usable.
No fake observer/public eligibility result is fabricated. These identity pins
do not bypass the unchanged public profile visibility evaluator: the eventual
current reader must rerun it for every foreign organizer/invitee/participant and
validate the actual current native actor/token. No stale public eligibility is
promised by a successful pure proposal.

## Exact private result

`ImportedMeetingReviewPlan` is an immutable private dataclass. A refusal has
state/reason only, no rows/policy/fingerprint. A success has state
`ready_for_review`, reason `source_bound`, exactly one `ProposedMeetingRow`, zero
or more active `ProposedMeetingMemberRow`, `ImportedMeetingVisibilityPolicy`
and a deterministic SHA256 fingerprint of those proposed rows/policy. Its only
log-safe representation is `summary()`: counts, bounded reason/state, explicit
zero writes/no HTTP/no apply, and known/unknown time indicators. Normal dataclass
repr suppresses private fields. Do not log/serve `asdict` or the retained raw.

The meeting proposal has exactly frozen canonical columns: `meeting_id`,
`organizer_uid`, `invited_uid`, `kind`, `title`, `description`, `country_code`,
`region`, `starts_at`, `created_at`, `updated_at`, `media_id`,
`creation_request_id`, `revision`, `deleted_at`, `legacy_raw`. Revision 0 is the
proposed initial canonical revision, not an invented historical source revision.
Media ID is NULL; original media URL strings stay private in retained raw and
never become a public descriptor. The original creation request ID, if present,
must be nonempty/representable and is preserved. Physical non-deletion must be
proven by the reviewed current-root pin before proposing deleted_at NULL.

Title/description are nullable and preserve original whitespace and bytes, at
1000/4000 and 4096/16384 character/UTF8byte bounds respectively. Geography strings
are nullable/191 characters/764 bytes. Newline, carriage return and tab are valid
for title/description; other C0/DEL/surrogates, oversized text or wrong typed
wrapper are refused. Source create/update must be valid UTC and exactly
representable in SQL DATETIME(6); nonzero sub-microsecond fractions are refused,
not rounded. Updated time cannot precede created time. The serialized retained
`legacy_raw` is the entire original typed root document; it is never `{}` or a
reconstructed public subset. It preserves source fields and original timestamp
spelling while projected SQL timestamps use exact microsecond representation.

An active member proposal has exactly canonical `meeting_id`, `uid`, `joined_at`,
`left_at`, `kicked_at`, `membership_revision`, `legacy_raw`. Its joined_at is the
explicit trusted `member_observed_at`, validated as exact microsecond UTC and
not before the reviewed root update. It is a migration observation marker,
**not a source historical join time**. The member's nonempty raw provenance
states `joinedAtBasis:'migration_first_observed'`, observed timestamp and
`historicalJoinedAt:null`, exact parent path/hash/archive/UID and active source
field evidence. The original full root is retained by the meeting row; per-member
raw is a bounded pointer/proof, not 1000 copies of that full root. Left/kicked
timestamps remain NULL for these proven active members. No kicked or absent UID
is inserted as an active member and no leave/kick timestamp is fabricated.
The future approved imported roster decoder must expose historical joinedAt NULL
until a separate historical event proof exists; it must not label this observed
SQL timestamp as the original join time.

The private policy binds exact root/archive/current hashes, source contract,
group `public_group` or individual `organizer_invitee_only` audience, exact
active/kicked/not-current-member UID tuples, current canonical profile pins,
geography mapping basis/catalog pin, source schedule basis and member observation.
It requires current accounts/profiles, foreign profile visibility and current
root/provenance revalidation. `public_serving_enabled=False` always. Kicked UID
is an explicit deny list that a future consumer must use before returning
metadata/participants/messages; NULL member timestamps are never its no-kick
evidence. Organizer/invitee absent from both lists is labelled only
not-current-member; future individual participant access must distinguish the
current exact organizer from an invited actor with no active membership.

The current native meeting service remains frozen/unmodified and accepts only
its separately reviewed native empty-source policy. It cannot consume these
nonempty imported proposals yet. A later imported-source policy decoder/projector
must verify the retained original root and provenance, enforce this source kick
deny list alongside newer current canonical changes, preserve foreign visibility
and reviewed actor rules, and handle observed-vs-historical timestamp display.
There is no trick that makes imported rows appear native by erasing raw.

## Geography and scheduled time

Pure review accepts already-loaded catalog bytes, never reads a path. The
existing pure decoder verifies exact pinned SHA256
`6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05`.
Source uppercase country code must exactly match the catalog, any supplied
country name must match it, and any region must be an exact member. If source
code is absent, one exact unique catalog name can map it, with explicit
`source_country_name_catalog_exact` basis. No trim/case/translation or city→region
fallback is performed. All geography missing is honestly unavailable; region
without a proven country or a contradictory/unknown pair is refused.

Source `datetime.stringValue` uses the actual Flutter local-date parser format,
including its permitted one/two digit components and calendar validation. Its
exact valid string is kept privately as scheduled_local, timezone unknown,
starts_at NULL, basis `source_local_datetime_timezone_unknown`. It is not the
archive creation time or UTC. Source `datetime.timestampValue` is actual absolute
UTC evidence used by both current Flutter readers: it yields exact starts_at and
`source_timestamp_utc` basis, scheduled_local NULL. Missing datetime is unavailable.
Malformed local dates/typed values or nonrepresentable UTC precision are refused.
A future approved DTO can expose the bounded local schedule as a named field
according to the UI specification without returning raw or guessing timezone;
that reader/UI change is not included here.

## Focused local evidence and remaining work

Only `test_imported_meeting_review` was exercised: 13 distinct synthetic cases
passed; after the actual Timestamp readmodel and immutable input-snapshot seam
were added, only the affected existing date, fingerprint/snapshot and text/type
cases were rerun and passed. Scoped Python compilation and whitespace checks
passed. Tests cover exact root/namespace/hash/archive, default unknown current
presence/completeness/observed proof, missing kicked refusal/explicit reviewed
omission, unknown deletion/status/privacy field refusal, strict arrays/conflicts,
individual pair, active canonical identities/pins, exact geography, local/UTC
date proof, precision/bounds, retained raw/immutable fingerprint/redacted summary,
and refusal bounds. The function is tested with file/path/network access blocked;
catalog file loading occurs only in the test harness. There was no SQL or actual
user archive scan.

Remaining: reviewed acquisition/current reread of source presence/completeness
and omission proof, historical unsupported field/kind/date cohorts, bounded
projector/apply and readback protocol, reviewed permissions/factory/HTTP adapter,
an imported current visibility/roster decoder that honors source kick/observed
times plus newer canonical authority, client/UI/local schedule display and
controlled production proof. No cohort coverage/count or completed migration
claim is made by these synthetic tests.

## Immediate imported runtime seam and date/geography limits

Root's next real check is only the same four bounded current-root/existing-row
cases after the `recentMessageTime` correction. No repeat import is needed.
The subsequent runtime hook needs an optional reviewed imported-origin decoder
and explicit factory injection, still default closed: bounded original meeting
raw/hash plus member source-path/index/UID/hash must match reviewed source and
current canonical rows; source kicked UIDs deny even without a SQL member row.
Keep current SQL left/kicked/revision, native actor/session pre/post and foreign
profile visibility checks, existing page/scan/body bounds, and bind continuation
to the actual origin-policy fingerprint. Existing NULL `joined_at` stays unknown;
no observation or creation timestamp becomes historical `joinedAt`.

An initial real case reported `created_at` and `region` metadata differences.
Their source mappings differ: `project-conversations-core.mjs:320-329` takes
`timeStamp` (or document createTime for its local ISO fallback), while this pure
review takes document createTime; mapper line 319 uses `region ?? city`, while
review uses only exact source region/pinned catalog. Those field origins require
explicit review before choosing a public projection or any later CAS correction;
there is no automatic UPDATE, city→region inference or timezone guess here.
Source local scheduled datetime legitimately leaves `starts_at=NULL`; a future
approved local-date DTO/display must preserve that string's unknown timezone.

The 300-second current-root receipt proves a bounded observation, not durable
public serving authority or a final source write barrier. Runtime factory remains
unwired/503 until source authority, production injection and meeting SELECT
permissions are separately reviewed. No future-cap framework or renewal is added.

## Source binding

| File | SHA256 |
| --- | --- |
| `server/timeweb/python-stand/imported_meeting_review.py` | `455da93672c54a49be840ef0819a3a9a642c9b7c42d06bf95d48792ed752b972` |
| `server/timeweb/python-stand/test_imported_meeting_review.py` | `193a912661dabf04e62bafdad48808d92881eb36557eb754415379a245866014` |

Sorted JSON implementation/test manifest SHA256: `d564e3629eb68567b8d9522301659ae637e19bfa3c93b4481d3449b1f97d135c`.

Audited input contracts (read-only, not changed by this task):

| File | SHA256 |
| --- | --- |
| `lib/shared/meeting_form.dart` | `b8db42230629adad10c4dd1652fb6d5255513f748f57eefb823d5f3e5f660bb2` |
| `lib/service/meeting_write_service.dart` | `e95f22b670c6f198c9d3c16208395ad4cbf5e8874efe97656adb003e7dddd7f6` |
| `lib/service/meeting_membership_service.dart` | `b32587d6fdb14e74e2175c38c4247b12e0623838dc43b89d4d6d6a4643c418db` |
| `lib/presentation/screens/meet_chat_screen/chat_page.dart` | `ce48002d6ca4dcfaabbcd8aaaf9988714ea9980db2a4b74a50cf879fa680cc27` |
| `lib/presentation/screens/list_of_meets/meetings.dart` | `7f8454ae33bb45804bd6a8644d04d74a7d1de2cdeaf8b8254084cbcb60b01870` |
| `server/timeweb/python-stand/legacy_conversation_read.py` | `da9e845d9286e0a400ab9ef43accbb0abe72b1b49e13a4a05f0f98a53f54d21a` |
| `server/timeweb/python-stand/legacy_conversation_discovery.py` | `e00e00ae95e1c60ab77cc668de730761388aec8545641fa8915c046bb0dc4286` |
| `server/timeweb/db/001_initial_mysql84.sql` | `069cc1a473475a85742c71387374da44ca5483abd219c00affb9cc9ce739f621` |
