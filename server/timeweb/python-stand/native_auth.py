"""Default-off framework-neutral native login/session service.

HTTP routes are integrated separately. New registration/password-reset and
provider sign-in are intentionally separate gates; no Firebase mutation here.
"""
from __future__ import annotations

import hmac
import os
import re
import threading
import time

from native_credentials import (CredentialCodec, CredentialUnavailable,
                                FirebaseScryptVerifier, decode_base64, unique_json)
from native_sessions import NativeSessionStore, SessionTokens, SessionRejected, SessionUnavailable
from native_password_credentials import NativePasswordCodec, PasswordWorkPool

MAX_BODY_BYTES = 8192
REQUEST_BUDGET_SECONDS = 8


class NativeRejected(Exception):
    """Generic 401; never reveal whether the email/account exists."""


class NativeUnavailable(Exception):
    """Generic 503; do not expose DB/KDF/configuration details."""


class NativeRateLimited(Exception):
    """Generic 429, with a fixed 60-second retry window."""


def _utf8(value):
    if not isinstance(value, str):
        raise NativeRejected()
    try:
        return value.encode("utf-8")
    except UnicodeError:
        raise NativeRejected() from None


def parse_login_body(raw):
    if not isinstance(raw, bytes) or len(raw) > MAX_BODY_BYTES:
        raise NativeRejected()
    try:
        result = unique_json(raw.decode("utf-8"))
    except (CredentialUnavailable, UnicodeError):
        raise NativeRejected() from None
    if set(result) != {"email", "password", "deviceId"}:
        raise NativeRejected()
    return result


def _login_fields(body):
    if not isinstance(body, dict) or set(body) != {"email", "password", "deviceId"}:
        raise NativeRejected()
    email = body["email"]; password = body["password"]; device = body["deviceId"]
    if (not isinstance(email, str) or not 1 <= len(email) <= 320 or len(_utf8(email)) > 1280
            or not isinstance(password, str) or len(_utf8(password)) > 4096
            or not isinstance(device, str) or re.fullmatch(r"[A-Za-z0-9._:-]{1,191}", device) is None):
        raise NativeRejected()
    email = email.strip().lower()
    if "@" not in email or "\0" in email or any(char.isspace() for char in email):
        raise NativeRejected()
    return email, password, device


class BoundedRateLimiter:
    """Per-process, fixed-window state; identity keys are HMAC, never email."""
    def __init__(self, key, *, clock=time.monotonic, capacity=4096):
        if not isinstance(key, bytes) or len(key) != 32 or not 1 <= capacity <= 4096:
            raise NativeUnavailable()
        self._key = key; self._clock = clock; self._capacity = capacity
        self._entries = {}; self._lock = threading.Lock()

    def consume(self, kind, value, limit):
        if not isinstance(value, str) or not value or len(_utf8(value)) > 1280:
            raise NativeRejected()
        identity = hmac.digest(self._key, kind.encode() + b"\0" + _utf8(value), "sha256")
        now = self._clock()
        with self._lock:
            expired = [key for key, (_, until) in self._entries.items() if now >= until]
            for key in expired:
                del self._entries[key]
            count, until = self._entries.get(identity, (0, now + 60))
            if count >= limit or (identity not in self._entries and len(self._entries) >= self._capacity):
                raise NativeRateLimited()
            self._entries[identity] = (count + 1, until)


class NativeAuthService:
    def __init__(self, env, store, verifier, limiter, *, monotonic=time.monotonic):
        self._env = env; self.store = store; self.verifier = verifier; self.limiter = limiter
        self._monotonic = monotonic

    @classmethod
    def from_env(cls, env=None, *, connect=None):
        env = os.environ if env is None else env
        if (env.get("CLRS_NATIVE_AUTH_ENABLED") != "1"
                or env.get("CLRS_NATIVE_AUTH_WRITES_ENABLED") != "1"):
            return None
        verifier = None
        try:
            raw_config = env.get("CLRS_NATIVE_SCRYPT_CONFIG_JSON", "")
            if not isinstance(raw_config, str) or len(raw_config.encode()) > 4096:
                raise CredentialUnavailable()
            hash_config = unique_json(raw_config)
            wrapping = decode_base64(env.get("CLRS_NATIVE_CREDENTIAL_WRAPPING_KEY_B64"), max_bytes=32)
            session_key = decode_base64(env.get("CLRS_NATIVE_SESSION_KEY_B64"), max_bytes=32)
            if len(wrapping) != 32 or len(session_key) != 32 or hmac.compare_digest(wrapping, session_key):
                raise CredentialUnavailable()
            codec = CredentialCodec(hash_config, env.get("CLRS_NATIVE_CREDENTIAL_CONFIG_REF"), wrapping)
            tokens = SessionTokens(session_key)
            password_flag = env.get("CLRS_NATIVE_PASSWORD_ENABLED")
            if password_flag not in (None, "0", "1"):
                raise CredentialUnavailable()
            selector = None
            if password_flag == "1":
                verifier = PasswordWorkPool(codec, NativePasswordCodec(wrapping))
                selector = verifier
            else:
                verifier = FirebaseScryptVerifier(codec)
            store = NativeSessionStore(env, codec, tokens, connect=connect, password_selector=selector)
            return cls(env, store, verifier, BoundedRateLimiter(session_key))
        except Exception:
            if verifier is not None:
                verifier.close()
            raise NativeUnavailable() from None

    def _deadline(self, peer, *, login=False):
        if (self._env.get("CLRS_NATIVE_AUTH_ENABLED") != "1"
                or self._env.get("CLRS_NATIVE_AUTH_WRITES_ENABLED") != "1"):
            raise NativeUnavailable()
        # peer is supplied by the server's trusted socket/proxy integration,
        # never read from a user-supplied request JSON/X-Forwarded-For here.
        if not isinstance(peer, str) or not 1 <= len(peer) <= 253 or "\0" in peer:
            raise NativeRejected()
        self.limiter.consume("login-peer" if login else "session-peer", peer, 10 if login else 120)
        return self._monotonic() + REQUEST_BUDGET_SECONDS

    def login(self, body, *, peer):
        deadline = self._deadline(peer, login=True)
        email, password, device = _login_fields(body)
        self.limiter.consume("login-email", email, 5)
        try:
            snapshot = self.store.read_login(email, deadline=deadline)
            material = snapshot.credential if snapshot is not None else self.store.codec.dummy()
            remaining = min(1.5, deadline - self._monotonic())
            if remaining <= 0:
                raise NativeUnavailable()
            valid = self.verifier.verify(material, password, timeout=remaining)
            if snapshot is None or not valid:
                raise NativeRejected()
            if self._monotonic() >= deadline:
                raise NativeUnavailable()
            return self.store.issue(snapshot, device, deadline=deadline)
        except SessionRejected:
            raise NativeRejected() from None
        except (SessionUnavailable, CredentialUnavailable):
            raise NativeUnavailable() from None

    def authorize(self, access_token, *, peer):
        deadline = self._deadline(peer)
        try:
            return self.store.authorize(access_token, deadline=deadline)
        except SessionRejected:
            raise NativeRejected() from None
        except SessionUnavailable:
            raise NativeUnavailable() from None

    def refresh(self, refresh_token, *, peer):
        deadline = self._deadline(peer)
        try:
            return self.store.refresh(refresh_token, deadline=deadline)
        except SessionRejected:
            raise NativeRejected() from None
        except SessionUnavailable:
            raise NativeUnavailable() from None

    def logout(self, access_token, *, peer, all_sessions=False):
        deadline = self._deadline(peer)
        try:
            return self.store.logout(access_token, all_sessions=all_sessions, deadline=deadline)
        except SessionRejected:
            raise NativeRejected() from None
        except SessionUnavailable:
            raise NativeUnavailable() from None

    def close(self):
        self.verifier.close()
