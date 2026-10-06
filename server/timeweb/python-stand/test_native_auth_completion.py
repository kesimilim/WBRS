"""Completion orchestration only; synthetic SQL/KDF, no older suite/live IO."""
import copy
import json
from types import SimpleNamespace
import unittest

from native_auth_completion import NativeAuthCompletion, AuthCompletionUnavailable
from native_credentials import CredentialCodec, CredentialUnavailable
from native_sessions import NativeSessionStore, SessionTokens
from native_password_credentials import PasswordWorkPool, NativePasswordCodec, AuthChallengeCodec
from native_auth_challenges import NativeAuthChallengeStore
from native_auth_receipts import SensitiveAuthReceipts
from native_pending_account import create_pending_account
from test_native_auth import CONFIG, CONFIG_REF, WRAPPING, SESSION_KEY
from test_native_auth_challenges import ENV, CODE, NOW, REGISTER, RESET, identifier, _timestamp
from test_native_pending_account import Database as PendingDatabase, Cursor as PendingCursor, UID, EMAIL
from test_native_auth_receipts import Cursor as ReceiptCursor

PASSWORD = ' new password with original spaces '
OPERATION = identifier(91)


class Database(PendingDatabase):
    def __init__(self):
        super().__init__()
        self.state.update(receipts={}, imported_rows={}, live_sessions={})
        self.in_tx = False; self.transactions = 0; self.unknown_commit = None
        self.cursors = []; self.timeline = []

    def transaction(self, action, *, deadline=None):
        assert not self.in_tx
        self.transactions += 1
        self.in_tx = True
        working = copy.deepcopy(self.state); cursor = Cursor(self, working)
        self.cursors.append(cursor)
        self.timeline.append(('begin', self.transactions))
        try:
            result = action(cursor, cursor.execute)
        except Exception:
            self.timeline.append(('rollback', self.transactions))
            raise
        else:
            self.state = working
            self.timeline.append(('commit', self.transactions))
            if self.unknown_commit == self.transactions:
                raise OSError('synthetic lost commit response containing no user data')
            return result
        finally:
            self.in_tx = False


class Cursor(PendingCursor):
    def __init__(self, db, working):
        super().__init__(db, working)
        receipt_db = SimpleNamespace(rows=working['receipts'], effects=0, calls=db.calls,
            fault='finish-readback' if db.fault == 'receipt-readback' else None)
        self.receipts = ReceiptCursor(receipt_db)

    def execute(self, sql, params=()):
        self.db.timeline.append(('sql', self.db.transactions, ' '.join(sql.split())))
        if 'native_auth_receipts' in sql:
            self.receipts.execute(sql, params)
            self.working['receipts'] = self.receipts.rows
            self.rowcount = self.receipts.rowcount; self.result = self.receipts.result
            return
        norm = ' '.join(sql.split())
        handled = (norm.startswith(('SELECT uid, email_normalized, disabled, lifecycle, token_version FROM',
            'SELECT uid FROM clrs_staging.native_password_credentials',
            'UPDATE clrs_staging.native_password_credentials', 'UPDATE clrs_staging.auth_credentials',
            'SELECT uid, scheme, password_hash, password_salt', 'UPDATE clrs_staging.device_sessions',
            'SELECT COUNT(*) FROM clrs_staging.device_sessions'))
            or norm.startswith('UPDATE clrs_staging.accounts SET token_version'))
        if not handled:
            return super().execute(sql, params)
        self.db.calls.append((sql, params)); self.result = None; self.rowcount = 0
        if norm.startswith('SELECT uid, email_normalized'):
            row = self.working['accounts'].get(params[0])
            self.result = None if row is None else row[:5]
        elif norm.startswith('SELECT uid FROM clrs_staging.native_password_credentials'):
            self.result = (params[0],) if params[0] in self.working['native'] else None
        elif norm.startswith('UPDATE clrs_staging.native_password_credentials'):
            scheme, version, cipher, parameters, uid = params
            self.working['native'][uid] = {'uid': uid, 'scheme': scheme, 'password_version': version,
                'material_ciphertext': bytes(cipher), 'parameters': json.loads(parameters)}
            self.rowcount = 1
        elif norm.startswith('UPDATE clrs_staging.auth_credentials'):
            row = self.working['imported_rows'].get(params[0])
            if row:
                row.update(scheme='bridge_only', password_hash=None, password_salt=None)
                self.rowcount = 1
        elif norm.startswith('SELECT uid, scheme, password_hash, password_salt'):
            row = self.working['imported_rows'].get(params[0])
            self.result = None if row is None else tuple(row[k] for k in
                ['uid', 'scheme', 'password_hash', 'password_salt'])
        elif norm.startswith('UPDATE clrs_staging.accounts SET token_version'):
            version, uid, email, expected = params
            row = self.working['accounts'].get(uid)
            if row and row[:5] == (uid, email, 0, 'active', expected):
                self.working['accounts'][uid] = (*row[:4], version, *row[5:]); self.rowcount = 1
        elif norm.startswith('UPDATE clrs_staging.device_sessions'):
            self.rowcount = self.working['live_sessions'].get(params[0], 0)
            self.working['live_sessions'][params[0]] = 0
        elif norm.startswith('SELECT COUNT(*) FROM clrs_staging.device_sessions'):
            self.result = (self.working['live_sessions'].get(params[0], 0),)


class ProbePool(PasswordWorkPool):
    def __init__(self, codec, native_codec, db):
        super().__init__(codec, native_codec, derive=lambda password, **kw: bytes([5]) * kw['dklen'])
        self.db = db; self.prepares = []; self.before_prepare = None; self.fail_prepare = False

    def prepare(self, uid, version, password, *, timeout=1.5):
        assert not self.db.in_tx, 'KDF must never run with SQL locks held'
        self.db.timeline.append(('kdf', len(self.prepares)))
        self.prepares.append((uid, version, timeout))
        if self.before_prepare:
            self.before_prepare()
        if self.fail_prepare:
            raise CredentialUnavailable()
        return super().prepare(uid, version, password, timeout=timeout)


class CompletionTests(unittest.TestCase):
    def setUp(self):
        self.db = Database(); self.clock = 0.0
        codec = CredentialCodec(CONFIG, CONFIG_REF, WRAPPING)
        self.pool = ProbePool(codec, NativePasswordCodec(WRAPPING), self.db)
        self.addCleanup(self.pool.close)
        self.store = NativeSessionStore(ENV, codec, SessionTokens(SESSION_KEY), password_selector=self.pool)
        self.challenges = NativeAuthChallengeStore(ENV, AuthChallengeCodec(SESSION_KEY))
        self.receipts = SensitiveAuthReceipts(bytes([13]) * 32)
        self.service = NativeAuthCompletion(self.store, self.pool, self.challenges, self.receipts,
            transaction=self.db.transaction, monotonic=lambda: self.clock)

    def issue(self, purpose=REGISTER):
        def action(c, e):
            pending = create_pending_account(c, e, uid=UID, email=EMAIL) if purpose == REGISTER else None
            result = self.challenges.issue(c, e, uid=UID, email=EMAIL, purpose=purpose, code=CODE,
                challenge_id=identifier(1), pending_account=pending)
            self.assertEqual(result.state, 'issued')
        self.db.transaction(action)

    def seed_reset(self):
        self.db.state['accounts'][UID] = (UID, EMAIL, 0, 'active', 0, 1, _timestamp(NOW-100))
        self.db.state['native'][UID] = self.pool.native_codec.seal(UID, 0, bytes([1])*16, bytes([2])*32)
        self.db.state['imported'].add(UID)
        self.db.state['imported_rows'][UID] = {'uid': UID, 'scheme': 'firebase_scrypt',
            'password_hash': b'old-encrypted-hash', 'password_salt': b'old-encrypted-salt'}
        self.db.state['profiles'][UID] = ('existing-profile-must-stay',)
        self.db.state['live_sessions'][UID] = 3
        self.issue(RESET)

    def complete(self, purpose=REGISTER, **changes):
        args = dict(uid=UID, email=EMAIL, purpose=purpose, operation_id=OPERATION,
            challenge_id=identifier(1), code=CODE, password=PASSWORD, deadline=self.clock+8)
        return self.service.complete(**(args | changes))

    def test_two_phases_shared_kdf_outside_sql_no_started_receipt_before_valid_kdf_and_exact_replay(self):
        self.issue()
        def before_kdf():
            self.assertEqual(self.db.state['receipts'], {})
            self.assertEqual(self.db.state['native'], {})
            self.assertIsNone(self.db.state['challenges'][(UID, REGISTER)]['consumed'])
        self.pool.before_prepare = before_kdf
        result = self.complete()
        self.assertEqual((result.state, result.outcome.kind, result.requires_lookup), ('completed', 'completed', False))
        self.assertEqual(len(self.pool.prepares), 1)
        self.assertEqual(self.pool.prepares[0][:2], (UID, 0))
        self.assertIsNot(self.db.cursors[-2], self.db.cursors[-1])
        self.assertEqual(self.db.state['accounts'][UID][2:6], (0, 'active', 0, 1))
        calls = len(self.db.calls)
        replay = self.complete()
        self.assertEqual(replay.outcome.kind, 'completed')
        self.assertEqual(len(self.pool.prepares), 1)
        self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.db.calls[calls:]))
        data = repr([params for _, params in self.db.calls if 'native_auth_receipts' in _])
        self.assertNotIn(PASSWORD, data); self.assertNotIn(CODE, data)
        self.assertNotIn(PASSWORD, repr(result)); self.assertNotIn(EMAIL, repr(result.fingerprint))

    def test_invalid_attempt_receipt_atomic_and_replay_conflict_before_another_charge(self):
        self.issue()
        result = self.complete(code='999999')
        self.assertEqual(result.outcome.kind, 'refused')
        self.assertEqual(self.db.state['challenges'][(UID, REGISTER)]['attempts'], 1)
        self.assertEqual(self.pool.prepares, [])
        replay = self.complete(code='999999')
        self.assertEqual(replay.outcome.kind, 'refused')
        self.assertEqual(self.db.state['challenges'][(UID, REGISTER)]['attempts'], 1)
        conflict = self.complete(code=CODE)
        self.assertEqual(conflict.state, 'unavailable'); self.assertTrue(conflict.requires_lookup)
        self.assertEqual(self.db.state['challenges'][(UID, REGISTER)]['attempts'], 1)
        self.assertEqual(self.pool.prepares, [])
        self.assertEqual(self.db.state['native'], {})
        self.assertIsNone(self.db.state['challenges'][(UID, REGISTER)]['consumed'])

    def test_kdf_failure_deadline_or_changed_challenge_account_refuses_without_stale_activation(self):
        for race in ['kdf', 'deadline', 'challenge', 'version', 'email', 'blocked']:
            self.setUp()
            self.issue()
            def during_kdf():
                if race == 'kdf':
                    self.pool.fail_prepare = True
                elif race == 'deadline':
                    self.clock = 8.0
                elif race == 'challenge':
                    self.db.now += 60
                    self.db.transaction(lambda c, e: self.challenges.issue(c, e, uid=UID, email=EMAIL,
                        purpose=REGISTER, code=CODE, challenge_id=identifier(2)))
                else:
                    row = list(self.db.state['accounts'][UID])
                    index, value = {'version': (4, 1), 'email': (1, 'changed@example.invalid'),
                                    'blocked': (3, 'blocked')}[race]
                    row[index] = value; self.db.state['accounts'][UID] = tuple(row)
            self.pool.before_prepare = during_kdf
            result = self.complete()
            self.assertIn(result.state, ['completed', 'unavailable'])
            if result.outcome:
                self.assertEqual(result.outcome.kind, 'refused')
            self.assertEqual(self.db.state['native'], {})
            self.assertEqual(self.db.state['identities'], {})
            self.assertEqual(self.db.state['profiles'], {})
            self.assertNotEqual(self.db.state['accounts'][UID][2], 0)
            if race in ['kdf', 'deadline']:
                self.assertEqual(self.db.state['receipts'], {})

    def test_atomic_reset_consumes_cap_retires_imported_material_and_revokes_sessions(self):
        self.seed_reset(); profile = copy.deepcopy(self.db.state['profiles'][UID])
        result = self.complete(RESET)
        self.assertEqual(result.outcome.kind, 'completed')
        self.assertEqual(self.pool.prepares[0][:2], (UID, 1))
        self.assertEqual(self.db.state['accounts'][UID][4], 1)
        self.assertEqual(self.db.state['native'][UID]['password_version'], 1)
        self.assertEqual(self.db.state['imported_rows'][UID], {'uid': UID,
            'scheme': 'bridge_only', 'password_hash': None, 'password_salt': None})
        self.assertEqual(self.db.state['live_sessions'][UID], 0)
        self.assertEqual(self.db.state['profiles'][UID], profile)
        self.assertIsNotNone(self.db.state['challenges'][(UID, RESET)]['consumed'])

    def test_finish_readback_failure_rolls_back_attempt_or_consumption_all_effects_receipt(self):
        for code in [CODE, '999999']:
            self.setUp(); self.issue(); before = copy.deepcopy(self.db.state)
            self.db.fault = 'receipt-readback'
            result = self.complete(code=code)
            self.assertEqual(result.state, 'unavailable'); self.assertTrue(result.requires_lookup)
            self.assertEqual(self.db.state, before)
            self.db.fault = None
            calls = len(self.db.calls)
            lookup = self.service.lookup(result.fingerprint, deadline=self.clock+8)
            self.assertEqual(lookup.state, 'not_found'); self.assertTrue(lookup.requires_lookup)
            self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.db.calls[calls:]))

    def test_unknown_commit_requires_digest_only_lookup_and_never_repeats_effects(self):
        self.issue(); self.db.unknown_commit = self.db.transactions + 2
        result = self.complete()
        self.assertEqual(result.state, 'unavailable'); self.assertTrue(result.requires_lookup)
        self.assertEqual(len(self.pool.prepares), 1)
        self.assertEqual(self.db.state['accounts'][UID][2], 0)
        self.db.unknown_commit = None
        before = copy.deepcopy(self.db.state); calls = len(self.db.calls)
        reconciled = self.service.lookup(result.fingerprint, deadline=self.clock+8)
        self.assertEqual((reconciled.state, reconciled.outcome.kind), ('completed', 'completed'))
        self.assertEqual(self.db.state, before); self.assertEqual(len(self.pool.prepares), 1)
        self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.db.calls[calls:]))
        self.assertFalse(any('native_auth_challenges' in sql for sql, _ in self.db.calls[calls:]))

    def test_shared_pool_bad_deadline_foreign_context_and_reused_cursor_fail_closed(self):
        with self.assertRaises(AuthCompletionUnavailable):
            NativeAuthCompletion(self.store, object(), self.challenges, self.receipts)
        for deadline in [None, float('inf'), self.clock, self.clock+9]:
            with self.assertRaises(AuthCompletionUnavailable):
                self.complete(deadline=deadline)
        self.assertEqual(self.db.calls, [])
        self.issue()
        first_cursor = []
        def reused(action, *, deadline):
            if not first_cursor:
                def capture(c, e):
                    first_cursor.append(c); return action(c, e)
                return self.db.transaction(capture)
            return action(first_cursor[0], first_cursor[0].execute)
        bad = NativeAuthCompletion(self.store, self.pool, self.challenges, self.receipts,
            transaction=reused, monotonic=lambda: self.clock)
        result = bad.complete(uid=UID, email=EMAIL, purpose=REGISTER, operation_id=OPERATION,
            challenge_id=identifier(1), code=CODE, password=PASSWORD, deadline=8)
        self.assertEqual(result.state, 'unavailable'); self.assertTrue(result.requires_lookup)
        self.assertEqual(self.db.state['receipts'], {})
        self.assertEqual(self.db.state['native'], {})


if __name__ == '__main__':
    unittest.main()
