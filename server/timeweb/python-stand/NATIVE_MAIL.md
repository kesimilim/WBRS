# Existing CLRS mailbox transport

The sender is the existing `supp.lrs@yandex.ru` mailbox, using verified TLS on
`smtp.yandex.ru:465`. The mailbox owner must allow mail clients and create a
**Mail application password** in Yandex ID. The ordinary mailbox password is
not a substitute. [Official Yandex setup](https://www.yandex.ru/support/yandex-360/customers/mail/ru/mail-clients/others).

`NativeMailTransport.from_env` remains disabled unless `CLRS_MAIL_ENABLED=1`.
`CLRS_MAIL_PASSWORD` must be provided only through the server secret settings;
no password belongs in Git, an APK, an example configuration or a report.
The host, port and sender cannot be changed to a client-provided destination.

Only two fixed Russian templates exist: email verification and password reset,
with a six-digit code and a ten-minute lifetime. This file implements the
transport, **not live verified reset/registration delivery**. The separately
gated lifecycle API now exists; before enabling its routes,
the server must persist an account/purpose-bound single-use challenge, an
expiry, a bounded attempt counter, rate limits and the durable delivery intent.
It must revoke applicable sessions when a password changes. Arbitrary users
must never invoke this transport or choose an arbitrary message body.

There is one active delivery at a time and an eight-second caller deadline.
A timed-out worker retains its slot until actual I/O closes. Once SMTP DATA
starts, loss of its acknowledgement is an unknown outcome; the transport
never retries it. A stable Message-ID does not guarantee SMTP deduplication.
The caller must retain that state in its outbox rather than silently resend.
`smtpAccepted` means that the SMTP server accepted DATA, not that the recipient
received or read the email. Seven synthetic focused tests passed; none sent mail.

On 2026-10-01 one real TLS SMTP authentication probe reached Yandex and was
rejected with status 535. No email was sent. A working application password,
deployed lifecycle routes and controlled recipient delivery remain unproved.
Do not enable mail or declare password recovery migrated on this evidence.

The gated lifecycle factory additionally requires `CLRS_MAIL_AUTH_VERIFIED=1`
after a new successful real authentication/delivery proof, and
`CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED=1`. It shares one bounded SMTP transport
with its background dispatcher; HTTP only wakes the queue. Auth-mail payloads
are encrypted and bound to the original UID/purpose/code. Acknowledged SQL claim
and fresh different-connection verification precede one SMTP attempt. Unknown
delivery/COMMIT is never retried automatically; dispatch stops for explicit
read-only reconciliation. Shutdown aborts transport before stopping dispatch.
These source paths are default-off and do not constitute actual delivery proof.
