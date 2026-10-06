"""Focused HTTP/app integration with synthetic SQL/S3; never TCP or cloud."""
import base64
import copy
from dataclasses import replace
import json
import os
import tempfile
import threading
import unittest
from urllib.parse import urlencode

from app import create_app
from native_auth import NativeRejected, NativeRateLimited
from private_media_s3 import PrivateMediaS3
from profile_photo_projector import verify_source_snapshot
from media_promotion_acknowledgement import VerifiedMediaPromotion
from runtime_mutations import RuntimeMutationStore, RuntimeUnavailable
from runtime_profile_photos import RuntimeProfilePhotosService, GALLERY_ORDER_POLICY
from runtime_profile_photos_http import (RuntimeProfilePhotosHttp, RuntimeProfilePhotoMediaReply,
    RuntimeProfilePhotosHttpReply)
from test_runtime_profile_photos import PhotoDatabase, KEY, BODY
from test_private_media_s3 import Port, BUCKET, OWNER
from test_profile_photo_projector import source_verifier, PROOF
from test_runtime_mutations import ENV, NOW, STAMP


PATH = "/v1/runtime/people/peer/photos"
ENABLED = {"CLRS_RUNTIME_WRITES_ENABLED": "1", "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "canonical-current-v1"}


class ForbiddenInput:
    def read(self, _): raise AssertionError("Photo GET never consumes a body")


class Native:
    def __init__(self, identity):
        self.identity = identity; self.calls = []; self.error = None
    def authorize(self, token, *, peer):
        self.calls.append((token, peer))
        if self.error: raise self.error("private identity diagnostic")
        return self.identity
    def close(self): pass


class Unmatched:
    def __init__(self): self.calls = []
    def dispatch(self, environ, **_): self.calls.append(environ["PATH_INFO"]); return None
    def close(self): pass


class ProfilePhotoHttpTests(unittest.TestCase):
    def setUp(self):
        self.db = PhotoDatabase(); self.native = Native(self.db.identity)
        self.store = RuntimeMutationStore({**ENV, "CLRS_RUNTIME_PERMISSION_MODEL": "provider-database-v1"},
            self.db.tokens, connect=self.db.connect, clock=lambda: NOW)
        self.addCleanup(self.store.close)
        self.directory = tempfile.TemporaryDirectory(); os.chmod(self.directory.name, 0o700)
        self.addCleanup(self.directory.cleanup)
        self.port = Port(BODY)
        s3 = PrivateMediaS3(BUCKET, OWNER, self.port,
            lambda bucket, deadline, cancel: {"bucket": bucket, "type": "private", "checked_at": 0},
            monotonic=lambda: 0)
        self.core = RuntimeProfilePhotosService(self.store, KEY, private_s3=s3,
            expected_bucket=BUCKET, expected_owner=OWNER,
            source_snapshot=verify_source_snapshot(PROOF, trusted_verifier=source_verifier),
            media_promotion=VerifiedMediaPromotion("0" * 64, NOW, NOW - 1),
            spool_directory=self.directory.name, gallery_order_policy=GALLERY_ORDER_POLICY,
            clock=lambda: NOW, monotonic=lambda: 0)
        self.addCleanup(self.core.close)
        self.factories = []; self.budgets = []
        def factory(): self.factories.append(1); return self.core
        self.factory = factory
        self.http = RuntimeProfilePhotosHttp(ENABLED, service_factory=factory, monotonic=lambda: 0)
        self.addCleanup(self.http.close)

    def begin(self):
        cancel = threading.Event(); self.budgets.append(cancel)
        return 60, cancel

    def request(self, **changes):
        return {"PATH_INFO": PATH, "REQUEST_METHOD": "GET", "QUERY_STRING": "",
            "HTTP_AUTHORIZATION": "Bearer " + self.db.access, "REMOTE_ADDR": "socket-peer",
            "CONTENT_LENGTH": "0", "wsgi.input": ForbiddenInput(),
            "clrs.media_request_budget": self.begin, **changes}

    def dispatch(self, **changes):
        return self.http.dispatch(self.request(**changes), native_service=self.native, native_configured=True)

    def reference(self): return self.dispatch().payload["items"][0]["reference"]

    def content(self, reference=None, **changes):
        return self.dispatch(PATH_INFO=PATH + "/content",
            QUERY_STRING=urlencode({"reference": reference or self.reference()}), **changes)

    def app(self, *, injected=True, env=None):
        self.other = Unmatched()
        return create_app(env=env or {**ENABLED, "CLRS_API_DRAFT_ENABLED": "1",
            "CLRS_NATIVE_AUTH_ENABLED": "1", "CLRS_NATIVE_AUTH_WRITES_ENABLED": "1"},
            native_service_factory=lambda _: self.native, legacy_http_factory=lambda _: self.other,
            media_http_factory=lambda _: self.other, runtime_http_factory=lambda _: self.other,
            lifecycle_http_factory=lambda *_: self.other,
            profile_photos_http=self.http if injected else None,
            verify_token=lambda *_args, **_kwargs: self.fail("Photo route must not use Firebase authorization"),
            profile_reader=lambda uid, **_: {"uid": uid})

    def call_app(self, application, environ=None, *, start=None, consume=True):
        states = []
        def response(status, headers):
            states.append((status, dict(headers)))
            if start: start(status, headers)
        body = application(environ or self.request(), response)
        raw = None
        if consume:
            try: raw = b"".join(body)
            finally:
                if callable(getattr(body, "close", None)): body.close()
        return states, body, raw

    def test_descriptor_current_native_exact_options_and_lazy_factory(self):
        self.assertEqual([], self.factories)
        page = self.dispatch(QUERY_STRING="limit=1")
        self.assertEqual("200 OK", page.status)
        self.assertEqual(1, len(page.payload["items"])); self.assertEqual([1], self.factories)
        self.assertEqual((self.db.access, "socket-peer"), self.native.calls[-1])
        self.assertEqual([], self.budgets); self.assertEqual([], self.port.calls)
        self.dispatch(); self.assertEqual([1], self.factories)
        self.assertTrue(all(c.readonly and c.commits == 0 for c in self.db.connections))

    def test_default_off_gates_unmatched_and_bad_method_never_construct(self):
        for env, factory in ((ENABLED, None), ({}, self.factory),
                ({**ENABLED, "CLRS_RUNTIME_WRITES_ENABLED": "0"}, self.factory),
                ({**ENABLED, "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "legacy"}, self.factory)):
            off = RuntimeProfilePhotosHttp(env, service_factory=factory)
            self.assertEqual("404 Not Found", off.dispatch(self.request()).status)
        for path in (PATH + "/", PATH + "/content/", PATH + "/other", PATH.replace("peer", "peer/other"),
                "/v1/runtime/people//photos", "/v1/media/opaque", "/v1/runtime/people/peer"):
            self.assertIsNone(self.dispatch(PATH_INFO=path))
        for method in ("HEAD", "POST", "PUT", "DELETE"):
            self.assertEqual("405 Method Not Allowed", self.dispatch(REQUEST_METHOD=method).status)
        self.assertEqual([], self.factories); self.assertEqual([], self.native.calls)

    def test_bad_path_alias_query_body_range_case_and_utf8_reject_before_auth(self):
        for path in (PATH.replace("peer", "."), PATH.replace("peer", ".."), PATH.replace("peer", "%2F"),
                PATH.replace("peer", "%252F"), PATH.replace("peer", "a\\b"), PATH.replace("peer", "a\x00b")):
            self.assertEqual("400 Bad Request", self.dispatch(PATH_INFO=path).status)
        for changes in ({"CONTENT_LENGTH": "1"}, {"HTTP_TRANSFER_ENCODING": "chunked"},
                {"HTTP_RANGE": ""}, {"http_range": "bytes=0-1"}, {"Http_If_Range": "any"}):
            self.assertEqual("400 Bad Request", self.dispatch(**changes).status)
        for query in ("limit=0", "limit=31", "limit=01", "limit=1&limit=2", "cursor=", "cursor=x%2Fy",
                "uid=peer", "limit=1&cursor=x&extra=y", "cursor=%FF", "cursor=%ED%A0%80", "cursor=%ZZ",
                "cursor=" + "x" * 4097, "limit=1&"):
            self.assertEqual("400 Bad Request", self.dispatch(QUERY_STRING=query).status)
        for query in ("", "reference=", "reference=a%2Fb", "reference=a&reference=b", "reference=a&limit=1"):
            self.assertEqual("400 Bad Request", self.dispatch(PATH_INFO=PATH + "/content", QUERY_STRING=query).status)
        self.assertEqual([], self.factories); self.assertEqual([], self.native.calls); self.assertEqual([], self.budgets)

    def test_only_native_access_identity_and_sanitized_limit_failure(self):
        for header in ("Bearer firebase.jwt", "Bearer nr1.refresh", "Basic private", "Bearer na1. space"):
            reply = self.dispatch(HTTP_AUTHORIZATION=header)
            self.assertEqual(("401 Unauthorized", True), (reply.status, reply.authenticate))
        self.assertEqual([], self.factories); self.assertEqual([], self.native.calls)
        self.native.error = NativeRateLimited
        reply = self.dispatch(); self.assertEqual("429 Too Many Requests", reply.status); self.assertTrue(reply.retry)
        self.native.error = NativeRejected
        reply = self.dispatch(); self.assertEqual({"error": "unauthorized"}, reply.payload)
        self.native.error = None; self.native.identity = object()
        self.assertEqual("503 Service Unavailable", self.dispatch().status)
        self.assertEqual([], self.factories)

    def test_invalid_or_absent_content_budget_has_no_factory_or_fetch(self):
        for begin in (None, lambda: (61, threading.Event()), lambda: (float("nan"), threading.Event()),
                lambda: (0, threading.Event()), lambda: (60, object())):
            self.assertEqual("503 Service Unavailable", self.dispatch(PATH_INFO=PATH + "/content",
                QUERY_STRING="reference=opaque", **{"clrs.media_request_budget": begin}).status)
        self.assertEqual([], self.factories); self.assertEqual([], self.port.calls)

    def test_verified_original_prime_current_third_proof_before_200_and_bounded_body(self):
        reference = self.reference(); before = copy.deepcopy(self.db.state)
        reply = self.content(reference); self.assertIsInstance(reply, RuntimeProfilePhotoMediaReply)
        started = []
        def start(status, headers):
            started.append((status, dict(headers)))
            self.assertEqual(4, len(self.db.connections))  # descriptor + three content proofs
        body = reply.respond(start)
        blocks = list(body); body.close()
        self.assertEqual(BODY, b"".join(blocks)); self.assertTrue(all(0 < len(x) <= 65_536 for x in blocks))
        self.assertEqual("200 OK", started[0][0])
        headers = started[0][1]
        self.assertEqual(str(len(BODY)), headers["Content-Length"])
        self.assertEqual("image/jpeg", headers["Content-Type"])
        self.assertEqual("private, no-store", headers["Cache-Control"])
        self.assertEqual("nosniff", headers["X-Content-Type-Options"])
        self.assertEqual("no-referrer", headers["Referrer-Policy"])
        self.assertNotIn("Location", headers); self.assertNotIn("Accept-Ranges", headers)
        self.assertEqual(before, self.db.state); self.assertEqual(set(), self.core._leases)

    def test_hidden_or_revoked_after_fetch_refuses_before_any_200_headers(self):
        reference = self.reference(); reply = self.content(reference)
        self.db.state["accounts"]["peer"][0] = 1
        starts = []; result = reply.respond(lambda *args: starts.append(args))
        self.assertEqual(("404 Not Found", False), (result.status, result.authenticate))
        self.assertEqual([], starts); self.assertEqual(set(), self.core._leases)
        self.db.state["accounts"]["peer"][0] = 0; reply = self.content(reference)
        self.db.state["sessions"][self.db.identity.session_id]["revoked_at"] = STAMP
        result = reply.respond(lambda *args: starts.append(args))
        self.assertEqual(("401 Unauthorized", True), (result.status, result.authenticate))
        self.assertEqual([], starts); self.assertEqual(set(), self.core._leases)

    def test_valid_B_session_cannot_redeem_A_reference_without_logout_challenge(self):
        reference = self.reference()
        session, access = self.db.tokens.mint("peer", "other-device", 0, NOW)
        self.db.state["sessions"][session["session_id"]] = session
        self.native.identity = replace(self.db.identity, uid="peer", session_id=session["session_id"])
        reply = self.dispatch(PATH_INFO=PATH + "/content", QUERY_STRING=urlencode({"reference": reference}),
            HTTP_AUTHORIZATION="Bearer " + access["accessToken"])
        self.assertEqual(("400 Bad Request", False), (reply.status, reply.authenticate))
        self.assertEqual([], self.port.calls)

    def test_empty_iterator_or_metadata_and_start_response_failure_close_resource(self):
        reference = self.reference(); reply = self.content(reference)
        reply._lease.iter_bytes = lambda: iter(())
        starts = []; result = reply.respond(lambda *args: starts.append(args))
        self.assertEqual("503 Service Unavailable", result.status); self.assertEqual([], starts)
        reply = self.content(reference); reply._lease.size = 0
        self.assertEqual("503 Service Unavailable", reply.respond(lambda *args: starts.append(args)).status)
        reply = self.content(reference)
        def broken(status, _headers): starts.append(status); raise BrokenPipeError("disconnected")
        with self.assertRaises(BrokenPipeError): reply.respond(broken)
        self.assertEqual(["200 OK"], starts); self.assertEqual(set(), self.core._leases)

    def test_body_disconnect_before_iteration_after_first_chunk_and_postclose(self):
        reference = self.reference()
        for consume_first in (False, True):
            reply = self.content(reference); body = reply.respond(lambda *_: None)
            if consume_first: self.assertTrue(next(body))
            body.close(); body.close(); self.assertEqual(set(), self.core._leases)
            with self.assertRaises(StopIteration): next(body)
        reply = self.content(reference); body = reply.respond(lambda *_: None)
        self.http.close()
        with self.assertRaises(RuntimeUnavailable): next(body)
        self.assertEqual(set(), self.core._leases)
        self.assertEqual("503 Service Unavailable", self.dispatch().status)

    def test_storage_errors_and_malformed_private_dto_are_sanitized(self):
        reference = self.reference(); self.port.body = b"corrupted"
        self.assertEqual({"error": "service_unavailable"}, self.content(reference).payload)
        self.port.body = BODY
        baseline = self.core.photos(self.db.identity, "peer", access_token=self.db.access)
        bad = [lambda value: value.update(legacy_raw={"private": True}),
            lambda value: value["items"][0].update(objectKey="private"),
            lambda value: value["items"][0].update(ordinal=True),
            lambda value: value["items"][0].update(contentType="image/svg+xml"),
            lambda value: value["items"][0].update(byteSize=8 * 1024 * 1024 + 1),
            lambda value: value["items"][0].update(reference="https://private.invalid"),
            lambda value: value.update(targetUid="other"),
            lambda value: value.update(items=value["items"] * 31),
            lambda value: value.update(items=[{**value["items"][0], "ordinal": i,
                "isPrimary": i == 0, "reference": "x" * 4096} for i in range(30)])]
        original = self.core.photos
        for mutation in bad:
            value = copy.deepcopy(baseline); mutation(value)
            self.core.photos = lambda *_args, **_kw: value
            self.assertEqual({"error": "service_unavailable"}, self.dispatch().payload)
        self.core.photos = original

    def test_close_during_lazy_factory_or_inflight_descriptor_returns_no_late_data(self):
        def factory(): self.http.close(); return self.core
        self.http = RuntimeProfilePhotosHttp(ENABLED, service_factory=factory)
        self.assertEqual("503 Service Unavailable", self.dispatch().status)
        self.assertEqual([], self.db.connections)

    def test_close_during_descriptor_action_suppresses_its_late_success(self):
        original = self.core.photos
        def read(*args, **kw):
            value = original(*args, **kw); self.http.close(); return value
        self.core.photos = read
        reply = self.dispatch()
        self.assertEqual(("503 Service Unavailable", {"error": "service_unavailable"}),
            (reply.status, reply.payload))
        self.assertEqual([1], self.factories)

    def test_app_default_off_guard_before_native_and_no_legacy_photo_auth(self):
        application = self.app(injected=False)
        starts, _, _ = self.call_app(application)
        self.assertEqual("404 Not Found", starts[0][0]); self.assertEqual([], self.factories)
        proof = bytes(range(32))
        env = {**ENABLED, "CLRS_API_DRAFT_ENABLED": "1", "CLRS_NATIVE_AUTH_ENABLED": "1",
            "CLRS_NATIVE_AUTH_WRITES_ENABLED": "1", "CLRS_PREVIEW_GUARD_ENABLED": "1",
            "CLRS_PREVIEW_ACCESS_KEY_B64": base64.b64encode(proof).decode()}
        application = self.app(env=env)
        starts, _, _ = self.call_app(application)
        self.assertEqual("404 Not Found", starts[0][0]); self.assertEqual([], self.native.calls)
        starts, _, raw = self.call_app(application, self.request(HTTP_X_CLRS_PREVIEW_PROOF=base64.b64encode(proof).decode()))
        self.assertEqual("200 OK", starts[0][0]); self.assertIn("items", json.loads(raw))
        self.assertEqual([], self.other.calls)

    def test_app_first_byte_404_is_json_without_200_or_logout_and_shared_route_stays(self):
        application = self.app(); reference = self.reference()
        original = self.core.open_photo
        def after_download(*args, **kw):
            lease = original(*args, **kw); self.db.state["accounts"]["peer"][0] = 1; return lease
        self.core.open_photo = after_download
        starts, _, raw = self.call_app(application, self.request(PATH_INFO=PATH + "/content",
            QUERY_STRING=urlencode({"reference": reference})))
        self.assertEqual(["404 Not Found"], [entry[0] for entry in starts])
        self.assertEqual({"error": "not_found"}, json.loads(raw)); self.assertNotIn("WWW-Authenticate", starts[0][1])
        starts, _, raw = self.call_app(application, self.request(PATH_INFO="/v1/me/profile"))
        self.assertEqual("200 OK", starts[0][0]); self.assertEqual({"profile": {"uid": "actor"}}, json.loads(raw))
        application.close(); self.assertTrue(self.http._closed); self.assertEqual(set(), self.core._leases)


if __name__ == "__main__": unittest.main()
