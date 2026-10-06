"""Isolated synthetic SQL/HTTP proof, using the real store and no TCP."""
import copy
import json
import unittest
from dataclasses import replace

from runtime_chat import RuntimeChatService
from runtime_http import RuntimeMutationHttp
from runtime_meeting_create import (CREATE_OPERATION, MEETING_ORIGIN, MEMBER_ORIGIN,
    RuntimeMeetingCreateService, MeetingAccessRejected, validate_creation, _COLUMNS, _INDEX_PARTS)
from runtime_meetings import RuntimeMeetingsService, TRUSTED_POLICY, MEETING_FIELDS, MEMBER_FIELDS, SCAN_CHUNK
from runtime_mutations import (RuntimeMutationStore, RuntimeCommitUnknown, RuntimeConflict,
    RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, request_digest)
from runtime_people import ROW_FIELDS
from runtime_profile import RuntimeProfileService, _FULL_FIELDS
from runtime_personal_chat import RuntimePersonalChatService
from runtime_reads import RuntimeReadRejected
from test_runtime_personal_chat import PersonalCursor, PersonalDatabase
from test_runtime_people import profile
from test_runtime_http import Native, env, OP, ENV as HTTP_ENV, ForbiddenInput
from test_runtime_mutations import NOW, STAMP


REQUEST = {"name": "  Встреча  ", "description": "Описание\n", "countryCode": "RU",
           "region": "Москва", "datetime": "03.10.2026 19:15", "type": "групповая"}
KEY = bytes(range(32))


class MeetingCursor(PersonalCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); db = self.c.db; state = self.c.state
        selected = ("clrs_staging.meetings" in sql or "clrs_staging.meeting_members" in sql
                    or "s.TABLE_NAME = 'meetings'" in sql or "full_name" in sql and "clrs_staging.profiles" in sql
                    or sql.startswith("SELECT p.uid, a.disabled") and "p.uid IN (" in sql)
        if not selected:
            return super().execute(statement, params)
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if db.fail_contains and db.fail_contains in sql:
            raise OSError("synthetic denied SQL")
        assert self.c.held
        if "FROM information_schema.STATISTICS" in sql:
            self.rows = db.meeting_indexes
        elif "clrs_staging.profiles" in sql:
            if "p.uid IN (" in sql:
                rows = [state["profiles"][uid] for uid in params[:params[-1]] if uid in state["profiles"]]
                for row in rows:
                    account = state["accounts"][row["uid"]]
                    data = {**row, "disabled": account[0], "lifecycle": account[1], "valid": 1}
                    self.rows.append(tuple(data.get(field) for field in ROW_FIELDS))
            else:
                assert params[0] == params[1] and sql.endswith("FOR SHARE")
                row = state["profiles"].get(params[0])
                if row:
                    self.rows = [tuple(row.get(field) for field in _FULL_FIELDS) + (STAMP, 1)]
        elif sql.startswith("INSERT INTO clrs_staging.meetings "):
            mid, uid, invited, kind, title, description, code, region, created, updated, operation, raw = params
            assert mid not in state["meetings"] and created == updated
            assert not any(row["organizerUid"] == uid and row["requestId"] == operation for row in state["meetings"].values())
            self.c.state["meetings"][mid] = {"meetingId": mid, "organizerUid": uid,
                "invitedUid": invited, "kind": kind, "title": title, "description": description,
                "countryCode": code, "region": region, "startsAt": None, "createdAt": STAMP,
                "updatedAt": STAMP, "revision": 0, "deletedAt": None, "requestId": operation,
                "legacy_raw": json.loads(raw)}
            self.rowcount = 1
        elif sql.startswith("INSERT INTO clrs_staging.meeting_members "):
            mid, uid, joined, raw = params
            assert mid in state["meetings"] and (mid, uid) not in state["meeting_members"]
            assert joined == STAMP[:-1].replace("T", " ")
            state["meeting_members"][(mid, uid)] = {"meetingId": mid, "uid": uid,
                "joinedAt": STAMP, "leftAt": None, "kickedAt": None, "membershipRevision": 0,
                "legacy_raw": json.loads(raw)}
            self.rowcount = 1
        elif "FROM clrs_staging.meetings AS m" in sql:
            assert self.c.readonly and "JSON_LENGTH(m.legacy_raw) = 2" in sql and MEETING_ORIGIN in sql
            rows = list(state["meetings"].values())
            if "FORCE INDEX" in sql:
                rows = [row for row in rows if row["kind"] == params[0] and row["deletedAt"] is None]
                if "m.starts_at IS NULL AND m.meeting_id >" in sql:
                    rows = [row for row in rows if row["startsAt"] is not None or row["meetingId"] > params[1]]
                rows.sort(key=lambda row: (row["startsAt"] is not None, row["startsAt"] or "", row["meetingId"].encode()))
                rows = rows[:SCAN_CHUNK]
            else:
                rows = [row for row in rows if row["meetingId"] == params[0] == params[1] and row["deletedAt"] is None]
            for row in rows:
                raw = row["legacy_raw"]; local = raw.get("localDatetime") if type(raw) is dict else None
                trusted = (type(raw) is dict and set(raw) == {"origin", "localDatetime"}
                    and raw["origin"] == MEETING_ORIGIN and type(local) is str
                    and len(local.encode()) == 16 and row["startsAt"] is None)
                data = {**row, "trusted": int(trusted), "valid": 1, "localDatetime": local if trusted else None}
                self.rows.append(tuple(data[field] for field in MEETING_FIELDS))
        elif "FROM clrs_staging.meetings " in sql:
            row = state["meetings"].get(params[0]); assert params[0] == params[1]
            if row:
                self.rows = [tuple(json.dumps(row["legacy_raw"]) if field == "raw" else row[field] for field in _COLUMNS)]
        elif "FROM clrs_staging.meeting_members AS mm" in sql:
            assert self.c.readonly and "JSON_LENGTH(mm.legacy_raw) = 1" in sql and MEMBER_ORIGIN in sql
            if "FORCE INDEX" in sql:
                rows = [row for row in state["meeting_members"].values() if row["meetingId"] == params[0] and row["leftAt"] is None]
                rows.sort(key=lambda row: row["uid"].encode()); rows = rows[:SCAN_CHUNK]
            else:
                ids = params[:params[-1]]; uid = params[-3]
                rows = [row for row in state["meeting_members"].values() if row["meetingId"] in ids and row["uid"] == uid]
            for row in rows:
                data = {**row, "trusted": int(row["legacy_raw"] == {"origin": MEMBER_ORIGIN})}
                self.rows.append(tuple(data[field] for field in MEMBER_FIELDS))
        else:
            row = state["meeting_members"].get((params[0], params[2]))
            assert params[0] == params[1] and params[2] == params[3]
            if row:
                self.rows = [(row["uid"], row["joinedAt"], row["leftAt"], row["kickedAt"],
                              row["membershipRevision"], json.dumps(row["legacy_raw"]))]
        return self.rowcount or len(self.rows)


class MeetingDatabase(PersonalDatabase):
    def __init__(self, **options):
        super().__init__(**options)
        self.state["meetings"] = {}; self.state["meeting_members"] = {}
        for uid in ("actor", "peer"):
            self.state["profiles"][uid] = {**profile(uid), "legacy_raw": {}, "raw": {}, "saved": 1,
                "complete": 1, "invisible": None, "profileDetailsSaved": 1, "isRegistrationEnd": 1,
                "profile_details_saved": 1, "registration_complete": 1}
        self.meeting_indexes = [(table, index, 0, sequence, column, None, "utf8mb4_0900_bin")
            for table, index, sequence, column in sorted(_INDEX_PARTS)]

    def connect(self, **config):
        connection = super().connect(**config)
        connection.cursor = lambda: MeetingCursor(connection)
        return connection

    def services(self):
        store = RuntimeMutationStore(self.env, self.tokens, connect=self.connect, clock=lambda: NOW)
        return store, RuntimeMeetingCreateService(store, clock=lambda: NOW)


class MeetingCreateTests(unittest.TestCase):
    def setup_services(self, **options):
        db = MeetingDatabase(**options); store, creator = db.services()
        self.addCleanup(store.close)
        reads = RuntimeMeetingsService(store, KEY, trusted_policy=TRUSTED_POLICY, clock=lambda: NOW)
        return db, store, creator, reads

    def test_real_http_create_replay_lookup_and_read_retains_local_date_and_creator_only(self):
        db, store, creator, reads = self.setup_services()
        native = Native(); native.identity = db.identity
        services = (store, RuntimeChatService(store), RuntimeProfileService(store), RuntimePersonalChatService(store), creator)
        http = RuntimeMutationHttp(HTTP_ENV, service_factory=lambda _: services,
            meetings_factory=lambda shared, _: reads if shared is store else self.fail("Different store"))
        def call(request):
            request["HTTP_AUTHORIZATION"] = "Bearer " + db.access
            return http.dispatch(request, native_service=native, native_configured=True)
        created = call(env("/v1/runtime/meetings", {"operationId": OP, **REQUEST}))
        self.assertEqual(created.status, "201 Created")
        result = created.payload["result"]; mid = result["meetingId"]
        self.assertEqual(result, {"meetingId": mid, "created": True, "meetingRevision": 0, "localDatetime": REQUEST["datetime"]})
        repeated = call(env("/v1/runtime/meetings", {"operationId": OP, **REQUEST}))
        self.assertEqual(repeated.payload["result"], result); self.assertTrue(repeated.payload["replayed"])
        found = call(env(f"/v1/runtime/operations/{CREATE_OPERATION}/{OP}", REQUEST_METHOD="GET",
                         QUERY_STRING="requestHash=" + request_digest(REQUEST).hex()))
        self.assertEqual(found.payload["result"], result)
        detail = call(env("/v1/runtime/meetings/" + mid, REQUEST_METHOD="GET"))
        self.assertEqual(detail.status, "200 OK")
        self.assertEqual((detail.payload["meeting"]["startsAt"], detail.payload["meeting"]["localDatetime"]), (None, REQUEST["datetime"]))
        roster = call(env("/v1/runtime/meetings/" + mid + "/participants", REQUEST_METHOD="GET"))
        self.assertEqual(roster.status, "200 OK"); self.assertEqual([row["uid"] for row in roster.payload["items"]], ["actor"])
        self.assertEqual(roster.payload["items"][0]["joinedAt"], STAMP)
        for key, raw in (("old-empty", {}), ("imported", {"fields": {"admin": {"stringValue": "actor"}}}),
                         ("extra-marker", {"origin": MEETING_ORIGIN, "localDatetime": REQUEST["datetime"], "private": False})):
            db.state["meetings"][key] = {**db.state["meetings"][mid], "meetingId": key, "legacy_raw": raw}
        page = call(env("/v1/runtime/meetings", REQUEST_METHOD="GET"))
        self.assertEqual([row["meetingId"] for row in page.payload["items"]], [mid])
        self.assertEqual(sum(sql.startswith("INSERT INTO clrs_staging.meetings ") for sql, _ in db.calls), 1)
        self.assertFalse(any(sql.startswith("UPDATE clrs_staging.profiles") or "legacy_documents" in sql for sql, _ in db.calls))
        self.assertIsNone(RuntimeMeetingsService.from_env(store, HTTP_ENV))
        closed = RuntimeMutationHttp(HTTP_ENV, service_factory=lambda _: services)
        reply = closed.dispatch(env("/v1/runtime/meetings", REQUEST_METHOD="GET", HTTP_AUTHORIZATION="Bearer " + db.access),
                                native_service=native, native_configured=True)
        self.assertEqual(reply.status, "503 Service Unavailable")
        denied = call(env("/v1/runtime/meetings", {"operationId": OP, **REQUEST, "raw": {}}))
        self.assertEqual(denied.status, "400 Bad Request")

    def test_unknown_commit_restart_reconciles_original_without_second_insert_or_post(self):
        for committed in (True, False):
            with self.subTest(committed=committed):
                db, store, creator, _ = self.setup_services()
                if committed:
                    db.commit_unknown_once = True
                else:
                    db.before_commit = lambda: (_ for _ in ()).throw(OSError("lost before commit"))
                with self.assertRaises(RuntimeCommitUnknown):
                    creator.create(db.identity, OP, REQUEST, access_token=db.access)
                self.assertEqual(len(db.connections), 1)
                store.close(); db.before_commit = None
                restarted, _ = db.services(); self.addCleanup(restarted.close)
                found = restarted.lookup(db.identity, CREATE_OPERATION, OP, payload=REQUEST, access_token=db.access)
                self.assertEqual(found.payload["state"], "committed" if committed else "not_found")
                self.assertEqual(len(db.state["meetings"]), int(committed)); self.assertTrue(db.connections[-1].readonly)
                self.assertEqual(sum(sql.startswith("INSERT INTO clrs_staging.meetings ") for sql, _ in db.calls), 1)
                peer, token = db.peer_identity()
                other = restarted.lookup(peer, CREATE_OPERATION, OP, payload=REQUEST, access_token=token)
                self.assertEqual(other.payload["state"], "not_found")

    def test_unknown_lookup_rejects_same_owner_same_payload_cross_operation_receipt(self):
        db, store, creator, _ = self.setup_services()
        other_id = "12345678-1234-4234-8234-123456789abd"
        other = creator.create(db.identity, other_id, REQUEST, access_token=db.access)
        db.commit_unknown_once = True
        with self.assertRaises(RuntimeCommitUnknown):
            creator.create(db.identity, OP, REQUEST, access_token=db.access)
        receipt = db.state["receipts"][("actor", CREATE_OPERATION, OP)]
        original_wrapper = receipt[3]; wrapper = json.loads(original_wrapper)
        original_mid = wrapper["response"]["meetingId"]
        self.assertNotEqual(original_mid, other.payload["result"]["meetingId"])
        wrapper["response"] = other.payload["result"]
        receipt[3] = json.dumps(wrapper)
        with self.assertRaises(RuntimeUnavailable):
            store.lookup(db.identity, CREATE_OPERATION, OP, payload=REQUEST, access_token=db.access)
        receipt[3] = original_wrapper
        # Original response ID alone is insufficient if its current row points
        # to a different operation. This must not confirm the pending intent.
        db.state["meetings"][original_mid]["requestId"] = other_id
        with self.assertRaises(MeetingAccessRejected):
            store.lookup(db.identity, CREATE_OPERATION, OP, payload=REQUEST, access_token=db.access)
        db.state["meetings"][original_mid]["requestId"] = OP
        found = store.lookup(db.identity, CREATE_OPERATION, OP, payload=REQUEST, access_token=db.access)
        self.assertEqual(found.payload["result"]["meetingId"], original_mid)
        self.assertEqual(len(db.state["meetings"]), 2)
        personal = RuntimePersonalChatService(store, clock=lambda: NOW)
        first = personal.open_personal(db.identity, "peer", OP, access_token=db.access)
        replay = personal.open_personal(db.identity, "peer", OP, access_token=db.access)
        self.assertEqual(replay.payload["result"], first.payload["result"])
        self.assertTrue(replay.payload["replayed"])  # old response-guard signature

    def test_validation_permissions_current_profile_and_atomic_membership_failure(self):
        for request in ({**REQUEST, "datetime": "31.02.2026 10:00"}, {**REQUEST, "datetime": "2026-10-03T19:15:00Z"},
                        {**REQUEST, "region": "unknown"}, {**REQUEST, "countryCode": "ru"},
                        {**REQUEST, "description": "x" * 4097}, {**REQUEST, "name": " "},
                        *({**REQUEST, key: value} for key, value in (("admin", "peer"), ("users", ["peer"]),
                           ("origin", MEETING_ORIGIN), ("invitedUid", "peer"), ("created_by", "peer")))):
            with self.assertRaises(RuntimeInvalidRequest):
                validate_creation(request)
        for provider, fail in ((False, None), (True, "INSERT INTO clrs_staging.meeting_members")):
            db, _, creator, _ = self.setup_services(provider=provider); db.fail_contains = fail
            before = copy.deepcopy(db.state)
            with self.assertRaises(RuntimeUnavailable):
                creator.create(db.identity, OP, REQUEST, access_token=db.access)
            self.assertEqual(db.state, before)
        db, store, creator, _ = self.setup_services()
        db.state["profiles"]["actor"].update(isRegistrationEnd=0, primaryGroup=None)
        refused = creator.create(db.identity, OP, REQUEST, access_token=db.access)
        self.assertEqual((refused.status, refused.payload["result"]), (409, {"error": "profile_not_ready"}))
        self.assertEqual(store.lookup(db.identity, CREATE_OPERATION, OP, payload=REQUEST, access_token=db.access).status, 409)
        self.assertEqual(db.state["meetings"], {})

    def test_individual_visibility_replay_membership_revocation_and_owner_isolation(self):
        db, store, creator, reads = self.setup_services()
        request = {**REQUEST, "type": "индивидуальная", "invitedUid": "peer"}
        created = creator.create(db.identity, OP, request, access_token=db.access); mid = created.payload["result"]["meetingId"]
        self.assertEqual(set(db.state["meeting_members"]), {(mid, "actor")})
        other_session, other_access = db.tokens.mint("other", "device-other", 0, NOW)
        db.state["accounts"]["other"] = [0, "active", 0, 1]; db.state["sessions"][other_session["session_id"]] = other_session
        other = replace(db.identity, uid="other", session_id=other_session["session_id"])
        with self.assertRaises(RuntimeReadRejected):
            reads.meeting(other, mid, access_token=other_access["accessToken"])
        for change in (lambda: db.state["profiles"]["peer"].update(invisible="2030-01-01T00:00:00Z"),
                       lambda: db.state["meeting_members"][(mid, "actor")].update(leftAt=STAMP, kickedAt=STAMP)):
            change()
            with self.assertRaises(MeetingAccessRejected):
                store.lookup(db.identity, CREATE_OPERATION, OP, payload=request, access_token=db.access)
            db.state["profiles"]["peer"]["invisible"] = None
        native = Native(); native.identity = db.identity
        http = RuntimeMutationHttp(HTTP_ENV, service_factory=lambda _: (store, None, None, None, creator))
        reply = http.dispatch(env(f"/v1/runtime/operations/{CREATE_OPERATION}/{OP}", REQUEST_METHOD="GET",
            QUERY_STRING="requestHash=" + request_digest(request).hex(), HTTP_AUTHORIZATION="Bearer " + db.access),
            native_service=native, native_configured=True)
        self.assertEqual((reply.status, reply.payload, reply.authenticate), ("404 Not Found", {"error": "meeting_unavailable"}, False))
        db.state["accounts"]["actor"][0] = 1
        with self.assertRaises(RuntimeRejected):
            store.lookup(db.identity, CREATE_OPERATION, OP, payload=request, access_token=db.access)


if __name__ == "__main__":
    unittest.main()
