"""Generated signup SQL/HTTP scenarios only; no SMTP, cloud or live accounts."""
import base64
import copy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_auth import NativeAuthService, BoundedRateLimiter, NativeUnavailable, NativeRateLimited
from native_auth_lifecycle import LifecycleInvalid
from native_auth_lifecycle_http import NativeAuthLifecycleHttp
from native_registration import NativeRegistration, _EMAIL_LOCK, _BUDGET
from native_credentials import CredentialCodec
from native_password_credentials import NativePasswordCodec, PasswordWorkPool
from native_sessions import NativeSessionStore, SessionTokens
from test_native_auth import CONFIG, CONFIG_REF, WRAPPING, SESSION_KEY
from test_native_auth_completion import Database as BaseDatabase, Cursor as BaseCursor
from test_native_auth_challenges import _timestamp
from app import create_app

OP = '00000000-0000-4000-8000-000000000041'
PREVIEW_PROOF = base64.b64encode(bytes([21])*32).decode()
BODY = {'operationId': OP, 'email': ' Fresh@Example.Invalid ',
        'password': ' original password ', 'nickname': ' Новый ник '}
ENV = {'CLRS_API_DRAFT_ENABLED': '1', 'CLRS_NATIVE_AUTH_ENABLED': '1',
    'CLRS_NATIVE_AUTH_WRITES_ENABLED': '1', 'CLRS_NATIVE_PASSWORD_ENABLED': '1',
    'CLRS_NATIVE_REGISTRATION_ENABLED': '1',
    'CLRS_NATIVE_REGISTRATION_SOURCE_AUTHORITY': 'final-auth-import-and-write-barrier-v1',
    'CLRS_NATIVE_AUTH_PERMISSION_MODEL': 'provider-database-v1',
    'CLRS_NATIVE_SESSION_KEY_B64': base64.b64encode(SESSION_KEY).decode()}


class Database(BaseDatabase):
    def __init__(self):
        super().__init__()
        self.budget_rows = []
    def transaction(self, action, *, deadline=None):
        assert not self.in_tx
        self.transactions += 1; self.in_tx = True
        working = copy.deepcopy(self.state); cursor = Cursor(self, working)
        try:
            result = action(cursor, cursor.execute)
            self.state = working
            if self.unknown_commit == self.transactions:
                raise OSError('synthetic lost COMMIT acknowledgement')
            return result
        finally:
            self.in_tx = False


class Cursor(BaseCursor):
    def execute(self, sql, params=()):
        norm = ' '.join(sql.split())
        if sql == _EMAIL_LOCK:
            self.db.calls.append((sql, params)); self.rowcount = 0
            self.result = [(a[0],) for a in self.working['accounts'].values() if a[1] == params[0]][:2]
        elif sql == _BUDGET:
            self.db.calls.append((sql, params)); self.rowcount = 0
            self.result = self.db.budget_rows
        elif sql == 'SELECT CAST(FLOOR(UNIX_TIMESTAMP(UTC_TIMESTAMP(6))) AS SIGNED)':
            self.db.calls.append((sql, params)); self.rowcount = 0; self.result = (self.db.now,)
        elif norm.startswith('INSERT INTO clrs_staging.accounts'):
            uid, email = params
            assert uid not in self.working['accounts']
            assert not any(row[1] == email for row in self.working['accounts'].values())
            self.db.calls.append((sql, params)); self.rowcount = 1; self.result = None
            self.working['accounts'][uid] = (uid, email, 0, 'active', 0, 0, _timestamp(self.db.now))
        elif norm.startswith('INSERT INTO clrs_staging.profiles'):
            uid, nickname = params
            assert uid not in self.working['profiles']
            self.db.calls.append((sql, params)); self.rowcount = 1; self.result = None
            self.working['profiles'][uid] = (uid, nickname, *([None]*14), '{}', 0, 0,
                                           None, None, _timestamp(self.db.now), '{}')
        else:
            super().execute(sql, params)


class SignupTests(unittest.TestCase):
    def setUp(self):
        self.db = Database(); self.clock = 0.0
        self.codec = CredentialCodec(CONFIG, CONFIG_REF, WRAPPING)
        # Real bounded password derivation verifies the resulting login material.
        self.pool = PasswordWorkPool(self.codec, NativePasswordCodec(WRAPPING))
        self.addCleanup(self.pool.close)
        self.store = NativeSessionStore(ENV, self.codec, SessionTokens(SESSION_KEY), password_selector=self.pool)
        self.native = NativeAuthService(ENV, self.store, self.pool,
            BoundedRateLimiter(SESSION_KEY, clock=lambda: self.clock), monotonic=lambda: self.clock)
        self.service = NativeRegistration(ENV, self.native, transaction=self.db.transaction,
                                          monotonic=lambda: self.clock)
    def register(self, **changes):
        return self.service.register(BODY | changes, peer='127.0.0.1')
    def test_new_account_unverified_clean_profile_real_password_and_replay_without_effects(self):
        self.db.state['accounts']['old-owner'] = ('old-owner', 'old@example.invalid', 0, 'active', 8, 1, _timestamp(self.db.now))
        self.db.state['profiles']['old-owner'] = ('old photo old phone old test old country',)
        old = copy.deepcopy(self.db.state)
        result = self.register()
        self.assertEqual((result.state, result.outcome.kind), ('completed', 'completed'))
        new = set(self.db.state['accounts']) - set(old['accounts'])
        self.assertEqual(len(new), 1); uid = new.pop()
        self.assertEqual(self.db.state['accounts'][uid][:6], (uid, 'fresh@example.invalid', 0, 'active', 0, 0))
        profile = self.db.state['profiles'][uid]
        self.assertEqual(profile[1], 'Новый ник'); self.assertTrue(all(v is None for v in profile[2:16]))
        self.assertEqual(profile[16:21], ('{}', 0, 0, None, None))
        self.assertEqual(self.db.state['profiles']['old-owner'], old['profiles']['old-owner'])
        native = self.db.state['native'][uid]
        material = self.pool.native_codec.decode(native)
        self.assertTrue(self.pool.verify(material, BODY['password'], timeout=1.5))
        self.assertFalse(self.pool.verify(material, BODY['password'].strip(), timeout=1.5))
        row = (uid, 0, 'active', 0, 0, None, None, None, None,
               native['scheme'], 0, native['material_ciphertext'], native['parameters'])
        snapshot = self.store._login_snapshot(row)
        self.assertEqual((snapshot.uid, snapshot.email_verified), (uid, False))
        self.assertEqual(self.db.state['identities'][uid][0][:4], (uid, 'password', uid, 'fresh@example.invalid'))
        self.assertEqual(self.db.state['live_sessions'], {})
        before = copy.deepcopy(self.db.state); calls = len(self.db.calls)
        replay = self.register()
        self.assertEqual(replay.outcome.kind, 'completed'); self.assertEqual(self.db.state, before)
        self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.db.calls[calls:]))
        self.assertNotIn(BODY['password'], repr(self.db.state['receipts']))
        self.assertNotIn(BODY['nickname'], repr(self.db.state['receipts']))
    def test_existing_email_including_disabled_account_never_adopted_or_overwritten(self):
        for disabled, lifecycle in [(0, 'active'), (1, 'active'), (1, 'blocked'), (1, 'deleted')]:
            with self.subTest(disabled=disabled, lifecycle=lifecycle):
                self.setUp()
                self.db.state['accounts']['existing'] = ('existing', 'fresh@example.invalid', disabled, lifecycle, 9, 1, _timestamp(self.db.now))
                self.db.state['profiles']['existing'] = ('retained old data',)
                before = copy.deepcopy(self.db.state)
                result = self.register()
                self.assertEqual(result.outcome.kind, 'refused')
                for table in ('accounts', 'native', 'profiles', 'identities', 'live_sessions'):
                    self.assertEqual(self.db.state[table], before[table])
                self.assertFalse(any('INSERT INTO clrs_staging.accounts' in sql for sql, _ in self.db.calls))
    def test_lost_commit_recovers_both_opaque_and_original_lookup_without_another_write(self):
        original_accounts = len(self.db.state['accounts'])
        self.db.unknown_commit = 2
        result = self.register(); self.assertEqual(result.state, 'unavailable')
        self.assertEqual(len(self.db.state['accounts']), original_accounts+1)
        token = self.service.operation_token(result.fingerprint)
        decoded = base64.urlsafe_b64decode(token + '='*(-len(token)%4))
        for secret in (BODY['email'].encode(), BODY['password'].encode(), BODY['nickname'].encode()):
            self.assertNotIn(secret, decoded)
        before = copy.deepcopy(self.db.state); calls = len(self.db.calls)
        for body in ({'operationToken': token}, {'purpose': 'register.v1', 'stage': 'complete', 'original': BODY}):
            resolved = self.service.lookup(body, peer='127.0.0.1')
            self.assertEqual(resolved.outcome.kind, 'completed')
        self.assertEqual(self.db.state, before)
        self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.db.calls[calls:]))
    def test_readback_failure_rolls_back_whole_signup_and_lookup_is_not_retry_authority(self):
        self.db.fault = 'native-readback'
        before = copy.deepcopy(self.db.state)
        result = self.register(); self.assertEqual(result.state, 'unavailable')
        self.assertEqual(self.db.state, before)
        calls = len(self.db.calls)
        resolved = self.service.lookup({'purpose': 'register.v1', 'stage': 'complete', 'original': BODY}, peer='127.0.0.1')
        self.assertEqual(resolved.state, 'not_found'); self.assertEqual(self.db.state, before)
        self.assertTrue(all(sql.startswith('SELECT') for sql, _ in self.db.calls[calls:]))
    def test_concurrent_existing_email_after_password_work_is_refused_without_touching_owner(self):
        original_prepare = self.pool.prepare
        def prepare(*args, **kwargs):
            self.assertFalse(self.db.in_tx)
            self.db.state['accounts']['concurrent-owner'] = ('concurrent-owner',
                'fresh@example.invalid', 0, 'active', 4, 1, _timestamp(self.db.now))
            self.db.state['profiles']['concurrent-owner'] = ('existing photo and old phone',)
            return original_prepare(*args, **kwargs)
        with patch.object(self.pool, 'prepare', prepare):
            result = self.register()
        self.assertEqual(result.outcome.kind, 'refused')
        self.assertEqual(self.db.state['accounts']['concurrent-owner'][4:6], (4, 1))
        self.assertEqual(self.db.state['profiles']['concurrent-owner'], ('existing photo and old phone',))
        self.assertEqual(self.db.state['native'], {}); self.assertEqual(self.db.state['identities'], {})
        self.assertFalse(any('INSERT INTO clrs_staging.accounts' in sql for sql, _ in self.db.calls))
    def test_invalid_nickname_email_or_password_fails_before_sql(self):
        for changed in ({'nickname': '   '}, {'nickname': 'name\nphone'}, {'nickname': 'x'*1001},
                        {'email': 'not-an-email'}, {'password': 'short'}, {'password': '\ud800'*6}):
            with self.assertRaises(LifecycleInvalid):
                self.register(**changed)
        self.assertEqual(self.db.calls, [])
    def test_changed_original_receipt_conflicts_and_uid_or_profile_input_is_rejected(self):
        self.register(); before = copy.deepcopy(self.db.state)
        for changed in ({'nickname': 'other'}, {'password': 'different password'}, {'email': BODY['email'].strip().lower()}):
            self.assertEqual(self.register(**changed).state, 'unavailable')
            self.assertEqual(self.db.state, before)
        for extra in ({'uid': 'old-owner'}, {'profile': {'phone': 'old'}}, {'code': '123456'}):
            with self.assertRaises(LifecycleInvalid):
                self.register(**extra)
    def test_durable_global_budget_and_trusted_peer_limits(self):
        self.db.budget_rows = [(self.db.now,)]*20
        before = copy.deepcopy(self.db.state)
        with self.assertRaises(NativeRateLimited):
            self.register()
        self.assertEqual(self.db.state, before)
        self.db.budget_rows = []
        for _ in range(4):
            self.register()
        with self.assertRaises(NativeRateLimited):
            self.register()
    def test_factory_keeps_final_source_gate_and_works_with_all_mail_flags_off(self):
        self.assertIsNone(NativeRegistration.from_env({}, self.native))
        for change in ({'CLRS_NATIVE_REGISTRATION_SOURCE_AUTHORITY': ''}, {'CLRS_NATIVE_PASSWORD_ENABLED': '0'},
                       {'CLRS_NATIVE_AUTH_WRITES_ENABLED': '0'}):
            with self.assertRaises(NativeUnavailable):
                NativeRegistration(ENV | change, self.native)
        self.assertIsInstance(NativeRegistration.from_env(ENV, self.native), NativeRegistration)


class HttpTests(unittest.TestCase):
    def request(self, app, path, body=BODY, **changes):
        raw = json.dumps(body).encode()
        environ = {'REQUEST_METHOD': 'POST', 'PATH_INFO': path, 'CONTENT_TYPE': 'application/json',
            'CONTENT_LENGTH': str(len(raw)), 'wsgi.input': io.BytesIO(raw), 'REMOTE_ADDR': '127.0.0.1',
            'HTTP_X_CLRS_PREVIEW_PROOF': PREVIEW_PROOF} | changes
        status = {}
        raw_result = b''.join(app(environ, lambda code, headers: status.update(code=code, headers=dict(headers))))
        return status | {'body': json.loads(raw_result)}
    def test_independent_signup_mount_without_smtp_and_default_off_and_preview_guard(self):
        calls = []
        class Fake:
            def register(self, body, *, peer):
                calls.append((body, peer))
                from native_auth_receipts import AuthReceiptOutcome
                return SimpleNamespace(state='completed', fingerprint=object(), outcome=AuthReceiptOutcome('completed'))
            lookup = register
            def operation_token(self, fingerprint): return 'opaque-digest'
            def close(self): pass
        def build(env):
            env = env | {'CLRS_PREVIEW_GUARD_ENABLED': '1', 'CLRS_PREVIEW_ACCESS_KEY_B64': PREVIEW_PROOF}
            return create_app(env=env, native_service_factory=lambda env: object(),
                lifecycle_http_factory=lambda env, native: NativeAuthLifecycleHttp(env, native,
                    registration_factory=lambda env, native: Fake()))
        off = self.request(build({'CLRS_API_DRAFT_ENABLED': '1'}), '/v1/auth/register')
        self.assertEqual(off['code'], '404 Not Found'); self.assertEqual(calls, [])
        app = build(ENV)
        reply = self.request(app, '/v1/auth/register', HTTP_X_FORWARDED_FOR='attacker')
        self.assertEqual(reply['code'], '200 OK')
        self.assertEqual(reply['body'], {'status': 'completed', 'operationToken': 'opaque-digest'})
        self.assertEqual(reply['headers']['Cache-Control'], 'no-store')
        self.assertEqual(calls, [(BODY, '127.0.0.1')])
        reply = self.request(app, '/v1/auth/register/lookup', body={'operationToken': 'opaque-digest'})
        self.assertEqual(reply['code'], '200 OK')
        self.assertEqual(self.request(app, '/v1/auth/register', REQUEST_METHOD='GET')['code'], '405 Method Not Allowed')
        guarded = build(ENV | {'CLRS_PREVIEW_GUARD_ENABLED': '1',
                              'CLRS_PREVIEW_ACCESS_KEY_B64': base64.b64encode(bytes([21])*32).decode()})
        before = len(calls)
        self.assertEqual(self.request(guarded, '/v1/auth/register', HTTP_X_CLRS_PREVIEW_PROOF='')['code'], '404 Not Found')
        self.assertEqual(len(calls), before)


if __name__ == '__main__':
    unittest.main()
