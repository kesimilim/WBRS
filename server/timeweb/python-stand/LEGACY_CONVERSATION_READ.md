# Legacy conversation compatibility reads — prepared, disabled

`legacy_conversation_read.py` and `legacy_conversation_payload.py` read retained
raw documents for personal message history, meeting message history, an account's
own removed meeting history, and meeting participants. They include cases the
normalized conversation projection classifies as raw-only. They do not change
accounts, membership, messages, read flags, schema, Firebase or Storage objects.
HTTP routes are prepared separately in `app.py` and
`legacy_conversation_http.py` and remain default-off. Flutter is not wired to
these compatibility routes yet.

## Primary access evidence and the narrower service policy

The active Firestore release was fetched read-only on 2026-10-01. Its file SHA-256
is `af7b73ae34238175f4f504cb55d9a07b339b8778a8504cff241a4eb45af74600`.
It permits all reads and writes when `request.auth != null`. The local
`tool/security/firestore.strict.rules` is an unpublished fixture and is not the
deployed policy. Neither the private rules snapshot nor release JSON belongs in
the repository.

This service intentionally narrows access using the client scenarios below. It
does not reproduce global signed-in access or call the fixture deployed rules.

| Source path | Evidence in current Flutter source | Service read policy |
| --- | --- | --- |
| `chats/{id}` and `chats/{id}/chats/{message}` | `chatscreen.dart` `_load` rejects an absent room or a UID outside `user1`/`user2`; `_watchMessages` orders `ts` descending | Read the exact existing root; verified current UID must equal an explicit `user1` or `user2`. Do not parse/guess participants from the chat ID. |
| `meets/{id}/messages/{message}` | `meet_chat_screen/chat_page.dart` `_load` derives `_joined` from root `users`; `_messageQuery` reads root messages only while joined | Current UID must be explicitly in `users` and absent from `kicked`. An organizer outside `users` receives no root messages. |
| `users/{currentUID}/removed_meets/{id}/messages/{message}` | `_messageQuery` uses the signed-in owner's namespace after leaving; `meeting_membership_service.dart` copies history before removal | Only the owner path built from the verified identity; no owner/target UID argument. Sparse missing archive/root meeting parents do not invalidate an owner's already copied history. |
| Meeting participants | `about_individual_meet.dart` `_showParticipants` displays the explicit `users` set plus `admin`; chat `_load` uses `users` | Viewer must be a member or the explicit organizer, and not kicked. Display organizer separately; adding it to display does not manufacture membership. Unknown individual invitees/relationships never become authorized readers. |

An old individual meeting without `invitedUid` remains readable to its explicit
members and organizer for their allowed operations. There is no public individual
meeting discovery or guessed invitee policy. Missing root chat/meeting parents
deny root history. Deleted/missing counterpart accounts, self-pairs and duplicate
chat pairs do not erase a still-authorized current account's existing messages.
Historical senders outside current membership can remain historical labels;
their presence never grants access or creates an account/member.

## Snapshot boundary — mandatory before any cutover

Raw parents are the **immutable reviewed import snapshot**, not an indefinitely
current membership authority. Before enabling production join/leave/kick/member
writes, implement and review an authoritative current membership overlay or keep
the read parent authorization state synchronized transactionally. Revoke access
on a change; a snapshot cursor alone cannot enforce a later membership change.
The three snapshot flags below explicitly refuse an unreviewed/current-write
mode. The API reports `membershipAuthority: immutable-reviewed-snapshot`.

Routes must re-run `FirebaseAuthBridge.verify` or native `authorize` for **every**
request; never retain an identity across requests or construct one from an HTTP
UID. The service accepts only the existing server identity types, checks expiry
again after the read, and checks the local exact UID, `disabled = 0`, and
`lifecycle = active` in its transaction. Native `authorize` remains responsible
for the current session token version/revocation check. An identity dataclass is
not itself a cryptographic verifier.

## Prepared interface and guard configuration

Construct one long-lived service per worker from private environment and a new
32-byte cursor key supplied by a secret store. Do not use a migration, session,
credential-wrapping or SCRYPT signer key. Never put private values in Git/APK/logs.

```python
service = LegacyConversationReadService(private_env, private_cursor_key)
# fresh_identity = bridge.verify(bearer) OR native_auth.authorize(bearer)
service.personal_messages(fresh_identity, chat_id, limit=50, cursor=None)
service.meeting_messages(fresh_identity, meeting_id, own_removed=False,
                        limit=50, cursor=None)
service.meeting_messages(fresh_identity, meeting_id, own_removed=True,
                        limit=50, cursor=None)
service.meeting_participants(fresh_identity, meeting_id, limit=50, cursor=None)
```

All of these are required; unset or different values fail before connecting:

- `CLRS_LEGACY_READ_ENABLED=1`
- `CLRS_LEGACY_READ_SNAPSHOT_REVIEWED=1`
- `CLRS_LEGACY_READ_MEMBERSHIP_MODE=immutable-reviewed-snapshot`
- `CLRS_LEGACY_READ_SOURCE_SHA256`: verified full archive composite digest
- `CLRS_LEGACY_READ_SOURCE_PROJECT`, `_DATABASE`, `_BUCKET`: exact verified source
- `CLRS_LEGACY_READ_DB_URL`: dedicated read-role DNS URL, only
  `/clrs_staging?sslmode=verify-full`
- `CLRS_LEGACY_READ_DB_CA_FILE`: absolute verified CA file

The archive digest namespace is a deployment assertion: root must bind it to the
completed sealed full archive and independently verified SQL import receipt
**before setting the reviewed flag**. `legacy_source` contains source identity,
not an archive-SHA column. The service checks that row in every transaction; it
does not pretend the environment digest is a new database source proof.

Default `strict-tables-v1` grants are exactly global `USAGE` plus `SELECT` on only:

- `clrs_staging.accounts`
- `clrs_staging.legacy_source`
- `clrs_staging.legacy_documents`

In that default model, `SHOW GRANTS` rejects schema-wide SELECT, migration DDL/write rights, other tables,
credential/session/Storage tables, roles and GRANT OPTION. This new role has not
been granted or deployed by this change. It is separate from both the migrator
and native Auth role. Existing strict CA and DNS certificate verification are
preserved; no TLS verification flag is weakened. Only MySQL 8.4/clrs_staging with
a live TLS cipher is accepted.

The separately reviewed `CLRS_LEGACY_READ_PERMISSION_MODEL=provider-database-v1`
accepts exactly `USAGE ON *.*` plus one `SELECT ON clrs_staging.*` grant, so the
existing approved read-only `clrs_api_ro` may be used after actual grant/TLS
verification. It rejects mixed table/database grants and all additional rights.
This grants SQL read access to the whole staging database, so it is an explicit
permission-model choice; application output/authorization and snapshot gates
remain unchanged. See [runtime role models](../RUNTIME_MYSQL84_GRANTS.md).

## Bounded ordering, integrity and data views

Each request uses a read-only repeatable-read consistent snapshot. It has two
second connect/read/write transport timeouts, a one second MySQL SELECT execution
limit, and an eight second overall operation deadline that shuts down the
existing socket. Connection cleanup remains bounded by the transport timeout.
No COMMIT, retry or write is performed. Four requests may be in flight per
process. The reused bounded HMAC limiter holds at most 2,048 per-process keys,
allows 60 reads per UID/minute and 240 per service worker/minute; multi-process
global limits still need the HTTP deployment layer. Instantiate once per worker.

- Page size 1–50; no OFFSET or unbounded collection reads. A bounded indexed
  count refuses histories over 10,000 records; oversized histories remain raw.
- Message order preserves timestamp seconds plus all nine fractional digits.
  Legacy integer `ts` values use the known millisecond writer branch. Ambiguous
  integers/missing fields use the **actual document create time**, labelled in
  `timestampBasis`; never current time or guessed timezone. Invalid timestamps
  fail closed. SQL order is read back against the Python interpretation.
- Ties use the byte-exact UTF-8 document ID, both in SQL binary comparison and
  cursor verification. AEAD cursor domains bind UID, source digest, collection,
  parent payload digest, purpose, exact last key and a 300-second expiry. Changing
  account, source, collection or parent cannot replay a cursor. Source updates
  during the immutable mode require a newly reviewed source namespace.
- Deleted-for-current-user flags hide the row and still advance its underlying
  cursor. An empty visible page can therefore contain `nextCursor`; callers must
  continue by cursor, not conclude history ended from zero visible items.
- Every returned raw row compares the complete source path/collection/ID and
  its canonical import payload SHA. The canonical serializer is cross-checked
  with Node and against all 21,761 scoped source envelopes; it preserves UTF-16
  key sorting, JS numeric key ordering and JSON number spelling boundaries.
- Document budget 128 KiB (SQL avoids transferring larger payloads); response
  budget 256 KiB. Oversized/corrupt source is refused and remains retained.
- Participant profile queries are batched for at most 50 display UIDs. Results
  preserve the actual `группа` field with English `group` fallback only when the
  Cyrillic field is absent. Avatars prefer `profilePicThumb` over `profilePic`;
  both still use the quarantined opaque descriptor without a public URL.
  Rows must match exact requested IDs/paths; a stored `users.uid` cannot substitute the
  document ID. Organizer first, then UTF-8 UID keyset order. This deterministic
  compatibility ordering is not the client alphabetical/full chat recent-order
  discovery feature. `name`, integer `age`, city/group and safe avatar descriptor
  are whitelisted. Email, balances, account claims, TOKENS and full raw maps never
  leave the service. Missing/deleted/Auth-orphan profiles receive explicit states
  and no interactive action, without fake accounts or fabricated names.

Body text, original sender label/UID, `legacyIsRead`, existing gift name/asset,
gift notice and quoted text/names are retained. Quotes without a message ID get
`messageId = None`; no invented reply link. Own notification mute state is
returned without other users' preference arrays. Shared post/comment metadata
is whitelisted and marked `linkAvailable = False` because wall authorization
is outside this service. Plain user-authored message text is not automatically
fetched as a URL.

Known bundled `assets/gifts/...` images remain logical bundle names. Legacy
Firebase/gs media is converted to an encrypted owner/resource-bound descriptor;
query strings, download tokens, Firebase URLs, S3 keys and source paths are not
returned. The descriptor explicitly says **quarantined**. Unknown external hosts,
credentials, ports/redirect-style hosts or malformed paths become unavailable;
the service performs no network/media fetch. The importer's
`clrs-import-quarantine` prefix must **not** be signed or served by this module.
A later reviewed promotion and media endpoint must reauthorize current access
and verify exact source/target hashes before making a photo usable.

## Evidence and remaining gates

Targeted Python 3.12 offline tests cover verified/expired A/B identities, outsiders,
blocked/deleted accounts, organizer-vs-member distinction, kicked users, orphan
parents/own archives, duplicate/self chats, UTF-8/nanosecond keysets, changed source
and parent cursors, hidden flags, quote/gift/media redaction, exact path/digest
checks, batched public profiles, role/TLS/staging/source bounds, rate/concurrency,
socket timeout, payload limits and Node/Python digest compatibility. Driver SQL
parameter escaping is checked without opening a socket.

Local read-only examination of the completed encrypted **metadata** shard found:
21,761 scoped envelopes with matching canonical hashes, zero envelope failures,
maximum encoded size 4,296 bytes; all 9,346 message payloads and 6,103 profiles
decoded. Timestamp types: 8,850 personal Firestore `ts`, 34 personal integer
milliseconds, 462 meeting/own-archive `time`. Largest existing history: 330
messages. These counts prove local data-shape compatibility; they do not grant
access or prove a live MySQL query, HTTP route, Flutter UI, current membership or
media delivery.

The completed full source keeps all 3,091 raw-only conversation documents and
314 unprojected participant entries. This module does not promise every orphan
record can be served: no root/current-owner proof means refusal while the raw
record remains preserved. A historical sender is not an active member.

Before full application cutover: review these new modules/policy, verify the
actual MySQL queries and index behavior on the stand using controlled accounts,
connect and test HTTP authentication/lifecycle/session revocation, implement
current membership authority, raw-plus-canonical room/meeting discovery and
read/write compatibility, promote/authorize media, connect the Flutter client,
and complete final source synchronization. No deployment/current-user mutation
was performed here.

MySQL transaction semantics were checked against the
[MySQL 8.4 transaction manual](https://dev.mysql.com/doc/refman/8.4/en/commit.html).
