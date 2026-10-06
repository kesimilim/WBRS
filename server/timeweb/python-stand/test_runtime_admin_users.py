"""Synthetic current-admin read proof: no TCP, real identities or role writes."""
import base64
import copy
from dataclasses import replace
import json
import unittest

from native_sessions import NativeIdentity
from runtime_admin_users import (RuntimeAdminUsersService, normalize_admin_query,
    admin_users_query, ADMIN_ORDER, MAX_SCAN_ROWS, SCAN_CHUNK)
from runtime_mutations import RuntimeMutationStore, RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from test_runtime_mutations import FakeDatabase, FakeCursor, ENV, NOW, STAMP, grants


KEY = bytes(range(32))
ADMIN_KEYS = {"uid", "email", "fullName", "age", "lifecycle", "disabled"}


class AdminDatabase(FakeDatabase):
    def __init__(self, *, provider=True):
        super().__init__()
        self.state["profiles"] = {}
        self.state["adminUsers"] = {"actor": {"email": "actor@example.invalid", "fullName": None, "age": None},
                                    "peer": {"email": None, "fullName": "Пользователь", "age": 0}}
        self.state["roles"] = {("actor", "admin"): ["approved_uid", None]}
        self.env = {**ENV, "CLRS_RUNTIME_PERMISSION_MODEL":
                    "provider-database-v1" if provider else "strict-tables-v1"}
        if provider:
            self.grant_rows = [grants()[0],
                ("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.* TO 'fixture'@'%'",)]
        self.after_scan = None; self.forced_role = None; self.forced_rows = None
        self.forbid_role_select = not provider; self.scan_sizes = []

    def connect(self, **config):
        connection = super().connect(**config)
        connection.cursor = lambda: AdminCursor(connection)
        return connection

    def services(self, *, clock=lambda: NOW):
        store = RuntimeMutationStore(self.env, self.tokens, connect=self.connect, clock=lambda: NOW)
        return store, RuntimeAdminUsersService(store, KEY, clock=clock)

    def add(self, uid, *, email=None, full_name=None, age=None, disabled=0, lifecycle="active"):
        self.state["accounts"][uid] = [disabled, lifecycle, 0, 1]
        self.state["adminUsers"][uid] = {"email": email, "fullName": full_name, "age": age}

    def peer_identity(self):
        session, access = self.tokens.mint("peer", "peer-device", 0, NOW)
        self.state["sessions"][session["session_id"]] = session
        return NativeIdentity("peer", True, session["session_id"], NOW, NOW + 900), access["accessToken"]


class AdminCursor(FakeCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); db = self.c.db; state = self.c.state
        if "FROM clrs_staging.role_grants" not in sql and not sql.startswith("SELECT a.uid, a.email_normalized"):
            return super().execute(statement, params)
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        assert self.c.readonly and self.c.held
        if "FROM clrs_staging.role_grants" in sql:
            assert params[0] == params[1] and sql.endswith("LIMIT 2 FOR SHARE")
            if db.forbid_role_select:
                raise OSError("synthetic SELECT permission refusal")
            grant = state["roles"].get((params[0], "admin"))
            self.rows = [(params[0], "admin", *grant)] if grant else []
            if db.forced_role is not None:
                self.rows = db.forced_role
        else:
            assert sql.endswith("ORDER BY a.uid ASC LIMIT %s FOR SHARE OF a, p")
            assert "p.uid = a.uid AND CAST(p.uid AS BINARY) = CAST(a.uid AS BINARY)" in sql
            assert "LIKE" not in sql and "REGEXP" not in sql and params[-1] == SCAN_CHUNK
            anchor = params[0] if len(params) == 3 else None
            if anchor is not None: assert params[0] == params[1]
            for uid in sorted(state["accounts"], key=lambda value: value.encode("utf-8")):
                if anchor is not None and uid.encode() <= anchor.encode(): continue
                account = state["accounts"][uid]; user = state["adminUsers"].get(uid, {})
                name = user.get("fullName")
                if type(name) is str and (len(name) > 1000 or len(name.encode()) > 4000): name = None
                self.rows.append((uid, user.get("email"), name, user.get("age"), account[1], account[0]))
            self.rows = self.rows[:SCAN_CHUNK]
            if db.forced_rows is not None: self.rows = db.forced_rows
            db.scan_sizes.append(len(self.rows))
            if db.after_scan:
                db.after_scan(self.c)
        self.rowcount = len(self.rows)
        return self.rowcount


class AdminUsersTests(unittest.TestCase):
    def users(self, db, service, **options):
        return service.users(db.identity, access_token=db.access, **options)

    def test_real_store_readonly_admin_dto_nulls_missing_profiles_and_redaction(self):
        db = AdminDatabase(); db.add("blocked", email="blocked@example.invalid", full_name="", age=None, disabled=1, lifecycle="blocked")
        db.add("deleted", lifecycle="deleted"); db.add("oversized", full_name="я" * 1001)
        store, service = db.services(); before = copy.deepcopy(db.state)
        result = self.users(db, service)
        self.assertEqual((result["kind"], result["ordering"]), ("canonical-admin-users", ADMIN_ORDER))
        self.assertIsNone(result["nextCursor"])
        self.assertEqual([row["uid"] for row in result["items"]], ["actor", "blocked", "deleted", "oversized", "peer"])
        self.assertTrue(all(set(row) == ADMIN_KEYS for row in result["items"]))
        self.assertIsNone(result["items"][0]["fullName"]); self.assertIsNone(result["items"][0]["age"])
        self.assertEqual(result["items"][1]["fullName"], ""); self.assertTrue(result["items"][1]["disabled"])
        self.assertIsNone(result["items"][3]["fullName"])
        self.assertEqual(result["items"][-1]["age"], 0)
        self.assertEqual(db.state, before); self.assertTrue(all(c.readonly for c in db.connections))
        self.assertEqual(sum(c.commits for c in db.connections), 0)
        self.assertEqual(sum("FROM clrs_staging.role_grants" in sql for sql, _ in db.calls), 2)
        for sql, _ in db.calls:
            if sql.startswith("SELECT a.uid, a.email_normalized"):
                for private in ("legacy", "password", "hash", "session", "balance", "grant", "claim"):
                    self.assertNotIn(private, sql.lower())
        store.close()

    def test_only_current_exact_admin_verified_source_and_unrevoked_grant(self):
        for change in (lambda db: db.state["roles"].clear(),
                       lambda db: db.state["roles"].__setitem__(("actor", "moderator"), db.state["roles"].pop(("actor", "admin"))),
                       lambda db: db.state["roles"][("actor", "admin")].__setitem__(1, STAMP),
                       lambda db: db.state["roles"][("actor", "admin")].__setitem__(0, "email_allowlist"),
                       lambda db: db.state["roles"].__setitem__(("Actor", "admin"), db.state["roles"].pop(("actor", "admin")))):
            db = AdminDatabase(); change(db); _, service = db.services()
            with self.assertRaises(RuntimeRejected): self.users(db, service)
            self.assertEqual(db.scan_sizes, [])
        for source in ("firebase_claim", "approved_uid", "admin_grant"):
            db = AdminDatabase(); db.state["roles"][("actor", "admin")][0] = source
            _, service = db.services(); self.assertTrue(self.users(db, service)["items"])

    def test_disabled_version_and_foreign_identity_fail_native_proof(self):
        db = AdminDatabase(); _, service = db.services()
        with self.assertRaises(RuntimeRejected):
            service.users(replace(db.identity, uid="peer"), access_token=db.access)
        db.state["accounts"]["actor"][0] = 1
        with self.assertRaises(RuntimeRejected): self.users(db, service)
        db.state["accounts"]["actor"][0] = 0; db.state["accounts"]["actor"][2] += 1
        with self.assertRaises(RuntimeRejected): self.users(db, service)
        self.assertEqual(db.scan_sizes, [])

    def test_role_and_session_post_checks_do_not_release_a_constructed_page(self):
        for change in (lambda c: c.state["roles"][("actor", "admin")].__setitem__(1, STAMP),
                       lambda c: c.state["roles"][("actor", "admin")].__setitem__(0, "firebase_claim"),
                       lambda c: c.state["accounts"]["actor"].__setitem__(2, 8),
                       lambda c: c.state["sessions"][c.db.identity.session_id].__setitem__("revoked_at", STAMP)):
            db = AdminDatabase(); db.after_scan = change; _, service = db.services()
            with self.assertRaises(RuntimeRejected): self.users(db, service)
            self.assertEqual(sum(c.commits for c in db.connections), 0)

    def test_literal_prefix_normalization_and_no_regex_or_contains(self):
        db = AdminDatabase(); db.add("u1", full_name="Алексей", email="alex@example.invalid")
        db.add("u2", full_name="Не Алексей", email="zz-alex@example.invalid")
        db.add("u3", full_name="%_literal")
        _, service = db.services()
        result = self.users(db, service, query="  АЛЕК  ")
        self.assertEqual([row["uid"] for row in result["items"]], ["u1"])
        self.assertEqual([row["uid"] for row in self.users(db, service, query="alex@")["items"]], ["u1"])
        self.assertEqual([row["uid"] for row in self.users(db, service, query="%_")["items"]], ["u3"])
        self.assertEqual(normalize_admin_query(""), ""); self.assertEqual(normalize_admin_query("   "), "")
        for value in ("a", 1, True, "x" * 101, "x\n", "x\u007f", "x\ud800", "İ" * 100):
            with self.assertRaises(RuntimeInvalidRequest): normalize_admin_query(value)
        for limit in (0, 31, True):
            with self.assertRaises(RuntimeInvalidRequest): self.users(db, service, limit=limit)

    def test_sparse_scan_is_128_only_and_continuation_does_not_claim_complete(self):
        db = AdminDatabase(); db.state["adminUsers"] = {}
        for index in range(140): db.add(f"u{index:03}", full_name="Подходящий" if index == 139 else "Другой")
        _, service = db.services(); page = self.users(db, service, query="под")
        self.assertEqual(page["items"], []); self.assertIsNotNone(page["nextCursor"])
        self.assertEqual(db.scan_sizes, [SCAN_CHUNK] * 4)
        next_page = self.users(db, service, query="ПОД", cursor=page["nextCursor"])
        self.assertEqual([row["uid"] for row in next_page["items"]], ["u139"])
        self.assertIsNone(next_page["nextCursor"])

    def test_page_limit_and_byte_budget_never_skip_nonfitting_match(self):
        db = AdminDatabase()
        for index in range(35): db.add(f"u{index:03}", full_name="😀" * 1000)
        _, service = db.services(); cursor = None; seen = []; pages = []
        while True:
            page = self.users(db, service, cursor=cursor); pages.append(page)
            self.assertLessEqual(len(canonical_json(page)), 65_536)
            self.assertLessEqual(len(page["items"]), 30)
            seen.extend(row["uid"] for row in page["items"])
            cursor = page["nextCursor"]
            if cursor is None: break
            self.assertLess(len(pages), 10)
        self.assertEqual(seen, sorted(db.state["accounts"], key=lambda uid: uid.encode()))
        self.assertEqual(len(seen), len(set(seen))); self.assertGreater(len(pages), 1)
        db = AdminDatabase(); _, service = db.services()
        page = self.users(db, service, limit=1)
        self.assertEqual([row["uid"] for row in page["items"]], ["actor"])
        next_page = self.users(db, service, limit=1, cursor=page["nextCursor"])
        self.assertEqual([row["uid"] for row in next_page["items"]], ["peer"])
        self.assertIsNone(next_page["nextCursor"])

    def test_cursor_actor_query_limit_expiry_tampering_and_revoke_bindings(self):
        db = AdminDatabase(); peer, peer_access = db.peer_identity()
        db.state["roles"][("peer", "admin")] = ["approved_uid", None]
        now = [NOW]; _, service = db.services(clock=lambda: now[0])
        cursor = self.users(db, service, limit=1)["nextCursor"]
        self.assertNotIn("actor", cursor); self.assertNotIn("example.invalid", cursor)
        for options in ({"limit": 2}, {"limit": 1, "query": "pe"}):
            with self.assertRaises(RuntimeInvalidRequest): self.users(db, service, cursor=cursor, **options)
        with self.assertRaises(RuntimeInvalidRequest):
            service.users(peer, access_token=peer_access, limit=1, cursor=cursor)
        with self.assertRaises(RuntimeInvalidRequest): self.users(db, service, limit=1, cursor="bad-token")
        now[0] += 300
        with self.assertRaises(RuntimeInvalidRequest): self.users(db, service, limit=1, cursor=cursor)
        now[0] = NOW; db.state["roles"][("actor", "admin")][1] = STAMP
        with self.assertRaises(RuntimeRejected): self.users(db, service, limit=1, cursor=cursor)

    def test_normalized_query_scope_and_cursor_domain_are_exact(self):
        db = AdminDatabase(); db.add("u1", full_name="ALPHA"); db.add("u2", full_name="alpha next")
        _, service = db.services(); page = self.users(db, service, query=" AL ", limit=1)
        next_page = self.users(db, service, query="al", limit=1, cursor=page["nextCursor"])
        self.assertEqual([row["uid"] for row in next_page["items"]], ["u2"])
        from runtime_people import RuntimePeopleService
        other = RuntimePeopleService(service._store, KEY, clock=lambda: NOW)
        foreign = other._next("actor", 1, "x" * 64, (None, "u1"))
        with self.assertRaises(RuntimeInvalidRequest): self.users(db, service, query="al", limit=1, cursor=foreign)

    def test_row_shape_bounds_ordering_and_role_shape_refuse_whole_page(self):
        bad_rows = [[("peer", None, None, None, "active", 0, "secret")],
            [("peer", None, None, True, "active", 0)], [("peer", None, None, 131, "active", 0)],
            [("peer", None, None, None, "unknown", 0)], [("peer", None, None, None, "active", False)],
            [("peer", "Wrong@example.invalid", None, None, "active", 0)],
            [("peer", None, "x\u0000", None, "active", 0)],
            [("peer", None, None, None, "active", 0)] * 2,
            [("z", None, None, None, "active", 0), ("a", None, None, None, "active", 0)],
            [("peer", None, None, None, "active", 0)] * 33]
        for rows in bad_rows:
            db = AdminDatabase(); db.forced_rows = rows; _, service = db.services()
            with self.assertRaises(RuntimeUnavailable): self.users(db, service)
        for rows in ([()], [("actor", "admin", None, None)],
                     [("actor", "admin", "approved_uid", None)] * 2,
                     [("peer", "admin", "approved_uid", None)]):
            db = AdminDatabase(); db.forced_role = rows; _, service = db.services()
            with self.assertRaises(RuntimeRejected): self.users(db, service)

    def test_missing_strict_role_select_and_extra_grant_fail_closed(self):
        db = AdminDatabase(provider=False); _, service = db.services()
        with self.assertRaises(RuntimeUnavailable): self.users(db, service)
        self.assertEqual(db.scan_sizes, [])
        db.grant_rows = [*grants(), ("GRANT SELECT ON `clrs_staging`.`role_grants` TO 'fixture'@'%'",)]
        with self.assertRaises(RuntimeUnavailable): self.users(db, service)
        self.assertEqual(db.scan_sizes, [])

    def test_constructor_and_existing_gate_default_off_without_routes(self):
        db = AdminDatabase(); store, _ = db.services()
        self.assertIsNone(RuntimeAdminUsersService.from_env(store, {}))
        configured = {**db.env, "CLRS_LEGACY_READ_CURSOR_KEY_B64": base64.b64encode(KEY).decode()}
        self.assertIsInstance(RuntimeAdminUsersService.from_env(store, configured), RuntimeAdminUsersService)
        for key in (b"short", "string", None):
            with self.assertRaises(RuntimeUnavailable): RuntimeAdminUsersService(store, key)
        with self.assertRaises(RuntimeUnavailable):
            RuntimeAdminUsersService.from_env(store, {**configured, "CLRS_LEGACY_READ_CURSOR_KEY_B64": "bad"})
        sql, params = admin_users_query("synthetic")
        self.assertEqual(params, ("synthetic", "synthetic", 32)); self.assertNotIn("OFFSET", sql)
        self.assertEqual(MAX_SCAN_ROWS, 128)


if __name__ == "__main__":
    unittest.main()
