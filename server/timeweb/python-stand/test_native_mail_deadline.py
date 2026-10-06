"""Only the new absolute deadline slice, no older transport-suite repeat."""
import threading
import time
import unittest
from unittest.mock import patch

from native_mail import NativeMailTransport, MailInvalid, MailUnavailable, MailOutcomeUnknown
from test_native_mail import Smtp, intent


class NativeMailDeadlineTests(unittest.TestCase):
    def test_absolute_slice_bounds_connection_and_stops_before_mail_without_mutating_shared_cap(self):
        now = [100.0]; timeouts = []
        class LoginConsumesSlice(Smtp):
            def login(self, *args):
                super().login(*args); now[0] += .6
        smtp = LoginConsumesSlice()
        def factory(host, port, *, context, timeout):
            timeouts.append(timeout); return smtp
        transport = NativeMailTransport('synthetic', smtp_factory=factory, clock=lambda: now[0])
        with self.assertRaises(MailUnavailable):
            transport.deliver(intent(), deadline=100.5)
        self.assertEqual(timeouts, [.5]); self.assertEqual(smtp.calls, ['login'])
        self.assertTrue(smtp.closed.wait(1)); self.assertEqual(transport._seconds, 8)

    def test_invalid_absolute_deadline_and_tls_setup_exhaustion_never_connect(self):
        now = [100.0]; factories = []
        def factory(*args, **kw):
            factories.append(kw); return Smtp()
        transport = NativeMailTransport('synthetic', smtp_factory=factory, clock=lambda: now[0])
        for deadline in [100.0, 99.0, float('nan'), float('inf'), True, '101']:
            with self.subTest(deadline=deadline), self.assertRaises(MailInvalid):
                transport.deliver(intent(), deadline=deadline)
        def context():
            now[0] = 100.6
            return object()
        with patch('native_mail.ssl.create_default_context', side_effect=context):
            with self.assertRaises(MailUnavailable):
                transport.deliver(intent(), deadline=100.5)
        self.assertEqual(factories, [])

    def test_absolute_timeout_keeps_actual_data_worker_slot_until_cleanup(self):
        gate = threading.Event(); smtp = Smtp(gate=gate)
        transport = NativeMailTransport('synthetic', smtp_factory=lambda *a, **kw: smtp)
        self.addCleanup(gate.set); self.addCleanup(transport.close)
        with self.assertRaises(MailOutcomeUnknown):
            transport.deliver(intent(), deadline=time.monotonic() + .15)
        self.assertTrue(smtp.started.is_set())
        with self.assertRaises(MailUnavailable):
            transport.deliver(intent(), deadline=time.monotonic() + .15)
        self.assertEqual(sum(isinstance(c, tuple) and c[0] == 'data' for c in smtp.calls), 1)
        gate.set(); self.assertTrue(smtp.closed.wait(1)); self.assertEqual(transport._seconds, 8)


if __name__ == '__main__':
    unittest.main()
