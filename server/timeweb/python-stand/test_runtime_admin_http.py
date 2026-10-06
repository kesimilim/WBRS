"""Focused native admin HTTP proof, using synthetic native/current SQL stores."""
import copy
import unittest
from urllib.parse import urlencode

from native_auth import NativeRejected, NativeRateLimited
from runtime_admin_http import RuntimeAdminUsersHttp, ADMIN_USERS_PATH
from runtime_admin_users import RuntimeAdminRoleRejected
from runtime_mutations import RuntimeRejected, RuntimeUnavailable
from runtime_read_http import RuntimeReadHttp
from test_runtime_admin_users import AdminDatabase
from test_runtime_mutations import STAMP


ENABLED = {"CLRS_RUNTIME_WRITES_ENABLED": "1",
           "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "canonical-current-v1"}


class ForbiddenInput:
    def read(self, _):
        raise AssertionError("Admin GET never reads a body")


class Native:
    def __init__(self, identity):
        self.identity = identity; self.calls = []; self.error = None

    def authorize(self, token, *, peer):
        self.calls.append((token, peer))
        if self.error: raise self.error("private authorization diagnostic")
        return self.identity


class Reader:
    def __init__(self):
        self.calls = []; self.error = None; self.change = None; self.on_read = None

    def users(self, identity, **options):
        self.calls.append((identity, options))
        if self.error: raise self.error("private service diagnostic")
        page = {"kind": "canonical-admin-users", "ordering": "uid_binary_asc", "items": [], "nextCursor": None}
        if self.change: self.change(page)
        if self.on_read: self.on_read()
        return page


def request(**changes):
    return {"PATH_INFO": ADMIN_USERS_PATH, "REQUEST_METHOD": "GET", "QUERY_STRING": "",
        "HTTP_AUTHORIZATION": "Bearer na1.synthetic", "REMOTE_ADDR": "socket-peer",
        "wsgi.input": ForbiddenInput(), **changes}


class AdminHttpTests(unittest.TestCase):
    def setUp(self):
        self.db = AdminDatabase(); self.native = Native(self.db.identity); self.reader = Reader()
        self.constructed = []
        self.store = object()
        def factory(store, env):
            self.constructed.append((store, env)); return self.reader
        self.factory = factory
        self.http = RuntimeAdminUsersHttp(ENABLED, self.store, service_factory=factory)

    def dispatch(self, **changes):
        return self.http.dispatch(request(**changes), native_service=self.native, native_configured=True)

    def test_exact_native_identity_normalized_options_and_lazy_same_pool(self):
        self.assertEqual(self.constructed, [])
        reply = self.dispatch(QUERY_STRING=urlencode({"query": " АЛ ", "limit": "10", "cursor": "opaque_-token"}),
                              HTTP_X_FORWARDED_FOR="spoofed")
        self.assertEqual(reply.status, "200 OK")
        identity, options = self.reader.calls[-1]
        self.assertIs(identity, self.db.identity)
        self.assertEqual(options, {"query": "ал", "limit": 10, "cursor": "opaque_-token", "access_token": "na1.synthetic"})
        self.assertEqual(self.native.calls[-1], ("na1.synthetic", "socket-peer"))
        self.assertIs(self.constructed[0][0], self.store)
        self.assertEqual(self.dispatch().status, "200 OK"); self.assertEqual(len(self.constructed), 1)

    def test_no_factory_on_unmatched_off_method_body_or_invalid_auth(self):
        for path in ("/admin", "/v1/runtime/admin/users/", "/v1/runtime/people", "/v1/runtime/admin/users/peer"):
            self.assertIsNone(self.dispatch(PATH_INFO=path))
        for config in ({}, {**ENABLED, "CLRS_RUNTIME_WRITES_ENABLED": "0"},
                       {**ENABLED, "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "snapshot"}):
            off = RuntimeAdminUsersHttp(config, self.store, service_factory=self.factory)
            self.assertEqual(off.dispatch(request(), native_service=self.native, native_configured=True).status, "404 Not Found")
        for method in ("POST", "PUT", "DELETE", "HEAD"):
            self.assertEqual(self.dispatch(REQUEST_METHOD=method).status, "405 Method Not Allowed")
        for options in ({"CONTENT_LENGTH": "1"}, {"HTTP_TRANSFER_ENCODING": "chunked"}):
            self.assertEqual(self.dispatch(**options).status, "400 Bad Request")
        for header in ("Bearer firebase.jwt", "Bearer nr1.refresh", "Basic test", "Bearer na1. space"):
            self.assertEqual(self.dispatch(HTTP_AUTHORIZATION=header).status, "401 Unauthorized")
        self.assertEqual(self.constructed, []); self.assertEqual(self.native.calls, [])

    def test_query_allowlist_duplicate_type_length_prefix_and_utf8_refusal(self):
        for query in ("uid=peer", "admin=true", "email=x", "role=admin", "query=a", "query=x%00", "query=x%7F",
                      "limit=0", "limit=31", "limit=01", "limit=1&limit=2", "query=ab&query=cd",
                      "cursor=", "cursor=a%2Fb", "query=%ZZ", "query=%FF", "query=%ED%A0%80",
                      "query=" + "x" * 101, "limit=1&query=ab&cursor=x&extra=y", "query=ab&",
                      "query=" + "x" * 8193):
            with self.subTest(query=query[:25]):
                self.assertEqual(self.dispatch(QUERY_STRING=query).status, "400 Bad Request")
        self.assertEqual(self.native.calls, []); self.assertEqual(self.constructed, [])

    def test_role_denied_is_403_without_authenticate_native_denied_is_401(self):
        self.reader.error = RuntimeAdminRoleRejected
        reply = self.dispatch()
        self.assertEqual((reply.status, reply.payload, reply.authenticate), ("403 Forbidden", {"error": "forbidden"}, False))
        self.reader.error = RuntimeRejected
        reply = self.dispatch(); self.assertEqual(reply.status, "401 Unauthorized"); self.assertTrue(reply.authenticate)
        self.reader.error = RuntimeUnavailable
        reply = self.dispatch(); self.assertEqual(reply.payload, {"error": "service_unavailable"})
        self.reader.error = None; self.native.error = NativeRateLimited
        self.assertTrue(self.dispatch().retry)
        self.native.error = NativeRejected
        self.assertTrue(self.dispatch().authenticate)

    def test_unknown_private_fields_bad_admin_types_order_bound_and_cursor_fail_closed(self):
        def item(uid="peer"):
            return {"uid": uid, "email": None, "fullName": None, "age": None,
                    "lifecycle": "active", "disabled": False}
        changes = [lambda page: page.__setitem__("raw", {"private": True}),
            lambda page: page.__setitem__("items", [{**item(), "role": "admin"}]),
            lambda page: page.__setitem__("items", [{**item(), "passwordHash": "private"}]),
            lambda page: page.__setitem__("items", [{**item(), "disabled": 0}]),
            lambda page: page.__setitem__("items", [{**item(), "age": True}]),
            lambda page: page.__setitem__("items", [item(), item()]),
            lambda page: page.__setitem__("items", [item("z"), item("a")]),
            lambda page: page.__setitem__("items", [item() for _ in range(31)]),
            lambda page: page.__setitem__("items", [{**item(), "fullName": "x" * 1001}]),
            lambda page: page.__setitem__("items", [{**item(), "email": "x" * 321}]),
            lambda page: page.__setitem__("items", [{**item(), "email": "Upper@example.invalid"}]),
            lambda page: page.__setitem__("nextCursor", "https://private.invalid"),
            lambda page: page.__setitem__("nextCursor", "x" * 4097)]
        for change in changes:
            self.reader.change = change
            self.assertEqual(self.dispatch().payload, {"error": "service_unavailable"})
        self.reader.change = lambda page: page.__setitem__("nextCursor", "input")
        self.assertEqual(self.dispatch(QUERY_STRING="cursor=input").status, "503 Service Unavailable")
        self.reader.change = lambda page: page.__setitem__("items", [{**item(), "fullName": "other"}])
        self.assertEqual(self.dispatch(QUERY_STRING="query=ab").status, "503 Service Unavailable")
        # Each item fits, while the complete page exceeds the response budget.
        self.reader.change = lambda page: page.__setitem__("items", [
            {**item(f"u{i:02}"), "fullName": "😀" * 1000} for i in range(30)])
        self.assertEqual(self.dispatch().status, "503 Service Unavailable")

    def test_sparse_empty_cursor_is_preserved_and_close_does_not_close_pool(self):
        self.reader.change = lambda page: page.__setitem__("nextCursor", "opaque_next")
        result = self.dispatch(); self.assertEqual(result.status, "200 OK")
        self.assertEqual(result.payload["items"], []); self.assertEqual(result.payload["nextCursor"], "opaque_next")
        self.http.close(); self.assertEqual(self.dispatch().status, "503 Service Unavailable")
        self.assertEqual(len(self.reader.calls), 1)
        # An already-started action also cannot publish after adapter closure.
        http = RuntimeAdminUsersHttp(ENABLED, self.store, service_factory=lambda *_: self.reader)
        self.reader.on_read = http.close
        self.assertEqual(http.dispatch(request(), native_service=self.native, native_configured=True).status, "503 Service Unavailable")

    def test_real_native_store_role_proof_revoke_next_page_and_actor_cursor(self):
        db = AdminDatabase(); peer, peer_access = db.peer_identity()
        db.state["roles"][("peer", "admin")] = ["approved_uid", None]
        store, service = db.services(); native = Native(db.identity)
        http = RuntimeAdminUsersHttp(ENABLED, store, service_factory=lambda *_: service)
        req = request(HTTP_AUTHORIZATION="Bearer " + db.access, QUERY_STRING="limit=1")
        before = copy.deepcopy(db.state)
        reply = http.dispatch(req, native_service=native, native_configured=True)
        self.assertEqual(reply.status, "200 OK"); self.assertEqual(db.state, before)
        cursor = reply.payload["nextCursor"]
        req["QUERY_STRING"] = urlencode({"limit": 1, "cursor": cursor})
        db.state["roles"][("actor", "admin")][1] = STAMP
        denied = http.dispatch(req, native_service=native, native_configured=True)
        self.assertEqual(denied.status, "403 Forbidden"); self.assertFalse(denied.authenticate)
        db.state["roles"][("actor", "admin")][1] = None
        native.identity = peer; req["HTTP_AUTHORIZATION"] = "Bearer " + peer_access
        self.assertEqual(http.dispatch(req, native_service=native, native_configured=True).status, "400 Bad Request")
        db.state["accounts"]["peer"][0] = 1
        self.assertEqual(http.dispatch(req, native_service=native, native_configured=True).status, "401 Unauthorized")
        self.assertEqual(sum(c.commits for c in db.connections), 0)
        store.close()

    def test_real_post_role_or_session_failure_and_strict_missing_privilege(self):
        for kind, expected in (("role", "403 Forbidden"), ("session", "401 Unauthorized"), ("permission", "503 Service Unavailable")):
            db = AdminDatabase(provider=kind != "permission"); store, service = db.services()
            if kind == "role": db.after_scan = lambda c: c.state["roles"][("actor", "admin")].__setitem__(1, STAMP)
            if kind == "session": db.after_scan = lambda c: c.state["accounts"]["actor"].__setitem__(2, 8)
            http = RuntimeAdminUsersHttp(ENABLED, store, service_factory=lambda *_: service)
            reply = http.dispatch(request(HTTP_AUTHORIZATION="Bearer " + db.access),
                native_service=Native(db.identity), native_configured=True)
            self.assertEqual(reply.status, expected); self.assertNotIn("items", reply.payload)
            store.close()

    def test_shared_read_http_seam_keeps_existing_paths_and_lazy_factory(self):
        class CurrentReader:
            def own_chats(self, *_args, **_options): return {"kind": "canonical-current", "items": []}
        http = RuntimeReadHttp(ENABLED, self.store, read_factory=lambda *_: CurrentReader(),
            people_factory=lambda *_: None, admin_factory=self.factory)
        self.assertEqual(self.constructed, [])
        current = http.dispatch(request(PATH_INFO="/v1/runtime/chats"), native_service=self.native, native_configured=True)
        self.assertEqual(current.status, "200 OK"); self.assertEqual(self.constructed, [])
        self.assertIsNone(http.dispatch(request(PATH_INFO="/v1/runtime/me/profile")))
        admin = http.dispatch(request(), native_service=self.native, native_configured=True)
        self.assertEqual(admin.status, "200 OK"); self.assertIs(self.constructed[0][0], self.store)
        http.close()
        self.assertEqual(http.dispatch(request(), native_service=self.native, native_configured=True).status, "503 Service Unavailable")


if __name__ == "__main__":
    unittest.main()
