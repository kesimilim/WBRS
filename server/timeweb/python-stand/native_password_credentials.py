"""Prepared native password/challenge codecs; no DB, SMTP, HTTP or session writes.

One PasswordWorkPool performs BOTH imported Firebase and native password work.
Native-row presence is authoritative, including an invalid row: never fallback.
The caller must re-lock the current account and exact selected ciphertext after
KDF before issuing a session or committing a password lifecycle transition.
"""
from __future__ import annotations

from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass
import hashlib
import hmac
import json
import math
import re
import secrets
import threading
import time
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from native_credentials import (CredentialCodec, CredentialMaterial, CredentialUnavailable,
    FirebaseScryptVerifier, KdfBusy, MEMORY_LIMIT, credential_row_identity, unique_json)

SCHEME = "clrs_scrypt_v1"
N, R, P, DKLEN, SALT_BYTES = 32768, 8, 3, 32, 16
MAX_VERSION = 2 ** 63 - 1
MAX_PASSWORD_BYTES = 4096
PARAMETERS = {"material_format": "aes256gcm-native-v1", "n": N, "r": R,
    "p": P, "dklen": DKLEN, "maxmem": MEMORY_LIMIT, "salt_bytes": SALT_BYTES}
ROW_FIELDS = {"uid", "scheme", "password_version", "material_ciphertext", "parameters"}
PURPOSES = {"register-email.v1", "password-reset.v1"}


def _json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"), allow_nan=False).encode("utf-8")


def _uid(value):
    if (not isinstance(value, str) or not 1 <= len(value) <= 191
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise CredentialUnavailable()
    try:
        if len(value.encode("utf-8")) > 764:
            raise CredentialUnavailable()
    except UnicodeError:
        raise CredentialUnavailable() from None
    return value


def _version(value):
    if type(value) is not int or not 0 <= value <= MAX_VERSION:
        raise CredentialUnavailable()
    return value


def _password(value, *, creating=False):
    try:
        raw = value.encode("utf-8") if isinstance(value, str) else None
    except UnicodeError:
        raise CredentialUnavailable() from None
    # No trimming, normalization or new-policy restriction on old passwords.
    # The future registration API must supply its reviewed minimum policy.
    if raw is None or len(raw) > MAX_PASSWORD_BYTES or (creating and not raw):
        raise CredentialUnavailable()
    return raw


@dataclass(frozen=True, repr=False)
class NativePasswordMaterial:
    uid: str
    password_version: int
    salt: bytes
    password_hash: bytes


@dataclass(frozen=True, repr=False)
class SelectedPassword:
    uid: str
    account_token_version: int
    scheme: str
    ciphertext_identity: bytes
    material: CredentialMaterial | NativePasswordMaterial


def revalidate_selection(original, current):
    """Call with the freshly decoded LOCKED account/credential after KDF.

    This check alone is not SQL authority: the session INSERT must be in that
    same transaction, after account lifecycle/disabled checks, not afterward.
    """
    if (type(original) is not SelectedPassword or type(current) is not SelectedPassword
            or original.uid != current.uid or original.scheme != current.scheme
            or original.account_token_version != current.account_token_version
            or not isinstance(original.ciphertext_identity, bytes) or len(original.ciphertext_identity) != 32
            or not isinstance(current.ciphertext_identity, bytes) or len(current.ciphertext_identity) != 32
            or not hmac.compare_digest(original.ciphertext_identity, current.ciphertext_identity)):
        raise CredentialUnavailable()


class NativePasswordCodec:
    def __init__(self, wrapping_key):
        if not isinstance(wrapping_key, bytes) or len(wrapping_key) != 32:
            raise CredentialUnavailable()
        # Reuse the server-only master key through a distinct cryptographic
        # domain; this is not the imported Firebase ciphertext key itself.
        self._key = hmac.digest(wrapping_key, b"CLRS native-password wrapping v1", "sha256")

    @staticmethod
    def _aad(uid, version, parameters):
        return _json(["clrs_staging", "native_password_credentials", _uid(uid),
                      SCHEME, _version(version), parameters])

    def seal(self, uid, version, salt, password_hash):
        _uid(uid); _version(version)
        if (not isinstance(salt, bytes) or len(salt) != SALT_BYTES
                or not isinstance(password_hash, bytes) or len(password_hash) != DKLEN):
            raise CredentialUnavailable()
        nonce = secrets.token_bytes(12)
        plain = b"NSP1" + salt + password_hash
        cipher = AESGCM(self._key).encrypt(nonce, plain, self._aad(uid, version, PARAMETERS))
        # Native layout nonce + ciphertext + tag, deliberately versioned and
        # distinct from the imported Node hash/salt envelope.
        return {"uid": uid, "scheme": SCHEME, "password_version": version,
                "material_ciphertext": nonce + cipher, "parameters": dict(PARAMETERS)}

    def decode(self, row):
        try:
            if type(row) is not dict or set(row) != ROW_FIELDS or row["scheme"] != SCHEME:
                raise CredentialUnavailable()
            uid, version = _uid(row["uid"]), _version(row["password_version"])
            params = row["parameters"]
            if isinstance(params, (str, bytes)):
                params = unique_json(params)
            # Equality alone would accept True == 1; enforce exact JSON types.
            if (type(params) is not dict or set(params) != set(PARAMETERS)
                    or any(type(params[k]) is not type(v) or params[k] != v
                           for k, v in PARAMETERS.items())):
                raise CredentialUnavailable()
            blob = row["material_ciphertext"]
            if not isinstance(blob, (bytes, bytearray, memoryview)) or len(blob) != 80:
                raise CredentialUnavailable()
            blob = bytes(blob)
            plain = AESGCM(self._key).decrypt(blob[:12], blob[12:], self._aad(uid, version, params))
            if len(plain) != 52 or plain[:4] != b"NSP1":
                raise CredentialUnavailable()
            return NativePasswordMaterial(uid, version, plain[4:20], plain[20:])
        except CredentialUnavailable:
            raise
        except Exception:
            raise CredentialUnavailable() from None

    def identity(self, row):
        # Validate before producing an identity used in the post-KDF recheck.
        self.decode(row)
        return hashlib.sha256(_json([row["uid"], row["scheme"], row["password_version"],
            bytes(row["material_ciphertext"]).hex(), PARAMETERS])).digest()


class PasswordWorkPool(FirebaseScryptVerifier):
    """One actual <=2-worker pool for new, changed AND old Firebase passwords.

    Reuses the existing published-vector Firebase implementation unchanged;
    do not run a separate FirebaseScryptVerifier beside this pool at runtime.
    """
    def __init__(self, firebase_codec, native_codec, *, workers=2, derive=hashlib.scrypt,
                 monotonic=time.monotonic):
        if not isinstance(native_codec, NativePasswordCodec) or not callable(monotonic):
            raise CredentialUnavailable()
        super().__init__(firebase_codec, workers=workers, derive=derive)
        self.native_codec = native_codec
        self._clock = monotonic
        self._lifecycle = threading.Lock()

    def select(self, *, uid, account_token_version, firebase_row=None, native_row=None):
        uid, version = _uid(uid), _version(account_token_version)
        if native_row is not None:
            material = self.native_codec.decode(native_row)
            if material.uid != uid or material.password_version > version:
                raise CredentialUnavailable()
            identity = self.native_codec.identity(native_row)
            return SelectedPassword(uid, version, SCHEME, identity, material)
        if firebase_row is None:
            raise CredentialUnavailable()
        material = self.codec.decode(firebase_row)
        if material.uid != uid:
            raise CredentialUnavailable()
        return SelectedPassword(uid, version, "firebase_scrypt",
                                credential_row_identity(firebase_row), material)

    def _verify(self, material, password_bytes):
        if type(material) is NativePasswordMaterial:
            _uid(material.uid); _version(material.password_version)
            if (not isinstance(material.salt, bytes) or len(material.salt) != SALT_BYTES
                    or not isinstance(material.password_hash, bytes) or len(material.password_hash) != DKLEN):
                raise CredentialUnavailable()
            generated = self._derive(password_bytes, salt=material.salt, n=N, r=R,
                                     p=P, dklen=DKLEN, maxmem=MEMORY_LIMIT)
            return hmac.compare_digest(generated, material.password_hash)
        return super()._verify(material, password_bytes)

    def _run(self, function, args, timeout):
        if (type(timeout) not in (int, float) or not math.isfinite(timeout)
                or not 0 < timeout <= 1.5):
            raise CredentialUnavailable()
        deadline = self._clock() + timeout
        with self._lifecycle:
            if self._closed:
                raise CredentialUnavailable()
            if not self._slots.acquire(blocking=False):
                raise KdfBusy()
            try:
                future = self._pool.submit(function, *args)
            except Exception:
                self._slots.release()
                raise CredentialUnavailable() from None
            future.add_done_callback(lambda _: self._slots.release())
        try:
            remaining = deadline - self._clock()
            if remaining <= 0:
                raise CredentialUnavailable()
            result = future.result(timeout=remaining)
            with self._lifecycle:
                if self._closed or self._clock() >= deadline:
                    raise CredentialUnavailable()
            return result
        except (FutureTimeout, Exception):
            # Do not cancel/adopt a late result or release its actual KDF slot.
            raise CredentialUnavailable() from None

    def verify(self, material, password, *, timeout=1.5):
        if not isinstance(material, (CredentialMaterial, NativePasswordMaterial)):
            raise CredentialUnavailable()
        raw = _password(password)
        if isinstance(material, CredentialMaterial) and material.disabled:
            return False
        return self._run(self._verify, (material, raw), timeout)

    def prepare(self, uid, password_version, password, *, timeout=1.5):
        uid, version, raw = _uid(uid), _version(password_version), _password(password, creating=True)

        def work():
            salt = secrets.token_bytes(SALT_BYTES)
            generated = self._derive(raw, salt=salt, n=N, r=R, p=P,
                                     dklen=DKLEN, maxmem=MEMORY_LIMIT)
            return self.native_codec.seal(uid, version, salt, generated)
        return self._run(work, (), timeout)

    def close(self):
        with self._lifecycle:
            self._closed = True
            self._pool.shutdown(wait=False, cancel_futures=True)


def advance_issuance_history(history, now):
    """Pure helper for a LOCKED persistent (uid,purpose) row, not a DB throttle.

    Keep the resulting history across challenge-ID replacement/consumption.
    Exactly five issues per rolling hour and at least60 seconds between issues.
    Future SQL must obtain one database UTC time, never client-provided time.
    """
    if (type(now) is not int or not 0 <= now <= 2 ** 53 - 1 or type(history) is not list
            or len(history) > 5 or any(type(x) is not int or not 0 <= x <= now for x in history)
            or any(history[i] >= history[i + 1] or history[i + 1] - history[i] < 60
                   for i in range(len(history) - 1))):
        raise CredentialUnavailable()
    if history and now - history[-1] < 60:
        raise CredentialUnavailable()
    recent = [x for x in history if now - x < 3600]
    if len(recent) >= 5:
        raise CredentialUnavailable()
    return recent + [now]


class AuthChallengeCodec:
    """Keyed challenge digest only; single-use/attempts require future locked SQL.

    No code/recipient is persisted or emitted by this codec. Mail intent must
    be separately AEAD-encrypted in outbox; it must not contain plain codes.
    """
    def __init__(self, session_key):
        if not isinstance(session_key, bytes) or len(session_key) != 32:
            raise CredentialUnavailable()
        self._key = hmac.digest(session_key, b"CLRS auth challenge digest v1", "sha256")
        self._email_key = hmac.digest(session_key, b"CLRS auth challenge email v1", "sha256")

    def email_identity(self, email):
        # Same canonical form as the existing native login. Do not silently
        # change email equivalence during a password migration.
        if not isinstance(email, str) or email != email.strip().lower() or not 3 <= len(email) <= 320:
            raise CredentialUnavailable()
        try:
            raw = email.encode("utf-8")
        except UnicodeError:
            raise CredentialUnavailable() from None
        if "@" not in email or len(raw) > 1280 or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in email):
            raise CredentialUnavailable()
        return hmac.digest(self._email_key, raw, "sha256")

    def digest(self, *, uid, email, purpose, challenge_id, account_token_version,
               issued_at, expires_at, code):
        _uid(uid); _version(account_token_version)
        try:
            identifier = uuid.UUID(challenge_id)
        except (ValueError, TypeError, AttributeError):
            raise CredentialUnavailable() from None
        if (str(identifier) != challenge_id or identifier.version != 4
                or not isinstance(purpose, str) or purpose not in PURPOSES
                or type(issued_at) is not int or type(expires_at) is not int
                or not 0 <= issued_at <= 2 ** 53 - 601 or expires_at != issued_at + 600
                or not isinstance(code, str) or re.fullmatch(r"[0-9]{6}", code) is None):
            raise CredentialUnavailable()
        data = ["clrs_staging", "native_auth_challenges", uid, self.email_identity(email).hex(),
                purpose, challenge_id, account_token_version, issued_at, expires_at, code]
        return hmac.digest(self._key, _json(data), "sha256")

    def verify(self, expected, *, now, attempts, consumed, **binding):
        if (not isinstance(expected, bytes) or len(expected) != 32 or type(now) is not int
                or type(attempts) is not int or not 0 <= attempts <= 5 or type(consumed) is not bool):
            raise CredentialUnavailable()
        generated = self.digest(**binding)
        eligible = (not consumed and attempts < 5 and binding["issued_at"] <= now < binding["expires_at"])
        return hmac.compare_digest(generated, expected) and eligible
