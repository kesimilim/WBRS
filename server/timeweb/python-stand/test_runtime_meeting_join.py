"""One scoped join module: real shared transactions, synthetic rows, no TCP."""
import copy
import json
import unittest

from runtime_http import RuntimeMutationHttp
from runtime_meeting_create import MEETING_ORIGIN, MEMBER_ORIGIN, MeetingAccessRejected, _meeting_id, member_archive_window
from runtime_meeting_join import JOIN_OPERATION, RuntimeMeetingJoinService, validate_join
from runtime_meetings import MEETING_FIELDS, MEMBER_FIELDS
from runtime_mutations import (RuntimeMutationStore, RuntimeInvalidRequest, RuntimeUnavailable,
    RuntimeCommitUnknown, RuntimeRejected, request_digest)
from test_runtime_meeting_create import MeetingCursor, MeetingDatabase, REQUEST
from test_runtime_http import Native, env, OP, ENV as HTTP_ENV
from test_runtime_mutations import NOW, STAMP


SECOND = "12345678-1234-4234-8234-123456789abd"
MID = _meeting_id("actor", OP)
PAYLOAD = {"meetingId": MID}


class JoinCursor(MeetingCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split())
        if ("FROM clrs_staging.meetings AS m" not in sql
                and "FROM clrs_staging.meeting_members AS mm" not in sql):
            return super().execute(statement, params)
        assert self.c.held
        share = "FOR SHARE OF " + ("mm" if "AS mm" in sql else "m")
        assert sql.endswith(share) or (not self.c.readonly and sql.endswith("FOR UPDATE"))
        self.c.db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        state = self.c.state
        if "FROM clrs_staging.meetings AS m" in sql:
            assert params == (MID, MID)
            row = state["meetings"].get(MID)
            if row:
                raw = row["legacy_raw"]; local = raw.get("localDatetime") if type(raw) is dict else None
                trusted = (type(raw) is dict and raw == {"origin": MEETING_ORIGIN, "localDatetime": REQUEST["datetime"]}
                    and row["startsAt"] is None)
                data = {**row, "trusted": int(trusted), "valid": 1, "localDatetime": local if trusted else None}
                self.rows = [tuple(data[key] for key in MEETING_FIELDS)]
        else:
            assert len(params) == 4 and params[0] == params[1] == MID and params[2] == params[3]
            row = state["meeting_members"].get((MID, params[2]))
            if row:
                try:
                    member_archive_window(row["legacy_raw"], row["membershipRevision"], row["joinedAt"], STAMP)
                    trusted = True
                except RuntimeUnavailable:
                    trusted = False
                data = {**row, "trusted": int(trusted)}
                self.rows = [tuple(data[key] for key in MEMBER_FIELDS)]
        return len(self.rows)


class JoinDatabase(MeetingDatabase):
    def __init__(self, *, individual=False, **options):
        super().__init__(**options)
        self.state["meetings"][MID] = {"meetingId": MID, "organizerUid": "actor",
            "invitedUid": "peer" if individual else None, "kind": "individual" if individual else "group",
            "title": REQUEST["name"], "description": REQUEST["description"],
            "countryCode": "RU", "region": "Москва", "startsAt": None, "createdAt": STAMP,
            "updatedAt": STAMP, "revision": 0, "deletedAt": None, "requestId": OP,
            "legacy_raw": {"origin": MEETING_ORIGIN, "localDatetime": REQUEST["datetime"]}}
        self.state["meeting_members"][(MID, "actor")] = self.member("actor")

    @staticmethod
    def member(uid, **changes):
        return {"meetingId": MID, "uid": uid, "joinedAt": STAMP, "leftAt": None,
            "kickedAt": None, "membershipRevision": 0, "legacy_raw": {"origin": MEMBER_ORIGIN}, **changes}

    def connect(self, **config):
        connection = super().connect(**config)
        connection.cursor = lambda: JoinCursor(connection)
        return connection

    def join_services(self):
        store = RuntimeMutationStore(self.env, self.tokens, connect=self.connect, clock=lambda: NOW)
        return store, RuntimeMeetingJoinService(store, clock=lambda: NOW)


class MeetingJoinTests(unittest.TestCase):
    def setup_join(self, **options):
        db = JoinDatabase(**options); identity, token = db.peer_identity()
        store, join = db.join_services(); self.addCleanup(store.close)
        return db, store, join, identity, token

    @staticmethod
    def inserts(db):
        return sum(sql.startswith("INSERT INTO clrs_staging.meeting_members ") for sql, _ in db.calls)

    def http(self, db, store, join, identity, token):
        native = Native(); native.identity = identity
        adapter = RuntimeMutationHttp(HTTP_ENV, service_factory=lambda _: (store, None, None, None, None, join))
        def call(environ):
            environ["HTTP_AUTHORIZATION"] = "Bearer " + token
            return adapter.dispatch(environ, native_service=native, native_configured=True)
        return call

    def test_real_http_join_original_replay_lookup_and_active_noop(self):
        for individual in (False, True):
            with self.subTest(individual=individual):
                db, store, join, peer, token = self.setup_join(individual=individual)
                call = self.http(db, store, join, peer, token)
                post = lambda operation: call(env("/v1/runtime/meetings/join", {"operationId": operation, **PAYLOAD}))
                joined = post(OP)
                expected = {"meetingId": MID, "joined": True, "alreadyMember": False, "membershipRevision": 0}
                self.assertEqual((joined.status, joined.payload["result"], joined.payload["entityRevision"]), ("200 OK", expected, 0))
                self.assertEqual(set(db.state["meeting_members"]), {(MID, "actor"), (MID, "peer")})
                self.assertEqual(db.state["meeting_members"][(MID, "peer")]["legacy_raw"], {"origin": MEMBER_ORIGIN})
                retained = copy.deepcopy(db.state["meeting_members"])
                repeated = post(OP)
                self.assertEqual(repeated.payload["result"], expected); self.assertTrue(repeated.payload["replayed"])
                found = call(env(f"/v1/runtime/operations/{JOIN_OPERATION}/{OP}", REQUEST_METHOD="GET",
                                QUERY_STRING="requestHash=" + request_digest(PAYLOAD).hex()))
                self.assertEqual(found.payload["result"], expected)
                already = post(SECOND)
                self.assertEqual(already.payload["result"], {**expected, "alreadyMember": True})
                self.assertEqual(db.state["meeting_members"], retained); self.assertEqual(self.inserts(db), 1)
                self.assertFalse(any(sql.startswith("INSERT INTO clrs_staging.meetings ") or sql.startswith("UPDATE clrs_staging.meeting") for sql, _ in db.calls))
                invalid = call(env("/v1/runtime/meetings/join", {"operationId": OP, **PAYLOAD, "uid": "actor"}))
                self.assertEqual(invalid.status, "400 Bad Request")
                self.assertEqual(call(env("/v1/runtime/meetings/join", REQUEST_METHOD="GET")).status, "405 Method Not Allowed")

    def test_unknown_commit_restart_lookup_only_has_no_second_insert_and_owner_isolation(self):
        for committed in (False, True):
            with self.subTest(committed=committed):
                db, store, join, peer, token = self.setup_join()
                if committed: db.commit_unknown_once = True
                else: db.before_commit = lambda: (_ for _ in ()).throw(OSError("lost before commit"))
                with self.assertRaises(RuntimeCommitUnknown): join.join(peer, OP, PAYLOAD, access_token=token)
                store.close(); db.before_commit = None
                restarted, _ = db.join_services(); self.addCleanup(restarted.close)
                result = restarted.lookup(peer, JOIN_OPERATION, OP, request_hash=request_digest(PAYLOAD), access_token=token)
                self.assertEqual(result.payload["state"], "committed" if committed else "not_found")
                self.assertEqual((MID, "peer") in db.state["meeting_members"], committed)
                self.assertTrue(db.connections[-1].readonly); self.assertEqual(self.inserts(db), 1)
                other = restarted.lookup(db.identity, JOIN_OPERATION, OP, payload=PAYLOAD, access_token=db.access)
                self.assertEqual(other.payload["state"], "not_found")

    def test_source_visibility_invitation_and_left_kick_fail_closed_without_membership_overwrite(self):
        changes = [
            (404, "meeting_not_found", lambda db: db.state["meetings"].clear()),
            (404, "meeting_not_found", lambda db: db.state["meetings"][MID].update(legacy_raw={})),
            (404, "meeting_not_found", lambda db: db.state["meetings"][MID].update(legacy_raw={"fields": {"admin": {"stringValue": "actor"}}})),
            (404, "meeting_not_found", lambda db: db.state["meetings"][MID].update(deletedAt=STAMP)),
            (409, "meeting_unavailable", lambda db: db.state["profiles"]["actor"].update(invisible_until="2030-01-01T00:00:00Z")),
            (409, "meeting_unavailable", lambda db: db.state["meeting_members"].update({(MID, "peer"): db.member("peer", leftAt=STAMP, kickedAt=STAMP)})),
            (409, "meeting_unavailable", lambda db: db.state["meeting_members"].update({(MID, "peer"): db.member("peer", legacy_raw={})})),
            (404, "profile_not_found", lambda db: db.state["profiles"].pop("peer")),
            (409, "profile_not_ready", lambda db: db.state["profiles"]["peer"].update(isRegistrationEnd=0, primaryGroup=None)),
            (409, "meeting_unavailable", lambda db: db.state["meetings"][MID].update(kind="individual", invitedUid="another")),
        ]
        for status, error, change in changes:
            with self.subTest(error=error, change=changes.index((status, error, change))):
                db, store, join, peer, token = self.setup_join(); change(db)
                before = copy.deepcopy(db.state["meeting_members"])
                reply = join.join(peer, OP, PAYLOAD, access_token=token)
                self.assertEqual((reply.status, reply.payload["result"]), (status, {"error": error}))
                self.assertEqual(store.lookup(peer, JOIN_OPERATION, OP, payload=PAYLOAD, access_token=token).payload["result"], {"error": error})
                self.assertEqual(db.state["meeting_members"], before); self.assertEqual(self.inserts(db), 0)
        for payload in ({}, {**PAYLOAD, "uid": "peer"}, {**PAYLOAD, "raw": {}}, {"meetingId": "x/y"}):
            with self.assertRaises(RuntimeInvalidRequest): validate_join(payload)

    def test_atomic_insert_failure_index_grants_and_current_receipt_access(self):
        for unsupported in ("grants", "index", "insert"):
            with self.subTest(unsupported=unsupported):
                db, _, join, peer, token = self.setup_join(provider=unsupported != "grants")
                if unsupported == "index": db.meeting_indexes = db.meeting_indexes[:-1]
                if unsupported == "insert": db.fail_contains = "INSERT INTO clrs_staging.meeting_members"
                before = copy.deepcopy(db.state)
                with self.assertRaises(RuntimeUnavailable): join.join(peer, OP, PAYLOAD, access_token=token)
                self.assertEqual(db.state, before)
        db, store, join, peer, token = self.setup_join()
        reply = join.join(peer, OP, PAYLOAD, access_token=token)
        receipt = db.state["receipts"][("peer", JOIN_OPERATION, OP)]
        wrapper = json.loads(receipt[3]); wrapper["response"]["meetingId"] = "another"
        original = receipt[3]; receipt[3] = json.dumps(wrapper)
        with self.assertRaises(RuntimeUnavailable): store.lookup(peer, JOIN_OPERATION, OP, payload=PAYLOAD, access_token=token)
        receipt[3] = original
        db.state["meeting_members"][(MID, "peer")].update(leftAt=STAMP, kickedAt=STAMP)
        with self.assertRaises(MeetingAccessRejected): store.lookup(peer, JOIN_OPERATION, OP, payload=PAYLOAD, access_token=token)
        call = self.http(db, store, join, peer, token)
        request = lambda: env(f"/v1/runtime/operations/{JOIN_OPERATION}/{OP}", REQUEST_METHOD="GET",
                             QUERY_STRING="requestHash=" + request_digest(PAYLOAD).hex())
        denied = call(request())
        self.assertEqual((denied.status, denied.payload, denied.authenticate), ("404 Not Found", {"error": "meeting_unavailable"}, False))
        db.state["accounts"]["peer"][0] = 1
        denied = call(request())
        self.assertEqual((denied.status, denied.authenticate), ("401 Unauthorized", True))
        self.assertEqual(reply.payload["result"]["meetingId"], MID); self.assertEqual(self.inserts(db), 1)


if __name__ == "__main__":
    unittest.main()
