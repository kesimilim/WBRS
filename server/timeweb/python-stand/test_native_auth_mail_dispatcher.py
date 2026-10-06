"""Only dispatcher lifecycle; synthetic fixed SELECT/TX/worker, no live I/O."""
import threading
import unittest

from native_auth_mail_dispatcher import NativeAuthMailDispatcher, AuthMailDispatcherUnavailable, _NEXT
from native_auth_mail_worker import NativeAuthMailWorker, AuthMailWorkerResult
from native_password_credentials import MAX_VERSION
from test_native_auth_challenges import UID, RESET, identifier


ENV = {'CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED': '1'}


class Worker(NativeAuthMailWorker):
    def __init__(self, db):
        self.db = db; self.calls = []; self.entered = threading.Event(); self.completed = threading.Event()
        self.drained = threading.Event()
        self.result = AuthMailWorkerResult('accepted', 'finish', True)
        self.gate = None

    def _enabled(self):
        pass  # This fixture does not construct a configured SQL/SMTP store.

    def run_once(self, **values):
        assert not self.db.in_tx, 'Selection TX must finish before worker starts'
        self.calls.append(values); self.entered.set()
        assert values['deadline'] == 132
        if self.gate:
            assert self.gate.wait(1)
        if values['cancel_event'].is_set():
            return AuthMailWorkerResult('unknown', 'claim', requires_reconcile=True)
        if self.result.state in ('accepted', 'failed'):
            self.db.rows.pop(0)
        if not self.db.rows:
            self.drained.set()
        self.completed.set(); return self.result


class Cursor:
    def __init__(self, db):
        self.db = db

    def execute(self, sql, params=()):
        assert sql == _NEXT and params == (MAX_VERSION,)
        self.db.calls.append((sql, params))

    def fetchall(self):
        return self.db.rows[:1]


class Database:
    def __init__(self, rows=None):
        self.rows = [(UID, RESET, identifier(1))] if rows is None else rows
        self.calls = []; self.in_tx = False; self.deadlines = []
        self.fail = False; self.after = None; self.gate = None; self.entered = threading.Event()

    def transaction(self, action, *, deadline):
        assert not self.in_tx
        self.in_tx = True; self.deadlines.append(deadline); self.entered.set()
        try:
            if self.gate:
                assert self.gate.wait(1)
            if self.fail:
                raise OSError('synthetic selection unavailable')
            cursor = Cursor(self); result = action(cursor, cursor.execute)
            if self.after:
                self.after()
            return result
        finally:
            self.in_tx = False


class AuthMailDispatcherTests(unittest.TestCase):
    def make(self, rows=None):
        db = Database(rows); worker = Worker(db)
        dispatcher = NativeAuthMailDispatcher(ENV, worker, transaction=db.transaction,
                                              monotonic=lambda: 100.0)
        self.addCleanup(dispatcher.close)
        return db, worker, dispatcher

    def test_default_off_explicit_start_existing_queue_single_thread_and_coalesced_wake(self):
        self.assertIsNone(NativeAuthMailDispatcher.from_env({}))
        self.assertIsNone(NativeAuthMailDispatcher.from_env({'CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED': '0'}))
        with self.assertRaises(AuthMailDispatcherUnavailable):
            NativeAuthMailDispatcher.from_env({'CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED': 'yes'})
        db, worker, dispatcher = self.make([(UID, RESET, identifier(1)), (UID, RESET, identifier(2))])
        self.assertFalse(dispatcher.wake()); self.assertEqual(db.calls, [])
        self.assertTrue(dispatcher.start()); thread = dispatcher._thread
        self.assertFalse(dispatcher.start()); self.assertIs(dispatcher._thread, thread)
        self.assertTrue(worker.drained.wait(1))
        # The initial wake drains original queued intents even if HTTP never wakes it.
        worker.completed.clear()
        for _ in range(20):
            dispatcher.wake()
        dispatcher.close()
        self.assertEqual(len(worker.calls), 2)
        self.assertFalse(dispatcher.wake()); self.assertFalse(thread.is_alive())
        self.assertTrue(all(deadline == 108 for deadline in db.deadlines))
        self.assertTrue(all(call['cancel_event'] is dispatcher._closed for call in worker.calls))

    def test_one_actual_pump_slot_and_deadlines_fixed_ids_only(self):
        db, worker, dispatcher = self.make()
        db.gate = threading.Event(); results = []
        thread = threading.Thread(target=lambda: results.append(dispatcher._pump_once()))
        thread.start(); self.assertTrue(db.entered.wait(1))
        self.assertEqual(dispatcher._pump_once(), 'stopped')
        self.assertEqual(len(db.deadlines), 1)
        db.gate.set(); thread.join(1); self.assertFalse(thread.is_alive())
        self.assertEqual(results, ['accepted']); self.assertEqual(len(worker.calls), 1)
        self.assertEqual(set(worker.calls[0]), {'uid', 'purpose', 'challenge_id', 'deadline', 'cancel_event'})
        self.assertEqual(worker.calls[0]['uid'], UID)
        for required in ["o.attempts = 0", "o.last_error_code IS NULL", "c.consumed_at IS NULL",
                         "c.expires_at > UTC_TIMESTAMP(6) + INTERVAL 8 SECOND", "a.lifecycle = 'active'",
                         "c.account_token_version = a.token_version", "pending_account_created_at = a.created_at",
                         "NOT EXISTS", "ORDER BY o.available_at ASC, o.outbox_id ASC LIMIT 1"]:
            self.assertIn(required, _NEXT)
        self.assertEqual(db.calls[0][1], (MAX_VERSION,))
        # Only a proven retired ACK allows advancing to the next queue entry.
        db, worker, dispatcher = self.make([(UID, RESET, identifier(1)), (UID, RESET, identifier(2))])
        worker.result = AuthMailWorkerResult('declined', 'retired')
        self.assertEqual(dispatcher._pump_once(), 'retired'); self.assertFalse(dispatcher.halted)
        db.rows.pop(0)  # Models the separately tested persisted retirement.
        worker.result = AuthMailWorkerResult('accepted', 'finish', True)
        self.assertEqual(dispatcher._pump_once(), 'accepted')
        self.assertEqual([c['challenge_id'] for c in worker.calls], [identifier(1), identifier(2)])

    def test_refused_or_unknown_sql_and_worker_unknown_halt_without_retry(self):
        cases = ['sql-failed', 'bad-purpose', 'bad-shape', 'worker-unknown', 'worker-declined']
        for case in cases:
            with self.subTest(case=case):
                db, worker, dispatcher = self.make()
                if case == 'sql-failed':
                    db.fail = True
                elif case == 'bad-purpose':
                    db.rows = [(UID, 'foreign-purpose', identifier(1))]
                elif case == 'bad-shape':
                    db.rows = [(UID, RESET, identifier(1), 'foreign-extra')]
                else:
                    worker.result = AuthMailWorkerResult('unknown' if case == 'worker-unknown' else 'declined', 'claim')
                self.assertEqual(dispatcher._pump_once(), 'halted'); self.assertTrue(dispatcher.halted)
                before = (len(db.deadlines), len(worker.calls))
                self.assertEqual(dispatcher._pump_once(), 'stopped')
                self.assertEqual((len(db.deadlines), len(worker.calls)), before)
                self.assertFalse(dispatcher.wake())
                with self.assertRaises(AuthMailDispatcherUnavailable):
                    dispatcher.start()

    def test_close_during_selection_or_active_worker_cancels_without_late_restart(self):
        db, worker, dispatcher = self.make()
        db.after = dispatcher.close
        self.assertEqual(dispatcher._pump_once(), 'stopped')
        self.assertEqual(worker.calls, []); self.assertFalse(dispatcher.wake())
        with self.assertRaises(AuthMailDispatcherUnavailable):
            dispatcher.start()
        db, worker, dispatcher = self.make()
        worker.gate = threading.Event(); thread = threading.Thread(target=dispatcher._pump_once)
        thread.start(); self.assertTrue(worker.entered.wait(1))
        dispatcher.close(); worker.gate.set(); thread.join(1); self.assertFalse(thread.is_alive())
        self.assertTrue(worker.calls[0]['cancel_event'].is_set())
        self.assertFalse(worker.completed.is_set())
        before = len(db.deadlines); self.assertEqual(dispatcher._pump_once(), 'stopped')
        self.assertEqual(len(db.deadlines), before)


if __name__ == '__main__':
    unittest.main()
