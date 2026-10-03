# Imported final authority: protected bootstrap transport

This source candidate supplies transport for an independently reviewed final
cutover authority. Actual final writer barrier/cohort authority has not been
issued. Imported service activation and app mounting remain separate work.
No bootstrap boolean, current-root observation, old archive, or unsigned JSON
creates authority.

`load_reviewed_imported_authority(env)` returns `(capability, reviewed_binding)`
for the existing `create_app(imported_meeting_authority=..., imported_meeting_binding=...)`
injection. It returns `(None, None)` only when all three bootstrap fields are
absent. Any partial, malformed, stale-source or rejected configuration raises
`RuntimeUnavailable`; the caller must fail startup closed rather than discard
the error and silently serve native-only routes. This patch does not edit or
mount `app.py`, change gates, issue a pack, or touch imported media's 14 files.

The protected operator settings carry only these three small fields:

- `CLRS_IMPORTED_MEETINGS_PACK_ACK_B64`: canonical UTF-8 ACK, at most 16 KiB.
- `CLRS_IMPORTED_MEETINGS_PACK_ACK_HMAC_HEX`: lowercase 64-hex HMAC-SHA256 over
  `b"clrs-imported-authority-bootstrap-ack-v1\0" + exact_ACK_bytes`.
- `CLRS_IMPORTED_MEETINGS_AUTHORITY_KEY_B64`: a dedicated, exactly 32-byte key;
  it must differ from configured preview/session/legacy-cursor keys.

ACK exact fields are `version:1`,
`kind:"reviewed-imported-authority-bootstrap"`, `binding`, `storage`, `object`,
`plaintextSha256`, and `packHmacHex`. `binding` contains exactly generation,
sourceSha256, cohortSha256, policy, barrierSha256, finalDeltaSha256. The current
reviewed policy and actual runtime source fingerprint must match before any S3
request and again when the accepted capability is returned. The authority's
source fingerprint adds this bootstrap, unchanged `private_media_s3.py`, and
`requirements.txt` to the existing runtime guard dependencies. No genuine final
pack exists to reissue yet. The old 300-second observation mode is unchanged.

`storage` contains exactly fixed endpoint `https://s3.twcstorage.ru/`, bucket,
owner, region and integer controlBucketId. It must equal the existing protected
`CLRS_LEGACY_MEDIA_TARGET_BUCKET`, `CLRS_LEGACY_MEDIA_EXPECTED_OWNER`,
`CLRS_LEGACY_MEDIA_S3_REGION`, and `CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID`
configuration. S3_USER_MODE must remain `dedicated-read-only`. Existing read
access/secret/control token fields are reused, without a new user/bucket or
writer credentials. The reader retains verified TLS, fixed hosts, no redirects,
no retries, private bucket API state and owner-only object/bucket ACL checks
before/after full GET. It does not write/delete/list objects.

`object` contains exact `key`, `size`, `sha256`, `content_type`:
`clrs-import-quarantine/<64 lowercase hex>`, positive integer ciphertext length
at most 8 MiB, complete body SHA256, and `application/octet-stream`. Use a new
immutable content key when separately publishing the approved pack; never
overwrite an imported object. The ACK authenticates the exact retained object
and full expected SHA, so replacement cannot issue authority.

Ciphertext format is `b"CLRSIMA1" + nonce12 + AESGCM_ciphertext_and_tag16`.
Derive its key as HMAC-SHA256(master key,
`b"clrs-imported-authority-encrypted-pack-v1\0encryption-key"`). AES-GCM AAD is
`b"clrs-imported-authority-encrypted-pack-v1\0"` plus canonical JSON containing
exact generation/sourceSha256/plaintextSha256. Ciphertext, decrypted pack and
ACK are held in bounded RAM only; no plaintext file or env-sized pack is made.
The 8 MiB ciphertext cap leaves at most 8 MiB minus 36 bytes for plaintext.
The total fetch has a 30-second deadline, all responses close, and cancellation
is set on success/failure.

After full verified fetch and AEAD/plaintext SHA validation, the loader passes
the exact plaintext, packHmacHex bytes and dedicated key to existing
`load_imported_authority(..., reviewed_binding=binding)`. Existing v1/v2 pack
domains, exact final-delta/tombstone/cohort checks, true consistent/final/barrier
fields, identity/member guards and source guards remain mandatory. The ACK
does not waive these checks. A trusted assembler can create this ACK only after
the actual enforced source barrier, coherent final capture, canonical CAS/apply
and fresh readback have been reviewed; those actions are not implemented or
claimed by this transport patch.

Three new local tests use actual AES-GCM, `PrivateMediaS3` and the final authority
validator with a synthetic HTTPS port and synthetic final fixture: absent and
malformed settings refuse before network; valid full private transport succeeds;
tampered cipher/AEAD, privacy/ACL, final/barrier/tombstones/pack signatures refuse.
No live config, key, Firebase, S3, SQL or real cohort is read. These tests are
source/contract evidence only, not proof of a real final barrier or activation.
