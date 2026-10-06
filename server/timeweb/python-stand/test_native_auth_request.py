"""New request orchestration only; synthetic TX/envelope, never SMTP/cloud."""
import copy
import uuid
from unittest.mock import patch
import unittest

from native_auth_request import NativeAuthRequest, AuthRequestUnavailable, _LOOKUP
from native_auth_challenges import NativeAuthChallengeStore
from native_auth_receipts import SensitiveAuthReceipts
from native_auth_mail_outbox import NativeAuthMailOutbox
from native_mail_envelope import NativeMailEnvelope
from native_password_credentials import NativePasswordCodec, PasswordWorkPool, AuthChallengeCodec
from native_credentials import CredentialCodec
from native_sessions import NativeSessionStore, SessionTokens
from test_native_auth import CONFIG, CONFIG_REF, WRAPPING, SESSION_KEY
from test_native_auth_completion import Database as CompletionDatabase, Cursor as CompletionCursor
from test_native_auth_mail_outbox import Cursor as OutboxCursor
from test_native_auth_challenges import ENV, NOW, RESET, REGISTER, identifier, _timestamp, CODE
from test_native_pending_account import UID, EMAIL

RAW_EMAIL = ' Pending@Example.Invalid '


class Database(CompletionDatabase):
    def __init__(self):
        super().__init__(); self.state['outbox'] = {}

    def transaction(self, action, *, deadline=None):
        assert not self.in_tx
        self.transactions += 1; self.in_tx = True
        working = copy.deepcopy(self.state); cursor = Cursor(self, working)
        self.cursors.append(cursor)
        try:
            result = action(cursor, cursor.execute)
            self.state = working
            if self.unknown_commit == self.transactions:
                raise OSError('synthetic lost commit acknowledgement')
            return result
        finally:
            self.in_tx = False


class Cursor(CompletionCursor):
    def __init__(self, db, working):
        super().__init__(db, working); self.connection = object()

    def execute(self, sql, params=()):
        if sql == _LOOKUP:
            self.db.calls.append((sql, params)); self.rowcount = 0
            self.result = [(a[0],) for a in self.working['accounts'].values() if a[1] == params[0]][:2]
            return
        if 'clrs_staging.outbox' in sql:
            return OutboxCursor.execute(self, sql, params)
        return super().execute(sql, params)


class RequestTests(unittest.TestCase):
    def setUp(self):
        self.db = Database(); self.clock = 0.0
        codec = CredentialCodec(CONFIG, CONFIG_REF, WRAPPING)
        pool = PasswordWorkPool(codec, NativePasswordCodec(WRAPPING))
        self.addCleanup(pool.close)
        self.store = NativeSessionStore(ENV, codec, SessionTokens(SESSION_KEY), password_selector=pool)
        self.challenges = NativeAuthChallengeStore(ENV, AuthChallengeCodec(SESSION_KEY))
        self.receipts = SensitiveAuthReceipts(bytes([11])*32)
        self.envelopes = NativeMailEnvelope(bytes([12])*32)
        self.outbox = NativeAuthMailOutbox(self.challenges, self.envelopes)
        self.source_calls = []
        self.service = self.make()

    def make(self, *, source='absent', budget=None):
        if source == 'absent':
            def source(c, e, email):
                self.source_calls.append(email)
                return False  # Synthetic callback ONLY, never a current-source proof.
        return NativeAuthRequest(self.store, self.challenges, self.receipts, self.outbox,
            transaction=self.db.transaction, source_account_exists=source,
            issue_budget=budget, monotonic=lambda: self.clock)

    def request(self, purpose=REGISTER, service=None, **changes):
        args = {'email': RAW_EMAIL, 'purpose': purpose, 'operation_id': identifier(101), 'deadline': self.clock+8}
        with patch('native_auth_request.secrets.randbelow', return_value=12345):
            return (service or self.service).request(**(args | changes))

    def active(self, *, disabled=0, lifecycle='active'):
        self.db.state['accounts'][UID] = (UID, EMAIL, disabled, lifecycle, 0, 1, _timestamp(NOW-100))

    def test_signup_atomic_pending_marker_encrypted_queue_no_password_and_original_email_replay(self):
        before = set(self.db.state['accounts'])
        result = self.request()
        self.assertEqual((result.state, result.outcome.status), ('completed', 202))
        challenge_id = result.outcome.challenge_id
        self.assertEqual(uuid.UUID(challenge_id).version, 4)
        created = set(self.db.state['accounts']) - before
        self.assertEqual(len(created), 1)
        uid = next(iter(created)); account = self.db.state['accounts'][uid]
        self.assertEqual(account[1:6], (EMAIL, 1, 'active', 0, 0))
        row = self.db.state['challenges'][(uid, REGISTER)]
        self.assertEqual(row['challenge_id'], challenge_id); self.assertEqual(len(row['marker']), 32)
        self.assertEqual(row['pending_created'], account[6])
        payload = self.db.state['outbox']['auth-mail:'+challenge_id]['payload']
        intent = self.envelopes.open(payload, uid=uid, purpose=REGISTER, delivery_id=challenge_id, now=NOW)
        self.assertEqual((intent.recipient, intent.code, intent.purpose), (EMAIL, CODE, 'verify-email'))
        self.assertNotIn(EMAIL, repr(payload)); self.assertNotIn(CODE, repr(payload))
        self.assertEqual(self.source_calls, [EMAIL])
        for table in ['native', 'identities', 'profiles']:
            self.assertEqual(self.db.state[table], {})
        # Same original request is replayed even if the account is activated,
        # email changes and source callback/budget would now refuse new effects.
        self.db.state['accounts'][uid] = (uid, 'changed@example.invalid', 0, 'active', 7, 1, account[6])
        calls = len(self.db.calls); before = copy.deepcopy(self.db.state)
        replay = self.request(service=self.make(source=None, budget=lambda c,e: False))
        self.assertEqual(replay.outcome.challenge_id, challenge_id)
        self.assertEqual(self.db.state, before)
        self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.db.calls[calls:]))
        self.assertEqual(self.source_calls, [EMAIL])

    def test_reset_unknown_blocked_existing_and_rate_denied_share_same_opaque_accepted_reply(self):
        missing = self.request(RESET, service=self.make(source=None))
        self.assertEqual(self.db.state['outbox'], {})
        self.active()
        issued = self.request(RESET, operation_id=identifier(102), service=self.make(source=None))
        self.assertIn('auth-mail:'+issued.outcome.challenge_id, self.db.state['outbox'])
        denied = self.request(RESET, operation_id=identifier(103))
        self.assertNotIn('auth-mail:'+denied.outcome.challenge_id, self.db.state['outbox'])
        self.assertEqual(self.db.state['challenges'][(UID, RESET)]['history'], [NOW])
        self.active(disabled=1)
        blocked = self.request(RESET, operation_id=identifier(104))
        self.assertNotIn('auth-mail:'+blocked.outcome.challenge_id, self.db.state['outbox'])
        for result in [missing, issued, denied, blocked]:
            self.assertEqual(result.outcome.status, 202)
            self.assertEqual(set(result.outcome.result), {'status', 'challengeId'})
            self.assertEqual(result.outcome.kind, 'accepted')
            self.assertEqual(uuid.UUID(result.outcome.challenge_id).version, 4)
        self.assertEqual(len(self.db.state['outbox']), 1)
        self.assertEqual(self.source_calls, [])

    def test_source_present_native_existing_budget_denial_never_reserve_or_queue(self):
        for kind in ['source', 'native', 'budget']:
            self.setUp()
            if kind == 'native':
                self.active(disabled=1)
            service = self.make(source=(lambda c,e,email: True) if kind == 'source' else
                (lambda *a: (_ for _ in ()).throw(AssertionError('source must not run'))),
                budget=(lambda c,e: False) if kind == 'budget' else None)
            before = copy.deepcopy(self.db.state)
            result = self.request(service=service)
            self.assertEqual(result.outcome.status, 202)
            self.assertEqual(self.db.state['accounts'], before['accounts'])
            self.assertEqual(self.db.state['challenges'], {})
            self.assertEqual(self.db.state['outbox'], {})
            self.assertFalse(any(sql.startswith('INSERT INTO clrs_staging.accounts') for sql, _ in self.db.calls))

    def test_source_and_budget_require_strict_bool_missing_source_failclosed_before_reservation(self):
        for source, budget in [(None, None), (lambda c,e,email: 0, None),
                               (lambda c,e,email: 1, None), (lambda c,e,email: False, lambda c,e: 1)]:
            self.setUp(); before = copy.deepcopy(self.db.state)
            result = self.request(service=self.make(source=source, budget=budget))
            self.assertEqual(result.state, 'unavailable'); self.assertTrue(result.requires_lookup)
            self.assertEqual(self.db.state, before)
            self.assertFalse(any(sql.startswith('INSERT INTO clrs_staging.accounts') for sql, _ in self.db.calls))

    def test_encrypted_queue_or_receipt_readback_failure_rolls_back_entire_new_registration(self):
        for fault in ['payload-readback', 'receipt-readback']:
            self.setUp(); before = copy.deepcopy(self.db.state); self.db.fault = fault
            result = self.request()
            self.assertEqual(result.state, 'unavailable'); self.assertTrue(result.requires_lookup)
            self.assertEqual(self.db.state, before)

    def test_unknown_commit_original_digest_lookup_does_not_reissue_and_raw_changed_context_conflicts(self):
        self.db.unknown_commit = self.db.transactions+1
        result = self.request()
        self.assertEqual(result.state, 'unavailable'); self.assertTrue(result.requires_lookup)
        self.assertEqual(len(self.db.state['outbox']), 1)
        self.db.unknown_commit = None
        before = copy.deepcopy(self.db.state); calls = len(self.db.calls)
        resolved = self.service.lookup(result.fingerprint, deadline=8)
        self.assertEqual(resolved.outcome.status, 202)
        self.assertIn('auth-mail:'+resolved.outcome.challenge_id, self.db.state['outbox'])
        self.assertEqual(self.db.state, before)
        self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.db.calls[calls:]))
        conflict = self.request(email=EMAIL)
        self.assertEqual(conflict.state, 'unavailable'); self.assertTrue(conflict.requires_lookup)
        self.assertEqual(self.db.state, before)
        self.assertEqual(self.source_calls, [EMAIL])

    def test_invalid_bind_bad_deadline_and_budget_timeout_never_create_pending(self):
        for changes in [{'email': 'bad-email'}, {'operation_id': 'bad-uuid'}, {'deadline': 9},
                        {'deadline': 0}, {'email': '\ud800'}, {'email': 'x'*321+'@example.invalid'}]:
            with self.assertRaises(AuthRequestUnavailable):
                self.request(**changes)
        self.assertEqual(self.db.calls, [])
        def budget(c,e):
            self.clock = 8
            return True
        before = copy.deepcopy(self.db.state)
        result = self.request(service=self.make(budget=budget))
        self.assertEqual(result.state, 'unavailable')
        self.assertEqual(self.db.state, before)
        self.assertFalse(any(sql.startswith('INSERT INTO clrs_staging.accounts') for sql, _ in self.db.calls))


if __name__ == '__main__':
    unittest.main()
