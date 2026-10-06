"""Native GET-only admin-user adapter; no identity/bootstrap/write fallback.

Construction is lazy and limited to a matching, enabled, authenticated route.
The canonical admin service keeps role/session proof in the shared READ ONLY
pool. HTTP rechecks the explicit admin DTO before handing it to the app owner.
"""
from __future__ import annotations

import re
import threading
from typing import NamedTuple
from urllib.parse import parse_qsl

from native_auth import NativeRejected, NativeUnavailable, NativeRateLimited
from native_sessions import NativeIdentity
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_admin_users import (RuntimeAdminUsersService, RuntimeAdminRoleRejected,
    normalize_admin_query, ADMIN_ORDER, MAX_CURSOR_CHARS, _user, _matches)


ADMIN_USERS_PATH = "/v1/runtime/admin/users"
_CURSOR = re.compile(r"[A-Za-z0-9_-]{1,4096}")


class RuntimeAdminHttpReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


def _options(environ):
    raw = environ.get("QUERY_STRING", "")
    if (type(raw) is not str or len(raw) > 8192
            or re.search(r"%(?![a-fA-F0-9]{2})", raw)
            or any(ord(c) < 32 or ord(c) > 126 for c in raw)):
        raise RuntimeInvalidRequest()
    try:
        entries = parse_qsl(raw, keep_blank_values=True, strict_parsing=True,
            encoding="utf-8", errors="strict", max_num_fields=3)
    except (ValueError, UnicodeError):
        raise RuntimeInvalidRequest() from None
    values = dict(entries)
    if len(entries) != len(values) or set(values) - {"query", "limit", "cursor"}:
        raise RuntimeInvalidRequest()
    limit = values.get("limit", "30")
    if re.fullmatch(r"[1-9][0-9]?", limit) is None or int(limit) > 30:
        raise RuntimeInvalidRequest()
    options = {"query": normalize_admin_query(values.get("query")), "limit": int(limit)}
    if "cursor" in values:
        if _CURSOR.fullmatch(values["cursor"]) is None:
            raise RuntimeInvalidRequest()
        options["cursor"] = values["cursor"]
    return options


def _page(value, options):
    if (type(value) is not dict or set(value) != {"kind", "ordering", "items", "nextCursor"}
            or value["kind"] != "canonical-admin-users" or value["ordering"] != ADMIN_ORDER
            or type(value["items"]) is not list or len(value["items"]) > options["limit"]):
        raise RuntimeUnavailable()
    keys = {"uid", "email", "fullName", "age", "lifecycle", "disabled"}
    previous = None
    for item in value["items"]:
        if type(item) is not dict or set(item) != keys or type(item["disabled"]) is not bool:
            raise RuntimeUnavailable()
        decoded = _user((item["uid"], item["email"], item["fullName"], item["age"],
                         item["lifecycle"], int(item["disabled"])))
        if (decoded != item or not _matches(decoded, options["query"])
                or previous is not None and decoded["uid"].encode() <= previous.encode()):
            raise RuntimeUnavailable()
        previous = decoded["uid"]
    cursor = value["nextCursor"]
    if cursor is not None and (type(cursor) is not str or len(cursor) > MAX_CURSOR_CHARS
            or _CURSOR.fullmatch(cursor) is None or cursor == options.get("cursor")):
        raise RuntimeUnavailable()
    try:
        canonical_json(value)
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None
    return value


class RuntimeAdminUsersHttp:
    def __init__(self, env, store, *, service_factory=None):
        self._enabled = (env.get("CLRS_RUNTIME_WRITES_ENABLED") == "1"
            and env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") == "canonical-current-v1")
        self._env = dict(env); self._store = store; self._factory = service_factory
        self._service = None; self._attempted = False; self._closed = False
        self._lock = threading.Lock()

    def close(self):
        # Shared transaction pool belongs to the parent runtime HTTP owner.
        with self._lock:
            self._closed = True; self._service = None

    def _reader(self):
        with self._lock:
            if self._closed or self._store is None:
                raise RuntimeUnavailable()
            if not self._attempted:
                self._attempted = True
                factory = self._factory or RuntimeAdminUsersService.from_env
                try:
                    self._service = factory(self._store, self._env)
                except Exception:
                    raise RuntimeUnavailable() from None
            if self._service is None:
                raise RuntimeUnavailable()
            return self._service

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        if environ.get("PATH_INFO") != ADMIN_USERS_PATH:
            return None
        if not self._enabled:
            return RuntimeAdminHttpReply("404 Not Found", {"error": "not_found"})
        if environ.get("REQUEST_METHOD") != "GET":
            return RuntimeAdminHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        try:
            if (environ.get("HTTP_TRANSFER_ENCODING")
                    or environ.get("CONTENT_LENGTH", "") not in ("", "0")):
                raise RuntimeInvalidRequest()
            options = _options(environ)
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (type(header) is not str or not header.startswith("Bearer na1.")
                    or len(header) > 135 or any(c.isspace() for c in header[7:])
                    or not native_configured):
                raise NativeRejected()
            if native_service is None:
                raise NativeUnavailable()
            token = header[7:]
            identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
            if type(identity) is not NativeIdentity:
                raise NativeUnavailable()
            result = self._reader().users(identity, access_token=token, **options)
            page = _page(result, options)
            with self._lock:
                if self._closed:
                    raise RuntimeUnavailable()
            return RuntimeAdminHttpReply("200 OK", page)
        except RuntimeInvalidRequest:
            return RuntimeAdminHttpReply("400 Bad Request", {"error": "invalid_request"})
        except RuntimeAdminRoleRejected:
            return RuntimeAdminHttpReply("403 Forbidden", {"error": "forbidden"})
        except (NativeRejected, RuntimeRejected):
            return RuntimeAdminHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
        except NativeRateLimited:
            return RuntimeAdminHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except Exception:
            return RuntimeAdminHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
