"""Opaque native sessions in the existing clrs_staging.device_sessions table.

Default-off private role; no DDL, Firebase call or global account change. Token
values never enter SQL. An uncertain COMMIT is never retried automatically.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
import os
import re
import secrets
import struct
import time
import base64

from native_credentials import (CredentialCodec, CredentialMaterial, CredentialUnavailable,
                                compact_json, credential_row_identity)
from profile_store import _database_config, DatabaseUnavailable, BUNDLED_CA_FILE


class SessionRejected(Exception):
    pass


class SessionUnavailable(Exception):
    pass


@dataclass(frozen=True, repr=False)
class LoginSnapshot:
    uid: str
    token_version: int
    email_verified: bool
    credential: object
    credential_identity: bytes


@dataclass(frozen=True)
class NativeIdentity:
    uid: str
    email_verified: bool
    session_id: str
    issued_at: int
    expires_at: int


def _b64(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _part(value, size):
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]+", value) is None:
        raise SessionRejected()
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except ValueError:
        raise SessionRejected() from None
    if len(raw) != size or _b64(raw) != value:
        raise SessionRejected()
    return raw


def _parse(token, prefix):
    if not isinstance(token, str) or len(token) > 128:
        raise SessionRejected()
    parts = token.split(".")
    if len(parts) != 3 or parts[0] != prefix:
        raise SessionRejected()
    _part(parts[1], 24)
    return parts[1], _part(parts[2], 32)


def _date(value):
    if not isinstance(value, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}", value) is None:
        raise SessionUnavailable()
    try:
        return int(datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=timezone.utc).timestamp())
    except (ValueError, OverflowError):
        raise SessionUnavailable() from None


def _timestamp(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%d %H:%M:%S.000000")


class SessionTokens:
    ACCESS_TTL = 900
    REFRESH_TTL = 14 * 24 * 60 * 60

    def __init__(self, key, *, random_bytes=secrets.token_bytes):
        if not isinstance(key, bytes) or len(key) != 32:
            raise SessionUnavailable()
        self._key = key
        self._random = random_bytes

    def _metadata(self, row):
        envelope = row["refresh_token_hash"]
        if not isinstance(envelope, (bytes, bytearray, memoryview)) or len(envelope) != 52:
            raise SessionUnavailable()
        envelope = bytes(envelope)
        if envelope[:4] != b"NS1\0":
            raise SessionUnavailable()
        version, access_expires = struct.unpack(">QQ", envelope[4:20])
        issued = _date(row["issued_at"])
        expires = _date(row["expires_at"])
        if (version > 2 ** 63 - 1 or not issued < access_expires <= issued + self.ACCESS_TTL
                or not access_expires <= expires <= issued + self.REFRESH_TTL):
            raise SessionUnavailable()
        return envelope, version, access_expires, issued, expires

    def _binding(self, row, *, access):
        envelope, _, _, _, _ = self._metadata(row)
        return compact_json([row["session_id"], row["uid"], row["device_id"], row["issued_at"],
            row["expires_at"], row["rotated_from"], (envelope if access else envelope[:20]).hex()]).encode()

    def _mac(self, row, *, access, refresh_secret=b""):
        domain = b"clrs-native-access-v1\0" if access else b"clrs-native-refresh-v1\0"
        return hmac.digest(self._key, domain + self._binding(row, access=access) + b"\0" + refresh_secret, "sha256")

    def mint(self, uid, device_id, version, now, *, rotated_from=None):
        if (type(version) is not int or not 0 <= version <= 2 ** 63 - 1 or type(now) is not int
                or not isinstance(uid, str) or not 1 <= len(uid) <= 191
                or not isinstance(device_id, str) or not 1 <= len(device_id) <= 191
                or "\0" in uid or "\0" in device_id):
            raise SessionUnavailable()
        session_bytes = self._random(24); refresh_secret = self._random(32)
        if not isinstance(session_bytes, bytes) or len(session_bytes) != 24 or not isinstance(refresh_secret, bytes) or len(refresh_secret) != 32:
            raise SessionUnavailable()
        session_id = _b64(session_bytes)
        row = {"session_id": session_id, "uid": uid, "device_id": device_id,
               "issued_at": _timestamp(now), "expires_at": _timestamp(now + self.REFRESH_TTL),
               "revoked_at": None, "rotated_from": rotated_from,
               "refresh_token_hash": b"NS1\0" + struct.pack(">QQ", version, now + self.ACCESS_TTL) + bytes(32)}
        row["refresh_token_hash"] = row["refresh_token_hash"][:20] + self._mac(row, access=False, refresh_secret=refresh_secret)
        access = f"na1.{session_id}.{_b64(self._mac(row, access=True))}"
        refresh = f"nr1.{session_id}.{_b64(refresh_secret)}"
        return row, {"accessToken": access, "refreshToken": refresh,
                     "expiresIn": self.ACCESS_TTL, "refreshExpiresIn": self.REFRESH_TTL}

    def validate(self, row, token, *, access, now, allow_revoked=False):
        session_id, proof = _parse(token, "na1" if access else "nr1")
        envelope, version, access_expires, issued, expires = self._metadata(row)
        expected = self._mac(row, access=True) if access else envelope[20:]
        actual = proof if access else self._mac(row, access=False, refresh_secret=proof)
        if session_id != row["session_id"] or not hmac.compare_digest(actual, expected):
            raise SessionRejected()
        if (issued > now + 30 or now >= (access_expires if access else expires)
                or (row["revoked_at"] is not None and not allow_revoked)):
            raise SessionRejected()
        return version, issued, access_expires


LOGIN_QUERY = """SELECT a.uid, a.disabled, a.lifecycle, a.token_version, a.email_verified,
 c.scheme, c.password_hash, c.password_salt, c.parameters
 FROM clrs_staging.accounts AS a LEFT JOIN clrs_staging.auth_credentials AS c ON c.uid = a.uid
 WHERE a.email_normalized = %s LIMIT 2"""
ACCOUNT_QUERY = """SELECT a.uid, a.disabled, a.lifecycle, a.token_version, a.email_verified,
 c.scheme, c.password_hash, c.password_salt, c.parameters
 FROM clrs_staging.accounts AS a JOIN clrs_staging.auth_credentials AS c ON c.uid = a.uid
 WHERE a.uid = %s LIMIT 1 FOR SHARE OF a, c"""
PASSWORD_LOGIN_QUERY = """SELECT a.uid, a.disabled, a.lifecycle, a.token_version, a.email_verified,
 c.scheme, c.password_hash, c.password_salt, c.parameters,
 n.scheme, n.password_version, n.material_ciphertext, n.parameters
 FROM clrs_staging.accounts AS a LEFT JOIN clrs_staging.auth_credentials AS c ON c.uid = a.uid
 LEFT JOIN clrs_staging.native_password_credentials AS n ON n.uid = a.uid
 WHERE a.email_normalized = %s LIMIT 2"""
PASSWORD_ACCOUNT_QUERY = """SELECT a.uid, a.disabled, a.lifecycle, a.token_version, a.email_verified,
 c.scheme, c.password_hash, c.password_salt, c.parameters,
 n.scheme, n.password_version, n.material_ciphertext, n.parameters
 FROM clrs_staging.accounts AS a LEFT JOIN clrs_staging.auth_credentials AS c ON c.uid = a.uid
 LEFT JOIN clrs_staging.native_password_credentials AS n ON n.uid = a.uid
 WHERE a.uid = %s LIMIT 1 FOR SHARE OF a, c, n"""
SESSION_QUERY = """SELECT s.session_id, s.uid, s.device_id, s.refresh_token_hash,
 DATE_FORMAT(s.issued_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'),
 DATE_FORMAT(s.expires_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'),
 DATE_FORMAT(s.revoked_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'), s.rotated_from,
 a.disabled, a.lifecycle, a.token_version, a.email_verified
 FROM clrs_staging.device_sessions AS s JOIN clrs_staging.accounts AS a ON a.uid = s.uid
 WHERE s.session_id = %s LIMIT 1"""


class NativeSessionStore:
    def __init__(self, env, codec, tokens, *, connect=None, clock=time.time, monotonic=time.monotonic,
                 password_selector=None):
        self._env = env
        if not isinstance(codec, CredentialCodec) or not isinstance(tokens, SessionTokens):
            raise SessionUnavailable()
        self.codec = codec; self.tokens = tokens
        self._password_selector = password_selector
        password_flag = env.get("CLRS_NATIVE_PASSWORD_ENABLED")
        if password_flag not in (None, "0", "1") or ((password_flag == "1") != (password_selector is not None)):
            raise SessionUnavailable()
        self._connect = connect; self._clock = clock; self._monotonic = monotonic

    def _enabled(self):
        if (self._env.get("CLRS_NATIVE_AUTH_ENABLED") != "1"
                or self._env.get("CLRS_NATIVE_AUTH_WRITES_ENABLED") != "1"):
            raise SessionUnavailable()
        password_flag = self._env.get("CLRS_NATIVE_PASSWORD_ENABLED")
        if password_flag not in (None, "0", "1") or ((password_flag == "1") != (self._password_selector is not None)):
            raise SessionUnavailable()
        self.permission_model

    @property
    def permission_model(self):
        model = self._env.get("CLRS_NATIVE_AUTH_PERMISSION_MODEL", "strict-tables-v1")
        if not isinstance(model, str) or model not in {"strict-tables-v1", "provider-database-v1"}:
            raise SessionUnavailable()
        return model

    def _execute(self, cursor, sql, params=(), *, deadline):
        if self._monotonic() >= deadline:
            raise SessionUnavailable()
        cursor.execute(sql, params)
        if self._monotonic() >= deadline:
            raise SessionUnavailable()

    def _grants(self, rows):
        if self.permission_model == "provider-database-v1":
            return self._database_grants(rows)
        expected = {"accounts": {"SELECT"}, "auth_credentials": {"SELECT"},
                    "device_sessions": {"SELECT", "INSERT", "UPDATE"}}
        if self._password_selector is not None:
            expected["native_password_credentials"] = {"SELECT"}
        found = {table: set() for table in expected}; usage = False
        names = "|".join(expected)
        for row in rows:
            if len(row) != 1 or not isinstance(row[0], str):
                raise SessionUnavailable()
            match = re.fullmatch(r"GRANT ([A-Z ,]+) ON (\*\.\*|`clrs_staging`\.`(" + names + r")`) TO (?:`[^`]+`|'[^']+')@(?:`[^`]+`|'[^']+')( REQUIRE SSL)?", row[0])
            if not match:
                raise SessionUnavailable()
            privileges = {item.strip() for item in match[1].split(",")}
            if match[2] == "*.*":
                if privileges != {"USAGE"} or usage:
                    raise SessionUnavailable()
                usage = True
            else:
                if match[4]:
                    raise SessionUnavailable()
                table = match[3]
                if not privileges <= expected[table] or privileges & found[table]:
                    raise SessionUnavailable()
                found[table].update(privileges)
        if not usage or found != expected:
            raise SessionUnavailable()

    @staticmethod
    def _database_grants(rows):
        # Explicit provider mode: exactly one USAGE and one database grant.
        # Never combine this broader role with the strict table-grant model.
        usage = False; database = False
        pattern = (r"GRANT ([A-Z ,]+) ON (\*\.\*|`clrs_staging`\.\*) TO "
            r"(?:`[^`]+`|'[^']+')@(?:`[^`]+`|'[^']+')( REQUIRE SSL)?")
        for row in rows:
            if not isinstance(row, (tuple, list)) or len(row) != 1 or not isinstance(row[0], str):
                raise SessionUnavailable()
            match = re.fullmatch(pattern, row[0])
            if match is None:
                raise SessionUnavailable()
            items = [item.strip() for item in match[1].split(",")]
            privileges = set(items)
            if len(items) != len(privileges):
                raise SessionUnavailable()
            if match[2] == "*.*":
                if privileges != {"USAGE"} or usage:
                    raise SessionUnavailable()
                usage = True
            else:
                if privileges != {"SELECT", "INSERT", "UPDATE"} or database or match[3]:
                    raise SessionUnavailable()
                database = True
        if not usage or not database:
            raise SessionUnavailable()

    def _transaction(self, action, *, deadline):
        self._enabled(); connection = None
        try:
            configuration = _database_config({"CLRS_DB_URL": self._env.get("CLRS_NATIVE_AUTH_DB_URL", ""),
                "CLRS_DB_CA_FILE": self._env.get("CLRS_NATIVE_AUTH_DB_CA_FILE",
                                                self._env.get("CLRS_DB_CA_FILE", BUNDLED_CA_FILE))})
            configuration.update(connect_timeout=2, read_timeout=2, write_timeout=2,
                                 autocommit=False, charset="utf8mb4")
            connect = self._connect
            if connect is None:
                import pymysql
                connect = pymysql.connect
            if self._monotonic() >= deadline:
                raise SessionUnavailable()
            connection = connect(**configuration)
            with connection.cursor() as cursor:
                self._execute(cursor, "SHOW GRANTS", deadline=deadline)
                self._grants(cursor.fetchall())
                self._execute(cursor, "SELECT DATABASE(), VERSION()", deadline=deadline)
                row = cursor.fetchone()
                if not row or row[0] != "clrs_staging" or not isinstance(row[1], str) or not row[1].startswith("8.4."):
                    raise SessionUnavailable()
                self._execute(cursor, "SHOW SESSION STATUS LIKE 'Ssl_cipher'", deadline=deadline)
                tls = cursor.fetchone()
                if not tls or not tls[1]:
                    raise SessionUnavailable()
                self._execute(cursor, "SET SESSION time_zone = '+00:00'", deadline=deadline)
                self._execute(cursor, "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'", deadline=deadline)
                self._execute(cursor, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", deadline=deadline)
                connection.begin()
                result = action(cursor)
                if self._monotonic() >= deadline:
                    raise SessionUnavailable()
                connection.commit()
                return result
        except SessionRejected:
            raise
        except Exception:
            raise SessionUnavailable() from None
        finally:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
                try:
                    connection.close()
                except Exception:
                    pass

    def _login_snapshot(self, row):
        if row is None:
            return None
        expected_size = 13 if self._password_selector is not None else 9
        if (len(row) != expected_size or not isinstance(row[0], str) or not 1 <= len(row[0]) <= 191
                or type(row[1]) is not int or row[1] not in (0, 1)
                or row[2] not in ("active", "blocked", "deleted")
                or type(row[3]) is not int or not 0 <= row[3] <= 2 ** 63 - 1
                or type(row[4]) is not int or row[4] not in (0, 1)):
            raise SessionUnavailable()
        if row[1] != 0 or row[2] != "active":
            return None
        if self._password_selector is not None:
            # A present native row is authoritative even if unusable. The
            # selector must never fall back to a retained Firebase verifier.
            firebase = None if all(value is None for value in row[5:9]) else dict(zip(
                ["uid", "scheme", "password_hash", "password_salt", "parameters"], [row[0], *row[5:9]]))
            native = None if all(value is None for value in row[9:13]) else dict(zip(
                ["uid", "scheme", "password_version", "material_ciphertext", "parameters"], [row[0], *row[9:13]]))
            if native is None and firebase is None:
                return None
            selected = self._password_selector.select(uid=row[0], account_token_version=row[3],
                firebase_row=firebase, native_row=native)
            if isinstance(selected.material, CredentialMaterial) and selected.material.disabled:
                return None
            return LoginSnapshot(row[0], row[3], bool(row[4]), selected.material, selected.ciphertext_identity)
        if row[5] is None:
            return None
        credential_row = dict(zip(["uid", "scheme", "password_hash", "password_salt", "parameters"],
                                  [row[0], *row[5:]]))
        credential = self.codec.decode(credential_row)
        if credential.disabled:
            return None
        return LoginSnapshot(row[0], row[3], bool(row[4]), credential, credential_row_identity(credential_row))

    def read_login(self, email, *, deadline):
        def action(cursor):
            query = PASSWORD_LOGIN_QUERY if self._password_selector is not None else LOGIN_QUERY
            self._execute(cursor, query, (email,), deadline=deadline)
            rows = cursor.fetchall()
            if len(rows) > 1:
                raise SessionUnavailable()
            return self._login_snapshot(rows[0] if rows else None)
        return self._transaction(action, deadline=deadline)

    def _insert(self, cursor, row, *, deadline):
        self._execute(cursor, """INSERT INTO clrs_staging.device_sessions
          (session_id, uid, device_id, refresh_token_hash, rotated_from, issued_at, expires_at)
          VALUES (%s, %s, %s, %s, %s, %s, %s)""",
          tuple(row[name] for name in ["session_id", "uid", "device_id", "refresh_token_hash",
                                      "rotated_from", "issued_at", "expires_at"]), deadline=deadline)
        if cursor.rowcount != 1:
            raise SessionUnavailable()
        try:
            retained = self._session(cursor, row["session_id"], lock=True, deadline=deadline)
        except SessionRejected:
            raise SessionUnavailable() from None
        if (any(retained[name] != row[name] for name in ["session_id", "uid", "device_id",
                "rotated_from", "issued_at", "expires_at", "revoked_at"])
                or not hmac.compare_digest(bytes(retained["refresh_token_hash"]), row["refresh_token_hash"])):
            raise SessionUnavailable()

    def issue(self, snapshot, device_id, *, deadline):
        if not isinstance(snapshot, LoginSnapshot):
            raise SessionRejected()
        def action(cursor):
            query = PASSWORD_ACCOUNT_QUERY if self._password_selector is not None else ACCOUNT_QUERY
            self._execute(cursor, query, (snapshot.uid,), deadline=deadline)
            current = self._login_snapshot(cursor.fetchone())
            # The account and credential rows are locked again after KDF;
            # blocking/reset/version changes cannot slip into a new session.
            if (current is None or current.uid != snapshot.uid or current.token_version != snapshot.token_version
                    or not hmac.compare_digest(current.credential_identity, snapshot.credential_identity)):
                raise SessionRejected()
            row, tokens = self.tokens.mint(current.uid, device_id, current.token_version, int(self._clock()))
            self._insert(cursor, row, deadline=deadline)
            return {**tokens, "uid": current.uid, "emailVerified": current.email_verified}
        return self._transaction(action, deadline=deadline)

    def _session(self, cursor, session_id, *, lock, deadline):
        self._execute(cursor, SESSION_QUERY + (" FOR UPDATE OF s FOR SHARE OF a" if lock else ""), (session_id,), deadline=deadline)
        row = cursor.fetchone()
        if row is None:
            raise SessionRejected()
        if len(row) != 12:
            raise SessionUnavailable()
        result = dict(zip(["session_id", "uid", "device_id", "refresh_token_hash", "issued_at",
                          "expires_at", "revoked_at", "rotated_from"], row[:8]))
        if (type(row[8]) is not int or row[8] not in (0, 1) or row[9] not in ("active", "blocked", "deleted")
                or type(row[10]) is not int or not 0 <= row[10] <= 2 ** 63 - 1
                or type(row[11]) is not int or row[11] not in (0, 1)):
            raise SessionUnavailable()
        result.update(disabled=row[8], lifecycle=row[9], token_version=row[10], email_verified=row[11])
        return result

    def _active(self, row, version):
        if row["disabled"] != 0 or row["lifecycle"] != "active" or row["token_version"] != version:
            raise SessionRejected()

    def authorize(self, token, *, deadline):
        session_id, _ = _parse(token, "na1")
        def action(cursor):
            row = self._session(cursor, session_id, lock=False, deadline=deadline)
            version, issued, expires = self.tokens.validate(row, token, access=True, now=int(self._clock()))
            self._active(row, version)
            return NativeIdentity(row["uid"], bool(row["email_verified"]), session_id, issued, expires)
        return self._transaction(action, deadline=deadline)

    def refresh(self, token, *, deadline):
        session_id, _ = _parse(token, "nr1")
        def action(cursor):
            old = self._session(cursor, session_id, lock=True, deadline=deadline)
            version, _, _ = self.tokens.validate(old, token, access=False, now=int(self._clock()), allow_revoked=True)
            if old["revoked_at"] is not None:
                # Only an authenticated old refresh triggers replay response.
                # Return a sentinel so revocation COMMIT happens before 401.
                self._execute(cursor, """UPDATE clrs_staging.device_sessions SET revoked_at = UTC_TIMESTAMP(6)
                  WHERE uid = %s AND device_id = %s AND revoked_at IS NULL""",
                  (old["uid"], old["device_id"]), deadline=deadline)
                return None
            self._active(old, version)
            self._execute(cursor, """UPDATE clrs_staging.device_sessions SET revoked_at = UTC_TIMESTAMP(6)
              WHERE session_id = %s AND revoked_at IS NULL""", (session_id,), deadline=deadline)
            if cursor.rowcount != 1:
                raise SessionRejected()
            row, tokens = self.tokens.mint(old["uid"], old["device_id"], version, int(self._clock()), rotated_from=session_id)
            self._insert(cursor, row, deadline=deadline)
            return {**tokens, "uid": old["uid"], "emailVerified": bool(old["email_verified"])}
        result = self._transaction(action, deadline=deadline)
        if result is None:
            raise SessionRejected()
        return result

    def logout(self, token, *, all_sessions=False, deadline):
        if type(all_sessions) is not bool:
            raise SessionRejected()
        session_id, _ = _parse(token, "na1")
        def action(cursor):
            row = self._session(cursor, session_id, lock=True, deadline=deadline)
            version, _, _ = self.tokens.validate(row, token, access=True, now=int(self._clock()))
            self._active(row, version)
            if all_sessions:
                self._execute(cursor, """UPDATE clrs_staging.device_sessions SET revoked_at = UTC_TIMESTAMP(6)
                  WHERE uid = %s AND revoked_at IS NULL""", (row["uid"],), deadline=deadline)
            else:
                self._execute(cursor, """UPDATE clrs_staging.device_sessions SET revoked_at = UTC_TIMESTAMP(6)
                  WHERE session_id = %s AND revoked_at IS NULL""", (session_id,), deadline=deadline)
            return {"loggedOut": True}
        return self._transaction(action, deadline=deadline)
