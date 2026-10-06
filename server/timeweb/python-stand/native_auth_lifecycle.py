"""Default-off native email lifecycle assembly for the existing SQL role.

No Firebase call, SMTP send, schema application or automatic mutation retry.
Public signup additionally requires a verified FINAL Auth import/write barrier;
setting its gate against the initial non-consistent snapshot is invalid.
Completion resolves immutable original context in its own read transaction,
never current email/challenge routing. Reconciliation tokens contain only sealed
receipt digests, never UID, email, code, password or session credentials.
"""
from __future__ import annotations

import base64
import json
import math
import re

from native_auth import NativeAuthService, NativeUnavailable
from native_credentials import decode_base64, unique_json
from native_password_credentials import PasswordWorkPool
from native_auth_challenges import NativeAuthChallengeStore
from native_auth_receipts import SensitiveAuthReceipts, AuthReceiptFingerprint
from native_auth_completion import NativeAuthCompletion
from native_auth_request import NativeAuthRequest
from native_auth_mail_outbox import NativeAuthMailOutbox, EVENT_KIND
from native_mail_envelope import NativeMailEnvelope
from native_mail import NativeMailIntent
from native_mail import NativeMailTransport
from native_auth_mail_worker import NativeAuthMailWorker
from native_auth_mail_dispatcher import NativeAuthMailDispatcher


class LifecycleInvalid(Exception):
    """Public malformed input, without sensitive request detail."""


class LifecycleRefused(Exception):
    """Generic code refusal; never reveal account existence/lifecycle."""


def _uuid(value):
    if not isinstance(value, str) or re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", value) is None:
        raise LifecycleInvalid()
    return value


def _email(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 320:
        raise LifecycleInvalid()
    try:
        if len(value.encode('utf-8')) > 1280:
            raise LifecycleInvalid()
        canonical = value.strip().lower()
        # Exactly the existing reviewed SMTP recipient grammar; Unicode domains
        # must be supplied as their ASCII domain form, never silently rewritten.
        NativeMailIntent(canonical, 'reset-password', '000000',
                         '00000000-0000-4000-8000-000000000000').message()
        return canonical
    except Exception:
        raise LifecycleInvalid() from None


def _purpose(value):
    if value not in ('password-reset.v1', 'register-email.v1'):
        raise LifecycleInvalid()
    return value


def _password(value):
    try:
        if not isinstance(value, str) or len(value) < 6 or len(value.encode('utf-8')) > 4096:
            raise LifecycleInvalid()
        return value  # Do not trim or normalize a password.
    except UnicodeError:
        raise LifecycleInvalid() from None


class NativeAuthLifecycle:
    def __init__(self, env, native_service, *, monotonic=None, start_mail=True):
        if (not isinstance(native_service, NativeAuthService)
                or not isinstance(native_service.verifier, PasswordWorkPool)
                or native_service.store._password_selector is not native_service.verifier
                or native_service.store.permission_model != 'provider-database-v1'):
            raise NativeUnavailable()
        if type(start_mail) is not bool:
            raise NativeUnavailable()
        self._env = env; self._native = native_service; self._transport = None
        self._clock = native_service._monotonic if monotonic is None else monotonic
        if not callable(self._clock):
            raise NativeUnavailable()
        self._registration = env.get('CLRS_NATIVE_REGISTRATION_ENABLED') == '1'
        if (env.get('CLRS_NATIVE_REGISTRATION_ENABLED') not in (None, '0', '1')
                or (self._registration and env.get('CLRS_NATIVE_REGISTRATION_SOURCE_AUTHORITY')
                    != 'final-auth-import-and-write-barrier-v1')):
            raise NativeUnavailable()
        try:
            key = decode_base64(env.get('CLRS_NATIVE_SESSION_KEY_B64'), max_bytes=32)
            wrapping = decode_base64(env.get('CLRS_NATIVE_CREDENTIAL_WRAPPING_KEY_B64'), max_bytes=32)
            self.challenges = NativeAuthChallengeStore.from_env(env)
            if self.challenges is None:
                raise NativeUnavailable()
            self.receipts = SensitiveAuthReceipts(key)
            self.mail = NativeAuthMailOutbox(self.challenges, NativeMailEnvelope(wrapping),
                                             monotonic=self._clock)
            # These assemblies share the SAME bounded password pool/store.
            self.completion = NativeAuthCompletion(native_service.store, native_service.verifier,
                self.challenges, self.receipts, monotonic=self._clock)
            self.requests = NativeAuthRequest(native_service.store, self.challenges,
                self.receipts, self.mail, source_account_exists=self._source_exists,
                issue_budget=self._issue_budget, monotonic=self._clock)
            self._transport = NativeMailTransport.from_env(env)
            self._worker = NativeAuthMailWorker.from_env(env, native_service.store, self.mail,
                self._transport, monotonic=self._clock)
            self.dispatcher = NativeAuthMailDispatcher.from_env(env, self._worker, monotonic=self._clock)
            if self._transport is None or self._worker is None or self.dispatcher is None:
                raise NativeUnavailable()
            if start_mail:
                self.dispatcher.start()
        except Exception:
            if self._transport is not None:
                self._transport.close()
            raise NativeUnavailable() from None

    @classmethod
    def from_env(cls, env, native_service, *, start_mail=True):
        flag = env.get('CLRS_NATIVE_AUTH_LIFECYCLE_ENABLED')
        if flag in (None, '0'):
            return None
        if (flag != '1' or env.get('CLRS_NATIVE_AUTH_ENABLED') != '1'
                or env.get('CLRS_NATIVE_AUTH_WRITES_ENABLED') != '1'
                or env.get('CLRS_NATIVE_PASSWORD_ENABLED') != '1'
                or env.get('CLRS_NATIVE_CHALLENGES_ENABLED') != '1'
                or env.get('CLRS_MAIL_ENABLED') != '1'
                or env.get('CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED') != '1'
                or env.get('CLRS_MAIL_AUTH_VERIFIED') != '1'):
            raise NativeUnavailable()
        return cls(env, native_service, start_mail=start_mail)

    def enabled_for(self, purpose):
        return _purpose(purpose) != 'register-email.v1' or self._registration

    def _deadline(self, peer, purpose, *, email=None):
        if not self.enabled_for(purpose):
            raise NativeUnavailable()
        deadline = self._native._deadline(peer)
        # Trusted socket/proxy peer only. No JSON or X-Forwarded-For identity.
        self._native.limiter.consume('auth-lifecycle-peer', peer, 10)
        if email is not None:
            self._native.limiter.consume('auth-lifecycle-email', email, 5)
        return deadline

    def _run(self, action, deadline):
        if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not 0 < deadline - self._clock() <= 8):
            raise NativeUnavailable()
        def bounded(cursor):
            count = 0
            def execute(sql, params=()):
                nonlocal count
                count += 1
                if count > 64:
                    raise NativeUnavailable()
                self._native.store._execute(cursor, sql, params, deadline=deadline)
            return action(cursor, execute)
        result = self._native.store._transaction(bounded, deadline=deadline)
        if self._clock() >= deadline:
            raise NativeUnavailable()
        return result

    @staticmethod
    def _source_exists(cursor, execute, email):
        # Bound only when FINAL canonical Auth import is current and old writes
        # are barred. The initial snapshot is not authority for this absence.
        execute('SELECT uid FROM clrs_staging.accounts WHERE email_normalized = %s LIMIT 2 FOR UPDATE',
                (email,))
        return bool(cursor.fetchall())

    @staticmethod
    def _issue_budget(cursor, execute):
        # Durable provider-wide budget, shared across processes/restarts. The
        # SERIALIZABLE range locks serialize competing auth-mail inserts.
        execute('SELECT CAST(FLOOR(UNIX_TIMESTAMP(UTC_TIMESTAMP(6))) AS SIGNED)')
        row = cursor.fetchone()
        if not isinstance(row, (tuple, list)) or len(row) != 1 or type(row[0]) is not int:
            raise NativeUnavailable()
        now = row[0]
        execute("""SELECT CAST(FLOOR(UNIX_TIMESTAMP(created_at)) AS SIGNED) FROM clrs_staging.outbox
          WHERE channel = 'email' AND event_kind = %s
          AND created_at >= DATE_SUB(UTC_TIMESTAMP(6), INTERVAL 1 HOUR)
          ORDER BY created_at, outbox_id LIMIT 101 FOR UPDATE""", (EVENT_KIND,))
        rows = cursor.fetchall()
        if any(not isinstance(item, (tuple, list)) or len(item) != 1
               or type(item[0]) is not int or not now - 3600 <= item[0] <= now for item in rows):
            raise NativeUnavailable()
        return len(rows) < 100 and sum(item[0] >= now - 60 for item in rows) < 20

    def operation_token(self, fingerprint):
        self.receipts._fingerprint(fingerprint)
        data = {'o': fingerprint.operation, 'id': fingerprint.operation_id,
                'a': fingerprint.actor_identity.hex(), 'c': fingerprint.context_digest.hex(),
                'r': fingerprint.request_digest.hex(), 's': fingerprint._seal.hex()}
        raw = json.dumps(data, sort_keys=True, separators=(',', ':')).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip('=')

    def _fingerprint(self, token):
        try:
            if not isinstance(token, str) or len(token) > 768 or re.fullmatch('[A-Za-z0-9_-]+', token) is None:
                raise LifecycleInvalid()
            raw = base64.urlsafe_b64decode(token + '=' * (-len(token) % 4))
            if base64.urlsafe_b64encode(raw).decode().rstrip('=') != token:
                raise LifecycleInvalid()
            value = unique_json(raw)
            if type(value) is not dict or set(value) != {'o', 'id', 'a', 'c', 'r', 's'}:
                raise LifecycleInvalid()
            for name in ('a', 'c', 'r', 's'):
                if not isinstance(value[name], str) or re.fullmatch('[0-9a-f]{64}', value[name]) is None:
                    raise LifecycleInvalid()
            result = AuthReceiptFingerprint(value['o'], value['id'], *(bytes.fromhex(value[x])
                                            for x in ('a', 'c', 'r', 's')))
            self.receipts._fingerprint(result)
            return result
        except Exception:
            raise LifecycleInvalid() from None

    def request(self, purpose, body, *, peer):
        _purpose(purpose)
        if type(body) is not dict or set(body) != {'email', 'operationId'}:
            raise LifecycleInvalid()
        email = _email(body['email']); operation_id = _uuid(body['operationId'])
        deadline = self._deadline(peer, purpose, email=email)
        if self.dispatcher.halted:
            raise NativeUnavailable()
        result = self.requests.request(purpose=purpose, email=body['email'],
            operation_id=operation_id, deadline=deadline)
        # Nonblocking notification only. SQL/SMTP runs on the one owned daemon;
        # queued committed intents are also found after process restart.
        self.dispatcher.wake()
        return result

    def complete(self, purpose, body, *, peer):
        _purpose(purpose)
        if type(body) is not dict or set(body) != {'challengeId', 'code', 'password', 'operationId'}:
            raise LifecycleInvalid()
        challenge_id = _uuid(body['challengeId']); operation_id = _uuid(body['operationId'])
        code = body['code']; password = _password(body['password'])
        if not isinstance(code, str) or re.fullmatch('[0-9]{6}', code) is None:
            raise LifecycleInvalid()
        deadline = self._deadline(peer, purpose)
        context = self._run(lambda cursor, execute: self.mail.resolve_context(
            cursor, execute, challenge_id=challenge_id), deadline)
        if context is None or context.purpose != purpose:
            raise LifecycleRefused()
        self._native.limiter.consume('auth-lifecycle-email', context.email, 5)
        return self.completion.complete(uid=context.uid, email=context.email, purpose=purpose,
            operation_id=operation_id, challenge_id=challenge_id, code=code,
            password=password, deadline=deadline)

    def lookup(self, body, *, peer):
        if type(body) is not dict:
            raise LifecycleInvalid()
        if set(body) == {'operationToken'}:
            fingerprint = self._fingerprint(body['operationToken'])
            purpose = fingerprint.operation.rsplit('.', 2)[0] + '.v1'
            deadline = self._deadline(peer, purpose)
        elif set(body) == {'purpose', 'stage', 'original'}:
            # If the entire response was lost, no operation token reached the
            # client. Reconstruct only the ORIGINAL digest from retained memory
            # input; this branch performs SELECT, never a repeated POST effect.
            purpose = _purpose(body['purpose']); stage = body['stage']; original = body['original']
            if type(original) is not dict or stage not in ('request', 'complete'):
                raise LifecycleInvalid()
            operation = purpose[:-3] + '.' + stage + '.v1'
            if stage == 'request':
                if set(original) != {'email', 'operationId'}:
                    raise LifecycleInvalid()
                email = _email(original['email']); _uuid(original['operationId'])
                deadline = self._deadline(peer, purpose, email=email)
                fingerprint = self.receipts.bind(operation, original['operationId'], actor_uid=None,
                    email_identity=self.challenges.codec.email_identity(email), purpose=purpose,
                    challenge_id=None, payload={'email': original['email']})
            else:
                if set(original) != {'challengeId', 'code', 'password', 'operationId'}:
                    raise LifecycleInvalid()
                challenge_id = _uuid(original['challengeId']); _uuid(original['operationId'])
                _password(original['password'])
                if not isinstance(original['code'], str) or re.fullmatch('[0-9]{6}', original['code']) is None:
                    raise LifecycleInvalid()
                deadline = self._deadline(peer, purpose)
                context = self._run(lambda cursor, execute: self.mail.resolve_context(
                    cursor, execute, challenge_id=challenge_id), deadline)
                if context is None or context.purpose != purpose:
                    raise LifecycleRefused()
                self._native.limiter.consume('auth-lifecycle-email', context.email, 5)
                fingerprint = self.receipts.bind(operation, original['operationId'], actor_uid=context.uid,
                    email_identity=self.challenges.codec.email_identity(context.email), purpose=purpose,
                    challenge_id=challenge_id, payload={name: original[name]
                        for name in ('challengeId', 'code', 'password')})
        else:
            raise LifecycleInvalid()
        return self.completion.lookup(fingerprint, deadline=deadline)

    def close(self):
        # Close/abort shared SMTP FIRST, then cancel/join its dispatcher. This
        # prevents the cancellation-check -> deliver race from starting late IO.
        self._transport.close()
        self.dispatcher.close()
        # Password pool belongs to NativeAuthService, not this assembly.
