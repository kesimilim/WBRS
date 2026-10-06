"""Default-off, native-only profile-photo HTTP with a caller-owned factory.

There is deliberately no production media factory or legacy authorization.
Prime the verified lease before HTTP 200 so its fresh first-byte SQL guard can
still return a normal 400/401/404/503 response without misleading headers.
"""
from __future__ import annotations

import math
import re
import threading
import time
from typing import NamedTuple
from urllib.parse import parse_qsl

from legacy_private_media import CHUNK_BYTES, MIME_TYPES
from legacy_private_media_http import MediaHttpBody, MediaHttpReply
from native_auth import NativeRejected, NativeUnavailable, NativeRateLimited
from native_sessions import NativeIdentity
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_profile_photos import (_PhotoLease, _uid, RuntimeProfilePhotoNotFound,
    MAX_IMAGE_BYTES, MAX_PAGE, MAX_PHOTOS, MAX_PUBLIC_BYTES, REFERENCE_SECONDS)


_PATH = re.compile(r"/v1/runtime/people/([^/]+)/photos(/content)?\Z")
_OPAQUE = re.compile(r"[A-Za-z0-9_-]{1,4096}\Z")


class RuntimeProfilePhotosHttpReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


def _error(error):
    if isinstance(error, RuntimeProfilePhotoNotFound):
        return RuntimeProfilePhotosHttpReply("404 Not Found", {"error": "not_found"})
    if isinstance(error, RuntimeInvalidRequest):
        return RuntimeProfilePhotosHttpReply("400 Bad Request", {"error": "invalid_request"})
    if isinstance(error, (NativeRejected, RuntimeRejected)):
        return RuntimeProfilePhotosHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
    if isinstance(error, NativeRateLimited):
        return RuntimeProfilePhotosHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
    return RuntimeProfilePhotosHttpReply("503 Service Unavailable", {"error": "service_unavailable"})


def _target(component):
    try:
        # PATH_INFO is already URL-decoded by WSGI. Never unquote it twice or
        # accept a slash/escape alias as another exact UID component.
        if any(c in component for c in "%\\?#"): raise RuntimeInvalidRequest()
        try:
            component = component.encode("latin-1").decode("utf-8", "strict")
        except UnicodeEncodeError:
            # Some trusted WSGI test/adaptation layers expose decoded Unicode.
            pass
        return _uid(component)
    except (UnicodeError, RuntimeInvalidRequest):
        raise RuntimeInvalidRequest() from None


def _options(environ, content):
    if (any(type(key) is str and key.upper() in {"HTTP_RANGE", "HTTP_IF_RANGE"} for key in environ)
            or environ.get("HTTP_TRANSFER_ENCODING")
            or environ.get("CONTENT_LENGTH", "") not in ("", "0")):
        raise RuntimeInvalidRequest()
    raw = environ.get("QUERY_STRING", "")
    if (type(raw) is not str or len(raw) > 8192
            or re.search(r"%(?![a-fA-F0-9]{2})", raw)
            or any(ord(c) < 32 or ord(c) > 126 for c in raw)):
        raise RuntimeInvalidRequest()
    try:
        entries = parse_qsl(raw, keep_blank_values=True, strict_parsing=True,
            encoding="utf-8", errors="strict", max_num_fields=1 if content else 2)
    except (ValueError, UnicodeError):
        raise RuntimeInvalidRequest() from None
    values = dict(entries)
    if len(values) != len(entries): raise RuntimeInvalidRequest()
    if content:
        if set(values) != {"reference"} or _OPAQUE.fullmatch(values["reference"]) is None:
            raise RuntimeInvalidRequest()
        return values
    if set(values) - {"limit", "cursor"}: raise RuntimeInvalidRequest()
    limit = values.get("limit", "30")
    if re.fullmatch(r"[1-9][0-9]?", limit) is None or int(limit) > MAX_PAGE:
        raise RuntimeInvalidRequest()
    options = {"limit": int(limit)}
    if "cursor" in values:
        if _OPAQUE.fullmatch(values["cursor"]) is None: raise RuntimeInvalidRequest()
        options["cursor"] = values["cursor"]
    return options


def _page(value, target_uid, options):
    if (type(value) is not dict or set(value) != {"kind", "targetUid", "ordering", "items", "nextCursor"}
            or value["kind"] != "canonical-profile-photos" or value["targetUid"] != target_uid
            or value["ordering"] != "ordinal_asc" or type(value["items"]) is not list
            or len(value["items"]) > options["limit"]):
        raise RuntimeUnavailable()
    previous = None
    for item in value["items"]:
        if (type(item) is not dict or set(item) != {"ordinal", "isPrimary", "contentType", "byteSize", "reference"}
                or type(item["ordinal"]) is not int or not 0 <= item["ordinal"] < MAX_PHOTOS
                or previous is not None and item["ordinal"] != previous + 1
                or type(item["isPrimary"]) is not bool or item["isPrimary"] != (item["ordinal"] == 0)
                or item["contentType"] not in MIME_TYPES or type(item["byteSize"]) is not int
                or not 0 < item["byteSize"] <= MAX_IMAGE_BYTES
                or type(item["reference"]) is not str or _OPAQUE.fullmatch(item["reference"]) is None):
            raise RuntimeUnavailable()
        previous = item["ordinal"]
    if ("cursor" not in options and value["items"] and value["items"][0]["ordinal"] != 0):
        raise RuntimeUnavailable()
    cursor = value["nextCursor"]
    if cursor is not None and (type(cursor) is not str or _OPAQUE.fullmatch(cursor) is None
            or cursor == options.get("cursor") or not value["items"]):
        raise RuntimeUnavailable()
    try:
        canonical_json(value, max_bytes=MAX_PUBLIC_BYTES)
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None
    return value


class _PhotoHttpBody(MediaHttpBody):
    def __init__(self, lease, check_open):
        super().__init__(lease)
        self._pending = None; self._remaining = lease.size; self._check_open = check_open

    def prime(self):
        self._check_open(); self._lease.__enter__()
        try:
            self._pending = next(self._iterator)
        except StopIteration:
            raise RuntimeUnavailable() from None
        self._validate(self._pending)

    def _validate(self, block):
        if type(block) is not bytes or not 0 < len(block) <= min(CHUNK_BYTES, self._remaining):
            raise RuntimeUnavailable()

    def __next__(self):
        if self._closed: raise StopIteration
        try:
            self._check_open(); self._lease.__enter__()
            if self._pending is not None:
                block = self._pending; self._pending = None
            else:
                try:
                    block = next(self._iterator)
                except StopIteration:
                    if self._remaining: raise RuntimeUnavailable() from None
                    self.close(); raise
            self._validate(block); self._remaining -= len(block)
            return block
        except BaseException:
            self.close()
            raise

    def close(self):
        if self._closed: return
        self._closed = True
        self._pending = None
        try:
            cleanup = getattr(self._iterator, "close", None)
            if callable(cleanup): cleanup()
        finally:
            self._lease.close()


class RuntimeProfilePhotoMediaReply(MediaHttpReply):
    def __init__(self, lease, check_open):
        super().__init__(lease); self._check_open = check_open

    def respond(self, start_response):
        body = None
        try:
            if (type(self._lease) is not _PhotoLease or self._lease.content_type not in MIME_TYPES
                    or type(self._lease.size) is not int or not 0 < self._lease.size <= MAX_IMAGE_BYTES):
                raise RuntimeUnavailable()
            body = _PhotoHttpBody(self._lease, self._check_open)
            body.prime()  # fresh current SQL authority BEFORE any 200 headers
            self._check_open(); self._lease.__enter__()
        except Exception as error:
            if body is not None: body.close()
            else: self._lease.close()
            return _error(error)
        except BaseException:
            if body is not None: body.close()
            else: self._lease.close()
            raise
        try:
            headers = [("Content-Type", self._lease.content_type), ("Content-Length", str(self._lease.size)),
                ("Cache-Control", "private, no-store"), ("X-Content-Type-Options", "nosniff"),
                ("Content-Disposition", "attachment; filename=media"), ("Referrer-Policy", "no-referrer")]
            start_response("200 OK", headers)
            return body
        except BaseException:
            # A failed start_response may already have started headers. Close
            # resources and propagate; never start a second JSON response.
            body.close()
            raise


class RuntimeProfilePhotosHttp:
    def __init__(self, env, *, service_factory=None, monotonic=time.monotonic):
        self._enabled = (callable(service_factory) and env.get("CLRS_RUNTIME_WRITES_ENABLED") == "1"
            and env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") == "canonical-current-v1")
        self._factory = service_factory; self._monotonic = monotonic
        self._service = None; self._attempted = False; self._closed = False; self._lock = threading.Lock()

    def _check_open(self):
        with self._lock:
            if self._closed: raise RuntimeUnavailable()

    def _reader(self):
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
            if self._service is not None: return self._service
            if self._attempted: raise RuntimeUnavailable()
            self._attempted = True
        # Factory is trusted caller setup, not request data. Do not hold an
        # owner lock across it: close during initialization must fail closed.
        service = None
        try:
            service = self._factory()
            if not all(callable(getattr(service, name, None)) for name in ("photos", "open_photo", "close")):
                raise RuntimeUnavailable()
        except Exception:
            cleanup = getattr(service, "close", None)
            if callable(cleanup): cleanup()
            raise RuntimeUnavailable() from None
        with self._lock:
            closed = self._closed
            if not closed: self._service = service
        if closed:
            service.close(); raise RuntimeUnavailable()
        return service

    def close(self):
        with self._lock:
            self._closed = True; service = self._service; self._service = None
        if service is not None: service.close()

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        path = environ.get("PATH_INFO", "")
        match = _PATH.fullmatch(path) if type(path) is str else None
        if match is None: return None
        if not self._enabled: return RuntimeProfilePhotosHttpReply("404 Not Found", {"error": "not_found"})
        if environ.get("REQUEST_METHOD") != "GET":
            return RuntimeProfilePhotosHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        lease = None
        try:
            self._check_open(); target_uid = _target(match[1]); content = bool(match[2])
            options = _options(environ, content)
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (type(header) is not str or not header.startswith("Bearer na1.") or len(header) > 135
                    or any(c.isspace() for c in header[7:]) or not native_configured):
                raise NativeRejected()
            if native_service is None: raise NativeUnavailable()
            token = header[7:]
            identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
            if type(identity) is not NativeIdentity: raise NativeUnavailable()
            if not content:
                page = _page(self._reader().photos(identity, target_uid, access_token=token, **options), target_uid, options)
                self._check_open()
                return RuntimeProfilePhotosHttpReply("200 OK", page)
            begin = environ.get("clrs.media_request_budget")
            if not callable(begin): raise RuntimeUnavailable()
            deadline, cancel = begin(); now = self._monotonic()
            if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                    or not now < deadline <= now + REFERENCE_SECONDS
                    or not isinstance(cancel, threading.Event) or cancel.is_set()):
                raise RuntimeUnavailable()
            lease = self._reader().open_photo(identity, target_uid, access_token=token,
                request_cancel=cancel, request_deadline=deadline, **options)
            if type(lease) is not _PhotoLease: raise RuntimeUnavailable()
            self._check_open()
            return RuntimeProfilePhotoMediaReply(lease, self._check_open)
        except Exception as error:
            if callable(getattr(lease, "close", None)): lease.close()
            return _error(error)
