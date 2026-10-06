# Current-authority native chat writes

`runtime_mutations.py` and `runtime_chat.py` prepare text/quote send, monotonic
read receipts and operation reconciliation on the existing canonical schema.
They create no accounts, chats, memberships or schema; retained `legacy_*`
tables and imported message payloads remain unchanged. The new message's own
JSON stores its quote snapshot. FCM is a transactional outbox entry only;
delivery workers and canonical chat reading are separate integration work.

All operations are off until **both** `CLRS_RUNTIME_WRITES_ENABLED=1` and
`CLRS_RUNTIME_MEMBERSHIP_AUTHORITY=canonical-current-v1` are explicitly set.
The latter must represent reconciled current accounts/memberships after the
final Firebase delta or controlled cutover. An old imported snapshot alone is
insufficient authority to enable writes. The HTTP operator preview guard is
separate and must continue to protect the stand.

`CLRS_RUNTIME_DB_URL` must use a DNS hostname, `clrs_staging` and
`?sslmode=verify-full`; absent `CLRS_RUNTIME_DB_CA_FILE` uses the bundled CA.
An explicitly empty/bad CA path fails. The existing native session signing key
comes from `CLRS_NATIVE_SESSION_KEY_B64`; credentials never enter SQL or logs.
The strict default role has exactly global USAGE (optional REQUIRE SSL) plus:

| Table | Privileges |
|---|---|
| accounts, device_sessions | SELECT |
| profiles, chats, chat_members, event_counter | SELECT, UPDATE |
| chat_messages, user_events, outbox | SELECT, INSERT |
| idempotency_receipts | SELECT, INSERT, UPDATE |

The explicit `CLRS_RUNTIME_PERMISSION_MODEL=provider-database-v1` alternative
requires exactly USAGE plus SELECT, INSERT, UPDATE on `clrs_staging.*` only.
It never accepts mixed table/database grants, DELETE, other databases, global
rights or GRANT OPTION. No role or flag was changed by this preparation.

## Transaction and wire contract

`RuntimeMutationStore.mutate(identity, operation, operation_id, payload, action,
*, access_token)` returns `MutationOutcome(status, payload)`. The trusted
callback `(cursor, execute, uid)` returns `(status, result_dict, revision_or_None)`.
`read_authenticated(identity, action, *, access_token)` uses the same native
proof and a read-only transaction/ROLLBACK without a receipt.

The mandatory access token is cryptographically checked against the locked
session's NS1 envelope, active account, version, expiry, revocation and exact
identity metadata, both before the callback and before COMMIT. Chat mutations
also lock the existing chat, both exact membership rows and both active
accounts. `archived_at` is UI archive state, not removal or revocation.
Receipt -> chat -> members -> accounts -> event-counter lock order is stable.
Shared actor account/session locks permit opposing sends; the chat row and
global counter serialize sequences and committed event order. The sender's
read cursor changes only through the explicit read operation.

The HTTP adapter's fixed flat bodies reconstruct these original hash payloads:

- `chat.send-text.v1`: `{chatId, text, quoteMessageId:null|string}`;
- `chat.mark-read.v1`: `{chatId, throughSequence:int}`;
- `profile.edit.v1`: `{expectedUpdatedAt, changes}`.

SHA-256 hashes compact recursively sorted UTF-8 JSON, with Unicode and input
whitespace preserved before semantic validation. Identifiers have at most
191 code points/764 UTF-8 bytes; text has 1..4096 code points/16384 UTF-8 bytes,
is not whitespace-only, and rejects control characters except CR/LF/TAB.
Sequences/revisions use 0..2^63-1. Request/public JSON is at most 65536 bytes;
the internal original-request/response receipt wrapper is at most 131072.

The public envelope is `{operation,operationId,requestHash,state:'committed',
replayed,result,entityRevision}`. Send HTTP201 result is
`{chatId,messageId,sequence,senderUid,text,quote,createdAt,chatRevision,eventIds}`;
quote is null or `{messageId,sequence,senderUid,text:null|string}`. Read HTTP200
result is `{chatId,readThroughSequence,changed,chatRevision,eventIds}`.
`entityRevision == chatRevision`, timestamps have six fractional UTC digits,
send has two event IDs, and read has zero or two. Notification outbox payloads
contain only identifiers/revision/time, never message text.

Declared callback failures complete a receipt with result `{error:code}` and
null revision: `chat_not_found` (404), `chat_unavailable`, `quote_unavailable`,
`sequence_ahead` (409). Reusing an operation ID with a different original
payload raises `RuntimeConflict`. Expired/revoked/forged native proofs are
rejected before a receipt or business write.

`lookup(identity,operation,operation_id,*,access_token,payload=None,
request_hash=None)` requires exactly one original payload or 32-byte hash.
Found receipts return the original status/result with `replayed:true`; missing
ones return HTTP200 `state:'not_found'`, `result:null`, `entityRevision:null`.
Chat receipt replay and hash-only lookup recheck current membership and both
active accounts before returning saved text. Missing receipt is not permission
to retry a POST whose original request may still be in flight.

Every operation has an eight-second absolute budget, two-second SQL/socket
timeouts, 64-statement cap and four per-process worker slots. On timeout or
shutdown the socket is shut down; the slot remains held until actual worker
I/O/cleanup finishes. A COMMIT exception/deadline is `RuntimeCommitUnknown`;
there is no automatic SQL/POST retry or adoption of a late result. Reconcile
using the original operation/hash. Successful profile edits may have a null
entity revision and expose their authoritative updatedAt instead.

## Scoped verification

16 focused no-network tests cover original Unicode hashing, exact roles/TLS
configuration, session status/version/expiry, replay/conflict, timeout slot
retention, failed worker startup, large profile receipt wrappers, unknown
COMMIT, current counterpart/membership, quote FKs, parallel operation IDs,
atomic message/event/outbox rollback, monotonic reads and raw immutability.

An isolated fresh MySQL **8.4.4** instance additionally passed 11 targeted
SQL/transaction scenarios using generated fixtures over a Unix socket with
`skip_networking` and mysqlx disabled, then shut down. This verified actual
read-only FOR SHARE syntax, duplicate-receipt NOOP, immediate quote FK,
profile read/CAS, concurrent same-operation send and receipt reconciliation.
Its grant/TLS preflight rows were explicitly injected for the Unix fixture:
this is **not** evidence of deployed role permissions or TLS connectivity.
No production/staging database, Firebase, S3, HTTP deployment, runtime flags or
user data were changed. Current membership authority, deployed role proof,
HTTP/client integration and controlled live acceptance remain required.
