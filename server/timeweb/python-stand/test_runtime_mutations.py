"""MySQL-shaped transaction fixtures: no TCP, cloud, credentials or real users."""
import base64
import copy
from dataclasses import replace
import json
import ssl
import threading
import time
import unittest
from unittest.mock import patch

from native_sessions import NativeIdentity, SessionTokens
from profile_store import BUNDLED_CA_FILE
from runtime_mutations import (RuntimeMutationStore, RuntimeInvalidRequest, RuntimeRejected,
    RuntimeConflict, RuntimeUnavailable, RuntimeCommitUnknown, request_digest, canonical_json,
    _TABLE_GRANTS)


NOW = 1800000000
STAMP = "2027-01-15T08:00:00.000001Z"
ENV = {"CLRS_RUNTIME_WRITES_ENABLED": "1",
    "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "canonical-current-v1",
    "CLRS_RUNTIME_DB_URL": "mysql://fixture:fixture@db.example.invalid/clrs_staging?sslmode=verify-full"}


def grants():
    return [("GRANT USAGE ON *.* TO 'fixture'@'%' REQUIRE SSL",)] + [
        ("GRANT " + ", ".join(sorted(privileges)) + " ON `clrs_staging`.`" + table + "` TO 'fixture'@'%'",)
        for table, privileges in _TABLE_GRANTS.items()]


class FakeDatabase:
    def __init__(self):
        self.lock = threading.RLock(); self.connections = []; self.calls = []
        self.tokens = SessionTokens(bytes(range(32)))
        self.session, access = self.tokens.mint("actor", "device", 7, NOW)
        self.access = access["accessToken"]
        self.identity = NativeIdentity("actor", True, self.session["session_id"], NOW, NOW + 900)
        self.state = {"accounts": {"actor": [0, "active", 7, 1], "peer": [0, "active", 0, 1]},
            "sessions": {self.session["session_id"]: self.session}, "receipts": {},
            "chats": {"chat": ["actor", "peer", 0, 0, "unchanged"]},
            "members": {("chat", "actor"): [0, 1, "archived UI only"], ("chat", "peer"): [0, 1, None]},
            "messages": {}, "counter": 0, "events": {}, "outbox": {},
            "legacy": {"retained": {"typed": ["unchanged"]}}}
        self.commit_unknown_once = False; self.fail_contains = None; self.grant_rows = grants()
        self.before_connect = None; self.rollback_error = False
        self.before_commit = None

    def connect(self, **config):
        assert config["ssl"].verify_mode == ssl.CERT_REQUIRED and config["ssl"].check_hostname
        if self.before_connect:
            self.before_connect()
        connection = FakeConnection(self); self.connections.append(connection)
        return connection


class FakeConnection:
    def __init__(self, db):
        self.db = db; self.state = None; self.held = False; self.closed = False
        self.commits = 0; self.rollbacks = 0; self.readonly = False

    def cursor(self):
        return FakeCursor(self)

    def begin(self):
        self.db.lock.acquire(); self.held = True; self.state = copy.deepcopy(self.db.state)

    def commit(self):
        assert self.held and not self.readonly
        if self.db.before_commit:
            self.db.before_commit()
        self.commits += 1; self.db.state = copy.deepcopy(self.state)
        self.held = False; self.db.lock.release()
        if self.db.commit_unknown_once:
            self.db.commit_unknown_once = False
            raise OSError("synthetic lost acknowledgement")

    def rollback(self):
        self.rollbacks += 1
        if self.held:
            self.held = False; self.db.lock.release()
        if self.db.rollback_error:
            raise OSError("synthetic rollback failure")

    def close(self):
        if self.held:
            self.rollback()
        self.closed = True


class FakeCursor:
    def __init__(self, connection):
        self.c = connection; self.rows = []; self.rowcount = 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return list(self.rows)

    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); db = self.c.db; state = self.c.state
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if db.fail_contains and db.fail_contains in sql:
            raise OSError("synthetic transaction failure")
        if sql == "SHOW GRANTS":
            self.rows = db.grant_rows
        elif sql == "SELECT DATABASE(), VERSION()":
            self.rows = [("clrs_staging", "8.4.4-fixture")]
        elif sql == "SHOW SESSION STATUS LIKE 'Ssl_cipher'":
            self.rows = [("Ssl_cipher", "TLS_AES_256_GCM_SHA384")]
        elif sql.startswith("SET "):
            if sql == "SET TRANSACTION READ ONLY":
                self.c.readonly = True
        elif "FROM clrs_staging.device_sessions AS s" in sql:
            self.assert_share(sql)
            session = state["sessions"].get(params[0])
            if session:
                account = state["accounts"].get(session["uid"])
                if account:
                    self.rows = [tuple(session[key] for key in ("session_id", "uid", "device_id",
                        "refresh_token_hash", "issued_at", "expires_at", "revoked_at", "rotated_from")) + tuple(account)]
        elif sql.startswith("INSERT INTO clrs_staging.idempotency_receipts"):
            uid, operation, key, digest, result = params
            receipt_key = (uid, operation, key)
            if receipt_key not in state["receipts"]:
                state["receipts"][receipt_key] = [digest, "processing", None, result, None, None]
                self.rowcount = 1
        elif sql.startswith("SELECT request_hash"):
            row = state["receipts"].get(tuple(params))
            self.rows = [tuple(row)] if row else []
        elif sql.startswith("UPDATE clrs_staging.idempotency_receipts"):
            status, response, revision, uid, operation, key, digest = params
            row = state["receipts"].get((uid, operation, key))
            if row and row[0] == digest and row[1] == "processing":
                row[:] = [digest, "completed", status, response, revision, STAMP]
                self.rowcount = 1
        elif sql.startswith("SELECT chat_id, uid_low"):
            chat = state["chats"].get(params[0])
            self.rows = [(params[0], *chat[:4])] if chat else []
        elif sql.startswith("SELECT uid, read_through_sequence"):
            self.rows = [(uid, *member[:2]) for (chat, uid), member in state["members"].items() if chat == params[0]]
        elif sql.startswith("SELECT uid, disabled, lifecycle"):
            account = state["accounts"].get(params[0])
            self.rows = [(params[0], *account[:2])] if account else []
        elif sql.startswith("SELECT message_id, sequence"):
            message = state["messages"].get(tuple(params))
            self.rows = [(params[1], message["sequence"], message["sender"], message["body"], message["deleted"])] if message else []
        elif sql.startswith("SELECT DATE_FORMAT(UTC_TIMESTAMP"):
            self.rows = [(STAMP,)]
        elif sql.startswith("INSERT INTO clrs_staging.chat_messages"):
            chat, message_id, sequence, sender, body, quote, created, raw = params
            assert (chat, message_id) not in state["messages"]
            assert not any(key[0] == chat and row["sequence"] == sequence for key, row in state["messages"].items())
            assert (chat, sender) in state["members"]
            assert quote is None or (chat, quote) in state["messages"]
            state["messages"][(chat, message_id)] = {"sequence": sequence, "sender": sender, "body": body,
                "quote": quote, "created": created, "raw": json.loads(raw), "deleted": None}
            self.rowcount = 1
        elif sql.startswith("UPDATE clrs_staging.chats SET last_sequence"):
            sequence, revision, created, chat_id, old_sequence, old_revision = params
            row = state["chats"].get(chat_id)
            if row and row[2:4] == [old_sequence, old_revision]:
                row[2:] = [sequence, revision, created]; self.rowcount = 1
        elif sql.startswith("UPDATE clrs_staging.chat_members"):
            sequence, chat, uid, old = params; row = state["members"].get((chat, uid))
            if row and row[0] == old:
                row[0] = sequence; self.rowcount = 1
        elif sql.startswith("UPDATE clrs_staging.chats SET revision"):
            revision, chat, old = params; row = state["chats"].get(chat)
            if row and row[3] == old:
                row[3] = revision; self.rowcount = 1
        elif sql.startswith("SELECT last_id FROM clrs_staging.event_counter"):
            self.rows = [(state["counter"],)]
        elif sql.startswith("UPDATE clrs_staging.event_counter"):
            new, old = params
            if state["counter"] == old:
                state["counter"] = new; self.rowcount = 1
        elif sql.startswith("INSERT INTO clrs_staging.user_events"):
            event, audience, kind, payload = params
            assert event not in state["events"]
            state["events"][event] = (audience, kind, json.loads(payload)); self.rowcount = 1
        elif sql.startswith("INSERT INTO clrs_staging.outbox"):
            key, event, audience, payload = params
            assert key not in state["outbox"]
            state["outbox"][key] = (event, audience, json.loads(payload)); self.rowcount = 1
        else:
            raise AssertionError("unexpected fixture SQL")
        return self.rowcount

    @staticmethod
    def assert_share(sql):
        assert sql.endswith("FOR SHARE OF s, a")


def store_for(db, **kwargs):
    return RuntimeMutationStore(ENV, db.tokens, connect=db.connect, clock=lambda: NOW, **kwargs)


class MutationTests(unittest.TestCase):
    def test_flags_tls_and_exact_grants(self):
        self.assertIsNone(RuntimeMutationStore.from_env({}))
        db = FakeDatabase(); store = store_for(db)
        config = store._configuration()
        self.assertEqual(config["ssl"].verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(config["ssl"].check_hostname)
        self.assertTrue(BUNDLED_CA_FILE.endswith("timeweb-ca.pem"))
        store._grants(grants())
        for change in ({"CLRS_RUNTIME_DB_CA_FILE": ""}, {"CLRS_RUNTIME_DB_CA_FILE": "/missing"},
                       {"CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "snapshot"}, {"CLRS_RUNTIME_PERMISSION_MODEL": "other"},
                       {"CLRS_RUNTIME_DB_URL": ENV["CLRS_RUNTIME_DB_URL"].replace("clrs_staging", "default_db")}):
            with self.subTest(change=tuple(change)), self.assertRaises(RuntimeUnavailable):
                RuntimeMutationStore({**ENV, **change}, db.tokens)._configuration()
        for extra in ("GRANT DELETE ON `clrs_staging`.`profiles` TO 'fixture'@'%'",
                      "GRANT SELECT ON `default_db`.* TO 'fixture'@'%'",
                      "GRANT SELECT ON `clrs_staging`.* TO 'fixture'@'%'",
                      "GRANT SELECT ON `clrs_staging`.`profiles` TO 'fixture'@'%' WITH GRANT OPTION"):
            with self.subTest(extra=extra), self.assertRaises(RuntimeUnavailable):
                store._grants([*grants(), (extra,)])
        provider = RuntimeMutationStore({**ENV, "CLRS_RUNTIME_PERMISSION_MODEL": "provider-database-v1"}, db.tokens)
        provider._grants([grants()[0], ("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.* TO 'fixture'@'%'",)])
        self.assertFalse(db.connections)

    def test_original_hash_replay_conflict_and_receipt_lookup(self):
        db = FakeDatabase(); store = store_for(db); calls = []
        def action(_, __, uid):
            calls.append(uid); return 200, {"saved": True}, None
        original = {"changes": {"fullName": "  Ж😀  "}, "expectedUpdatedAt": "stamp"}
        first = store.mutate(db.identity, "profile.edit.v1", "op", original, action, access_token=db.access)
        replay = store.mutate(db.identity, "profile.edit.v1", "op", original, action, access_token=db.access)
        self.assertFalse(first.payload["replayed"]); self.assertTrue(replay.payload["replayed"])
        self.assertEqual(calls, ["actor"])
        self.assertNotEqual(request_digest(original), request_digest({**original, "changes": {"fullName": "Ж😀"}}))
        with self.assertRaises(RuntimeConflict):
            store.mutate(db.identity, "profile.edit.v1", "op", {"changed": True}, action, access_token=db.access)
        found = store.lookup(db.identity, "profile.edit.v1", "op", request_hash=request_digest(original), access_token=db.access)
        self.assertEqual(found.payload["result"], {"saved": True})
        missing = store.lookup(db.identity, "profile.edit.v1", "missing", payload=original, access_token=db.access)
        self.assertEqual(missing.payload["state"], "not_found")
        self.assertEqual(sum(c.commits for c in db.connections), 2)
        with self.assertRaises(RuntimeInvalidRequest):
            store.lookup(db.identity, "profile.edit.v1", "op", payload=original,
                         request_hash=request_digest(original), access_token=db.access)

    def test_native_proof_status_version_expiry_and_readonly(self):
        db = FakeDatabase(); store = store_for(db)
        for change in (replace(db.identity, uid="peer"), replace(db.identity, expires_at=NOW + 899)):
            with self.assertRaises(RuntimeRejected):
                store.read_authenticated(change, lambda *_: {"ok": True}, access_token=db.access)
        for kind in ("version", "blocked", "revoked"):
            original = copy.deepcopy(db.state)
            if kind == "version": db.state["accounts"]["actor"][2] += 1
            if kind == "blocked": db.state["accounts"]["actor"][1] = "blocked"
            if kind == "revoked": db.state["sessions"][db.identity.session_id]["revoked_at"] = "2027-01-15 08:00:00.000000"
            with self.subTest(kind=kind), self.assertRaises(RuntimeRejected):
                store.read_authenticated(db.identity, lambda *_: {"ok": True}, access_token=db.access)
            db.state = original
        clock = [NOW]; store = RuntimeMutationStore(ENV, db.tokens, connect=db.connect, clock=lambda: clock[0])
        def expire(*_):
            clock[0] += 901; return 200, {"ok": True}, None
        with self.assertRaises(RuntimeRejected):
            store.mutate(db.identity, "profile.edit.v1", "expiry", {}, expire, access_token=db.access)
        self.assertFalse(db.state["receipts"])
        clock[0] = NOW
        self.assertEqual(store.read_authenticated(db.identity, lambda _, __, uid: {"uid": uid}, access_token=db.access), {"uid": "actor"})
        self.assertEqual(sum(c.commits for c in db.connections), 0)
        with self.assertRaises(RuntimeUnavailable):
            store.read_authenticated(db.identity, lambda _, execute, uid: execute(
                "UPDATE clrs_staging.profiles SET full_name = %s WHERE uid = %s", ("x", uid)), access_token=db.access)

    def test_unknown_commit_is_not_retried_and_lookup_reconciles(self):
        db = FakeDatabase(); store = store_for(db); calls = []
        db.commit_unknown_once = True; db.rollback_error = True
        def action(*_):
            calls.append(1); return 409, {"error": "profile_changed"}, None
        with self.assertRaises(RuntimeCommitUnknown):
            store.mutate(db.identity, "profile.edit.v1", "uncertain", {"x": 1}, action, access_token=db.access)
        self.assertEqual(calls, [1]); self.assertEqual(len(db.state["receipts"]), 1)
        db.rollback_error = False
        outcome = store.lookup(db.identity, "profile.edit.v1", "uncertain", payload={"x": 1}, access_token=db.access)
        self.assertEqual(outcome.status, 409); self.assertEqual(outcome.payload["state"], "committed")
        self.assertTrue(outcome.payload["replayed"]); self.assertEqual(calls, [1])

    def test_deadline_holds_slot_until_real_io_settles_and_close_refuses(self):
        db = FakeDatabase(); entered = threading.Event(); release = threading.Event()
        db.before_connect = lambda: (entered.set(), release.wait(2))
        store = store_for(db, request_seconds=0.04, concurrency=1)
        with self.assertRaises(RuntimeUnavailable):
            store.read_authenticated(db.identity, lambda *_: {"ok": True}, access_token=db.access)
        self.assertTrue(entered.is_set())
        with self.assertRaises(RuntimeUnavailable):
            store.read_authenticated(db.identity, lambda *_: {"ok": True}, access_token=db.access)
        release.set()
        deadline = time.monotonic() + 1
        while store._active and time.monotonic() < deadline:
            time.sleep(0.001)
        self.assertFalse(store._active); self.assertTrue(db.connections[0].closed)
        self.assertFalse(db.state["receipts"])
        store.close()
        with self.assertRaises(RuntimeUnavailable):
            store.read_authenticated(db.identity, lambda *_: {"ok": True}, access_token=db.access)

    def test_retained_tables_never_written_and_nonfinite_json_refused(self):
        db = FakeDatabase(); store = store_for(db)
        def bad(_, execute, uid):
            execute("UPDATE clrs_staging.legacy_documents SET payload = %s", ("changed",))
            return 200, {}, None
        with self.assertRaises(RuntimeUnavailable):
            store.mutate(db.identity, "profile.edit.v1", "raw", {}, bad, access_token=db.access)
        self.assertFalse(db.state["receipts"])
        self.assertEqual(db.state["legacy"], {"retained": {"typed": ["unchanged"]}})
        for value in ({"x": float("nan")}, {"x": "\ud800"}, {"x": "a" * 65536}, {1: "x"}):
            with self.subTest(kind=type(value)), self.assertRaises(RuntimeInvalidRequest):
                canonical_json(value)

    def test_receipt_internal_bound_does_not_reject_valid_unicode_profile(self):
        db = FakeDatabase(); store = store_for(db)
        changes = {"about": "😀" * 4096, "hobbi": "Ж" * 4096}
        request = {"expectedUpdatedAt": STAMP, "changes": changes}
        result = {"uid": "actor", "profile": changes}
        # Use two four-byte texts so request+response exceed the public cap,
        # while each of the request and actual public envelope still fits it.
        changes["hobbi"] = "😀" * 4096
        self.assertGreater(len(canonical_json({"request": request, "response": result}, max_bytes=131072)), 65536)
        outcome = store.mutate(db.identity, "profile.edit.v1", "large", request,
            lambda *_: (200, result, None), access_token=db.access)
        self.assertLess(len(canonical_json(outcome.payload)), 65536)
        retained = store.lookup(db.identity, "profile.edit.v1", "large", payload=request, access_token=db.access)
        self.assertEqual(retained.payload["result"], result)

    def test_pending_commit_deadline_requires_lookup_and_keeps_slot(self):
        db = FakeDatabase(); entered = threading.Event(); release = threading.Event()
        db.before_commit = lambda: (entered.set(), release.wait(1))
        store = store_for(db, request_seconds=0.04, concurrency=1)
        with self.assertRaises(RuntimeCommitUnknown):
            store.mutate(db.identity, "profile.edit.v1", "late", {"x": 1},
                         lambda *_: (200, {"saved": True}, None), access_token=db.access)
        self.assertTrue(entered.is_set())
        with self.assertRaises(RuntimeUnavailable):
            store.lookup(db.identity, "profile.edit.v1", "late", payload={"x": 1}, access_token=db.access)
        release.set()
        deadline = time.monotonic() + 1
        while store._active and time.monotonic() < deadline:
            time.sleep(0.001)
        self.assertFalse(store._active); self.assertTrue(db.connections[0].closed)
        db.before_commit = None
        found = store.lookup(db.identity, "profile.edit.v1", "late", payload={"x": 1}, access_token=db.access)
        self.assertEqual(found.payload["result"], {"saved": True})
        self.assertEqual(sum(c.commits for c in db.connections), 1)

    def test_worker_start_failure_releases_capacity(self):
        db = FakeDatabase(); store = store_for(db, concurrency=1)
        with patch("runtime_mutations.threading.Thread.start", side_effect=RuntimeError("fixture")):
            with self.assertRaises(RuntimeUnavailable):
                store.read_authenticated(db.identity, lambda *_: {"ok": True}, access_token=db.access)
        self.assertFalse(store._active); self.assertFalse(db.connections)
        self.assertEqual(store.read_authenticated(db.identity, lambda *_: {"ok": True}, access_token=db.access), {"ok": True})


if __name__ == "__main__":
    unittest.main()
