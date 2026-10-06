# Imported meeting read authority: default-closed assembler seam

This patch supports list/detail/roster for an explicitly reviewed imported
cohort with a supported exact local schedule or canonical UTC timestamp. It is source
readiness only. No real barrier/final-delta evidence, production manifest,
issuer, actual authority injection, activation, grant or SQL mutation was produced here.
It does not establish readiness for all imported meetings.

The old private current-root observation and its 300-second expiry are untouched.
An old snapshot, `consistent=false` receipt, signed configuration boolean or
current-root observation cannot be loaded as final authority.

## Required external cutover evidence

Only a separately reviewed trusted cutover assembler may call
`load_imported_authority(raw, signature, key, reviewed_binding=...)` and inject
the accepted opaque capability through
`create_app(imported_meeting_authority=authority, imported_meeting_binding=reviewed_binding)`.
The binding is not accepted from a user request or an env flag.
The assembler must independently authenticate and review the genuine enforced
barrier for **all** Firebase writers and the complete consistent final delta,
deletions and verified canonical readback. Reopening source writers requires
revoking/replacing this generation before serving. No automatic renewal exists.

The bounded HMAC-SHA256 pack has exact version/kind/namespace, distinct domain
`clrs-imported-meeting-final-authority-v1\0`, source-code fingerprint, policy,
generation, cohort hash and reviewed barrier/final-delta receipt hashes. Barrier
`enforced`, `allWritersStopped`, `verified` and delta `consistent`, `final`,
`complete`, `readbackVerified` must each be boolean true. Ordered final root
IDs/hashes and explicit tombstones have separately recomputed digests; live
roots and tombstones must be disjoint and each served entry must exist exactly
in the final root set. The reviewed canonical projection and metadata review
digest, source users/kicked arrays and omission policy are authenticated too.

These checks verify authenticated assertions and exact reviewed references;
they do **not** acquire or independently prove an external writer barrier or
readback. A trusted signing key alone does not make invented assertions genuine.
There is currently no issued genuine final barrier/cohort or production evidence
input. The app now has an injectable assembler port, but imported reads remain
default closed and are not activated. The signer/key provisioning is a
separate operator decision; this patch reads no real key, env or protected data.

Bounds: 8 MiB pack, 4096 final roots/cohort entries/tombstones, 1000 users/kicked
per root, 65536 total user/kicked entries. Exceeding a bound refuses, never clips.
The immutable capability stores sealed entry bytes and returns copies. Its source
fingerprint includes the reader/policy/shared guards and pinned geography;
changing any bound source invalidates it before/after a read. The actual app,
runtime dispatcher and read dispatcher source hashes also enter this binding.

## App assembly

The optional app arguments pass directly to the existing runtime dispatcher,
which reuses its same current transaction store for list/detail/roster. Without
them, the previous native marker policy and one-argument custom factory contract
remain unchanged. A partial pair, boolean/dictionary imitation, mismatched
reviewed binding or stale capability refuses construction; it cannot silently
fall back to native authority. The preview guard still runs before initialization
and before the injected capability is adopted. Under the preview guard, failed
assembly returns 503 without publishing imported data. No env flag, JSON input,
key loader or issuer is added. Shared store close/drain ownership is unchanged.

## Current runtime proof

The read-only subclass reuses the current RuntimeMutationStore session/account
pre/post check and SQL transaction/locks, actor and foreign profile visibility,
canonical member left/kicked state/revision, sparse pagination and 64 KiB DTO.
It adds only bounded exact PK root/member provenance SELECTs with FOR SHARE.
The existing 64-statement cap remains. Root raw is limited to 131072 bytes;
member pointer raw to 2048 bytes; each extra query is limited to 32 exact keys.

The retained typed source payload hash, exact source users/index/path/hash and
reviewed canonical metadata must match. IDs/raw are never rewritten. Initial
canonical revisions are lower bounds so later canonical revisions do not freeze
the read; source kicked UIDs deny even without a canonical member row. Existing
NULL joined_at stays unknown. Current canonical left/kicked state remains final
for roster eligibility; leaving a public group does not hide its public metadata.
Invalid provenance or metadata cannot fall back to native/legacy visibility.
Cursor filtering binds the complete authority fingerprint, including generation.

Policy `reviewed-imported-meetings-read-schedules-v2` has two exclusive wire
branches using the existing fields: localDatetime is the original calendar-valid
`d[d].M[M].yyyy H[H]:mm` source string and startsAt is NULL, or localDatetime is
NULL and startsAt is the canonical `YYYY-MM-DDTHH:mm:ss.ffffffZ` UTC value.
Local day/month/hour may have one or two digits; the source spelling is retained.
UTC years must fit SQL DATETIME, 1000..9999. The original typed timestamp stays
unchanged in retained raw; the existing reviewed `_schedule` supplies its SQL6
representation and refuses a nonzero nanosecond remainder. Neither read branch
guesses a timezone or converts local time into UTC. Both missing, both present,
offset/truncated UTC, invalid calendar and disagreement with retained source are
closed. Native create/request/receipt validation remains strict local16.

The pure `meeting_schedule.read_schedule` helper is shared with HTTP wire
validation and both helper/HTTP source hashes now enter authority binding.
Changing to v2 invalidates old source/policy-bound manifests; no old observation
is renewed. Flutter displays original local text or an explicit UTC label,
without device-local conversion; list validation retains the server's
null-first startsAt/meetingId order. UI/transport changes are reviewed separately.

Native marker globals and mutation guards remain unchanged. Imported current or
archived messages are refused with current actor authentication. Existing native
message paths keep their previous implementation. No imported join/chat/leave/
kick capability, DDL, write, role or factory activation is added.

## Local evidence

Five new synthetic cases passed using the real shared read store with injected
SQL fixtures: mandatory signed flags/domain/binding/tombstones/schedule refusal;
list/detail/roster and redaction/NULL history/current revisions; raw/metadata/
member provenance/hidden/deleted/current leave/source kick; actor A→B and current
revocation plus cursor generation binding; factory closure and unchanged native
mutation rejection. No TCP/database/cloud call or old suite was run. Initial
fixture-only failures and affected corrections are recorded in the private freeze
manifest; passing cases were not repeated after unrelated fixture corrections.

The schedule correction adds three targeted runtime/HTTP fixture scenarios:
UTC/null-first ordering and unchanged raw; one-digit and native16 literal local
dates; unknown/conflicting/offset/truncated/nanosecond/unrepresentable timestamp
and source/wire mismatch refusal. Historical cases are not a rerun claim.

One additional focused app case uses the exact app construction/WSGI functions
and real runtime dispatcher with the existing synthetic current-store fixtures.
It checks the unchanged preview guard, default closure, invalid injection refusal,
accepted synthetic authority list/detail/roster and native detail routing, plus
shared-store cleanup. It does not issue or prove an actual final barrier/cohort.
