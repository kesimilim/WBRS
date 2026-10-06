"""Native-only bounded HTTP pages from current conversation/people authority.

Uses the mutation service's existing transaction pool. No Firebase fallback,
arbitrary audience, raw legacy payload, client URL or independent write path.
"""
from __future__ import annotations

import re
from typing import NamedTuple
from urllib.parse import parse_qsl

from native_auth import NativeRejected, NativeUnavailable, NativeRateLimited
from native_sessions import NativeIdentity
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, MAX_INTEGER
from runtime_reads import RuntimeReadRejected
from runtime_admin_http import RuntimeAdminUsersHttp
from runtime_meetings_http import RuntimeMeetingsHttp


class RuntimeReadHttpReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


def _route(environ):
    path = environ.get("PATH_INFO", "")
    if not isinstance(path, str) or len(path) > 1000:
        return None
    try:
        path = path.encode("latin-1").decode("utf-8")
    except UnicodeError:
        return None
    if path == "/v1/runtime/chats":
        return "chats", None
    if path == "/v1/runtime/events":
        return "events", None
    if path == "/v1/runtime/people":
        return "people", None
    match = re.fullmatch(r"/v1/runtime/people/([^/]{1,191})", path)
    if match:
        if match[1] in {".", ".."} or any(ord(c) < 32 or ord(c) == 127 for c in match[1]):
            return None
        return "person", match[1]
    match = re.fullmatch(r"/v1/runtime/chats/([^/]{1,191})/messages", path)
    if match and environ.get("REQUEST_METHOD") != "POST":
        if any(ord(c) < 32 or ord(c) == 127 for c in match[1]):
            return None
        return "messages", match[1]
    return None


def _query(environ, operation):
    raw = environ.get("QUERY_STRING", "")
    if (not isinstance(raw, str) or len(raw) > (8192 if operation == "people" else 4096)
            or re.search(r"%(?![a-fA-F0-9]{2})", raw)
            or any(ord(c) < 32 or ord(c) > 126 for c in raw)):
        raise RuntimeInvalidRequest()
    try:
        entries = parse_qsl(raw, keep_blank_values=True, strict_parsing=True,
                            encoding="utf-8", errors="strict", max_num_fields=8 if operation == "people" else 2)
    except (ValueError, UnicodeError):
        raise RuntimeInvalidRequest() from None
    values = dict(entries)
    if operation == "person":
        if entries:
            raise RuntimeInvalidRequest()
        return {}
    if operation == "people":
        allowed = {"limit", "cursor", "minAge", "maxAge", "countryCode", "region", "pol", "compatibleGroup"}
        if len(entries) != len(values) or set(values) - allowed:
            raise RuntimeInvalidRequest()
        result = {}
        for name, parameter, default, maximum in (("limit", "limit", "30", 30),
                ("minAge", "min_age", "18", 100), ("maxAge", "max_age", "100", 100)):
            value = values.get(name, default)
            if re.fullmatch(r"[1-9][0-9]{0,2}", value) is None or int(value) > maximum:
                raise RuntimeInvalidRequest()
            result[parameter] = int(value)
        for name, parameter in (("countryCode", "country_code"), ("region", "region"),
                                ("pol", "gender"), ("compatibleGroup", "compatible_group")):
            if name in values:
                result[parameter] = values[name]
        from runtime_people import validate_people_filters
        validate_people_filters(**{key: value for key, value in result.items() if key != "limit"})
        if "cursor" in values:
            cursor = values["cursor"]
            if not cursor or len(cursor) > 4096 or re.fullmatch(r"[A-Za-z0-9_-]+", cursor) is None:
                raise RuntimeInvalidRequest()
            result["cursor"] = cursor
        return result
    cursor_name = {"chats": "cursor", "messages": "beforeSequence",
                   "events": "afterEventId"}[operation]
    if len(entries) != len(values) or set(values) - {"limit", cursor_name}:
        raise RuntimeInvalidRequest()
    limit = values.get("limit", "50")
    if re.fullmatch(r"[1-9][0-9]{0,2}", limit) is None or int(limit) > 100:
        raise RuntimeInvalidRequest()
    result = {"limit": int(limit)}
    if cursor_name in values:
        cursor = values[cursor_name]
        if operation == "chats":
            if not cursor or len(cursor) > 2048 or re.fullmatch(r"[A-Za-z0-9_-]+", cursor) is None:
                raise RuntimeInvalidRequest()
            result["cursor"] = cursor
        else:
            if re.fullmatch(r"0|[1-9][0-9]{0,18}", cursor) is None:
                raise RuntimeInvalidRequest()
            value = int(cursor)
            if value > MAX_INTEGER or (operation == "messages" and value == 0):
                raise RuntimeInvalidRequest()
            result["before_sequence" if operation == "messages" else "after_event_id"] = value
    return result


class RuntimeReadHttp:
    def __init__(self, env, store, *, read_factory=None, people_factory=None, admin_factory=None,
                 meetings_factory=None):
        self._enabled = (env.get("CLRS_RUNTIME_WRITES_ENABLED") == "1"
            and env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") == "canonical-current-v1")
        self._reader = None
        self._people = None
        self._admin = RuntimeAdminUsersHttp(env, store, service_factory=admin_factory)
        self._meetings = RuntimeMeetingsHttp(env, store, service_factory=meetings_factory)
        if self._enabled and store is not None:
            try:
                if read_factory is None:
                    from runtime_reads import RuntimeReadService
                    read_factory = RuntimeReadService.from_env
                self._reader = read_factory(store, env)
            except Exception:
                pass
            try:
                if people_factory is None:
                    from runtime_people import RuntimePeopleService
                    people_factory = RuntimePeopleService.from_env
                self._people = people_factory(store, env)
            except Exception:
                pass

    def close(self):
        # The parent HTTP adapter owns and closes the shared transaction pool.
        self._reader = None
        self._people = None
        self._admin.close()
        self._meetings.close()

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        meetings_reply = self._meetings.dispatch(environ, native_service=native_service,
                                                native_configured=native_configured)
        if meetings_reply is not None:
            return meetings_reply
        admin_reply = self._admin.dispatch(environ, native_service=native_service,
                                           native_configured=native_configured)
        if admin_reply is not None:
            return admin_reply
        route = _route(environ)
        if route is None:
            return None
        if not self._enabled:
            return RuntimeReadHttpReply("404 Not Found", {"error": "not_found"})
        if environ.get("REQUEST_METHOD") != "GET":
            return RuntimeReadHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        operation, resource = route
        try:
            if (environ.get("HTTP_TRANSFER_ENCODING")
                    or environ.get("CONTENT_LENGTH", "") not in ("", "0")):
                raise RuntimeInvalidRequest()
            options = _query(environ, operation)
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (not isinstance(header, str) or not header.startswith("Bearer na1.")
                    or len(header) > 135 or any(c.isspace() for c in header[7:])
                    or not native_configured):
                raise NativeRejected()
            reader = self._people if operation in {"people", "person"} else self._reader
            if native_service is None or reader is None:
                raise NativeUnavailable()
            token = header[7:]
            identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
            if type(identity) is not NativeIdentity:
                raise NativeUnavailable()
            if operation == "chats":
                result = reader.own_chats(identity, access_token=token, **options)
            elif operation == "messages":
                result = reader.messages(identity, resource, access_token=token, **options)
            elif operation == "people":
                result = reader.people(identity, access_token=token, **options)
            elif operation == "person":
                result = reader.public_person(identity, resource, access_token=token)
            else:
                result = reader.own_events(identity, access_token=token, **options)
            if type(result) is not dict:
                raise NativeUnavailable()
            return RuntimeReadHttpReply("200 OK", result)
        except RuntimeInvalidRequest:
            return RuntimeReadHttpReply("400 Bad Request", {"error": "invalid_request"})
        except RuntimeReadRejected:
            return RuntimeReadHttpReply("404 Not Found", {"error": "not_found"})
        except (NativeRejected, RuntimeRejected):
            return RuntimeReadHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
        except NativeRateLimited:
            return RuntimeReadHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except Exception:
            return RuntimeReadHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
