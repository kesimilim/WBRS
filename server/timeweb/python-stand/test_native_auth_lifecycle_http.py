"""New lifecycle HTTP/factory boundaries only; no real account/cloud/SMTP."""
import base64
import io
import json
from types import SimpleNamespace
import unittest

from app import create_app
from native_auth import (NativeAuthService, NativeUnavailable, NativeRateLimited,
                         BoundedRateLimiter)
from native_auth_lifecycle import (NativeAuthLifecycle, LifecycleInvalid, _email, _password)
from native_auth_lifecycle_http import NativeAuthLifecycleHttp
from native_auth_receipts import SensitiveAuthReceipts, AuthReceiptOutcome
from native_credentials import CredentialCodec
from native_password_credentials import NativePasswordCodec, PasswordWorkPool
from native_sessions import NativeSessionStore, SessionTokens
from test_native_auth import CONFIG, CONFIG_REF, WRAPPING, SESSION_KEY

CID = '00000000-0000-4000-8000-000000000001'
OP = '00000000-0000-4000-8000-000000000002'
ENV = {name: '1' for name in ('CLRS_API_DRAFT_ENABLED', 'CLRS_NATIVE_AUTH_ENABLED',
    'CLRS_NATIVE_AUTH_WRITES_ENABLED', 'CLRS_NATIVE_PASSWORD_ENABLED',
    'CLRS_NATIVE_CHALLENGES_ENABLED', 'CLRS_NATIVE_AUTH_LIFECYCLE_ENABLED',
    'CLRS_MAIL_ENABLED', 'CLRS_MAIL_AUTH_VERIFIED', 'CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED')}
ENV.update(CLRS_NATIVE_AUTH_PERMISSION_MODEL='provider-database-v1',
    CLRS_NATIVE_SESSION_KEY_B64=base64.b64encode(SESSION_KEY).decode(),
    CLRS_NATIVE_CREDENTIAL_WRAPPING_KEY_B64=base64.b64encode(WRAPPING).decode(),
    CLRS_MAIL_PASSWORD='public-synthetic-smtp-password-never-used')


def request(app, path, *, body=None, raw=None, **changes):
    raw = json.dumps(body or {}).encode() if raw is None else raw
    environ = {'REQUEST_METHOD': 'POST', 'PATH_INFO': path, 'CONTENT_TYPE': 'application/json',
        'CONTENT_LENGTH': str(len(raw)), 'wsgi.input': io.BytesIO(raw), 'REMOTE_ADDR': '127.0.0.1'}
    environ.update(changes)
    result = {}
    def respond(status, headers):
        result.update(status=status, headers=dict(headers))
    result['raw'] = b''.join(app(environ, respond))
    result['body'] = json.loads(result['raw'])
    return result


class FakeLifecycle:
    def __init__(self):
        self.calls = []; self.error = None
        self.state = 'completed'; self.kind = 'accepted'; self.closed = False
    def _call(self, name, purpose, body, peer):
        self.calls.append((name, purpose, body, peer))
        if self.error:
            raise self.error('private request must never enter public error')
        return SimpleNamespace(state=self.state, fingerprint=object(),
            outcome=AuthReceiptOutcome(self.kind, CID if self.kind == 'accepted' else None))
    def request(self, purpose, body, *, peer):
        return self._call('request', purpose, body, peer)
    def complete(self, purpose, body, *, peer):
        return self._call('complete', purpose, body, peer)
    def lookup(self, body, *, peer):
        return self._call('lookup', None, body, peer)
    def operation_token(self, fingerprint):
        return 'sealed.digest.only'
    def close(self):
        self.closed = True


class LifecycleHttpTests(unittest.TestCase):
    def setUp(self):
        self.service = FakeLifecycle()
        self.factory_calls = []
        def factory(env, native):
            self.factory_calls.append(native)
            return self.service
        self.factory = factory
        self.app = self.build(ENV)
    def build(self, env):
        return create_app(env=env, native_service_factory=lambda env: object(),
            lifecycle_http_factory=lambda env, native: NativeAuthLifecycleHttp(
                env, native, service_factory=self.factory))

    def test_default_off_and_signup_separate_gate_do_not_construct_or_expose(self):
        self.factory_calls.clear()
        app = self.build({'CLRS_API_DRAFT_ENABLED': '1'})
        response = request(app, '/v1/auth/password-reset/request')
        self.assertEqual(response['status'], '404 Not Found')
        self.assertEqual(self.factory_calls, [])
        response = request(self.app, '/v1/auth/register-email/request')
        self.assertEqual(response['status'], '404 Not Found')
        self.assertEqual(self.service.calls, [])

    def test_preview_guard_precedes_factory_and_sensitive_body_read(self):
        self.factory_calls.clear()
        env = {**ENV, 'CLRS_PREVIEW_GUARD_ENABLED': '1',
            'CLRS_PREVIEW_ACCESS_KEY_B64': base64.b64encode(bytes([21])*32).decode()}
        app = self.build(env)
        class NeverRead:
            def read(self, size):
                raise AssertionError('unauthorized body was read')
        response = request(app, '/v1/auth/password-reset/request', **{'wsgi.input': NeverRead()})
        self.assertEqual(response['status'], '404 Not Found')
        self.assertEqual(self.factory_calls, [])

    def test_mounted_contract_no_store_cache_and_trusted_socket_peer(self):
        body = {'email': 'synthetic@example.invalid', 'operationId': OP}
        response = request(self.app, '/v1/auth/password-reset/request', body=body,
                           HTTP_X_FORWARDED_FOR='attacker-selected')
        self.assertEqual(response['status'], '202 Accepted')
        self.assertEqual(response['body'], {'status': 'accepted', 'challengeId': CID,
                                           'operationToken': 'sealed.digest.only'})
        self.assertEqual(response['headers']['Cache-Control'], 'no-store')
        self.assertEqual(self.service.calls[-1], ('request', 'password-reset.v1', body, '127.0.0.1'))
        self.service.kind = 'completed'
        response = request(self.app, '/v1/auth/password-reset/complete',
            body={'challengeId': CID, 'code': '123456', 'password': ' original ', 'operationId': OP})
        self.assertEqual(response['status'], '200 OK')
        self.assertNotIn(' original ', response['raw'].decode())
        self.assertNotIn('123456', response['raw'].decode())
        request(self.app, '/v1/auth/operations/lookup', body={'operationToken': 'synthetic'})
        self.assertEqual(self.service.calls[-1][0], 'lookup')
        self.app.close(); self.assertTrue(self.service.closed)

    def test_unavailable_pending_absent_are_unknown_and_never_retry_authority(self):
        for state in ('unavailable', 'pending', 'not_found'):
            self.service.state = state
            response = request(self.app, '/v1/auth/password-reset/complete')
            self.assertEqual(response['status'], '503 Service Unavailable')
            self.assertEqual(response['body'], {'error': 'outcome_unknown',
                                               'operationToken': 'sealed.digest.only'})
        self.service.error = NativeRateLimited
        response = request(self.app, '/v1/auth/password-reset/request')
        self.assertEqual(response['status'], '429 Too Many Requests')
        self.assertEqual(response['headers']['Retry-After'], '60')
        self.assertNotIn('private', response['raw'].decode())

    def test_malformed_duplicate_truncated_query_transfer_and_method_before_service(self):
        cases = [dict(raw=b'{"email":"a","email":"b"}'),
            dict(raw=b'{'), dict(raw=b'{}', CONTENT_LENGTH='3'),
            dict(QUERY_STRING='code=123456'), dict(HTTP_TRANSFER_ENCODING='chunked'),
            dict(CONTENT_TYPE='text/plain')]
        for changes in cases:
            response = request(self.app, '/v1/auth/password-reset/request', **changes)
            self.assertEqual(response['status'], '400 Bad Request')
        response = request(self.app, '/v1/auth/password-reset/request', REQUEST_METHOD='GET')
        self.assertEqual(response['status'], '405 Method Not Allowed')
        self.assertEqual(self.service.calls, [])


class LifecycleFactoryTests(unittest.TestCase):
    def setUp(self):
        self.clock = 0.0
        self.codec = CredentialCodec(CONFIG, CONFIG_REF, WRAPPING)
        self.pool = PasswordWorkPool(self.codec, NativePasswordCodec(WRAPPING))
        self.addCleanup(self.pool.close)
        self.store = NativeSessionStore(ENV, self.codec, SessionTokens(SESSION_KEY), password_selector=self.pool)
        self.native = NativeAuthService(ENV, self.store, self.pool,
            BoundedRateLimiter(SESSION_KEY, clock=lambda: self.clock), monotonic=lambda: self.clock)
    def build(self, env=ENV):
        service = NativeAuthLifecycle.from_env(env, self.native, start_mail=False)
        if service is not None:
            self.addCleanup(service.close)
        return service

    def test_factory_requires_shared_pool_verified_mail_provider_role_and_final_signup_gate(self):
        self.assertIsNone(self.build({'CLRS_NATIVE_AUTH_LIFECYCLE_ENABLED': '0'}))
        for key in ('CLRS_MAIL_AUTH_VERIFIED', 'CLRS_NATIVE_PASSWORD_ENABLED', 'CLRS_NATIVE_CHALLENGES_ENABLED',
                    'CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED'):
            with self.assertRaises(NativeUnavailable):
                self.build({**ENV, key: '0'})
        with self.assertRaises(NativeUnavailable):
            self.build({**ENV, 'CLRS_NATIVE_REGISTRATION_ENABLED': '1'})
        service = self.build()
        self.assertIs(service.completion._pool, self.pool)
        self.assertIs(service.completion._store, self.store)
        self.assertFalse(service.enabled_for('register-email.v1'))
        self.assertTrue(service.enabled_for('password-reset.v1'))
        self.store._env = {**ENV, 'CLRS_NATIVE_AUTH_PERMISSION_MODEL': 'strict-tables-v1'}
        with self.assertRaises(NativeUnavailable):
            self.build()

    def test_digest_only_reconciliation_roundtrip_forgery_and_exact_original_bytes(self):
        service = self.build()
        fingerprint = service.receipts.bind('password-reset.complete.v1', OP,
            actor_uid='synthetic-original', email_identity=service.challenges.codec.email_identity(
                'synthetic@example.invalid'), purpose='password-reset.v1', challenge_id=CID,
            payload={'challengeId': CID, 'code': '123456', 'password': ' original '})
        token = service.operation_token(fingerprint)
        self.assertEqual(service._fingerprint(token), fingerprint)
        decoded = base64.urlsafe_b64decode(token + '='*(-len(token)%4))
        for secret in (b'synthetic-original', b'@', b'123456', b' original '):
            self.assertNotIn(secret, decoded)
        value = json.loads(decoded); value['r'] = '00'*32
        forged = base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
        for invalid in (forged, token+'=', 'not-a-token', 'a'*769):
            with self.assertRaises(LifecycleInvalid):
                service._fingerprint(invalid)

    def test_lost_entire_ack_original_lookup_only_uses_digests_and_historical_context(self):
        service = self.build(); looked = []
        service.completion.lookup = lambda fingerprint, deadline: looked.append(fingerprint) or fingerprint
        original_request = {'email': ' Synthetic@Example.Invalid ', 'operationId': OP}
        request_fp = service.lookup({'purpose': 'password-reset.v1', 'stage': 'request',
            'original': original_request}, peer='socket-peer')
        expected_request = service.receipts.bind('password-reset.request.v1', OP,
            actor_uid=None, email_identity=service.challenges.codec.email_identity('synthetic@example.invalid'),
            purpose='password-reset.v1', challenge_id=None, payload={'email': original_request['email']})
        self.assertEqual(request_fp, expected_request)
        service._run = lambda action, deadline: action(object(), lambda *args: None)
        service.mail.resolve_context = lambda *args, **kwargs: SimpleNamespace(
            uid='original-owner', email='old@example.invalid', purpose='password-reset.v1')
        original_complete = {'challengeId': CID, 'operationId': OP, 'code': '123456', 'password': ' original '}
        complete_fp = service.lookup({'purpose': 'password-reset.v1', 'stage': 'complete',
            'original': original_complete}, peer='socket-peer')
        expected_complete = service.receipts.bind('password-reset.complete.v1', OP,
            actor_uid='original-owner', email_identity=service.challenges.codec.email_identity('old@example.invalid'),
            purpose='password-reset.v1', challenge_id=CID,
            payload={key: original_complete[key] for key in ('challengeId', 'code', 'password')})
        self.assertEqual(complete_fp, expected_complete)
        self.assertEqual(len(looked), 2)
        with self.assertRaises(LifecycleInvalid):
            service.lookup({'purpose': 'password-reset.v1', 'stage': 'complete',
                'original': {**original_complete, 'uid': 'attacker'}}, peer='socket-peer')

    def test_original_context_resolves_in_separate_tx_then_complete_and_minimum_password(self):
        service = self.build(); timeline = []
        context = SimpleNamespace(uid='synthetic-original', email='old@example.invalid',
            purpose='password-reset.v1')
        def run(action, deadline):
            timeline.append('context-begin')
            result = action(object(), lambda *args: None)
            timeline.append('context-committed')
            return result
        service._run = run
        service.mail.resolve_context = lambda *args, **kwargs: context
        def complete(**kwargs):
            timeline.append('completion-begin')
            self.assertEqual(kwargs['uid'], context.uid)
            self.assertEqual(kwargs['email'], context.email)
            self.assertEqual(kwargs['password'], ' exact ')
            return 'completed'
        service.completion.complete = complete
        body = {'challengeId': CID, 'operationId': OP, 'code': '123456', 'password': ' exact '}
        self.assertEqual(service.complete('password-reset.v1', body, peer='socket-peer'), 'completed')
        self.assertEqual(timeline, ['context-begin', 'context-committed', 'completion-begin'])
        for bad in ('short', '', 'x'*4097, None):
            with self.assertRaises(LifecycleInvalid):
                _password(bad)
        self.assertEqual(_password('  exact  '), '  exact  ')
        with self.assertRaises(LifecycleInvalid):
            _email('bad\r\nInjected@example.invalid')

    def test_durable_global_budget_limits_no_plaintext_rows_and_peer_limit_before_sql(self):
        service = self.build()
        class Cursor:
            def fetchone(self): return (1700000000,)
            def fetchall(self): return self.rows
        cursor = Cursor(); calls = []
        execute = lambda sql, params=(): calls.append((sql, params))
        for count, age, expected in ((19, 1, True), (20, 1, False), (99, 61, True), (100, 61, False)):
            cursor.rows = [(1700000000-age,)]*count
            self.assertEqual(service._issue_budget(cursor, execute), expected)
        self.assertTrue(all('CAST(' in sql for sql, _ in calls))
        service.requests.request = lambda **kwargs: 'accepted'
        for n in range(10):
            service.request('password-reset.v1', {'email': f'person{n}@example.invalid', 'operationId': OP},
                            peer='same-trusted-socket')
        with self.assertRaises(NativeRateLimited):
            service.request('password-reset.v1', {'email': 'other@example.invalid', 'operationId': OP},
                            peer='same-trusted-socket')


if __name__ == '__main__':
    unittest.main()
