"""Auth mail lifecycle only; synthetic TX/connection identities, no SMTP/network."""
import copy
import json
import threading
import unittest

from native_auth_challenges import NativeAuthChallengeStore, IssuedChallenge
from native_auth_mail_outbox import (NativeAuthMailOutbox, AuthMailUnavailable,
    AuthMailClaim, EVENT_KIND, STARTED, _QUERY, _CONTEXT_QUERY)
from native_mail import NativeMailIntent
from native_mail_envelope import NativeMailEnvelope
from native_password_credentials import AuthChallengeCodec
from test_native_auth_challenges import (FakeDatabase, FakeCursor, ENV, UID, EMAIL,
    CODE, NOW, RESET, REGISTER, identifier, _timestamp)


class Database(FakeDatabase):
    def __init__(self):
        super().__init__(); self.state['outbox'] = {}; self.fault = None
        self.mutex = threading.RLock()

    def transaction(self, action):
        with self.mutex:
            working = copy.deepcopy(self.state); cursor = Cursor(self, working)
            execute = cursor.execute  # One captured callable for this transaction.
            result = action(cursor, execute)
            self.state = working
            return result


class Cursor(FakeCursor):
    def __init__(self, database, working):
        super().__init__(database, working)
        self.connection = object()  # Every outer TX models a different actual connection.

    def execute(self, sql, params=()):
        if not (sql in (_QUERY, _CONTEXT_QUERY) or sql.startswith(('INSERT INTO clrs_staging.outbox',
                                                'UPDATE clrs_staging.outbox'))):
            return super().execute(sql, params)
        self.db.calls.append((sql, params)); self.result = None; self.rowcount = 0
        rows = self.working['outbox']
        if sql in (_QUERY, _CONTEXT_QUERY):
            row = rows.get(params[0])
            if row is not None:
                payload = copy.deepcopy(row['payload'])
                if self.db.fault == 'payload-readback' and self.wrote:
                    payload['unexpected'] = 'synthetic-corruption'
                self.result = (row['id'], row['source'], row['uid'], 'email', EVENT_KIND,
                    json.dumps(payload), row['available'], row['attempts'], row['delivered'],
                    row['error'], row['created'])
        elif sql.startswith('INSERT INTO clrs_staging.outbox'):
            row_id, source, uid, event_kind, payload, available = params
            assert row_id not in rows and event_kind == EVENT_KIND
            rows[row_id] = {'id': row_id, 'source': source, 'uid': uid, 'payload': json.loads(payload),
                'available': available, 'attempts': 0, 'delivered': None, 'error': None,
                'created': _timestamp(self.db.now)}
            self.rowcount = 1; self.wrote = True
        elif sql.startswith('UPDATE clrs_staging.outbox SET attempts = 1'):
            error, row_id = params; row = rows.get(row_id)
            if row and row['attempts'] == 0 and row['delivered'] is None and row['error'] is None:
                row.update(attempts=1, error=error); self.rowcount = 1; self.wrote = True
        elif sql.startswith('UPDATE clrs_staging.outbox SET delivered_at ='):
            outcome, error, row_id, previous = params; row = rows.get(row_id)
            if row and row['attempts'] == 1 and row['delivered'] is None and row['error'] == previous:
                row.update(delivered=_timestamp(self.db.now) if outcome == 'accepted' else None, error=error)
                self.rowcount = 1; self.wrote = True
        else:
            raise AssertionError('unexpected SQL')


class AuthMailOutboxTests(unittest.TestCase):
    def setUp(self):
        self.db = Database(); self.clock = [100.0]
        self.challenges = NativeAuthChallengeStore(ENV, AuthChallengeCodec(b'c' * 32))
        self.envelopes = NativeMailEnvelope(b'e' * 32)
        self.outbox = NativeAuthMailOutbox(self.challenges, self.envelopes,
                                         monotonic=lambda: self.clock[0])
        self.issued = self.db.transaction(lambda c, e: self.challenges.issue(c, e,
            uid=UID, email=EMAIL, purpose=RESET, code=CODE, challenge_id=identifier(1))).challenge
        self.intent = NativeMailIntent(EMAIL, 'reset-password', CODE, identifier(1))

    def enqueue(self, *, issued=None, intent=None):
        return self.db.transaction(lambda c, e: self.outbox.enqueue(c, e,
            issued=issued or self.issued, intent=intent or self.intent))

    def start(self, *, purpose=RESET):
        return self.db.transaction(lambda c, e: self.outbox.start_delivery(c, e,
            uid=UID, purpose=purpose, challenge_id=identifier(1)))

    def verify(self, claim, *, state='acknowledged'):
        return self.db.transaction(lambda c, e: self.outbox.verify_committed_claim(c, e, claim,
                                                                                commit_state=state))

    def finish(self, claim, outcome):
        return self.db.transaction(lambda c, e: self.outbox.finish_delivery(c, e, claim, outcome=outcome))

    def test_enqueue_exact_encrypted_once_and_wrong_email_code_rollback_no_plain_sql(self):
        self.assertEqual(self.enqueue().state, 'queued')
        payload = copy.deepcopy(self.db.state['outbox']['auth-mail:' + identifier(1)]['payload'])
        self.assertEqual(self.enqueue().state, 'already_queued')
        self.assertEqual(len(self.db.state['outbox']), 1)
        self.assertEqual(self.db.state['outbox']['auth-mail:' + identifier(1)]['payload'], payload)
        parameters = repr([params for _, params in self.db.calls])
        self.assertNotIn(EMAIL, parameters); self.assertNotIn(CODE, parameters)
        for intent in [NativeMailIntent('other@example.invalid', 'reset-password', CODE, identifier(1)),
                       NativeMailIntent(EMAIL, 'reset-password', '654321', identifier(1))]:
            before = copy.deepcopy(self.db.state)
            with self.assertRaises(AuthMailUnavailable):
                self.enqueue(intent=intent)
            self.assertEqual(self.db.state, before)

    def test_start_has_no_intent_and_requires_fresh_different_connection_ack_and_remaining_budget(self):
        self.enqueue()
        captured = []
        def start(c, e):
            captured.extend([c, e])
            return self.outbox.start_delivery(c, e, uid=UID, purpose=RESET, challenge_id=identifier(1))
        claim = self.db.transaction(start).claim
        self.assertIsNotNone(claim)
        self.assertFalse(hasattr(claim, 'intent'))
        before = len(self.db.calls)
        with self.assertRaises(AuthMailUnavailable):
            self.outbox.verify_committed_claim(captured[0], captured[1], claim, commit_state='acknowledged')
        self.assertEqual(len(self.db.calls), before)
        self.assertIsNone(self.start().claim)
        # Separate independent valid claim/database to exercise the allowed fresh proof.
        self.setUp(); self.enqueue(); claim = self.start().claim
        delivery = self.verify(claim)
        self.assertEqual(delivery.intent, self.intent)
        self.assertEqual(delivery.remaining_seconds(), 8)
        self.assertNotIn(CODE, repr(delivery)); self.assertNotIn(EMAIL, repr(delivery))
        self.clock[0] += 7.5
        self.assertEqual(delivery.remaining_seconds(), .5)
        self.clock[0] += .5
        with self.assertRaises(AuthMailUnavailable):
            delivery.remaining_seconds()
        with self.assertRaises(AuthMailUnavailable):
            self.verify(claim)

    def test_concurrent_claim_only_once_and_unknown_commit_never_exposes_or_retries(self):
        self.enqueue(); results = []
        threads = [threading.Thread(target=lambda: results.append(self.start())) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=1); self.assertFalse(thread.is_alive())
        self.assertEqual(sorted(r.state for r in results), ['declined', 'started'])
        claim = next(r.claim for r in results if r.claim is not None)
        before = len(self.db.calls)
        self.assertIsNone(self.verify(claim, state='unknown'))
        self.assertEqual(len(self.db.calls), before)
        with self.assertRaises(AuthMailUnavailable):
            self.verify(claim)
        self.assertEqual(self.start().state, 'declined')
        self.assertEqual(self.finish(claim, 'unknown').state, 'unknown')
        row = self.db.state['outbox']['auth-mail:' + identifier(1)]
        self.assertEqual((row['attempts'], row['error'], row['delivered']), (1, 'auth.mail.unknown', None))
        self.assertEqual(self.start().state, 'declined')

    def test_replacement_version_email_block_consumption_expiry_never_charge_code_attempts(self):
        self.enqueue(); original = copy.deepcopy(self.db.state)
        for field, value in [('challenge', identifier(2)), ('consumed', NOW), ('attempts', 5),
                             ('account-version', 1), ('account-disabled', 1),
                             ('account-lifecycle', 'blocked'), ('account-email', 'changed@example.invalid')]:
            self.db.state = copy.deepcopy(original)
            record = self.db.state['challenges'][(UID, RESET)]
            if field in ('challenge', 'consumed', 'attempts'):
                record[{'challenge': 'challenge_id'}.get(field, field)] = value
            else:
                index = {'account-version': 4, 'account-disabled': 2,
                         'account-lifecycle': 3, 'account-email': 1}[field]
                account = list(self.db.state['accounts'][UID]); account[index] = value
                self.db.state['accounts'][UID] = tuple(account)
            expected_attempts = record['attempts']
            self.assertEqual(self.start().state, 'declined')
            self.assertEqual(self.db.state['challenges'][(UID, RESET)]['attempts'], expected_attempts)
            retired = self.db.state['outbox']['auth-mail:' + identifier(1)]
            self.assertEqual((retired['attempts'], retired['error']), (1, 'auth.mail.failed'))
        self.db.state = original
        for now in [NOW + 592, NOW + 600]:
            self.db.now = now
            self.assertEqual(self.start().state, 'declined')
        self.assertEqual(self.db.state['challenges'][(UID, RESET)]['attempts'], 0)

    def test_tamper_and_transaction_readback_failure_abort_without_claim_or_new_attempts(self):
        self.db.fault = 'payload-readback'; before = copy.deepcopy(self.db.state)
        with self.assertRaises(AuthMailUnavailable):
            self.enqueue()
        self.assertEqual(self.db.state, before)
        self.db.fault = None; self.enqueue(); original = copy.deepcopy(self.db.state)
        for field, value in [('ciphertext', 'A' * 100), ('uid', 'other-user'), ('expiresAt', NOW + 601)]:
            self.db.state = copy.deepcopy(original)
            self.db.state['outbox']['auth-mail:' + identifier(1)]['payload'][field] = value
            with self.assertRaises(AuthMailUnavailable):
                self.start()
            self.assertEqual(self.db.state['outbox']['auth-mail:' + identifier(1)]['attempts'], 0)
        self.db.state = original; self.db.fault = 'payload-readback'
        with self.assertRaises(AuthMailUnavailable):
            self.start()
        self.assertEqual(self.db.state, original)

    def test_fresh_verification_rechecks_hmac_payload_currentness_and_foreign_claim(self):
        self.enqueue(); claim = self.start().claim
        other = NativeAuthMailOutbox(self.challenges, self.envelopes)
        before = len(self.db.calls)
        for foreign in [AuthMailClaim(), claim]:
            with self.assertRaises(AuthMailUnavailable):
                self.db.transaction(lambda c, e: other.verify_committed_claim(c, e, foreign,
                                                                            commit_state='acknowledged'))
        self.assertEqual(len(self.db.calls), before)
        self.db.state['challenges'][(UID, RESET)]['code_hmac'] = bytes(32)
        with self.assertRaises(AuthMailUnavailable):
            self.verify(claim)
        self.assertEqual(self.db.state['challenges'][(UID, RESET)]['attempts'], 0)
        self.assertEqual(self.db.state['outbox']['auth-mail:' + identifier(1)]['error'], STARTED)

    def test_finish_accepted_failed_unknown_park_once_and_cannot_unclaim_or_send_after_replacement(self):
        for outcome in ['accepted', 'failed', 'unknown']:
            self.setUp(); self.enqueue(); claim = self.start().claim
            if outcome == 'accepted':
                with self.assertRaises(AuthMailUnavailable):
                    self.finish(claim, outcome)
            self.verify(claim)
            # Source can change after SMTP began; audit completion still binds the old outbox.
            self.db.state['challenges'][(UID, RESET)]['challenge_id'] = identifier(2)
            self.assertEqual(self.finish(claim, outcome).state, outcome)
            row = self.db.state['outbox']['auth-mail:' + identifier(1)]
            self.assertEqual(row['attempts'], 1)
            self.assertEqual(row['delivered'] is not None, outcome == 'accepted')
            self.assertEqual(row['error'], None if outcome == 'accepted' else 'auth.mail.' + outcome)
            with self.assertRaises(AuthMailUnavailable):
                self.finish(claim, outcome)
            self.assertEqual(self.start().state, 'declined')

    def test_signup_requires_exact_pending_marker_created_flags_and_empty_four_children(self):
        account = (UID, EMAIL, 1, 'active', 0, 0, _timestamp(NOW - 100))
        self.db.state['accounts'][UID] = account
        record = {'uid': UID, 'purpose': REGISTER, 'challenge_id': identifier(1),
            'email_identity': self.challenges.codec.email_identity(EMAIL),
            'code_hmac': self.challenges.codec.digest(uid=UID, email=EMAIL, purpose=REGISTER,
                challenge_id=identifier(1), account_token_version=0, issued_at=NOW, expires_at=NOW + 600, code=CODE),
            'version': 0, 'history': [NOW], 'issued': NOW, 'expires': NOW + 600,
            'attempts': 0, 'consumed': None, 'marker': b'm' * 32, 'pending_created': account[6]}
        self.db.state['challenges'][(UID, REGISTER)] = record
        issued = IssuedChallenge(UID, REGISTER, identifier(1), 0, NOW, NOW + 600)
        intent = NativeMailIntent(EMAIL, 'verify-email', CODE, identifier(1))
        self.assertEqual(self.enqueue(issued=issued, intent=intent).state, 'queued')
        original = copy.deepcopy(self.db.state)
        for children in [(1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1)]:
            self.db.state = copy.deepcopy(original); self.db.state['credential_counts'][UID] = children
            self.assertEqual(self.start(purpose=REGISTER).state, 'declined')
        self.db.state = copy.deepcopy(original)
        self.db.state['challenges'][(UID, REGISTER)]['pending_created'] = _timestamp(NOW - 101)
        self.assertEqual(self.start(purpose=REGISTER).state, 'declined')
        self.db.state = original
        self.assertIsNotNone(self.start(purpose=REGISTER).claim)

    def test_historical_context_preserves_original_after_expiry_rotation_email_and_version_change(self):
        self.enqueue()
        self.db.now = NOW + 10000
        account = list(self.db.state['accounts'][UID]); account[1] = 'changed@example.invalid'; account[4] = 7
        self.db.state['accounts'][UID] = tuple(account)
        self.db.state['challenges'][(UID, RESET)]['challenge_id'] = identifier(2)
        before = copy.deepcopy(self.db.state); count = len(self.db.calls)
        context = self.db.transaction(lambda c, e: self.outbox.resolve_context(c, e, challenge_id=identifier(1)))
        self.assertEqual((context.uid, context.email, context.purpose, context.challenge_id),
                         (UID, EMAIL, RESET, identifier(1)))
        self.assertEqual(context.email_identity, self.challenges.codec.email_identity(EMAIL))
        self.assertFalse(hasattr(context, 'code')); self.assertFalse(hasattr(context, 'intent'))
        self.assertNotIn(CODE, repr(context)); self.assertNotIn(EMAIL, repr(context))
        self.assertEqual(self.db.state, before)
        self.assertEqual(len(self.db.calls[count:]), 1)
        self.assertEqual(self.db.calls[count][0], _CONTEXT_QUERY)
        self.assertEqual(self.start().state, 'declined')  # Context never grants delivery.

    def test_historical_context_absent_fake_and_malformed_cipher_payload_refuses_without_intent(self):
        self.enqueue()
        self.assertIsNone(self.db.transaction(lambda c, e: self.outbox.resolve_context(c, e,
                                                                                   challenge_id=identifier(99))))
        original = copy.deepcopy(self.db.state)
        for field, value in [('ciphertext', 'A' * 100), ('uid', 'other-user'),
                             ('purpose', REGISTER), ('recipient', EMAIL), ('issuedAt', None)]:
            self.db.state = copy.deepcopy(original)
            self.db.state['outbox']['auth-mail:' + identifier(1)]['payload'][field] = value
            with self.assertRaises(AuthMailUnavailable):
                self.db.transaction(lambda c, e: self.outbox.resolve_context(c, e, challenge_id=identifier(1)))
        self.assertEqual(self.db.state['outbox']['auth-mail:' + identifier(1)]['attempts'], 0)


if __name__ == '__main__':
    unittest.main()
