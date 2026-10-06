"""Resource HTTP contracts with synthetic identities; no cloud or SQL calls."""
import json
import base64
import unittest

from auth_bridge import AuthenticatedIdentity, AuthRejected, AuthUnavailable
from app import create_app
from legacy_conversation_http import LegacyConversationHttp, create_legacy_read_service
from legacy_conversation_read import LegacyReadRejected, LegacyReadRateLimited, LegacyReadUnavailable
from legacy_own_profile import LegacyReadApiService
from native_auth import NativeRejected
from native_sessions import NativeIdentity
from test_native_http import request

ENV = {"CLRS_API_DRAFT_ENABLED": "1", "CLRS_LEGACY_READ_ENABLED": "1",
    "CLRS_LEGACY_READ_SNAPSHOT_REVIEWED": "1",
    "CLRS_LEGACY_READ_MEMBERSHIP_MODE": "immutable-reviewed-snapshot",
    "FIREBASE_PROJECT_ID": "synthetic-project", "FIREBASE_WEB_API_KEY": "public-test-key"}


class Service:
    def __init__(self): self.calls = []; self.error = None; self.response = {"items": []}
    def __getattr__(self, operation):
        def call(identity, *args, **kwargs):
            self.calls.append((operation, identity, args, kwargs))
            if self.error: raise self.error("private synthetic record and token")
            return self.response
        return call


class LegacyHttpTest(unittest.TestCase):
    def setUp(self):
        self.service = Service(); self.identities = []
        self.identity = AuthenticatedIdentity("owner-A", 10, 10, 100)
        def verify(token, **kwargs):
            self.identities.append((token, kwargs)); return self.identity
        self.dispatcher = LegacyConversationHttp(ENV,
            service_factory=lambda env: self.service, identity_verifier=verify)
        self.app = create_app(env=ENV, legacy_http_factory=lambda env: self.dispatcher)
    def get(self, path, **kwargs):
        return request(self.app, path, method="GET", header="Bearer synthetic-token", **kwargs)

    def test_explicit_snapshot_gate_routes_are_default_off(self):
        for change in ({"CLRS_LEGACY_READ_ENABLED": "0"},
                       {"CLRS_LEGACY_READ_SNAPSHOT_REVIEWED": "0"},
                       {"CLRS_LEGACY_READ_MEMBERSHIP_MODE": "mutable"}):
            dispatcher = LegacyConversationHttp(ENV | change,
                service_factory=lambda _: self.fail("Unexpected service construction"))
            self.assertEqual(dispatcher.dispatch({"PATH_INFO": "/v1/chats", "REQUEST_METHOD": "GET"}).status,
                             "404 Not Found")
        response = self.get("/v1/chats")
        self.assertEqual(response["headers"]["Cache-Control"], "no-store")

    def test_real_route_identity_and_query_never_take_target_owner(self):
        rows = [("/v1/chats", "personal_chats", ()),
            ("/v1/meetings", "own_meetings", ()),
            ("/v1/chats/chat-A/messages", "personal_messages", ("chat-A",)),
            ("/v1/meetings/meet-A/messages", "meeting_messages", ("meet-A",)),
            ("/v1/meetings/meet-A/participants", "meeting_participants", ("meet-A",))]
        for path, operation, args in rows:
            self.assertEqual(self.get(path, QUERY_STRING="limit=5&cursor=opaque_cursor")["status"], "200 OK")
            self.assertEqual(self.service.calls[-1], (operation, self.identity, args, {"limit": 5, "cursor": "opaque_cursor"}))
        self.assertEqual(self.get("/v1/meetings/meet-A")["status"], "200 OK")
        self.assertEqual(self.service.calls[-1], ("meeting_details", self.identity, ("meet-A",), {}))

    def test_wsgiref_utf8_path_and_owned_removed_flag_are_preserved(self):
        path = "/v1/meetings/встреча/messages".encode().decode("latin1")
        self.assertEqual(self.get(path, QUERY_STRING="own_removed=1")["status"], "200 OK")
        self.assertEqual(self.service.calls[-1][2], ("встреча",))
        self.assertTrue(self.service.calls[-1][3]["own_removed"])
        self.assertEqual(self.get("/v1/chats/chat-A/messages", QUERY_STRING="own_removed=1")["status"], "400 Bad Request")

    def test_query_bounds_duplicates_unknown_owner_and_injection_fail_before_auth(self):
        queries = ["limit=0", "limit=51", "limit=01", "limit=5&limit=6", "uid=other",
            "accessToken=secret", "cursor=", "cursor=" + "a"*4097, "cursor=%zz",
            "cursor=%ff", "own_removed=true", "limit", "x=" + "a"*8193]
        for query in queries:
            self.assertEqual(self.get("/v1/meetings/meet-A/messages", QUERY_STRING=query)["status"], "400 Bad Request")
        self.assertEqual(self.get("/v1/meetings/meet-A", QUERY_STRING="limit=1")["status"], "400 Bad Request")
        self.assertEqual(self.identities, []); self.assertEqual(self.service.calls, [])

    def test_unknown_paths_and_writes_are_closed(self):
        for path in ["/v1/chats/chat-A", "/v1/chats/chat-A/participants", "/v1/chats/../messages",
                     "/v1/chats/a/b/messages", "/sql", "/v1/admin/users", "/v1/media/private"]:
            self.assertEqual(self.get(path)["status"], "404 Not Found")
        self.assertEqual(request(self.app, "/v1/chats", body={"message": "text"})["status"], "405 Method Not Allowed")
        self.assertEqual(self.identities, []); self.assertEqual(self.service.calls, [])

    def test_native_prefix_never_falls_back_and_identity_must_be_typed(self):
        for token in ["na1.invalid", "nr1.invalid"]:
            reply = self.dispatcher.dispatch({"PATH_INFO": "/v1/chats", "REQUEST_METHOD": "GET",
                "HTTP_AUTHORIZATION": "Bearer " + token}, native_configured=False)
            self.assertEqual(reply.status, "401 Unauthorized")
        self.assertEqual(self.identities, [])
        class Native:
            def authorize(self, token, *, peer):
                if token != "na1.valid": raise NativeRejected()
                return NativeIdentity("owner-B", True, "session", 10, 100)
        reply = self.dispatcher.dispatch({"PATH_INFO": "/v1/chats", "REQUEST_METHOD": "GET",
            "HTTP_AUTHORIZATION": "Bearer na1.valid", "REMOTE_ADDR": "proxy"},
            native_configured=True, native_service=Native())
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(self.service.calls[-1][1].uid, "owner-B")
        self.assertEqual(self.identities, [])
        self.identity = "unverified-owner"
        self.assertEqual(self.get("/v1/chats")["status"], "503 Service Unavailable")
        self.assertEqual(len(self.service.calls), 1)

    def test_resource_refusal_generic_error_and_response_bound(self):
        for error, status in [(LegacyReadRejected, "404 Not Found"),
            (LegacyReadRateLimited, "429 Too Many Requests"), (RuntimeError, "503 Service Unavailable")]:
            self.service.error = error
            response = self.get("/v1/chats")
            self.assertEqual(response["status"], status)
            self.assertNotIn("private", response["raw"].decode())
            if error is LegacyReadRateLimited:
                self.assertEqual(response["headers"]["Retry-After"], "60")
        self.service.error = None; self.service.response = {"text": "a" * 262144}
        self.assertEqual(self.get("/v1/chats")["status"], "503 Service Unavailable")

    def test_full_profile_default_off_fixed_route_and_shared_factory(self):
        for change in ({"CLRS_LEGACY_READ_ENABLED": "0"},
                       {"CLRS_LEGACY_READ_SNAPSHOT_REVIEWED": "0"},
                       {"CLRS_LEGACY_READ_MEMBERSHIP_MODE": "mutable"}):
            closed = LegacyConversationHttp(ENV | change,
                service_factory=lambda _: self.fail("Unexpected service construction"))
            self.assertEqual(closed.dispatch({"PATH_INFO": "/v1/me/full-profile",
                "REQUEST_METHOD": "GET"}).status, "404 Not Found")
        combined = create_legacy_read_service(ENV | {
            "CLRS_LEGACY_CURSOR_KEY_B64": base64.b64encode(b"K"*32).decode()})
        self.assertIs(type(combined), LegacyReadApiService)
        self.assertTrue(callable(combined.own_profile))
        self.assertTrue(callable(combined.personal_chats))
        self.assertTrue(callable(combined.meeting_messages))
        self.assertEqual(request(self.app,"/v1/me/full-profile",body={})["status"],"405 Method Not Allowed")
        self.assertEqual(self.get("/v1/me/full-profile/other")["status"],"404 Not Found")
        self.assertEqual([],self.identities); self.assertEqual([],self.service.calls)

    def test_full_profile_each_request_uses_verified_firebase_or_native_identity_only(self):
        self.service.response={"profile":None,"onboarding":"registration","uid":"owner-A"}
        for uid in ("owner-A","owner-B"):
            self.identity=AuthenticatedIdentity(uid,10,10,100)
            self.service.response["uid"]=uid
            response=self.get("/v1/me/full-profile")
            self.assertEqual("200 OK",response["status"])
            self.assertEqual("no-store",response["headers"]["Cache-Control"])
            self.assertEqual(("own_profile",self.identity,(),{}),self.service.calls[-1])
        self.assertEqual(2,len(self.identities))
        native_identity=NativeIdentity("owner-native",True,"synthetic-session",10,100)
        calls=[]
        class Native:
            def authorize(self,token,*,peer):
                calls.append((token,peer)); return native_identity
        self.service.response["uid"]=native_identity.uid
        reply=self.dispatcher.dispatch({"PATH_INFO":"/v1/me/full-profile","REQUEST_METHOD":"GET",
            "HTTP_AUTHORIZATION":"Bearer na1.synthetic","REMOTE_ADDR":"synthetic-peer"},
            native_configured=True,native_service=Native())
        self.assertEqual("200 OK",reply.status)
        self.assertEqual(("own_profile",native_identity,(),{}),self.service.calls[-1])
        self.assertEqual([("na1.synthetic","synthetic-peer")],calls)
        self.assertEqual(2,len(self.identities))  # Native never invokes Firebase fallback.

    def test_full_profile_rejects_every_query_before_identity_or_read(self):
        for query in ["&","&&","?","uid=other","limit=1","cursor=opaque","own_removed=1","x=",
                      "uid=other&uid=owner","uid=%ff","%zz=1","uid","a="+"x"*8193]:
            self.assertEqual("400 Bad Request",self.get("/v1/me/full-profile",QUERY_STRING=query)["status"])
        self.assertEqual([],self.identities); self.assertEqual([],self.service.calls)

    def test_full_profile_unavailable_auth_error_and_oversize_are_generic_failclosed(self):
        unavailable=LegacyConversationHttp(ENV,service_factory=lambda _: (_ for _ in ()).throw(RuntimeError("private")))
        self.assertEqual("503 Service Unavailable",unavailable.dispatch({"PATH_INFO":"/v1/me/full-profile",
            "REQUEST_METHOD":"GET","HTTP_AUTHORIZATION":"Bearer synthetic"}).status)
        for error,status in [(LegacyReadRejected,"404 Not Found"),(LegacyReadUnavailable,"503 Service Unavailable"),
                             (RuntimeError,"503 Service Unavailable")]:
            self.service.error=error; response=self.get("/v1/me/full-profile")
            self.assertEqual(status,response["status"]); self.assertNotIn("private",response["raw"].decode())
        self.service.error=None; self.service.response={"profile":{"fullName":"x"*262144}}
        self.assertEqual("503 Service Unavailable",self.get("/v1/me/full-profile")["status"])
        self.identity={"uid":"guessed"}; before=len(self.service.calls)
        self.assertEqual("503 Service Unavailable",self.get("/v1/me/full-profile")["status"])
        self.assertEqual(before,len(self.service.calls))
        native_reply=self.dispatcher.dispatch({"PATH_INFO":"/v1/me/full-profile","REQUEST_METHOD":"GET",
            "HTTP_AUTHORIZATION":"Bearer na1.unavailable"},native_configured=False)
        self.assertEqual("401 Unauthorized",native_reply.status)


if __name__ == "__main__": unittest.main()
