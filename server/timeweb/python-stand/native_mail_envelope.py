"""Prepared encrypted challenge email payload, never a delivery authorization.

The future outbox caller must commit this envelope alongside its locked current
challenge and digest-only receipt. A worker must revalidate current account,
challenge ID, version, expiry and consumption before durably starting delivery.
Opened recipient/email HMAC and code HMAC must also match that current SQL row;
AEAD validity alone never proves current delivery eligibility.
This module opens no connection, installs no route and sends no email.
"""
from __future__ import annotations

import base64
import hmac
import json
import secrets

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from native_credentials import unique_json
from native_mail import NativeMailIntent, MailInvalid, MailUnavailable


_FIELDS = frozenset({'version', 'uid', 'purpose', 'deliveryId',
                     'issuedAt', 'expiresAt', 'ciphertext'})
_METADATA = _FIELDS - {'ciphertext'}
_PURPOSES = {'register-email.v1': 'verify-email',
             'password-reset.v1': 'reset-password'}


def _canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'), allow_nan=False).encode('utf-8')


def _uid(value):
    if (not isinstance(value, str) or not 1 <= len(value) <= 191
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise MailInvalid()
    try:
        if len(value.encode('utf-8')) > 764:
            raise MailInvalid()
    except UnicodeError:
        raise MailInvalid() from None
    return value


def _metadata(uid, purpose, delivery_id, issued_at, expires_at):
    if (not isinstance(purpose, str) or purpose not in _PURPOSES or type(issued_at) is not int
            or type(expires_at) is not int
            or not 0 <= issued_at <= 2 ** 63 - 601
            or expires_at != issued_at + 600):
        raise MailInvalid()
    # Reuse the fixed transport's exact UUID, purpose and body validation.
    NativeMailIntent('probe@example.invalid', _PURPOSES[purpose],
                     '000000', delivery_id).message()
    return {'version': 'clrs-auth-mail-aead.v1', 'uid': _uid(uid),
            'purpose': purpose, 'deliveryId': delivery_id,
            'issuedAt': issued_at, 'expiresAt': expires_at}


class NativeMailEnvelope:
    def __init__(self, server_key):
        if type(server_key) is not bytes or len(server_key) != 32:
            raise MailUnavailable()
        self._key = hmac.digest(server_key, b'CLRS native-mail outbox wrapping v1', 'sha256')

    @staticmethod
    def _aad(metadata):
        return _canonical(['clrs_staging', 'outbox', 'auth-mail.v1', metadata])

    def seal(self, *, uid, purpose, intent, issued_at, expires_at):
        if type(intent) is not NativeMailIntent:
            raise MailInvalid()
        metadata = _metadata(uid, purpose, intent.delivery_id, issued_at, expires_at)
        if intent.purpose != _PURPOSES[purpose]:
            raise MailInvalid()
        intent.message()
        plain = _canonical({'recipient': intent.recipient, 'code': intent.code})
        nonce = secrets.token_bytes(12)
        cipher = nonce + AESGCM(self._key).encrypt(nonce, plain, self._aad(metadata))
        return {**metadata, 'ciphertext': base64.b64encode(cipher).decode('ascii')}

    def open(self, envelope, *, uid, purpose, delivery_id, now):
        """Decrypt only after caller has proved current SQL delivery eligibility.

        `now` must be the bounded worker's trusted database UTC time. Expired,
        replaced, cross-account/purpose or corrupt envelopes are refused. This
        check does not establish that the SQL challenge is still current.
        """
        try:
            if type(envelope) is not dict or set(envelope) != _FIELDS:
                raise MailInvalid()
            metadata = _metadata(uid, purpose, delivery_id,
                                 envelope['issuedAt'], envelope['expiresAt'])
            if any(envelope[k] != metadata[k] for k in _METADATA):
                raise MailInvalid()
            if (type(now) is not int or not metadata['issuedAt'] <= now < metadata['expiresAt']
                    or not isinstance(envelope['ciphertext'], str)
                    or not 60 <= len(envelope['ciphertext']) <= 4096):
                raise MailInvalid()
            cipher = base64.b64decode(envelope['ciphertext'], validate=True)
            if (not 44 <= len(cipher) <= 3072
                    or base64.b64encode(cipher).decode('ascii') != envelope['ciphertext']):
                raise MailInvalid()
            plain = AESGCM(self._key).decrypt(cipher[:12], cipher[12:], self._aad(metadata))
            fields = unique_json(plain.decode('utf-8'))
            if type(fields) is not dict or set(fields) != {'recipient', 'code'}:
                raise MailInvalid()
            intent = NativeMailIntent(fields['recipient'], _PURPOSES[purpose],
                                      fields['code'], delivery_id)
            intent.message()
            return intent
        except Exception:
            raise MailUnavailable() from None
