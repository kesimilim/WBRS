"""Synthetic no-TCP people reads through the real current-token read store."""
import base64
import copy
from dataclasses import replace
import json
import ssl
import unittest
from urllib.parse import urlencode

from runtime_people import (RuntimePeopleService, PEOPLE_ORDER, ROW_FIELDS,
                            MAX_SCAN_ROWS, SCAN_CHUNK, COMPATIBLE_GROUPS,
                            validate_people_filters, people_query, person_query)
from runtime_read_http import RuntimeReadHttp
from runtime_http import RuntimeMutationHttp
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_reads import RuntimeReadRejected
from test_runtime_mutations import (FakeDatabase, FakeConnection, FakeCursor,
                                   ENV, STAMP, NOW, store_for)


CURSOR_KEY = bytes(range(32))
READ_ENV = {**ENV, "CLRS_LEGACY_READ_CURSOR_KEY_B64": base64.b64encode(CURSOR_KEY).decode()}
SUMMARY_KEYS = {"uid", "fullName", "age", "pol", "country", "countryCode", "region", "city",
                "primaryGroup", "secondaryGroup", "lastOnlineAt", "avatar", "mediaReady"}
PUBLIC_KEYS = SUMMARY_KEYS | {"rost", "about", "hobbi", "deti", "relationStatus"}


def source(profile_uid, **changes):
    return {"fields": {"uid": {"stringValue": profile_uid}, "status": {"stringValue": "active"},
            "email": {"stringValue": "private@example.invalid"},
            "balance": {"integerValue": "999"}, **changes},
            "createTime": "2020-01-01T00:00:00Z", "updateTime": STAMP}


def profile(uid, **changes):
    return {"uid": uid, "profile_details_saved": 0, "registration_complete": 0,
        "invisible_until": None, "lastOnlineAt": None, "legacy_raw": source(uid),
        "age": 35, "rost": 180, "deti": 0, "fullName": "  Имя  ", "about": "Коротко",
        "hobbi": "Хобби\n", "pol": "м", "relationStatus": None, "country": "Россия",
        "countryCode": None, "region": "Москва", "city": None,
        "primaryGroup": "синяя", "secondaryGroup": None, **changes}


class PeopleDatabase(FakeDatabase):
    def __init__(self):
        super().__init__()
        self.state["profiles"] = {"actor": profile("actor"), "peer": profile("peer")}
        self.after_people_read = None
        self.forced_rows = None

    def connect(self, **config):
        assert config["ssl"].verify_mode == ssl.CERT_REQUIRED and config["ssl"].check_hostname
        if self.before_connect:
            self.before_connect()
        connection = PeopleConnection(self); self.connections.append(connection)
        return connection

    def add(self, uid, **changes):
        self.state["profiles"][uid] = profile(uid, **changes)
        self.state["accounts"][uid] = [0, "active", 0, 1]


class PeopleConnection(FakeConnection):
    def cursor(self):
        return PeopleCursor(self)


class PeopleCursor(FakeCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); state = self.c.state
        if not sql.startswith("SELECT p.uid, a.disabled"):
            return super().execute(statement, params)
        self.c.db.calls.append((sql, params))
        assert self.c.readonly and self.c.held and sql.endswith("FOR SHARE OF p, a")
        assert "a.uid = p.uid AND CAST(a.uid AS BINARY) = CAST(p.uid AS BINARY)" in sql
        assert "CASE WHEN" in sql and "131072" in sql
        is_list = "p.age BETWEEN" in sql
        index = 0; country = region = gender = groups = anchor = None
        if is_list:
            actor, minimum, maximum = params[:3]; index = 3
            for column in ("country", "region", "gender"):
                if f"CAST(p.{column} AS BINARY) = CAST(%s AS BINARY)" in sql:
                    value = params[index]; index += 1
                    if column == "country": country = value
                    elif column == "region": region = value
                    else: gender = value
            if "CAST(p.primary_group AS BINARY) IN" in sql:
                count = sql.split("CAST(p.primary_group AS BINARY) IN (")[1].split(") AND")[0].split(") ORDER")[0].count("%s")
                groups = params[index:index + count]; index += count
            if "p.last_online_at < CAST" in sql:
                anchor = (params[index].replace(" ", "T") + "Z", params[index + 2]); index += 3
            elif "p.last_online_at IS NULL AND CAST(p.uid" in sql:
                anchor = (None, params[index]); index += 1
            assert index == len(params) - 1 and params[-1] == SCAN_CHUNK
        else:
            assert len(params) == 2 and params[0] == params[1]
        rows = []
        for uid, person in state["profiles"].items():
            account = state["accounts"].get(uid)
            if not account or account[:2] != [0, "active"]:
                continue
            if is_list:
                if uid == actor or type(person["age"]) is not int or not minimum <= person["age"] <= maximum:
                    continue
                if country is not None and person["country"] != country: continue
                if region is not None and person["region"] != region: continue
                if gender is not None and person["pol"] != gender: continue
                if groups is not None and person["primaryGroup"] not in groups: continue
                if anchor is not None:
                    stamp = person["lastOnlineAt"]
                    if anchor[0] is None:
                        if stamp is not None or uid.encode() <= anchor[1].encode(): continue
                    elif stamp is not None and not (stamp < anchor[0] or (stamp == anchor[0] and uid.encode() > anchor[1].encode())):
                        continue
            elif uid != params[0]:
                continue
            raw = person["legacy_raw"]
            valid = int(len(json.dumps(raw, ensure_ascii=False).encode()) <= 131072)
            data = {**person, "disabled": account[0], "lifecycle": account[1], "valid": valid}
            for key in ("fullName", "about", "hobbi", "pol", "relationStatus", "country", "countryCode",
                        "region", "city", "primaryGroup", "secondaryGroup"):
                value = data[key]
                maximum = 1000 if key == "fullName" else (4096 if key in {"about", "hobbi"} else 191)
                if type(value) is str and (len(value) > maximum or len(value.encode(errors="surrogatepass")) > maximum * 4):
                    data[key] = None; data["valid"] = 0
            rows.append(tuple(data[field] for field in ROW_FIELDS))
        rows.sort(key=lambda row: row[0].encode())
        rows.sort(key=lambda row: row[6] or "", reverse=True)
        self.rows = rows[:params[-1]] if is_list else rows
        if self.c.db.forced_rows is not None:
            self.rows = self.c.db.forced_rows
        self.rowcount = len(self.rows)
        if self.c.db.after_people_read:
            self.c.db.after_people_read(self.c)
        return self.rowcount


class Native:
    def __init__(self, identity):
        self.identity = identity; self.calls = []

    def authorize(self, token, *, peer):
        self.calls.append((token, peer)); return self.identity


class ForbiddenInput:
    def read(self, _):
        raise AssertionError("People GET must never read a body")


class RuntimePeopleTests(unittest.TestCase):
    def setUp(self):
        self.db = PeopleDatabase(); self.store = store_for(self.db)
        self.reads = RuntimePeopleService(self.store, CURSOR_KEY, clock=lambda: NOW)
        self.addCleanup(self.store.close)

    def people(self, **changes):
        return self.reads.people(self.db.identity, access_token=self.db.access, **changes)

    def person(self, uid="peer", **changes):
        return self.reads.public_person(self.db.identity, uid, access_token=self.db.access, **changes)

    def test_public_allowlist_nullable_canonical_fields_no_raw_fallback_no_writes(self):
        before = copy.deepcopy(self.db.state)
        page = self.people(); person = self.person()["profile"]
        self.assertEqual(set(page), {"kind", "ordering", "items", "nextCursor", "mediaReady"})
        self.assertEqual(set(page["items"][0]), SUMMARY_KEYS)
        self.assertEqual(set(person), PUBLIC_KEYS)
        self.assertEqual(person["fullName"], "  Имя  ")
        self.assertEqual(person["about"], "Коротко")
        self.assertIs(person["deti"], False)
        for key in ("countryCode", "city", "secondaryGroup", "lastOnlineAt", "avatar"):
            self.assertIsNone(person[key])
        self.assertIs(person["mediaReady"], False)
        self.assertEqual(self.db.state, before)
        encoded = json.dumps(page) + json.dumps(person)
        for secret in ("private", "email", "balance", "legacy", "role", "token", "profile_details_saved"):
            self.assertNotIn(secret, encoded)
        self.assertTrue(all(c.closed and c.readonly and c.commits == 0 for c in self.db.connections))
        self.assertTrue(all(not sql.startswith(("INSERT", "UPDATE", "DELETE")) for sql, _ in self.db.calls))

    def test_account_source_status_deleted_and_both_visibility_spellings_gate_both_reads(self):
        original = copy.deepcopy(self.db.state)
        scenarios = [
            ("disabled", None), ("blocked-account", None),
            ("source", {"status": {"stringValue": "blocked"}}),
            ("source", {"registrationStatus": {"stringValue": "deleted"}}),
            ("source", {"deleted": {"booleanValue": True}}),
            ("source", {"isUnVisible": {"booleanValue": True}}),
            ("source", {"isUnvisible": {"booleanValue": True}}),
            ("source", {"isUnvisible": {"booleanValue": True}, "unvisibleEnd": {"timestampValue": "2099-01-01T00:00:00Z"}}),
            ("source", {"isUnVisible": {"booleanValue": "false"}}),
            ("source", {"uid": {"stringValue": "actor"}}),
        ]
        for kind, fields in scenarios:
            with self.subTest(kind=kind, fields=fields):
                self.db.state = copy.deepcopy(original)
                if kind == "disabled": self.db.state["accounts"]["peer"][0] = 1
                elif kind == "blocked-account": self.db.state["accounts"]["peer"][1] = "blocked"
                else: self.db.state["profiles"]["peer"]["legacy_raw"] = source("peer", **fields)
                self.assertEqual(self.people()["items"], [])
                with self.assertRaises(RuntimeReadRejected): self.person()
        self.db.state = copy.deepcopy(original)
        del self.db.state["profiles"]["peer"]["legacy_raw"]["fields"]["status"]
        self.assertEqual(self.people()["items"], [])

    def test_expired_legacy_period_native_completed_and_incomplete_empty_raw(self):
        self.db.state["profiles"]["peer"]["legacy_raw"] = source("peer",
            isUnVisible={"booleanValue": True}, unvisibleEnd={"timestampValue": "2020-01-01T00:00:00Z"})
        self.assertEqual(len(self.people()["items"]), 1)
        for saved, complete in ((0, 0), (1, 0), (0, 1), (1, 1)):
            self.db.state["profiles"]["peer"].update(legacy_raw={}, profile_details_saved=saved,
                                                       registration_complete=complete)
            self.assertEqual(len(self.people()["items"]), int(saved == complete == 1))
        self.db.state["profiles"]["peer"]["invisible_until"] = "2099-01-01T00:00:00.000000Z"
        self.assertEqual(self.people()["items"], [])

    def test_actor_token_identity_expiry_revocation_and_byte_exact_target(self):
        with self.assertRaises(RuntimeRejected):
            self.reads.people(replace(self.db.identity, uid="other"), access_token=self.db.access)
        for uid in ("Peer", "actor", "missing"):
            with self.assertRaises(RuntimeReadRejected): self.person(uid)
        self.db.state["accounts"]["actor"][0] = 1
        with self.assertRaises(RuntimeRejected): self.people()
        self.db.state["accounts"]["actor"][0] = 0
        self.db.after_people_read = lambda c: c.state["sessions"][self.db.identity.session_id].update(revoked_at=NOW)
        with self.assertRaises(RuntimeRejected): self.people()
        self.assertTrue(all(c.commits == 0 for c in self.db.connections))

    def test_exact_geo_gender_and_all_existing_compatibility_cases(self):
        filters = validate_people_filters(country_code="RU", region="Москва", gender="м", compatible_group="красная")
        sql, params = people_query("actor", filters)
        self.assertIn("CAST(p.country AS BINARY)", sql)
        self.assertIn("Россия", params)
        self.assertEqual(self.people(country_code="RU", region="Москва", gender="м", compatible_group="красная")["items"][0]["uid"], "peer")
        self.assertEqual(self.people(gender="ж")["items"], [])
        self.assertEqual(self.people(min_age=36)["items"], [])
        self.assertEqual(len(COMPATIBLE_GROUPS), 16)
        for group, expected in COMPATIBLE_GROUPS.items():
            with self.subTest(group=group):
                plan, bindings = people_query("actor", validate_people_filters(compatible_group=group))
                self.assertEqual(bindings[3:-1], expected)
                self.assertEqual(plan.count("CAST(%s AS BINARY)"), len(expected) + 1)
        for options in ({"gender": "мужской"}, {"country_code": "ru"}, {"region": "Москва"},
                        {"country_code": "RU", "region": "unknown"}, {"compatible_group": "red"},
                        {"min_age": True}, {"min_age": 101}, {"min_age": 40, "max_age": 20}):
            with self.assertRaises(RuntimeInvalidRequest): self.people(**options)

    def test_microsecond_equal_null_keysets_no_duplicate_and_cursor_binding(self):
        self.db.state["profiles"]["peer"]["lastOnlineAt"] = "2027-01-15T08:00:00.000001Z"
        self.db.add("A", lastOnlineAt="2027-01-15T08:00:00.000002Z")
        self.db.add("z", lastOnlineAt="2027-01-15T08:00:00.000002Z")
        self.db.add("null-last")
        seen = []; cursor = None
        while True:
            page = self.people(limit=2, cursor=cursor)
            seen.extend(item["uid"] for item in page["items"])
            cursor = page["nextCursor"]
            if cursor is None: break
        self.assertEqual(seen, ["A", "z", "peer", "null-last"])
        first = self.people(limit=2)
        tampered = first["nextCursor"][:-1] + ("A" if first["nextCursor"][-1] != "A" else "B")
        with self.assertRaises(RuntimeInvalidRequest): self.people(limit=2, cursor=tampered)
        for options in ({"limit": 1}, {"limit": 2, "min_age": 19}, {"limit": 2, "gender": "м"}):
            with self.assertRaises(RuntimeInvalidRequest): self.people(cursor=first["nextCursor"], **options)
        opened = self.reads._codec.open("cursor", first["nextCursor"])
        for changes in ({"uid": "other"}, {"exp": NOW}, {"purpose": "chat"}, {"after": [True, "A"]}):
            forged = self.reads._codec.seal("cursor", {**opened, **changes})
            with self.assertRaises(RuntimeInvalidRequest): self.people(limit=2, cursor=forged)

    def test_sparse_hidden_scan_cap_continues_without_plaintext_hidden_uid(self):
        del self.db.state["profiles"]["peer"]
        for index in range(MAX_SCAN_ROWS + 2):
            uid = f"hidden-{index:03d}"
            self.db.add(uid, legacy_raw=source(uid, isUnvisible={"booleanValue": True}))
        self.db.add("visible-later")
        first = self.people()
        self.assertEqual(first["items"], [])
        self.assertIsNotNone(first["nextCursor"])
        self.assertNotIn("hidden", json.dumps(first))
        queries = [sql for sql, _ in self.db.calls if sql.startswith("SELECT p.uid")]
        self.assertEqual(len(queries), MAX_SCAN_ROWS // SCAN_CHUNK)
        second = self.people(cursor=first["nextCursor"])
        self.assertEqual([item["uid"] for item in second["items"]], ["visible-later"])
        self.assertIsNone(second["nextCursor"])

    def test_byte_budget_preserves_whole_names_and_resume_anchor(self):
        del self.db.state["profiles"]["peer"]
        for index in range(25): self.db.add(f"person-{index:02d}", fullName="😀" * 1000)
        seen = []; cursor = None
        while True:
            page = self.people(cursor=cursor)
            self.assertLessEqual(len(canonical_json(page)), 65536)
            self.assertTrue(all(item["fullName"] == "😀" * 1000 for item in page["items"]))
            seen.extend(item["uid"] for item in page["items"])
            cursor = page["nextCursor"]
            if cursor is None: break
        self.assertEqual(seen, [f"person-{index:02d}" for index in range(25)])

    def test_backfill_absence_malformed_public_fields_and_source_bounds_no_fallback(self):
        self.db.state["profiles"]["peer"].update(age=None, about=None, hobbi=None, deti=None, pol=None)
        self.assertEqual(self.people()["items"], [])
        full = self.person()["profile"]
        for field in ("age", "about", "hobbi", "deti", "pol"):
            self.assertIsNone(full[field])
        for changes in ({"fullName": "x" * 1001}, {"fullName": "\x00"},
                        {"legacy_raw": source("peer", extra={"stringValue": "x" * 131073})},
                        {"legacy_raw": "{\"fields\":{},\"fields\":{}}"}):
            self.db.state["profiles"]["peer"] = profile("peer", **changes)
            self.assertEqual(self.people()["items"], [])
            with self.assertRaises(RuntimeReadRejected): self.person()

    def test_http_default_off_queries_get_only_and_mount_share_current_store(self):
        native = Native(self.db.identity)
        http = RuntimeReadHttp(READ_ENV, self.store, people_factory=lambda *_: self.reads)
        def request(path="/v1/runtime/people", query="", **extra):
            env = {"PATH_INFO": path, "REQUEST_METHOD": "GET", "QUERY_STRING": query,
                "CONTENT_LENGTH": "0", "wsgi.input": ForbiddenInput(),
                "HTTP_AUTHORIZATION": "Bearer " + self.db.access, "REMOTE_ADDR": "socket-peer", **extra}
            return http.dispatch(env, native_service=native, native_configured=True)
        self.assertEqual(request(query=urlencode({"pol": "м", "countryCode": "RU", "region": "Москва"})).status, "200 OK")
        self.assertEqual(request("/v1/runtime/people/peer").status, "200 OK")
        self.assertEqual(request("/v1/runtime/people/Peer").status, "404 Not Found")
        self.assertEqual(request(REQUEST_METHOD="POST").status, "405 Method Not Allowed")
        for query in ("limit=0", "limit=31", "limit=01", "uid=peer", "minAge=17", "minAge=40&maxAge=20",
                      "pol=male", "region=abc", "limit=1&limit=2", "cursor=", "cursor=%FF", "origin=native"):
            self.assertEqual(request(query=query).status, "400 Bad Request")
        self.assertEqual(request("/v1/runtime/people/peer", "limit=1").status, "400 Bad Request")
        self.assertEqual(request(CONTENT_LENGTH="1").status, "400 Bad Request")
        self.assertEqual(request(HTTP_AUTHORIZATION="Bearer firebase-token").status, "401 Unauthorized")
        for env in ({}, {**READ_ENV, "CLRS_RUNTIME_WRITES_ENABLED": "0"},
                    {**READ_ENV, "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "immutable-reviewed-snapshot"}):
            off = RuntimeReadHttp(env, None, people_factory=lambda *_: self.fail("created default-off people service"))
            self.assertEqual(off.dispatch({"PATH_INFO": "/v1/runtime/people"}).status, "404 Not Found")
        mounted = RuntimeMutationHttp(READ_ENV, service_factory=lambda _: (self.store, None, None))
        reply = mounted.dispatch({"PATH_INFO": "/v1/runtime/people/peer", "REQUEST_METHOD": "GET",
            "CONTENT_LENGTH": "0", "QUERY_STRING": "", "wsgi.input": ForbiddenInput(),
            "HTTP_AUTHORIZATION": "Bearer " + self.db.access}, native_service=native, native_configured=True)
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(reply.payload["profile"]["uid"], "peer")


if __name__ == "__main__":
    unittest.main()
