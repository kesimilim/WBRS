"""Current reads on new mutation data via an isolated no-TCP transaction port."""
import copy
import json
import unittest
from unittest.mock import patch

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
                row = (chat_id, low, high, updated, last, revision, ml[0], mh[0], ml[1], mh[1],
                    int(ml[2] is not None), int(mh[2] is not None), "Имя собеседника")
                if "LEFT JOIN clrs_staging.chat_messages AS preview" in sql:
                    candidates = [(message_id, message) for (message_chat, message_id), message in state["messages"].items()
                        if message_chat == chat_id and message["deleted"] is None and message["sequence"] <= last]
                    latest = max(candidates, key=lambda value: value[1]["sequence"]) if candidates else None
                    if latest is None:
                        row += (None, None, None, None, None, 1, None)
                    else:
                        message_id, message = latest; body = message["body"]
                        within_size = body is None or (len(body) <= 4096 and len(body.encode("utf-8", errors="surrogatepass")) <= 16384)
                        excerpt = body[:160] if body is not None and "LEFT(preview.body, 160)" in sql else body
                        row += (chat_id, message_id, message["sequence"], message["sender"],
                                excerpt if within_size else None, int(within_size), message["deleted"])
                rows.append(row)
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

    def chats(self, **kwargs):
        return self.reads.own_chats(self.db.identity, access_token=self.db.access, **kwargs)

    def test_chat_preview_opt_in_latest_canonical_message_one_query_and_old_shape(self):
        self.send("first", "Исходное сообщение")
        self.send("second", "Последнее сообщение\nвторая строка")
        base = self.chats()["items"][0]
        self.assertEqual(len(base), 10)
        self.assertNotIn("lastMessage", base)
        before = copy.deepcopy(self.db.state); self.db.calls.clear()
        commits = sum(c.commits for c in self.db.connections)
        preview = self.chats(include_preview=True)["items"][0]
        self.assertEqual(len(preview), 12)
        self.assertEqual({key: preview[key] for key in base}, base)
        self.assertEqual(preview["lastMessage"], "Последнее сообщение\nвторая строка")
        self.assertEqual(preview["lastMessageSenderUid"], "actor")
        query = [(sql, params) for sql, params in self.db.calls if sql.startswith("SELECT c.chat_id")]
        self.assertEqual(len(query), 1)
        self.assertIn("LEFT JOIN clrs_staging.chat_messages AS preview", query[0][0])
        self.assertIn("recent.sequence <= c.last_sequence", query[0][0])
        self.assertIn("preview.deleted_at IS NULL", query[0][0])
        self.assertIn("FOR SHARE OF c, ml, mh, al, ah, preview", query[0][0])
        self.assertFalse(any(sql.startswith("SELECT m.chat_id") for sql, _ in self.db.calls))
        self.assertEqual(sum(c.commits for c in self.db.connections), commits)
        self.assertEqual(self.db.state, before)

    def test_chat_preview_skips_deleted_future_and_foreign_chat_rows(self):
        first = self.send("first", "Правильный текст")
        latest = self.send("latest", "Удалённый текст")
        self.db.state["messages"][("chat", latest["messageId"])]["deleted"] = "deleted"
        self.db.state["messages"][("chat", "future")] = {
            "sequence": 3, "sender": "peer", "body": "Будущий текст", "deleted": None}
        self.db.state["messages"][("foreign-chat", "foreign")] = {
            "sequence": 100, "sender": "peer", "body": "Другой чат", "deleted": None}
        preview = self.chats(include_preview=True)["items"][0]
        self.assertEqual(preview["lastMessage"], "Правильный текст")
        original = self.db.state["messages"][("chat", first["messageId"])]
        original["sender"] = "peer"
        self.assertEqual(self.chats(include_preview=True)["items"][0]["lastMessageSenderUid"], "peer")
        original["sender"] = "foreign-account"
        with self.assertRaises(RuntimeUnavailable):
            self.chats(include_preview=True)

    def test_chat_preview_empty_null_text_deleted_and_malformed_body(self):
        self.db.state["chats"]["chat"][4] = None
        empty = self.chats(include_preview=True)["items"][0]
        self.assertIsNone(empty["lastMessage"]); self.assertIsNone(empty["lastMessageSenderUid"])
        sent = self.send("empty")
        message = self.db.state["messages"][("chat", sent["messageId"])]
        message["body"] = None
        value = self.chats(include_preview=True)["items"][0]
        self.assertIsNone(value["lastMessage"]); self.assertEqual(value["lastMessageSenderUid"], "actor")
        for body in ("x" * 4097, "😀" * 4097, "forbidden\x00", "\ud800"):
            message["body"] = body
            with self.subTest(body_length=len(body)), self.assertRaises(RuntimeUnavailable):
                self.chats(include_preview=True)
        message["body"] = "😀" * 4096
        self.assertEqual(self.chats(include_preview=True)["items"][0]["lastMessage"], message["body"][:160])
        message["deleted"] = "deleted"
        value = self.chats(include_preview=True)["items"][0]
        self.assertIsNone(value["lastMessage"]); self.assertIsNone(value["lastMessageSenderUid"])

    def test_chat_preview_bad_join_rows_fail_closed_and_no_partial_preview(self):
        self.send("one")
        fetchall = ReadCursor.fetchall
        for index, value in ((13, "foreign-chat"), (14, ""), (15, 2), (15, True),
                             (16, "foreign-account"), (17, 42), (18, 0), (18, True),
                             (19, "deleted"), (13, None)):
            def damaged(cursor):
                rows = fetchall(cursor)
                if rows and len(rows[0]) == 20:
                    row = list(rows[0]); row[index] = value; rows[0] = row
                return rows
            with self.subTest(index=index, value=value), patch.object(ReadCursor, "fetchall", damaged):
                with self.assertRaises(RuntimeUnavailable):
                    self.chats(include_preview=True)

    def test_chat_preview_rechecks_native_session_and_current_pair_without_cache(self):
        self.send("one")
        self.assertEqual(len(self.chats(include_preview=True)["items"]), 1)
        execute = ReadCursor.execute
        def revoke(cursor, statement, params=()):
            result = execute(cursor, statement, params)
            if "LEFT JOIN clrs_staging.chat_messages AS preview" in statement:
                cursor.c.state["accounts"]["actor"][2] += 1
            return result
        with patch.object(ReadCursor, "execute", revoke), self.assertRaises(RuntimeRejected):
            self.chats(include_preview=True)
        self.assertEqual(len(self.chats(include_preview=True)["items"]), 1)
        del self.db.state["members"][("chat", "peer")]
        self.assertEqual(self.chats(include_preview=True)["items"], [])

    def test_chat_preview_cursor_preserves_order_bounded_excerpt_and_existing_scope(self):
        self.db.state["chats"]["chat"][4] = None
        for chat_id in ("A", "B", "C"):
            self.db.state["chats"][chat_id] = ["actor", "peer", 1, 1, STAMP]
            for uid in ("actor", "peer"):
                self.db.state["members"][(chat_id, uid)] = [0, 1, None]
            self.db.state["messages"][(chat_id, "message")] = {
                "sequence": 1, "sender": "peer", "body": "😀" * 4096, "deleted": None}
        seen = []; cursor = None
        while True:
            page = self.chats(include_preview=True, limit=3, cursor=cursor)
            self.assertLessEqual(len(canonical_json(page)), 65536)
            seen.extend(item["chatId"] for item in page["items"])
            self.assertTrue(all(item["lastMessage"] in (None, "😀" * 160) for item in page["items"]))
            cursor = page["nextCursor"]
            if cursor is None: break
        self.assertEqual(seen, ["A", "B", "C", "chat"])
        first = self.chats(include_preview=True, limit=2)
        with self.assertRaises(RuntimeInvalidRequest):
            self.chats(include_preview=True, limit=1, cursor=first["nextCursor"])
        for value in (1, "1", None):
            with self.subTest(include_preview=value), self.assertRaises(RuntimeInvalidRequest):
                self.chats(include_preview=value)

    def test_chat_preview_fifty_full_valid_bodies_fit_in_one_bounded_excerpt_page(self):
        self.db.state["chats"].clear(); self.db.state["members"].clear()
        original = "😀" * 4096
        for index in range(50):
            chat_id = f"chat-{index:03}"
            self.db.state["chats"][chat_id] = ["actor", "peer", 1, 1, STAMP]
            for uid in ("actor", "peer"):
                self.db.state["members"][(chat_id, uid)] = [0, 1, None]
            self.db.state["messages"][(chat_id, "message")] = {
                "sequence": 1, "sender": "peer", "body": original, "deleted": None}
        before = copy.deepcopy(self.db.state)
        page = self.chats(include_preview=True, limit=50)
        self.assertEqual(len(page["items"]), 50)
        self.assertIsNone(page["nextCursor"])
        self.assertLessEqual(len(canonical_json(page)), 65536)
        self.assertTrue(all(item["lastMessage"] == original[:160] for item in page["items"]))
        self.assertEqual(self.db.state, before)

    def test_chat_preview_http_real_reader_changes_only_opt_in_response_and_never_writes(self):
        from runtime_read_http import RuntimeReadHttp
        self.send("one", "Канонический текст")
        class Native:
            def authorize(native, token, *, peer):
                self.assertEqual(token, self.db.access)
                return self.db.identity
        adapter = RuntimeReadHttp(ENV, self.store, read_factory=lambda *_: self.reads,
                                  people_factory=lambda *_: None)
        environ = {"PATH_INFO": "/v1/runtime/chats", "REQUEST_METHOD": "GET",
                   "HTTP_AUTHORIZATION": "Bearer " + self.db.access,
                   "QUERY_STRING": "includePreview=1&limit=10", "CONTENT_LENGTH": "0"}
        before = copy.deepcopy(self.db.state)
        commits = sum(c.commits for c in self.db.connections)
        preview = adapter.dispatch(environ, native_service=Native(), native_configured=True)
        self.assertEqual(preview.status, "200 OK")
        self.assertEqual(len(preview.payload["items"][0]), 12)
        self.assertEqual(preview.payload["items"][0]["lastMessage"], "Канонический текст")
        environ["QUERY_STRING"] = "limit=10"
        original = adapter.dispatch(environ, native_service=Native(), native_configured=True)
        self.assertEqual(original.status, "200 OK")
        self.assertEqual(len(original.payload["items"][0]), 10)
        self.assertEqual(sum(c.commits for c in self.db.connections), commits)
        self.assertEqual(self.db.state, before)

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
        self.store.close()
        self.assertTrue(all(c.closed for c in self.db.connections))


if __name__ == "__main__":
    unittest.main()
