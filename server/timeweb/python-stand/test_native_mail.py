import ssl
import threading
import unittest

from native_mail import (NativeMailIntent, NativeMailTransport, MailInvalid,
                         MailUnavailable, MailOutcomeUnknown)


ID = "11111111-1111-4111-8111-111111111111"


def intent(**overrides):
    values = dict(recipient="fixture@example.invalid", purpose="reset-password",
                  code="123456", delivery_id=ID)
    return NativeMailIntent(**{**values, **overrides})


class Smtp:
    def __init__(self, *, auth_error=False, data_error=False, gate=None):
        self.calls = []
        self.auth_error = auth_error
        self.data_error = data_error
        self.gate = gate
        self.started = threading.Event()
        self.closed = threading.Event()

    def login(self, *args):
        self.calls.append("login")
        if self.auth_error:
            raise RuntimeError("private provider response must never be exposed")

    def mail(self, sender):
        self.calls.append(("mail", sender))
        return 250, b"ok"

    def rcpt(self, recipient):
        self.calls.append(("rcpt", recipient))
        return 250, b"ok"

    def data(self, raw):
        self.calls.append(("data", raw))
        self.started.set()
        if self.gate:
            self.gate.wait(1)
        if self.data_error:
            raise TimeoutError()
        return 250, b"ok"

    def close(self):
        self.closed.set()


class NativeMailTests(unittest.TestCase):
    def transport(self, smtp, **options):
        def factory(host, port, *, context, timeout):
            self.assertEqual((host, port), ("smtp.yandex.ru", 465))
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(context.check_hostname)
            self.assertGreater(timeout, 0)
            return smtp
        return NativeMailTransport("synthetic-only-password", smtp_factory=factory, **options)

    def test_disabled_fixed_provider_and_private_configuration(self):
        self.assertIsNone(NativeMailTransport.from_env({}))
        for env in ({"CLRS_MAIL_HOST": "foreign.invalid"}, {"CLRS_MAIL_PORT": "25"},
                    {"CLRS_MAIL_USER": "another@example.invalid"}, {"CLRS_MAIL_PASSWORD": "bad\nsecret"}):
            with self.subTest(env=env), self.assertRaises(MailUnavailable):
                NativeMailTransport.from_env({"CLRS_MAIL_ENABLED": "1", **env})

    def test_templates_are_fixed_and_header_injection_never_starts_smtp(self):
        smtp = Smtp()
        transport = self.transport(smtp)
        for changes in ({"recipient": "x@example.invalid\r\nBcc:y@example.invalid"},
                        {"purpose": "arbitrary-message"}, {"purpose": []}, {"code": "foreign URL"},
                        {"delivery_id": "123"}):
            with self.subTest(changes=changes), self.assertRaises(MailInvalid):
                transport.deliver(intent(**changes))
        self.assertEqual(smtp.calls, [])
        self.assertNotIn("123456", repr(intent()))

    def test_verified_tls_single_delivery_fixed_sender_and_message_id(self):
        smtp = Smtp()
        transport = self.transport(smtp)
        result = transport.deliver(intent())
        self.assertEqual(result, {"deliveryId": ID, "smtpAccepted": True})
        self.assertEqual(sum(call == "login" for call in smtp.calls), 1)
        raw = [call[1] for call in smtp.calls if isinstance(call, tuple) and call[0] == "data"][0]
        self.assertIn(f"<clrs.{ID}@yandex.ru>".encode(), raw)
        self.assertNotIn(b"\n", raw.replace(b"\r\n", b""))
        self.assertNotIn(b"synthetic-only-password", raw)
        self.assertTrue(smtp.closed.is_set())

    def test_failed_auth_has_no_data_and_no_automatic_retry(self):
        smtp = Smtp(auth_error=True)
        with self.assertRaises(MailUnavailable) as error:
            self.transport(smtp).deliver(intent())
        self.assertIs(type(error.exception), MailUnavailable)
        self.assertEqual(smtp.calls, ["login"])

    def test_lost_data_ack_is_unknown_and_never_retried(self):
        smtp = Smtp(data_error=True)
        with self.assertRaises(MailOutcomeUnknown):
            self.transport(smtp).deliver(intent())
        self.assertEqual(sum(isinstance(c, tuple) and c[0] == "data" for c in smtp.calls), 1)

    def test_late_cleanup_cannot_adopt_success_after_deadline(self):
        now = [0]
        class LateCleanup(Smtp):
            def close(self):
                now[0] = 9
                super().close()
        smtp = LateCleanup()
        with self.assertRaises(MailOutcomeUnknown):
            self.transport(smtp, clock=lambda: now[0]).deliver(intent())
        self.assertTrue(smtp.closed.is_set())
        self.assertEqual(sum(isinstance(c, tuple) and c[0] == "data" for c in smtp.calls), 1)

    def test_timed_out_worker_keeps_slot_and_shutdown_rejects_new_calls(self):
        gate = threading.Event()
        smtp = Smtp(gate=gate)
        transport = self.transport(smtp, deadline_seconds=.15)
        with self.assertRaises(MailOutcomeUnknown):
            transport.deliver(intent())
        self.assertTrue(smtp.started.is_set())
        with self.assertRaises(MailUnavailable):
            transport.deliver(intent())
        transport.close()
        gate.set()
        self.assertTrue(smtp.closed.wait(1))
        with self.assertRaises(MailUnavailable):
            transport.deliver(intent())


if __name__ == "__main__":
    unittest.main()
