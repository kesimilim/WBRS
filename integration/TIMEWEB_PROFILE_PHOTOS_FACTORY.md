Native profile-photo setup
==========================

The app mounts a lazy, default-off native photo reader behind the existing
operator preview guard. `CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED=1` still requires
the existing canonical runtime flags and an explicit
`CLRS_RUNTIME_PROFILE_PHOTO_ORDER_POLICY`: `reviewed-source-document-id-binary-asc-v1`
keeps the original strict behavior;
`reviewed-source-document-id-binary-asc-available-originals-v2` explicitly selects
the same `available-originals-v2` policy as the projector. Only missing, valid
typed-null or empty gallery `url` is omitted in that policy. Every source ID,
document/payload pin and complete binary ID order remains bound; `profilePic`
original and all nonempty gallery originals still require exact ready ownership
and provenance. Malformed/nonempty-unmapped/foreign/conflicting evidence fails
closed. Complete old associations remain readable; new v2 leases use a distinct
context fingerprint. Strict planner/projector defaults and v1 receipt/AAD semantics
remain unchanged; missing or unreviewed factory policy is not a fallback.

Construction verifies the existing authenticated completed media acknowledgement,
including its fixed source/archive pins and approved full raw SQL/S3 readback
proof. That same genuine acknowledgement supplies the trusted completed source
capability; SQL alone or a caller-created dataclass does not. This remains an
archival import with `consistent=false`, not a final write barrier or cutover.

Only the dedicated read-only S3 key, read-only control-plane token and existing
native runtime SQL configuration are accepted. Session, reference and completed
receipt keys must be distinct. There is no migration-key fallback, public URL,
SQL/S3 request during setup, or new paid resource. A new owned private temporary
directory holds anonymous verified original streams. Closing the HTTP reader
aborts its downloads and SQL work and cleans up that directory.

Required existing media settings use the `CLRS_LEGACY_MEDIA_*` names from the
private media setup; enabling native photos does not enable legacy media routes.
Missing/bad photo flag leaves routes at 404. Invalid proof/configuration with an
explicitly enabled reader returns 503 without weakening authorization.

Focused synthetic checks cover setup/cleanup and explicit v2 factory selection,
blank-source pin retention, old complete associations and changed-context lease
refusal. Accepted source/tests are in GitHub `bec0a3d`; root confirmed GitLab
`7f880d9` ONLINE behind the preview guard and bounded real association apply /
readback. This acceptance does not establish that every source photo is available,
that native login or public access has been proved, or that cutover is complete.
Existing runtime gates, current-session/account/visibility checks, source/media
proofs and dedicated private S3 permission boundaries remain mandatory.
