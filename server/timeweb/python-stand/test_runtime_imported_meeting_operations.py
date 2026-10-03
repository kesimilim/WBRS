"""One actual shared-store scenario; synthetic final source/SQL, no TCP."""
import copy
from datetime import datetime, timezone
import hmac
import json
import unittest

from imported_meeting_authority import (load_imported_authority, reviewed_message,
    source_fingerprint, digest, OPERATIONS_DOMAIN, POLICY, MAX_BYTES)
from legacy_conversation_payload import payload_digest
from runtime_imported_meetings import RuntimeImportedMeetingsService
from runtime_meeting_chat import RuntimeMeetingChatService, MESSAGE_ORIGIN, SEND_OPERATION, _message_id
from runtime_meeting_join import RuntimeMeetingJoinService, JOIN_OPERATION
from runtime_meeting_membership import RuntimeMeetingMembershipService, LEAVE_OPERATION, KICK_OPERATION
from runtime_mutations import RuntimeMutationStore, RuntimeUnavailable, RuntimeCommitUnknown, request_digest, canonical_json
from runtime_reads import RuntimeReadRejected
from test_imported_meeting_authority import root_payload, SHA
from test_runtime_meeting_chat import MessageDatabase, MessageCursor, KEY
from test_runtime_meeting_membership import MembershipCursor
from test_runtime_meeting_join import MID
from test_runtime_mutations import NOW, STAMP
from test_runtime_http import OP

SIGNING = b"synthetic-final-message-cohort-key!"
SECOND = "12345678-1234-4234-8234-123456789abd"
THIRD = "12345678-1234-4234-8234-123456789abe"
FOURTH = "12345678-1234-4234-8234-123456789abf"
FIFTH = "12345678-1234-4234-8234-123456789ac0"


class ImportedCursor(MessageCursor, MembershipCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); state = self.c.state; db = self.c.db
        root = sql.startswith("SELECT m.meeting_id, CASE WHEN OCTET_LENGTH")
        member = sql.startswith("SELECT mm.meeting_id, mm.uid, CASE WHEN OCTET_LENGTH")
        message = sql.startswith("SELECT mm.meeting_id, mm.message_id, CASE WHEN OCTET_LENGTH")
        overlay = "meeting_archive_windows" in sql
        revision = sql.startswith("UPDATE clrs_staging.meetings SET revision")
        select_message = sql.startswith("SELECT mm.meeting_id, mm.message_id, mm.sequence")
        owner = sql.startswith("SELECT p.uid FROM clrs_staging.profiles")
        if not any((root, member, message, overlay, revision, select_message, owner)):
            return super().execute(statement, params)
        assert self.c.held; db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if root or member or message:
            alias = "m" if root else "mm"; assert sql.endswith("FOR SHARE OF " + alias)
            step = 2 if root else 4
            assert 1 <= params[-1] <= 31 and len(params) == step * params[-1] + 1
            for offset in range(0, len(params) - 1, step):
                mid = params[offset]; assert mid == params[offset + 1] == MID
                if root:
                    row = state["meetings"].get(mid); key = (mid,)
                else:
                    other = params[offset + 2]; assert other == params[offset + 3]
                    row = state["meeting_members" if member else "meeting_messages"].get((mid, other)); key = (mid, other)
                if row: self.rows.append((*key, copy.deepcopy(row["legacy_raw"])))
        elif overlay:
            if "information_schema" in sql:
                self.rows = [("PRIMARY", 0, 1, "meeting_id", "A", None, "utf8mb4_0900_bin"),
                    ("PRIMARY", 0, 2, "uid", "A", None, "utf8mb4_0900_bin"),
                    ("meeting_archive_windows_operation_uq", 0, 1, "uid", "A", None, "utf8mb4_0900_bin"),
                    ("meeting_archive_windows_operation_uq", 0, 2, "operation_id", "A", None, "ascii_bin")]
            elif sql.startswith("SELECT"):
                assert params[0] == params[1] == MID and params[2] == params[3]
                assert sql.endswith("FOR SHARE OF w") or not self.c.readonly and sql.endswith("FOR UPDATE")
                row = state["windows"].get((MID, params[2])); self.rows = [] if row is None else [row]
            elif sql.startswith("INSERT"):
                assert not self.c.readonly; mid, uid, op, rev, cap, stamp, binding = params
                assert (mid, uid) not in state["windows"]
                state["windows"][(mid, uid)] = (mid, uid, op, rev, cap, stamp.replace(" ", "T") + "Z", binding); self.rowcount = 1
            else:
                assert not self.c.readonly
                op, rev, cap, stamp, binding, mid, exact, uid, exact_uid, old = params
                assert mid == exact == MID and uid == exact_uid and state["windows"][(mid, uid)][3] == old
                state["windows"][(mid, uid)] = (mid, uid, op, rev, cap, stamp.replace(" ", "T") + "Z", binding); self.rowcount = 1
        elif revision:
            assert not self.c.readonly
            rev, stamp, mid, exact, old = params; assert mid == exact == MID and state["meetings"][mid]["revision"] == old
            assert rev >= old + 1 and rev >= max(row["sequence"] for row in state["meeting_messages"].values())
            state["meetings"][mid].update(revision=rev, updatedAt=STAMP); self.rowcount = 1
        elif owner:
            assert params[0] == params[1] and sql.endswith("FOR SHARE OF p")
            if params[0] in state["profiles"]: self.rows = [(params[0],)]
        elif select_message:
            assert params[0] == params[1] == MID and sql.endswith("FOR SHARE OF mm")
            rows = sorted(state["meeting_messages"].values(), key=lambda row: row["sequence"], reverse=True)
            if "mm.message_id = %s" in sql:
                assert params[2] == params[3]; rows = [row for row in rows if row["messageId"] == params[2]]
            elif "mm.sequence = %s" in sql: rows = [row for row in rows if row["sequence"] == params[2]]
            elif "mm.sequence <= %s" in sql:
                rows = [row for row in rows if row["sequence"] <= params[2]]
                if "mm.sequence < %s" in sql: rows = [row for row in rows if row["sequence"] < params[3]]
                rows = rows[:params[-1]]
            else: rows = rows[:1]
            self.rows = [(row["meetingId"], row["messageId"], row["sequence"], row["senderUid"], row["text"], row["createdAt"],
                int(row["media_id"] is None), int(row["legacy_raw"] == {"origin": MESSAGE_ORIGIN})) for row in rows]
        return self.rowcount or len(self.rows)


class ImportedDatabase(MessageDatabase):
    def __init__(self):
        super().__init__(); self.cas_failure = False; self.revoke_during_update = False; self.state["windows"] = {}
        row = self.state["meetings"][MID]; raw = root_payload(users=("actor",))
        for field, key in (("admin", "organizerUid"), ("name", "title"), ("description", "description")):
            raw["fields"][field] = {"stringValue": row[key]}
        row["legacy_raw"] = raw; row["localDatetime"] = raw["fields"]["datetime"]["stringValue"]
        self.state["meeting_members"] = {(MID, "actor"): self.member("actor", joinedAt=None, legacy_raw={
            "source_path": "meets/" + MID, "source_index": 0, "source_field": "users", "source_payload_hash": payload_digest(raw)})}
        child = {"fields": {"sender": {"stringValue": "actor"}, "message": {"stringValue": "Исходный текст"},
            "time": {"timestampValue": STAMP}, "type": {"stringValue": "text"}}, "createTime": STAMP, "updateTime": STAMP}
        self.state["meeting_messages"] = {(MID, "old-source-id"): {"meetingId": MID, "messageId": "old-source-id", "sequence": 1,
            "senderUid": "actor", "text": "Исходный текст", "createdAt": STAMP, "media_id": None, "legacy_raw": child}}
        from runtime_meetings import MEETING_FIELDS
        entry = {"meetingId": MID, "firebasePath": "meets/" + MID, "payloadSha256": payload_digest(raw),
            "metadataReviewSha256": SHA("2"), "sourceContract": "reviewed-imported-meets-v1",
            "canonical": {key: row[key] for key in (*MEETING_FIELDS[:12], "localDatetime")},
            "users": ["actor"], "kicked": [], "missingKickedReviewed": False,
            "messages": [reviewed_message(MID, "old-source-id", child, 1)]}
        final = [[MID, entry["payloadSha256"]]]; tombstones = ["source-deleted"]
        binding = {"generation": SHA("1"), "sourceSha256": source_fingerprint(), "cohortSha256": digest({"meetings": [entry], "tombstones": tombstones}),
            "policy": POLICY, "barrierSha256": SHA("3"), "finalDeltaSha256": SHA("4")}
        self.body = {"v": 2, "kind": "imported-meeting-final-authority", "namespace": {"project": "chatapp-4e347", "database": "(default)", "collection": "meets"},
            "binding": binding, "barrier": {"enforced": True, "allWritersStopped": True, "verified": True, "receiptSha256": SHA("3"),
                "writerSetSha256": SHA("5"), "enforcementSha256": SHA("6"), "verifiedAt": STAMP, "generation": SHA("1")},
            "finalDelta": {"consistent": True, "final": True, "complete": True, "readbackVerified": True, "receiptSha256": SHA("4"),
                "barrierSha256": SHA("3"), "rootSetSha256": digest(final), "tombstonesSha256": digest(tombstones),
                "completedAt": STAMP, "messageSetSha256": digest([[MID, entry["messages"][0]]])},
            "issuedAt": STAMP, "finalRoots": final, "tombstones": tombstones, "meetings": [entry]}
        self.authority = self.load(self.body)

    @staticmethod
    def load(body):
        raw = canonical_json(body, max_bytes=MAX_BYTES)
        return load_imported_authority(raw, hmac.digest(SIGNING, OPERATIONS_DOMAIN + raw, "sha256"), SIGNING,
            reviewed_binding=body["binding"], clock=lambda: datetime.fromtimestamp(NOW + 1, timezone.utc))

    def connect(self, **config):
        connection = super().connect(**config); connection.cursor = lambda: ImportedCursor(connection); return connection

    def services(self):
        store = RuntimeMutationStore(self.env, self.tokens, connect=self.connect, clock=lambda: NOW)
        args = {"imported_authority": self.authority, "reviewed_binding": self.body["binding"], "clock": lambda: NOW}
        reads = RuntimeImportedMeetingsService(store, KEY, authority=self.authority, reviewed_binding=self.body["binding"], clock=lambda: NOW)
        return store, RuntimeMeetingJoinService(store, **args), RuntimeMeetingChatService(store, **args), RuntimeMeetingMembershipService(store, **args), reads


class ImportedMeetingOperationTests(unittest.TestCase):
    def test_actual_store_source_join_chat_unknown_leave_archive_rejoin_and_kick(self):
        db = ImportedDatabase(); peer, token = db.peer_identity(); store, join, chat, membership, reads = db.services(); self.addCleanup(store.close)
        source_root = copy.deepcopy(db.state["meetings"][MID]["legacy_raw"])
        source_member = copy.deepcopy(db.state["meeting_members"][(MID, "actor")]["legacy_raw"])
        source_child = copy.deepcopy(db.state["meeting_messages"][(MID, "old-source-id")])
        joined = join.join(peer, OP, {"meetingId": MID}, access_token=token)
        self.assertEqual(joined.payload["result"]["alreadyMember"], False)
        self.assertEqual(join.join(peer, OP, {"meetingId": MID}, access_token=token).payload["result"], joined.payload["result"])
        first = reads.messages(peer, MID, limit=1, access_token=token)
        self.assertEqual((first["chatRevision"], first["items"][0]["messageId"]), (1, "old-source-id"))
        sent = chat.send_text(peer, MID, SECOND, "Новое сообщение", access_token=token)
        self.assertEqual((sent.payload["result"]["sequence"], sent.payload["entityRevision"]), (2, 2))
        self.assertEqual(sent.payload["result"]["messageId"], _message_id(MID, "peer", SECOND))
        db.commit_unknown_once = True
        with self.assertRaises(RuntimeCommitUnknown): membership.leave(db.identity, THIRD, {"meetingId": MID}, access_token=db.access)
        store.close(); store, join, chat, membership, reads = db.services(); self.addCleanup(store.close)
        original = store.lookup(db.identity, LEAVE_OPERATION, THIRD, request_hash=request_digest({"meetingId": MID}), access_token=db.access)
        self.assertEqual((original.payload["state"], original.payload["result"]["membershipRevision"]), ("committed", 1))
        self.assertEqual(store.lookup(peer, LEAVE_OPERATION, THIRD, payload={"meetingId": MID}, access_token=token).payload["state"], "not_found")
        with self.assertRaises(RuntimeReadRejected): reads.messages(db.identity, MID, access_token=db.access)
        archived = reads.archived_messages(db.identity, MID, limit=1, access_token=db.access)
        self.assertEqual(archived["archiveWindow"]["throughSequence"], 2)
        older = reads.archived_messages(db.identity, MID, limit=1, cursor=archived["nextCursor"], access_token=db.access)
        self.assertEqual(older["items"][0]["messageId"], "old-source-id")
        join.join(db.identity, FOURTH, {"meetingId": MID}, access_token=db.access)
        chat.send_text(db.identity, MID, FIFTH, "После возвращения", access_token=db.access)
        self.assertEqual(reads.archived_messages(db.identity, MID, access_token=db.access)["items"][0]["sequence"], 2)
        kicked = membership.kick(db.identity, "12345678-1234-4234-8234-123456789ac1", {"meetingId": MID, "targetUid": "peer"}, access_token=db.access)
        self.assertTrue(kicked.payload["result"]["kicked"])
        self.assertEqual(join.join(peer, "12345678-1234-4234-8234-123456789ac2", {"meetingId": MID}, access_token=token).payload["result"], {"error": "meeting_unavailable"})
        with self.assertRaises(RuntimeReadRejected): reads.messages(peer, MID, access_token=token)
        self.assertEqual(db.state["meetings"][MID]["legacy_raw"], source_root)
        self.assertEqual(db.state["meeting_members"][(MID, "actor")]["legacy_raw"], source_member)
        self.assertIsNone(db.state["meeting_members"][(MID, "actor")]["joinedAt"])
        self.assertEqual(db.state["meeting_messages"][(MID, "old-source-id")], source_child)
        self.assertEqual(sum(sql.startswith("INSERT INTO clrs_staging.meeting_messages") for sql, _ in db.calls), 2)
        self.assertEqual(sum(sql.startswith("INSERT INTO clrs_staging.meeting_archive_windows") for sql, _ in db.calls), 1)
        wrong = copy.deepcopy(db.body); wrong["barrier"]["allWritersStopped"] = False
        with self.assertRaises(RuntimeUnavailable): db.load(wrong)
        wrong = copy.deepcopy(db.body); wrong["meetings"][0]["messages"][0]["sequence"] = 2
        wrong["binding"]["cohortSha256"] = digest({"meetings": wrong["meetings"], "tombstones": wrong["tombstones"]})
        wrong["finalDelta"]["messageSetSha256"] = digest([[MID, wrong["meetings"][0]["messages"][0]]])
        with self.assertRaises(RuntimeUnavailable): db.load(wrong)
        fake = {**db.state["meeting_members"][(MID, "actor")], "joinedAt": STAMP, "trusted": 0}
        self.assertEqual(db.authority.member(fake, {"origin": "clrs-native-meeting-member-v1"})["trusted"], 0)
        db.state["meeting_messages"][(MID, "old-source-id")]["legacy_raw"]["fields"]["message"] = {"stringValue": "Подмена"}
        with self.assertRaises(RuntimeUnavailable): reads.archived_messages(db.identity, MID, access_token=db.access)


if __name__ == "__main__": unittest.main()
