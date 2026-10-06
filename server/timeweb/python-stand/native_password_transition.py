"""Trusted reset SQL step only; no route, connection, commit or delivery.

The future lifecycle caller must first validate a current single-use email
challenge, bind its UID/email/token version, and use one bounded SERIALIZABLE
transaction for this step, challenge consumption and a keyed sensitive receipt.
Do not use the generic runtime original-payload receipt for passwords/codes.
"""
from dataclasses import dataclass
import hmac
import json

from native_credentials import CredentialUnavailable
from native_password_credentials import NativePasswordCodec, MAX_VERSION


@dataclass(frozen=True, repr=False)
class PasswordResetTransition:
    uid: str
    password_version: int
    imported_verifier_retired: bool


def apply_prepared_reset(cursor, execute, codec, *, uid, email,
                         expected_token_version, prepared_row):
    """Apply after trusted challenge eligibility; caller owns rollback/COMMIT.

    The function never accepts a password/code or begins another transaction.
    Every SQL statement must go through the caller's deadline/statement cap.
    A timeout/unknown COMMIT must be reconciled using that caller's receipt;
    neither this leaf nor a client may automatically repeat the reset.
    """
    if (not isinstance(codec, NativePasswordCodec) or not callable(execute)
            or type(expected_token_version) is not int
            or not 0 <= expected_token_version < MAX_VERSION
            or not isinstance(email, str) or email != email.strip().lower()
            or not 3 <= len(email) <= 320 or '@' not in email
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in email)):
        raise CredentialUnavailable()
    material = codec.decode(prepared_row)
    next_version = expected_token_version + 1
    if material.uid != uid or material.password_version != next_version:
        raise CredentialUnavailable()
    try:
        if len(email.encode('utf-8')) > 1280:
            raise CredentialUnavailable()
    except UnicodeError:
        raise CredentialUnavailable() from None

    # All password/reset operations must acquire the account first. A changed
    # challenge-bound email/version or current block cannot be overwritten.
    execute("""SELECT uid, email_normalized, disabled, lifecycle, token_version
      FROM clrs_staging.accounts WHERE uid = %s LIMIT 1 FOR UPDATE""", (uid,))
    account = cursor.fetchone()
    if (account is None or len(account) != 5 or account[0] != uid
            or account[1] != email or type(account[2]) is not int or account[2] != 0
            or account[3] != 'active' or type(account[4]) is not int
            or account[4] != expected_token_version):
        raise CredentialUnavailable()

    execute("""SELECT uid FROM clrs_staging.native_password_credentials
      WHERE uid = %s LIMIT 1 FOR UPDATE""", (uid,))
    existing = cursor.fetchone()
    if existing is not None and (len(existing) != 1 or existing[0] != uid):
        raise CredentialUnavailable()
    parameters = json.dumps(prepared_row['parameters'], sort_keys=True,
                            separators=(',', ':'), allow_nan=False)
    if existing is None:
        execute("""INSERT INTO clrs_staging.native_password_credentials
          (uid, scheme, password_version, material_ciphertext, parameters)
          VALUES (%s, %s, %s, %s, %s)""",
          (uid, prepared_row['scheme'], next_version, prepared_row['material_ciphertext'], parameters))
    else:
        execute("""UPDATE clrs_staging.native_password_credentials
          SET scheme = %s, password_version = %s, material_ciphertext = %s,
              parameters = %s, updated_at = UTC_TIMESTAMP(6) WHERE uid = %s""",
          (prepared_row['scheme'], next_version, prepared_row['material_ciphertext'], parameters, uid))
    if cursor.rowcount != 1:
        raise CredentialUnavailable()

    # Retirement also protects a cold restart/old binary that can only read
    # auth_credentials: it must never restore the old Firebase password.
    # Preserve uid, imported_at, parameters and the immutable source archive.
    execute("""UPDATE clrs_staging.auth_credentials SET scheme = 'bridge_only',
      password_hash = NULL, password_salt = NULL WHERE uid = %s""", (uid,))
    if cursor.rowcount not in (0, 1):
        raise CredentialUnavailable()
    execute("""SELECT uid, scheme, password_hash, password_salt
      FROM clrs_staging.auth_credentials WHERE uid = %s LIMIT 1 FOR SHARE""", (uid,))
    imported = cursor.fetchone()
    if imported is not None and imported != (uid, 'bridge_only', None, None):
        raise CredentialUnavailable()

    execute("""UPDATE clrs_staging.accounts SET token_version = %s,
      updated_at = UTC_TIMESTAMP(6) WHERE uid = %s AND email_normalized = %s
      AND disabled = 0 AND lifecycle = 'active' AND token_version = %s""",
      (next_version, uid, email, expected_token_version))
    if cursor.rowcount != 1:
        raise CredentialUnavailable()
    execute("""UPDATE clrs_staging.device_sessions SET revoked_at = UTC_TIMESTAMP(6)
      WHERE uid = %s AND revoked_at IS NULL""", (uid,))

    execute("""SELECT uid, scheme, password_version, material_ciphertext, parameters
      FROM clrs_staging.native_password_credentials WHERE uid = %s LIMIT 1 FOR SHARE""", (uid,))
    retained = cursor.fetchone()
    if retained is None or len(retained) != 5:
        raise CredentialUnavailable()
    retained = dict(zip(['uid', 'scheme', 'password_version', 'material_ciphertext', 'parameters'], retained))
    if not hmac.compare_digest(codec.identity(prepared_row), codec.identity(retained)):
        raise CredentialUnavailable()
    execute("""SELECT uid, email_normalized, disabled, lifecycle, token_version
      FROM clrs_staging.accounts WHERE uid = %s LIMIT 1 FOR SHARE""", (uid,))
    if cursor.fetchone() != (uid, email, 0, 'active', next_version):
        raise CredentialUnavailable()
    execute("""SELECT COUNT(*) FROM clrs_staging.device_sessions
      WHERE uid = %s AND revoked_at IS NULL""", (uid,))
    if cursor.fetchone() != (0,):
        raise CredentialUnavailable()
    return PasswordResetTransition(uid, next_version, imported is not None)
