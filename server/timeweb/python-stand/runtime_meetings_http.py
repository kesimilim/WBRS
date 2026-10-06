"""Default-closed native GET adapter for current meeting read projections.

The trusted caller may inject a reviewed reader factory using the same store.
No policy is inferred/supplied here; the normal service factory stays closed.
"""
from __future__ import annotations

import re
import threading
from typing import NamedTuple
from urllib.parse import parse_qsl

from native_auth import NativeRejected, NativeUnavailable, NativeRateLimited
from native_sessions import NativeIdentity, _parse, SessionRejected
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_reads import RuntimeReadRejected, _text, _timestamp, _number
from runtime_people import _uid, validate_people_filters
from runtime_meetings import (RuntimeMeetingsService, MEETING_ORDER, PARTICIPANT_ORDER,
                             MAX_PAGE, MAX_PUBLIC_BYTES)
from meeting_schedule import read_schedule
from runtime_meeting_chat import validate_page
from runtime_meeting_archive import validate_archive_page


PREFIX = "/v1/runtime/meetings"
_OPAQUE = re.compile(r"[A-Za-z0-9_-]{1,4096}\Z")
_MEETING_KEYS = {"meetingId", "organizerUid", "invitedUid", "kind", "title", "description",
    "countryCode", "region", "startsAt", "localDatetime", "createdAt", "updatedAt", "revision", "media", "mediaReady"}
_PARTICIPANT_KEYS = {"uid", "fullName", "primaryGroup", "joinedAt", "membershipRevision", "avatar", "mediaReady"}


class RuntimeMeetingsHttpReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


def _route(environ):
    raw = environ.get("PATH_INFO", "")
    if type(raw) is not str or not (raw == PREFIX or raw.startswith(PREFIX + "/")):
        return None
    if len(raw) > 1000:
        raise RuntimeInvalidRequest()
    try:
        # WSGI already URL-decodes PATH_INFO. Never percent-decode a second time.
        try:
            path = raw.encode("latin-1").decode("utf-8", "strict")
        except UnicodeEncodeError:
            path = raw  # trusted adaptation layers may expose decoded Unicode
        if path == PREFIX:
            return "meetings", None
        pieces = path[len(PREFIX) + 1:].split("/")
        if len(pieces) not in (1, 2) or len(pieces) == 2 and pieces[1] not in {"participants", "messages", "archived-messages"}:
            raise RuntimeInvalidRequest()
        resource = pieces[0]
        if any(c in resource for c in "%\\?#"):
            raise RuntimeInvalidRequest()
        resource = _uid(resource)
        return ("meeting" if len(pieces) == 1 else pieces[1]), resource
    except (UnicodeError, RuntimeInvalidRequest):
        raise RuntimeInvalidRequest() from None


def _options(environ, operation):
    if "HTTP_TRANSFER_ENCODING" in environ or environ.get("CONTENT_LENGTH", "") not in ("", "0"):
        raise RuntimeInvalidRequest()
    raw = environ.get("QUERY_STRING", "")
    if (type(raw) is not str or len(raw) > 8192
            or re.search(r"%(?![a-fA-F0-9]{2})", raw)
            or any(ord(c) < 32 or ord(c) > 126 for c in raw)):
        raise RuntimeInvalidRequest()
    allowed = {"scope", "limit", "cursor", "countryCode", "region"} if operation == "meetings" else (
        {"limit", "cursor"} if operation in {"participants", "messages", "archived-messages"} else set())
    try:
        entries = parse_qsl(raw, keep_blank_values=True, strict_parsing=True,
            encoding="utf-8", errors="strict", max_num_fields=len(allowed))
    except (ValueError, UnicodeError):
        raise RuntimeInvalidRequest() from None
    values = dict(entries)
    if len(entries) != len(values) or set(values) - allowed:
        raise RuntimeInvalidRequest()
    if operation == "meeting":
        return {}
    limit = values.get("limit", "30")
    if re.fullmatch(r"[1-9][0-9]?", limit) is None or int(limit) > MAX_PAGE:
        raise RuntimeInvalidRequest()
    options = {"limit": int(limit)}
    if "cursor" in values:
        if _OPAQUE.fullmatch(values["cursor"]) is None:
            raise RuntimeInvalidRequest()
        options["cursor"] = values["cursor"]
    if operation == "meetings":
        scope = values.get("scope", "group")
        if scope not in {"group", "individual"}:
            raise RuntimeInvalidRequest()
        options["scope"] = scope
        for source, target in (("countryCode", "country_code"), ("region", "region")):
            if source in values:
                options[target] = values[source]
        validate_people_filters(**{key: value for key, value in options.items() if key in {"country_code", "region"}})
    return options


def _output_uid(value):
    try:
        return _uid(value)
    except (RuntimeInvalidRequest, UnicodeError):
        raise RuntimeUnavailable() from None


def _meeting(value):
    if type(value) is not dict or set(value) != _MEETING_KEYS or value["media"] is not None or value["mediaReady"] is not False:
        raise RuntimeUnavailable()
    for field in ("meetingId", "organizerUid"):
        _output_uid(value[field])
    invited = value["invitedUid"]
    if invited is not None:
        _output_uid(invited)
    if not ((value["kind"] == "group" and invited is None)
            or (value["kind"] == "individual" and invited is not None and invited != value["organizerUid"])):
        raise RuntimeUnavailable()
    for field, maximum in (("title", 1000), ("description", 4096), ("countryCode", 191), ("region", 191)):
        _text(value[field], maximum, nullable=True)
    for field in ("startsAt", "createdAt", "updatedAt"):
        _timestamp(value[field], nullable=True)
    read_schedule(value["localDatetime"], value["startsAt"])
    _number(value["revision"])
    return value


def _next_cursor(value, options):
    if value is not None and (type(value) is not str or _OPAQUE.fullmatch(value) is None or value == options.get("cursor")):
        raise RuntimeUnavailable()


def _result(value, operation, resource, options):
    if operation == "archived-messages":
        return validate_archive_page(value, resource, options["limit"], options.get("cursor"))
    if operation == "messages":
        return validate_page(value, resource, options["limit"], options.get("cursor"))
    if type(value) is not dict or value.get("kind") != "canonical-current" or value.get("mediaReady") is not False:
        raise RuntimeUnavailable()
    if operation == "meeting":
        if set(value) != {"kind", "meeting", "mediaReady"} or _meeting(value["meeting"])["meetingId"] != resource:
            raise RuntimeUnavailable()
    else:
        expected = {"kind", "ordering", "items", "nextCursor", "mediaReady", "scope" if operation == "meetings" else "meetingId"}
        if set(value) != expected or type(value["items"]) is not list or len(value["items"]) > options["limit"]:
            raise RuntimeUnavailable()
        if operation == "meetings":
            if value["scope"] != options["scope"] or value["ordering"] != MEETING_ORDER:
                raise RuntimeUnavailable()
            previous = None; seen = set()
            for source in value["items"]:
                item = _meeting(source)
                if (item["kind"] != options["scope"] or item["meetingId"] in seen
                        or any(options.get(key) is not None and item[field] != options[key]
                               for key, field in (("country_code", "countryCode"), ("region", "region")))):
                    raise RuntimeUnavailable()
                anchor = (item["startsAt"] is not None, item["startsAt"] or "", item["meetingId"].encode())
                if previous is not None and anchor <= previous:
                    raise RuntimeUnavailable()
                previous = anchor; seen.add(item["meetingId"])
        else:
            if value["meetingId"] != resource or value["ordering"] != PARTICIPANT_ORDER:
                raise RuntimeUnavailable()
            previous = None
            for item in value["items"]:
                if (type(item) is not dict or set(item) != _PARTICIPANT_KEYS
                        or item["avatar"] is not None or item["mediaReady"] is not False):
                    raise RuntimeUnavailable()
                uid = _output_uid(item["uid"])
                if previous is not None and uid.encode() <= previous.encode():
                    raise RuntimeUnavailable()
                previous = uid
                _text(item["fullName"], 1000, nullable=True); _text(item["primaryGroup"], 191, nullable=True)
                _timestamp(item["joinedAt"], nullable=True); _number(item["membershipRevision"])
        # Empty sparse pages with a valid continuation are intentionally valid.
        _next_cursor(value["nextCursor"], options)
    try:
        canonical_json(value, max_bytes=MAX_PUBLIC_BYTES)
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None
    return value


class RuntimeMeetingsHttp:
    def __init__(self, env, store, *, service_factory=None):
        self._enabled = (env.get("CLRS_RUNTIME_WRITES_ENABLED") == "1"
            and env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") == "canonical-current-v1")
        self._env = dict(env); self._store = store; self._factory = service_factory
        self._service = None; self._attempted = False; self._closed = False
        self._lock = threading.Lock()

    def close(self):
        # Caller owns the shared current transaction pool and its drain/close.
        with self._lock:
            self._closed = True; self._service = None

    def _reader(self):
        with self._lock:
            if self._closed or self._store is None:
                raise RuntimeUnavailable()
            if not self._attempted:
                self._attempted = True
                factory = self._factory or RuntimeMeetingsService.from_env
                try:
                    # Never supply trusted_policy or infer it from source/env.
                    self._service = factory(self._store, self._env)
                except Exception:
                    raise RuntimeUnavailable() from None
            if self._service is None:
                raise RuntimeUnavailable()
            return self._service

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        try:
            route = _route(environ)
        except RuntimeInvalidRequest:
            return RuntimeMeetingsHttpReply("400 Bad Request", {"error": "invalid_request"})
        if route is None:
            return None
        if not self._enabled:
            return RuntimeMeetingsHttpReply("404 Not Found", {"error": "not_found"})
        if environ.get("REQUEST_METHOD") != "GET":
            return RuntimeMeetingsHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        operation, resource = route
        try:
            options = _options(environ, operation)
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (type(header) is not str or not header.startswith("Bearer na1.")
                    or len(header) > 135 or any(c.isspace() for c in header[7:])
                    or native_configured is not True):
                raise NativeRejected()
            token = header[7:]
            try:
                _parse(token, "na1")
            except SessionRejected:
                raise NativeRejected() from None
            if native_service is None:
                raise NativeUnavailable()
            identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
            if type(identity) is not NativeIdentity:
                raise NativeUnavailable()
            reader = self._reader()
            if operation == "meetings":
                value = reader.meetings(identity, access_token=token, **options)
            elif operation == "archived-messages":
                value = reader.archived_messages(identity, resource, access_token=token, **options)
            elif operation == "messages":
                value = reader.messages(identity, resource, access_token=token, **options)
            elif operation == "meeting":
                value = reader.meeting(identity, resource, access_token=token)
            else:
                value = reader.participants(identity, resource, access_token=token, **options)
            value = _result(value, operation, resource, options)
            with self._lock:
                if self._closed:
                    raise RuntimeUnavailable()
            return RuntimeMeetingsHttpReply("200 OK", value)
        except RuntimeInvalidRequest:
            return RuntimeMeetingsHttpReply("400 Bad Request", {"error": "invalid_request"})
        except RuntimeReadRejected:
            return RuntimeMeetingsHttpReply("404 Not Found", {"error": "archive_unavailable" if operation == "archived-messages" else ("meeting_unavailable" if operation == "messages" else "not_found")})
        except (NativeRejected, RuntimeRejected):
            return RuntimeMeetingsHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
        except NativeRateLimited:
            return RuntimeMeetingsHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except Exception:
            return RuntimeMeetingsHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
