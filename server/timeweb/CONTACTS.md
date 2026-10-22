# Native friends and guests

The Timeweb client now opens Friends and Guests from its existing CLRS drawer.
Public profiles offer friend actions. Friends has current, incoming and outgoing
lists; accepted relationships can be removed, requests can be cancelled/declined.

`GET /v1/runtime/contacts?kind=friends|incoming|outgoing|guests` returns up to 20
items by default (maximum 30). Continuation tokens bind the session owner, list,
page size and a five minute expiry. Public profile fields are joined in one
bounded batch; hidden, blocked or deleted profiles are excluded. The list never
accepts an owner UID. Avatars reuse the native photo admission/cache path and
rows are built lazily with a sliver list.

`GET /v1/runtime/contacts/people/{uid}` reads the pair revision. The fixed
`contacts.change.v1` operation accepts `kind`, `targetUid`, `expectedRevision` at
`POST /v1/runtime/contacts/actions`, with the normal operation UUID envelope.
Friend actions require the current revision. Both directions share one pair
row; removing a relationship retains a tombstone revision. This prevents stale
requests from recreating an old friendship. Lost responses retain the original
operation and hash for receipt reconciliation; they are never silently resent.
A committed rejection for a now unavailable target can be acknowledged too.

Visits are recorded after the public profile has loaded. The server derives the
visitor from the current session, excludes invisible visitors, and upserts only
the latest visit. The background visit journal is separate from explicit friend
actions and never blocks profile rendering. Logout invalidates all cached list
and receipt objects; local intent files are scoped by API origin and account.

## Database rollout

Apply `db/019_contacts_mysql84.sql` through `python-stand/contacts_migration.py`.
The CLI defaults to a read-only review and needs `--apply` for the additive
migration. Connection settings and the TLS CA are provided outside the repository.
The existing database-scoped runtime SELECT/INSERT/UPDATE account supports both
new tables. For installations using table-specific privileges, grant only those
three operations on `contact_relationships` and `profile_visits` and review the
runtime permission model before enabling these routes.

The importer verifies archived visitor document paths, hashes, UIDs and timestamp
precision, then imports relationships between existing distinct accounts. It
refuses to proceed if either existing canonical or archived friend data is
present, since that requires a separately reviewed projection. Source documents
are never changed. Re-running the import preserves newer native visit dates and
verifies every projected row before committing. Excluded self-visits and missing
account references stay in the archive.

Deploy the new Python modules alongside `runtime_http.py` and
`runtime_mutations.py`, using the existing source-binding/startup procedure.
Database migration alone does not activate the API. Keep the previous deployment
and source-bound environment for rollback; leave the additive tables intact.
Do not publish a client release until actual native session reads and friend
operations have passed against the deployed service.

## Focused verification

`test_runtime_contacts.py` covers request/accept/remove, stale revisions, lost
commit acknowledgements, account isolation, invisible guests, owner-bound
pagination, HTTP validation and source import checks. `timeweb_contacts_test.dart`
covers durable receipt recovery, committed rejection, account invalidation,
320px layouts, tab switching, retry and lazy rows. Its optional
`CLRS_CONTACTS_CAPTURE` define exports screenshots with synthetic accounts.
These checks do not certify live API deployment, physical-device performance or
store publication.
