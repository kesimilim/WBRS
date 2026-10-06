"""Synthetic media HTTP/loopback proof; no cloud, real user or credential."""
import io
import base64
import json
import os
import socket
import ssl
import stat
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from urllib.request import Request, urlopen
from urllib.error import HTTPError

from app import create_app
from auth_bridge import AuthenticatedIdentity
from http_runtime import make_bounded_server
from legacy_private_media import LegacyPrivateMediaService, _SLOTS
from legacy_private_media_http import LegacyPrivateMediaHttp, create_private_media_service
from legacy_conversation_read import LegacyReadUnavailable
from native_auth import NativeRejected
from native_sessions import NativeIdentity
from profile_store import BUNDLED_CA_FILE, DatabaseUnavailable
from test_legacy_private_media import MediaDatabase, FakeS3, DATA, URL, PATH
from test_legacy_conversation_read import KEY, NOW, PIN, SOURCE, UID_A, UID_B, enabled, s


class Native:
    def __init__(self):
        self.identity = NativeIdentity(UID_A, True, "synthetic-session", NOW - 1, NOW + 900)
        self.calls = []; self.reject = False

    def authorize(self, token, *, peer):
        self.calls.append((token, peer))
        if self.reject:
            raise NativeRejected()
        return self.identity


class _MediaFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        os.chmod(self.directory.name, 0o700)
        self.addCleanup(self.directory.cleanup)
        self.db = MediaDatabase(); self.s3 = FakeS3(); self.native = Native()
        self.db.message("chats/old-room/chats/photo", extra={"image": s(URL)})
        self.env = {**enabled(), "CLRS_API_DRAFT_ENABLED": "1",
            "CLRS_NATIVE_AUTH_ENABLED": "1", "CLRS_NATIVE_AUTH_WRITES_ENABLED": "1",
            "CLRS_LEGACY_MEDIA_ENABLED": "1", "CLRS_LEGACY_MEDIA_PROMOTION_REVIEWED": "1",
            "CLRS_LEGACY_MEDIA_PROMOTION_MODE": "reviewed-immutable-object-alias",
            "CLRS_LEGACY_MEDIA_S3_USER_MODE": "dedicated-read-only",
            "CLRS_LEGACY_MEDIA_FULL_READBACK_SOURCE_SHA256": PIN,
            "CLRS_LEGACY_MEDIA_DB_URL": enabled()["CLRS_LEGACY_READ_DB_URL"],
            "CLRS_LEGACY_MEDIA_DB_CA_FILE": enabled()["CLRS_LEGACY_READ_DB_CA_FILE"],
            "CLRS_LEGACY_MEDIA_SPOOL_DIR": self.directory.name,
            "FIREBASE_PROJECT_ID": "synthetic-project", "FIREBASE_WEB_API_KEY": "public-test-key"}
        self.core = LegacyPrivateMediaService(self.env, KEY, private_s3=self.s3,
            connect=self.db.connect, clock=lambda: NOW)
        self.verified = []; self.budgets = []; self.files = []
        def spool():
            result = tempfile.TemporaryFile(mode="w+b", dir=self.directory.name)
            self.files.append(result); return result
        self.core._spool = spool
        self.app = self.application()

    def application(self, *, env=None):
        def verify(token, **kw):
            self.verified.append((token, kw))
            return AuthenticatedIdentity(UID_A, NOW - 1, NOW - 1, NOW + 900)
        return create_app(env=env or self.env,
            native_service_factory=lambda _: self.native,
            media_http_factory=lambda settings: LegacyPrivateMediaHttp(settings,
                service_factory=lambda _: self.core, identity_verifier=verify))

    def reference(self, *, uid=UID_A):
        parent = self.db.documents["chats/old-room"][4].hex()
        binding = self.core._binding(uid, PIN, "chats/old-room/chats", parent, "messages")
        return self.core._codec.seal("media", {**binding,
            "message": "chats/old-room/chats/photo", "bucket": SOURCE[2], "path": PATH, "exp": NOW + 300})

    def begin(self):
        cancel = threading.Event(); self.budgets.append(cancel)
        return time.monotonic() + 60, cancel

    def request(self, *, app=None, header="Bearer na1.synthetic", reference=None,
            respond=None, consume=True, **changes):
        result = {}
        def start(status, headers):
            result.update(status=status, headers=dict(headers))
            if respond: respond(status, headers)
        env = {"REQUEST_METHOD": "GET", "PATH_INFO": "/v1/media/" + (reference or self.reference()),
            "QUERY_STRING": "", "REMOTE_ADDR": "127.0.0.1", "CONTENT_LENGTH": "0",
            "wsgi.input": io.BytesIO(), "clrs.media_request_budget": self.begin}
        if header is not None: env["HTTP_AUTHORIZATION"] = header
        env.update(changes)
        body = (app or self.app)(env, start)
        result["iterable"] = body
        if consume:
            try: result["raw"] = b"".join(body)
            finally:
                if callable(getattr(body, "close", None)): body.close()
        return result

    def assert_slots_available(self):
        self.assertTrue(_SLOTS.acquire(False)); self.assertTrue(_SLOTS.acquire(False))
        self.assertFalse(_SLOTS.acquire(False)); _SLOTS.release(); _SLOTS.release()


class MediaHttpTests(_MediaFixture):
    def test_absent_media_ca_uses_bundled_verified_tls_explicit_bad_ca_refuses(self):
        env = dict(self.env); env.pop("CLRS_LEGACY_MEDIA_DB_CA_FILE")
        with patch("profile_store.ssl.create_default_context", wraps=ssl.create_default_context) as create_context:
            service = LegacyPrivateMediaService(env, KEY, private_s3=self.s3, connect=self.db.connect)
            config, _, _ = service._configuration()
            create_context.assert_called_once_with(cafile=BUNDLED_CA_FILE)
        self.assertTrue(config["ssl"].check_hostname)
        self.assertEqual(ssl.CERT_REQUIRED, config["ssl"].verify_mode)
        for value in ["", "relative.pem", "/__clrs_synthetic__/missing.pem"]:
            env["CLRS_LEGACY_MEDIA_DB_CA_FILE"] = value
            with self.assertRaises(DatabaseUnavailable):
                LegacyPrivateMediaService(env, KEY, private_s3=self.s3,
                    connect=self.db.connect)._configuration()
        self.assertEqual([], self.db.configs)

    def test_verified_factory_default_spool_lifetime_and_failure_cleanup_explicit_path_strict(self):
        from test_media_promotion_acknowledgement import body, date, fixture
        value = body(); now = int(time.time())
        value.update(startedAt=date(now - 1), verifiedAt=date(now))
        env = {**self.env, **fixture(value), "CLRS_LEGACY_CURSOR_KEY_B64": base64.b64encode(KEY).decode(),
            "CLRS_LEGACY_MEDIA_S3_REGION": "ru-1", "CLRS_LEGACY_MEDIA_S3_ACCESS_KEY": "synthetic-access",
            "CLRS_LEGACY_MEDIA_S3_SECRET_KEY": "synthetic-secret",
            "CLRS_LEGACY_MEDIA_CONTROL_TOKEN": "synthetic-control-token",
            "CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID": "123"}
        env["CLRS_LEGACY_MEDIA_FULL_READBACK_SOURCE_SHA256"] = env["CLRS_LEGACY_READ_SOURCE_SHA256"]
        env.pop("CLRS_LEGACY_MEDIA_SPOOL_DIR"); env.pop("CLRS_LEGACY_MEDIA_DB_CA_FILE")
        factory = tempfile.TemporaryDirectory
        with patch("legacy_private_media_http.tempfile.TemporaryDirectory", wraps=factory) as directories:
            self.assertIsNone(create_private_media_service({}))
            directories.assert_not_called()
            broken = {**env, "CLRS_LEGACY_MEDIA_PROMOTION_ACK_SHA256": "0" * 64}
            with self.assertRaises(LegacyReadUnavailable): create_private_media_service(broken)
            directories.assert_not_called()
            service = create_private_media_service(env)
            directory = service._env["CLRS_LEGACY_MEDIA_SPOOL_DIR"]
            self.assertTrue(os.path.isabs(directory))
            self.assertEqual(0o700, stat.S_IMODE(os.lstat(directory).st_mode))
            self.assertEqual(os.getuid(), os.lstat(directory).st_uid)
            self.assertNotIn("CLRS_LEGACY_MEDIA_PROMOTION_RECEIPT_KEY_B64", service._env)
            self.assertNotIn("CLRS_LEGACY_MEDIA_S3_SECRET_KEY", service._env)
            with service._spool() as file:
                self.assertEqual(0o600, stat.S_IMODE(os.fstat(file.fileno()).st_mode))
            service.close(); service.close()
            self.assertFalse(os.path.exists(directory))
            service = create_private_media_service(env)
            directory = service._env["CLRS_LEGACY_MEDIA_SPOOL_DIR"]
            dispatcher = LegacyPrivateMediaHttp(env, service_factory=lambda _: service)
            application = create_app(env=env, native_service_factory=lambda _: self.native,
                media_http_factory=lambda _: dispatcher)
            server = make_bounded_server("127.0.0.1", 0, application)
            try:
                server.server_close()
                self.assertFalse(os.path.exists(directory))
                self.assertIsNone(dispatcher._service)
            finally:
                server.server_close()
        for explicit in ["", "relative-directory", self.directory.name]:
            if explicit == self.directory.name: os.chmod(explicit, 0o755)
            with patch("legacy_private_media_http.tempfile.TemporaryDirectory") as directories:
                with self.assertRaises(LegacyReadUnavailable):
                    create_private_media_service({**env, "CLRS_LEGACY_MEDIA_SPOOL_DIR": explicit})
                directories.assert_not_called()
        os.chmod(self.directory.name, 0o700)
        created = []
        def temporary(*args, **kwargs):
            result = factory(*args, **kwargs); created.append(result.name); return result
        with patch("legacy_private_media_http.tempfile.TemporaryDirectory", side_effect=temporary), \
                patch.object(LegacyPrivateMediaService, "_spool", side_effect=LegacyReadUnavailable):
            with self.assertRaises(LegacyReadUnavailable): create_private_media_service(env)
        self.assertEqual(1, len(created)); self.assertFalse(os.path.exists(created[0]))

    def test_valid_bytes_start_only_after_full_hash_and_second_sql_authorization(self):
        def started(status, headers):
            self.assertEqual("200 OK", status)
            self.assertEqual(1, len(self.s3.calls)); self.assertEqual(2, len(self.db.connections))
        response = self.request(respond=started)
        self.assertEqual(DATA, response["raw"])
        self.assertEqual("private, no-store", response["headers"]["Cache-Control"])
        self.assertEqual("attachment; filename=media", response["headers"]["Content-Disposition"])
        self.assertEqual("no-referrer", response["headers"]["Referrer-Policy"])
        self.assertTrue(all(file.closed for file in self.files)); self.assert_slots_available()
        self.assertEqual([], self.verified)
        self.assertEqual("200 OK", self.request(header="Bearer synthetic-firebase")["status"])
        self.assertEqual(1, len(self.verified))

    def test_no_auth_native_rejection_or_wrong_identity_never_extends_budget(self):
        for header in [None, "Bearer ", "Bearer na1.\nsecret", "Basic secret"]:
            self.assertEqual("401 Unauthorized", self.request(header=header)["status"])
        self.native.reject = True
        self.assertEqual("401 Unauthorized", self.request()["status"])
        self.native.reject = False; self.native.identity = SimpleNamespace(uid=UID_A)
        self.assertEqual("503 Service Unavailable", self.request()["status"])
        self.assertEqual([], self.budgets); self.assertEqual([], self.s3.calls); self.assertEqual([], self.verified)

    def test_feature_off_and_invalid_query_range_body_reference_fail_before_auth(self):
        with patch("legacy_private_media_http.SigV4HTTPSReadTransport") as constructor:
            self.assertIsNone(create_private_media_service({}))
            constructor.assert_not_called()
        off = self.application(env={**self.env, "CLRS_LEGACY_MEDIA_ENABLED": "0"})
        self.assertEqual("404 Not Found", self.request(app=off)["status"])
        for changes in [{"QUERY_STRING": "uid=other"}, {"HTTP_RANGE": "bytes=0-1"},
                {"CONTENT_LENGTH": "1"}, {"HTTP_TRANSFER_ENCODING": "chunked"},
                {"reference": "x" * 4097}, {"reference": "x/y"}]:
            self.assertEqual("400 Bad Request", self.request(**changes)["status"])
        self.assertEqual([], self.native.calls); self.assertEqual([], self.budgets)
        for raw_id in ["", "01", "-1", "1.0", "1e3"]:
            with self.assertRaises(LegacyReadUnavailable):
                create_private_media_service({"CLRS_LEGACY_MEDIA_ENABLED": "1",
                    "CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID": raw_id})

    def test_account_bound_reference_and_bad_sha_have_no_media_response(self):
        response = self.request(reference=self.reference(uid=UID_B))
        self.assertEqual("404 Not Found", response["status"]); self.assertEqual([], self.s3.calls)
        self.s3.data = DATA + b"corrupt"
        response = self.request()
        self.assertEqual("503 Service Unavailable", response["status"])
        self.assertEqual({"error": "service_unavailable"}, json.loads(response["raw"]))
        self.assertTrue(all(file.closed for file in self.files)); self.assert_slots_available()

    def test_wsgi_early_close_before_iteration_and_after_first_chunk_cleans_spool(self):
        for first_chunk in [False, True]:
            response = self.request(consume=False)
            body = response["iterable"]
            if first_chunk: self.assertLessEqual(len(next(body)), 65536)
            body.close(); body.close()
            self.assertTrue(self.files[-1].closed); self.assertTrue(self.budgets[-1].is_set())
            self.assert_slots_available()

    def test_start_response_failure_closes_uniterated_spool(self):
        def fail(*args): raise OSError("synthetic disconnected output")
        with self.assertRaises(OSError): self.request(respond=fail)
        self.assertTrue(all(file.closed for file in self.files)); self.assert_slots_available()

    def test_http_media_budget_is_required_and_cancelled_budget_never_downloads(self):
        self.assertEqual("503 Service Unavailable", self.request(**{"clrs.media_request_budget": None})["status"])
        cancelled = threading.Event(); cancelled.set()
        self.assertEqual("503 Service Unavailable", self.request(**{
            "clrs.media_request_budget": lambda: (time.monotonic() + 1, cancelled)})["status"])
        self.assertEqual([], self.s3.calls)


class MediaRuntimeTests(_MediaFixture):
    def test_shutdown_before_worker_budget_registration_does_not_start_handler(self):
        server = make_bounded_server("127.0.0.1", 0,
            lambda *args: self.fail("A late handler started after shutdown"))
        class Peer:
            cancelled = False
            def shutdown(self, *_): self.cancelled = True
        peer = Peer(); closed = []
        server.shutdown_request = lambda request: closed.append(request)
        server._stopping.set(); self.assertTrue(server._slots.acquire(False))
        try:
            server.process_request_thread(peer, ("127.0.0.1", 0))
            self.assertTrue(peer.cancelled); self.assertEqual([peer], closed)
            self.assertEqual({}, server._budgets)
            slots = []
            while server._slots.acquire(False): slots.append(True)
            self.assertEqual(server.MAX_WORKERS, len(slots))
            for _ in slots: server._slots.release()
        finally:
            server.server_close()

    def server(self):
        # server_close owns app.close: a new server must not reuse the closed
        # HTTP dispatcher from the preceding timeout/disconnect subcase.
        server = make_bounded_server("127.0.0.1", 0, self.application())
        server.REQUEST_DEADLINE_SECONDS = .15; server.MEDIA_DEADLINE_SECONDS = .7
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .02}, daemon=True)
        thread.start(); return server, thread

    @staticmethod
    def wait_empty(server):
        end = time.monotonic() + 2
        while time.monotonic() < end:
            with server._budget_lock:
                if not server._budgets: return True
            time.sleep(.01)
        return False

    def test_authenticated_media_extends_only_its_budget_and_streams_after_initial_deadline(self):
        original = self.s3.get_verified_to_file
        def delayed(*args, **kwargs):
            time.sleep(.25); return original(*args, **kwargs)
        self.s3.get_verified_to_file = delayed
        server, thread = self.server()
        try:
            req = Request(f"http://127.0.0.1:{server.server_port}/v1/media/" + self.reference(),
                headers={"Authorization": "Bearer na1.synthetic"})
            with urlopen(req, timeout=2) as response:
                self.assertEqual(DATA, response.read())
            self.assertEqual(.15, server.REQUEST_DEADLINE_SECONDS)
            self.assertTrue(self.wait_empty(server)); self.assert_slots_available()
        finally:
            server.shutdown(); server.server_close(); thread.join(2)

    def test_timeout_disconnect_shutdown_cancel_io_without_early_slot_release(self):
        for cause in ["timeout", "disconnect", "shutdown"]:
            with self.subTest(cause=cause):
                entered = threading.Event(); cancelled = threading.Event(); settle = threading.Event()
                def blocked(record, sink, *, deadline, cancel):
                    entered.set()
                    if cancel.wait(2): cancelled.set()
                    settle.wait(2)
                    raise RuntimeError("synthetic cancelled download")
                self.s3.get_verified_to_file = blocked
                server, thread = self.server()
                peer = socket.create_connection(server.server_address, timeout=2)
                peer.sendall(("GET /v1/media/" + self.reference() + " HTTP/1.1\r\nHost: test\r\n"
                    "Authorization: Bearer na1.synthetic\r\n\r\n").encode())
                try:
                    self.assertTrue(entered.wait(1))
                    if cause == "disconnect": peer.close()
                    if cause == "shutdown": server.shutdown()
                    self.assertTrue(cancelled.wait(1.5))
                    # One operation is still actually running after cancellation.
                    self.assertTrue(server._media_slots.acquire(False))
                    self.assertFalse(server._media_slots.acquire(False)); server._media_slots.release()
                    self.assertTrue(_SLOTS.acquire(False)); self.assertFalse(_SLOTS.acquire(False)); _SLOTS.release()
                    settle.set(); self.assertTrue(self.wait_empty(server))
                    self.assertTrue(all(file.closed for file in self.files)); self.assert_slots_available()
                finally:
                    settle.set(); peer.close()
                    if cause != "shutdown": server.shutdown()
                    server.server_close(); thread.join(2)

    def test_two_transport_slots_bound_parallel_media_and_third_fails_without_download(self):
        entered = threading.Event(); settle = threading.Event(); active = []
        lock = threading.Lock()
        def blocked(record, sink, *, deadline, cancel):
            with lock:
                active.append(cancel)
                if len(active) == 2: entered.set()
            settle.wait(2)
            raise RuntimeError("synthetic cancelled download")
        self.s3.get_verified_to_file = blocked
        server, thread = self.server(); peers = []
        try:
            for _ in range(2):
                peer = socket.create_connection(server.server_address, timeout=2); peers.append(peer)
                peer.sendall(("GET /v1/media/" + self.reference() + " HTTP/1.1\r\nHost: test\r\n"
                    "Authorization: Bearer na1.synthetic\r\n\r\n").encode())
            self.assertTrue(entered.wait(1))
            req = Request(f"http://127.0.0.1:{server.server_port}/v1/media/" + self.reference(),
                headers={"Authorization": "Bearer na1.synthetic"})
            with self.assertRaises(HTTPError) as result: urlopen(req, timeout=1)
            self.assertEqual(503, result.exception.code)
            self.assertEqual(2, len(active))
            server.shutdown(); self.assertTrue(all(cancel.is_set() for cancel in active))
            settle.set(); self.assertTrue(self.wait_empty(server)); self.assert_slots_available()
        finally:
            settle.set()
            for peer in peers: peer.close()
            if thread.is_alive(): server.shutdown()
            server.server_close(); thread.join(2)


if __name__ == "__main__": unittest.main()
