"""Native write HTTP contracts, without cloud credentials or real accounts."""
import io
import json
import unittest
from types import SimpleNamespace
from native_sessions import NativeIdentity
from runtime_http import RuntimeMutationHttp
from runtime_mutations import RuntimeCommitUnknown, RuntimeConflict

OP = "12345678-1234-4234-8234-123456789abc"
ENV = {"CLRS_RUNTIME_WRITES_ENABLED": "1", "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "canonical-current-v1"}


class ForbiddenInput:
    def read(self, _):
        raise AssertionError("Body read before authorization")


class Native:
    def __init__(self):
        self.calls = []
        self.identity = NativeIdentity("self-uid", False, "session", 1, 1000)

    def authorize(self, token, *, peer):
        self.calls.append((token, peer))
        return self.identity


class Services:
    def __init__(self):
        self.calls = []
        self.error = None

    def _result(self, kind, args, kw):
        self.calls.append((kind, args, kw))
        if self.error:
            raise self.error("private diagnostic must never leak")
        return SimpleNamespace(status=201, payload={"state": "committed"})

    def send_text(self, *args, **kw):
        return self._result("send", args, kw)

    def mark_read(self, *args, **kw):
        return self._result("read", args, kw)

    def edit(self, *args, **kw):
        return self._result("profile", args, kw)

    def lookup(self, *args, **kw):
        return self._result("lookup", args, kw)

    def read_for_edit(self, *args, **kw):
        self.calls.append(("profile-get", args, kw))
        return {"uid": "self-uid", "profile": None, "profileExists": False}


def env(path, body=None, **changes):
    raw = json.dumps(body).encode() if body is not None else b""
    return {"REQUEST_METHOD": "POST", "PATH_INFO": path,
        "QUERY_STRING": "", "CONTENT_LENGTH": str(len(raw)),
        "CONTENT_TYPE": "application/json", "wsgi.input": io.BytesIO(raw),
        "HTTP_AUTHORIZATION": "Bearer na1.test", "REMOTE_ADDR": "socket-peer", **changes}


class RuntimeHttpTests(unittest.TestCase):
    def setUp(self):
        self.native = Native(); self.services = Services()
        self.http = RuntimeMutationHttp(ENV, service_factory=lambda _: (self.services,)*3)

    def request(self, request):
        return self.http.dispatch(request, native_service=self.native, native_configured=True)

    def test_default_off_and_membership_mode_do_not_construct_services(self):
        for config in ({}, {**ENV, "CLRS_RUNTIME_WRITES_ENABLED": "0"},
                       {**ENV, "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "immutable-reviewed-snapshot"}):
            http = RuntimeMutationHttp(config, service_factory=lambda _: self.fail("Constructed"))
            reply = http.dispatch(env("/v1/runtime/chats/chat/messages", **{"wsgi.input": ForbiddenInput()}),
                                  native_service=self.native, native_configured=True)
            self.assertEqual(reply.status, "404 Not Found")
        self.assertEqual(self.native.calls, [])

    def test_current_get_and_send_share_pool_without_route_collision(self):
        reader = SimpleNamespace(messages=lambda identity, resource, **options:
            {"kind": "canonical-current", "chatId": resource, "items": [],
             "uid": identity.uid, "limit": options["limit"]})
        captured = []
        def create_reader(store, _):
            captured.append(store)
            return reader
        http = RuntimeMutationHttp(ENV, service_factory=lambda _: (self.services,) * 3,
                                   read_factory=create_reader)
        reply = http.dispatch(env("/v1/runtime/chats/chat/messages", REQUEST_METHOD="GET",
                                  QUERY_STRING="limit=2"),
                              native_service=self.native, native_configured=True)
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(reply.payload["chatId"], "chat")
        self.assertEqual(reply.payload["uid"], "self-uid")
        self.assertEqual(captured, [self.services])
        sent = http.dispatch(env("/v1/runtime/chats/chat/messages", {
            "operationId": OP, "text": "text", "quoteMessageId": None}),
            native_service=self.native, native_configured=True)
        self.assertEqual(sent.status, "201 Created")
        self.assertEqual(self.services.calls[-1][0], "send")

    def test_send_read_profile_forward_exact_self_identity_and_original_payload(self):
        request = env("/v1/runtime/chats/chat/messages", {
            "operationId": OP, "text": " original text ", "quoteMessageId": None},
            HTTP_X_FORWARDED_FOR="spoofed")
        self.assertEqual(self.request(request).status, "201 Created")
        kind, args, kw = self.services.calls[-1]
        self.assertEqual((kind, args[0].uid, args[1:]), ("send", "self-uid", ("chat", OP, " original text ")))
        self.assertEqual(kw, {"quote_message_id": None, "access_token": "na1.test"})
        self.assertEqual(self.native.calls[-1][1], "socket-peer")
        self.request(env("/v1/runtime/chats/chat/read", {"operationId": OP, "throughSequence": 7}))
        self.assertEqual(self.services.calls[-1][1][1:], ("chat", OP, 7))
        payload = {"expectedUpdatedAt": "2026-10-01T18:00:00.000000Z", "changes": {"age": 28}}
        self.request(env("/v1/runtime/me/profile", {"operationId": OP, **payload}))
        self.assertEqual(self.services.calls[-1][1][1:], (OP, payload))

    def test_no_firebase_token_fallback_or_body_read_before_authorization(self):
        for header in ("Bearer firebase.jwt", "Bearer nr1.refresh", "Basic token", "Bearer na1. bad"):
            reply = self.request(env("/v1/runtime/chats/chat/messages", HTTP_AUTHORIZATION=header,
                                     **{"wsgi.input": ForbiddenInput()}))
            self.assertEqual(reply.status, "401 Unauthorized")
            self.assertTrue(reply.authenticate)
        self.assertEqual(self.native.calls, [])
        self.assertEqual(self.services.calls, [])

    def test_unknown_target_uid_or_duplicate_body_keys_cannot_reach_writer(self):
        base = {"operationId": OP, "text": "hello", "quoteMessageId": None}
        for changes in ({"body": {**base, "targetUid": "other"}},
                        {"body": {**base, "operationId": "arbitrary"}},
                        {"CONTENT_LENGTH": "65537"}, {"HTTP_TRANSFER_ENCODING": "chunked"},
                        {"CONTENT_TYPE": "text/plain"}, {"QUERY_STRING": "uid=other"}):
            body = changes.pop("body", base)
            reply = self.request(env("/v1/runtime/chats/chat/messages", body, **changes))
            self.assertEqual(reply.status, "400 Bad Request")
        raw = b'{"operationId":"'+OP.encode()+b'","text":"a","text":"b","quoteMessageId":null}'
        reply = self.request(env("/v1/runtime/chats/chat/messages", **{
            "CONTENT_LENGTH": str(len(raw)), "wsgi.input": io.BytesIO(raw)}))
        self.assertEqual(reply.status, "400 Bad Request")
        self.assertEqual(self.services.calls, [])

    def test_reconcile_binds_exact_hash_operation_and_self_token(self):
        digest = "ab"*32
        reply = self.request(env("/v1/runtime/operations/chat.send-text.v1/"+OP,
            REQUEST_METHOD="GET", QUERY_STRING="requestHash="+digest))
        self.assertEqual(reply.status, "201 Created")
        kind, args, kw = self.services.calls[-1]
        self.assertEqual((kind, args[0].uid, args[1:]), ("lookup", "self-uid", ("chat.send-text.v1", OP)))
        self.assertEqual(kw["request_hash"], bytes.fromhex(digest))
        self.assertEqual(kw["access_token"], "na1.test")
        for query in ("requestHash="+digest+"&uid=other", "requestHash="+digest.upper(), "payload=private"):
            self.assertEqual(self.request(env("/v1/runtime/operations/chat.send-text.v1/"+OP,
                REQUEST_METHOD="GET", QUERY_STRING=query)).status, "400 Bad Request")

    def test_commit_uncertainty_is_unknown_and_never_retried(self):
        for error, status, key in ((RuntimeCommitUnknown, "503 Service Unavailable", "outcome_unknown"),
                                   (RuntimeConflict, "409 Conflict", "operation_conflict")):
            self.services.error = error
            before = len(self.services.calls)
            reply = self.request(env("/v1/runtime/chats/chat/messages", {
                "operationId": OP, "text": "hello", "quoteMessageId": None}))
            self.assertEqual((reply.status, reply.payload), (status, {"error": key}))
            self.assertEqual(len(self.services.calls)-before, 1)
            self.assertNotIn("private", json.dumps(reply.payload))

    def test_editor_get_has_no_body_and_accepts_no_foreign_uid(self):
        reply = self.request(env("/v1/runtime/me/profile", REQUEST_METHOD="GET"))
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(reply.payload["uid"], "self-uid")
        before = len(self.services.calls)
        reply = self.request(env("/v1/runtime/me/profile", REQUEST_METHOD="GET", QUERY_STRING="uid=other"))
        self.assertEqual(reply.status, "400 Bad Request")
        self.assertEqual(len(self.services.calls), before)


if __name__ == "__main__":
    unittest.main()
