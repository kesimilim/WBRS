"""Focused personal-chat proof; synthetic rows only, no TCP/cloud/schema writes."""
import copy
import json
import threading
import unittest

from native_sessions import NativeIdentity
from runtime_chat import RuntimeChatService
from runtime_http import RuntimeMutationHttp
from runtime_mutations import (RuntimeMutationStore, RuntimeInvalidRequest, RuntimeRejected,
    RuntimeUnavailable, RuntimeConflict, RuntimeCommitUnknown, request_digest)
from runtime_personal_chat import (RuntimePersonalChatService, PersonalChatAccessRejected, OPEN_OPERATION, personal_pair,
                                  _INDEX_PARTS)
from test_runtime_mutations import FakeDatabase, FakeCursor, ENV, NOW, STAMP, grants
from test_runtime_http import Native, Services, env, OP, ENV as HTTP_ENV, ForbiddenInput


def legacy(**fields):
    return {"fields": {"status": {"stringValue": "active"}, **fields},
        "createTime": "2026-10-01T00:00:00Z", "updateTime": "2026-10-01T00:00:01Z"}


class PersonalCursor(FakeCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); state = self.c.state; db = self.c.db
        personal = ("WHERE uid_low = %s AND uid_high = %s" in sql
            or "FROM information_schema.STATISTICS" in sql or sql.startswith("SELECT p.uid, a.disabled")
            or sql.startswith("INSERT INTO clrs_staging.chats ")
            or sql.startswith("INSERT INTO clrs_staging.chat_members "))
        if not personal:
            return super().execute(statement, params)
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if db.fail_contains and db.fail_contains in sql:
            raise OSError("synthetic transaction failure")
        if "WHERE uid_low = %s AND uid_high = %s" in sql:
            assert params[0:2] == params[2:4]
            self.rows = [(chat_id, *chat[:4]) for chat_id, chat in state["chats"].items()
                         if chat[:2] == list(params[:2])]
        elif "FROM information_schema.STATISTICS" in sql:
            self.rows = copy.deepcopy(db.indexes)
        elif sql.startswith("SELECT p.uid, a.disabled"):
            assert params[0] == params[1] and sql.endswith("FOR SHARE OF p, a")
            account, profile = state["accounts"].get(params[0]), state["profiles"].get(params[0])
            if account is not None and profile is not None:
                raw = profile["raw"]
                encoded = raw if type(raw) is str else json.dumps(raw)
                self.rows = [(params[0], *account[:2], profile["saved"], profile["complete"],
                              profile["invisible"], encoded)]
        elif sql.startswith("INSERT INTO clrs_staging.chats "):
            chat_id, low, high, created, updated, raw = params
            assert chat_id not in state["chats"] and low.encode() < high.encode()
            assert not any(row[:2] == [low, high] for row in state["chats"].values())
            assert created == updated and raw == "{}"
            state["chats"][chat_id] = [low, high, 0, 0, created]; self.rowcount = 1
        else:
            chat_id, uid = params
            assert chat_id in state["chats"] and (chat_id, uid) not in state["members"]
            state["members"][(chat_id, uid)] = [0, 1, None]; self.rowcount = 1
        return self.rowcount


class PersonalDatabase(FakeDatabase):
    def __init__(self, *, provider=True, existing=False):
        super().__init__()
        if not existing:
            self.state["chats"] = {}; self.state["members"] = {}
        self.state["profiles"] = {uid: {"raw": {}, "saved": 1, "complete": 1,
            "invisible": None, "fullName": None} for uid in ("actor", "peer")}
        self.indexes = [(table, index, 0, sequence, column, None, "utf8mb4_0900_bin")
            for table, index, sequence, column in sorted(_INDEX_PARTS)]
        self.env = {**ENV, "CLRS_RUNTIME_PERMISSION_MODEL":
                    "provider-database-v1" if provider else "strict-tables-v1"}
        if provider:
            self.grant_rows = [grants()[0],
                ("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.* TO 'fixture'@'%'",)]

    def connect(self, **config):
        connection = super().connect(**config)
        connection.cursor = lambda: PersonalCursor(connection)
        return connection

    def services(self):
        store = RuntimeMutationStore(self.env, self.tokens, connect=self.connect, clock=lambda: NOW)
        return store, RuntimePersonalChatService(store, clock=lambda: NOW)

    def peer_identity(self):
        session, access = self.tokens.mint("peer", "peer-device", 0, NOW)
        self.state["sessions"][session["session_id"]] = session
        return NativeIdentity("peer", True, session["session_id"], NOW, NOW + 900), access["accessToken"]


class PersonalTests(unittest.TestCase):
    def open(self, db, service, operation="open", target="peer"):
        return service.open_personal(db.identity, target, operation, access_token=db.access)

    def test_pair_is_exact_stable_ordered_and_has_no_names(self):
        for left, right in (("actor", "peer"), ("я", "A"), ("A ", "A"), ("😀", "я")):
            first = personal_pair(left, right)
            self.assertEqual(first, personal_pair(right, left))
            self.assertLess(first[0].encode(), first[1].encode())
            self.assertRegex(first[2], r"^tw-pair-[0-9a-f]{64}$")
        for value in ("actor", "", ".", "..", "x/y", "x\n", None, True, "x" * 192):
            with self.subTest(value=type(value)), self.assertRaises(RuntimeInvalidRequest):
                personal_pair("actor", value)
        self.assertNotEqual(personal_pair("actor", "peer")[2], personal_pair("Actor", "peer")[2])

    def test_create_atomic_then_find_from_both_actors_without_duplicates(self):
        db = PersonalDatabase(); peer, peer_access = db.peer_identity(); store, service = db.services()
        original = copy.deepcopy(db.state)
        created = self.open(db, service); chat_id = created.payload["result"]["chatId"]
        self.assertEqual(created.status, 201)
        self.assertEqual(created.payload["result"], {"chatId": chat_id, "peerUid": "peer",
            "created": True, "chatRevision": 0})
        self.assertEqual(set(db.state["members"]), {(chat_id, "actor"), (chat_id, "peer")})
        self.assertEqual([row[:2] for row in db.state["members"].values()], [[0, 1], [0, 1]])
        found = self.open(db, service, "find")
        reverse = service.open_personal(peer, "actor", "reverse", access_token=peer_access)
        self.assertEqual((found.status, reverse.status), (200, 200))
        self.assertFalse(found.payload["result"]["created"])
        self.assertEqual(reverse.payload["result"]["chatId"], chat_id)
        self.assertEqual(len(db.state["chats"]), 1)
        for key in ("accounts", "profiles", "messages", "legacy", "counter", "events", "outbox"):
            self.assertEqual(db.state[key], original[key])
        self.assertFalse(any("full_name" in sql for sql, _ in db.calls))
        store.close()

    def test_existing_imported_id_and_member_settings_are_retained(self):
        db = PersonalDatabase(existing=True, provider=False); _, service = db.services()
        before = copy.deepcopy(db.state)
        reply = self.open(db, service)
        self.assertEqual(reply.status, 200)
        self.assertEqual(reply.payload["result"]["chatId"], "chat")
        self.assertEqual(db.state["chats"], before["chats"])
        self.assertEqual(db.state["members"], before["members"])
        self.assertFalse(any(sql.startswith("INSERT INTO clrs_staging.chats ") for sql, _ in db.calls))

    def test_strict_grants_fail_closed_for_create_without_changing_send_read(self):
        db = PersonalDatabase(provider=False); store, service = db.services()
        before = copy.deepcopy(db.state)
        with self.assertRaises(RuntimeUnavailable):
            self.open(db, service)
        self.assertEqual(db.state, before)
        self.assertFalse(any(sql.startswith("INSERT INTO clrs_staging.chats ") for sql, _ in db.calls))
        db.state["chats"]["chat"] = ["actor", "peer", 0, 0, "unchanged"]
        db.state["members"] = {("chat", "actor"): [0, 1, None], ("chat", "peer"): [0, 1, None]}
        chat = RuntimeChatService(store)
        sent = chat.send_text(db.identity, "chat", "send", "synthetic", access_token=db.access)
        replayed = chat.send_text(db.identity, "chat", "send", "synthetic", access_token=db.access)
        self.assertEqual((sent.status, replayed.status), (201, 201))
        self.assertTrue(replayed.payload["replayed"])
        read = chat.mark_read(db.identity, "chat", "read", 1, access_token=db.access)
        reread = chat.mark_read(db.identity, "chat", "read", 1, access_token=db.access)
        self.assertEqual((read.status, reread.status), (200, 200))
        self.assertTrue(reread.payload["replayed"])

    def test_self_missing_hidden_disabled_incomplete_or_malformed_never_create(self):
        changes = [lambda db: db.state["profiles"].pop("peer"),
            lambda db: db.state["accounts"]["peer"].__setitem__(0, 1),
            lambda db: db.state["accounts"]["peer"].__setitem__(1, "blocked"),
            lambda db: db.state["profiles"]["peer"].__setitem__("complete", 0),
            lambda db: db.state["profiles"]["actor"].__setitem__("saved", 0),
            lambda db: db.state["profiles"]["peer"].__setitem__("invisible", "2030-01-01T00:00:00Z"),
            lambda db: db.state["profiles"]["peer"].__setitem__("raw", {"fields": {}}),
            lambda db: db.state["profiles"]["peer"].__setitem__("raw", "{\"x\":1,\"x\":2}"),
            lambda db: db.state["profiles"]["peer"].__setitem__("raw", "x" * 131_073),
            lambda db: db.state["profiles"]["peer"].__setitem__("raw", legacy(isUnvisible={"booleanValue": True})),
            lambda db: db.state["profiles"]["peer"].__setitem__("raw", legacy(status={"stringValue": "blocked"}))]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                db = PersonalDatabase(); change(db); _, service = db.services()
                reply = self.open(db, service)
                self.assertEqual((reply.status, reply.payload["result"]), (404, {"error": "person_unavailable"}))
                self.assertEqual(db.state["chats"], {}); self.assertEqual(db.state["members"], {})
        db = PersonalDatabase(); _, service = db.services(); before = copy.deepcopy(db.state)
        with self.assertRaises(RuntimeInvalidRequest):
            self.open(db, service, target="actor")
        self.assertEqual(db.state, before)

    def test_legacy_eligibility_uses_source_without_requiring_native_completion(self):
        db = PersonalDatabase(); db.state["profiles"]["peer"].update(raw=legacy(), saved=0, complete=0)
        _, service = db.services()
        self.assertEqual(self.open(db, service).status, 201)

    def test_missing_unique_prefix_or_nonbinary_metadata_refuses_before_create(self):
        for mutation in (lambda rows: rows.pop(), lambda rows: rows.append(rows[0]),
                         lambda rows: rows.__setitem__(0, (*rows[0][:5], 10, rows[0][6])),
                         lambda rows: rows.__setitem__(0, (*rows[0][:6], "utf8mb4_general_ci")),
                         lambda rows: rows.__setitem__(0, (*rows[0][:2], 1, *rows[0][3:]))):
            db = PersonalDatabase(); mutation(db.indexes); _, service = db.services()
            before = copy.deepcopy(db.state)
            with self.assertRaises(RuntimeUnavailable):
                self.open(db, service)
            self.assertEqual(db.state, before)

    def test_member_insert_failure_rolls_back_chat_and_receipt(self):
        db = PersonalDatabase(); db.fail_contains = "INSERT INTO clrs_staging.chat_members"
        _, service = db.services(); before = copy.deepcopy(db.state)
        with self.assertRaises(RuntimeUnavailable):
            self.open(db, service)
        self.assertEqual(db.state, before)
        self.assertTrue(any(sql.startswith("INSERT INTO clrs_staging.chats ") for sql, _ in db.calls))
        self.assertEqual(sum(c.commits for c in db.connections), 0)

    def test_replay_and_request_conflict_keep_one_conversation(self):
        db = PersonalDatabase(); store, service = db.services()
        first = self.open(db, service); replay = self.open(db, service)
        self.assertEqual(first.payload["result"], replay.payload["result"])
        self.assertTrue(replay.payload["replayed"])
        with self.assertRaises(RuntimeConflict):
            self.open(db, service, target="another")
        found = store.lookup(db.identity, OPEN_OPERATION, "open", payload={"targetUid": "peer"}, access_token=db.access)
        self.assertEqual(found.payload["result"], first.payload["result"])
        self.assertEqual(len(db.state["chats"]), 1)

    def test_unknown_commit_reconciles_fresh_without_automatic_retry(self):
        for did_commit in (True, False):
            with self.subTest(did_commit=did_commit):
                db = PersonalDatabase(); store, service = db.services()
                if did_commit:
                    db.commit_unknown_once = True
                else:
                    def lost_before_commit():
                        raise OSError("synthetic connection lost before commit")
                    db.before_commit = lost_before_commit
                with self.assertRaises(RuntimeCommitUnknown):
                    self.open(db, service)
                self.assertEqual(len(db.connections), 1)
                db.before_commit = None
                found = store.lookup(db.identity, OPEN_OPERATION, "open", payload={"targetUid": "peer"}, access_token=db.access)
                self.assertEqual(found.payload["state"], "committed" if did_commit else "not_found")
                self.assertEqual(len(db.connections), 2)
                self.assertEqual(len(db.state["chats"]), int(did_commit))
                self.assertTrue(db.connections[-1].readonly)

    def test_declared_target_failure_is_retained_without_invalidating_session(self):
        db = PersonalDatabase(); store, service = db.services()
        db.state["profiles"]["peer"]["invisible"] = "2030-01-01T00:00:00Z"
        first = self.open(db, service)
        found = store.lookup(db.identity, OPEN_OPERATION, "open",
            payload={"targetUid": "peer"}, access_token=db.access)
        self.assertEqual((first.status, found.status), (404, 404))
        self.assertEqual(first.payload["result"], {"error": "person_unavailable"})
        self.assertEqual(found.payload["result"], first.payload["result"])
        self.assertTrue(found.payload["replayed"])
        self.assertEqual(len(db.state["chats"]), 0)

    def test_receipt_rechecks_current_visibility_disable_and_membership(self):
        for change in (lambda db: db.state["profiles"]["peer"].__setitem__("invisible", "2030-01-01T00:00:00Z"),
                       lambda db: db.state["profiles"]["actor"].__setitem__("complete", 0),
                       lambda db: db.state["accounts"]["peer"].__setitem__(0, 1),
                       lambda db: db.state["members"].pop(next(key for key in db.state["members"] if key[1] == "peer"))):
            db = PersonalDatabase(); store, service = db.services(); self.open(db, service); change(db)
            before = copy.deepcopy(db.state)
            with self.assertRaises(PersonalChatAccessRejected):
                self.open(db, service)
            with self.assertRaises(PersonalChatAccessRejected):
                store.lookup(db.identity, OPEN_OPERATION, "open", payload={"targetUid": "peer"}, access_token=db.access)
            self.assertEqual(db.state, before)
        db = PersonalDatabase(); store, service = db.services(); self.open(db, service)
        db.state["accounts"]["actor"][0] = 1
        with self.assertRaises(RuntimeRejected):
            store.lookup(db.identity, OPEN_OPERATION, "open", payload={"targetUid": "peer"}, access_token=db.access)

    def test_empty_foreign_or_replaced_receipt_chat_cannot_escape_guard(self):
        for response_change in (lambda response: response.clear(),
                                lambda response: response.__setitem__("chatId", "another-chat"),
                                lambda response: response.__setitem__("chatId", ""),
                                lambda response: response.__setitem__("peerUid", "another")):
            db = PersonalDatabase(); store, service = db.services(); self.open(db, service)
            receipt = db.state["receipts"][("actor", OPEN_OPERATION, "open")]
            wrapper = json.loads(receipt[3]); response_change(wrapper["response"]); receipt[3] = json.dumps(wrapper)
            with self.assertRaises(RuntimeUnavailable):
                store.lookup(db.identity, OPEN_OPERATION, "open", payload={"targetUid": "peer"}, access_token=db.access)
        db = PersonalDatabase(); store, service = db.services(); self.open(db, service)
        chat_id = next(iter(db.state["chats"]))
        db.state["chats"]["replacement"] = db.state["chats"].pop(chat_id)
        db.state["members"] = {("replacement", uid): row for (_, uid), row in db.state["members"].items()}
        with self.assertRaises(RuntimeUnavailable):
            self.open(db, service)

    def test_concurrent_operation_ids_and_replay_share_one_pair(self):
        for operations in (("same", "same"), ("left", "right")):
            db = PersonalDatabase(); _, service = db.services(); barrier = threading.Barrier(2)
            results, errors = [], []
            def run(operation):
                try:
                    barrier.wait(timeout=2); results.append(self.open(db, service, operation))
                except Exception as error:
                    errors.append(type(error).__name__)
            threads = [threading.Thread(target=run, args=(operation,)) for operation in operations]
            for thread in threads: thread.start()
            for thread in threads: thread.join(timeout=3)
            self.assertFalse(errors); self.assertEqual(len(results), 2)
            self.assertEqual(len(db.state["chats"]), 1); self.assertEqual(len(db.state["members"]), 2)
            self.assertEqual(len(db.state["receipts"]), len(set(operations)))


class PersonalHttpServices(Services):
    def open_personal(self, *args, **kw):
        return self._result("open", args, kw)


class PersonalHttpTests(unittest.TestCase):
    def setUp(self):
        self.native = Native(); self.services = PersonalHttpServices()
        self.http = RuntimeMutationHttp(HTTP_ENV, service_factory=lambda _: (self.services,) * 4)

    def request(self, request):
        return self.http.dispatch(request, native_service=self.native, native_configured=True)

    def test_target_denial_is_404_without_authentication_challenge(self):
        def refused(*args, **kwargs):
            raise PersonalChatAccessRejected()
        self.services.open_personal = refused
        self.services.lookup = refused
        for request in (env("/v1/runtime/personal-chats", {"operationId": OP, "targetUid": "peer"}),
            env("/v1/runtime/operations/" + OPEN_OPERATION + "/" + OP,
                REQUEST_METHOD="GET", QUERY_STRING="requestHash=" + request_digest({"targetUid": "peer"}).hex())):
            reply = self.request(request)
            self.assertEqual(reply.status, "404 Not Found")
            self.assertEqual(reply.payload, {"error": "person_unavailable"})
            self.assertFalse(reply.authenticate)

    def test_exact_route_body_token_and_reconciliation(self):
        reply = self.request(env("/v1/runtime/personal-chats", {"operationId": OP, "targetUid": "peer"}))
        self.assertEqual(reply.status, "201 Created")
        kind, args, kw = self.services.calls[-1]
        self.assertEqual((kind, args[0].uid, args[1:]), ("open", "self-uid", ("peer", OP)))
        self.assertEqual(kw, {"access_token": "na1.test"})
        reply = self.request(env("/v1/runtime/operations/" + OPEN_OPERATION + "/" + OP,
            REQUEST_METHOD="GET", QUERY_STRING="requestHash=" + request_digest({"targetUid": "peer"}).hex()))
        self.assertEqual(reply.status, "201 Created")
        self.assertEqual(self.services.calls[-1][0], "lookup")

    def test_no_body_before_authorization_extra_identity_or_guess_fields(self):
        reply = self.request(env("/v1/runtime/personal-chats", HTTP_AUTHORIZATION="Bearer firebase.jwt",
                                **{"wsgi.input": ForbiddenInput()}))
        self.assertEqual(reply.status, "401 Unauthorized")
        for extra in ({"uid": "foreign"}, {"chatId": "guess"}, {"publicProfile": {"fullName": "guess"}}):
            self.assertEqual(self.request(env("/v1/runtime/personal-chats",
                {"operationId": OP, "targetUid": "peer", **extra})).status, "400 Bad Request")
        self.assertEqual(self.request(env("/v1/runtime/personal-chats", REQUEST_METHOD="GET")).status, "405 Method Not Allowed")
        self.assertEqual(self.services.calls, [])

    def test_default_off_and_old_factory_fail_closed_for_only_new_route(self):
        http = RuntimeMutationHttp({}, service_factory=lambda _: self.fail("constructed"))
        reply = http.dispatch(env("/v1/runtime/personal-chats"), native_service=self.native, native_configured=True)
        self.assertEqual(reply.status, "404 Not Found")
        http = RuntimeMutationHttp(HTTP_ENV, service_factory=lambda _: (self.services,) * 3)
        reply = http.dispatch(env("/v1/runtime/personal-chats", {"operationId": OP, "targetUid": "peer"}),
                              native_service=self.native, native_configured=True)
        self.assertEqual(reply.status, "503 Service Unavailable")
        old = http.dispatch(env("/v1/runtime/chats/chat/messages", {"operationId": OP,
            "text": "synthetic", "quoteMessageId": None}), native_service=self.native, native_configured=True)
        self.assertEqual(old.status, "201 Created")


if __name__ == "__main__":
    unittest.main()
