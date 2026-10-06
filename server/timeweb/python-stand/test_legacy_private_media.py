"""Synthetic offline media checks: no real UID, archive, SQL, S3 or files."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import legacy_private_media as media
from legacy_private_media import LegacyPrivateMediaService, target_key
from legacy_conversation_read import LegacyReadRejected, LegacyReadUnavailable, LegacyReadRateLimited
from legacy_conversation_payload import document, media_reference
from test_legacy_conversation_read import (FakeConnection, FakeDatabase, KEY,
    NOW, PIN, SOURCE, UID_A, UID_B, UID_X, array, enabled, identity, row, s)
from private_media_s3 import PrivateMediaS3
from test_private_media_s3 import BUCKET as TARGET_BUCKET, OWNER, Port, Reply

DATA = b"\x89PNG\r\n\x1a\n" + b"synthetic image fixture" * 7000
PATH = "synthetic-images/one.png"
URL = "gs://" + SOURCE[2] + "/" + PATH
SHA = hashlib.sha256(DATA).digest()


class MediaDatabase(FakeDatabase):
    def __init__(self):
        super().__init__(); self.base()
        self.storage = (SOURCE[2], PATH, json.dumps({"contentType": "image/png"}),
            len(DATA), SHA, target_key(SOURCE[0], SOURCE[2], PATH), SHA, "synthetic-copied-at")
        self.ready = (UID_B, "message", self.storage[5], "image/png", len(DATA), SHA, "ready", PATH)
        self.grants_override = None

    def connect(self, **config):
        self.configs.append(config)
        connection = MediaConnection(self); self.connections.append(connection)
        return connection


class MediaConnection(FakeConnection):
    def execute(self, sql, parameters=()):
        if sql == "SHOW GRANTS":
            self.db.calls.append((sql, copy.deepcopy(parameters)))
            self.result = (self.db.grants_override if self.db.grants_override is not None else
                [("GRANT USAGE ON *.* TO `media`@`%` REQUIRE SSL",)] + [
                    (f"GRANT SELECT ON `clrs_staging`.`{name}` TO `media`@`%`",)
                    for name in sorted(media.TABLES)])
        elif "FROM clrs_staging.legacy_storage_objects" in sql:
            self.db.calls.append((sql, copy.deepcopy(parameters)))
            self.result = [self.db.storage] if self.db.storage is not None else []
        elif "FROM clrs_staging.media_objects" in sql:
            self.db.calls.append((sql, copy.deepcopy(parameters)))
            self.result = [self.db.ready] if self.db.ready is not None else []
        elif "FROM clrs_staging.legacy_documents" in sql and "collection_path_sha256 = %s" in sql:
            self.db.calls.append((sql, copy.deepcopy(parameters)))
            collection = parameters[1].decode(); candidates = []
            for item in self.db.documents.values():
                fields = document(item[3])["fields"]
                if item[1] != collection:
                    continue
                if collection == "chats":
                    a = fields.get("user1", {}).get("stringValue")
                    b = fields.get("user2", {}).get("stringValue")
                    if (a, b) not in [(parameters[2].decode(), parameters[3].decode()),
                            (parameters[4].decode(), parameters[5].decode())]:
                        continue
                else:
                    owner = fields.get("admin", {}).get("stringValue")
                    users = fields.get("users", {}).get("arrayValue", {}).get("values", [])
                    if (owner != parameters[2].decode() or not (owner == parameters[3].decode()
                            or {"stringValue": parameters[4]} in users)):
                        continue
                candidates.append(item)
            self.result = candidates[:parameters[-1]]
        else:
            super().execute(sql, parameters)


class FakeS3:
    def __init__(self):
        self.calls = []; self.data = DATA; self.after = None; self.fail = False

    def get_verified_to_file(self, record, sink, *, deadline, cancel):
        self.calls.append(copy.deepcopy(record))
        sink.write(self.data)
        if self.after:
            self.after()
        if self.fail:
            raise ValueError("synthetic connector failure must stay private")
        sink.seek(0)


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(); os.chmod(self.dir.name, 0o700)
        self.addCleanup(self.dir.cleanup)
        self.db = MediaDatabase(); self.s3 = FakeS3(); self.now = NOW; self.mono = 100.0
        self.env = {**enabled(), "CLRS_LEGACY_MEDIA_ENABLED": "1",
            "CLRS_LEGACY_MEDIA_PROMOTION_REVIEWED": "1",
            "CLRS_LEGACY_MEDIA_PROMOTION_MODE": "reviewed-immutable-object-alias",
            "CLRS_LEGACY_MEDIA_S3_USER_MODE": "dedicated-read-only",
            "CLRS_LEGACY_MEDIA_FULL_READBACK_SOURCE_SHA256": PIN,
            "CLRS_LEGACY_MEDIA_DB_URL": enabled()["CLRS_LEGACY_READ_DB_URL"],
            "CLRS_LEGACY_MEDIA_DB_CA_FILE": enabled()["CLRS_LEGACY_READ_DB_CA_FILE"],
            "CLRS_LEGACY_MEDIA_SPOOL_DIR": self.dir.name}
        self.service = self.make_service()
        self.db.message("chats/old-room/chats/photo", extra={"image": s(URL)})

    def make_service(self, env=None):
        return LegacyPrivateMediaService(env or self.env, KEY, private_s3=self.s3,
            connect=self.db.connect, clock=lambda: self.now, monotonic=lambda: self.mono)

    def reference(self, *, purpose="messages", collection="chats/old-room/chats",
            parent=None, extras=None, owner=UID_A, path=PATH):
        if parent is None:
            parent = self.db.documents["chats/old-room"][4].hex()
        binding = self.service._binding(owner, PIN, collection, parent, purpose)
        if extras is None:
            extras = {"message": "chats/old-room/chats/photo"}
        return self.service._codec.seal("media", {**binding, **extras,
            "bucket": SOURCE[2], "path": path, "exp": self.now + 300})

    def assert_denied(self, ref=None, who=None):
        with self.assertRaises((LegacyReadRejected, LegacyReadUnavailable)):
            self.service.open_media(who or identity(), ref or self.reference())

    def profile(self, *, purpose="participants"):
        self.db.add("users/" + UID_B, {"profilePicThumb": s(URL), "profilePic": s("gs://" + SOURCE[2] + "/different/full.png")})
        self.db.ready = (UID_B, "profile", self.db.storage[5], "image/png", len(DATA), SHA, "ready", PATH)
        parent = self.db.documents["meets/old-meet"][4].hex() if purpose == "participants" else hashlib.sha256(
            ("immutable-discovery\0" + purpose).encode()).hexdigest()
        return self.reference(purpose=purpose, collection="meets/old-meet" if purpose == "participants" else
            "chats" if purpose == "personal_chats" else "meets", parent=parent,
            extras={"profile": "users/" + UID_B, "profileDigest": self.db.documents["users/" + UID_B][4].hex()})

    def meeting(self, *, purpose="meeting_details"):
        self.db.add("meets/old-meet", {"admin": s(UID_B), "users": array([UID_A, UID_B]), "imageUrl": s(URL)})
        digest = self.db.documents["meets/old-meet"][4].hex()
        self.db.ready = (UID_B, "meeting", self.db.storage[5], "image/png", len(DATA), SHA, "ready", PATH)
        return self.reference(purpose=purpose, collection="meets/old-meet" if purpose == "meeting_details" else "meets",
            parent=digest if purpose == "meeting_details" else hashlib.sha256(b"immutable-discovery\0own_meetings").hexdigest(),
            extras={"meeting": "meets/old-meet", "parentDigest": digest})

    def test_verified_bytes_only_lease_chunks_readonly_transactions_and_safe_headers(self):
        with self.service.open_media(identity(), self.reference()) as lease:
            self.assertEqual("image/png", lease.content_type); self.assertEqual(len(DATA), lease.size)
            chunks = list(lease.iter_bytes())
        self.assertEqual(DATA, b"".join(chunks))
        self.assertTrue(all(len(chunk) <= media.CHUNK_BYTES for chunk in chunks))
        self.assertEqual(1, len(self.s3.calls)); self.assertEqual(2, len(self.db.connections))
        self.assertTrue(all(c.closed and c.rolled_back for c in self.db.connections))
        self.assertTrue(all("COMMIT" not in sql and not sql.startswith(("INSERT", "UPDATE", "DELETE")) for sql, _ in self.db.calls))
        config = self.db.configs[0]
        self.assertTrue(config["ssl"].check_hostname)
        self.assertEqual([], os.listdir(self.dir.name))

    def own_avatar(self, *, field="profilePic", extra=None):
        self.db.add("users/" + UID_A, {"uid": s(UID_A), "status": s("active"),
            "profilePic": s(URL), "profilePicThumb": s("gs://" + SOURCE[2] + "/different/thumb.png"),
            **(extra or {})})
        self.db.ready = (UID_A, "profile", self.db.storage[5], "image/png", len(DATA), SHA, "ready", PATH)
        return self.reference(purpose="own-profile", collection="users",
            parent=self.db.documents["users/" + UID_A][4].hex(), extras={"field": field})

    def test_own_avatar_exact_full_profile_field_without_conversation_authority(self):
        ref = self.own_avatar()
        with self.service.open_media(identity(), ref) as lease:
            self.assertEqual(DATA, b"".join(lease.iter_bytes()))
        self.assertEqual(1, len(self.s3.calls))
        self.assertEqual(2, len(self.db.connections))
        self.assertTrue(all(c.closed and c.rolled_back for c in self.db.connections))

    def test_own_avatar_does_not_substitute_other_field_or_ready_owner(self):
        ref = self.own_avatar(field="profilePicThumb")
        self.assert_denied(ref)
        ref = self.own_avatar()
        self.db.ready = (UID_B, *self.db.ready[1:])
        self.assert_denied(ref)
        self.assertEqual([], self.s3.calls)

    def test_own_avatar_other_account_and_invalid_field_before_sql(self):
        ref = self.own_avatar()
        self.assert_denied(ref, identity(UID_B))
        forged = self.reference(purpose="own-profile", collection="users",
            parent=self.db.documents["users/" + UID_A][4].hex(), extras={"field": "balance"})
        self.assert_denied(forged)
        self.assertEqual([], self.db.calls)
        self.assertEqual([], self.s3.calls)

    def test_own_avatar_wrong_collection_or_document_hash(self):
        self.own_avatar()
        for collection, parent in [("users/" + UID_B, "c" * 64), ("users", "d" * 64)]:
            self.assert_denied(self.reference(purpose="own-profile", collection=collection,
                parent=parent, extras={"field": "profilePic"}))
        self.assertEqual([], self.s3.calls)

    def test_own_avatar_unavailable_profile_never_reads_storage(self):
        for fields in [{"uid": s(UID_B)}, {"status": s("blocked")},
                {"deleted": {"booleanValue": True}}, {"deleted": s("false")},
                {"registrationStatus": s("deleted")}, {"registrationStatus": s("blocked")}]:
            self.assert_denied(self.own_avatar(extra=fields))
        self.assertEqual([], self.s3.calls)

    def test_own_avatar_profile_changes_during_download_no_body_lease(self):
        ref = self.own_avatar()
        self.s3.after = lambda: self.db.add("users/" + UID_A,
            {"profilePic": s(URL), "status": s("blocked")})
        self.assert_denied(ref)
        self.assertEqual(1, len(self.s3.calls))
        self.assertEqual([], os.listdir(self.dir.name))

    def test_explicit_provider_readonly_model_without_implicit_legacy_opt_in(self):
        grants = [("GRANT USAGE ON *.* TO `media`@`%`",),
            ("GRANT SELECT ON `clrs_staging`.* TO `media`@`%`",)]
        self.db.grants_override = grants
        self.assert_denied(self.own_avatar())
        self.env["CLRS_LEGACY_READ_PERMISSION_MODEL"] = "provider-database-v1"
        self.service = self.make_service()
        self.assert_denied(self.own_avatar())
        self.env["CLRS_LEGACY_MEDIA_PERMISSION_MODEL"] = "provider-database-v1"
        self.service = self.make_service()
        with self.service.open_media(identity(), self.own_avatar()) as lease:
            self.assertEqual(DATA, b"".join(lease.iter_bytes()))

    def test_provider_model_refuses_broader_mixed_or_unknown_permissions(self):
        self.env["CLRS_LEGACY_MEDIA_PERMISSION_MODEL"] = "provider-database-v1"
        self.service = self.make_service()
        usage = ("GRANT USAGE ON *.* TO `media`@`%`",)
        for grant in ["GRANT SELECT, INSERT ON `clrs_staging`.* TO `media`@`%`",
                "GRANT SELECT ON *.* TO `media`@`%`",
                "GRANT SELECT ON `default_db`.* TO `media`@`%`",
                "GRANT SELECT ON `clrs_staging`.* TO `media`@`%` WITH GRANT OPTION"]:
            self.db.grants_override = [usage, (grant,)]
            self.assert_denied(self.own_avatar())
        self.db.grants_override = [usage, ("GRANT SELECT ON `clrs_staging`.* TO `media`@`%`",),
            ("GRANT SELECT ON `clrs_staging`.`accounts` TO `media`@`%`",)]
        self.assert_denied(self.own_avatar())
        self.env["CLRS_LEGACY_MEDIA_PERMISSION_MODEL"] = "unknown"
        self.service = self.make_service(); self.db.configs.clear()
        self.assert_denied(self.own_avatar())
        self.assertEqual([], self.db.configs)

    def real_s3_port(self, *, corrupt=False, public=False):
        port = Port(body=DATA)
        port.override = lambda operation: Reply(bytes(len(DATA)) if corrupt else DATA,
            content_type="image/png") if operation == "GetObject" else None
        state = lambda bucket, deadline, cancel: {"bucket": bucket,
            "type": "public" if public else "private", "checked_at": self.mono}
        self.s3 = PrivateMediaS3(TARGET_BUCKET, OWNER, port, state, monotonic=lambda: self.mono)
        self.service = self.make_service()
        return port

    def test_full_core_and_real_private_s3_port_match_record_contract_offline(self):
        port = self.real_s3_port()
        with self.service.open_media(identity(), self.reference()) as lease:
            self.assertEqual("private, no-store", lease.headers["Cache-Control"])
            self.assertNotIn("Location", lease.headers)
            self.assertEqual(DATA, b"".join(lease.iter_bytes()))
        self.assertEqual(7, len(port.calls))
        self.assertTrue(all(call[1] == TARGET_BUCKET for call in port.calls))
        self.assertTrue(all(call[2] is None or call[2] == self.db.storage[5] for call in port.calls))
        self.assertTrue(all(reply.closed for reply in port.replies))

    def test_real_port_full_hash_or_public_state_fails_before_body_lease(self):
        for flags in [{"corrupt": True}, {"public": True}]:
            port = self.real_s3_port(**flags); self.assert_denied()
            self.assertTrue(all(reply.closed for reply in port.replies))
            self.assertEqual([], os.listdir(self.dir.name))
        port = self.real_s3_port(); self.db.ready = None; self.assert_denied()
        self.assertEqual([], port.calls)

    def test_raw_without_reviewed_ready_row_never_downloads(self):
        for ready in [None, (*self.db.ready[:6], "pending", PATH), (*self.db.ready[:6], "deleted", PATH)]:
            self.db.ready = ready; self.assert_denied()
        self.assertEqual([], self.s3.calls)

    def test_a_reference_cannot_move_to_b_unknown_identity_or_expiry(self):
        ref = self.reference()
        for who in [identity(UID_B), UID_A, {"uid": UID_A}, identity(expires=NOW)]:
            self.assert_denied(ref, who)
        self.now += 300; self.assert_denied(ref)
        self.assertEqual([], self.db.configs)

    def test_defaultoff_full_source_readback_and_alias_mode_gates_before_connect(self):
        for name, value in [("CLRS_LEGACY_MEDIA_ENABLED", "0"),
                ("CLRS_LEGACY_MEDIA_PROMOTION_REVIEWED", "0"),
                ("CLRS_LEGACY_MEDIA_FULL_READBACK_SOURCE_SHA256", "d" * 64),
                ("CLRS_LEGACY_MEDIA_PROMOTION_MODE", "copy-ready-prefix"),
                ("CLRS_LEGACY_MEDIA_S3_USER_MODE", "migration-user")]:
            self.service = self.make_service({**self.env, name: value}); self.assert_denied()
        self.assertEqual([], self.db.configs)

    def test_exact_five_table_select_role_rejects_schemawide_write_or_extra(self):
        good = [("GRANT USAGE ON *.* TO `m`@`%` REQUIRE SSL",)] + [
            (f"GRANT SELECT ON `clrs_staging`.`{name}` TO `m`@`%`",) for name in sorted(media.TABLES)]
        media.LegacyPrivateMediaService._grants(good)
        for bad in [good[:-1], good + [("GRANT SELECT ON `clrs_staging`.`auth_credentials` TO `m`@`%`",)],
                [("GRANT SELECT ON `clrs_staging`.* TO `m`@`%`",)],
                good + [("GRANT INSERT ON `clrs_staging`.`media_objects` TO `m`@`%`",)],
                good + [(good[-1][0] + " REQUIRE SSL",)], good + [good[-1]],
                [(good[0][0] + " WITH GRANT OPTION",), *good[1:]]]:
            with self.assertRaises(LegacyReadUnavailable):
                media.LegacyPrivateMediaService._grants(bad)

    def test_wrong_parent_hash_nonmember_and_deleted_message_never_download(self):
        self.assert_denied(self.reference(parent="d" * 64))
        self.assert_denied(self.reference(owner=UID_X), identity(UID_X))
        self.db.message("chats/old-room/chats/photo", extra={"image": s(URL), "deletedFor": array([UID_A])})
        self.assert_denied(); self.assertEqual([], self.s3.calls)

    def test_shared_wall_image_and_own_gallery_purposes_are_not_authority(self):
        self.db.message("chats/old-room/chats/photo", extra={"sharedContent": {"mapValue": {"fields": {"imageUrl": s(URL)}}}})
        self.assert_denied()
        for purpose in ["own_profile", "gallery", "wall", "quoted"]:
            self.assert_denied(self.reference(purpose=purpose))
        self.assertEqual([], self.s3.calls)

    def test_raw_storage_exact_path_bucket_key_hash_size_metadata_and_copy_gate(self):
        good = self.db.storage
        for index, value in [(0, SOURCE[2].upper()), (1, PATH.upper()), (2, '{"contentType":"image/png","contentType":"image/png"}'),
                (2, '{"contentType":"text/html"}'), (3, media.MAX_OBJECT_BYTES + 1), (3, True),
                (4, bytes(31)), (5, "clrs-media-ready/" + "a" * 64), (6, bytes(32)), (7, None)]:
            bad = list(good); bad[index] = value; self.db.storage = tuple(bad); self.assert_denied()
        self.assertEqual([], self.s3.calls)

    def test_ready_owner_purpose_key_mime_size_hash_path_require_exact_match(self):
        good = self.db.ready
        for index, value in [(0, UID_A), (1, "post"), (2, good[2].upper()), (3, "image/jpeg"),
                (4, len(DATA) + 1), (4, True), (5, bytes(32)), (7, PATH.upper())]:
            bad = list(good); bad[index] = value; self.db.ready = tuple(bad); self.assert_denied()
        self.assertEqual([], self.s3.calls)

    def test_missing_disabled_owner_is_unavailable_not_fabricated(self):
        for value in [None, (UID_B, 1, "active"), (UID_B, 0, "deleted")]:
            if value is None:
                self.db.accounts.pop(UID_B, None)
            else:
                self.db.accounts[UID_B] = value
            self.assert_denied()
        self.assertEqual([], self.s3.calls)

    def test_recheck_current_viewer_after_download_releases_spool_no_bytes(self):
        self.s3.after = lambda: self.db.accounts.update({UID_A: (UID_A, 1, "active")})
        self.assert_denied(); self.assertEqual(1, len(self.s3.calls)); self.assertEqual([], os.listdir(self.dir.name))
        self.db.accounts[UID_A] = (UID_A, 0, "active"); self.s3.after = None
        with self.service.open_media(identity(), self.reference()) as lease:
            self.assertEqual(DATA, b"".join(lease.iter_bytes()))

    def test_recheck_parent_profile_and_ready_changes_after_full_bytes(self):
        for mutate in [lambda: self.db.add("chats/old-room", {"user1": s(UID_A), "user2": s(UID_X)}),
                lambda: setattr(self.db, "ready", (*self.db.ready[:6], "deleted", PATH))]:
            self.db = MediaDatabase(); self.service = self.make_service()
            self.db.message("chats/old-room/chats/photo", extra={"image": s(URL)})
            self.s3.after = mutate; self.assert_denied()
        self.assertEqual([], os.listdir(self.dir.name))

    def test_size_or_full_hash_failure_never_constructs_lease(self):
        for data in [DATA[:-1], DATA + b"x", bytes(len(DATA))]:
            self.s3.data = data; self.assert_denied()
        self.s3.fail = True; self.assert_denied()
        self.assertEqual([], os.listdir(self.dir.name))
        self.s3.fail = False; self.s3.data = DATA
        with self.service.open_media(identity(), self.reference()) as lease:
            lease.close()

    def test_two_slots_held_through_response_and_released_by_close(self):
        first = self.service.open_media(identity(), self.reference())
        second = self.service.open_media(identity(), self.reference())
        try:
            before = len(self.s3.calls); self.assert_denied(); self.assertEqual(before, len(self.s3.calls))
            first.close(); first.close()
            third = self.service.open_media(identity(), self.reference()); third.close()
        finally:
            first.close(); second.close()

    def test_expiry_during_response_closes_lease_and_no_future_chunks(self):
        lease = self.service.open_media(identity(), self.reference())
        iterator = lease.iter_bytes(); self.assertTrue(next(iterator))
        self.now += 300
        with self.assertRaises(LegacyReadRejected):
            next(iterator)
        self.assertTrue(lease._closed)

    def test_expiry_before_context_enter_also_closes_lease(self):
        lease = self.service.open_media(identity(), self.reference())
        self.now += 300
        with self.assertRaises(LegacyReadRejected):
            with lease:
                self.fail("expired context must not enter")
        self.assertTrue(lease._closed)
        with self.service.open_media(identity(), self.reference()) as second:
            second.close()

    def test_deadline_during_download_retains_slot_until_actual_return_then_cleans(self):
        self.s3.after = lambda: setattr(self, "mono", self.mono + 60)
        self.assert_denied(); self.assertEqual([], os.listdir(self.dir.name))
        self.s3.after = None
        with self.service.open_media(identity(), self.reference()) as lease:
            lease.close()

    def test_real_deadline_does_not_free_slots_while_injected_io_still_running(self):
        entered = []; release = threading.Event(); lock = threading.Lock(); failures = []
        def blocked(record, sink, *, deadline, cancel):
            with lock:
                entered.append(cancel)
            release.wait(2)
            sink.write(DATA)
        self.s3.get_verified_to_file = blocked
        ref = self.reference()
        def work():
            try:
                self.service.open_media(identity(), ref)
            except (LegacyReadRejected, LegacyReadUnavailable):
                failures.append(True)
        with patch.object(media, "REQUEST_SECONDS", 0.03):
            workers = [threading.Thread(target=work) for _ in range(2)]
            for worker in workers:
                worker.start()
            try:
                until = time.monotonic() + 1
                while len(entered) != 2 and time.monotonic() < until:
                    time.sleep(0.005)
                self.assertEqual(2, len(entered))
                self.assertTrue(all(event.wait(0.3) for event in entered))
                self.assert_denied(ref)
                self.assertEqual(2, len(entered))  # no third I/O after timeout
            finally:
                release.set()
                for worker in workers:
                    worker.join(2)
            self.assertEqual(2, len(failures))
        self.s3 = FakeS3(); self.service = self.make_service()
        with self.service.open_media(identity(), self.reference()) as lease:
            lease.close()

    def test_insecure_or_symlink_spool_is_refused(self):
        os.chmod(self.dir.name, 0o755); self.assert_denied(); self.assertEqual([], self.s3.calls)
        os.chmod(self.dir.name, 0o700)
        with tempfile.TemporaryDirectory() as outer:
            alias = Path(outer) / "alias"; alias.symlink_to(self.dir.name)
            self.service = self.make_service({**self.env, "CLRS_LEGACY_MEDIA_SPOOL_DIR": str(alias)})
            self.assert_denied()

    def test_participant_thumbnail_scope_hash_and_kicked_gates(self):
        ref = self.profile()
        with self.service.open_media(identity(), ref) as lease:
            self.assertEqual(DATA, b"".join(lease.iter_bytes()))
        self.db.add("users/" + UID_B, {"profilePicThumb": s(URL), "deleted": {"booleanValue": True}})
        self.assert_denied(ref)
        ref = self.profile()
        self.db.add("meets/old-meet", {"admin": s(UID_B), "users": array([UID_A, UID_B]), "kicked": array([UID_A])})
        self.assert_denied(ref)

    def test_kicked_participant_avatar_owner_is_not_current_member_authority(self):
        self.db.add("meets/old-meet", {"admin": s(UID_A), "users": array([UID_A, UID_B]), "kicked": array([UID_B])})
        ref = self.profile()
        self.assert_denied(ref)
        self.assertEqual([], self.s3.calls)

    def test_discovery_avatar_requires_exact_fresh_own_pair_and_bounded_parents(self):
        ref = self.profile(purpose="personal_chats")
        with self.service.open_media(identity(), ref) as lease:
            lease.close()
        self.db.add("chats/old-room", {"user1": s(UID_B), "user2": s(UID_X)})
        self.assert_denied(ref)
        for number in range(media.MAX_CANDIDATE_PARENTS + 1):
            self.db.add("chats/synthetic-" + str(number), {"user1": s(UID_A), "user2": s(UID_B)})
        self.assert_denied(ref)

    def test_discovery_relation_digest_rechecked_after_download_even_if_still_pair(self):
        ref = self.profile(purpose="personal_chats")
        self.s3.after = lambda: self.db.add("chats/old-room", {"user1": s(UID_A), "user2": s(UID_B), "newField": s("synthetic")})
        self.assert_denied(ref); self.assertEqual(1, len(self.s3.calls))

    def test_meeting_image_specific_parent_and_discovery_organizer_avatar(self):
        for purpose in ["meeting_details", "own_meetings"]:
            ref = self.meeting(purpose=purpose)
            with self.service.open_media(identity(), ref) as lease:
                lease.close()
        ref = self.profile(purpose="own_meetings")
        with self.service.open_media(identity(), ref) as lease:
            lease.close()

    def test_own_removed_history_sparse_parent_valid_and_other_owner_forbidden(self):
        collection = "users/" + UID_A + "/removed_meets/sparse/messages"
        self.db.message(collection + "/photo", extra={"image": s(URL)})
        ref = self.reference(collection=collection,
            parent=hashlib.sha256(("owned-removed-history\0" + collection).encode()).hexdigest(),
            extras={"message": collection + "/photo"})
        with self.service.open_media(identity(), ref) as lease:
            lease.close()
        self.assert_denied(ref, identity(UID_B))

    def test_malformed_extra_or_source_path_and_noncanonical_gcm_ref_before_sql(self):
        good = self.service._codec.open("media", self.reference())
        for update in [{"source": "d" * 64}, {"purpose": []}, {"v": True}, {"path": "x/../z"},
                {"path": "x/\x00z"}, {"extra": "synthetic"}, {"collection": 1}]:
            self.assert_denied(self.service._codec.seal("media", {**good, **update}))
        self.assert_denied(self.reference() + "=")
        self.assertEqual([], self.db.configs)

    def test_malformed_reference_rate_limit_before_aes_and_sql(self):
        for _ in range(30):
            self.assert_denied("bad-opaque")
        with self.assertRaises(LegacyReadRateLimited):
            self.service.open_media(identity(), "bad-opaque")
        self.assertEqual([], self.db.configs)


if __name__ == "__main__":
    unittest.main()
