"""GET-only private media port. Unused until an authorized core enables it.

Input records must come from exact SQL authorization and reviewed logical
promotion to ready. This adapter does not make quarantine objects public or
authorize an arbitrary caller. No SDK, presign, redirect, range, retry or write.
"""
from __future__ import annotations

import datetime
import hashlib
import hmac
import http.client
import json
import math
import re
import socket
import ssl
import threading
import time
import xml.etree.ElementTree as ET


PREFIX = "clrs-import-quarantine/"
MAX_OBJECT_BYTES = 64_000_000
CHUNK_BYTES = 65_536
MAX_CONTROL_BYTES = 65_536
MAX_REQUEST_SECONDS = 120
PRIVACY_MAX_AGE = 5
CONTENT_TYPES = frozenset({"image/jpeg", "image/png", "image/webp", "image/gif",
    "audio/mpeg", "audio/mp4", "audio/ogg", "audio/aac", "video/mp4",
    "application/pdf", "application/octet-stream"})
_SETUP_SLOTS = threading.BoundedSemaphore(4)
_EMPTY_HASH = hashlib.sha256(b"").hexdigest()


class PrivateMediaUnavailable(Exception):
    """Intentionally empty: never disclose a key, URL, token or upstream error."""


def _bucket(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", value) or ".." in value:
        raise PrivateMediaUnavailable()
    return value


def _key(value):
    if not isinstance(value, str) or not re.fullmatch(re.escape(PREFIX) + r"[a-f0-9]{64}", value):
        raise PrivateMediaUnavailable()
    return value


def _headers(response):
    result = {}; total = 0
    for name, value in response.headers:
        if (not isinstance(name, str) or not isinstance(value, str)
                or not re.fullmatch(r"[A-Za-z0-9-]{1,100}", name)
                or any(ord(ch) < 32 or ord(ch) == 127 for ch in value)):
            raise PrivateMediaUnavailable()
        total += len(name.encode()) + len(value.encode())
        if total > 16_384:
            raise PrivateMediaUnavailable()
        name = name.lower()
        if name in result:
            raise PrivateMediaUnavailable()
        result[name] = value
    if ("transfer-encoding" in result or "content-range" in result
            or result.get("content-encoding", "identity") != "identity"):
        raise PrivateMediaUnavailable()
    return result


def _length(headers, maximum):
    value = headers.get("content-length", "")
    if not re.fullmatch(r"0|[1-9][0-9]{0,8}", value) or int(value) > maximum:
        raise PrivateMediaUnavailable()
    return int(value)


def _json_pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise PrivateMediaUnavailable()
        result[key] = value
    return result


def _owner_acl(raw, expected):
    if b"<!" in raw:
        raise PrivateMediaUnavailable()
    try:
        root = ET.fromstring(raw)
        for node in root.iter():
            node.tag = node.tag.split("}", 1)[-1]
        if root.tag != "AccessControlPolicy" or [node.tag for node in root] != ["Owner", "AccessControlList"]:
            raise PrivateMediaUnavailable()
        owner = root.find("Owner")
        if ([node.tag for node in owner].count("ID") != 1
                or any(node.tag not in {"ID", "DisplayName"} for node in owner)
                or owner.findtext("ID") != expected):
            raise PrivateMediaUnavailable()
        grants = list(root.find("AccessControlList"))
        if len(grants) != 1 or grants[0].tag != "Grant":
            raise PrivateMediaUnavailable()
        grant = grants[0]
        if [node.tag for node in grant] != ["Grantee", "Permission"] or grant.findtext("Permission") != "FULL_CONTROL":
            raise PrivateMediaUnavailable()
        grantee = grant.find("Grantee")
        kinds = list(grantee.attrib.values())
        children = [node.tag for node in grantee]
        if (grantee.findtext("ID") != expected or children.count("ID") != 1
                or children.count("Type") > 1 or children.count("DisplayName") > 1
                or any(tag not in {"ID", "DisplayName", "Type"} for tag in children)
                or set(grantee.attrib) - {"{http://www.w3.org/2001/XMLSchema-instance}type"}
                or (kinds and kinds != ["CanonicalUser"])
                or (not kinds and grantee.findtext("Type") != "CanonicalUser")
                or grantee.findtext("Type", "CanonicalUser") != "CanonicalUser"):
            raise PrivateMediaUnavailable()
    except (ET.ParseError, AttributeError, TypeError):
        raise PrivateMediaUnavailable() from None


class PrivateMediaS3:
    """transport.open(op,bucket,key,deadline,cancel) -> status/headers/read/close.

    bucket_state(bucket,deadline,cancel) must issue an authenticated GET-only
    Timeweb bucket lookup and return exact {bucket,type,checked_at}; checked_at
    uses this monotonic clock. Separate least-privilege credentials are required.
    sink is a private seekable temporary binary file, never an HTTP output stream.
    """
    def __init__(self, bucket, expected_owner, transport, bucket_state, *, monotonic=time.monotonic):
        self._bucket = _bucket(bucket)
        if (not isinstance(expected_owner, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,191}", expected_owner)
                or not callable(getattr(transport, "open", None)) or not callable(bucket_state)):
            raise PrivateMediaUnavailable()
        self._owner = expected_owner; self._transport = transport
        self._state = bucket_state; self._clock = monotonic

    def _check(self, deadline, cancel):
        if cancel.is_set() or self._clock() >= deadline:
            raise PrivateMediaUnavailable()

    def _control(self, operation, key, deadline, cancel, *, absent_policy=False):
        self._check(deadline, cancel)
        response = self._transport.open(operation, self._bucket, key, deadline, cancel)
        try:
            self._check(deadline, cancel)
            headers = _headers(response); length = _length(headers, MAX_CONTROL_BYTES)
            if response.status != 200 and not (absent_policy and response.status == 404):
                raise PrivateMediaUnavailable()
            raw = bytearray()
            while True:
                self._check(deadline, cancel)
                chunk = response.read(min(CHUNK_BYTES, length - len(raw) + 1))
                if not isinstance(chunk, bytes) or len(raw) + len(chunk) > length:
                    raise PrivateMediaUnavailable()
                if not chunk:
                    break
                raw.extend(chunk)
            if len(raw) != length:
                raise PrivateMediaUnavailable()
            if response.status == 404:
                if b"<!" in raw:
                    raise PrivateMediaUnavailable()
                root = ET.fromstring(raw)
                if root.tag.split("}", 1)[-1] != "Error" or root.findtext("Code") != "NoSuchBucketPolicy":
                    raise PrivateMediaUnavailable()
                return None
            return bytes(raw)
        finally:
            response.close()

    def _privacy(self, deadline, cancel):
        self._check(deadline, cancel)
        state = self._state(self._bucket, deadline, cancel)
        now = self._clock()
        if (not isinstance(state, dict) or set(state) != {"bucket", "type", "checked_at"}
                or state["bucket"] != self._bucket or state["type"] != "private"
                or type(state["checked_at"]) not in {int, float} or not math.isfinite(state["checked_at"])
                or not 0 <= now - state["checked_at"] <= PRIVACY_MAX_AGE):
            raise PrivateMediaUnavailable()
        _owner_acl(self._control("GetBucketAcl", None, deadline, cancel), self._owner)
        policy = self._control("GetBucketPolicy", None, deadline, cancel, absent_policy=True)
        if policy is not None:
            value = json.loads(policy, object_pairs_hook=_json_pairs)
            if (not isinstance(value, dict) or set(value) != {"Version", "Statement"}
                    or value["Version"] != "2012-10-17" or value["Statement"] != []):
                raise PrivateMediaUnavailable()
        self._check(deadline, cancel)
        if self._clock() - state["checked_at"] > PRIVACY_MAX_AGE:
            raise PrivateMediaUnavailable()
        return state["checked_at"]

    def get_verified_to_file(self, record, sink, deadline, cancel):
        response = None; sink_accepted = False
        try:
            if (not isinstance(record, dict) or set(record) != {"key", "size", "sha256", "content_type"}
                    or type(record["size"]) is not int or not 0 <= record["size"] <= MAX_OBJECT_BYTES
                    or not isinstance(record["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", record["sha256"])
                    or record["content_type"] not in CONTENT_TYPES
                    or type(deadline) not in {int, float} or not math.isfinite(deadline)
                    or not callable(getattr(cancel, "is_set", None))
                    or not all(callable(getattr(sink, method, None)) for method in ["write", "tell", "seek", "truncate", "flush"])
                    or sink.tell() != 0):
                raise PrivateMediaUnavailable()
            key = _key(record["key"])
            sink.seek(0, 2)
            if sink.tell() != 0:
                raise PrivateMediaUnavailable()
            sink.seek(0); sink_accepted = True
            deadline = min(deadline, self._clock() + MAX_REQUEST_SECONDS)
            checked_at = self._privacy(deadline, cancel)
            _owner_acl(self._control("GetObjectAcl", key, deadline, cancel), self._owner)
            if self._clock() - checked_at > PRIVACY_MAX_AGE:
                raise PrivateMediaUnavailable()
            response = self._transport.open("GetObject", self._bucket, key, deadline, cancel)
            headers = _headers(response)
            if (response.status != 200 or _length(headers, MAX_OBJECT_BYTES) != record["size"]
                    or headers.get("content-type") != record["content_type"]):
                raise PrivateMediaUnavailable()
            digest = hashlib.sha256(); total = 0
            while True:
                self._check(deadline, cancel)
                amount = min(CHUNK_BYTES, record["size"] - total + 1)
                chunk = response.read(amount)
                if not isinstance(chunk, bytes) or len(chunk) > amount or total + len(chunk) > record["size"]:
                    raise PrivateMediaUnavailable()
                if not chunk:
                    break
                offset = 0
                while offset < len(chunk):
                    self._check(deadline, cancel)
                    written = sink.write(chunk[offset:])
                    if type(written) is not int or not 1 <= written <= len(chunk) - offset:
                        raise PrivateMediaUnavailable()
                    offset += written
                digest.update(chunk); total += len(chunk)
            response.close(); response = None
            if total != record["size"] or not hmac.compare_digest(digest.hexdigest(), record["sha256"]):
                raise PrivateMediaUnavailable()
            # Privacy may have changed while a larger full object was downloaded.
            checked_at = self._privacy(deadline, cancel)
            _owner_acl(self._control("GetObjectAcl", key, deadline, cancel), self._owner)
            if self._clock() - checked_at > PRIVACY_MAX_AGE:
                raise PrivateMediaUnavailable()
            self._check(deadline, cancel)
            sink.flush(); sink.truncate(total); sink.seek(0)
            return {"size": total, "sha256": record["sha256"], "headers": {
                "Content-Length": str(total), "Content-Type": record["content_type"],
                "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
                "Content-Disposition": "attachment; filename=media"}}
        except Exception:
            if sink_accepted:
                try:
                    sink.seek(0); sink.truncate(0)
                except Exception:
                    pass
            raise PrivateMediaUnavailable() from None
        finally:
            if response is not None:
                try:
                    response.close()
                except Exception:
                    pass


def _signed_headers(method, host, path, query, region, service, access_key, secret_key, stamp, token=None):
    """Internal deterministic SigV4 helper; only the transport exposes GET."""
    headers = {"host": host, "x-amz-content-sha256": _EMPTY_HASH, "x-amz-date": stamp}
    if token is not None:
        headers["x-amz-security-token"] = token
    names = ";".join(sorted(headers))
    canonical = "\n".join([method, path, query,
        "".join(name + ":" + headers[name] + "\n" for name in sorted(headers)), names, _EMPTY_HASH])
    scope = stamp[:8] + "/" + region + "/" + service + "/aws4_request"
    value = "\n".join(["AWS4-HMAC-SHA256", stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = ("AWS4" + secret_key).encode()
    for part in [stamp[:8], region, service, "aws4_request"]:
        key = hmac.digest(key, part.encode(), "sha256")
    signature = hmac.digest(key, value.encode(), "sha256").hex()
    headers["authorization"] = "AWS4-HMAC-SHA256 Credential=" + access_key + "/" + scope + ", SignedHeaders=" + names + ", Signature=" + signature
    return headers


class _Lease:
    def __init__(self, connection, deadline, cancel, clock):
        self.connection = connection; self.socket = None; self.closed = threading.Event()
        self.deadline = deadline; self.cancel = cancel; self.clock = clock
        self._lock = threading.Lock()
        self._watcher = threading.Thread(target=self._watch, daemon=True); self._watcher.start()

    def _watch(self):
        try:
            while not self.closed.wait(0.025):
                if self.cancel.is_set() or self.clock() >= self.deadline:
                    self.close()
        except Exception:
            self.close()

    def check(self):
        if self.closed.is_set() or self.cancel.is_set() or self.clock() >= self.deadline:
            self.close(); raise PrivateMediaUnavailable()

    def attach_socket(self):
        with self._lock:
            self.socket = self.connection.sock
        self.check()

    def close(self):
        self.closed.set()
        with self._lock:
            stream = self.socket
        if stream is not None:
            try:
                stream.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
        try:
            self.connection.close()
        except Exception:
            pass


class _Response:
    def __init__(self, response, lease):
        self._response = response; self._lease = lease
        self.status = response.status; self.headers = response.getheaders()

    def read(self, maximum):
        try:
            self._lease.check()
            if type(maximum) is not int or not 1 <= maximum <= CHUNK_BYTES:
                raise PrivateMediaUnavailable()
            # http.client closes the response file when Content-Length bytes
            # are consumed. A final bounded EOF read must not touch its closed
            # socket; the caller still checks the exact length and checksum.
            if isinstance(self._response, http.client.HTTPResponse) and self._response.isclosed():
                return b""
            self._lease.socket.settimeout(min(2, max(0.001, self._lease.deadline - self._lease.clock())))
            result = self._response.read(maximum)
            self._lease.check()
            return result
        except Exception:
            self._lease.close()
            raise PrivateMediaUnavailable() from None

    def close(self):
        self._lease.close()
        try:
            self._response.close()
        except Exception:
            raise PrivateMediaUnavailable() from None


def _https_get(factory, path, headers, deadline, cancel, clock):
    lease = None; response = None; slot_owned = False
    try:
        if (type(deadline) not in {int, float} or not math.isfinite(deadline)
                or not callable(getattr(cancel, "is_set", None)) or cancel.is_set() or deadline <= clock()
                or not _SETUP_SLOTS.acquire(blocking=False)):
            raise PrivateMediaUnavailable()
        slot_owned = True
        deadline = min(deadline, clock() + MAX_REQUEST_SECONDS)
        connection = factory()
        lease = _Lease(connection, deadline, cancel, clock)
        result = []; done = threading.Event()
        def setup():
            try:
                lease.check(); connection.connect(); lease.attach_socket()
                connection.request("GET", path, headers=headers)
                lease.check(); candidate = connection.getresponse()
                with lease._lock:
                    if lease.closed.is_set():
                        candidate.close(); raise PrivateMediaUnavailable()
                    result.append(candidate)
            except Exception:
                lease.close()
            finally:
                done.set(); _SETUP_SLOTS.release()
        worker = threading.Thread(target=setup, daemon=True)
        worker.start(); slot_owned = False
        setup_deadline = min(deadline, clock() + 5)
        while not done.wait(0.025):
            lease.check()
            if clock() >= setup_deadline:
                raise PrivateMediaUnavailable()
        lease.check()
        if len(result) != 1:
            raise PrivateMediaUnavailable()
        response = result[0]
        return _Response(response, lease)
    except Exception:
        if lease is not None:
            lease.close()
        if response is not None:
            response.close()
        elif "result" in locals():
            for candidate in result:
                try:
                    candidate.close()
                except Exception:
                    pass
        raise PrivateMediaUnavailable() from None
    finally:
        if slot_owned:
            _SETUP_SLOTS.release()


def _https_factory(host):
    context = ssl.create_default_context(); context.minimum_version = ssl.TLSVersion.TLSv1_2
    return lambda: http.client.HTTPSConnection(host, 443, timeout=2, context=context)


class TimewebPrivateBucketState:
    """Concrete GET-only control-plane probe using a separate read API token."""
    def __init__(self, bucket_id, bucket, token, *, connection_factory=None, monotonic=time.monotonic):
        if (type(bucket_id) is not int or not 1 <= bucket_id <= 2 ** 63 - 1
                or not isinstance(token, str) or not 8 <= len(token) <= 4096
                or any(ord(ch) < 33 or ord(ch) > 126 for ch in token)):
            raise PrivateMediaUnavailable()
        self._id = bucket_id; self._bucket = _bucket(bucket); self._token = token; self._clock = monotonic
        self._factory = connection_factory or _https_factory("api.timeweb.cloud")

    def __call__(self, bucket, deadline, cancel):
        response = None
        try:
            if bucket != self._bucket or type(deadline) not in {int, float} or not math.isfinite(deadline):
                raise PrivateMediaUnavailable()
            deadline = min(deadline, self._clock() + PRIVACY_MAX_AGE)
            headers = {"host": "api.timeweb.cloud", "authorization": "Bearer " + self._token,
                "accept": "application/json", "accept-encoding": "identity", "connection": "close",
                "cache-control": "no-store"}
            response = _https_get(self._factory, "/api/v1/storages/buckets/" + str(self._id), headers, deadline, cancel, self._clock)
            found_headers = _headers(response); length = _length(found_headers, MAX_CONTROL_BYTES)
            if response.status != 200 or found_headers.get("content-type", "").split(";")[0].strip() != "application/json":
                raise PrivateMediaUnavailable()
            raw = bytearray()
            while True:
                chunk = response.read(min(CHUNK_BYTES, length - len(raw) + 1))
                if not isinstance(chunk, bytes) or len(raw) + len(chunk) > length:
                    raise PrivateMediaUnavailable()
                if not chunk:
                    break
                raw.extend(chunk)
            if len(raw) != length:
                raise PrivateMediaUnavailable()
            value = json.loads(raw, object_pairs_hook=_json_pairs)
            found = value.get("bucket") if isinstance(value, dict) else None
            if (not isinstance(found, dict) or type(found.get("id")) is not int or found["id"] != self._id
                    or found.get("name") != self._bucket or found.get("type") != "private"):
                raise PrivateMediaUnavailable()
            website = found.get("website_config")
            if website is not None and (not isinstance(website, dict) or website.get("enabled") is not False):
                raise PrivateMediaUnavailable()
            if cancel.is_set() or self._clock() >= deadline:
                raise PrivateMediaUnavailable()
            return {"bucket": self._bucket, "type": "private", "checked_at": self._clock()}
        except Exception:
            raise PrivateMediaUnavailable() from None
        finally:
            if response is not None:
                response.close()


class SigV4HTTPSReadTransport:
    """Concrete stdlib TLS/SigV4 port, fixed Timeweb endpoint, no network retries.

    Connection setup runs in at most four daemon workers, so even a stalled
    platform DNS resolver cannot make the caller wait past its deadline. A late
    setup result is closed. Production DNS/TLS/S3 acceptance is still required.
    """
    def __init__(self, endpoint, region, access_key, secret_key, *, session_token=None,
            connection_factory=None, monotonic=time.monotonic, wall_clock=None):
        if (endpoint != "https://s3.twcstorage.ru/" or not isinstance(region, str)
                or not re.fullmatch(r"[a-z0-9-]{1,40}", region)
                or not isinstance(access_key, str) or not re.fullmatch(r"[A-Za-z0-9_-]{3,128}", access_key)
                or not isinstance(secret_key, str) or not 1 <= len(secret_key) <= 2048
                or any(ord(ch) < 33 or ord(ch) > 126 for ch in secret_key)
                or (session_token is not None and (not isinstance(session_token, str) or not 1 <= len(session_token) <= 4096
                    or any(ord(ch) < 33 or ord(ch) > 126 for ch in session_token)))):
            raise PrivateMediaUnavailable()
        self._region = region; self._access = access_key; self._secret = secret_key; self._token = session_token
        self._clock = monotonic; self._wall = wall_clock or (lambda: datetime.datetime.now(datetime.timezone.utc))
        self._factory = connection_factory or _https_factory("s3.twcstorage.ru")

    def open(self, operation, bucket, key, deadline, cancel):
        try:
            _bucket(bucket)
            if operation in {"GetObject", "GetObjectAcl"}:
                _key(key)
                path = "/" + bucket + "/" + key
                query = "acl=" if operation == "GetObjectAcl" else ""
            elif operation in {"GetBucketAcl", "GetBucketPolicy"} and key is None:
                path = "/" + bucket; query = "acl=" if operation == "GetBucketAcl" else "policy="
            else:
                raise PrivateMediaUnavailable()
            stamp = self._wall().astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            headers = _signed_headers("GET", "s3.twcstorage.ru", path, query, self._region, "s3", self._access, self._secret, stamp, self._token)
            headers.update({"connection": "close", "accept-encoding": "identity"})
            return _https_get(self._factory, path + ("?" + query if query else ""), headers, deadline, cancel, self._clock)
        except Exception:
            raise PrivateMediaUnavailable() from None
