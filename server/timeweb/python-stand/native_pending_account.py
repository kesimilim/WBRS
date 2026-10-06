"""Trusted registration SQL leaves; no HTTP, connection, KDF, mail or COMMIT.

The caller supplies a server-chosen UID and canonical email, and owns ONE
bounded SERIALIZABLE transaction, TLS/schema/role checks, keyed receipt and
rollback/unknown-COMMIT reconciliation. Use a fresh cursor and capture one
execute callable for each outer transaction. Never reuse them after COMMIT.
Request reserves only the account: password is supplied at completion.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hmac
import json
import re
import secrets
import weakref

from native_credentials import CredentialUnavailable, unique_json
from native_password_credentials import NativePasswordCodec


_ACCOUNT = """SELECT uid, email_normalized, disabled, lifecycle, token_version,
 email_verified, DATE_FORMAT(created_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f')
 FROM clrs_staging.accounts WHERE uid = %s LIMIT 1 FOR UPDATE"""
_EMPTY = """SELECT
 EXISTS(SELECT 1 FROM clrs_staging.auth_credentials WHERE uid = %s),
 EXISTS(SELECT 1 FROM clrs_staging.native_password_credentials WHERE uid = %s),
 EXISTS(SELECT 1 FROM clrs_staging.auth_identities WHERE uid = %s),
 EXISTS(SELECT 1 FROM clrs_staging.profiles WHERE uid = %s)"""
_NATIVE = """SELECT uid, scheme, password_version, material_ciphertext, parameters
 FROM clrs_staging.native_password_credentials WHERE uid = %s LIMIT 1 FOR SHARE"""
_PROFILE = """SELECT uid, full_name, age, height_cm, about_text, interests_text,
 has_children, gender, relationship_status, country, country_code, region, city,
 language_code, primary_group, secondary_group, test_result,
 profile_details_saved, registration_complete, invisible_until, last_online_at,
 DATE_FORMAT(updated_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'), legacy_raw
 FROM clrs_staging.profiles WHERE uid = %s LIMIT 1 FOR SHARE"""


@dataclass(frozen=True, repr=False)
class _PendingAccountBinding:
    uid: str
    email: str
    token_version: int
    account_created_at: str
    marker: bytes


@dataclass(frozen=True, repr=False, eq=False)
class _PendingAccountCapability:
    cursor: object
    execute: object
    binding: _PendingAccountBinding


@dataclass(frozen=True, repr=False)
class PendingRegistrationTransition:
    uid: str
    token_version: int


_pending = weakref.WeakSet()


def _date(value):
    if not isinstance(value, str) or re.fullmatch(
            r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}', value) is None:
        raise CredentialUnavailable()
    try:
        date = datetime.strptime(value, '%Y-%m-%d %H:%M:%S.%f')
        if date.year < 1000:
            raise CredentialUnavailable()
    except (ValueError, OverflowError):
        raise CredentialUnavailable() from None
    return value


def _fields(uid, email):
    try:
        if (not isinstance(uid, str) or not 1 <= len(uid) <= 191
                or len(uid.encode('utf-8')) > 764
                or any(ord(c) < 32 or ord(c) == 127 for c in uid)
                or not isinstance(email, str) or email != email.strip().lower()
                or not 3 <= len(email) <= 320 or '@' not in email
                or len(email.encode('utf-8')) > 1280
                or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in email)):
            raise CredentialUnavailable()
    except UnicodeError:
        raise CredentialUnavailable() from None


def _empty(cursor, execute, uid):
    execute(_EMPTY, (uid, uid, uid, uid))
    row = cursor.fetchone()
    if (not isinstance(row, (tuple, list)) or len(row) != 4
            or any(type(value) is not int or value != 0 for value in row)):
        raise CredentialUnavailable()


def _account(cursor, execute, uid, email, *, created=None, complete=False):
    execute(_ACCOUNT, (uid,))
    row = cursor.fetchone()
    if (not isinstance(row, (tuple, list)) or len(row) != 7
            or row[0] != uid or row[1] != email
            or type(row[2]) is not int or row[2] != (0 if complete else 1)
            or row[3] != 'active' or type(row[4]) is not int or row[4] != 0
            or type(row[5]) is not int or row[5] != (1 if complete else 0)):
        raise CredentialUnavailable()
    stamp = _date(row[6])
    if created is not None and stamp != created:
        raise CredentialUnavailable()
    return stamp


def create_pending_account(cursor, execute, *, uid, email):
    """Reserve only a new account, never adopt/overwrite an existing one.

    Initial challenge issue must consume the returned capability in this same
    transaction. It is not an API input or durable activation authority.
    """
    try:
        _fields(uid, email)
        if cursor is None or not callable(execute):
            raise CredentialUnavailable()
        execute("""SELECT uid FROM clrs_staging.accounts
 WHERE uid = %s LIMIT 1 FOR UPDATE""", (uid,))
        if cursor.fetchone() is not None:
            raise CredentialUnavailable()
        execute("""SELECT uid FROM clrs_staging.accounts
 WHERE email_normalized = %s LIMIT 1 FOR UPDATE""", (email,))
        if cursor.fetchone() is not None:
            raise CredentialUnavailable()
        execute("""INSERT INTO clrs_staging.accounts
 (uid, email_normalized, email_verified, disabled, lifecycle, token_version)
 VALUES (%s, %s, 0, 1, 'active', 0)""", (uid, email))
        if cursor.rowcount != 1:
            raise CredentialUnavailable()
        created = _account(cursor, execute, uid, email)
        _empty(cursor, execute, uid)
        binding = _PendingAccountBinding(uid, email, 0, created, secrets.token_bytes(32))
        capability = _PendingAccountCapability(cursor, execute, binding)
        _pending.add(capability)
        return capability
    except CredentialUnavailable:
        raise
    except Exception:
        raise CredentialUnavailable() from None


def validate_pending_account_capability(capability, cursor, execute):
    """One-time same-transaction initial-issue proof; locked exact readback."""
    try:
        if (type(capability) is not _PendingAccountCapability or capability not in _pending
                or capability.cursor is not cursor or capability.execute is not execute):
            raise CredentialUnavailable()
        _pending.discard(capability)
        binding = capability.binding
        _account(cursor, execute, binding.uid, binding.email, created=binding.account_created_at)
        _empty(cursor, execute, binding.uid)
        return binding
    except CredentialUnavailable:
        raise
    except Exception:
        raise CredentialUnavailable() from None


def _empty_object(value):
    if isinstance(value, (str, bytes)):
        if len(value) > 32:
            raise CredentialUnavailable()
        value = unique_json(value)
    return type(value) is dict and not value


def complete_pending_registration(cursor, execute, codec, *, consumed_challenge, prepared_row):
    """Install a new password/profile only after trusted same-TX consumption.

    Activation consumes no password/code itself and never creates a session.
    The outer caller must commit challenge, keyed receipt and these writes
    together, or roll back all of them on any refusal/error.
    """
    try:
        if not isinstance(codec, NativePasswordCodec) or not callable(execute):
            raise CredentialUnavailable()
        # Freeze exact validated ciphertext/parameters before any SQL callback.
        codec.decode(prepared_row)
        prepared_row = {**prepared_row, 'material_ciphertext': bytes(prepared_row['material_ciphertext']),
                        'parameters': json.dumps(prepared_row['parameters'], sort_keys=True,
                            separators=(',', ':'), allow_nan=False)
                        if isinstance(prepared_row['parameters'], dict) else prepared_row['parameters']}
        material = codec.decode(prepared_row)
        expected_native = codec.identity(prepared_row)
        if material.password_version != 0:
            raise CredentialUnavailable()
        # Lazy import avoids a cycle: first issue consumes our pending proof.
        from native_auth_challenges import validate_consumed_challenge_capability
        binding = validate_consumed_challenge_capability(consumed_challenge, cursor, execute)
        if (binding.purpose != 'register-email.v1' or type(binding.token_version) is not int
                or binding.token_version != 0 or binding.uid != material.uid
                or not isinstance(binding.marker, bytes) or len(binding.marker) != 32):
            raise CredentialUnavailable()
        _fields(binding.uid, binding.email)
        if type(binding.consumed_at) is not int or not 0 <= binding.consumed_at <= 2**53-601:
            raise CredentialUnavailable()
        _account(cursor, execute, binding.uid, binding.email, created=binding.account_created_at)
        _empty(cursor, execute, binding.uid)
        parameters = prepared_row['parameters']
        execute("""INSERT INTO clrs_staging.native_password_credentials
 (uid, scheme, password_version, material_ciphertext, parameters)
 VALUES (%s, %s, 0, %s, %s)""", (binding.uid, prepared_row['scheme'],
            prepared_row['material_ciphertext'], parameters))
        if cursor.rowcount != 1:
            raise CredentialUnavailable()
        execute("""INSERT INTO clrs_staging.auth_identities
 (uid, provider, provider_subject, provider_email) VALUES (%s, 'password', %s, %s)""",
            (binding.uid, binding.uid, binding.email))
        if cursor.rowcount != 1:
            raise CredentialUnavailable()
        execute("""INSERT INTO clrs_staging.profiles
 (uid, profile_details_saved, registration_complete) VALUES (%s, 0, 0)""", (binding.uid,))
        if cursor.rowcount != 1:
            raise CredentialUnavailable()
        execute(_NATIVE, (binding.uid,))
        retained = cursor.fetchone()
        if not isinstance(retained, (tuple, list)) or len(retained) != 5:
            raise CredentialUnavailable()
        retained = dict(zip(['uid', 'scheme', 'password_version', 'material_ciphertext', 'parameters'], retained))
        if not hmac.compare_digest(expected_native, codec.identity(retained)):
            raise CredentialUnavailable()
        execute("""SELECT uid, provider, provider_subject, provider_email, legacy_raw
 FROM clrs_staging.auth_identities WHERE uid = %s FOR SHARE""", (binding.uid,))
        identities = cursor.fetchall()
        if (not isinstance(identities, (tuple, list)) or len(identities) != 1
                or not isinstance(identities[0], (tuple, list)) or len(identities[0]) != 5
                or tuple(identities[0][:4]) != (binding.uid, 'password', binding.uid, binding.email)
                or not _empty_object(identities[0][4])):
            raise CredentialUnavailable()
        execute(_PROFILE, (binding.uid,))
        profile = cursor.fetchone()
        if (not isinstance(profile, (tuple, list)) or len(profile) != 23 or profile[0] != binding.uid
                or any(value is not None for value in profile[1:16])
                or not _empty_object(profile[16])
                or type(profile[17]) is not int or profile[17] != 0
                or type(profile[18]) is not int or profile[18] != 0
                or profile[19] is not None or profile[20] is not None
                or not _empty_object(profile[22])):
            raise CredentialUnavailable()
        _date(profile[21])
        execute("""UPDATE clrs_staging.accounts SET email_verified = 1, disabled = 0,
 updated_at = UTC_TIMESTAMP(6) WHERE uid = %s AND email_normalized = %s
 AND email_verified = 0 AND disabled = 1 AND lifecycle = 'active' AND token_version = 0
 AND created_at = %s""", (binding.uid, binding.email, binding.account_created_at))
        if cursor.rowcount != 1:
            raise CredentialUnavailable()
        _account(cursor, execute, binding.uid, binding.email,
                 created=binding.account_created_at, complete=True)
        return PendingRegistrationTransition(binding.uid, 0)
    except CredentialUnavailable:
        raise
    except Exception:
        raise CredentialUnavailable() from None
