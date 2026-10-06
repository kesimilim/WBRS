"""Focused native HTTP/current-store synthetic cases; no TCP or real accounts."""
import copy
import ast
from pathlib import Path
import unittest
from urllib.parse import urlencode

from native_auth import NativeRejected, NativeRateLimited
from runtime_meetings import RuntimeMeetingsService, TRUSTED_POLICY, MEETING_ORDER
from runtime_meetings_http import RuntimeMeetingsHttp, PREFIX
from runtime_read_http import RuntimeReadHttp
from runtime_mutations import canonical_json
from test_runtime_meetings import MeetingsDatabase, KEY, READ_ENV, meeting
from test_runtime_mutations import NOW, STAMP, store_for
from test_runtime_people import source


class ForbiddenBody:
    def read(self, *_):
        raise AssertionError("Meeting GET must never read a body")


class Native:
    def __init__(self, db):
        self.identities = {db.access: db.identity}; self.calls = []; self.error = None

    def authorize(self, token, *, peer):
        self.calls.append((token, peer))
        if self.error:
            raise self.error()
        if token not in self.identities:
            raise NativeRejected()
        return self.identities[token]


def public_item(meeting_id="m", **changes):
    item = meeting(meeting_id, **changes)
    del item["legacy_raw"]; del item["deletedAt"]
    item.update(media=None, mediaReady=False)
    return item


def page(items=(), *, cursor=None):
    return {"kind": "canonical-current", "ordering": MEETING_ORDER, "scope": "group",
            "items": list(items), "nextCursor": cursor, "mediaReady": False}


class FixedReader:
    def __init__(self, value):
        self.value = value; self.calls = 0

    def meetings(self, *_args, **_options):
        self.calls += 1; return copy.deepcopy(self.value)

    def meeting(self, *_args, **_options):
        return self.meetings()

    def participants(self, *_args, **_options):
        return self.meetings()


class ChatReader:
    def __init__(self):
        self.calls = []

    def own_chats(self, identity, **options):
        self.calls.append((identity.uid, options))
        return {"kind": "canonical-current", "items": []}


class RuntimeMeetingsHttpTests(unittest.TestCase):
    def setUp(self):
        self.db = MeetingsDatabase(); self.store = store_for(self.db); self.now = NOW
        self.reader = RuntimeMeetingsService(self.store, KEY, trusted_policy=TRUSTED_POLICY, clock=lambda: self.now)
        self.native = Native(self.db); self.factories = []
        def factory(store, env):
            self.assertIs(store, self.store); self.assertEqual(env, READ_ENV)
            self.factories.append(store); return self.reader
        self.http = RuntimeMeetingsHttp(READ_ENV, self.store, service_factory=factory)
        self.addCleanup(self.http.close); self.addCleanup(self.store.close)

    def environ(self, path=PREFIX, query="", *, token=None, **extra):
        value = {"PATH_INFO": path, "QUERY_STRING": query, "REQUEST_METHOD": "GET",
            "HTTP_AUTHORIZATION": "Bearer " + (self.db.access if token is None else token),
            "REMOTE_ADDR": "127.0.0.1", "wsgi.input": ForbiddenBody()}
        value.update(extra); return value

    def request(self, path=PREFIX, query="", *, adapter=None, token=None, configured=True, **extra):
        return (self.http if adapter is None else adapter).dispatch(
            self.environ(path, query, token=token, **extra), native_service=self.native,
            native_configured=configured)

    def test_default_policy_missing_reader_disabled_flags_and_lazy_factory_are_closed(self):
        self.db.add_meeting("m")  # Even a valid marker cannot supply the default factory policy.
        default = RuntimeMeetingsHttp({**READ_ENV, "CLRS_RUNTIME_MEETINGS_TRUSTED_POLICY": TRUSTED_POLICY}, self.store)
        for _ in range(2):
            reply = self.request(adapter=default)
            self.assertEqual((reply.status, reply.payload), ("503 Service Unavailable", {"error": "service_unavailable"}))
        self.assertEqual(self.db.calls, []); self.assertEqual(self.factories, [])
        disabled = RuntimeMeetingsHttp({}, self.store, service_factory=lambda *_: self.fail("disabled factory"))
        self.assertEqual(self.request(adapter=disabled).status, "404 Not Found")
        missing = RuntimeMeetingsHttp(READ_ENV, None, service_factory=lambda *_: self.fail("missing store factory"))
        self.assertEqual(self.request(adapter=missing).status, "503 Service Unavailable")
        attempts = []
        def broken(*_):
            attempts.append(1); raise RuntimeError("private factory failure")
        broken_adapter = RuntimeMeetingsHttp(READ_ENV, self.store, service_factory=broken)
        for _ in range(2): self.assertEqual(self.request(adapter=broken_adapter).status, "503 Service Unavailable")
        self.assertEqual(attempts, [1]); self.assertFalse(self.store._closed)

    def test_real_list_detail_participants_unicode_route_exact_filters_and_read_only_owner(self):
        self.db.add_meeting("встреча", title="  Имя\t ", description="Описание\n", createdAt=None)
        self.db.join("встреча", "actor"); self.db.join("встреча", "peer")
        before = copy.deepcopy(self.db.state)
        query = urlencode({"scope": "group", "limit": 3, "countryCode": "RU", "region": "Москва"})
        listing = self.request(query=query)
        self.assertEqual(listing.status, "200 OK")
        self.assertEqual(listing.payload["items"][0]["meetingId"], "встреча")
        wsgi_target = (PREFIX + "/встреча").encode("utf-8").decode("latin-1")
        detail = self.request(wsgi_target)
        self.assertEqual(detail.status, "200 OK")
        self.assertEqual(detail.payload["meeting"], listing.payload["items"][0])
        self.assertEqual(detail.payload["meeting"]["title"], "  Имя\t ")
        roster = self.request(wsgi_target + "/participants", "limit=2")
        self.assertEqual(roster.status, "200 OK")
        self.assertEqual([p["uid"] for p in roster.payload["items"]], ["actor", "peer"])
        self.assertIsNone(roster.payload["items"][0]["avatar"])
        self.assertEqual(self.factories, [self.store]); self.assertEqual(self.db.state, before)
        self.assertTrue(all(c.closed and c.readonly and c.commits == 0 for c in self.db.connections))
        self.assertTrue(all(not sql.startswith(("INSERT", "UPDATE", "DELETE")) for sql, _ in self.db.calls))
        encoded = canonical_json(detail.payload)
        for private in (b"legacy", b"email", b"balance", b"role", b"token", b"media_id"):
            self.assertNotIn(private, encoded)

    def test_strict_query_body_and_path_bounds_fail_before_authorization_or_factory(self):
        invalid = ("limit=0", "limit=31", "limit=01", "limit=+1", "scope=public", "scope=",
            "limit=1&limit=2", "actorUid=other", "cursor=", "cursor=%ZZ", "cursor=%FF",
            "cursor=%00", "countryCode=ru", "countryCode=ZZ", "region=" + "%D0%9C",
            "countryCode=RU&region=+Москва", "limit=1&", "limit=1&scope=group&cursor=x&countryCode=RU&region=x&extra=1",
            "cursor=" + "x" * 4097, "q=" + "x" * 8193)
        for query in invalid:
            with self.subTest(query=query): self.assertEqual(self.request(query=query).status, "400 Bad Request")
        self.assertEqual(self.request(PREFIX + "/m", "limit=1").status, "400 Bad Request")
        self.assertEqual(self.request(PREFIX + "/m/participants", "scope=group").status, "400 Bad Request")
        for extra in ({"CONTENT_LENGTH": "1"}, {"CONTENT_LENGTH": "00"}, {"CONTENT_LENGTH": 0},
                      {"HTTP_TRANSFER_ENCODING": "chunked"}, {"HTTP_TRANSFER_ENCODING": ""}):
            with self.subTest(extra=extra): self.assertEqual(self.request(**extra).status, "400 Bad Request")
        for suffix in ("/", "/..", "/m%2Falias", "/m\\alias", "/m?alias", "/m/messages", "/" + "x" * 192,
                       "/" + "x" * 1100, "/bad\x00", "/\ud800", "/\xc3"):
            with self.subTest(suffix=suffix): self.assertEqual(self.request(PREFIX + suffix).status, "400 Bad Request")
        self.assertEqual(self.native.calls, []); self.assertEqual(self.factories, []); self.assertEqual(self.db.calls, [])

    def test_native_only_headers_methods_identity_and_rate_limit_have_safe_statuses(self):
        for header in ("Bearer firebase-token", "Bearer na1.synthetic", "Basic x", "bearer " + self.db.access,
                       "Bearer " + self.db.access + " ", "Bearer " + self.db.access + ",other", "Bearer " + "x" * 136,
                       "Bearer " + self.db.access + "\x00", ["Bearer " + self.db.access]):
            reply = self.request(HTTP_AUTHORIZATION=header)
            self.assertEqual(reply.status, "401 Unauthorized"); self.assertTrue(reply.authenticate)
        self.assertEqual(self.request(configured=False).status, "401 Unauthorized")
        self.assertEqual(self.native.calls, []); self.assertEqual(self.factories, [])
        for method in ("POST", "HEAD", "PUT", "DELETE", "OPTIONS"):
            self.assertEqual(self.request(REQUEST_METHOD=method).status, "405 Method Not Allowed")
        self.assertIsNone(self.request("/v1/legacy/meets"))
        self.native.error = NativeRateLimited
        reply = self.request(); self.assertEqual(reply.status, "429 Too Many Requests"); self.assertTrue(reply.retry)
        self.native.error = NativeRejected
        self.assertTrue(self.request().authenticate)
        self.native.error = None; self.native.identities[self.db.access] = object()
        self.assertEqual(self.request().status, "503 Service Unavailable")
        self.assertEqual(self.factories, [])
        reply = self.http.dispatch(self.environ(), native_service=None, native_configured=True)
        self.assertEqual(reply.status, "503 Service Unavailable")

    def test_current_hidden_deleted_kicked_private_and_imported_targets_are_404_without_logout(self):
        self.db.add("outsider")
        self.db.add_meeting("m")
        self.db.add_meeting("private", kind="individual", organizerUid="peer", invitedUid="outsider")
        self.db.add_meeting("imported", legacy_raw={"fields": {"private": True}})
        for target in ("missing", "private", "imported"):
            reply = self.request(PREFIX + "/" + target)
            self.assertEqual((reply.status, reply.payload), ("404 Not Found", {"error": "not_found"}))
            self.assertFalse(reply.authenticate)
        original = copy.deepcopy(self.db.state)
        for change in ("hidden", "deleted", "kicked"):
            self.db.state = copy.deepcopy(original)
            if change == "hidden": self.db.state["profiles"]["peer"]["legacy_raw"] = source("peer", isUnVisible={"booleanValue": True})
            elif change == "deleted": self.db.state["meetings"]["m"]["deletedAt"] = STAMP
            else: self.db.join("m", "actor", leftAt=STAMP, kickedAt=STAMP)
            for path in (PREFIX + "/m", PREFIX + "/m/participants"):
                reply = self.request(path)
                self.assertEqual(reply.status, "404 Not Found"); self.assertFalse(reply.authenticate)
        self.db.state = copy.deepcopy(original)
        self.db.state["accounts"]["actor"][0] = 1
        reply = self.request(PREFIX + "/m")
        self.assertEqual(reply.status, "401 Unauthorized"); self.assertTrue(reply.authenticate)

    def test_real_opaque_cursor_actor_scope_filter_limit_resource_purpose_and_expiry(self):
        for meeting_id in ("m0", "m1"): self.db.add_meeting(meeting_id)
        self.db.join("m0", "actor"); self.db.join("m0", "peer")
        first = self.request(query="limit=1"); cursor = first.payload["nextCursor"]
        self.assertEqual(first.status, "200 OK"); self.assertIsNotNone(cursor)
        second = self.request(query=urlencode({"limit": 1, "cursor": cursor}))
        self.assertEqual(second.status, "200 OK"); self.assertEqual(second.payload["items"][0]["meetingId"], "m1")
        for options in ({"limit": 2}, {"limit": 1, "scope": "individual"}, {"limit": 1, "countryCode": "RU"}):
            reply = self.request(query=urlencode({**options, "cursor": cursor}))
            self.assertEqual(reply.status, "400 Bad Request"); self.assertFalse(reply.authenticate)
        identity_b, token_b = self.db.actor_b(); self.native.identities[token_b] = identity_b
        self.assertEqual(self.request(query=urlencode({"limit": 1, "cursor": cursor}), token=token_b).status, "400 Bad Request")
        roster = self.request(PREFIX + "/m0/participants", "limit=1")
        member_cursor = roster.payload["nextCursor"]
        self.assertEqual(self.request(PREFIX + "/m1/participants", urlencode({"limit": 1, "cursor": member_cursor})).status, "400 Bad Request")
        self.assertEqual(self.request(query=urlencode({"limit": 1, "cursor": member_cursor})).status, "400 Bad Request")
        self.now += 300
        self.assertEqual(self.request(query=urlencode({"limit": 1, "cursor": cursor})).status, "400 Bad Request")

    def test_sparse_continuation_and_bounded_real_text_envelopes_survive_http_validation(self):
        for index in range(128): self.db.add_meeting(f"g{index:03}", region="Санкт-Петербург")
        self.db.add_meeting("g128", region="Москва")
        options = {"countryCode": "RU", "region": "Москва"}
        first = self.request(query=urlencode(options))
        self.assertEqual(first.status, "200 OK"); self.assertEqual(first.payload["items"], [])
        self.assertIsNotNone(first.payload["nextCursor"])
        second = self.request(query=urlencode({**options, "cursor": first.payload["nextCursor"]}))
        self.assertEqual(second.status, "200 OK"); self.assertEqual(second.payload["items"][0]["meetingId"], "g128")
        self.db.state["meetings"].clear()
        text = "🙂" * 4096
        for index in range(4): self.db.add_meeting(f"m{index}", description=text)
        result = self.request()
        self.assertEqual(result.status, "200 OK"); self.assertLessEqual(len(canonical_json(result.payload)), 65536)
        self.assertTrue(all(item["description"] == text for item in result.payload["items"]))
        self.assertIsNotNone(result.payload["nextCursor"])

    def test_malformed_or_private_reader_output_never_reaches_public_http(self):
        bad = [page([public_item()], cursor="invalid!"), {**page(), "legacy_raw": "private"},
               {**page(), "mediaReady": 0}, page([public_item(), public_item()]),
               page([public_item("z"), public_item("a")]), page([{**public_item(), "media": "https://private.invalid"}]),
               page([public_item(revision=True)]), page([public_item(title="bad\x00")]),
               page([public_item(f"m{index}", description="🙂" * 4096) for index in range(4)]),
               {"kind": "legacy-only", "items": []}]
        for index, value in enumerate(bad):
            with self.subTest(index=index):
                fixed = FixedReader(value)
                http = RuntimeMeetingsHttp(READ_ENV, self.store, service_factory=lambda *_: fixed)
                reply = self.request(adapter=http)
                self.assertEqual((reply.status, reply.payload), ("503 Service Unavailable", {"error": "service_unavailable"}))
                self.assertFalse(reply.authenticate)
        fixed = FixedReader({"kind": "canonical-current", "meeting": public_item("other"), "mediaReady": False})
        http = RuntimeMeetingsHttp(READ_ENV, self.store, service_factory=lambda *_: fixed)
        self.assertEqual(self.request(PREFIX + "/m", adapter=http).status, "503 Service Unavailable")
        fixed.value = page(cursor="same_cursor")
        self.assertEqual(self.request(query="cursor=same_cursor", adapter=http).status, "503 Service Unavailable")

    def test_revocation_after_real_read_and_adapter_close_drop_late_result_without_pool_close(self):
        self.db.add_meeting("m")
        self.db.after_read = lambda _, c: c.state["sessions"][self.db.identity.session_id].update(revoked_at=NOW)
        reply = self.request(PREFIX + "/m")
        self.assertEqual(reply.status, "401 Unauthorized"); self.assertTrue(reply.authenticate)
        self.db.after_read = lambda *_: self.http.close()
        reply = self.request(PREFIX + "/m")
        self.assertEqual(reply.status, "503 Service Unavailable"); self.assertFalse(reply.authenticate)
        count = len(self.db.calls)
        self.assertEqual(self.request().status, "503 Service Unavailable")
        self.assertEqual(len(self.db.calls), count)
        self.assertFalse(self.store._closed)
        self.assertTrue(all(c.closed and c.commits == 0 for c in self.db.connections))

    def test_dispatcher_shared_store_injection_preserves_existing_reads_and_unrelated_handoffs(self):
        self.db.add_meeting("m")
        chats = ChatReader()
        dispatcher = RuntimeReadHttp(READ_ENV, self.store, read_factory=lambda *_: chats,
            people_factory=lambda *_: None, admin_factory=lambda *_: None,
            meetings_factory=lambda store, _env: self.reader if store is self.store else self.fail("new pool"))
        reply = self.request(PREFIX + "/m", adapter=dispatcher)
        self.assertEqual(reply.status, "200 OK")
        reply = self.request("/v1/runtime/chats", "limit=2", adapter=dispatcher)
        self.assertEqual(reply.status, "200 OK"); self.assertEqual(chats.calls[0][0], "actor")
        self.assertIsNone(self.request("/v1/runtime/me/profile", adapter=dispatcher))
        self.assertIsNone(self.request("/v1/runtime/chats/chat/messages", adapter=dispatcher, REQUEST_METHOD="POST"))
        dispatcher.close()
        self.assertEqual(self.request(adapter=dispatcher).status, "503 Service Unavailable")
        self.assertFalse(self.store._closed)

    def test_exact_app_default_factory_injects_reviewed_policy_without_changing_closed_adapters(self):
        # Execute only the app's small construction function; importing the whole
        # app would initialize unrelated authentication/media configuration.
        from runtime_http import RuntimeMutationHttp
        tree = ast.parse(Path(__file__).with_name("app.py").read_text())
        factory = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "_native_runtime_http")
        create = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "create_app")
        defaults = {arg.arg: value for arg, value in zip(create.args.kwonlyargs, create.args.kw_defaults)}
        self.assertEqual(defaults["runtime_http_factory"].id, factory.name)
        namespace = {"RuntimeMeetingsService": RuntimeMeetingsService, "TRUSTED_POLICY": TRUSTED_POLICY,
            "RuntimeMutationHttp": lambda config, **options: RuntimeMutationHttp(config,
                service_factory=lambda _: (self.store, None, None), **options)}
        exec(compile(ast.Module(body=[factory], type_ignores=[]), "app-construction", "exec"), namespace)
        self.db.add_meeting("m")
        assembled = namespace[factory.name](READ_ENV)
        reply = self.request(PREFIX + "/m", adapter=assembled)
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(reply.payload["meeting"]["localDatetime"], "03.10.2026 19:15")
        self.assertIsNone(RuntimeMeetingsService.from_env(self.store, READ_ENV))
        closed = RuntimeMutationHttp(READ_ENV, service_factory=lambda _: (self.store, None, None))
        self.assertEqual(self.request(adapter=closed).status, "503 Service Unavailable")
        self.assertFalse(self.store._closed)


if __name__ == "__main__":
    unittest.main()
