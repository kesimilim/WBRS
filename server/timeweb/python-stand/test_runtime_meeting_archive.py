"""One scoped archive proof: shared real session/receipt transactions, no TCP."""
import copy
import json
import unittest

from runtime_http import RuntimeMutationHttp
from runtime_meeting_archive import validate_archive_page
from runtime_meeting_chat import RuntimeMeetingChatService, MESSAGE_ORIGIN, _message_id
from runtime_meeting_create import (MEMBER_ORIGIN, member_archive_window, native_origin_sql,
    _check, _meeting as created_meeting)
from runtime_meeting_join import RuntimeMeetingJoinService
from runtime_meeting_membership import RuntimeMeetingMembershipService, LEAVE_OPERATION
from runtime_meetings import RuntimeMeetingsService, TRUSTED_POLICY, MEMBER_FIELDS
from runtime_mutations import RuntimeMutationStore, RuntimeUnavailable, RuntimeCommitUnknown, RuntimeInvalidRequest, request_digest, canonical_json
from runtime_reads import RuntimeReadRejected
from test_runtime_meeting_chat import MessageCursor, _INDEX_PARTS, KEY
from test_runtime_meeting_membership import MembershipCursor, MembershipDatabase, MID, PAYLOAD, KICK, SECOND, THIRD, FOURTH
from test_runtime_meeting_create import REQUEST
from test_runtime_http import Native, env, OP, ENV as HTTP_ENV
from test_runtime_mutations import NOW, STAMP


class ArchiveCursor(MessageCursor, MembershipCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); db = self.c.db; state = self.c.state
        own_profile = sql.startswith("SELECT p.uid FROM clrs_staging.profiles AS p")
        window = sql.startswith("SELECT DATE_FORMAT(mm.joined_at")
        exact_sequence = "FROM clrs_staging.meeting_messages AS mm" in sql and "mm.sequence = %s" in sql
        if not (own_profile or window or exact_sequence):
            result = super().execute(statement, params)
            if db.revoke_on_page and "mm.sequence <= %s" in sql:
                state["accounts"][db.read_owner][0] = 1
            return result
        assert self.c.held
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if own_profile:
            assert params[0] == params[1] and sql.endswith("FOR SHARE OF p")
            db.read_owner = params[0]
            if params[0] in state["profiles"]:
                self.rows = [(params[0],)]
        elif window:
            assert params[:2] == (MID, MID) and params[2] == params[3] and sql.endswith("FOR SHARE OF mm")
            row = state["meeting_members"].get((MID, params[2]))
            if row:
                raw = row["legacy_raw"].get("archiveWindow")
                self.rows = [(row["joinedAt"], row["membershipRevision"], json.dumps(raw) if raw is not None else None)]
        else:
            assert params[:2] == (MID, MID) and sql.endswith("FOR SHARE OF mm")
            rows = [row for row in state["meeting_messages"].values() if row["sequence"] == params[2]]
            self.rows = [(row["meetingId"], row["messageId"], row["sequence"], row["senderUid"], row["text"], row["createdAt"],
                int(row["media_id"] is None), int(row["legacy_raw"] == {"origin": MESSAGE_ORIGIN})) for row in rows]
        return len(self.rows)


class ArchiveDatabase(MembershipDatabase):
    def __init__(self, **options):
        super().__init__(**options)
        self.state["meeting_members"][(MID, "peer")] = self.member("peer")
        self.state["meeting_messages"] = {}; self.revoke_on_page = False; self.read_owner = None

    def connect(self, **config):
        connection = super().connect(**config); connection.cursor = lambda: ArchiveCursor(connection)
        return connection

    def services(self, clock=lambda: NOW):
        store = RuntimeMutationStore(self.env, self.tokens, connect=self.connect, clock=lambda: NOW)
        return store, RuntimeMeetingJoinService(store, clock=clock), RuntimeMeetingMembershipService(store, clock=clock), RuntimeMeetingsService(store, KEY, trusted_policy=TRUSTED_POLICY, clock=clock)

    def add_messages(self, count, text="  Исходный текст\n"):
        for sequence in range(len(self.state["meeting_messages"]) + 1, count + 1):
            mid = _message_id(MID, "actor", f"12345678-1234-4234-8234-{sequence:012x}")
            self.state["meeting_messages"][(MID, mid)] = {"meetingId": MID, "messageId": mid, "sequence": sequence,
                "senderUid": "actor", "text": text, "createdAt": STAMP, "media_id": None, "legacy_raw": {"origin": MESSAGE_ORIGIN}}
        self.state["meetings"][MID]["revision"] = count


class NativeArchiveTests(unittest.TestCase):
    def setup_archive(self, **options):
        db = ArchiveDatabase(**options); peer, token = db.peer_identity()
        store, join, membership, reader = db.services(); self.addCleanup(store.close)
        return db, store, join, membership, reader, peer, token

    def http(self, db, store, join, membership, reader, peer, token):
        native = Native(); native.identity = peer
        adapter = RuntimeMutationHttp(HTTP_ENV, service_factory=lambda _: (store, None, None, None, None, join, None, membership), meetings_factory=lambda shared, _: reader if shared is store else self.fail("Different store"))
        def call(query="", **extra):
            return adapter.dispatch(env(f"/v1/runtime/meetings/{MID}/archived-messages", REQUEST_METHOD="GET", QUERY_STRING=query,
                HTTP_AUTHORIZATION="Bearer " + token, **extra), native_service=native, native_configured=True)
        return call

    def test_atomic_cutoff_exact_tail_future_messages_rejoin_and_kick_keep_archive_only(self):
        for individual in (False, True):
            with self.subTest(individual=individual):
                db, store, join, membership, reader, peer, token = self.setup_archive(individual=individual)
                db.add_messages(4); before_joined = db.state["meeting_members"][(MID, "peer")]["joinedAt"]
                result = membership.leave(peer, OP, PAYLOAD, access_token=token)
                self.assertEqual(set(result.payload["result"]), {"meetingId", "left", "alreadyLeft", "membershipRevision", "leftAt"})
                window = db.state["meeting_members"][(MID, "peer")]["legacy_raw"]["archiveWindow"]
                self.assertEqual(window, {"throughSequence": 4, "capturedAt": STAMP, "operationId": OP, "membershipRevision": 1})
                db.add_messages(5)
                call = self.http(db, store, join, membership, reader, peer, token)
                archived = call("limit=30")
                self.assertEqual(archived.status, "200 OK"); self.assertEqual(archived.payload["archiveWindow"], window)
                self.assertEqual([row["sequence"] for row in archived.payload["items"]], [4, 3, 2, 1])
                self.assertEqual(set(archived.payload), {"kind", "meetingId", "archiveWindow", "ordering", "items", "nextCursor", "mediaReady"})
                self.assertTrue(all(set(row) == {"meetingId", "messageId", "sequence", "senderUid", "text", "createdAt"} for row in archived.payload["items"]))
                with self.assertRaises(RuntimeReadRejected): reader.messages(peer, MID, access_token=token)
                rejoined = join.join(peer, OP, PAYLOAD, access_token=token)
                self.assertEqual(rejoined.payload["result"]["membershipRevision"], 2)
                self.assertEqual(db.state["meeting_members"][(MID, "peer")]["legacy_raw"]["archiveWindow"], window)
                self.assertEqual(db.state["meeting_members"][(MID, "peer")]["joinedAt"], before_joined)
                membership.kick(db.identity, OP, KICK, access_token=db.access)
                self.assertEqual(db.state["meeting_members"][(MID, "peer")]["legacy_raw"]["archiveWindow"], window)
                self.assertEqual([item["sequence"] for item in call().payload["items"]], [4, 3, 2, 1])
                with self.assertRaises(RuntimeReadRejected): reader.messages(peer, MID, access_token=token)
                self.assertEqual(store.lookup(peer, LEAVE_OPERATION, OP, payload=PAYLOAD, access_token=token).payload["result"], result.payload["result"])
                # Current profile existence is enough; search presence is not required.
                db.state["profiles"]["peer"].update(isRegistrationEnd=0, primaryGroup=None)
                self.assertEqual(call().status, "200 OK")
                self.assertFalse(any("removed_meeting_messages" in sql or "DELETE" in sql for sql, _ in db.calls))
                self.assertEqual(len(MEMBER_FIELDS), 7)

    def test_empty_window_no_retrofill_owner_binding_and_native_prepost_revocation(self):
        db, store, join, membership, reader, peer, token = self.setup_archive()
        call = self.http(db, store, join, membership, reader, peer, token)
        missing = call(); self.assertEqual((missing.status, missing.payload, missing.authenticate), ("404 Not Found", {"error": "archive_unavailable"}, False))
        membership.leave(peer, OP, PAYLOAD, access_token=token); db.add_messages(1)
        empty = call(); self.assertEqual((empty.status, empty.payload["items"], empty.payload["nextCursor"], empty.payload["archiveWindow"]["throughSequence"]), ("200 OK", [], None, 0))
        with self.assertRaises(RuntimeReadRejected): reader.archived_messages(db.identity, MID, access_token=db.access)
        db.state["meeting_members"][(MID, "peer")]["legacy_raw"] = {"origin": MEMBER_ORIGIN}
        membership.leave(peer, SECOND, PAYLOAD, access_token=token)
        self.assertEqual(call().status, "404 Not Found")  # Already-left never retrofills from current tail.
        db.state["meeting_members"][(MID, "peer")]["legacy_raw"] = {"origin": MEMBER_ORIGIN,
            "archiveWindow": {"throughSequence": 0, "capturedAt": STAMP, "operationId": OP, "membershipRevision": 1}}
        db.state["profiles"].pop("peer"); self.assertEqual(call().status, "404 Not Found")
        db.state["profiles"]["peer"] = copy.deepcopy(db.state["profiles"]["actor"]); db.state["profiles"]["peer"]["uid"] = "peer"
        db.revoke_on_page = True; denied = call()
        self.assertEqual((denied.status, denied.authenticate), ("401 Unauthorized", True))
        db.revoke_on_page = False; db.state["accounts"]["peer"][0] = 1
        denied = call(); self.assertEqual((denied.status, denied.authenticate), ("401 Unauthorized", True))

    def test_cursor_whole_messages_original_expiry_and_window_replacement_rejects_old_cursor(self):
        db, store, join, membership, reader, peer, token = self.setup_archive()
        db.add_messages(6, "😀" * 4096); membership.leave(peer, OP, PAYLOAD, access_token=token)
        first = reader.archived_messages(peer, MID, limit=30, access_token=token)
        self.assertEqual([row["sequence"] for row in first["items"]], [6, 5, 4]); self.assertLessEqual(len(canonical_json(first)), 65536)
        opaque = first["nextCursor"]; claim = reader._codec.open("cursor", opaque)
        self.assertEqual((claim["window"], claim["uid"], claim["meetingId"], claim["limit"], claim["exp"]), (first["archiveWindow"], "peer", MID, 30, NOW + 300))
        for patch in ({"uid": "actor"}, {"meetingId": "another"}, {"limit": 1}, {"purpose": "meeting_messages_sequence_desc"}, {"exp": NOW}, {"exp": NOW+301}):
            with self.subTest(patch=patch), self.assertRaises(RuntimeInvalidRequest):
                reader.archived_messages(peer, MID, cursor=reader._codec.seal("cursor", {**claim, **patch}), access_token=token)
        reader._clock = lambda: NOW + 100
        second = reader.archived_messages(peer, MID, cursor=opaque, access_token=token)
        self.assertEqual([row["sequence"] for row in second["items"]], [3, 2, 1]); self.assertIsNone(second["nextCursor"])
        self.assertTrue(all(len(row["text"]) == 4096 for row in second["items"]))
        reader._clock = lambda: NOW + 301
        with self.assertRaises(RuntimeInvalidRequest): reader.archived_messages(peer, MID, cursor=opaque, access_token=token)
        reader._clock = lambda: NOW
        join.join(peer, OP, PAYLOAD, access_token=token); db.add_messages(7, "😀" * 4096)
        membership.leave(peer, SECOND, PAYLOAD, access_token=token)
        with self.assertRaises(RuntimeInvalidRequest): reader.archived_messages(peer, MID, cursor=opaque, access_token=token)
        fresh = reader.archived_messages(peer, MID, access_token=token)
        self.assertEqual((fresh["archiveWindow"]["operationId"], fresh["archiveWindow"]["throughSequence"], fresh["archiveWindow"]["membershipRevision"]), (SECOND, 7, 3))

    def test_unknown_commit_original_lookup_proves_window_and_failure_rolls_back_all(self):
        for committed in (False, True):
            with self.subTest(committed=committed):
                db, store, _, membership, reader, peer, token = self.setup_archive(); db.add_messages(2)
                if committed: db.commit_unknown_once = True
                else: db.before_commit = lambda: (_ for _ in ()).throw(OSError("lost before commit"))
                with self.assertRaises(RuntimeCommitUnknown): membership.leave(peer, OP, PAYLOAD, access_token=token)
                updates = sum(sql.startswith("UPDATE clrs_staging.meeting_members") for sql, _ in db.calls)
                store.close(); db.before_commit = None
                restored, _, _, archived = db.services(); self.addCleanup(restored.close)
                lookup = restored.lookup(peer, LEAVE_OPERATION, OP, payload=PAYLOAD, access_token=token)
                self.assertEqual(lookup.payload["state"], "committed" if committed else "not_found")
                if committed: self.assertEqual([row["sequence"] for row in archived.archived_messages(peer, MID, access_token=token)["items"]], [2, 1])
                else:
                    with self.assertRaises(RuntimeReadRejected): archived.archived_messages(peer, MID, access_token=token)
                self.assertEqual(sum(sql.startswith("UPDATE clrs_staging.meeting_members") for sql, _ in db.calls), updates)
        for fail in ("cas", "indexes", "tail", "receipt"):
            db, _, _, membership, _, peer, token = self.setup_archive(); db.add_messages(1)
            if fail == "cas": db.cas_failure = True
            if fail == "indexes": db.message_indexes = db.message_indexes[:-1]
            if fail == "tail": next(iter(db.state["meeting_messages"].values()))["legacy_raw"] = {}
            if fail == "receipt": db.fail_contains = "UPDATE clrs_staging.idempotency_receipts"
            before = copy.deepcopy(db.state)
            with self.subTest(fail=fail), self.assertRaises(RuntimeUnavailable): membership.leave(peer, OP, PAYLOAD, access_token=token)
            self.assertEqual(db.state, before)

    def test_strict_marker_window_types_dates_future_revision_and_original_owner_receipt(self):
        window = {"throughSequence": 0, "capturedAt": STAMP, "operationId": OP, "membershipRevision": 1}
        self.assertIsNone(member_archive_window({"origin": MEMBER_ORIGIN}, 0, STAMP, STAMP))
        sql = native_origin_sql("mm", member=True)
        for bound in ("JSON_LENGTH(mm.legacy_raw) = 1 OR", "JSON_LENGTH(mm.legacy_raw) = 2", "$.archiveWindow", "$.operationId", "$.capturedAt", "DECIMAL(20,0)", "mm.membership_revision", "UTC_TIMESTAMP(6)", "LAST_DAY"):
            self.assertIn(bound, sql)
        bad = [{**window, "extra": None}, {**window, "throughSequence": True}, {**window, "throughSequence": -1}, {**window, "throughSequence": 2**63},
            {**window, "membershipRevision": 2}, {**window, "membershipRevision": 1.0}, {**window, "operationId": OP.upper()},
            {**window, "capturedAt": "2027-02-30T08:00:00.000001Z"}, {**window, "capturedAt": "2027-01-15T08:00:00Z"},
            {**window, "capturedAt": "2027-01-15T08:00:01.000001Z"}]
        for value in bad:
            with self.subTest(value=value), self.assertRaises(RuntimeUnavailable):
                member_archive_window({"origin": MEMBER_ORIGIN, "archiveWindow": value}, 1, STAMP, STAMP)
        for raw in ({}, {"fields": {}}, {"origin": MEMBER_ORIGIN, "archiveWindow": window, "other": False}):
            with self.assertRaises(RuntimeUnavailable): member_archive_window(raw, 1, STAMP, STAMP)
        db, store, _, membership, reader, peer, token = self.setup_archive(); membership.leave(peer, OP, PAYLOAD, access_token=token)
        member = db.state["meeting_members"][(MID, "peer")]
        member["legacy_raw"]["archiveWindow"]["operationId"] = THIRD
        with self.assertRaises(RuntimeReadRejected): reader.archived_messages(peer, MID, access_token=token)
        member["legacy_raw"]["archiveWindow"]["operationId"] = OP
        receipt = db.state["receipts"][("peer", LEAVE_OPERATION, OP)]; original = receipt[3]
        wrapper = json.loads(original); wrapper["response"]["membershipRevision"] = 0; receipt[3] = json.dumps(wrapper)
        with self.assertRaises(RuntimeReadRejected): reader.archived_messages(peer, MID, access_token=token)
        receipt[3] = original
        # Owner's window cannot borrow another actor's original receipt.
        db.state["receipts"][("actor", LEAVE_OPERATION, OP)] = copy.deepcopy(receipt)
        with self.assertRaises(RuntimeReadRejected): reader.archived_messages(db.identity, MID, access_token=db.access)

    def test_native_creator_marker_proof_after_rejoin_and_http_whitelist(self):
        db, store, join, membership, reader, peer, token = self.setup_archive(); db.add_messages(1)
        membership.leave(db.identity, OP, PAYLOAD, access_token=db.access)
        join.join(db.identity, OP, PAYLOAD, access_token=db.access)
        store.read_authenticated(db.identity, lambda cursor, execute, uid: _check(cursor, execute, uid, REQUEST,
            created_meeting(cursor, execute, MID, readonly=True), OP, readonly=True) or {"checked": True}, access_token=db.access)
        call = self.http(db, store, join, membership, reader, db.identity, db.access)
        for query in ("ownerUid=peer", "limit=31", "limit=1&limit=2", "cursor=x%2Fy", "scope=group"):
            self.assertEqual(call(query).status, "400 Bad Request")
        self.assertEqual(call(CONTENT_LENGTH="1").status, "400 Bad Request")
        self.assertEqual(call().status, "200 OK")
        malformed = {"kind": "canonical-current", "meetingId": MID, "archiveWindow": {"throughSequence": 0, "capturedAt": STAMP, "operationId": OP, "membershipRevision": 1},
            "ordering": "sequence_desc", "items": [], "nextCursor": "opaque", "mediaReady": False}
        with self.assertRaises(RuntimeUnavailable): validate_archive_page(malformed, MID, 30)


if __name__ == "__main__":
    unittest.main()
