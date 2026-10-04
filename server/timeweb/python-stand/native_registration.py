"""New-email signup without SMTP; bounded, atomic, explicit-login only.

No client UID, profile import, old-account activation, schema/grant mutation or
automatic retry. Existing final Auth source-authority gate remains required.
Only a committed opaque receipt proves completion after a lost acknowledgement.
"""
from __future__ import annotations

import hmac
import json
import math
import uuid
from types import SimpleNamespace

from native_auth import NativeAuthService, NativeUnavailable, NativeRateLimited
from native_auth_lifecycle import NativeAuthLifecycle, LifecycleInvalid, _email, _password, _uuid
from native_auth_receipts import SensitiveAuthReceipts, AuthReceiptOutcome, AuthReceiptResolution
from native_credentials import decode_base64
from native_password_credentials import PasswordWorkPool, AuthChallengeCodec
from native_pending_account import _ACCOUNT, _NATIVE, _PROFILE, _empty_object, _date, _empty

OPERATION = 'register.complete.v1'
PURPOSE = 'register.v1'
_EMAIL_LOCK = ('SELECT uid FROM clrs_staging.accounts '
               'WHERE email_normalized = %s LIMIT 2 FOR UPDATE')
_BUDGET = """SELECT CAST(FLOOR(UNIX_TIMESTAMP(created_at)) AS SIGNED)
 FROM clrs_staging.native_auth_receipts WHERE operation = %s
 AND created_at >= DATE_SUB(UTC_TIMESTAMP(6), INTERVAL 1 HOUR)
 ORDER BY created_at, operation_id LIMIT 101 FOR UPDATE"""


def _nickname(value):
    try:
        if (not isinstance(value, str) or not value.strip() or len(value) > 1000
                or len(value.encode('utf-8')) > 4000
                or any(ord(c) < 32 or ord(c) == 127 for c in value)):
            raise LifecycleInvalid()
        return value.strip()
    except UnicodeError:
        raise LifecycleInvalid() from None


class NativeRegistration:
    def __init__(self, env, native_service, *, transaction=None, monotonic=None):
        if (env.get('CLRS_NATIVE_REGISTRATION_ENABLED') != '1'
                or env.get('CLRS_NATIVE_REGISTRATION_SOURCE_AUTHORITY')
                    != 'final-auth-import-and-write-barrier-v1'
                or env.get('CLRS_NATIVE_AUTH_ENABLED') != '1'
                or env.get('CLRS_NATIVE_AUTH_WRITES_ENABLED') != '1'
                or env.get('CLRS_NATIVE_PASSWORD_ENABLED') != '1'
                or not isinstance(native_service, NativeAuthService)
                or not isinstance(native_service.verifier, PasswordWorkPool)
                or native_service.store._password_selector is not native_service.verifier
                or native_service.store.permission_model != 'provider-database-v1'):
            raise NativeUnavailable()
        self._native = native_service
        self._env = env
        self._transaction = transaction
        self._clock = native_service._monotonic if monotonic is None else monotonic
        key = decode_base64(env.get('CLRS_NATIVE_SESSION_KEY_B64'), max_bytes=32)
        self.receipts = SensitiveAuthReceipts(key)
        self._email_codec = AuthChallengeCodec(key)

    @classmethod
    def from_env(cls, env, native_service):
        if env.get('CLRS_NATIVE_REGISTRATION_ENABLED') in (None, '0'):
            return None
        return cls(env, native_service)

    # Same sealed, digest-only envelope as other native auth operations.
    operation_token = NativeAuthLifecycle.operation_token
    _fingerprint = NativeAuthLifecycle._fingerprint

    def _bind(self, body):
        if type(body) is not dict or set(body) != {'operationId', 'email', 'password', 'nickname'}:
            raise LifecycleInvalid()
        email = _email(body['email']); _password(body['password']); _nickname(body['nickname'])
        _uuid(body['operationId'])
        fingerprint = self.receipts.bind(OPERATION, body['operationId'], actor_uid=None,
            email_identity=self._email_codec.email_identity(email), purpose=PURPOSE,
            challenge_id=None, payload={key: body[key] for key in ('email', 'nickname', 'password')})
        return email, fingerprint

    def _deadline(self, peer, email=None):
        if (self._env.get('CLRS_NATIVE_REGISTRATION_ENABLED') != '1'
                or self._env.get('CLRS_NATIVE_REGISTRATION_SOURCE_AUTHORITY')
                    != 'final-auth-import-and-write-barrier-v1'):
            raise NativeUnavailable()
        deadline = self._native._deadline(peer)
        self._native.limiter.consume('registration-peer', peer, 10)
        if email is not None:
            self._native.limiter.consume('registration-email', email, 5)
        return deadline

    def _run(self, action, deadline):
        if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not 0 < deadline - self._clock() <= 8):
            raise NativeUnavailable()
        def bounded(cursor, raw_execute):
            count = 0
            def execute(sql, params=()):
                nonlocal count
                count += 1
                if count > 64 or self._clock() >= deadline:
                    raise NativeUnavailable()
                raw_execute(sql, params)
                if self._clock() >= deadline:
                    raise NativeUnavailable()
            return action(cursor, execute)
        if self._transaction is None:
            result = self._native.store._transaction(lambda cursor: bounded(cursor,
                lambda sql, params=(): self._native.store._execute(cursor, sql, params, deadline=deadline)),
                deadline=deadline)
        else:
            result = self._transaction(bounded, deadline=deadline)
        if self._clock() >= deadline:
            raise NativeUnavailable()
        return result

    @staticmethod
    def _result(fingerprint, resolution=None):
        return SimpleNamespace(fingerprint=fingerprint,
            state='unavailable' if resolution is None else resolution.state,
            outcome=None if resolution is None else resolution.outcome)

    @staticmethod
    def _existing(cursor, execute, email):
        execute(_EMAIL_LOCK, (email,))
        rows = cursor.fetchall()
        if (not isinstance(rows, (tuple, list)) or len(rows) > 1
                or any(not isinstance(row, (tuple, list)) or len(row) != 1 for row in rows)):
            raise NativeUnavailable()
        return bool(rows)

    @staticmethod
    def _budget(cursor, execute):
        execute('SELECT CAST(FLOOR(UNIX_TIMESTAMP(UTC_TIMESTAMP(6))) AS SIGNED)')
        row = cursor.fetchone()
        if not isinstance(row, (tuple, list)) or len(row) != 1 or type(row[0]) is not int:
            raise NativeUnavailable()
        now = row[0]
        execute(_BUDGET, (OPERATION,))
        rows = cursor.fetchall()
        if (not isinstance(rows, (tuple, list)) or any(not isinstance(row, (tuple, list))
                or len(row) != 1 or type(row[0]) is not int or not now - 3600 <= row[0] <= now for row in rows)):
            raise NativeUnavailable()
        if len(rows) >= 100 or sum(row[0] >= now - 60 for row in rows) >= 20:
            raise NativeRateLimited()

    def register(self, body, *, peer):
        email, fingerprint = self._bind(body)
        deadline = self._deadline(peer, email)
        try:
            def first(cursor, execute):
                existing = self._existing(cursor, execute, email)
                replay = self.receipts.lookup(cursor, execute, fingerprint)
                if replay.state != 'not_found':
                    return replay
                if existing:
                    self._budget(cursor, execute)
                    lease = self.receipts.begin(cursor, execute, fingerprint)
                    return (lease if type(lease) is AuthReceiptResolution else
                            self.receipts.finish(lease, AuthReceiptOutcome('refused')))
                self._budget(cursor, execute)
                return None  # No receipt or account reserved around password KDF.
            resolved = self._run(first, deadline)
            if resolved is not None:
                return self._result(fingerprint, resolved)
            uid = str(uuid.uuid4())  # Chosen only by the server, never cached or imported.
            prepared = self._native.verifier.prepare(uid, 0, body['password'],
                timeout=min(1.5, deadline - self._clock()))
            def second(cursor, execute):
                existing = self._existing(cursor, execute, email)
                replay = self.receipts.lookup(cursor, execute, fingerprint)
                if replay.state != 'not_found':
                    return replay
                self._budget(cursor, execute)
                execute('SELECT uid FROM clrs_staging.accounts WHERE uid = %s LIMIT 1 FOR UPDATE', (uid,))
                if cursor.fetchone() is not None:
                    raise NativeUnavailable()
                lease = self.receipts.begin(cursor, execute, fingerprint)
                if type(lease) is AuthReceiptResolution:
                    return lease
                if existing:
                    return self.receipts.finish(lease, AuthReceiptOutcome('refused'))
                self._insert(cursor, execute, uid, email, _nickname(body['nickname']), prepared)
                return self.receipts.finish(lease, AuthReceiptOutcome('completed'))
            return self._result(fingerprint, self._run(second, deadline))
        except NativeRateLimited:
            raise
        except Exception:
            # A failed/lost COMMIT never proves rollback or permits a new write.
            return self._result(fingerprint)

    def _insert(self, cursor, execute, uid, email, nickname, prepared):
        codec = self._native.verifier.native_codec
        material = codec.decode(prepared)
        if material.uid != uid or material.password_version != 0:
            raise NativeUnavailable()
        prepared = {**prepared, 'material_ciphertext': bytes(prepared['material_ciphertext']),
            'parameters': json.dumps(prepared['parameters'], sort_keys=True, separators=(',', ':'))
                if type(prepared['parameters']) is dict else prepared['parameters']}
        expected = codec.identity(prepared)
        execute("""INSERT INTO clrs_staging.accounts
 (uid, email_normalized, email_verified, disabled, lifecycle, token_version)
 VALUES (%s, %s, 0, 0, 'active', 0)""", (uid, email))
        if cursor.rowcount != 1:
            raise NativeUnavailable()
        _empty(cursor, execute, uid)
        execute("""INSERT INTO clrs_staging.native_password_credentials
 (uid, scheme, password_version, material_ciphertext, parameters)
 VALUES (%s, %s, 0, %s, %s)""", (uid, prepared['scheme'], prepared['material_ciphertext'], prepared['parameters']))
        if cursor.rowcount != 1:
            raise NativeUnavailable()
        execute("""INSERT INTO clrs_staging.auth_identities
 (uid, provider, provider_subject, provider_email) VALUES (%s, 'password', %s, %s)""", (uid, uid, email))
        if cursor.rowcount != 1:
            raise NativeUnavailable()
        execute("""INSERT INTO clrs_staging.profiles
 (uid, full_name, profile_details_saved, registration_complete) VALUES (%s, %s, 0, 0)""", (uid, nickname))
        if cursor.rowcount != 1:
            raise NativeUnavailable()
        execute(_ACCOUNT, (uid,))
        account = cursor.fetchone()
        if (not isinstance(account, (tuple, list)) or len(account) != 7
                or tuple(account[:6]) != (uid, email, 0, 'active', 0, 0)):
            raise NativeUnavailable()
        _date(account[6])
        execute(_NATIVE, (uid,))
        native = cursor.fetchone()
        if not isinstance(native, (tuple, list)) or len(native) != 5:
            raise NativeUnavailable()
        retained = dict(zip(('uid', 'scheme', 'password_version', 'material_ciphertext', 'parameters'), native))
        if not hmac.compare_digest(expected, codec.identity(retained)):
            raise NativeUnavailable()
        execute('SELECT uid, provider, provider_subject, provider_email, legacy_raw '
                'FROM clrs_staging.auth_identities WHERE uid = %s FOR SHARE', (uid,))
        identities = cursor.fetchall()
        if (not isinstance(identities, (tuple, list)) or len(identities) != 1
                or not isinstance(identities[0], (tuple, list)) or len(identities[0]) != 5
                or tuple(identities[0][:4]) != (uid, 'password', uid, email)
                or not _empty_object(identities[0][4])):
            raise NativeUnavailable()
        execute(_PROFILE, (uid,))
        profile = cursor.fetchone()
        if (not isinstance(profile, (tuple, list)) or len(profile) != 23
                or tuple(profile[:2]) != (uid, nickname) or any(value is not None for value in profile[2:16])
                or not _empty_object(profile[16]) or type(profile[17]) is not int or profile[17] != 0
                or type(profile[18]) is not int or profile[18] != 0 or profile[19] is not None
                or profile[20] is not None or not _empty_object(profile[22])):
            raise NativeUnavailable()
        _date(profile[21])

    def lookup(self, body, *, peer):
        if type(body) is not dict:
            raise LifecycleInvalid()
        if set(body) == {'operationToken'}:
            fingerprint = self._fingerprint(body['operationToken'])
            if fingerprint.operation != OPERATION:
                raise LifecycleInvalid()
            deadline = self._deadline(peer)
        elif set(body) == {'purpose', 'stage', 'original'} and body['purpose'] == PURPOSE and body['stage'] == 'complete':
            email, fingerprint = self._bind(body['original'])
            deadline = self._deadline(peer, email)
        else:
            raise LifecycleInvalid()
        try:
            return self._result(fingerprint, self._run(
                lambda cursor, execute: self.receipts.lookup(cursor, execute, fingerprint), deadline))
        except Exception:
            return self._result(fingerprint)

    def close(self):
        pass  # Shared password pool/store lifetime belongs to NativeAuthService.
