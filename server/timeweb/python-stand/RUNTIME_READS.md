# Current canonical conversation and people reads

`RuntimeReadService.from_env(existing_runtime_store, env)` shares the mutation
store's native proof, TLS/grants validation, eight-second budget and four-slot
worker pool. Every page uses `read_authenticated` and READ ONLY/ROLLBACK;
session revocation/version/expiry and active account are checked inside the
transaction. No second pool, mutation, legacy payload or arbitrary audience
query is introduced. Conversation reads never accept a target UID; the public
person route below accepts one only with public-visibility checks. Existing runtime write/current-authority flags gate the
service; it remains off before current membership authority/final delta.

Factory configuration reuses `CLRS_LEGACY_READ_CURSOR_KEY_B64` through an HMAC
subkey dedicated to current read cursors. Chat cursors are encrypted and bind
the verified UID, purpose, limit and exact microsecond timestamp-or-null/chat
ID, with a 300-second expiry. Legacy media/cursors cannot be reused here.

The GET routes are `/v1/runtime/chats`,
`/v1/runtime/chats/{chatId}/messages`, `/v1/runtime/events`.
`runtime_read_http.py` mounts them through the shared `runtime_http.py`
adapter behind the existing preview and current-authority gates. No live
write/authority flag is enabled by this source change. Query names are
`limit` (1..100), discovery `cursor`,
messages `beforeSequence` (positive integer), events `afterEventId` (0..2^63-1).
For conversation reads the caller never supplies a target UID. Wrong/inaccessible chat raises
`RuntimeReadRejected` for generic HTTP404; invalid cursor/limits are HTTP400.

Exact envelopes:

- Chats: `{kind:'canonical-current',ordering:'updated_at_desc_chat_id_asc_null_last',items,nextCursor}`.
  Item: `{chatId,counterpartUid,name,avatar:null,updatedAt,lastSequence,revision,readThrough,archived,notifications}`.
- Messages: `{kind:'canonical-current',chatId,chatRevision,ordering:'sequence_desc',items,nextBeforeSequence}`.
  Item: `{chatId,messageId,sequence,senderUid,text,quote,createdAt}`.
  Quote: null or `{messageId,sequence,senderUid,text}`.
- Events: `{kind:'canonical-current',ordering:'event_id_asc',items,nextAfterEventId}`.
  Item: `{eventId,kind,chatId,messageId,sequence,senderUid,readerUid,readThroughSequence,chatRevision,createdAt}`.

All continuation fields are nullable. Historical message text/timestamps and
profile names may be null; genuine empty historical text remains empty.
Timestamps use six fractional UTC digits. Text is at most 4096 code points/
16384 UTF-8 bytes, name 1000/4000; ASCII controls except CR/LF/TAB, DEL and
surrogates fail closed. IDs have at most 191 code points/764 bytes, no controls.
Sequence/revision values use signed 63-bit bounds. The minimal message DTO
matches send receipt content, without inventing per-message event IDs or the
original send revision unavailable from its canonical row.

Both exact membership rows and both active accounts authorize each pair;
extra/missing members fail closed. `archived_at` affects only the returned UI
state. Discovery filters inaccessible pairs before LIMIT and sorts recent to
old, equal timestamps by byte-exact ID ascending, null timestamps last.
Messages exclude deleted rows, and quotes are reread from the same accessible
chat with deletion checked; retained quote snapshots cannot bypass deletion.

Only `chat.message.created.v1` and `chat.read.updated.v1` own-audience events
are queried. Their server-defined payloads must have exact expected fields and
pair identities; arbitrary JSON is never returned. Created events have
messageId/sequence/senderUid and null reader/readThrough; read events have the
opposite nullability. Event createdAt is the canonical event row timestamp.

Conversation queries fetch at most limit+1 rows. Adaptive packing keeps the public envelope
within **65536 UTF-8 bytes**, preserving complete texts/quotes. Continuation
always follows the last emitted row; no private filtered row becomes a cursor
anchor. Historical attachment/gift metadata hydration, avatar references,
event consumption/UI wiring and live current-authority acceptance remain
separate gates. This preparation does not claim complete attachment history.

Eight focused no-TCP tests cover post-write data, current access/blocking,
deleted messages/quotes, exact microsecond/null cursor ordering, cursor
account/limit binding, byte-budget continuation, safe event descriptors,
nullable historical fields and read-only transaction behavior.

A fresh isolated MySQL **8.4.4** instance passed six additional targeted SQL
checks: JOIN/FOR SHARE aliases, adjacent microsecond/equal/null discovery
keysets, whole-message byte continuation, own-event JSON joins/filtering,
deleted quoted parents and blocked filtering before LIMIT. It used generated
fixtures over a Unix socket, networking/mysqlx disabled, then shut down.
Only grant/TLS preflight rows were injected: no deployed TLS/role acceptance
or production/staging user-data operation is claimed.

## Authenticated public people reads

`RuntimePeopleService` uses the same existing store and its current token/account
transaction, with both token checks and READ ONLY/ROLLBACK. The exact unchanged
gates are `CLRS_RUNTIME_WRITES_ENABLED=1` and
`CLRS_RUNTIME_MEMBERSHIP_AUTHORITY=canonical-current-v1`; the word WRITES in the
shared configuration does not make these GET routes write to the database.
Both routes are absent while the existing gates are off. No configuration,
role, grant, schema, authority activation or deployment is included here.

- `GET /v1/runtime/people` accepts only `limit` (1..30, default 30), `cursor`,
  `minAge`/`maxAge` (18..100, defaults 18/100, inclusive), `countryCode`, `region`,
  `pol` and `compatibleGroup`. Duplicate, unknown, empty or malformed parameters
  fail with HTTP400. A GET body/transfer encoding is rejected and never read.
- `GET /v1/runtime/people/{uid}` accepts one byte-exact target UID and no query.
  Missing, self, hidden, disabled, deleted or refused public target data returns
  the same generic HTTP404; database/service failures return HTTP503. Native Bearer authorization is
  required for both routes; private visibility reasons never enter the DTO.

SQL uses the account UID equality for indexed lookup plus a separate byte-exact
UID comparison. It first filters active/non-disabled accounts, the actor's own byte-exact UID,
age and requested canonical fields. Each candidate then passes the existing
[`profile_visibility.py`](profile_visibility.py) evaluator inside that same
transaction. Retained Firestore `legacy_raw` is bounded and read solely for
server eligibility: exact source status/UID, deletion, registration status,
both invisibility flag spellings and UTC expiry. Canonical `invisible_until=NULL`
does not override source-hidden legacy profiles. Malformed or unknown source
evidence refuses visibility. The reader treats an actual stored object `{}` as
native origin, relying on the existing native-creation contract and mutations
that preserve raw; native rows still require both complete canonical flags.
There is no client origin override or public raw/source-content fallback.

`countryCode` must be an exact uppercase entry in the existing pinned geography
catalog. It resolves to that catalog's country **name** for the SQL comparison,
matching the existing Flutter search and retaining legacy rows whose country
code is null. Region requires that country and must be an exact catalog member.
`pol` accepts only the actual search values `м`/`ж`. `compatibleGroup` accepts the
16 existing combined group strings and reproduces `getListOfGroup` from
`lib/core/utils/compatibility.dart`; it compares `primary_group` without splitting
or inventing aliases. Catalog country/region, gender and group comparisons are
byte-exact. Unknown source labels are not normalized by this read path.

Directory envelope:
`{kind:'canonical-current',ordering:'last_online_at_desc_uid_binary_asc_null_last',items,nextCursor,mediaReady:false}`.
Each item is exactly
`{uid,fullName,age,pol,country,countryCode,region,city,primaryGroup,secondaryGroup,lastOnlineAt,avatar:null,mediaReady:false}`.
Single-person envelope: `{kind:'canonical-current',profile,mediaReady:false}`.
Its profile adds only `{rost,about,hobbi,deti,relationStatus}` to the directory
item fields. `deti` is a nullable Boolean, and age/height are nullable integers.
Names/details/geography/groups and activity remain canonical nullable fields;
empty strings and whole texts are preserved. Email, retained raw, session/token
data, roles, private settings and financial fields are never returned.

Keyset order is canonical `last_online_at` descending, null last, then byte-exact
UID ascending. Six-digit UTC timestamps retain adjacent microseconds. Current
backfill does not establish `last_online_at`, so null activity remains unknown
and those rows sort by UID. Source online timestamps or online badges are not
fabricated. Missing age is excluded by the directory age filter; an otherwise
eligible direct public profile can still expose canonical nullable details.
Unsupported/unmapped historical details remain null instead of hydrating from
raw. This does not claim complete historic activity or detail migration.

Each request scans at most **128** candidate rows in chunks of **32** and emits
at most 30 items within **65536 UTF-8 bytes**. Full values are preserved by
continuing before a public item that would exceed the byte budget. Sparse
visibility can produce an empty page with a continuation. Unlike conversation
cursors, people cursors may anchor the last **scanned**, hidden row to bound
work and allow forward progress. That UID remains inside an authenticated
encrypted cursor and is never returned as a public field. The dedicated HMAC
cursor subkey binds actor UID, exact normalized filter hash, limit, purpose and
microsecond-or-null/UID anchor, with a 300-second expiry. Changed filters,
changed actor, tampering, stale cursors and malformed anchors fail HTTP400.
Pages authorize current data separately; a multi-page directory is not a frozen
snapshot across edits.

Media readiness is explicitly false and avatar is null. Source references and
URLs are not returned; validated media access and the native Home/public-profile
Flutter flow remain separate gates. There is no claim that the existing
picture-first list can use this DTO unchanged. Current supported filters are
age, pinned country/region, exact gender and existing group compatibility;
city, name substring, distance, unknown country labels and presence filters are
not added.

The focused local suite passed **28 tests**: ten new people/store cases, nine
HTTP cases, eight existing current-read cases and the existing shared HTTP mount
case. It covers private-output allowlists, null/empty canonical data, source
visibility and expiry, native completeness, active/disabled accounts, byte-exact
A/B identity and mid-transaction token revocation, all compatibility cases,
typed geography/filter refusal, microsecond/equal/null keysets, cursor binding
and tampering, sparse 128-row continuation, full-text byte packing, default-off
routes and GET/body refusal. Fixtures run through the real authenticated runtime
store with synthetic SQL-shaped responses and confirm no SQL writes or commits.

The separate private `people-sql-constant-proof-20261002-v2.json` reports
`passed:true` for MySQL **8.4.4-4**, with CA and hostname verified, bound to
`runtime_people.py` SHA256
`986cc6ca105a70f0f56f3cd3d643af5893831e1d794be38a3da1db0001b0597d`.
It used **EXPLAIN, not EXPLAIN ANALYZE**, on the three unchanged production
query forms against the actual schema, including `FOR SHARE OF p, a`, without
reading user rows or writing data. Plans showed directory `a:ALL` then
`p:eq_ref/PRIMARY`, and keyset `p:ALL` then `a:eq_ref/PRIMARY`; the public-person
fixture UID was absent and only optimizer metadata was returned. Three further
constant-derived query shapes exercised actual transport and public DTO decoding,
including JSON, nullable values, integer height and Boolean children. Only these
constant fixtures used `FOR SHARE` instead of `FOR SHARE OF p, a`, because MySQL
cannot lock derived constants by `OF` alias. The initial fixture error 3569 is
retained separately; production SQL was not weakened or changed. This proves
syntax/planning and fixture decoding, not live API authorization/privacy,
production eligibility, query latency, media readiness or runtime activation.
