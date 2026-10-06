"""Synthetic no-TCP meeting projection through the real current read store."""
import base64
import copy
from dataclasses import replace
import json
import ssl
import unittest

from runtime_meetings import (RuntimeMeetingsService, TRUSTED_POLICY, MEETING_ORDER,
    PARTICIPANT_ORDER, MEETING_FIELDS, MEMBER_FIELDS, MAX_SCAN_ROWS, SCAN_CHUNK,
    meetings_query, participants_query, profiles_query, actor_members_query)
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_reads import RuntimeReadRejected
from runtime_meeting_create import MEETING_ORIGIN, MEMBER_ORIGIN
from runtime_people import ROW_FIELDS, _TEXT_FIELDS
from test_runtime_people import profile, source, PeopleDatabase, PeopleCursor
from test_runtime_mutations import FakeConnection, ENV, STAMP, NOW, store_for


KEY = bytes(range(32))
READ_ENV = {**ENV, "CLRS_LEGACY_READ_CURSOR_KEY_B64": base64.b64encode(KEY).decode()}
MEETING_KEYS = set(MEETING_FIELDS[:12]) | {"localDatetime", "media", "mediaReady"}
MEMBER_KEYS = {"uid", "fullName", "primaryGroup", "joinedAt", "membershipRevision", "avatar", "mediaReady"}


def meeting(meeting_id, **changes):
    return {"meetingId": meeting_id, "organizerUid": "peer", "invitedUid": None,
        "kind": "group", "title": "  Встреча  ", "description": "Описание\n",
        "countryCode": "RU", "region": "Москва", "startsAt": None,
        "createdAt": None, "updatedAt": STAMP, "revision": 0, "deletedAt": None,
        "localDatetime": "03.10.2026 19:15",
        "legacy_raw": {"origin": MEETING_ORIGIN, "localDatetime": "03.10.2026 19:15"}, **changes}


def member(meeting_id, uid, **changes):
    return {"meetingId": meeting_id, "uid": uid, "joinedAt": STAMP, "leftAt": None,
            "kickedAt": None, "membershipRevision": 0, "legacy_raw": {"origin": MEMBER_ORIGIN}, **changes}


def _after_meeting(row, anchor):
    if anchor is None:
        return True
    if anchor[0] is None:
        return row["startsAt"] is not None or row["meetingId"].encode() > anchor[1].encode()
    return row["startsAt"] is not None and (row["startsAt"] > anchor[0]
        or (row["startsAt"] == anchor[0] and row["meetingId"].encode() > anchor[1].encode()))


class MeetingsDatabase(PeopleDatabase):
    def __init__(self):
        super().__init__()
        self.state["meetings"] = {}; self.state["meeting_members"] = {}
        self.forced = {}; self.after_read = None

    def connect(self, **config):
        assert config["ssl"].verify_mode == ssl.CERT_REQUIRED and config["ssl"].check_hostname
        connection = MeetingsConnection(self); self.connections.append(connection)
        return connection

    def add_meeting(self, meeting_id, **changes):
        self.state["meetings"][meeting_id] = meeting(meeting_id, **changes)

    def join(self, meeting_id, uid, **changes):
        self.state["meeting_members"][(meeting_id, uid)] = member(meeting_id, uid, **changes)

    def actor_b(self):
        self.add("actor-b")
        session, access = self.tokens.mint("actor-b", "device-b", 0, NOW)
        self.state["sessions"][session["session_id"]] = session
        return replace(self.identity, uid="actor-b", session_id=session["session_id"]), access["accessToken"]


class MeetingsConnection(FakeConnection):
    def cursor(self):
        return MeetingsCursor(self)


class MeetingsCursor(PeopleCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); state = self.c.state
        category = None
        if "FROM clrs_staging.meetings AS m" in sql:
            category = "meetings"
            if "FORCE INDEX (meetings_browse_idx)" in sql:
                scope = params[0]; anchor = None
                if "m.starts_at IS NULL AND m.meeting_id >" in sql:
                    anchor = (None, params[1])
                elif "m.starts_at > CAST" in sql:
                    anchor = (params[1].replace(" ", "T") + "Z", params[3])
                rows = [row for row in state["meetings"].values() if row["kind"] == scope
                        and row["deletedAt"] is None and _after_meeting(row, anchor)]
                rows.sort(key=lambda row: (row["startsAt"] is not None, row["startsAt"] or "", row["meetingId"].encode()))
                assert params[-1] == SCAN_CHUNK
                rows = rows[:SCAN_CHUNK]
            else:
                assert params[0] == params[1]
                row = state["meetings"].get(params[0])
                rows = [] if row is None or row["deletedAt"] is not None else [row]
            self.rows = []
            for row in rows:
                raw = row["legacy_raw"]; local = raw.get("localDatetime") if type(raw) is dict else None
                trusted = (type(raw) is dict and set(raw) == {"origin", "localDatetime"}
                    and raw["origin"] == MEETING_ORIGIN and type(local) is str
                    and len(local.encode()) == 16 and row["startsAt"] is None)
                data = {**row, "trusted": int(trusted), "valid": 1, "localDatetime": local if trusted else None}
                for field, maximum in (("title", 1000), ("description", 4096), ("countryCode", 191), ("region", 191)):
                    value = data[field]
                    if type(value) is str and (len(value) > maximum or len(value.encode(errors="surrogatepass")) > maximum * 4):
                        data[field] = None; data["valid"] = 0
                self.rows.append(tuple(data[field] for field in MEETING_FIELDS))
        elif "FROM clrs_staging.meeting_members AS mm" in sql:
            category = "members"
            if "FORCE INDEX (meeting_members_active_idx)" in sql:
                assert params[0] == params[1] and params[-1] == SCAN_CHUNK
                anchor = params[2] if "mm.uid >" in sql else None
                rows = [row for row in state["meeting_members"].values()
                        if row["meetingId"] == params[0] and row["leftAt"] is None
                        and (anchor is None or row["uid"].encode() > anchor.encode())]
                rows.sort(key=lambda row: row["uid"].encode()); rows = rows[:SCAN_CHUNK]
            else:
                count = params[-1]; meeting_ids = params[:count]; uid = params[-3]
                assert tuple(meeting_ids) == tuple(params[count:count * 2]) and params[-3] == params[-2]
                rows = [row for row in state["meeting_members"].values()
                        if row["meetingId"] in meeting_ids and row["uid"] == uid]
            self.rows = [tuple({**row, "trusted": int(row["legacy_raw"] == {"origin": MEMBER_ORIGIN})}[field]
                               for field in MEMBER_FIELDS) for row in rows]
        elif sql.startswith("SELECT p.uid, a.disabled") and "p.uid IN (" in sql:
            category = "profiles"
            count = params[-1]; uids = params[:count]
            assert tuple(uids) == tuple(params[count:count * 2]) and count <= 64
            self.rows = []
            for uid in uids:
                row = state["profiles"].get(uid); account = state["accounts"].get(uid)
                if row is None or account is None or account[:2] != [0, "active"]:
                    continue
                data = {**row, "disabled": account[0], "lifecycle": account[1],
                        "valid": int(len(json.dumps(row["legacy_raw"], ensure_ascii=False).encode(errors="surrogatepass")) <= 131072)}
                for field, (_, maximum) in _TEXT_FIELDS.items():
                    value = data[field]
                    if type(value) is str and (len(value) > maximum or len(value.encode(errors="surrogatepass")) > maximum * 4):
                        data[field] = None; data["valid"] = 0
                self.rows.append(tuple(data[field] for field in ROW_FIELDS))
        else:
            return super().execute(statement, params)
        self.c.db.calls.append((sql, params))
        assert self.c.readonly and self.c.held and "FOR SHARE" in sql
        if self.c.db.fail_contains and self.c.db.fail_contains in sql:
            raise OSError("synthetic SQL denied")
        if category in self.c.db.forced:
            self.rows = self.c.db.forced[category]
        self.rowcount = len(self.rows)
        if self.c.db.after_read:
            self.c.db.after_read(category, self.c)
        return self.rowcount


class RuntimeMeetingsTests(unittest.TestCase):
    def setUp(self):
        self.db = MeetingsDatabase(); self.store = store_for(self.db)
        self.now = NOW
        self.reads = RuntimeMeetingsService(self.store, KEY, trusted_policy=TRUSTED_POLICY, clock=lambda: self.now)
        self.addCleanup(self.store.close)

    def meetings(self, **options):
        return self.reads.meetings(self.db.identity, access_token=self.db.access, **options)

    def detail(self, meeting_id="m", **options):
        return self.reads.meeting(self.db.identity, meeting_id, access_token=self.db.access, **options)

    def participants(self, meeting_id="m", **options):
        return self.reads.participants(self.db.identity, meeting_id, access_token=self.db.access, **options)

    def test_default_factory_never_trusts_empty_raw_or_env_policy_and_empty_is_honest(self):
        env = {**READ_ENV, "CLRS_RUNTIME_MEETINGS_TRUSTED_POLICY": TRUSTED_POLICY}
        self.assertIsNone(RuntimeMeetingsService.from_env(self.store, env))
        with self.assertRaises(RuntimeUnavailable):
            RuntimeMeetingsService(self.store, KEY, trusted_policy=None)
        with self.assertRaises(RuntimeUnavailable):
            RuntimeMeetingsService.from_env(self.store, env, trusted_policy="unreviewed")
        self.assertIsNotNone(RuntimeMeetingsService.from_env(self.store, env, trusted_policy=TRUSTED_POLICY))
        self.assertIsNone(RuntimeMeetingsService.from_env(self.store, {**env, "CLRS_RUNTIME_WRITES_ENABLED": "0"}, trusted_policy=TRUSTED_POLICY))
        page = self.meetings()
        self.assertEqual(page, {"kind": "canonical-current", "ordering": MEETING_ORDER, "scope": "group", "items": [], "nextCursor": None, "mediaReady": False})
        # Retained legacy state exists, and must never become a meeting fallback.
        self.assertTrue(self.db.state["legacy"])
        self.assertFalse(any("FROM clrs_staging.legacy_" in sql for sql, _ in self.db.calls))

    def test_nullable_exact_allowlist_no_private_source_media_or_writes(self):
        self.db.add_meeting("m", title="  Название\t ", description="Описание\n",
                            startsAt=None, createdAt=None, updatedAt=None,
                            media_id="private-media", creation_request_id="private-operation")
        before = copy.deepcopy(self.db.state)
        page = self.meetings(); detail = self.detail()
        self.assertEqual(set(page), {"kind", "ordering", "scope", "items", "nextCursor", "mediaReady"})
        self.assertEqual(set(detail), {"kind", "meeting", "mediaReady"})
        item = detail["meeting"]
        self.assertEqual(set(item), MEETING_KEYS)
        self.assertEqual(item, page["items"][0]); self.assertEqual(item["title"], "  Название\t ")
        self.assertIsNone(item["media"]); self.assertIs(item["mediaReady"], False)
        for key in ("startsAt", "createdAt", "updatedAt", "invitedUid"):
            self.assertIsNone(item[key])
        self.assertEqual(item["localDatetime"], "03.10.2026 19:15")
        self.assertEqual((item["countryCode"], item["region"]), ("RU", "Москва"))
        encoded = canonical_json(detail)
        for forbidden in (b"email", b"balance", b"role", b"legacy", b"private", b"media_id", b"creation_request", b"participantCount"):
            self.assertNotIn(forbidden, encoded)
        self.assertEqual(self.db.state, before)
        self.assertTrue(all(c.closed and c.readonly and c.commits == 0 for c in self.db.connections))
        self.assertTrue(all(not sql.startswith(("INSERT", "UPDATE", "DELETE")) for sql, _ in self.db.calls))

    def test_group_visibility_self_owner_exception_and_source_privacy_fail_closed(self):
        self.db.add_meeting("m")
        original = copy.deepcopy(self.db.state)
        scenarios = ["disabled", "blocked", "hidden", "missing-status", "deleted-meeting", "raw-meeting", "oversize", "control-text"]
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                self.db.state = copy.deepcopy(original)
                if scenario == "disabled": self.db.state["accounts"]["peer"][0] = 1
                elif scenario == "blocked": self.db.state["accounts"]["peer"][1] = "blocked"
                elif scenario == "hidden": self.db.state["profiles"]["peer"]["legacy_raw"] = source("peer", isUnVisible={"booleanValue": True})
                elif scenario == "missing-status": del self.db.state["profiles"]["peer"]["legacy_raw"]["fields"]["status"]
                elif scenario == "deleted-meeting": self.db.state["meetings"]["m"]["deletedAt"] = STAMP
                elif scenario == "raw-meeting": self.db.state["meetings"]["m"]["legacy_raw"] = {"fields": {"private": True}}
                elif scenario == "oversize": self.db.state["meetings"]["m"]["description"] = "x" * 4097
                else: self.db.state["meetings"]["m"]["title"] = "secret\x00"
                self.assertEqual(self.meetings()["items"], [])
                with self.assertRaises(RuntimeReadRejected): self.detail()
                with self.assertRaises(RuntimeReadRejected): self.participants()
        self.db.state = copy.deepcopy(original)
        self.db.state["meetings"]["m"]["organizerUid"] = "actor"
        self.db.state["profiles"]["actor"]["legacy_raw"] = source("actor", isUnVisible={"booleanValue": True})
        self.assertEqual(self.detail()["meeting"]["organizerUid"], "actor")
        identity_b, token_b = self.db.actor_b()
        with self.assertRaises(RuntimeReadRejected):
            self.reads.meeting(identity_b, "m", access_token=token_b)

    def test_individual_keeps_actor_organizer_and_invitee_exact_current_audience(self):
        self.db.add("outsider")
        self.db.add_meeting("a-created", kind="individual", organizerUid="actor", invitedUid="peer")
        self.db.add_meeting("b-invited", kind="individual", organizerUid="peer", invitedUid="actor")
        self.db.add_meeting("c-private", kind="individual", organizerUid="peer", invitedUid="outsider")
        self.assertEqual([m["meetingId"] for m in self.meetings(scope="individual")["items"]], ["a-created", "b-invited"])
        with self.assertRaises(RuntimeReadRejected): self.detail("c-private")
        with self.assertRaises(RuntimeReadRejected): self.detail("A-created")
        with self.assertRaises(RuntimeReadRejected): self.participants("b-invited")
        self.db.join("b-invited", "actor")
        self.assertEqual(self.participants("b-invited")["items"][0]["uid"], "actor")
        self.db.state["meeting_members"][("b-invited", "actor")]["leftAt"] = STAMP
        self.assertEqual(self.detail("b-invited")["meeting"]["kind"], "individual")
        with self.assertRaises(RuntimeReadRejected): self.participants("b-invited")
        self.db.join("a-created", "actor", leftAt=STAMP)
        self.assertEqual(self.participants("a-created")["items"], [])
        self.db.state["profiles"]["peer"]["legacy_raw"] = source("peer", isUnvisible={"booleanValue": True})
        self.assertEqual(self.meetings(scope="individual")["items"], [])

    def test_public_group_nonmember_left_and_current_kick_authority(self):
        self.db.add_meeting("m"); self.db.join("m", "peer")
        self.assertEqual(self.participants()["items"][0]["uid"], "peer")
        self.db.join("m", "actor", leftAt=STAMP)
        self.assertEqual(len(self.meetings()["items"]), 1)
        self.assertEqual(self.participants()["items"][0]["uid"], "peer")
        self.db.state["meeting_members"][("m", "actor")]["kickedAt"] = STAMP
        self.assertEqual(self.meetings()["items"], [])
        with self.assertRaises(RuntimeReadRejected): self.detail()
        with self.assertRaises(RuntimeReadRejected): self.participants()
        self.db.state["meeting_members"][("m", "actor")].update(kickedAt=None, legacy_raw={"left": "unreviewed"})
        with self.assertRaises(RuntimeReadRejected): self.detail()

    def test_active_participants_including_self_nullable_own_fields_and_hidden_others(self):
        self.db.add_meeting("m")
        for uid in ("actor", "peer", "hidden", "left", "kicked", "raw"):
            if uid not in ("actor", "peer"): self.db.add(uid)
            self.db.join("m", uid)
        self.db.state["profiles"]["hidden"]["legacy_raw"] = source("hidden", isUnvisible={"booleanValue": True})
        self.db.state["meeting_members"][("m", "left")]["leftAt"] = STAMP
        self.db.state["meeting_members"][("m", "kicked")].update(leftAt=STAMP, kickedAt=STAMP)
        self.db.state["meeting_members"][("m", "raw")]["legacy_raw"] = {"private": "unreviewed"}
        self.db.state["profiles"]["actor"].update(fullName="  Я\n", primaryGroup="синяя",
                                                  legacy_raw=source("actor", isUnVisible={"booleanValue": True}))
        page = self.participants()
        self.assertEqual(set(page), {"kind", "meetingId", "ordering", "items", "nextCursor", "mediaReady"})
        self.assertEqual(page["ordering"], PARTICIPANT_ORDER)
        self.assertEqual([p["uid"] for p in page["items"]], ["actor", "peer"])
        self.assertEqual(page["items"][0]["fullName"], "  Я\n")
        self.assertTrue(all(set(p) == MEMBER_KEYS and p["avatar"] is None and not p["mediaReady"] for p in page["items"]))
        self.db.state["profiles"]["actor"].update(fullName="x" * 1001, primaryGroup="bad\x00")
        own = self.participants()["items"][0]
        self.assertIsNone(own["fullName"]); self.assertIsNone(own["primaryGroup"])
        del self.db.state["profiles"]["actor"]
        self.assertIsNone(self.participants()["items"][0]["fullName"])
        self.assertNotIn("count", canonical_json(page).decode())

    def test_sparse_exact_geo_window_and_individual_scan_bound_batches_under_store_limit(self):
        for index in range(MAX_SCAN_ROWS):
            self.db.add_meeting(f"g{index:03}", countryCode="RU", region="Санкт-Петербург")
        self.db.add_meeting("g128", region="Москва")
        page = self.meetings(country_code="RU", region="Москва")
        self.assertEqual(page["items"], []); self.assertIsNotNone(page["nextCursor"])
        self.assertEqual([m["meetingId"] for m in self.meetings(country_code="RU", region="Москва", cursor=page["nextCursor"])["items"]], ["g128"])
        self.assertEqual(len([sql for sql, _ in self.db.calls if "FORCE INDEX (meetings_browse_idx)" in sql]), 5)
        self.db.state["meetings"].clear(); self.db.calls.clear(); self.db.add("outsider")
        for index in range(MAX_SCAN_ROWS):
            self.db.add_meeting(f"i{index:03}", kind="individual", invitedUid="outsider")
        self.db.add_meeting("i128", kind="individual", organizerUid="actor", invitedUid="peer")
        page = self.meetings(scope="individual")
        self.assertEqual(page["items"], []); self.assertIsNotNone(page["nextCursor"])
        self.assertEqual(len(self.db.calls), 15)  # fixed store setup/auth/actor + four scans, no N+1
        self.assertEqual(self.meetings(scope="individual", cursor=page["nextCursor"])["items"][0]["meetingId"], "i128")
        self.db.state["meetings"].clear(); self.db.calls.clear()
        for index in range(MAX_SCAN_ROWS):
            uid = f"organizer{index:03}"; self.db.add(uid)
            self.db.state["profiles"][uid]["legacy_raw"] = source(uid, isUnVisible={"booleanValue": True})
            self.db.add_meeting(f"m{index:03}", organizerUid=uid)
        page = self.meetings()
        self.assertEqual(page["items"], []); self.assertIsNotNone(page["nextCursor"])
        self.assertLessEqual(len(self.db.calls), 64)
        self.assertEqual(len([sql for sql, _ in self.db.calls if "p.uid IN (" in sql]), 4)
        self.assertEqual(len([sql for sql, _ in self.db.calls if "mm.meeting_id IN (" in sql]), 4)

    def test_opaque_actor_filter_limit_purpose_expiry_binding_and_null_timestamp_order(self):
        self.db.add_meeting("null-a"); self.db.add_meeting("null-b")
        self.db.add_meeting("timed-a", startsAt=STAMP); self.db.add_meeting("timed-b", startsAt=STAMP)
        self.db.add_meeting("later", startsAt="2028-01-01T00:00:00.000000Z")
        self.db.join("null-a", "actor"); self.db.join("null-a", "peer")
        ids = []; page = self.meetings(limit=1); original_cursor = page["nextCursor"]
        ids.extend(m["meetingId"] for m in page["items"])
        original_exp = self.reads._codec.open("cursor", original_cursor)["exp"]
        self.now += 10
        while page["nextCursor"] is not None:
            page = self.meetings(limit=1, cursor=page["nextCursor"])
            ids.extend(m["meetingId"] for m in page["items"])
            if page["nextCursor"] is not None:
                self.assertEqual(self.reads._codec.open("cursor", page["nextCursor"])["exp"], original_exp)
        self.assertEqual(ids, ["null-a", "null-b"])  # UTC rows are excluded by this native marker policy
        self.assertNotIn("null-a", original_cursor); self.assertNotIn("actor", original_cursor)
        for options in ({"limit": 2}, {"limit": 1, "scope": "individual"},
                        {"limit": 1, "country_code": "RU"}, {"limit": 1, "region": "Москва", "country_code": "RU"}):
            with self.assertRaises(RuntimeInvalidRequest): self.meetings(cursor=original_cursor, **options)
        identity_b, token_b = self.db.actor_b()
        with self.assertRaises(RuntimeInvalidRequest):
            self.reads.meetings(identity_b, access_token=token_b, limit=1, cursor=original_cursor)
        with self.assertRaises(RuntimeInvalidRequest): self.participants("null-a", limit=1, cursor=original_cursor)
        participant_cursor = self.participants("null-a", limit=1)["nextCursor"]
        with self.assertRaises(RuntimeInvalidRequest): self.participants("null-b", limit=1, cursor=participant_cursor)
        for invalid in ("bad", original_cursor + "!", "x" * 4097, True):
            with self.assertRaises(RuntimeInvalidRequest): self.meetings(limit=1, cursor=invalid)
        self.now = original_exp
        with self.assertRaises(RuntimeInvalidRequest): self.meetings(limit=1, cursor=original_cursor)

    def test_participant_sparse_bound_active_index_paging_and_current_revalidation(self):
        self.db.add_meeting("m")
        for index in range(MAX_SCAN_ROWS):
            uid = f"a{index:03}"; self.db.add(uid); self.db.join("m", uid)
            self.db.state["profiles"][uid]["legacy_raw"] = source(uid, isUnVisible={"booleanValue": True})
        self.db.join("m", "peer")
        page = self.participants()
        self.assertEqual(page["items"], []); self.assertIsNotNone(page["nextCursor"])
        self.assertLessEqual(len(self.db.calls), 64)
        self.assertEqual(self.participants(cursor=page["nextCursor"])["items"][0]["uid"], "peer")
        self.db.join("m", "actor", leftAt=STAMP, kickedAt=STAMP)
        with self.assertRaises(RuntimeReadRejected): self.participants(cursor=page["nextCursor"])
        self.db.state["meeting_members"].pop(("m", "actor"))
        self.db.state["profiles"]["peer"]["legacy_raw"] = source("peer", isUnVisible={"booleanValue": True})
        with self.assertRaises(RuntimeReadRejected): self.participants(cursor=page["nextCursor"])

    def test_token_a_b_revoked_during_read_and_no_stale_authority(self):
        self.db.add_meeting("m", kind="individual", organizerUid="actor", invitedUid="peer")
        identity_b, token_b = self.db.actor_b()
        self.assertEqual(self.reads.meetings(identity_b, access_token=token_b, scope="individual")["items"], [])
        with self.assertRaises(RuntimeReadRejected): self.reads.meeting(identity_b, "m", access_token=token_b)
        with self.assertRaises(RuntimeRejected): self.reads.meeting(identity_b, "m", access_token=self.db.access)
        with self.assertRaises(RuntimeRejected): self.reads.meeting(replace(self.db.identity, uid="actor-b"), "m", access_token=self.db.access)
        self.db.state["accounts"]["actor"][0] = 1
        with self.assertRaises(RuntimeRejected): self.detail()
        self.db.state["accounts"]["actor"][0] = 0
        self.db.after_read = lambda _, c: c.state["sessions"][self.db.identity.session_id].update(revoked_at=NOW)
        with self.assertRaises(RuntimeRejected): self.detail()
        self.assertTrue(all(c.closed and c.commits == 0 for c in self.db.connections))

    def test_sixty_four_kibibytes_no_truncation_no_skipping_unemitted_rows(self):
        text = "🙂" * 4096
        for index in range(8): self.db.add_meeting(f"m{index}", description=text)
        ids = []; page = self.meetings()
        self.assertLess(len(page["items"]), 8); self.assertIsNotNone(page["nextCursor"])
        while True:
            self.assertLessEqual(len(canonical_json(page)), 65536)
            self.assertTrue(all(item["description"] == text for item in page["items"]))
            ids.extend(item["meetingId"] for item in page["items"])
            if page["nextCursor"] is None: break
            page = self.meetings(cursor=page["nextCursor"])
        self.assertEqual(ids, [f"m{index}" for index in range(8)])

    def test_malformed_database_rows_duplicates_order_and_sql_failure_fail_closed(self):
        self.db.add_meeting("m"); self.db.join("m", "actor")
        good = {**self.db.state["meetings"]["m"], "trusted": 1, "valid": 1}
        for changes in ({"revision": True}, {"revision": -1}, {"startsAt": "invalid"},
                        {"trusted": True}, {"kind": "individual"}, {"organizerUid": "bad/uid"}):
            self.db.forced["meetings"] = [tuple({**good, **changes}[field] for field in MEETING_FIELDS)]
            with self.assertRaises(RuntimeUnavailable): self.meetings()
        self.db.forced["meetings"] = [tuple(good[field] for field in MEETING_FIELDS)] * 2
        with self.assertRaises(RuntimeUnavailable): self.detail()
        with self.assertRaises(RuntimeUnavailable): self.meetings()
        self.db.forced.clear()
        self.db.forced["profiles"] = [tuple({**profile("peer"), "disabled": 0, "lifecycle": "active", "valid": 1}[field] for field in ROW_FIELDS)] * 2
        with self.assertRaises(RuntimeUnavailable): self.detail()
        self.db.forced.clear()
        malformed = {**member("m", "actor"), "trusted": 1, "leftAt": None, "kickedAt": STAMP}
        self.db.forced["members"] = [tuple(malformed[field] for field in MEMBER_FIELDS)]
        with self.assertRaises(RuntimeUnavailable): self.detail()
        self.db.forced.clear(); self.db.fail_contains = "FROM clrs_staging.meetings"
        with self.assertRaises(RuntimeUnavailable): self.meetings()

    def test_request_validation_and_frozen_index_parameterization(self):
        for options in ({"limit": True}, {"limit": 0}, {"limit": 31}, {"scope": "public"},
                        {"country_code": "ru"}, {"country_code": "ZZ"}, {"region": "Москва"},
                        {"country_code": "RU", "region": " Москва"}):
            with self.assertRaises(RuntimeInvalidRequest): self.meetings(**options)
        for invalid in ("", ".", "..", "bad/uid", True):
            with self.assertRaises(RuntimeInvalidRequest): self.detail(invalid)
        for anchor in (None, (None, "id'quote"), (STAMP, "id'quote")):
            sql, params = meetings_query("individual", anchor)
            self.assertIn("FORCE INDEX (meetings_browse_idx)", sql)
            self.assertIn("m.kind = %s AND m.deleted_at IS NULL", sql)
            self.assertIn("ORDER BY m.starts_at ASC, m.meeting_id ASC LIMIT %s", sql)
            self.assertNotIn("OFFSET", sql); self.assertNotIn("id'quote", sql)
            self.assertNotIn("CAST(m.meeting_id AS BINARY) >", sql)
            self.assertEqual(params[-1], SCAN_CHUNK)
        sql, params = participants_query("id'quote", "uid'quote")
        self.assertIn("FORCE INDEX (meeting_members_active_idx)", sql)
        self.assertIn("mm.left_at IS NULL", sql); self.assertIn("ORDER BY mm.uid ASC LIMIT %s", sql)
        self.assertNotIn("id'quote", sql); self.assertNotIn("uid'quote", sql)
        self.assertEqual(params, ("id'quote", "id'quote", "uid'quote", SCAN_CHUNK))
        for sql, params in (profiles_query(["actor", "peer"]), actor_members_query(["one", "two"], "actor")):
            self.assertNotIn("OFFSET", sql); self.assertIn("LIMIT %s FOR SHARE", sql)
            self.assertLessEqual(params[-1], 64)


if __name__ == "__main__":
    unittest.main()
