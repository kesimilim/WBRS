# Private media ownership audit

The audit prepares a private mapping; it does not publish images, change ACLs,
insert ready rows, or enable the media endpoint. Run it once against the
authenticated completed segmented source and keep its output outside Git.

```sh
node server/timeweb/media-audit-cli.mjs \
  --archive /private/full.clrsenc --key-file /private/archive.key \
  --manifest /private/final-manifest.json --hmac-key-file /private/manifest-hmac.key \
  --project chatapp-4e347 --database '(default)' \
  --bucket chatapp-4e347.appspot.com \
  --confirm-archive-sha256 <reviewed-full-archive-sha256> \
  --confirm-manifest-sha256 <reviewed-final-manifest-sha256> \
  --output /private/media-audit.json
```

Inputs must be distinct owner-only files, keys must be separate 32-byte values,
and the output directory must be owner-only (`0700`) outside the repository.
The output is created as `0600`, authenticated with HMAC, and never replaces an
existing file. Only aggregate counts and plan hashes are printed. Storage
download tokens and URL query strings are not retained in the mapping.

The full archive scanner decrypts and hashes every source object. Ownership
uses exact supported Firestore/Auth reference locations and evidenced upload
paths; it never guesses a UID from a display name or arbitrary path substring.
Ambiguous owners, disabled/deleted users, unsupported contexts or MIME types,
unsafe paths, invalid hashes, and unreferenced files remain quarantined.
Reference locations and source-document hashes are preserved privately for
the later authorization review. A proposed ready row is a proposal only.

## Actual audit on 2026-10-01

| Result | Count |
| --- | ---: |
| All source objects | 6,478 |
| Source bytes | 6,932,196,752 |
| References | 65,886 |
| Candidates for separate promotion review | 5,191 |
| Objects retained in quarantine | 1,287 |
| References to files absent from the source | 2,887 |
| Distinct absent source files in this audit | 418 |
| Promotions / SQL or S3 writes | 0 |

The 418 figure counts distinct keys in this audit's whole-value URL scan,
including retained reference contexts. It is not the earlier manifest's
different reference projection. These missing files were already absent from
the Firebase source inventory; the audit does not report a migration loss.

Full archive SHA256:
`b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e`.
Final manifest SHA256:
`82352a0bb8a172fc33034204be2a3a752bcac69cc971f0feeb9a177ebcb3a341`.
Plan SHA256:
`c9b8279bada1f8442dd9d8f97792f45d7f0eb56e9bba2f71968c052e8fe46f0b`.

Coverage, HMAC, owner/purpose/key/size/content-hash binding and private file
permissions passed. This evidence does not replace live authorization,
private-bucket checks, promotion receipts, or a current membership authority.
See [default-off private image service](python-stand/LEGACY_PRIVATE_MEDIA.md)
and [final synchronization](FINAL_SOURCE_SYNC.md) before any client cutover.
