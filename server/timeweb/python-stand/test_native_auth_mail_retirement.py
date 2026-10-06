"""Only obsolete immutable row retirement; synthetic SQL, no mail network."""
import copy
import unittest

from native_auth_mail_outbox import AuthMailUnavailable
from native_auth_mail_dispatcher import NativeAuthMailDispatcher, _NEXT
import test_native_auth_mail_outbox as outbox_fixture
import test_native_auth_mail_worker as worker_fixture
from test_native_auth_challenges import UID, RESET, CODE, identifier


class AuthMailRetirementTests(unittest.TestCase):
    setUp = outbox_fixture.AuthMailOutboxTests.setUp
    enqueue = outbox_fixture.AuthMailOutboxTests.enqueue
    start = outbox_fixture.AuthMailOutboxTests.start

    def stale_email(self):
        account = list(self.db.state['accounts'][UID]); account[1] = 'changed@example.invalid'
        self.db.state['accounts'][UID] = tuple(account)

    def test_stale_email_exact_cipher_retired_without_intent_or_code_charge_and_readback_rollback(self):
        self.enqueue(); original = copy.deepcopy(self.db.state); self.stale_email()
        payload = copy.deepcopy(self.db.state['outbox']['auth-mail:' + identifier(1)]['payload'])
        decision = self.start()
        self.assertEqual(decision.state, 'declined'); self.assertTrue(decision.retired)
        self.assertIsNone(decision.claim); self.assertFalse(hasattr(decision, 'intent'))
        row = self.db.state['outbox']['auth-mail:' + identifier(1)]
        self.assertEqual((row['attempts'], row['error'], row['delivered']), (1, 'auth.mail.failed', None))
        self.assertEqual(row['payload'], payload)
        self.assertEqual(self.db.state['challenges'][(UID, RESET)]['attempts'], 0)
        self.assertFalse(self.start().retired)
        for fault in ['cipher', 'readback']:
            self.db.state = copy.deepcopy(original); self.stale_email()
            if fault == 'cipher':
                self.db.state['outbox']['auth-mail:' + identifier(1)]['payload']['ciphertext'] = 'A' * 100
            else:
                self.db.fault = 'payload-readback'
            before = copy.deepcopy(self.db.state)
            with self.assertRaises(AuthMailUnavailable):
                self.start()
            self.assertEqual(self.db.state, before)
            self.db.fault = None

    def test_real_worker_retires_stale_then_dispatcher_selects_next_current_row_without_smtp_for_old(self):
        # Use actual worker/outbox/challenge code; only SQL selection and SMTP are synthetic.
        fixture = worker_fixture.AuthMailWorkerTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        db, challenges, outbox, worker = fixture.db, fixture.challenges, fixture.outbox, fixture.worker
        first = list(db.state['accounts'][UID]); first[1] = 'changed@example.invalid'
        db.state['accounts'][UID] = tuple(first)
        second_uid = 'second-current-account'; second_email = 'second@example.invalid'
        second = (second_uid, second_email, *first[2:])
        db.state['accounts'][second_uid] = second
        issued = db.transaction(lambda c,e: challenges.issue(c,e,uid=second_uid,email=second_email,
            purpose=RESET,code=CODE,challenge_id=identifier(2))).challenge
        from native_mail import NativeMailIntent
        db.transaction(lambda c,e: outbox.enqueue(c,e,issued=issued,
            intent=NativeMailIntent(second_email,'reset-password',CODE,identifier(2))))
        class SelectionCursor:
            def execute(self, sql, params=()):
                assert sql == _NEXT
            def fetchall(self):
                eligible = [row for row in db.state['outbox'].values() if row['attempts'] == 0]
                eligible.sort(key=lambda row: row['id'])
                return [] if not eligible else [(eligible[0]['uid'], RESET, eligible[0]['id'][10:])]
        def selection(action, *, deadline):
            cursor = SelectionCursor(); return action(cursor, cursor.execute)
        dispatcher = NativeAuthMailDispatcher(fixture.env, worker, transaction=selection,
                                              monotonic=lambda: fixture.clock[0])
        self.addCleanup(dispatcher.close)
        self.assertEqual(dispatcher._pump_once(), 'retired'); self.assertEqual(fixture.transport.calls, [])
        self.assertEqual(dispatcher._pump_once(), 'accepted')
        self.assertEqual(len(fixture.transport.calls), 1)
        self.assertEqual(fixture.transport.calls[0][0].delivery_id, identifier(2))
        self.assertFalse(dispatcher.halted)


if __name__ == '__main__':
    unittest.main()
