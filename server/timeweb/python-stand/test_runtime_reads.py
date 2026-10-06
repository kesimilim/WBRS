"""Current reads on new mutation data via an isolated no-TCP transaction port."""
import copy
import json
import unittest

from runtime_reads import RuntimeReadService, RuntimeReadRejected, CHAT_ORDER, chats_query
from runtime_chat import RuntimeChatService
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from test_runtime_mutations import (FakeDatabase, FakeConnection, FakeCursor, ENV, STAMP, NOW,
                                   store_for)


def stamp(value):
    return value if value is None or "T" in value else value.replace(" ", "T") + "Z"


class ReadDatabase(FakeDatabase):
    def connect(self, **config):
        connection = ReadConnection(self); self.connections.append(connection); return connection


class ReadConnection(FakeConnection):
    def cursor(self):
        return ReadCursor(self)


class ReadCursor(FakeCursor):
    def allowed(self, chat_id, uid):
        state = self.c.state; chat = state["chats"].get(chat_id)
        if not chat or uid not in chat[:2] or chat[0] == chat[1]: return False
        members = {member for (chat, member) in state["members"] if chat == chat_id}
        return members == set(chat[:2]) and all(
            state["accounts"].get(member, [1, "missing"])[:2] == [0, "active"] for member in chat[:2])

    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); state = self.c.state
        if sql.startswith("SELECT c.chat_id, c.uid_low"):
            self.c.db.calls.append((sql, params)); uid = params[0]
            rows = []
            for chat_id, chat in state["chats"].items():
                if not self.allowed(chat_id, uid): continue
                low, high, last, revision, updated = chat
                updated = stamp(updated)
                if "c.updated_at < CAST" in sql:
                    anchor_stamp = stamp(params[3]); anchor_id = params[5]
                    if updated is not None and not (updated < anchor_stamp or (updated == anchor_stamp and chat_id.encode() > anchor_id.encode())): continue
                elif "AND c.updated_at IS NULL AND" in sql:
                    if updated is not None or chat_id.encode() <= params[3].encode(): continue
                ml, mh = state["members"][(chat_id, low)], state["members"][(chat_id, high)]
                rows.append((chat_id, low, high, updated, last, revision, ml[0], mh[0], ml[1], mh[1],
                    int(ml[2] is not None), int(mh[2] is not None), "Имя собеседника"))
            rows.sort(key=lambda row: row[0].encode())
            rows.sort(key=lambda row: row[3] or "", reverse=True)
            self.rows = rows[:params[-1]]; self.rowcount = len(self.rows); return self.rowcount
        if sql.startswith("SELECT m.chat_id, m.message_id"):
            self.c.db.calls.append((sql, params)); rows = []
            for (chat_id, message_id), message in state["messages"].items():
                if chat_id != params[0] or message["deleted"] is not None: continue
                if "AND m.sequence < %s" in sql and message["sequence"] >= params[1]: continue
                quote_id = message["quote"]; quote = state["messages"].get((chat_id, quote_id))
                if quote and quote["deleted"] is not None: quote = None
                if not quote: quote_id = None
                rows.append((chat_id, message_id, message["sequence"], message["sender"], message["body"],
                    stamp(message["created"]), quote_id, None if not quote else quote["sequence"],
                    None if not quote else quote["sender"], None if not quote else quote["body"], 1, 1))
            rows.sort(key=lambda row: row[2], reverse=True)
            self.rows = rows[:params[-1]]; self.rowcount = len(self.rows); return self.rowcount
        if sql.startswith("SELECT e.event_id, e.event_kind"):
            self.c.db.calls.append((sql, params)); rows = []
            for event, (audience, kind, payload) in sorted(state["events"].items()):
                if audience != params[0] or event <= params[1] or kind not in {"chat.message.created.v1", "chat.read.updated.v1"}: continue
                chat_id = payload.get("chatId")
                if not self.allowed(chat_id, params[0]): continue
                chat = state["chats"][chat_id]
                rows.append((event, kind, json.dumps(payload), STAMP, chat_id, *chat[:4]))
            self.rows = rows[:params[-1]]; self.rowcount = len(self.rows); return self.rowcount
        return super().execute(statement, params)


class RuntimeReadTests(unittest.TestCase):
    def setUp(self):
        self.db = ReadDatabase(); self.store = store_for(self.db)
        self.chat = RuntimeChatService(self.store)
        self.reads = RuntimeReadService(self.store, bytes(range(32)), clock=lambda: NOW)

    def send(self, op, text="Текст", quote=None):
        return self.chat.send_text(self.db.identity, "chat", op, text,
            quote_message_id=quote, access_token=self.db.access).payload["result"]

    def messages(self, **kwargs):
        return self.reads.messages(self.db.identity, "chat", access_token=self.db.access, **kwargs)

    def test_new_post_write_messages_quotes_and_sequence_pages(self):
        first = self.send("one", "Первое😀")
        second = self.send("two", "Второе", first["messageId"])
        third = self.send("three", "Третье")
        page = self.messages(limit=2)
        self.assertEqual([item["sequence"] for item in page["items"]], [3, 2])
        self.assertEqual(page["nextBeforeSequence"], 2)
        self.assertEqual(page["items"][1]["quote"], second["quote"])
        self.assertEqual(set(page["items"][0]), {"chatId", "messageId", "sequence", "senderUid", "text", "quote", "createdAt"})
        rest = self.messages(limit=2, before_sequence=page["nextBeforeSequence"])
        self.assertEqual([item["sequence"] for item in rest["items"]], [1])
        self.assertIsNone(rest["nextBeforeSequence"])
        self.assertEqual(page["chatRevision"], third["chatRevision"])

    def test_deleted_message_and_deleted_quote_are_not_exposed(self):
        first = self.send("one"); second = self.send("two", "Ответ", first["messageId"])
        self.db.state["messages"][("chat", first["messageId"])]["deleted"] = "deleted"
        page = self.messages()
        self.assertEqual([item["messageId"] for item in page["items"]], [second["messageId"]])
        self.assertIsNone(page["items"][0]["quote"])

    def test_current_member_counterpart_account_proof_and_archive_semantics(self):
        self.send("one")
        self.assertEqual(len(self.messages()["items"]), 1)  # archived actor remains member
        before = copy.deepcopy(self.db.state)
        for kind in ("member", "blocked", "disabled", "foreign"):
            self.db.state = copy.deepcopy(before)
            if kind == "member": del self.db.state["members"][("chat", "peer")]
            if kind == "blocked": self.db.state["accounts"]["peer"][1] = "blocked"
            if kind == "disabled": self.db.state["accounts"]["peer"][0] = 1
            if kind == "foreign": self.db.state["chats"]["chat"][0] = "foreign"
            with self.subTest(kind=kind), self.assertRaises(RuntimeReadRejected): self.messages()
            self.assertEqual(self.reads.own_chats(self.db.identity, access_token=self.db.access)["items"], [])
            self.assertEqual(self.reads.own_events(self.db.identity, access_token=self.db.access)["items"], [])
        self.db.state = before; self.db.state["accounts"]["actor"][2] += 1
        with self.assertRaises(RuntimeRejected): self.messages()

    def test_recent_chat_order_equal_microseconds_nulls_and_opaque_cursor(self):
        self.db.state["chats"]["chat"][4] = None
        for chat_id, updated in (("A", STAMP), ("z", STAMP), ("older", "2027-01-15T08:00:00.000000Z"), ("null-last", None)):
            self.db.state["chats"][chat_id] = ["actor", "peer", 0, 0, updated]
            for uid in ("actor", "peer"): self.db.state["members"][(chat_id, uid)] = [0, 1, None]
        seen = []; cursor = None
        while True:
            page = self.reads.own_chats(self.db.identity, limit=2, cursor=cursor, access_token=self.db.access)
            self.assertEqual(page["ordering"], CHAT_ORDER)
            seen.extend(item["chatId"] for item in page["items"])
            cursor = page["nextCursor"]
            if cursor is None: break
        self.assertEqual(seen, ["A", "z", "older", "chat", "null-last"])
        first = self.reads.own_chats(self.db.identity, limit=2, access_token=self.db.access)
        with self.assertRaises(RuntimeInvalidRequest):
            self.reads.own_chats(self.db.identity, limit=1, cursor=first["nextCursor"], access_token=self.db.access)
        wrong = self.reads._codec.seal("cursor", {"v": 1, "uid": "other", "purpose": CHAT_ORDER,
            "limit": 2, "after": [STAMP, "A"], "exp": NOW + 300})
        with self.assertRaises(RuntimeInvalidRequest):
            self.reads.own_chats(self.db.identity, limit=2, cursor=wrong, access_token=self.db.access)
        self.assertIn("CAST(%s AS DATETIME(6))", chats_query([STAMP, "A"]))

    def test_byte_budget_preserves_whole_text_quote_and_last_emitted_anchor(self):
        first = self.send("one", "😀" * 4096)
        self.send("two", "😀" * 4096, first["messageId"])
        self.send("three", "😀" * 4096, first["messageId"])
        page = self.messages(limit=100)
        self.assertEqual(len(page["items"]), 1)
        self.assertEqual(page["nextBeforeSequence"], 3)
        self.assertEqual(page["items"][0]["text"], "😀" * 4096)
        self.assertEqual(page["items"][0]["quote"]["text"], "😀" * 4096)
        self.assertLessEqual(len(canonical_json(page)), 65536)
        second = self.messages(limit=100, before_sequence=page["nextBeforeSequence"])
        self.assertEqual([item["sequence"] for item in second["items"]], [2, 1])
        self.assertIsNone(second["nextBeforeSequence"])

    def test_own_event_descriptors_safe_fields_pagination_and_no_arbitrary_payload(self):
        self.send("one")
        self.chat.mark_read(self.db.identity, "chat", "read", 1, access_token=self.db.access)
        page = self.reads.own_events(self.db.identity, limit=1, access_token=self.db.access)
        self.assertEqual(page["items"][0]["eventId"], 1)
        self.assertIsNone(page["items"][0]["readerUid"])
        following = self.reads.own_events(self.db.identity, limit=1,
            after_event_id=page["nextAfterEventId"], access_token=self.db.access)
        self.assertEqual(following["items"][0]["eventId"], 3)
        self.assertEqual(following["items"][0]["readerUid"], "actor")
        self.assertIsNone(following["items"][0]["messageId"])
        self.db.state["events"][5] = ("actor", "private.unknown.kind", {"chatId": "chat", "secret": "hidden"})
        self.assertEqual(len(self.reads.own_events(self.db.identity, access_token=self.db.access)["items"]), 2)
        self.db.state["events"][1][2]["arbitrary"] = "hidden"
        with self.assertRaises(RuntimeUnavailable):
            self.reads.own_events(self.db.identity, access_token=self.db.access)

    def test_historical_nullable_text_and_date_no_media_url_or_raw_fields(self):
        sent = self.send("one")
        message = self.db.state["messages"][("chat", sent["messageId"])]
        message["body"] = None; message["created"] = None
        message["raw"] = {"url": "https://example.invalid/private?token=secret"}
        view = self.messages()["items"][0]
        self.assertIsNone(view["text"]); self.assertIsNone(view["createdAt"])
        self.assertNotIn("url", json.dumps(view)); self.assertNotIn("raw", view)

    def test_default_off_limits_and_reads_do_not_commit_or_write(self):
        self.assertIsNone(RuntimeReadService.from_env(self.store, {}))
        for method, kwargs in ((self.reads.own_chats, {"limit": 101}),
                               (self.reads.own_events, {"after_event_id": True}),
                               (self.reads.messages, {"chat_id": "chat", "before_sequence": 0})):
            with self.assertRaises(RuntimeInvalidRequest): method(self.db.identity, access_token=self.db.access, **kwargs)
        self.assertFalse(self.db.connections)
        self.send("one"); commits = sum(c.commits for c in self.db.connections)
        self.messages(); self.reads.own_chats(self.db.identity, access_token=self.db.access)
        self.reads.own_events(self.db.identity, access_token=self.db.access)
        self.assertEqual(sum(c.commits for c in self.db.connections), commits)
        self.assertTrue(all(c.closed for c in self.db.connections))


if __name__ == "__main__":
    unittest.main()
