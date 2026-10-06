"""Native leave/kick/rejoin through real receipt/session transactions, no TCP."""
import copy
import json
import unittest

from runtime_http import RuntimeMutationHttp
from runtime_meeting_create import MeetingAccessRejected
from runtime_meeting_chat import _INDEX_PARTS
from runtime_meeting_join import JOIN_OPERATION, RuntimeMeetingJoinService
from runtime_meeting_membership import (LEAVE_OPERATION, KICK_OPERATION,
    RuntimeMeetingMembershipService, validate_membership)
from runtime_mutations import (RuntimeMutationStore, RuntimeUnavailable,
    RuntimeCommitUnknown, RuntimeRejected, request_digest)
from test_runtime_meeting_join import JoinCursor, JoinDatabase, MID, PAYLOAD, SECOND
from test_runtime_http import Native, env, OP, ENV as HTTP_ENV
from test_runtime_mutations import NOW, STAMP


THIRD = "12345678-1234-4234-8234-123456789abe"
FOURTH = "12345678-1234-4234-8234-123456789abf"
KICK = {**PAYLOAD, "targetUid": "peer"}


class MembershipCursor(JoinCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); db = self.c.db
        if "s.TABLE_NAME = 'meeting_messages'" in sql or "FROM clrs_staging.meeting_messages AS mm" in sql:
            assert self.c.held
            db.calls.append((sql, params)); self.rows = db.message_indexes if "information_schema" in sql else []; self.rowcount = 0
            return len(self.rows)
        if not sql.startswith("UPDATE clrs_staging.meeting_members "):
            return super().execute(statement, params)
        assert self.c.held and not self.c.readonly
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if db.fail_contains and db.fail_contains in sql:
            raise OSError("synthetic denied update")
        rejoin = "SET left_at = NULL" in sql
        if rejoin:
            revision, mid, exact_mid, uid, exact_uid, previous = params
        else:
            if "legacy_raw = %s" in sql:
                left, kicked, revision, raw, mid, exact_mid, uid, exact_uid, previous = params
            else:
                left, kicked, revision, mid, exact_mid, uid, exact_uid, previous = params
                raw = None
        assert mid == exact_mid == MID and uid == exact_uid
        # Writes are serialized by the meeting lock, then by exact member PK.
        assert any("FROM clrs_staging.meetings AS m" in query and query.endswith("FOR UPDATE") for query, _ in db.calls)
        row = self.c.state["meeting_members"].get((mid, uid))
        if row is not None and row["membershipRevision"] == previous and not db.cas_failure:
            if rejoin:
                assert row["leftAt"] is not None and row["kickedAt"] is None
                row["leftAt"] = None
            else:
                to_stamp = lambda value: value.replace(" ", "T") + "Z" if value is not None else None
                row.update(leftAt=to_stamp(left), kickedAt=to_stamp(kicked))
                if raw is not None:
                    row["legacy_raw"] = json.loads(raw)
            row["membershipRevision"] = revision; self.rowcount = 1
        if db.revoke_during_update:
            self.c.state["accounts"][uid][0] = 1
        return self.rowcount


class MembershipDatabase(JoinDatabase):
    def __init__(self, **options):
        super().__init__(**options); self.cas_failure = False; self.revoke_during_update = False
        self.message_indexes = [(*part, None, None if part[3] == "sequence" else "utf8mb4_0900_bin") for part in sorted(_INDEX_PARTS)]

    def connect(self, **config):
        connection = super().connect(**config)
        connection.cursor = lambda: MembershipCursor(connection)
        return connection

    def services(self):
        store = RuntimeMutationStore(self.env, self.tokens, connect=self.connect, clock=lambda: NOW)
        return store, RuntimeMeetingJoinService(store, clock=lambda: NOW), RuntimeMeetingMembershipService(store, clock=lambda: NOW)


class MeetingMembershipTests(unittest.TestCase):
    def setup_services(self, **options):
        db = MembershipDatabase(**options); peer, token = db.peer_identity()
        store, join, membership = db.services(); self.addCleanup(store.close)
        return db, store, join, membership, peer, token

    @staticmethod
    def updates(db):
        return sum(sql.startswith("UPDATE clrs_staging.meeting_members ") for sql, _ in db.calls)

    def http(self, db, store, join, membership, identity, token):
        native = Native(); native.identity = identity
        adapter = RuntimeMutationHttp(HTTP_ENV, service_factory=lambda _: (store, None, None, None, None, join, None, membership))
        def call(request):
            request["HTTP_AUTHORIZATION"] = "Bearer " + token
            return adapter.dispatch(request, native_service=native, native_configured=True)
        return call

    def test_real_http_leave_original_ack_rejoin_and_old_join_receipt_is_historical(self):
        for individual in (False, True):
            with self.subTest(individual=individual):
                db, store, join, membership, peer, token = self.setup_services(individual=individual)
                original_join = join.join(peer, OP, PAYLOAD, access_token=token)
                before = copy.deepcopy(db.state["meeting_members"][(MID, "peer")])
                call = self.http(db, store, join, membership, peer, token)
                result = call(env("/v1/runtime/meetings/leave", {"operationId": SECOND, **PAYLOAD}))
                expected = {"meetingId": MID, "left": True, "alreadyLeft": False, "membershipRevision": 1, "leftAt": STAMP}
                self.assertEqual((result.status, result.payload["result"], result.payload["entityRevision"]), ("200 OK", expected, 1))
                self.assertEqual(db.state["meeting_members"][(MID, "peer")]["joinedAt"], before["joinedAt"])
                # Current join/chat access is gone, but original leave can ACK.
                with self.assertRaises(MeetingAccessRejected):
                    store.lookup(peer, JOIN_OPERATION, OP, payload=PAYLOAD, access_token=token)
                lookup = call(env(f"/v1/runtime/operations/{LEAVE_OPERATION}/{SECOND}", REQUEST_METHOD="GET",
                    QUERY_STRING="requestHash=" + request_digest(PAYLOAD).hex()))
                self.assertEqual(lookup.payload["result"], expected); self.assertFalse(lookup.authenticate)
                again = membership.leave(peer, THIRD, PAYLOAD, access_token=token)
                self.assertEqual(again.payload["result"], {**expected, "alreadyLeft": True})
                self.assertEqual(self.updates(db), 1)
                rejoined = join.join(peer, SECOND, PAYLOAD, access_token=token)
                self.assertEqual(rejoined.payload["result"], {"meetingId": MID, "joined": True, "alreadyMember": False, "membershipRevision": 2})
                current = db.state["meeting_members"][(MID, "peer")]
                self.assertEqual((current["joinedAt"], current["leftAt"], current["kickedAt"]), (before["joinedAt"], None, None))
                self.assertEqual(store.lookup(peer, JOIN_OPERATION, OP, payload=PAYLOAD, access_token=token).payload["result"], original_join.payload["result"])
                self.assertEqual(store.lookup(peer, LEAVE_OPERATION, SECOND, payload=PAYLOAD, access_token=token).payload["result"], expected)
                malformed = call(env("/v1/runtime/meetings/leave", {"operationId": FOURTH, **PAYLOAD, "uid": "actor"}))
                self.assertEqual(malformed.status, "400 Bad Request")
                self.assertEqual(call(env("/v1/runtime/meetings/kick", REQUEST_METHOD="GET")).status, "405 Method Not Allowed")
                self.assertFalse(any("DELETE" in sql or "removed_meeting_messages" in sql for sql, _ in db.calls))

    def test_creator_can_leave_then_kick_and_kicked_cannot_rejoin(self):
        for individual in (False, True):
            with self.subTest(individual=individual):
                db, store, join, membership, peer, token = self.setup_services(individual=individual)
                join.join(peer, OP, PAYLOAD, access_token=token)
                membership.leave(db.identity, OP, PAYLOAD, access_token=db.access)
                # A current organizer relation survives voluntary own leave.
                result = membership.kick(db.identity, OP, KICK, access_token=db.access)
                expected = {"meetingId": MID, "targetUid": "peer", "kicked": True, "alreadyKicked": False,
                    "membershipRevision": 1, "kickedAt": STAMP, "leftAt": STAMP}
                self.assertEqual((result.status, result.payload["result"], result.payload["entityRevision"]), (200, expected, 1))
                original = copy.deepcopy(db.state["meeting_members"][(MID, "peer")])
                repeated = membership.kick(db.identity, SECOND, KICK, access_token=db.access)
                self.assertEqual(repeated.payload["result"], {**expected, "alreadyKicked": True})
                self.assertEqual(db.state["meeting_members"][(MID, "peer")], original)
                self.assertEqual(store.lookup(db.identity, KICK_OPERATION, OP, payload=KICK, access_token=db.access).payload["result"], expected)
                denied = join.join(peer, SECOND, PAYLOAD, access_token=token)
                self.assertEqual((denied.status, denied.payload["result"]), (409, {"error": "meeting_unavailable"}))
                self.assertEqual(db.state["meeting_members"][(MID, "peer")], original)

    def test_absent_leave_noop_and_kick_authority_absent_self_and_timestamp_preservation(self):
        db, store, join, membership, peer, token = self.setup_services()
        absent = membership.leave(peer, OP, PAYLOAD, access_token=token)
        self.assertEqual(absent.payload["result"], {"meetingId": MID, "left": True, "alreadyLeft": True, "membershipRevision": None, "leftAt": None})
        self.assertIsNone(absent.payload["entityRevision"]); self.assertNotIn((MID, "peer"), db.state["meeting_members"])
        self.assertEqual(store.lookup(peer, LEAVE_OPERATION, OP, payload=PAYLOAD, access_token=token).payload["result"], absent.payload["result"])
        for operation, identity, access, payload, status, error in (
            (OP, db.identity, db.access, KICK, 404, "participant_not_found"),
            (SECOND, db.identity, db.access, {**PAYLOAD, "targetUid": "actor"}, 409, "cannot_kick_self"),
            (OP, peer, token, {**PAYLOAD, "targetUid": "actor"}, 409, "organizer_required")):
            result = membership.kick(identity, operation, payload, access_token=access)
            self.assertEqual((result.status, result.payload["result"]), (status, {"error": error}))
            self.assertEqual(store.lookup(identity, KICK_OPERATION, operation, payload=payload, access_token=access).payload["result"], {"error": error})
        old = "2026-01-01T00:00:00.000000Z"
        db.state["meeting_members"][(MID, "peer")] = db.member("peer", joinedAt=old, leftAt=old, membershipRevision=2)
        kicked = membership.kick(db.identity, THIRD, KICK, access_token=db.access)
        self.assertEqual((kicked.payload["result"]["leftAt"], kicked.payload["result"]["kickedAt"], kicked.payload["entityRevision"]), (old, STAMP, 3))
        self.assertEqual(db.state["meeting_members"][(MID, "peer")]["joinedAt"], old)
        for payload in ({}, {**PAYLOAD, "raw": {}}, {"meetingId": "x/y"}):
            with self.assertRaises(ValueError): validate_membership(payload)

    def test_unknown_commit_lookup_only_and_owner_revocation_keep_original(self):
        for kick in (False, True):
            for committed in (False, True):
                with self.subTest(kick=kick, committed=committed):
                    db, store, _, membership, peer, token = self.setup_services()
                    db.state["meeting_members"][(MID, "peer")] = db.member("peer")
                    identity, access, payload = (db.identity, db.access, KICK) if kick else (peer, token, PAYLOAD)
                    if committed: db.commit_unknown_once = True
                    else: db.before_commit = lambda: (_ for _ in ()).throw(OSError("lost before commit"))
                    method = membership.kick if kick else membership.leave
                    with self.assertRaises(RuntimeCommitUnknown): method(identity, OP, payload, access_token=access)
                    before = self.updates(db); store.close(); db.before_commit = None
                    restarted, _, _ = db.services(); self.addCleanup(restarted.close)
                    operation = KICK_OPERATION if kick else LEAVE_OPERATION
                    result = restarted.lookup(identity, operation, OP, payload=payload, access_token=access)
                    self.assertEqual(result.payload["state"], "committed" if committed else "not_found")
                    self.assertEqual(self.updates(db), before); self.assertTrue(db.connections[-1].readonly)
                    other, other_token = (peer, token) if kick else (db.identity, db.access)
                    self.assertEqual(restarted.lookup(other, operation, OP, payload=payload, access_token=other_token).payload["state"], "not_found")
                    db.state["accounts"][identity.uid][0] = 1
                    with self.assertRaises(RuntimeRejected): restarted.lookup(identity, operation, OP, payload=payload, access_token=access)

    def test_native_provenance_current_target_and_rollback_fail_closed(self):
        for unsupported in ("grants", "index", "cas", "update", "revocation"):
            with self.subTest(unsupported=unsupported):
                db, _, _, membership, peer, token = self.setup_services(provider=unsupported != "grants")
                db.state["meeting_members"][(MID, "peer")] = db.member("peer")
                if unsupported == "index": db.meeting_indexes = db.meeting_indexes[:-1]
                if unsupported == "cas": db.cas_failure = True
                if unsupported == "update": db.fail_contains = "UPDATE clrs_staging.meeting_members"
                if unsupported == "revocation": db.revoke_during_update = True
                before = copy.deepcopy(db.state)
                with self.assertRaises(RuntimeRejected if unsupported == "revocation" else RuntimeUnavailable):
                    membership.leave(peer, OP, PAYLOAD, access_token=token)
                self.assertEqual(db.state, before)
        for raw in ({}, {"fields": {"admin": {"stringValue": "actor"}}}):
            db, _, _, membership, peer, token = self.setup_services()
            db.state["meetings"][MID]["legacy_raw"] = raw
            self.assertEqual(membership.leave(peer, OP, PAYLOAD, access_token=token).payload["result"], {"error": "meeting_not_found"})
        db, store, _, membership, peer, token = self.setup_services()
        db.state["meeting_members"][(MID, "peer")] = db.member("peer")
        left = membership.leave(peer, OP, PAYLOAD, access_token=token)
        # Exact original minimal acknowledgment survives profile onboarding loss.
        db.state["profiles"]["peer"].update(isRegistrationEnd=0, primaryGroup=None)
        self.assertEqual(store.lookup(peer, LEAVE_OPERATION, OP, payload=PAYLOAD, access_token=token).payload["result"], left.payload["result"])
        receipt = db.state["receipts"][("peer", LEAVE_OPERATION, OP)]
        original = receipt[3]; wrapper = json.loads(original); wrapper["response"]["meetingId"] = "other"
        receipt[3] = json.dumps(wrapper)
        with self.assertRaises(RuntimeUnavailable): store.lookup(peer, LEAVE_OPERATION, OP, payload=PAYLOAD, access_token=token)
        receipt[3] = original; db.state["meeting_members"][(MID, "peer")]["legacy_raw"] = {}
        with self.assertRaises(MeetingAccessRejected): store.lookup(peer, LEAVE_OPERATION, OP, payload=PAYLOAD, access_token=token)


if __name__ == "__main__":
    unittest.main()
