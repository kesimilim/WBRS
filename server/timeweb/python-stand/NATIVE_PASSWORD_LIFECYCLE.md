# Prepared native password and email challenge lifecycle

Status: codecs, default-off composite login, two-phase completion and atomic
request assemblies, durable challenges/receipts, encrypted outbox, strictly gated
HTTP mount and proposed schema. Local generated-data SQL/API checks passed.
Live schema application, SMTP delivery, source write barrier, app activation and
production account/password changes remain unproved and disabled.
The existing Firebase password path remains the default. The composite store
is selected only with `CLRS_NATIVE_PASSWORD_ENABLED=1`; with the flag absent or
`0`, it does not reference the proposed native credential table. Unknown flag
values fail closed. Do not enable it before the separate schema migration.
The running Firebase source still requires final synchronization before cutover.

## Credential contract and old-password compatibility

The existing `auth_credentials.scheme` CHECK does not admit native scrypt and
the migration role lacks ALTER. Proposed `db/004_native_auth_lifecycle.sql`
therefore creates two tables without altering imported credentials, accounts,
sessions, `legacy_*`, media or payments. Applying it is a separate reviewed
migration: DDL auto-commits; it needs a backup/version receipt and exact schema
gate update from 42 tables/66 FKs to 44 tables/68 FKs. Do not weaken earlier
snapshot/import guards or run this SQL through a runtime role.

`NativePasswordCodec(wrapping_key: bytes32)` accepts this exact row mapping:

```text
{uid: string, scheme: "clrs_scrypt_v1", password_version: int,
 material_ciphertext: bytes80, parameters: exact fixed JSON object}
```

The SQL adapter must select only these five fields; created/updated timestamps
are row metadata. JSON parameters are fixed, exact types, with no extra fields:
`material_format=aes256gcm-native-v1`, `n=32768`, `r=8`, `p=3`, `dklen=32`,
`maxmem=67108864`, `salt_bytes=16`. Salt is random for each derivation. Plain
material is `NSP1 || salt16 || hash32`; storage is `nonce12 || ciphertext52 ||
GCMtag16`. AES-GCM uses a domain-separated HMAC-derived key from the existing
server wrapping master. AAD binds database, table, exact UID, scheme, password
version and fixed parameters. No plaintext password is retained in the row.
No master, signer, code or session key belongs in source/Git/client artifacts.

`PasswordWorkPool(firebase_codec, native_codec, workers=2)` is the one actual
pool for imported Firebase verification, native verification and new derivation.
Do not keep a second active Firebase verifier alongside it. `select(uid=...,
account_token_version=..., firebase_row=None, native_row=None)` returns frozen
`SelectedPassword(uid, account_token_version, scheme, ciphertext_identity,
material)`. Any native row, including a malformed/unreadable row, is authoritative
and prevents fallback to the old Firebase password. If native is absent, the
unchanged Firebase codec/verifier and official published test password apply.

`verify(selected.material, password, timeout=1.5)` and
`prepare(uid, password_version, password, timeout=1.5)` share at most two actual
KDF workers. Timeout, close or unknown outcome do not release a running slot
early or adopt its late result. No queued overflow is accepted. Password bytes
are preserved without trimming or Unicode normalization; UTF-8 bound is 4096.
Creation rejects an empty password. The new API requires at least six characters
and at most 4096 UTF-8 bytes for a new password, preserving its exact bytes; it
does not retroactively impose that rule on old Firebase passwords. Python cannot promise
zeroization of immutable password objects; their lifetime is bounded by real
worker completion and they are never logged or put into generic receipts.

The native password version is an immutable material epoch, not the session
revocation counter. Reset stores a new material version equal to the newly
incremented account token version. Later logout-all may increment token version
without replacing password material, so selector requires password version <=
account token version. After KDF, lock account first and re-read selected
credential in the same session-issuance transaction. Recheck active lifecycle,
disabled flag, exact UID/version/ciphertext and then call
`revalidate_selection(original, freshly_locked)` before session INSERT. A reset,
block or token-version change during KDF must reject the stale snapshot.
This prepared helper does not itself create a SQL authority boundary.

The prepared `NativeSessionStore` composite queries select the current account,
imported credential and optional native credential in one transaction. Issuance
re-reads them with `FOR SHARE OF a,c,n`, then compares the locked active UID,
token version and exact selected ciphertext identity with the pre-KDF snapshot
before session INSERT. Current blocked/disabled accounts and disabled imported
verifiers remain refused. A present invalid native row makes login unavailable;
the old verifier cannot restore access. Existing refresh/logout/session checks
remain unchanged. Strict table-role mode adds SELECT only on
`native_password_credentials`; the already reviewed provider-database role
needs no new grant. One `PasswordWorkPool` handles both schemes and new
derivation, so enabling this gate does not double the two-worker limit.

`native_password_transition.apply_prepared_reset` is a fixed SQL leaf for the
future reset transaction, **not** a reset API. It accepts already encrypted
material with `password_version == challenge_bound_token_version + 1`, never
plaintext passwords/codes. Under the caller's bounded SERIALIZABLE transaction
it locks the challenge-bound current UID/email/active account/version, installs
the native credential, retires an existing imported verifier to the already
allowed `bridge_only` scheme with NULL hash/salt, increments token version and
revokes all device sessions. Exact credential/account/retirement/session
readbacks must match before return. The caller still must validate/consume a
single-use current challenge and write its keyed sensitive receipt in that same
transaction, then own COMMIT/rollback and unknown-outcome reconciliation.

Verifier retirement is mandatory, not an optional cleanup after COMMIT. Without
it, a cold restart with the native flag absent/0 or an older server binary could
accept the retained old Firebase password. Retirement makes that old native
Timeweb login fail closed while composite login uses the new verifier. Preserve
the source/raw archives and `auth_credentials.uid`, `imported_at`, parameters;
the current verifier is superseded by an authorized password change. The
existing importer rejects overwrite conflicts and must never restore the old
verifier over a retirement. A pre-reset database restore also needs the separate
reviewed recovery/cutover policy. This does not reset passwords or revoke tokens
in the still-running Firebase source or permit its bridge to become current
native authority.

The fixed parameters are the 32 MiB scrypt tradeoff documented by
[OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#scrypt).
[Python 3.12 hashlib](https://docs.python.org/3.12/library/hashlib.html#hashlib.scrypt)
provides the existing OpenSSL-backed implementation and memory limit. One local
synthetic derivation on Python 3.12.14/macOS took 0.315685 s; process peak RSS was
48,168,960 bytes, peak increase 33,210,368 bytes. Base scrypt buffer is 33,554,432
bytes; `maxmem` is an OpenSSL bound, not total process RSS. Two concurrent jobs
can consume roughly two such buffers plus process/library overhead. These are
local measurements, not Timeweb runtime capacity/performance proof.

## Proposed challenge and delivery transactions

Implemented API mount, default-off and behind the existing preview guard:

| Action | Request body | Response |
| --- | --- | --- |
| POST `/v1/auth/register-email/request` | `operationId,email` | generic 202 + opaque challengeId |
| POST `/v1/auth/register-email/complete` | `operationId,challengeId,code,password` | success without automatic session, or generic refusal |
| POST `/v1/auth/password-reset/request` | `operationId,email` | generic 202 + opaque challengeId |
| POST `/v1/auth/password-reset/complete` | `operationId,challengeId,code,password` | success requiring fresh login, or generic refusal |
| POST `/v1/auth/operations/lookup` | `operationToken` OR `purpose,stage,original` | read-only original receipt, never retry authority |

Every unavailable/existing email request uses the same outward 202 shape and
synthetic opaque ID without sending mail or exposing account existence. No
credentials, codes or email go in query strings/logs. Unknown-outcome lookup
uses a bounded protected POST and a sealed digest-only operation token. If the
whole response was lost, the client explicitly looks up its exact original body
retained only in memory. Neither branch checks a code or repeats a write.
Immutable encrypted outbox context preserves original UID/email after challenge
replacement, expiry or later email/version changes; it grants no delivery authority.

`AuthChallengeCodec(session_key: bytes32)` derives separate code and normalized
email HMAC keys. `digest(uid,email,purpose,challenge_id,account_token_version,
issued_at,expires_at,code)` binds every field; canonical UUIDv4, six ASCII digits,
and exactly 600 seconds are required. Purpose is `register-email.v1` or
`password-reset.v1`. `verify(expected,now,attempts,consumed,**binding)` rejects
consumed, expired, not-yet-issued and five-failed-attempt challenges. This is
cryptographic eligibility only: SQL consumption/attempts are a separate gate.

`native_auth_challenges` has persistent PK `(uid,purpose)`. Resend replaces only
the current challenge fields and **preserves** its issuance history and signup
marker. Consumption leaves a tombstone. `advance_issuance_history(history,now)`
checks minimum 60 seconds and at most five issues in a sliding hour; callers
must use one server database UTC time and the locked row history. A new
challengeID never creates a new throttle row, resets counters or deletes old
history. History is a bounded array of integer UTC seconds, at most five.
Lock order is account -> challenge -> receipt -> credential/session/outbox.
Account row locking also serializes registration vs reset issuance. Existing
per-peer process rate limit is supplemental. The API adds a durable global
issuance budget over SERIALIZABLE outbox ranges: at most 20 emails/minute and
100/hour; the trusted socket-peer limit is ten lifecycle calls/minute, with five
per canonical email/minute. Client X-Forwarded-For identity is not trusted.

For signup, only a successful **new INSERT** into accounts under unique
normalized email can establish pending authority. Account initially has
disabled=1, email_verified=0, lifecycle=active and token_version=0. In that same
transaction create its registration row with random pending_signup_marker32
and exact account.created_at. Never attach such a marker to an existing account
and never infer signup ownership from disabled=1. Resend must preserve both
pending fields and their original account identity; completion requires marker,
created_at, initial version/flags, unchanged email, and no imported/native
credential or existing auth identity. A concurrent block/version/lifecycle
change refuses completion; activation applies only to this reserved new row.
Orphan/cancelled pending reservations are kept for explicit reviewed cleanup,
not auto-replaced by a fresh UID to bypass email throttling.

Issue transaction creates/updates challenge, preserved history, idempotent
receipt and one outbox email intent together. The existing email outbox payload
must contain an AEAD envelope of code/recipient with exact challenge/UID/purpose
AAD, never plain code/email. `native_mail_envelope.NativeMailEnvelope` supplies
this prepared envelope with exact 600-second lifetime and a separate wrapping
domain. Decryption is not delivery authority: fresh SQL account/challenge state
and both email/code HMACs must also match. `source_event_id` is unique per issued challenge. Receipt request hash
must be domain-separated keyed HMAC and receipt result limited to non-secret
proof/status; do **not** reuse RuntimeMutationStore's original-request wrapper
for password/code bodies. Exact same operation replay does not charge another
issuance/failed attempt or enqueue another email.

Complete protocol: lock and verify eligible challenge/account first; an invalid
code increments failed attempts and commits its declared receipt (no rollback
of charged attempts). Release SQL locks before bounded password KDF. Re-lock
account -> challenge -> receipt, revalidate exact identity/ciphertext/counters,
expiry/email/version/pending authority and consume single-use challenge in the
same transaction as credential write. Reset increments token_version, replaces
native material, retires the imported active verifier and revokes **all** device
sessions atomically. Concurrent
completes yield one change and safe replay/conflict. An uncertain COMMIT requires
explicit receipt lookup, never blind completion resend. Imported identities and
raw archives stay unchanged; both native-row precedence and retirement of the
old active verifier prevent use of the old password after reset.

Mail worker must durably mark `mail_attempt_started`/increment attempts BEFORE
SMTP DATA, then send once. A crash or uncertain SMTP DATA result is not eligible
for automatic resend; stable Message-ID is not deduplication proof. Explicit
user resend is a new operation/challenge with persistent throttling, invalidates
old code, and enqueues a new intent. Expired/replaced challenge intents are not
sent. SMTP transport exists separately, default-off, but real authentication is
currently blocked by its recorded 535 response; no email is sent here.

## Required future integration gates

Runtime SELECT/INSERT/UPDATE on `clrs_staging.*` already covers these proposed
tables after an approved migration; no new runtime GRANT or CREATE is proposed.
Strict table-only role validators must explicitly add only needed tables if
that alternative permission model is used. A distinct default-off lifecycle
flag must avoid selecting absent tables before migration. Closed preview guard,
fixed TLS CA/hostname verification and existing current account/session checks
remain required. SMTP actual credentials/delivery, runtime schema application,
migration backup/version receipt, final source synchronization/write barrier
and controlled login/reset/register
proofs must pass before saying native registration/reset or Firebase-free
production authentication works. This change supplies none of those live proofs.

Focused codec tests: eight synthetic scenarios cover the official old-password
vector alongside new scheme, reset precedence, logout-all, stale post-KDF
selection, AES/AAD/parameter tampering, shared worker saturation/timeouts/close,
submit failure/late result, exact password bytes/bounds, challenge bindings and
durable rolling issuance history. Nine further login transaction scenarios
cover native-only and retained legacy rows, malformed/future native material,
old-password refusal, exact whitespace, credential/version/block races during
KDF, password lifetime across session revocation, strict grants and absent/invalid
feature flags, cold flag-off refusal after imported verifier retirement and
rejection of an incorrectly prepared password epoch before SQL. The 25 existing
native auth scenarios also passed after selecting
the configured Node runtime for the two cross-language fixtures. These tests
use generated data and transaction doubles; no cloud schema or account changed.

A subsequent scoped SQL proof applied the proposal only to a fresh isolated
MySQL8.4.4 datadir over a Unix socket, with skip-networking and mysqlx OFF. Ten
scenarios passed: exactly two added tables (42->44, 66->68 FKs), native-only/
legacy-only/both-password login and nullable LEFT JOIN FOR SHARE queries,
invalid native refusal, post-KDF ciphertext/version/disabled/blocked/deleted
changes, fresh login after token-only revocation and rejection of a missing JSON
parameter. The first local DDL attempt found MySQL3812: CHECK requires a boolean
expression; the COALESCE fail-closed predicate was corrected with explicit
`= TRUE` and then executed successfully. TLS and SHOW GRANTS preflight were
simulated solely for this Unix-socket fixture; no Timeweb role/TLS/cloud
acceptance is claimed. The isolated server was stopped, the earlier restore
datadir was not opened, and no real user data was used.

Six additional reset SQL checks passed on that same isolated database. The
trusted step installed a native credential, retired the imported verifier,
advanced the account version and revoked every device session atomically.
Injected readback and pre-COMMIT failures rolled all four affected tables back
byte for byte. A stale pre-reset KDF snapshot was refused. A cold flag-off
restart refused the old password without creating a session; enabling native
selection allowed the new password to create a valid session. The initial
cold-start harness expected only 401, while the closed service safely returned
503; the harness accepted the documented closed response and continued only
the remaining checks. There were no SQL driver errors. This proves only the
trusted local SQL step, not challenge eligibility, a public reset API, mail
delivery or live Timeweb password reset.

The separate durable leaves now exist: `native_auth_challenges` binds a current
account to one expiring challenge, preserves hourly issuance history, and commits
declared failed attempts through its trusted caller. `native_pending_account`
reserves only a brand-new account at request time and activates it only with a
registered same-transaction consumed-signup proof. `native_auth_receipts` stores
only server-keyed request/context/actor HMACs and fixed safe responses; request
scope is always pre-account email identity, completion scope is the original
challenge's UID. Unknown COMMIT lookup is read only and never authorizes retry.
Their ordinary runtime transaction, schema/TLS/role and HTTP authority are
explicit caller requirements, not supplied by those leaves.

Seven challenge, six pending-account and eight sensitive-receipt synthetic
scenarios passed. Seven envelope scenarios also passed; none sent mail. Six
additional grouped checks on the same generated-only local MySQL8.4.4 applied
005 (44->45 tables, FKs unchanged at 68), exercised reservation/first issue,
failed-attempt receipt and replay without a second charge, current email/version/
block refusal, activation of exactly the reserved account, atomic reset and
post-effect full rollback, plus SELECT-only unknown-outcome lookup. The 163
bounded SQL statements produced no unexpected driver error. The local server
was stopped; earlier password scenarios, restored real data, cloud schema,
SMTP and live permissions were not touched. No lifecycle API or delivery was
enabled by these checks.

## Mounted assembly and activation conditions

`native_auth_request` atomically reserves a genuinely new pending account,
issues one challenge, encrypts one outbox intent and finishes its safe receipt.
`native_auth_completion` releases the first SQL transaction before the shared
KDF, then re-locks current account/challenge and atomically consumes the original
code, changes credentials/activation, revokes reset sessions and finishes the
receipt. Valid-code preparation never commits a started receipt before KDF.
Unknown COMMIT returns original keyed fingerprint; no automatic replay occurs.

`native_auth_lifecycle_http` is mounted after the preview guard in `app.py`.
It requires `CLRS_NATIVE_AUTH_LIFECYCLE_ENABLED=1`, the existing auth/write,
password/challenge flags, provider-database role, verified working mail and
`CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED=1`.
These flags remain off on the closed live stand. Signup additionally requires
`CLRS_NATIVE_REGISTRATION_ENABLED=1` and
`CLRS_NATIVE_REGISTRATION_SOURCE_AUTHORITY=final-auth-import-and-write-barrier-v1`.
That assertion is permitted ONLY after the actual final canonical Auth import
and old-source write barrier are verified. The first inconsistent snapshot
does not qualify. Table-only alternative grants are not silently expanded.

Seven completion and seven request synthetic tests passed. Four new completion
groups through actual local MySQL/store transactions confirmed two-phase KDF,
replay without writes, a version race and COMMIT with lost acknowledgement.
One new WSGI/local SQL flow confirmed preview denial, signup including a wrong
attempt, protected receipt lookup, reset of the same account and generic unknown
email response. Further original-body lookups recovered lost request/completion
responses without KDF or writes, including after current email/challenge changes.
These used generated accounts, not real users; mail verification and final-source
gates were synthetic assertions. They do not prove SMTP, live TLS/grants, source
consistency or app cutover.

`native_auth_mail_worker` claims one encrypted intent, requires acknowledged
claim COMMIT and a different connection's fresh verification COMMIT, releases
all SQL locks, then passes the remaining absolute budget to the shared SMTP
transport. Unknown SQL/SMTP outcome is never automatically sent again.
`native_auth_mail_dispatcher` owns one background daemon, checks an eligible
current row every five seconds and coalesces nonblocking HTTP wake events.
The 32-second maximum spans background SQL/delivery phases, never HTTP waiting.
Stale-email intents are retired with an acknowledged exact-row write and no
SMTP/code-attempt charge; they cannot hot-loop or block later current rows.
Uncertain claim/verification/finish halts dispatch until explicit operator
read-only reconciliation/restart; automatic recovery is not claimed.
Shutdown closes the SMTP transport before cancel/join, preventing late delivery.

The separate Flutter `TimewebAuthLifecycleClient` is typed and default-off. It
retains exact original input only within a bounded in-memory screen/account
scope, deduplicates taps, aborts real HTTP/stream ownership, blocks late A-B-A
responses and performs explicit read-only reconciliation without resending a
mutation. Two targeted Flutter scenarios and scoped analysis passed. It is not
installed in the auth screens or the application's backend selector yet.
