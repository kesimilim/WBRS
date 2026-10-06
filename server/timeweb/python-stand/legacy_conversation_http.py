"""Default-off, bounded HTTP dispatch for reviewed snapshot reads only."""
from __future__ import annotations

import json
import re
from typing import NamedTuple
from urllib.parse import parse_qsl

from auth_bridge import (AuthenticatedIdentity, AuthRejected, AuthUnavailable,
    AuthenticationError, verify_firebase_identity)
from native_auth import NativeRejected, NativeRateLimited, NativeUnavailable
from native_credentials import decode_base64
from native_sessions import NativeIdentity
from legacy_conversation_payload import identifier, LegacyInvalid
from legacy_conversation_read import (LegacyReadRejected, LegacyReadUnavailable,
    LegacyReadRateLimited, MAX_RESPONSE_BYTES)
from legacy_own_profile import LegacyReadApiService


class LegacyHttpReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


class InvalidReadRequest(Exception):
    pass


def create_legacy_read_service(env):
    key = decode_base64(env.get("CLRS_LEGACY_CURSOR_KEY_B64"), max_bytes=32)
    if len(key) != 32:
        raise LegacyReadUnavailable()
    return LegacyReadApiService(env, key)


def _route(path):
    if not isinstance(path, str) or len(path) > 4600:
        return None
    # WSGI PATH_INFO carries the decoded UTF-8 bytes in Latin-1 code points.
    try:
        path = path.encode("latin-1", "strict").decode("utf-8", "strict")
    except UnicodeError:
        return None
    if path == "/v1/me/full-profile":
        return "own_profile", None
    if path == "/v1/chats":
        return "personal_chats", None
    if path == "/v1/meetings":
        return "own_meetings", None
    match = re.fullmatch(r"/v1/(chats|meetings)/([^/]+)(?:/(messages|participants))?", path)
    if not match:
        return None
    domain, resource, child = match.groups()
    try:
        identifier(resource)
    except LegacyInvalid:
        return None
    if any(ord(char) < 32 or ord(char) == 127 for char in resource):
        return None
    if domain == "chats":
        return ("personal_messages", resource) if child == "messages" else None
    return {None: ("meeting_details", resource), "messages": ("meeting_messages", resource),
            "participants": ("meeting_participants", resource)}.get(child)


def _parameters(query, operation):
    if operation == "own_profile" and query != "":
        raise InvalidReadRequest()
    if (not isinstance(query, str) or len(query) > 8192 or not query.isascii()
            or re.search(r"%(?![0-9A-Fa-f]{2})", query)):
        raise InvalidReadRequest()
    allowed = set() if operation in {"meeting_details", "own_profile"} else {"limit", "cursor"}
    if operation == "meeting_messages":
        allowed.add("own_removed")
    try:
        pairs = parse_qsl(query, keep_blank_values=True, strict_parsing=True,
                          encoding="utf-8", errors="strict", max_num_fields=3)
    except (ValueError, UnicodeError):
        raise InvalidReadRequest() from None
    result = {}
    for key, value in pairs:
        if key not in allowed or key in result:
            raise InvalidReadRequest()
        result[key] = value
    kwargs = {}
    if operation not in {"meeting_details", "own_profile"}:
        limit = result.get("limit", "50")
        if not re.fullmatch(r"[1-9][0-9]?", limit) or not 1 <= int(limit) <= 50:
            raise InvalidReadRequest()
        kwargs["limit"] = int(limit)
        token = result.get("cursor")
        if token is not None and (len(token) > 4096 or not re.fullmatch(r"[A-Za-z0-9_-]+", token)):
            raise InvalidReadRequest()
        kwargs["cursor"] = token
    if "own_removed" in result:
        if result["own_removed"] not in {"0", "1"}:
            raise InvalidReadRequest()
        kwargs["own_removed"] = result["own_removed"] == "1"
    return kwargs


class LegacyConversationHttp:
    def __init__(self, env, *, service_factory=create_legacy_read_service,
                 identity_verifier=verify_firebase_identity):
        self._env = dict(env)
        self._verify = identity_verifier
        self._enabled = (env.get("CLRS_LEGACY_READ_ENABLED") == "1"
            and env.get("CLRS_LEGACY_READ_SNAPSHOT_REVIEWED") == "1"
            and env.get("CLRS_LEGACY_READ_MEMBERSHIP_MODE") == "immutable-reviewed-snapshot")
        self._service = None
        if self._enabled:
            try:
                self._service = service_factory(env)
            except Exception:
                pass

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        route = _route(environ.get("PATH_INFO", ""))
        if route is None:
            return None
        if not self._enabled:
            return LegacyHttpReply("404 Not Found", {"error": "not_found"})
        if environ.get("REQUEST_METHOD") != "GET":
            return LegacyHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        operation, resource = route
        try:
            kwargs = _parameters(environ.get("QUERY_STRING", ""), operation)
        except InvalidReadRequest:
            return LegacyHttpReply("400 Bad Request", {"error": "invalid_request"})
        if self._service is None:
            return LegacyHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
        try:
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (not isinstance(header, str) or not header.startswith("Bearer ")
                    or not header[7:] or len(header) > 8192 or any(c.isspace() for c in header[7:])):
                raise NativeRejected()
            token = header[7:]
            if token.startswith(("na1.", "nr1.")):
                if not native_configured:
                    raise NativeRejected()
                if native_service is None:
                    raise NativeUnavailable()
                identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
                if type(identity) is not NativeIdentity:
                    raise NativeUnavailable()
            else:
                if not self._env.get("FIREBASE_PROJECT_ID") or not self._env.get("FIREBASE_WEB_API_KEY"):
                    raise AuthUnavailable()
                identity = self._verify(token, project_id=self._env["FIREBASE_PROJECT_ID"],
                                        web_api_key=self._env["FIREBASE_WEB_API_KEY"])
                if type(identity) is not AuthenticatedIdentity:
                    raise AuthUnavailable()
            method = getattr(self._service, operation)
            payload = method(identity, **kwargs) if resource is None else method(identity, resource, **kwargs)
            if not isinstance(payload, dict) or len(json.dumps(payload, ensure_ascii=False,
                    separators=(",", ":"), allow_nan=False).encode()) > MAX_RESPONSE_BYTES:
                raise LegacyReadUnavailable()
            return LegacyHttpReply("200 OK", payload)
        except (NativeRejected, AuthRejected):
            return LegacyHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
        except LegacyReadRejected:
            return LegacyHttpReply("404 Not Found", {"error": "not_found"})
        except (NativeRateLimited, LegacyReadRateLimited):
            return LegacyHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except (NativeUnavailable, AuthenticationError, LegacyReadUnavailable):
            return LegacyHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
        except Exception:
            return LegacyHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
