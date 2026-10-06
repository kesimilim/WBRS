"""Synthetic port/TLS/signing tests. No real SQL, S3, API or user values."""
import datetime
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading
import time
import unittest
from unittest.mock import patch
import private_media_s3 as media_port

from private_media_s3 import (CHUNK_BYTES, MAX_OBJECT_BYTES, PREFIX,
    PrivateMediaS3, PrivateMediaUnavailable, SigV4HTTPSReadTransport, TimewebPrivateBucketState, _signed_headers)


BUCKET = "synthetic-private-bucket"
OWNER = "synthetic-owner"
KEY = PREFIX + "a" * 64
BODY = b"synthetic full object"


def acl(owner=OWNER, *, grant_owner=None, permission="FULL_CONTROL", extra=""):
    return (f'<AccessControlPolicy><Owner><ID>{owner}</ID></Owner><AccessControlList>'
        f'<Grant><Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser">'
        f'<ID>{grant_owner or owner}</ID></Grantee><Permission>{permission}</Permission></Grant>'
        f'{extra}</AccessControlList></AccessControlPolicy>').encode()


def record(body=BODY):
    return {"key": KEY, "size": len(body), "sha256": hashlib.sha256(body).hexdigest(), "content_type": "image/jpeg"}


class Reply:
    def __init__(self, body, *, status=200, content_type="application/xml", headers=None, hook=None):
        self.status = status; self.body = io.BytesIO(body); self.closed = False
        self.headers = headers if headers is not None else [("Content-Length", str(len(body))), ("Content-Type", content_type)]
        self.read_sizes = []; self.hook = hook

    def read(self, maximum):
        self.read_sizes.append(maximum)
        if self.hook:
            self.hook()
        return self.body.read(maximum)

    def close(self):
        self.closed = True


class Port:
    def __init__(self, body=BODY):
        self.body = body; self.calls = []; self.replies = []
        self.policy = b'{"Version":"2012-10-17","Statement":[]}'
        self.override = None

    def open(self, operation, bucket, key, deadline, cancel):
        self.calls.append((operation, bucket, key))
        if self.override:
            reply = self.override(operation)
            if reply is not None:
                self.replies.append(reply); return reply
        if operation == "GetObject":
            reply = Reply(self.body, content_type="image/jpeg")
        elif operation == "GetBucketPolicy":
            reply = Reply(self.policy, content_type="application/json")
        elif operation in {"GetObjectAcl", "GetBucketAcl"}:
            reply = Reply(acl())
        else:
            raise AssertionError("Unexpected operation")
        self.replies.append(reply); return reply


class PrivatePortTests(unittest.TestCase):
    def setUp(self):
        self.port = Port(); self.now = 0.0; self.cancel = threading.Event()
        self.probes = []
        self.state_override = None
        self.sink = io.BytesIO()
        def state(bucket, deadline, cancel):
            self.probes.append(bucket)
            return self.state_override or {"bucket": bucket, "type": "private", "checked_at": self.now}
        self.media = PrivateMediaS3(BUCKET, OWNER, self.port, state, monotonic=lambda: self.now)

    def fetch(self, value=None):
        return self.media.get_verified_to_file(value or record(self.port.body), self.sink, 100, self.cancel)

    def test_full_stream_then_rechecks_rewinds_and_only_safe_headers(self):
        self.port.body = b"x" * (CHUNK_BYTES * 2 + 13)
        result = self.fetch()
        self.assertEqual(self.port.body, self.sink.read())
        self.assertEqual(len(self.port.body), result["size"])
        self.assertEqual(2, len(self.probes))
        self.assertEqual(["GetBucketAcl", "GetBucketPolicy", "GetObjectAcl", "GetObject", "GetBucketAcl", "GetBucketPolicy", "GetObjectAcl"], [call[0] for call in self.port.calls])
        self.assertTrue(all(reply.closed for reply in self.port.replies))
        body_reply = self.port.replies[3]
        self.assertTrue(all(size <= CHUNK_BYTES for size in body_reply.read_sizes))
        self.assertEqual("private, no-store", result["headers"]["Cache-Control"])
        self.assertEqual("nosniff", result["headers"]["X-Content-Type-Options"])
        self.assertNotIn("Location", result["headers"])

    def test_record_key_shape_size_mime_sha_guard_before_any_request(self):
        changes = [{"key": "clrs-media-ready/" + "a" * 64}, {"key": PREFIX + "../x"},
            {"key": PREFIX + "A" * 64}, {"size": True}, {"size": MAX_OBJECT_BYTES + 1},
            {"size": -1}, {"sha256": "a" * 63}, {"content_type": "text/html"},
            {"content_type": "image/svg+xml"}, {"extra": "ignored"}]
        for change in changes:
            with self.subTest(change=change):
                with self.assertRaises(PrivateMediaUnavailable):
                    self.fetch({**record(), **change})
        self.assertEqual([], self.port.calls)
        self.assertEqual([], self.probes)

    def test_nonempty_sink_is_not_modified(self):
        self.sink = io.BytesIO(b"existing protected bytes")
        with self.assertRaises(PrivateMediaUnavailable):
            self.fetch()
        self.assertEqual(b"existing protected bytes", self.sink.getvalue())
        self.assertEqual([], self.port.calls)

    def test_bucket_state_must_match_private_fresh_not_future(self):
        for state in [{"bucket": BUCKET, "type": "public", "checked_at": 0},
                {"bucket": "other-bucket", "type": "private", "checked_at": 0},
                {"bucket": BUCKET, "type": "private", "checked_at": -6},
                {"bucket": BUCKET, "type": "private", "checked_at": 1},
                {"bucket": BUCKET, "type": "private", "checked_at": float("nan")},
                {"bucket": BUCKET, "type": "private", "checked_at": True}]:
            self.state_override = state
            with self.assertRaises(PrivateMediaUnavailable):
                self.fetch()
        self.assertEqual([], self.port.calls)

    def test_acl_owner_only_for_bucket_and_object_with_no_entities(self):
        invalid = [acl("other-owner"), acl(grant_owner="other-owner"), acl(permission="READ"),
            acl().replace(b' xsi:type="CanonicalUser"', b''),
            acl().replace(b'xsi:type="CanonicalUser"', b'xsi:unknown="CanonicalUser"'),
            acl(extra="<Grant><Grantee><URI>public</URI></Grantee><Permission>READ</Permission></Grant>"),
            b'<!DOCTYPE x [<!ENTITY leak "secret">]><AccessControlPolicy/>']
        for operation in ["GetBucketAcl", "GetObjectAcl"]:
            for raw in invalid:
                self.port.override = lambda op, operation=operation, raw=raw: Reply(raw) if op == operation else None
                with self.assertRaises(PrivateMediaUnavailable):
                    self.fetch()
        self.assertFalse(any(call[0] == "GetObject" for call in self.port.calls))

    def test_bucket_policy_exact_empty_or_absent_no_403_fallback(self):
        for raw in [b'{"Statement":[{"Effect":"Allow","Principal":"*"}]}',
                b'{"Statement":[],"Statement":[{}]}', b'{"Statement":[],"Other":true}', b'[]', b'{"Statement":[]}']:
            self.port.policy = raw
            with self.assertRaises(PrivateMediaUnavailable):
                self.fetch()
        self.port.override = lambda op: Reply(b'<Error><Code>NoSuchBucketPolicy</Code></Error>', status=404) if op == "GetBucketPolicy" else None
        self.fetch()
        self.sink = io.BytesIO()
        for code in [403, 405, 301]:
            self.port.override = lambda op, code=code: Reply(b'<Error><Code>AccessDenied</Code></Error>', status=code) if op == "GetBucketPolicy" else None
            with self.assertRaises(PrivateMediaUnavailable):
                self.fetch()

    def test_full_body_sha_and_length_mime_all_fail_without_partial_sink(self):
        for change in [{"sha256": "0" * 64}, {"size": len(BODY) + 1}, {"size": len(BODY) - 1}, {"content_type": "image/png"}]:
            with self.assertRaises(PrivateMediaUnavailable):
                self.fetch({**record(), **change})
            self.assertEqual(b"", self.sink.getvalue())
            self.assertTrue(all(reply.closed for reply in self.port.replies))

    def test_no_ranges_redirects_duplicate_or_encoded_headers(self):
        variants = [Reply(BODY, status=206, content_type="image/jpeg"), Reply(BODY, status=302, content_type="image/jpeg"),
            Reply(BODY, headers=[("Content-Length", str(len(BODY))), ("Content-Length", str(len(BODY))), ("Content-Type", "image/jpeg")]),
            Reply(BODY, headers=[("Content-Length", str(len(BODY))), ("Content-Type", "image/jpeg"), ("Transfer-Encoding", "chunked")]),
            Reply(BODY, headers=[("Content-Length", str(len(BODY))), ("Content-Type", "image/jpeg"), ("Content-Encoding", "gzip")]),
            Reply(BODY, headers=[("Content-Type", "image/jpeg")]),
            Reply(BODY, headers=[("Content-Length", str(len(BODY))), ("Content-Type", "image/jpeg\r\nInjected: yes")])]
        for reply in variants:
            self.port.override = lambda op, reply=reply: reply if op == "GetObject" else None
            with self.assertRaises(PrivateMediaUnavailable):
                self.fetch()
            self.assertTrue(reply.closed)
            self.assertEqual(b"", self.sink.getvalue())

    def test_deadline_cancel_slow_drip_and_privacy_change_after_body(self):
        self.cancel.set()
        with self.assertRaises(PrivateMediaUnavailable):
            self.fetch()
        self.assertEqual([], self.port.calls)
        self.cancel.clear()
        self.port.override = lambda op: Reply(BODY, content_type="image/jpeg", hook=lambda: setattr(self, "now", 101)) if op == "GetObject" else None
        with self.assertRaises(PrivateMediaUnavailable):
            self.fetch()
        self.assertEqual(b"", self.sink.getvalue())
        self.now = 0
        def hook():
            self.state_override = {"bucket": BUCKET, "type": "public", "checked_at": self.now}
        self.port.override = lambda op: Reply(BODY, content_type="image/jpeg", hook=hook) if op == "GetObject" else None
        with self.assertRaises(PrivateMediaUnavailable):
            self.fetch()
        self.assertEqual(b"", self.sink.getvalue())

    def test_privacy_control_duration_cannot_make_freshness_stale(self):
        self.port.override = lambda op: Reply(acl(), hook=lambda: setattr(self, "now", 6)) if op == "GetBucketAcl" else None
        with self.assertRaises(PrivateMediaUnavailable):
            self.fetch()
        self.assertFalse(any(call[0] == "GetObject" for call in self.port.calls))

    def test_short_writes_supported_and_failed_sink_never_verified(self):
        class ShortSink(io.BytesIO):
            def write(self, value):
                return super().write(value[:2])
        self.sink = ShortSink()
        self.fetch(); self.assertEqual(BODY, self.sink.getvalue())
        class FailedSink(io.BytesIO):
            def write(self, value):
                raise OSError("private-path-must-not-leak")
        self.sink = FailedSink()
        with self.assertRaises(PrivateMediaUnavailable) as error:
            self.fetch()
        self.assertEqual("", str(error.exception)); self.assertEqual(b"", self.sink.getvalue())

    def test_policy_actions_and_resources_are_exact_no_list_write_or_presign(self):
        value = json.loads((Path(__file__).parent.parent / "deploy/s3-runtime-read-policy.json").read_text())
        statements = value["Statement"]
        self.assertEqual({"s3:GetBucketAcl", "s3:GetBucketPolicy"}, set(statements[0]["Action"]))
        self.assertEqual({"s3:GetObject", "s3:GetObjectAcl"}, set(statements[1]["Action"]))
        self.assertTrue(statements[1]["Resource"].endswith("/" + PREFIX + "*"))
        self.assertTrue(all(item["Effect"] == "Allow" for item in statements))


class Sock:
    def __init__(self):
        self.closed = threading.Event(); self.timeouts = []
    def shutdown(self, how):
        self.closed.set()
    def settimeout(self, value):
        self.timeouts.append(value)


class WireReply:
    status = 200
    def __init__(self, sock, *, hang=False):
        self.sock = sock; self.hang = hang; self.closed = False
    def getheaders(self):
        return [("Content-Length", "1"), ("Content-Type", "image/jpeg")]
    def read(self, size):
        if self.hang:
            self.sock.closed.wait(2)
            raise OSError("sensitive-upstream-body")
        return b"x"
    def close(self):
        self.closed = True


class WireConnection:
    def __init__(self, *, connect_gate=None, body_hang=False):
        self.sock = None; self.connect_gate = connect_gate; self.body_hang = body_hang
        self.calls = []; self.closed = False; self.reply = None
    def connect(self):
        if self.connect_gate:
            self.connect_gate.wait(2)
        self.sock = Sock()
    def request(self, method, path, *, headers):
        self.calls.append((method, path, headers))
    def getresponse(self):
        self.reply = WireReply(self.sock, hang=self.body_hang); return self.reply
    def close(self):
        self.closed = True
        if self.sock:
            self.sock.closed.set()


class HTTPSReadTests(unittest.TestCase):
    def transport(self, connection, *, token=None):
        return SigV4HTTPSReadTransport("https://s3.twcstorage.ru/", "ru-1", "foo", "bar",
            session_token=token, connection_factory=lambda: connection,
            wall_clock=lambda: datetime.datetime(2000, 1, 1, tzinfo=datetime.timezone.utc))

    def test_real_httpresponse_eof_after_content_length_closes_socket_file(self):
        # A real HTTPResponse closes its file after Content-Length bytes. The
        # next EOF read must not call settimeout on that already closed socket.
        class ClosingSocket(Sock):
            def __init__(self):
                super().__init__()
                self.file = io.BytesIO(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nxml")
            def makefile(self, *_):
                return self.file
            def settimeout(self, value):
                if self.file.closed:
                    raise OSError("synthetic closed descriptor")
                super().settimeout(value)
        sock = ClosingSocket(); raw = http.client.HTTPResponse(sock); raw.begin()
        class Lease:
            socket = sock
            deadline = time.monotonic() + 1
            clock = staticmethod(time.monotonic)
            def check(self):
                pass
            def close(self):
                sock.closed.set()
        response = media_port._Response(raw, Lease())
        self.assertEqual(b"xml", response.read(65536))
        self.assertTrue(raw.isclosed())
        self.assertEqual(b"", response.read(1))
        response.close()

    def test_get_only_fixed_endpoint_acl_canonical_query_no_range(self):
        for operation, key, path in [("GetBucketAcl", None, "/" + BUCKET + "?acl="),
                ("GetBucketPolicy", None, "/" + BUCKET + "?policy="),
                ("GetObjectAcl", KEY, "/" + BUCKET + "/" + KEY + "?acl="),
                ("GetObject", KEY, "/" + BUCKET + "/" + KEY)]:
            connection = WireConnection(); transport = self.transport(connection, token="synthetic-token")
            response = transport.open(operation, BUCKET, key, time.monotonic() + 1, threading.Event())
            method, actual, headers = connection.calls[0]
            self.assertEqual("GET", method); self.assertEqual(path, actual)
            self.assertNotIn("range", headers); self.assertNotIn("X-Amz-Signature", actual)
            self.assertIn("x-amz-security-token", headers["authorization"])
            response.close(); self.assertTrue(connection.closed); self.assertTrue(connection.reply.closed)
        for operation in ["PutObject", "DeleteObject", "ListObjectsV2", "HeadObject", "Presign"]:
            with self.assertRaises(PrivateMediaUnavailable):
                self.transport(WireConnection()).open(operation, BUCKET, KEY, time.monotonic() + 1, threading.Event())
        with self.assertRaises(PrivateMediaUnavailable):
            SigV4HTTPSReadTransport("https://outside.invalid/", "ru-1", "foo", "bar")

    def test_default_https_context_checks_hostname_ca_tls12(self):
        connection = WireConnection()
        with patch("private_media_s3.http.client.HTTPSConnection", return_value=connection) as factory:
            transport = SigV4HTTPSReadTransport("https://s3.twcstorage.ru/", "ru-1", "foo", "bar")
            response = transport.open("GetObject", BUCKET, KEY, time.monotonic() + 1, threading.Event()); response.close()
            args, kwargs = factory.call_args
            self.assertEqual(("s3.twcstorage.ru", 443), args)
            self.assertEqual(2, kwargs["timeout"])
            self.assertTrue(kwargs["context"].check_hostname)
            self.assertEqual(ssl.CERT_REQUIRED, kwargs["context"].verify_mode)
            self.assertEqual(ssl.TLSVersion.TLSv1_2, kwargs["context"].minimum_version)

    def test_absolute_deadline_closes_hanging_body_and_preserves_generic_facade(self):
        connection = WireConnection(body_hang=True)
        transport = self.transport(connection)
        response = transport.open("GetObject", BUCKET, KEY, time.monotonic() + 0.12, threading.Event())
        before = time.monotonic()
        try:
            with self.assertRaises(PrivateMediaUnavailable):
                response.read(1)
        finally:
            response.close()
        self.assertLess(time.monotonic() - before, 0.6)
        self.assertTrue(connection.sock.closed.is_set()); self.assertTrue(connection.reply.closed)

    def test_cancel_closes_hanging_body_before_absolute_deadline(self):
        cancel = threading.Event(); connection = WireConnection(body_hang=True)
        response = self.transport(connection).open("GetObject", BUCKET, KEY, time.monotonic() + 1, cancel)
        timer = threading.Timer(0.08, cancel.set); timer.start()
        try:
            with self.assertRaises(PrivateMediaUnavailable):
                response.read(1)
        finally:
            timer.cancel(); response.close()
        self.assertTrue(connection.sock.closed.is_set())

    def test_late_dns_setup_is_bounded_and_late_connection_closed(self):
        gate = threading.Event(); connection = WireConnection(connect_gate=gate)
        before = time.monotonic()
        with self.assertRaises(PrivateMediaUnavailable):
            self.transport(connection).open("GetObject", BUCKET, KEY, time.monotonic() + 0.08, threading.Event())
        self.assertLess(time.monotonic() - before, 0.6)
        gate.set()
        for _ in range(50):
            if connection.sock is not None and connection.sock.closed.is_set():
                break
            time.sleep(0.01)
        self.assertTrue(connection.sock.closed.is_set()); self.assertEqual([], connection.calls)

    def test_stalled_setup_uses_only_four_workers_and_recovers_after_drain(self):
        gate = threading.Event(); connections = []; callers = []; cancels = []
        class WaitingConnection(WireConnection):
            def __init__(self):
                super().__init__(connect_gate=gate); self.entered = threading.Event()
            def connect(self):
                self.entered.set(); super().connect()
        def call(transport, cancel):
            try:
                transport.open("GetObject", BUCKET, KEY, time.monotonic() + 1, cancel)
            except PrivateMediaUnavailable:
                pass
        try:
            for _ in range(4):
                connection = WaitingConnection(); connections.append(connection)
                cancel = threading.Event(); cancels.append(cancel)
                caller = threading.Thread(target=call, args=(self.transport(connection), cancel)); callers.append(caller); caller.start()
            self.assertTrue(all(connection.entered.wait(0.5) for connection in connections))
            extra = WireConnection()
            with self.assertRaises(PrivateMediaUnavailable):
                self.transport(extra).open("GetObject", BUCKET, KEY, time.monotonic() + 1, threading.Event())
            self.assertIsNone(extra.sock)
            for cancel in cancels:
                cancel.set()
            for caller in callers:
                caller.join(0.5); self.assertFalse(caller.is_alive())
        finally:
            gate.set()
            for caller in callers:
                caller.join(0.5)
        for _ in range(50):
            if all(connection.sock and connection.sock.closed.is_set() for connection in connections):
                break
            time.sleep(0.01)
        self.assertTrue(all(connection.sock.closed.is_set() for connection in connections))
        connection = WireConnection()
        response = self.transport(connection).open("GetObject", BUCKET, KEY, time.monotonic() + 1, threading.Event())
        response.close()

    def test_published_smithy_header_signature_vector(self):
        # https://raw.githubusercontent.com/smithy-lang/smithy-typescript/main/packages/signature-v4/src/SignatureV4.spec.ts
        signed = _signed_headers("POST", "foo.us-bar-1.amazonaws.com", "/", "", "us-bar-1", "foo", "foo", "bar", "20000101T000000Z")
        self.assertEqual("1e3b24fcfd7655c0c245d99ba7b6b5ca6174eab903ebfbda09ce457af062ad30", signed["authorization"].split("Signature=")[1])
        signed = _signed_headers("POST", "foo.us-bar-1.amazonaws.com", "/", "", "us-bar-1", "foo", "foo", "bar", "20000101T000000Z", "baz")
        self.assertEqual("4fd09a8cf3b28a62a9c6c424f03ababcd703528578bc6ec9184fc585f18c3fbb", signed["authorization"].split("Signature=")[1])

    def test_all_four_s3_requests_match_existing_smithy_signer_without_network(self):
        node = os.environ.get("CLRS_TEST_NODE_BIN", "node")
        script = """import { SignatureV4 } from '@smithy/signature-v4';
import { Sha256 } from '@smithy/core/checksum';
const signer=new SignatureV4({region:'ru-1',service:'s3',credentials:{accessKeyId:'foo',secretAccessKey:'bar'},sha256:Sha256,uriEscapePath:false});
const paths=JSON.parse(process.argv[1]); const results=[];
for (const [path,sub] of paths) { const value=await signer.sign({method:'GET',protocol:'https:',hostname:'s3.twcstorage.ru',path,query:sub?{[sub]:''}:{},headers:{host:'s3.twcstorage.ru'}},{signingDate:new Date('2000-01-01T00:00:00.000Z')}); results.push(value.headers.authorization); }
process.stdout.write(JSON.stringify(results));"""
        paths = [["/" + BUCKET, "acl"], ["/" + BUCKET, "policy"], ["/" + BUCKET + "/" + KEY, "acl"], ["/" + BUCKET + "/" + KEY, ""]]
        result = subprocess.run([node, "--input-type=module", "-e", script, json.dumps(paths)], cwd=Path(__file__).parent.parent,
            capture_output=True, text=True, timeout=5, check=True)
        expected = json.loads(result.stdout)
        for (path, sub), signature in zip(paths, expected):
            actual = _signed_headers("GET", "s3.twcstorage.ru", path, sub + "=" if sub else "", "ru-1", "s3", "foo", "bar", "20000101T000000Z")
            self.assertEqual(signature, actual["authorization"])


class TimewebStateTests(unittest.TestCase):
    def probe(self, value, *, status=200, content_type="application/json"):
        self.connection = WireConnection()
        reply = Reply(json.dumps(value).encode(), status=status, content_type=content_type)
        reply.getheaders = lambda: reply.headers
        self.connection.getresponse = lambda: reply
        self.reply = reply
        return TimewebPrivateBucketState(1234, BUCKET, "synthetic-read-api-token", connection_factory=lambda: self.connection)

    def value(self):
        return {"bucket": {"id": 1234, "name": BUCKET, "type": "private", "website_config": {"enabled": False}}}

    def test_only_exact_authenticated_timeweb_bucket_get(self):
        probe = self.probe(self.value())
        before = time.monotonic()
        result = probe(BUCKET, before + 1, threading.Event())
        self.assertEqual({"bucket", "type", "checked_at"}, set(result))
        self.assertEqual(BUCKET, result["bucket"]); self.assertEqual("private", result["type"])
        self.assertGreaterEqual(result["checked_at"], before)
        method, path, headers = self.connection.calls[0]
        self.assertEqual(("GET", "/api/v1/storages/buckets/1234"), (method, path))
        self.assertEqual("api.timeweb.cloud", headers["host"])
        self.assertEqual("Bearer synthetic-read-api-token", headers["authorization"])
        self.assertEqual("no-store", headers["cache-control"])
        self.assertTrue(self.reply.closed); self.assertTrue(self.connection.closed)

    def test_changed_identity_public_website_unknown_denied_or_redirect_fail(self):
        for change in [{"id": 1235}, {"id": "1234"}, {"name": "other-bucket"}, {"type": "public"},
                {"website_config": {"enabled": True}}, {"website_config": {"enabled": "false"}}]:
            value = self.value(); value["bucket"].update(change)
            with self.assertRaises(PrivateMediaUnavailable):
                self.probe(value)(BUCKET, time.monotonic() + 1, threading.Event())
            self.assertTrue(self.reply.closed)
        for status in [301, 302, 403, 404, 500]:
            with self.assertRaises(PrivateMediaUnavailable):
                self.probe(self.value(), status=status)(BUCKET, time.monotonic() + 1, threading.Event())
        with self.assertRaises(PrivateMediaUnavailable):
            self.probe(self.value(), content_type="text/html")(BUCKET, time.monotonic() + 1, threading.Event())

    def test_invalid_constructor_or_bucket_never_sends_token(self):
        for bucket_id, token in [(True, "synthetic-token"), (0, "synthetic-token"), (1234, "token\r\ninjected")]:
            with self.assertRaises(PrivateMediaUnavailable):
                TimewebPrivateBucketState(bucket_id, BUCKET, token)
        probe = self.probe(self.value())
        with self.assertRaises(PrivateMediaUnavailable):
            probe("other-bucket", time.monotonic() + 1, threading.Event())
        self.assertEqual([], self.connection.calls)


if __name__ == "__main__":
    unittest.main()
