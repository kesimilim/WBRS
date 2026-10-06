# Reviewed logical media promotion (staging verified)

The authenticated private audit contains all 6,478 Storage objects / 6,932,196,752
bytes. Exactly 5,191 candidates have now been staged and independently verified in
26 bounded transactions; 1,287 remain quarantined. **HTTP remains disabled.**

Promotion inserts canonical `media_objects` rows pointing to the SAME immutable
`clrs-import-quarantine/<source-identity-SHA>` key. It copies no objects and changes
no legacy rows, Storage metadata, key, ACL, policy, credentials, runtime flags or
source data. It does not attach `profile_photos`, chat/meeting media relationships
or expose URLs. The importer still never serves/signs quarantine. The reviewed
canonical alias is a separate backend decision; there is no automatic promotion.

## Immutable review pins

- FULL archive: `b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e`
- Inventory manifest: `82352a0bb8a172fc33034204be2a3a752bcac69cc971f0feeb9a177ebcb3a341`
- Authenticated audit plan: `c9b8279bada1f8442dd9d8f97792f45d7f0eb56e9bba2f71968c052e8fe46f0b`
- Full canonical rows digest: `c30890b3a247fd927ff7274ddc64475b393a91c513dc6edc685c411014d57bd6`

The executable CLI hardcodes those source/plan pins. There is no unpinned CLI,
alternate-source flag, environment override or SQL input. Library fixtures can
provide explicit alternative review pins for synthetic tests only. All SQL plans
must have been minted by the HMAC-validating preparation factory. The CLI reads
the existing authenticated mapping; it does not decrypt/copy the 6.9GB export again.

## Evidence required before a future stage

`signMediaReadbackAcknowledgement` signs an **operator-reviewed evidence binding**;
it does not run or independently prove a readback. Do not produce this file until
the reviewer has checked the actual completed FULL SQL/S3 verification result,
its successful completion status and their relationship to the pinned archive.
Use an existing private HMAC key, an outside-Git 0600 file and this exact body:

```text
kind: clrs-media-full-readback-acknowledgement
version: 1
state: reviewed_verified_full_raw_sql_s3
pins: the three immutable review pins above (archiveSha256,
      inventoryManifestSha256, planSha256)
source: exact {project, database, bucket} from the authenticated private mapping
counts: exact {authUsers:8208, firestoreDocuments:70486,
              storageObjects:6478, storageBytes:6932196752}
targetBucket / expectedOwner: exact private Timeweb/S3 target and canonical ACL owner
completedAt: actual completed verification UTC timestamp (ISO with milliseconds)
rawVerifyResultSha256 / rawVerifyStatusSha256: SHA256 of the reviewed private reports
```

The helper adds `proofSha256` and domain-separated `proofHmacSha256`. The CLI also
requires the exact SHA256 of that completed private acknowledgement file. This
file is NOT created by dry-run, does not substitute for current privacy checks,
and was created only after reviewing the completed full raw SQL/S3 reports. Its
file SHA256 is `09f1fb45427b0f1e460fea482d5dad9fd5e682263c40051d5dfb49d0214a76fd`.

Stage requires actual read-only Timeweb private-type/website checks, expected-owner
bucket ACL, absent/exact-empty bucket policy, and expected-owner ACL of each candidate
object. Only GET commands are used; no anonymous probe, PUT, DELETE, presign or
public URL. The existing key must actually permit these GETs; failures block stage.
No runtime credential or privilege changes are included here.

## Bounded chunks, receipts and explicit recovery

The byte-sorted full plan has **26 deterministic chunks**, at most 200 candidates
each (last chunk 191). Each chunk's object ACL preflight runs **before its database
transaction** with at most 4 operations, 5-second per-operation deadlines and a
120-second total deadline. All object proofs must still be younger than 120 seconds
before COMMIT. The final global bucket/type/ACL/policy checks are bounded; thousands
of remote object requests are never run while SQL locks are held. Slow checks refuse
the chunk; bounds cannot be extended by CLI arguments.

Each transaction is SERIALIZABLE and has a 60-second absolute socket-kill deadline;
individual SQL uses the shared bounded MySQL wrapper. TLS requires CA verification,
DNS/SNI hostname identity, utf8mb4, staging database, MySQL8.4/16KiB pages, strict mode,
42 InnoDB/binary-collation tables, 66 FK and schema version1. SHOW GRANTS must have
exactly CREATE, REFERENCES, SELECT, INSERT, UPDATE on `clrs_staging.*`, only global
USAGE, and default_db access must fail. No DDL/DELETE/GRANT is issued.

Within the transaction, the exact raw source counts are checked, along with every
chunk object's exact bucket/path, metadata SHA/MIME, source and target SHA, immutable
target key, bounded size and completed copy marker. Candidate references are checked
against their typed source-document/Auth hashes. Owner UID equality is byte-exact;
source Auth must exist/be enabled, the canonical account must be active/enabled,
and existing root profiles must not be malformed, disabled, deleted or blocked,
including `registrationStatus=blocked/deleted`. Missing profiles are not invented.

Only plain INSERT of ready rows is allowed. The existing canonical table must
match the complete already-verified prefix exactly. Any extra, missing, conflicting
or partially applied row refuses writes; there is no overwrite/upsert/DELETE.
Requests/results are bounded by max100 rows and actual max_allowed_packet; source
JSON readback has explicit row bounds. Full canonical records, generated key hashes,
timestamps and total COUNT are compared before COMMIT.

For each chunk an AES-GCM encrypted, HMAC-bound **prepared** receipt is fsynced before
COMMIT. Prepared does not mean committed. Lost/failed COMMIT sets
`MEDIA_PROMOTION_COMMIT_OUTCOME_UNKNOWN`, poisons the connection and requires a new
connection plus receipt-bound verify before any retry. No automatic replay occurs.
Pre-COMMIT failures roll back; they can still leave a prepared local receipt.

Verify emits and durably saves a separate encrypted/HMAC verification proof:
`present_verified` or `not_committed_verified`. Only `present_verified` proves an
already-existing prefix. Resuming chunk N requires an ordered private history of
exactly N receipt/verification pairs and a last verification younger than 5minutes.
The whole prefix is checked again inside the next transaction. A prepared receipt
alone, stale proof, proof from another receipt, or unknown COMMIT cannot authorize
resume. After an interrupted pause, re-verify the last receipt into a new proof file.

The 0600 outside-Git history file contains only paths:

```json
{"kind":"clrs-media-promotion-history","version":1,"entries":[
  {"receiptFile":"/private/chunk-0.clrsenc","verificationFile":"/private/chunk-0-verified.clrsenc"}
]}
```

Each immutable receipt links all previous receipt digests. Encryption uses a
separate protected 32-byte receipt key (not the audit HMAC key). Output directories
must be same-owner0700, files0600, existing outputs are never overwritten. Shared
stdout/errors contain aggregates only, never identifiers, URLs, keys or SQL payloads.

## Future command sequence (do not execute before review)

Use Node22. Common CLI arguments:

```text
--audit-file ABS_PRIVATE_MAPPING --hmac-key-file ABS_PRIVATE_HMAC_KEY
--project EXACT_PRIVATE_PROJECT --database EXACT_PRIVATE_DATABASE --bucket EXACT_PRIVATE_SOURCE_BUCKET
--confirm-archive-sha256 b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e
--confirm-manifest-sha256 82352a0bb8a172fc33034204be2a3a752bcac69cc971f0feeb9a177ebcb3a341
--confirm-plan-sha256 c9b8279bada1f8442dd9d8f97792f45d7f0eb56e9bba2f71968c052e8fe46f0b
```

1. `media-promotion-cli.mjs --mode dry-run` + common arguments: entirely local.
2. After reviewing actual evidence and read-only ACL permissions, stage chunk0:
   common arguments, `--mode stage --chunk-index 0 --confirm-target-db clrs_staging`,
   private config/CA/readback acknowledgement/exact acknowledgement fileSHA,
   separate receipt key/new chunk receipt path, exact target bucket/owner and
   Timeweb bucketID/private-bucket confirmation. Existing private S3/Timeweb
   environment variables are read; no credentials are written to Git or settings.
3. Fresh connection: `--mode verify --chunk-index 0` with same source/evidence,
   receipt/key and a new `--verification-file`. This uses SQL reads only.
4. For N=1..25, supply `--history-file` with all prior authenticated pairs. Stage
   N once, then fresh verify N. Any unknown result stops the sequence at that exact
   receipt. This CLI deliberately does not orchestrate/retry all chunks automatically.
5. With26 verified pairs: `--mode verify-all --history-file ... --complete-ack-file NEW_PRIVATE_PATH`
   and the same readback/TLS/private S3 configuration. Each chunk gets fresh read-only
   ACL checks and a short read transaction. A final SQL snapshot verifies all5191 full
   rows, COUNT, full raw Storage bindings and current owner/source state. Only then is
   an encrypted/HMAC complete acknowledgement saved. Privacy checks are sequential
per chunk, **not an atomic SQL/S3 snapshot**; HTTP remains disabled.

The operator must keep the imported keys immutable throughout this reviewed phase;
the CLI itself issues no S3 mutation and cannot freeze unrelated writers. The pinned
Firebase export is a nonconsistent live-source snapshot; final source synchronization
and a production cutover are separate work, not established by media promotion.

Partial ready rows do not authorize enabling the endpoint. The Python media factory now consumes and verifies the complete acknowledgement
before configuration or SQL, including exact pins, target, EOF, AES-GCM and HMAC.
It has also accepted the real completed ciphertext below. This is not an HTTP route
in app.py. Before enable, the existing private media service
must require that gate and keep current membership/owner/ACL/hash rechecks plus full
GET SHA verification before returning any bytes. Its HTTP deadline/cancellation
contract and dedicated Get-only role still require review/live proof.

## Verification performed

Targeted synthetic tests cover HMAC/pin/count failures, candidate/quarantine coverage,
200-row chunking, source/canonical inactive owners, registration blocked/deleted,
grants/packet/raw conflicts, prepared receipt ordering/fsync failure, both unknown
COMMIT outcomes, stale/mismatched history, final exact verification, read-only privacy
cap4, owner/public-state failures and strict CLI pins. A local dry-run of the real
authenticated mapping confirmed6478/5191/1287 and26chunks. No network/SQL/S3 mutation,
promotion, live ACL check, runtime flag change or HTTP exposure was performed.

## Actual staging result, 2026-10-01

All 26 transactions committed and each receipt passed a fresh connection verify:
5,191 exact `media_objects` records, 1,287 retained quarantine files. A final
`verify-all` rechecked each private S3 ACL chunk and the full SQL/source/owner
binding in a final SQL snapshot. It issued reads only and saved the encrypted
complete acknowledgement, SHA256
`35f562035f24a80f69f4c0a165d5f6b79fb8b69486eb2722d1e338796a76b833`.
The real ciphertext passed the Python AES-GCM/HMAC consumer too. No file was
copied or made public; raw objects and their original receipt bindings remain
unchanged. Privacy checks are sequential, not an atomic SQL/S3 snapshot.

Private evidence outside Git: `media-promotion-stage-0-result.json` through
`media-promotion-stage-25-result.json`, matching fresh verify results, 26 encrypted
receipts and verification proofs, `media-promotion-history-all.json`,
`media-promotion-verify-all-all-result.json` and `media-promotion-complete-ack.clrsenc`.
The receipt key and all identifiers remain private. Final source synchronization,
current mutable membership, HTTP integration and native APK acceptance remain open.
