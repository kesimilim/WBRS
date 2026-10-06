"""Bounded canonical admin-user reads with locked current native authority.

No routes/grants/bootstrap. The existing mutation store verifies current native
session/account before and after this READ ONLY callback; this service also
checks the canonical admin grant before and after constructing each page.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import time

from native_credentials import decode_base64
from legacy_conversation_payload import OpaqueReferences, LegacyInvalid
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_chat import _identifier
from runtime_reads import _text


ADMIN_ORDER = "uid_binary_asc"
MAX_PAGE = 30
SCAN_CHUNK = 32
MAX_SCAN_ROWS = 128
MAX_PUBLIC_BYTES = 65_536
MAX_CURSOR_CHARS = 4096
VERIFIED_SOURCES = frozenset({"firebase_claim", "approved_uid", "admin_grant"})


class RuntimeAdminRoleRejected(RuntimeRejected):
    """Current native identity is valid, but canonical admin access is denied."""


ROLE_QUERY = """SELECT uid, role, verified_source, revoked_at
 FROM clrs_staging.role_grants WHERE uid = %s
 AND CAST(uid AS BINARY) = CAST(%s AS BINARY)
 AND role = 'admin' AND CAST(role AS BINARY) = CAST('admin' AS BINARY)
 LIMIT 2 FOR SHARE"""
_SELECT = """SELECT a.uid, a.email_normalized,
 CASE WHEN p.full_name IS NULL OR
 (CHAR_LENGTH(p.full_name) <= 1000 AND OCTET_LENGTH(p.full_name) <= 4000)
 THEN p.full_name ELSE NULL END,
 p.age, a.lifecycle, a.disabled
 FROM clrs_staging.accounts AS a LEFT JOIN clrs_staging.profiles AS p
 ON p.uid = a.uid AND CAST(p.uid AS BINARY) = CAST(a.uid AS BINARY)"""


def _uid(value):
    if type(value) is not str:
        raise RuntimeInvalidRequest()
    value = _identifier(value)
    if value in {".", ".."} or "/" in value:
        raise RuntimeInvalidRequest()
    return value


def normalize_admin_query(value=None):
    """One literal Unicode prefix, or empty for the unfiltered admin listing."""
    if value is None:
        return ""
    if (type(value) is not str or len(value) > 100
            or any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)
            or len(value.encode("utf-8")) > 400):
        raise RuntimeInvalidRequest()
    normalized = value.strip().casefold()
    if (normalized and not 2 <= len(normalized) <= 100
            or len(normalized.encode("utf-8")) > 400):
        raise RuntimeInvalidRequest()
    return normalized


def admin_users_query(anchor=None):
    # The schema's utf8mb4_0900_bin UID primary keys support this exact range
    # and order. No LIKE/regex/OR search on unindexed full_name: scan only a
    # bounded candidate chunk, then apply the literal prefix to its DTOs.
    sql = _SELECT
    params = []
    if anchor is not None:
        sql += " WHERE a.uid > %s AND CAST(a.uid AS BINARY) > CAST(%s AS BINARY)"
        params += [anchor, anchor]
    sql += " ORDER BY a.uid ASC LIMIT %s FOR SHARE OF a, p"
    return sql, tuple([*params, SCAN_CHUNK])


def _admin(cursor, execute, actor_uid):
    execute(ROLE_QUERY, (actor_uid, actor_uid)); rows = cursor.fetchall()
    if len(rows) != 1:
        raise RuntimeAdminRoleRejected()
    row = rows[0]
    if (not isinstance(row, (tuple, list)) or len(row) != 4
            or type(row[0]) is not str or row[0] != actor_uid
            or type(row[1]) is not str or row[1] != "admin"
            or type(row[2]) is not str or row[2] not in VERIFIED_SOURCES
            or row[3] is not None):
        raise RuntimeAdminRoleRejected()
    # A post-check must retain the same reviewed grant source as the pre-check.
    return tuple(row)


def _user(row):
    if not isinstance(row, (tuple, list)) or len(row) != 6:
        raise RuntimeUnavailable()
    try:
        uid = _uid(row[0])
        email = _text(row[1], 320, nullable=True)
        name = _text(row[2], 1000, nullable=True)
    except (RuntimeInvalidRequest, RuntimeUnavailable):
        raise RuntimeUnavailable() from None
    if (email is not None and (not email or email != email.strip().lower()
            or any(ord(c) < 32 or ord(c) == 127 for c in email))):
        raise RuntimeUnavailable()
    if row[3] is not None and (type(row[3]) is not int or not 0 <= row[3] <= 130):
        raise RuntimeUnavailable()
    if (type(row[4]) is not str or row[4] not in {"active", "blocked", "deleted"}
            or type(row[5]) is not int or row[5] not in (0, 1)):
        raise RuntimeUnavailable()
    return {"uid": uid, "email": email, "fullName": name, "age": row[3],
            "lifecycle": row[4], "disabled": bool(row[5])}


def _matches(user, query):
    return not query or any(value is not None and value.casefold().startswith(query)
        for value in (user["fullName"], user["email"]))


class RuntimeAdminUsersService:
    def __init__(self, store, cursor_key, *, clock=time.time):
        if store is None or type(cursor_key) is not bytes or len(cursor_key) != 32 or not callable(clock):
            raise RuntimeUnavailable()
        self._store = store; self._clock = clock
        self._codec = OpaqueReferences(hmac.digest(cursor_key,
            b"clrs-runtime-current-admin-users-cursor-v1\0", "sha256"))

    @classmethod
    def from_env(cls, store, env=None):
        env = os.environ if env is None else env
        if (env.get("CLRS_RUNTIME_WRITES_ENABLED") != "1"
                or env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") != "canonical-current-v1"):
            return None
        try:
            return cls(store, decode_base64(env.get("CLRS_LEGACY_READ_CURSOR_KEY_B64"), max_bytes=32))
        except Exception:
            raise RuntimeUnavailable() from None

    def _cursor(self, value, actor_uid, limit, digest):
        if value is None:
            return None
        try:
            if type(value) is not str or not 1 <= len(value) <= MAX_CURSOR_CHARS:
                raise RuntimeInvalidRequest()
            opened = self._codec.open("cursor", value)
            now = int(self._clock())
            if (set(opened) != {"v", "actorUid", "purpose", "limit", "queryHash", "afterUid", "exp"}
                    or type(opened["v"]) is not int or opened["v"] != 1
                    or opened["actorUid"] != actor_uid or opened["purpose"] != ADMIN_ORDER
                    or type(opened["limit"]) is not int or opened["limit"] != limit
                    or opened["queryHash"] != digest or type(opened["exp"]) is not int
                    or not now < opened["exp"] <= now + 300):
                raise RuntimeInvalidRequest()
            return _uid(opened["afterUid"])
        except (LegacyInvalid, RuntimeInvalidRequest):
            raise RuntimeInvalidRequest() from None

    def _next(self, actor_uid, limit, digest, anchor):
        return self._codec.seal("cursor", {"v": 1, "actorUid": actor_uid,
            "purpose": ADMIN_ORDER, "limit": limit, "queryHash": digest,
            "afterUid": anchor, "exp": int(self._clock()) + 300})

    @staticmethod
    def _page(items, next_cursor=None):
        return {"kind": "canonical-admin-users", "ordering": ADMIN_ORDER,
                "items": items, "nextCursor": next_cursor}

    def users(self, identity, *, access_token, query=None, limit=30, cursor=None):
        if type(limit) is not int or not 1 <= limit <= MAX_PAGE:
            raise RuntimeInvalidRequest()
        normalized = normalize_admin_query(query)
        digest = hashlib.sha256(canonical_json({"prefix": normalized})).hexdigest()
        def action(sql_cursor, execute, actor_uid):
            before = _admin(sql_cursor, execute, actor_uid)
            anchor = self._cursor(cursor, actor_uid, limit, digest)
            items = []; scanned = 0
            def finish(next_anchor=None):
                if _admin(sql_cursor, execute, actor_uid) != before:
                    raise RuntimeAdminRoleRejected()
                page = self._page(items, None if next_anchor is None
                    else self._next(actor_uid, limit, digest, next_anchor))
                try:
                    canonical_json(page)
                except RuntimeInvalidRequest:
                    raise RuntimeUnavailable() from None
                return page
            while scanned < MAX_SCAN_ROWS:
                sql, params = admin_users_query(anchor)
                execute(sql, params); rows = sql_cursor.fetchall()
                if len(rows) > SCAN_CHUNK:
                    raise RuntimeUnavailable()
                for raw in rows:
                    user = _user(raw)
                    if anchor is not None and user["uid"].encode("utf-8") <= anchor.encode("utf-8"):
                        raise RuntimeUnavailable()
                    previous = anchor
                    if _matches(user, normalized):
                        packed = self._page([*items, user], "x" * MAX_CURSOR_CHARS)
                        if len(items) == limit or len(canonical_json(packed, max_bytes=4 * 1024 * 1024)) > MAX_PUBLIC_BYTES:
                            # The current fitting/matching row was not consumed.
                            # Continue after the last emitted/scanned row so it
                            # remains the first candidate on the next request.
                            if not items or previous is None:
                                raise RuntimeUnavailable()
                            return finish(previous)
                        items.append(user)
                    anchor = user["uid"]; scanned += 1
                    if scanned == MAX_SCAN_ROWS:
                        return finish(anchor)
                if len(rows) < SCAN_CHUNK:
                    return finish()
            raise RuntimeUnavailable()
        return self._store.read_authenticated(identity, action, access_token=access_token)
