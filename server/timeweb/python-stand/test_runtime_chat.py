"""Focused chat semantics using the no-network MySQL-shaped transaction port."""
import copy
import threading
import unittest

from runtime_chat import RuntimeChatService, SEND_OPERATION, READ_OPERATION
from runtime_mutations import RuntimeConflict, RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, request_digest
from test_runtime_mutations import FakeDatabase, store_for


class ChatTests(unittest.TestCase):
    def setUp(self):
        self.db = FakeDatabase(); self.store = store_for(self.db); self.chat = RuntimeChatService(self.store)

    def send(self, operation="send", text="  Привет😀\nКак дела?  ", quote=None):
        return self.chat.send_text(self.db.identity, "chat", operation, text,
                                  quote_message_id=quote, access_token=self.db.access)

    def read(self, operation, sequence):
        return self.chat.mark_read(self.db.identity, "chat", operation, sequence, access_token=self.db.access)

    def test_atomic_send_replay_quote_outbox_and_raw_retained(self):
        raw_before = copy.deepcopy(self.db.state["legacy"])
        first = self.send(); result = first.payload["result"]
        self.assertEqual(first.status, 201); self.assertEqual(result["sequence"], 1)
        self.assertEqual(result["text"], "  Привет😀\nКак дела?  ")
        self.assertEqual(first.payload["entityRevision"], result["chatRevision"])
        self.assertEqual(result["eventIds"], [1, 2]); self.assertEqual(self.db.state["counter"], 2)
        self.assertEqual(self.db.state["members"][("chat", "actor")][0], 0)
        self.assertEqual(len(self.db.state["outbox"]), 1)
        self.assertFalse(any("text" in row[2] for row in self.db.state["outbox"].values()))
        replay = self.send()
        self.assertTrue(replay.payload["replayed"]); self.assertEqual(replay.payload["result"], result)
        self.assertEqual(len(self.db.state["messages"]), 1); self.assertEqual(self.db.state["counter"], 2)
        second = self.send("quoted", "Ответ", result["messageId"]).payload["result"]
        self.assertEqual(second["quote"], {"messageId": result["messageId"], "sequence": 1,
            "senderUid": "actor", "text": result["text"]})
        self.assertEqual(self.db.state["legacy"], raw_before)
        with self.assertRaises(RuntimeConflict):
            self.send("send", "Изменённый текст")

    def test_current_pair_membership_account_and_archived_semantics(self):
        # Actor fixture is already archived. It remains a legitimate member.
        self.assertEqual(self.send().status, 201)
        original = copy.deepcopy(self.db.state)
        for scenario in ("blocked", "disabled", "missing_member", "wrong_pair"):
            self.db.state = copy.deepcopy(original)
            if scenario == "blocked": self.db.state["accounts"]["peer"][1] = "blocked"
            if scenario == "disabled": self.db.state["accounts"]["peer"][0] = 1
            if scenario == "missing_member": del self.db.state["members"][("chat", "peer")]
            if scenario == "wrong_pair": self.db.state["chats"]["chat"][0] = "outsider"
            with self.subTest(scenario=scenario):
                denied = self.send("denied-" + scenario)
                self.assertIn(denied.status, (404, 409))
                self.assertEqual(len(self.db.state["messages"]), 1)
                with self.assertRaises(RuntimeRejected):
                    self.store.lookup(self.db.identity, SEND_OPERATION, "send", access_token=self.db.access,
                        request_hash=request_digest({"chatId": "chat", "text": "  Привет😀\nКак дела?  ", "quoteMessageId": None}))

    def test_quote_same_chat_undeleted_and_notifications_respected(self):
        missing = self.send("missing", "Ответ", "other-chat-message")
        self.assertEqual(missing.payload["result"], {"error": "quote_unavailable"})
        self.assertFalse(self.db.state["messages"])
        first = self.send().payload["result"]
        self.db.state["messages"][("chat", first["messageId"])]["deleted"] = "deleted"
        self.assertEqual(self.send("deleted", "Ответ", first["messageId"]).status, 409)
        self.db.state["members"][("chat", "peer")][1] = 0
        self.send("silent", "Сообщение без уведомления")
        self.assertEqual(len(self.db.state["outbox"]), 1)
        self.assertEqual(self.db.state["counter"], 4)

    def test_read_monotonic_not_ahead_and_does_not_reorder_chat(self):
        self.send("one"); self.send("two")
        updated = self.db.state["chats"]["chat"][4]
        advanced = self.read("read-one", 1)
        self.assertTrue(advanced.payload["result"]["changed"])
        self.assertEqual(advanced.payload["result"]["eventIds"], [5, 6])
        unchanged = self.read("read-older", 0)
        self.assertFalse(unchanged.payload["result"]["changed"])
        self.assertEqual(unchanged.payload["result"]["readThroughSequence"], 1)
        self.assertEqual(unchanged.payload["result"]["eventIds"], [])
        ahead = self.read("read-ahead", 3)
        self.assertEqual(ahead.status, 409); self.assertEqual(ahead.payload["result"], {"error": "sequence_ahead"})
        self.assertEqual(self.db.state["chats"]["chat"][4], updated)
        self.assertEqual(len(self.db.state["outbox"]), 2)
        self.assertEqual(self.db.state["members"][("chat", "actor")][0], 1)
        replay = self.read("read-one", 1)
        self.assertTrue(replay.payload["replayed"]); self.assertEqual(self.db.state["counter"], 6)

    def test_outbox_failure_rolls_back_message_events_counter_and_receipt(self):
        before = copy.deepcopy(self.db.state)
        self.db.fail_contains = "INSERT INTO clrs_staging.outbox"
        with self.assertRaises(RuntimeUnavailable):
            self.send()
        self.assertEqual(self.db.state, before)
        self.assertEqual(self.db.connections[0].commits, 0)

    def test_concurrent_same_and_distinct_operation_ids(self):
        results = []; failures = []; barrier = threading.Barrier(2)
        def send(operation):
            try:
                barrier.wait(); results.append(self.send(operation))
            except Exception as error:
                failures.append(type(error))
        threads = [threading.Thread(target=send, args=("same",)) for _ in range(2)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(2)
        self.assertFalse(failures); self.assertEqual(len(results), 2)
        self.assertEqual(sorted(row.payload["replayed"] for row in results), [False, True])
        self.assertEqual(len(self.db.state["messages"]), 1)
        results.clear(); barrier = threading.Barrier(2)
        threads = [threading.Thread(target=send, args=(operation,)) for operation in ("next-a", "next-b")]
        for thread in threads: thread.start()
        for thread in threads: thread.join(2)
        self.assertFalse(failures)
        self.assertEqual(sorted(row.payload["result"]["sequence"] for row in results), [2, 3])
        self.assertEqual(self.db.state["counter"], 6)

    def test_exact_bounds_original_text_and_no_malformed_preflight_sql(self):
        for text in ("", " \n\t", "\0", "\ud800", "a" * 4097):
            with self.subTest(length=len(text)), self.assertRaises(RuntimeInvalidRequest):
                self.send(text=text)
        for sequence in (True, -1, 2 ** 63, "1"):
            with self.assertRaises(RuntimeInvalidRequest):
                self.read("bad-read", sequence)
        self.assertFalse(self.db.connections)
        valid = self.send("bounded", "😀" * 4096)
        self.assertEqual(len(valid.payload["result"]["text"]), 4096)


if __name__ == "__main__":
    unittest.main()
