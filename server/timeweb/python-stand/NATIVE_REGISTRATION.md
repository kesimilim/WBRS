# Native registration without an email code

The original CLRS form sends nickname, email and password. The server creates a
new random UID, an unverified active account, native password identity and a
fresh profile containing only `full_name`. The remaining profile fields stay
empty and onboarding remains incomplete. Registration never issues a session;
the user explicitly signs in with the new credentials before filling the profile.

`POST /v1/auth/register` accepts exactly `operationId,email,password,nickname`.
It returns `status:completed` (200) or `status:refused` (400), with a sealed
`operationToken`. Any existing normalized email, including a blocked, deleted or
unfinished old registration, is refused without activation or data changes.
The request cannot supply a UID, profile, phone or a source account.

`POST /v1/auth/register/lookup` accepts an `operationToken`, or the exact original
request as `purpose:register.v1,stage:complete,original:{...}` if the entire reply
was lost. This route reads only the original keyed receipt. Unknown, absent and
pending receipts remain unknown; they never authorize another registration write.
The client freezes the original fields and offers explicit lookup after uncertainty.
Passwords retain their original spaces and never enter a receipt, log or local
preferences. Signup stores only keyed digests plus fixed non-secret outcomes.

Signup requires `CLRS_NATIVE_REGISTRATION_ENABLED=1`, native auth/writes/password
enabled, the existing `provider-database-v1` permission model, and the unchanged
`CLRS_NATIVE_REGISTRATION_SOURCE_AUTHORITY=final-auth-import-and-write-barrier-v1`
gate. The operator must have the corresponding real final source authority.
Enabling signup does not prove that authority. Preview/final acceptance remains
enforced by `app.py`. SMTP, email challenges and recovery lifecycle can stay off.
Flutter enables this form with the existing `CLRS_TIMEWEB_REGISTRATION_ENABLED`
flag independently of `CLRS_TIMEWEB_AUTH_LIFECYCLE_ENABLED`.

Apply reviewed migration `031_native_registration_receipt_mysql84.sql` before
enabling signup. It changes only the two receipt CHECK constraints, adding
`register.complete.v1`; it has no new tables, columns or grants. Verify the
original constraint names with the existing schema before running it. The runtime
uses existing SELECT/INSERT/UPDATE privileges without expanding them.

Limits use trusted socket peers (10/minute), canonical emails (5/minute) and a
durable SERIALIZABLE receipt range (20/minute, 100/hour). Password derivation uses
the existing bounded shared pool outside SQL. Account, identity, profile,
credential and completed receipt commit together, with exact readback checks.
Lost COMMIT acknowledgements require read-only lookup and never automatic retry.

Local validation: `test_native_registration`, `test_native_auth_receipts` and
`test_native_auth_lifecycle_http.LifecycleFactoryTests` pass 23 generated tests.
They cover a real bounded password derivation, unverified login eligibility,
clean profile/account separation, existing/disabled-email refusal, rollback,
lost acknowledgement/replay, original-body conflicts, budgets, factory gates and
the guarded HTTP mount. Flutter registration/lifecycle tests cover the three
fields, original payload, no code, no session adoption, old-cache independence,
late account change and lookup without another write. No real account, API call,
SMTP send or live migration is part of these checks.
