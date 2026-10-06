# Current native profile editor

The existing native runtime now provides a reachable edit form for `fullName`,
`about`, and `hobbi`. It uses the approved CLRS photograph, panel, form controls,
and existing localization keys. It does not use Firebase services or hydrate a
profile from the immutable legacy snapshot.

Activation requires the existing explicit native startup/auth configuration
plus `CLRS_TIMEWEB_PROFILE_EDITOR_ENABLED=true`. This new flag defaults to false
and sets the existing native client's `runtimeWritesEnabled` configuration.
Review APK `CLRS-1.0.25-43.apk` includes this source at commit `5481858`, with
Firebase selected and the native editor flag disabled. It does not establish
Timeweb cutover or deployed editing.

When this editor is enabled, the native gate reads only the authenticated
`GET /v1/runtime/me/profile`. The edit button appears after a successful typed
`canonical-current-v1` response with an existing profile. Missing, refused or
unconfirmed reads retain the normal unavailable/retry/logout treatment; they
do not open Firebase Home or infer registration completion. The immutable full
profile reader remains the previous default-off-editor path.

The form preserves historical nullable or short values unless that particular
field changes. Changed descriptions/interests must contain at least 20 trimmed
Unicode characters. Original entered bytes are sent unchanged. Only changed
fields are included; no age, geography, photos, test/group, onboarding flags,
roles or financial values are written.

Before a POST, the exact owner/origin, UUID4, CAS `updatedAt`, changed fields and
request hash are flushed to one serialized application-private journal. File
names contain only a digest of the owner/origin; entries contain profile text,
not access tokens, refresh tokens, email, code or password. This follows the
app's existing private-draft storage approach; device backup/extraction behavior
and OS-level encrypted storage for profile text have not been proven here.
Journal decoding has a 64 KiB bound, exact encoding/shape and digest checks.
Unresolved entries are never replaced. A runtime's stop waits real journal IO
after invalidating its session, before another owner can be installed.

The existing mutation client supplies the only transport. Duplicate saves share
the original Future. A deadline or missing ACK keeps the operation unknown;
explicit checking uses the original operation's receipt GET, never a replacement
POST. A recovered journal is always lookup-only. A `not_found` receipt cannot
authorize another write. A definite refusal/CAS conflict retires exactly the
original journal and requires explicit reopening with a new current GET.
Confirmed saves retire the matching journal before success closes the form.

Both facade and native-client leases guard the form and response. A/B/ABA,
logout or stop closes/invalidates the form; late results cannot clear another
owner's journal, update their fields or display success. Leaving the screen
revokes UI adoption and retains unresolved data. It does not assert cancellation
of a server write that may already be committed.

Focused local evidence consists of one flow test (CAS conflict, nullable-field
preservation, durable-before-POST, duplicate save, lost ACK, new-runtime lookup,
not-found and matching confirmation, bad digest) and one widget test (actual
gate→form→POST→ACK→close, then pending A→B invalidation and journal isolation).
These use synthetic HTTP and a real temporary disk journal, not production
writes or an Android device.

Remaining migration work includes native Home/search/chat/meeting/feed services,
native onboarding geography/media/test/group contracts, final source write
barrier and consistent delta import, and device/live acceptance. Editing these
three current fields does not establish that the application has migrated.
