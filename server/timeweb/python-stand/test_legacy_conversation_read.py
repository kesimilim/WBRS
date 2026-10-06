"""Scoped offline synthetic tests. No real archive, UID, DB, HTTP or S3."""
import copy
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import threading
import time
import unittest
from unittest.mock import patch

from auth_bridge import AuthenticatedIdentity
from native_sessions import NativeIdentity
from profile_store import BUNDLED_CA_FILE
import legacy_conversation_read as read_module
from legacy_conversation_read import (LegacyConversationReadService,
    LegacyReadRejected, LegacyReadUnavailable, LegacyReadRateLimited, messages_query)
from legacy_conversation_payload import (LegacyInvalid, OpaqueReferences,
    document, message_time, payload_digest, timestamp_ns)

NOW = 1_700_000_000
STAMP = "2023-11-14T22:13:20.000000001Z"
SOURCE = ("synthetic-project", "(default)", "synthetic-bucket.invalid")
PIN = "c" * 64
KEY = bytes([11]) * 32
UID_A = "Synthetic-A"
UID_B = "Synthetic-B"
UID_X = "Synthetic-X"


def s(value):
    return {"stringValue": value}


def array(values):
    return {"arrayValue": {"values": [s(value) for value in values]}}


def payload(fields):
    return {"fields": fields, "createTime": STAMP, "updateTime": STAMP}


def row(path, fields):
    collection, message_id = path.rsplit("/", 1)
    raw = payload(fields)
    return (path, collection, message_id, json.dumps(raw, ensure_ascii=False), bytes.fromhex(payload_digest(raw)))


def identity(uid=UID_A, *, expires=NOW + 900):
    return AuthenticatedIdentity(uid, NOW - 1, NOW - 1, expires)


def enabled():
    return {"CLRS_LEGACY_READ_ENABLED": "1", "CLRS_LEGACY_READ_SNAPSHOT_REVIEWED": "1",
        "CLRS_LEGACY_READ_MEMBERSHIP_MODE": "immutable-reviewed-snapshot",
        "CLRS_LEGACY_READ_SOURCE_SHA256": PIN,
        "CLRS_LEGACY_READ_SOURCE_PROJECT": SOURCE[0], "CLRS_LEGACY_READ_SOURCE_DATABASE": SOURCE[1],
        "CLRS_LEGACY_READ_SOURCE_BUCKET": SOURCE[2],
        "CLRS_LEGACY_READ_DB_URL": "mysql://synthetic:synthetic@synthetic-db.example.invalid/clrs_staging?sslmode=verify-full",
        "CLRS_LEGACY_READ_DB_CA_FILE": str(Path(__file__).parent / "timeweb-ca.pem")}


class FakeSocket:
    def __init__(self):
        self.closed = threading.Event()

    def shutdown(self, *_):
        self.closed.set()

    def close(self):
        self.closed.set()


class FakeDatabase:
    def __init__(self):
        self.documents = {}
        self.accounts = {uid: (uid, 0, "active") for uid in [UID_A, UID_B, UID_X]}
        self.calls = []; self.configs = []; self.connections = []
        self.target = "clrs_staging"; self.source = SOURCE; self.tls = True
        self.extra_grant = False; self.alter_result = None; self.stall = False
        self.require_ssl = False

    def add(self, path, fields):
        self.documents[path] = row(path, fields)

    def connect(self, **config):
        self.configs.append(config)
        connection = FakeConnection(self); self.connections.append(connection)
        return connection

    def service(self, *, env=None, clock=None):
        return LegacyConversationReadService(env or enabled(), KEY, connect=self.connect, clock=clock or (lambda: NOW))

    def base(self):
        self.add("chats/old-room", {"user1": s(UID_A), "user2": s(UID_B)})
        self.add("meets/old-meet", {"type": s("индивидуальная"), "admin": s(UID_A), "users": array([UID_A, UID_B])})

    def message(self, path, *, body="synthetic text", stamp=STAMP, sender=UID_B, extra=None):
        group = "/messages/" in path
        fields = {"message": s(body), "name" if group else "sendBy": s("Synthetic Name"),
            "sender" if group else "sendByID": s(sender),
            "time" if group else "ts": {"timestampValue": stamp}, "isRead": {"booleanValue": False}}
        fields.update(extra or {})
        self.add(path, fields)


class FakeConnection:
    def __init__(self, db):
        self.db = db; self.result = []; self.closed = False; self.rolled_back = False
        self._sock = FakeSocket()

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def close(self):
        self.closed = True; self._sock.close()

    def rollback(self):
        self.rolled_back = True

    def fetchone(self):
        return self.result[0] if self.result else None

    def fetchall(self):
        return self.result

    def execute(self, sql, parameters=()):
        self.db.calls.append((sql, copy.deepcopy(parameters))); self.result = []
        if self.db.stall and sql == "SHOW GRANTS":
            self._sock.closed.wait(0.5)
        if sql == "SHOW GRANTS":
            suffix = " REQUIRE SSL" if self.db.require_ssl else ""
            self.result = [("GRANT USAGE ON *.* TO `legacy`@`%`" + suffix,)] + [
                (f"GRANT SELECT ON `clrs_staging`.`{table}` TO `legacy`@`%`",)
                for table in sorted(read_module.TABLES)]
            if self.db.extra_grant:
                self.result.append(("GRANT SELECT ON `clrs_staging`.`auth_credentials` TO `legacy`@`%`",))
        elif sql == "SELECT DATABASE(), VERSION()":
            self.result = [(self.db.target, "8.4.6")]
        elif sql.startswith("SHOW SESSION STATUS"):
            self.result = [("Ssl_cipher", "TLS_AES_256_GCM_SHA384" if self.db.tls else "")]
        elif sql.startswith("SET ") or sql.startswith("START TRANSACTION "):
            pass
        elif "FROM clrs_staging.legacy_source" in sql:
            self.result = [self.db.source]
        elif "FROM clrs_staging.accounts" in sql:
            self.result = [self.db.accounts[uid] for uid in parameters if uid in self.db.accounts]
        elif "AS bounded_history" in sql:
            collection = parameters[1].decode()
            self.result = [(min(parameters[2], sum(item[1] == collection for item in self.db.documents.values())),)]
        elif "AS history" in sql:
            collection = parameters[1].decode(); time_field = "time" if "/messages" in collection else "ts"
            rows = []
            for item in self.db.documents.values():
                if item[1] == collection:
                    order, _, _ = message_time(document(item[3]), time_field)
                    if len(parameters) == 6 and (order, item[2].encode()) >= (int(parameters[2]), parameters[4]):
                        continue
                    rows.append((*item, Decimal(order)))
            rows.sort(key=lambda item: (item[5], item[2].encode()), reverse=True)
            self.result = rows[:parameters[-1]]
            if self.db.alter_result:
                self.result = self.db.alter_result(self.result)
        elif "FROM clrs_staging.legacy_documents" in sql:
            wanted = set(parameters)
            self.result = [item for path, item in self.db.documents.items() if hashlib.sha256(path.encode()).digest() in wanted]
        else:
            raise AssertionError("Unexpected synthetic SQL")


class CompatibilityReadTests(unittest.TestCase):
    def setUp(self):
        self.db = FakeDatabase(); self.db.base(); self.service = self.db.service()

    def test_absent_ca_uses_bundled_verified_tls_and_bad_explicit_ca_never_connects(self):
        env = enabled(); env.pop("CLRS_LEGACY_READ_DB_CA_FILE")
        with patch("profile_store.ssl.create_default_context", wraps=ssl.create_default_context) as create_context:
            config, _, _ = self.db.service(env=env)._configuration()
            create_context.assert_called_once_with(cafile=BUNDLED_CA_FILE)
        self.assertTrue(Path(BUNDLED_CA_FILE).is_absolute())
        self.assertTrue(config["ssl"].check_hostname)
        self.assertEqual(ssl.CERT_REQUIRED, config["ssl"].verify_mode)
        for value in ["", "relative-ca.pem", "/__clrs_synthetic__/missing-ca.pem"]:
            with self.subTest(value=value):
                env["CLRS_LEGACY_READ_DB_CA_FILE"] = value
                before = len(self.db.configs)
                with self.assertRaises(LegacyReadUnavailable):
                    self.db.service(env=env).personal_messages(identity(), "old-room")
                self.assertEqual(before, len(self.db.configs))

    def test_default_off_and_unverified_or_expired_identity_never_connect(self):
        for value in [UID_A, {"uid": UID_A}, identity(expires=NOW), identity(uid="bad/uid")]:
            with self.assertRaises(LegacyReadRejected):
                self.service.personal_messages(value, "old-room")
        with self.assertRaises(LegacyReadUnavailable):
            self.db.service(env={"unused": "1"}).personal_messages(identity(), "old-room")
        self.assertEqual([], self.db.configs)

    def test_a_b_membership_and_missing_parent_cannot_read_messages(self):
        self.db.message("chats/old-room/chats/one")
        self.assertEqual("one", self.service.personal_messages(identity(), "old-room")["items"][0]["id"])
        self.assertEqual(1, len(self.service.personal_messages(identity(UID_B), "old-room")["items"]))
        before = len([sql for sql, _ in self.db.calls if "AS history" in sql])
        for user, room in [(UID_X, "old-room"), (UID_A, "missing-parent")]:
            with self.assertRaises(LegacyReadRejected):
                self.service.personal_messages(identity(user), room)
        self.assertEqual(before, len([sql for sql, _ in self.db.calls if "AS history" in sql]))

    def test_deleted_counterparty_outside_sender_self_and_duplicate_pairs_preserve_history(self):
        self.db.accounts.pop(UID_B)
        self.db.message("chats/old-room/chats/historical", sender="Historical-No-Auth")
        result = self.service.personal_messages(identity(), "old-room")
        self.assertEqual("Historical-No-Auth", result["items"][0]["senderUid"])
        self.db.add("chats/duplicate", {"user1": s(UID_A), "user2": s(UID_B)})
        self.db.add("chats/self", {"user1": s(UID_A), "user2": s(UID_A)})
        for room in ["duplicate", "self"]:
            self.db.message(f"chats/{room}/chats/separate")
            self.assertEqual("separate", self.service.personal_messages(identity(), room)["items"][0]["id"])

    def test_meeting_member_required_organizer_is_not_created_as_member(self):
        self.db.add("meets/old-meet", {"type": s("индивидуальная"), "admin": s(UID_A), "users": array([UID_B])})
        self.db.message("meets/old-meet/messages/one")
        for uid in [UID_A, UID_X]:
            with self.assertRaises(LegacyReadRejected):
                self.service.meeting_messages(identity(uid), "old-meet")
        self.assertEqual(1, len(self.service.meeting_messages(identity(UID_B), "old-meet")["items"]))
        result = self.service.meeting_participants(identity(), "old-meet")
        self.assertTrue(result["items"][0]["organizer"])
        self.assertFalse(result["items"][0]["member"])

    def test_kicked_and_disabled_current_account_are_denied(self):
        self.db.add("meets/old-meet", {"admin": s(UID_B), "users": array([UID_A, UID_B]), "kicked": array([UID_A])})
        for call in [self.service.meeting_messages, self.service.meeting_participants]:
            with self.assertRaises(LegacyReadRejected):
                call(identity(), "old-meet")
        for account in [(UID_A, 1, "active"), (UID_A, 0, "deleted"), ("case-other", 0, "active")]:
            self.db.accounts[UID_A] = account
            with self.assertRaises(LegacyReadRejected):
                self.service.personal_messages(identity(), "old-room")

    def test_own_removed_history_survives_missing_parent_other_owner_cannot_read_it(self):
        self.db.message(f"users/{UID_A}/removed_meets/missing/messages/archived")
        self.assertEqual("archived", self.service.meeting_messages(identity(), "missing", own_removed=True)["items"][0]["id"])
        self.assertEqual([], self.service.meeting_messages(identity(UID_B), "missing", own_removed=True)["items"])
        with self.assertRaises(LegacyReadRejected):
            self.service.meeting_messages(identity(), "missing")

    def test_keyset_orders_nanoseconds_and_utf8_ids_no_duplicate_on_new_head(self):
        for name in ["a", "A", "Ä", "😀"]:
            self.db.message("chats/old-room/chats/" + name)
        first = self.service.personal_messages(identity(), "old-room", limit=2)
        self.assertEqual(["😀", "Ä"], [item["id"] for item in first["items"]])
        self.db.message("chats/old-room/chats/new", stamp="2023-11-14T22:13:20.000000002Z")
        second = self.service.personal_messages(identity(), "old-room", limit=2, cursor=first["nextCursor"])
        self.assertEqual(["a", "A"], [item["id"] for item in second["items"]])
        self.assertIsNone(second["nextCursor"])
        self.assertTrue(all("OFFSET" not in sql.upper() for sql, _ in self.db.calls))

    def test_cursor_bound_to_uid_resource_source_parent_expiry_and_cipher_domain(self):
        self.db.message("chats/old-room/chats/a"); self.db.message("chats/old-room/chats/b")
        token = self.service.personal_messages(identity(), "old-room", limit=1)["nextCursor"]
        for user in [UID_B, UID_X]:
            with self.assertRaises(LegacyReadRejected):
                self.service.personal_messages(identity(user), "old-room", cursor=token)
        changed = enabled(); changed["CLRS_LEGACY_READ_SOURCE_SHA256"] = "d" * 64
        with self.assertRaises(LegacyReadRejected):
            self.db.service(env=changed).personal_messages(identity(), "old-room", cursor=token)
        with self.assertRaises(LegacyReadRejected):
            self.db.service(clock=lambda: NOW + 301).personal_messages(identity(), "old-room", cursor=token)
        self.db.add("chats/old-room", {"user1": s(UID_A), "user2": s(UID_B), "changed": s("new parent version")})
        with self.assertRaises(LegacyReadRejected):
            self.service.personal_messages(identity(), "old-room", cursor=token)
        with self.assertRaises(LegacyInvalid):
            OpaqueReferences(KEY).open("media", token)

    def test_hidden_messages_advance_source_cursor_and_flags_never_write(self):
        self.db.message("chats/old-room/chats/a")
        self.db.message("chats/old-room/chats/b", extra={"deletedFor": array([UID_A])})
        self.db.message("chats/old-room/chats/c", extra={"deleteFor": s(UID_A)})
        first = self.service.personal_messages(identity(), "old-room", limit=2)
        self.assertEqual([], first["items"]); self.assertIsNotNone(first["nextCursor"])
        second = self.service.personal_messages(identity(), "old-room", limit=2, cursor=first["nextCursor"])
        self.assertEqual(["a"], [item["id"] for item in second["items"]])
        self.assertEqual(False, second["items"][0]["legacyIsRead"])
        self.assertTrue(all(not re_write(sql) for sql, _ in self.db.calls))
        self.assertTrue(self.db.connections[-1].rolled_back)

    def test_quote_gift_and_shared_content_preserved_without_url_download_token_or_raw_map(self):
        url = "https://firebasestorage.googleapis.com/v0/b/synthetic-bucket.invalid/o/pictures%2Fsynthetic.jpg?alt=media&token=synthetic-secret"
        self.db.message("chats/old-room/chats/gift", extra={"image": s("assets/gifts/52.png"), "name": s("Synthetic gift"),
            "giftNoticeName": s("Synthetic gift"), "unrelatedSecret": s("never-return"),
            "replyMessage": {"mapValue": {"fields": {"message": s("quoted text"), "sendBy": s("Past Name"), "secret": s("never-return")}}},
            "sharedContent": {"mapValue": {"fields": {"kind": s("comment"), "postId": s("synthetic-post"),
                "commentId": s("synthetic-comment"), "text": s("shared text"), "imageUrl": s(url), "token": s("never-return")}}}})
        view = self.service.personal_messages(identity(), "old-room")["items"][0]
        self.assertEqual("Synthetic gift", view["giftName"])
        self.assertEqual("assets/gifts/52.png", view["image"]["asset"])
        self.assertEqual("quoted text", view["quote"]["message"]); self.assertIsNone(view["quote"]["messageId"])
        self.assertEqual("quarantined", view["sharedContent"]["image"]["status"])
        encoded = json.dumps(view)
        for secret in ["https://", "synthetic-secret", "imageUrl", "never-return", "pictures/synthetic.jpg"]:
            self.assertNotIn(secret, encoded)
        self.assertFalse(view["sharedContent"]["linkAvailable"])

    def test_external_image_cannot_be_fetched_or_redirected(self):
        for index, url in enumerate(["https://outside.example.invalid/x?token=secret", "https://firebasestorage.googleapis.com.evil.invalid/x", "https://user:secret@firebasestorage.googleapis.com/x"]):
            self.db.message(f"chats/old-room/chats/{index}", extra={"image": s(url)})
        views = self.service.personal_messages(identity(), "old-room")["items"]
        self.assertTrue(all(view["image"]["kind"] == "unavailable" for view in views))
        self.assertNotIn("secret", json.dumps(views))

    def test_participant_group_uses_cyrillic_and_avatar_prefers_thumbnail(self):
        thumbnail = f"https://firebasestorage.googleapis.com/v0/b/{SOURCE[2]}/o/profiles%2Fthumb.jpg?token=do-not-return"
        self.db.add("users/" + UID_B, {"fullName": s("Synthetic participant"),
            "группа": s("cyrillic-group"), "group": s("english-fallback"),
            "profilePicThumb": s(thumbnail), "profilePic": s("https://outside.invalid/not-used")})
        item = next(item for item in self.service.meeting_participants(identity(), "old-meet")["items"] if item["uid"] == UID_B)
        self.assertEqual("cyrillic-group", item["group"])
        self.assertEqual("quarantined", item["avatar"]["status"])
        descriptor = self.service._codec.open("media", item["avatar"]["reference"])
        self.assertEqual("profiles/thumb.jpg", descriptor["path"])
        self.assertEqual(UID_A, descriptor["uid"])
        self.assertNotIn("https://", json.dumps(item))
        self.assertNotIn("do-not-return", json.dumps(item))
        self.db.add("users/" + UID_B, {"fullName": s("Synthetic participant"),
            "group": s("english-fallback"), "profilePic": s(thumbnail)})
        fallback = next(item for item in self.service.meeting_participants(identity(), "old-meet")["items"] if item["uid"] == UID_B)
        self.assertEqual("english-fallback", fallback["group"])
        self.assertEqual("quarantined", fallback["avatar"]["status"])

    def test_participants_profile_whitelist_no_fake_account_and_batched_reads(self):
        self.db.add("meets/old-meet", {"admin": s(UID_A), "users": array([UID_A, UID_B, "Historical-Deleted", "Historical-Missing"])})
        self.db.add("users/" + UID_A, {"uid": s(UID_X), "fullName": s("Public name"), "age": {"integerValue": "32"},
            "email": s("never@example.invalid"), "balance": {"integerValue": "999"},
            "profilePic": s("https://outside.example.invalid/avatar?token=never-return")})
        self.db.add("users/Historical-Deleted", {"fullName": s("Past name"), "deleted": {"booleanValue": True}})
        result = self.service.meeting_participants(identity(), "old-meet")
        self.assertEqual(UID_A, result["items"][0]["uid"])
        self.assertEqual("Public name", result["items"][0]["name"])
        self.assertEqual(32, result["items"][0]["age"])
        self.assertEqual("unavailable", result["items"][0]["avatar"]["kind"])
        states = {item["uid"]: item["profileState"] for item in result["items"]}
        self.assertEqual("legacy_only", states["Historical-Deleted"])
        self.assertEqual("missing_profile", states["Historical-Missing"])
        self.assertNotIn("never@example.invalid", json.dumps(result)); self.assertNotIn("balance", json.dumps(result))
        self.assertEqual(1, sum("accounts WHERE uid IN" in sql for sql, _ in self.db.calls))
        self.assertEqual(1, sum("firebase_path_sha256 IN" in sql for sql, _ in self.db.calls))

    def test_parent_digest_tamper_path_collision_and_message_sort_mismatch_fail_closed(self):
        self.db.message("chats/old-room/chats/one")
        original = self.db.documents["chats/old-room"]
        self.db.documents["chats/old-room"] = (*original[:3], original[3].replace(UID_B, UID_X), original[4])
        with self.assertRaises(LegacyReadUnavailable):
            self.service.personal_messages(identity(), "old-room")
        self.db.documents["chats/old-room"] = original
        for alter in [lambda rows: [(*rows[0][:5], rows[0][5] + 1)],
                      lambda rows: [("chats/wrong/chats/one", *rows[0][1:])]]:
            self.db.alter_result = alter
            with self.assertRaises(LegacyReadUnavailable):
                self.service.personal_messages(identity(), "old-room")

    def test_select_role_tls_source_and_staging_guards(self):
        for attribute, value in [("extra_grant", True), ("tls", False), ("target", "default_db"), ("source", ("other", SOURCE[1], SOURCE[2]))]:
            before = len([sql for sql, _ in self.db.calls if "AS history" in sql])
            old = getattr(self.db, attribute); setattr(self.db, attribute, value)
            with self.assertRaises(LegacyReadUnavailable):
                self.service.personal_messages(identity(), "old-room")
            setattr(self.db, attribute, old)
            self.assertEqual(before, len([sql for sql, _ in self.db.calls if "AS history" in sql]))
        config = self.db.configs[0]
        self.assertEqual(ssl.CERT_REQUIRED, config["ssl"].verify_mode); self.assertTrue(config["ssl"].check_hostname)
        self.assertEqual((2, 2, 2), (config["connect_timeout"], config["read_timeout"], config["write_timeout"]))

    def test_require_ssl_is_accepted_only_on_global_usage_without_expanding_read_role(self):
        self.db.require_ssl = True
        self.assertEqual([], self.service.personal_messages(identity(), "old-room")["items"])
        rows = [("GRANT USAGE ON *.* TO `legacy`@`%` REQUIRE SSL",)] + [
            (f"GRANT SELECT ON `clrs_staging`.`{table}` TO `legacy`@`%`",)
            for table in sorted(read_module.TABLES)]
        self.service._grants(rows)
        for index, bad in [
            (0, rows[0][0] + " WITH GRANT OPTION"),
            (0, rows[0][0].replace("REQUIRE SSL", "REQUIRE X509")),
            (0, rows[0][0].replace("USAGE", "SELECT")),
            (1, rows[1][0] + " REQUIRE SSL"),
            (1, rows[1][0].replace("SELECT", "SELECT, UPDATE")),
            (1, rows[1][0].replace("`clrs_staging`.`accounts`", "`clrs_staging`.*")),
        ]:
            with self.subTest(grant=index):
                altered = list(rows); altered[index] = (bad,)
                with self.assertRaises(LegacyReadUnavailable):
                    self.service._grants(altered)

    def test_bounds_response_document_history_and_invalid_limits(self):
        for limit in [0, 51, True, "2"]:
            with self.assertRaises(LegacyReadRejected):
                self.service.personal_messages(identity(), "old-room", limit=limit)
        self.assertEqual([], self.db.configs)
        self.db.message("chats/old-room/chats/big", body="x" * 131_073)
        with self.assertRaises(LegacyReadUnavailable):
            self.service.personal_messages(identity(), "old-room")
        self.db.documents.pop("chats/old-room/chats/big")
        for index in range(4):
            self.db.message(f"chats/old-room/chats/{index}", body="x" * 70_000)
        with self.assertRaises(LegacyReadUnavailable):
            self.service.personal_messages(identity(), "old-room")
        with patch.object(read_module, "MAX_HISTORY", 2):
            with self.assertRaises(LegacyReadUnavailable):
                self.service.personal_messages(identity(), "old-room")

    def test_absolute_deadline_closes_socket_and_no_late_result(self):
        self.db.stall = True
        start = time.monotonic()
        with patch.object(read_module, "REQUEST_SECONDS", 0.04):
            with self.assertRaises(LegacyReadUnavailable):
                self.service.personal_messages(identity(), "old-room")
        self.assertLess(time.monotonic() - start, 0.3)
        self.assertTrue(self.db.connections[-1]._sock.closed.is_set())
        self.assertTrue(self.db.connections[-1].closed)

    def test_native_identity_accepted_and_inflight_slots_released_on_all_errors(self):
        native = NativeIdentity(UID_A, True, "synthetic-session", NOW - 1, NOW + 900)
        self.assertEqual([], self.service.personal_messages(native, "old-room")["items"])
        held = []
        try:
            for _ in range(read_module.MAX_INFLIGHT):
                self.assertTrue(read_module._SLOTS.acquire(blocking=False)); held.append(1)
            with self.assertRaises(LegacyReadUnavailable):
                self.service.personal_messages(identity(), "old-room")
        finally:
            for _ in held:
                read_module._SLOTS.release()
        self.assertEqual([], self.service.personal_messages(identity(), "old-room")["items"])

    def test_per_uid_rate_limit_is_bounded_and_requests_do_not_borrow_other_uid(self):
        self.service._limiter.consume("legacy-uid", UID_A, 1)
        for _ in range(59):
            self.service._limiter.consume("legacy-uid", UID_A, 60)
        with self.assertRaises(LegacyReadRateLimited):
            self.service.personal_messages(identity(), "old-room")
        self.assertEqual([], self.db.configs)
        self.assertEqual([], self.service.personal_messages(identity(UID_B), "old-room")["items"])

    def test_own_notifications_preference_is_retained_without_other_members_flags(self):
        self.db.add("chats/old-room", {"user1": s(UID_A), "user2": s(UID_B), "usersWOutNotifications": array([UID_B])})
        self.assertFalse(self.service.personal_messages(identity(), "old-room")["notificationsMuted"])
        self.assertTrue(self.service.personal_messages(identity(UID_B), "old-room")["notificationsMuted"])

    def test_integer_milliseconds_and_create_time_fallback_never_use_now(self):
        raw = payload({"ts": {"integerValue": "1700000000000"}})
        self.assertEqual((1700000000000000000, "2023-11-14T22:13:20.000Z", "ts_legacy_milliseconds"), message_time(raw, "ts"))
        raw = payload({"ts": {"integerValue": "1700000000"}})
        self.assertEqual("document_create_time", message_time(raw, "ts")[2])
        self.assertEqual(timestamp_ns(STAMP), message_time(raw, "ts")[0])

    def test_node_payload_hash_cross_language_boundaries_and_sql_driver_escaping(self):
        executable = os.environ.get("CLRS_TEST_NODE_BIN") or shutil.which("node")
        self.assertIsNotNone(executable, "Node is required for cross-language hash proof")
        raw = {"😀": 1e-7, "\ue000": 1e21, "10": 1.0, "2": -0.0, "01": 1e-6,
            "text": "control\nquote\"/🕊", "numbers": [1e20, 1.2345e-7, -1e-8, 1.0000000000000001e18],
            "bool": True, "null": None}
        script = "import {payloadHash} from './server/timeweb/import-core.mjs';let raw='';for await(const s of process.stdin)raw+=s;process.stdout.write(payloadHash(JSON.parse(raw)));"
        result = subprocess.run([executable, "--input-type=module", "-e", script],
            input=json.dumps(raw), text=True, capture_output=True, check=True, timeout=10,
            cwd=Path(__file__).resolve().parents[3])
        self.assertEqual(result.stdout, payload_digest(raw))
        import pymysql
        connection = pymysql.connect(defer_connect=True, charset="utf8mb4")
        connection.server_status = 0  # Driver quoting only; never open a socket.
        earlier = "1700000000000000001"; later = "1700000000000000002"
        self.assertEqual(float(earlier), float(later))  # Real DOUBLE collision.
        self.assertLess(Decimal(earlier), Decimal(later))
        sql = connection.cursor().mogrify(messages_query("ts", after=True), (bytes([1]) * 32,
            "chats/synthetic/chats".encode(), later, later, "Ä".encode(), 3))
        self.assertIn("'%Y-%m-%dT%H:%i:%s'", sql); self.assertNotIn("%%Y", sql)
        self.assertIn("CAST(document_id AS BINARY)", sql); self.assertNotIn("OFFSET", sql)
        self.assertEqual(2, sql.count("CAST('1700000000000000002' AS DECIMAL(30,0))"))


def re_write(sql):
    return sql.strip().split(" ", 1)[0].upper() in {"INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "COMMIT"}


if __name__ == "__main__":
    unittest.main()
