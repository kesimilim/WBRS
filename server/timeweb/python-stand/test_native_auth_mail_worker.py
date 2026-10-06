"""One-shot orchestration only; synthetic SQL and transport, no real I/O."""
import copy
import threading
import unittest

from native_auth_mail_worker import NativeAuthMailWorker, AuthMailWorkerUnavailable
from native_auth_mail_outbox import NativeAuthMailOutbox, STARTED
from native_auth_challenges import NativeAuthChallengeStore
from native_credentials import CredentialCodec
from native_mail import NativeMailTransport, NativeMailIntent, MailUnavailable, MailOutcomeUnknown
from native_mail_envelope import NativeMailEnvelope
from native_password_credentials import AuthChallengeCodec
from native_sessions import NativeSessionStore, SessionTokens
from test_native_auth import CONFIG, CONFIG_REF, WRAPPING, SESSION_KEY
from test_native_auth_mail_outbox import Database as BaseDatabase, Cursor
from test_native_auth_challenges import ENV, UID, EMAIL, CODE, NOW, RESET, identifier


class Database(BaseDatabase):
    def __init__(self):
        super().__init__()
        self.transactions = 0; self.in_tx = False; self.unknown = None; self.fail = None
        self.connections = []; self.same_connection = False; self.after_commit = None
        self.deadlines = []

    def transaction(self, action, *, deadline=None):
        with self.mutex:
            assert not self.in_tx
            self.transactions += 1; number = self.transactions; self.deadlines.append(deadline)
            working = copy.deepcopy(self.state); cursor = Cursor(self, working)
            if self.same_connection and self.connections:
                cursor.connection = self.connections[0]
            self.connections.append(cursor.connection); self.in_tx = True
            try:
                result = action(cursor, cursor.execute)
                if self.fail == number:
                    raise OSError('synthetic transaction failed before commit')
                self.state = working
                if self.after_commit:
                    self.after_commit(number)
                if self.unknown == number:
                    raise OSError('synthetic commit acknowledgement unknown')
                return result
            finally:
                self.in_tx = False


class Transport(NativeMailTransport):
    def __init__(self, db, clock):
        super().__init__('synthetic-only-password', clock=clock)
        self.db = db; self.calls = []; self.outcome = 'accepted'; self.gate = None
        self.entered = threading.Event(); self.before_result = None

    def deliver(self, intent, *, deadline=None):
        assert not self.db.in_tx, 'SQL transaction must be released before SMTP'
        assert self._clock() < deadline <= self._clock() + 8
        self.calls.append((intent, deadline)); self.entered.set()
        if self.gate is not None:
            assert self.gate.wait(1)
        if self.before_result:
            self.before_result()
        if self.outcome == 'failed':
            raise MailUnavailable()
        if self.outcome == 'unknown':
            raise MailOutcomeUnknown()
        return {'deliveryId': intent.delivery_id, 'smtpAccepted': True}


class AuthMailWorkerTests(unittest.TestCase):
    def setUp(self):
        self.db = Database(); self.clock = [100.0]
        self.env = ENV | {'CLRS_MAIL_ENABLED': '1', 'CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED': '1'}
        # This store is only the runner type here; injected synthetic TX is used.
        self.store = NativeSessionStore({k: v for k, v in ENV.items() if k != 'CLRS_NATIVE_PASSWORD_ENABLED'},
            CredentialCodec(CONFIG, CONFIG_REF, WRAPPING), SessionTokens(SESSION_KEY))
        self.challenges = NativeAuthChallengeStore(ENV, AuthChallengeCodec(b'c' * 32))
        self.outbox = NativeAuthMailOutbox(self.challenges, NativeMailEnvelope(b'e' * 32),
                                         monotonic=lambda: self.clock[0])
        issued = self.db.transaction(lambda c, e: self.challenges.issue(c, e,
            uid=UID, email=EMAIL, purpose=RESET, code=CODE, challenge_id=identifier(1))).challenge
        self.intent = NativeMailIntent(EMAIL, 'reset-password', CODE, identifier(1))
        self.db.transaction(lambda c, e: self.outbox.enqueue(c, e, issued=issued, intent=self.intent))
        self.db.transactions = 0; self.db.connections = []; self.db.deadlines = []
        self.transport = Transport(self.db, lambda: self.clock[0]); self.addCleanup(self.transport.close)
        self.worker = self.make_worker()

    def make_worker(self, env=None):
        return NativeAuthMailWorker(self.env if env is None else env, self.store, self.outbox,
            self.transport, transaction=self.db.transaction, monotonic=lambda: self.clock[0])

    def run_once(self, **changes):
        return self.worker.run_once(**(dict(uid=UID, purpose=RESET, challenge_id=identifier(1)) | changes))

    def row(self):
        return self.db.state['outbox']['auth-mail:' + identifier(1)]

    def test_default_off_and_trusted_scope_fail_before_sql_or_transport(self):
        self.assertIsNone(NativeAuthMailWorker.from_env({}))
        self.assertIsNone(NativeAuthMailWorker.from_env({'CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED': '0'}))
        for flag in ['yes', []]:
            with self.assertRaises(AuthMailWorkerUnavailable):
                NativeAuthMailWorker.from_env({'CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED': flag})
        with self.assertRaises(AuthMailWorkerUnavailable):
            self.make_worker(self.env | {'CLRS_MAIL_ENABLED': '0'}).run_once(
                uid=UID, purpose=RESET, challenge_id=identifier(1))
        for changes in [dict(purpose=[]), dict(purpose='arbitrary-template'), dict(challenge_id='bad'),
                        dict(deadline=100), dict(deadline=133), dict(deadline=True)]:
            with self.assertRaises(AuthMailWorkerUnavailable):
                self.run_once(**changes)
        self.assertEqual(self.db.transactions, 0); self.assertEqual(self.transport.calls, [])
        self.assertEqual(self.run_once(uid='not-this-account').state, 'unknown')
        self.assertEqual(self.row()['attempts'], 0)

    def test_acknowledged_fresh_transactions_release_before_exact_single_send_and_finish(self):
        result = self.run_once(deadline=106.5)
        self.assertEqual((result.state, result.phase, result.smtp_attempted, result.requires_reconcile),
                         ('accepted', 'finish', True, False))
        self.assertEqual(len(self.transport.calls), 1)
        self.assertEqual(self.transport.calls[0], (self.intent, 106.5))
        self.assertEqual(self.db.transactions, 3)
        self.assertEqual(len({id(c) for c in self.db.connections}), 3)
        self.assertEqual(self.db.deadlines, [106.5, 106.5, 106.5])
        self.assertEqual(self.transport._seconds, 8)
        self.assertEqual(self.row()['attempts'], 1); self.assertIsNotNone(self.row()['delivered'])
        self.assertIsNone(self.row()['error'])
        self.assertEqual(self.run_once().state, 'declined'); self.assertEqual(len(self.transport.calls), 1)
        self.assertNotIn(EMAIL, repr(result)); self.assertNotIn(CODE, repr(result))

    def test_claim_or_verification_commit_unknown_never_sends_or_reopens_started_row(self):
        for phase, name in [(1, 'claim'), (2, 'verify')]:
            with self.subTest(phase=phase):
                self.setUp(); self.db.unknown = phase
                result = self.run_once()
                self.assertEqual((result.state, result.phase, result.smtp_attempted, result.requires_reconcile),
                                 ('unknown', name, False, True))
                self.assertEqual(self.transport.calls, [])
                self.assertEqual((self.row()['attempts'], self.row()['error']), (1, STARTED))
                self.db.unknown = None
                self.assertEqual(self.run_once().state, 'declined')
                self.assertEqual(self.transport.calls, [])

    def test_same_actual_connection_or_expiry_between_commits_refuses_delivery(self):
        self.db.same_connection = True
        result = self.run_once()
        self.assertEqual((result.state, result.phase), ('unknown', 'verify'))
        self.assertEqual(self.transport.calls, [])
        self.setUp()
        self.db.after_commit = lambda n: setattr(self.db, 'now', NOW + 593) if n == 1 else None
        result = self.run_once()
        self.assertEqual(result.state, 'failed'); self.assertFalse(result.smtp_attempted)
        self.assertEqual(self.row()['error'], 'auth.mail.failed')
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(self.db.state['challenges'][(UID, RESET)]['attempts'], 0)

    def test_smtp_failure_unknown_or_unknown_finish_are_parked_and_never_resent(self):
        for outcome in ['failed', 'unknown', 'accepted']:
            with self.subTest(outcome=outcome):
                self.setUp(); self.transport.outcome = outcome
                if outcome == 'accepted':
                    self.db.unknown = 3
                result = self.run_once()
                self.assertEqual(result.state, 'unknown' if outcome == 'accepted' else outcome)
                self.assertTrue(result.smtp_attempted)
                self.assertEqual(result.requires_reconcile, outcome in ('accepted', 'unknown'))
                self.assertEqual(self.row()['attempts'], 1)
                self.assertEqual(self.row()['error'], None if outcome == 'accepted' else 'auth.mail.' + outcome)
                self.db.unknown = None
                self.assertEqual(self.run_once().state, 'declined')
                self.assertEqual(len(self.transport.calls), 1)

    def test_failed_parking_transaction_or_elapsed_budget_leaves_ineligible_claim_without_resend(self):
        self.transport.outcome = 'unknown'; self.db.fail = 3
        result = self.run_once()
        self.assertEqual((result.state, result.phase, result.requires_reconcile), ('unknown', 'finish', True))
        self.assertEqual((self.row()['attempts'], self.row()['error']), (1, STARTED))
        self.db.fail = None; self.assertEqual(self.run_once().state, 'declined')
        self.assertEqual(len(self.transport.calls), 1)
        self.setUp()
        self.db.after_commit = lambda n: self.clock.__setitem__(0, 106) if n == 2 else None
        result = self.run_once(deadline=106)
        self.assertEqual((result.state, result.phase), ('unknown', 'verify'))
        self.assertEqual(self.transport.calls, []); self.assertEqual(self.row()['attempts'], 1)

    def test_one_worker_and_existing_actual_transport_slot_bound_before_claim(self):
        with self.transport._lock:
            self.transport._active = object()
        self.assertEqual(self.run_once().state, 'busy'); self.assertEqual(self.db.transactions, 0)
        with self.transport._lock:
            self.transport._active = None
        self.transport.gate = threading.Event(); results = []
        thread = threading.Thread(target=lambda: results.append(self.run_once()))
        thread.start(); self.assertTrue(self.transport.entered.wait(1))
        transactions = self.db.transactions
        self.assertEqual(self.run_once().state, 'busy')
        self.assertEqual(self.db.transactions, transactions)
        self.transport.gate.set(); thread.join(1); self.assertFalse(thread.is_alive())
        self.assertEqual(results[0].state, 'accepted'); self.assertEqual(len(self.transport.calls), 1)

    def test_dispatcher_cancellation_during_claim_or_verify_never_reaches_smtp(self):
        for phase in [1, 2]:
            with self.subTest(phase=phase):
                self.setUp(); cancel = threading.Event()
                self.db.after_commit = lambda n: cancel.set() if n == phase else None
                result = self.run_once(cancel_event=cancel)
                self.assertEqual(result.state, 'unknown'); self.assertTrue(result.requires_reconcile)
                self.assertEqual(self.transport.calls, [])
                self.assertEqual(self.row()['attempts'], 1)
                with self.assertRaises(AuthMailWorkerUnavailable):
                    self.run_once(cancel_event=cancel)


if __name__ == '__main__':
    unittest.main()
