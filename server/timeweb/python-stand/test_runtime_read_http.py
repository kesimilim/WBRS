import unittest

from native_auth import NativeRejected, NativeRateLimited
from native_sessions import NativeIdentity
from runtime_reads import RuntimeReadRejected
from runtime_read_http import RuntimeReadHttp


ENABLED = {"CLRS_RUNTIME_WRITES_ENABLED": "1",
           "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "canonical-current-v1"}


class Native:
    def __init__(self, error=None):
        self.error = error
        self.calls = []

    def authorize(self, token, *, peer):
        self.calls.append((token, peer))
        if self.error:
            raise self.error()
        return NativeIdentity("owner", True, "session", 1, 2)


class Reader:
    def __init__(self):
        self.calls = []
        self.error = None

    def own_chats(self, identity, **options):
        return self._call("chats", identity, options)

    def messages(self, identity, resource, **options):
        return self._call("messages", identity, {**options, "chatId": resource})

    def own_events(self, identity, **options):
        return self._call("events", identity, options)

    def people(self, identity, **options):
        return self._call("people", identity, options)

    def public_person(self, identity, resource, **options):
        return self._call("person", identity, {**options, "profileUid": resource})

    def _call(self, operation, identity, options):
        self.calls.append((operation, identity.uid, options))
        if self.error:
            raise self.error()
        return {"kind": "canonical-current", "items": []}


class RuntimeReadHttpTests(unittest.TestCase):
    def setUp(self):
        self.reader = Reader()
        self.native = Native()
        self.http = RuntimeReadHttp(ENABLED, object(), read_factory=lambda *_: self.reader,
                                    people_factory=lambda *_: self.reader)

    def request(self, path="/v1/runtime/chats", query="", **extra):
        env = {"PATH_INFO": path, "QUERY_STRING": query, "REQUEST_METHOD": "GET",
               "HTTP_AUTHORIZATION": "Bearer na1.synthetic", "REMOTE_ADDR": "127.0.0.1"}
        env.update(extra)
        return self.http.dispatch(env, native_service=self.native, native_configured=True)

    def test_disabled_and_missing_reader_fail_closed(self):
        closed = RuntimeReadHttp({}, None)
        self.assertEqual(closed.dispatch({"PATH_INFO": "/v1/runtime/chats"}).status, "404 Not Found")
        broken = RuntimeReadHttp(ENABLED, None)
        reply = broken.dispatch({"PATH_INFO": "/v1/runtime/chats", "REQUEST_METHOD": "GET",
            "HTTP_AUTHORIZATION": "Bearer na1.synthetic"}, native_configured=True,
            native_service=self.native)
        self.assertEqual(reply.status, "503 Service Unavailable")
        self.assertEqual(self.native.calls, [])

    def test_exact_routes_identity_and_fixed_options(self):
        self.assertEqual(self.request(query="limit=10&cursor=opaque_-cursor").status, "200 OK")
        self.assertEqual(self.reader.calls[-1], ("chats", "owner",
            {"limit": 10, "cursor": "opaque_-cursor", "access_token": "na1.synthetic"}))
        self.request("/v1/runtime/chats/chat1/messages", "beforeSequence=9&limit=3")
        self.assertEqual(self.reader.calls[-1][2], {"chatId": "chat1", "limit": 3,
            "before_sequence": 9, "access_token": "na1.synthetic"})
        self.request("/v1/runtime/events", "afterEventId=0")
        self.assertEqual(self.reader.calls[-1][2]["after_event_id"], 0)

    def test_duplicate_unknown_oversized_and_noncanonical_query_rejected(self):
        for query in ("limit=1&limit=2", "limit=0", "limit=101", "limit=01",
                      "uid=other", "cursor=", "cursor=%ZZ", "cursor=%FF",
                      "limit=1&cursor=a&extra=b", "limit=1&"):
            with self.subTest(query=query):
                self.assertEqual(self.request(query=query).status, "400 Bad Request")
        self.assertEqual(self.request("/v1/runtime/chats/c/messages", "beforeSequence=0").status,
                         "400 Bad Request")
        self.assertEqual(self.request("/v1/runtime/events", "afterEventId=9223372036854775808").status,
                         "400 Bad Request")
        self.assertEqual(self.native.calls, [])

    def test_request_body_and_non_native_tokens_are_rejected(self):
        self.assertEqual(self.request(CONTENT_LENGTH="1").status, "400 Bad Request")
        self.assertEqual(self.request(HTTP_TRANSFER_ENCODING="chunked").status, "400 Bad Request")
        self.assertEqual(self.request(HTTP_AUTHORIZATION="Bearer firebase-token").status,
                         "401 Unauthorized")
        self.assertEqual(self.reader.calls, [])

    def test_post_message_handoff_and_other_method_rules(self):
        self.assertIsNone(self.request("/v1/runtime/chats/c/messages", REQUEST_METHOD="POST"))
        self.assertIsNone(self.request("/v1/runtime/me/profile"))
        self.assertEqual(self.request(REQUEST_METHOD="POST").status, "405 Method Not Allowed")
        self.assertEqual(self.request("/v1/runtime/events", REQUEST_METHOD="HEAD").status,
                         "405 Method Not Allowed")

    def test_private_service_failures_have_safe_statuses(self):
        self.reader.error = RuntimeReadRejected
        self.assertEqual(self.request("/v1/runtime/chats/foreign/messages").status, "404 Not Found")
        self.reader.error = RuntimeError
        self.assertEqual(self.request().payload, {"error": "service_unavailable"})
        self.reader.error = None
        self.native.error = NativeRateLimited
        self.assertTrue(self.request().retry)
        self.native.error = NativeRejected
        self.assertTrue(self.request().authenticate)

    def test_close_drops_reader_without_double_closing_shared_store(self):
        self.http.close()
        self.assertEqual(self.request().status, "503 Service Unavailable")
        self.assertEqual(self.reader.calls, [])

    def test_people_exact_filters_and_public_target_use_verified_actor(self):
        reply = self.request("/v1/runtime/people", "limit=10&minAge=20&maxAge=40&countryCode=RU")
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(self.reader.calls[-1], ("people", "owner", {
            "limit": 10, "min_age": 20, "max_age": 40, "country_code": "RU", "access_token": "na1.synthetic"}))
        reply = self.request("/v1/runtime/people/public-peer")
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(self.reader.calls[-1], ("person", "owner", {
            "profileUid": "public-peer", "access_token": "na1.synthetic"}))
        self.assertEqual(self.request("/v1/runtime/people/public-peer", "uid=other").status, "400 Bad Request")
        self.assertEqual(self.request("/v1/runtime/people", REQUEST_METHOD="POST").status, "405 Method Not Allowed")

    def test_people_hidden_target_and_unavailable_reader_have_safe_responses(self):
        self.reader.error = RuntimeReadRejected
        reply = self.request("/v1/runtime/people/hidden")
        self.assertEqual((reply.status, reply.payload), ("404 Not Found", {"error": "not_found"}))
        self.reader.error = RuntimeError
        self.assertEqual(self.request("/v1/runtime/people").payload, {"error": "service_unavailable"})
        self.http.close()
        self.assertEqual(self.request("/v1/runtime/people").status, "503 Service Unavailable")


if __name__ == "__main__":
    unittest.main()
