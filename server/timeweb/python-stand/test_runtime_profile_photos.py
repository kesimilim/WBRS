"""Focused no-TCP current-session/SQL/private-S3 profile-photo scenarios."""
import copy
from dataclasses import replace
from datetime import datetime
import hashlib
import json
import os
import ssl
import tempfile
import threading
import unittest
from unittest.mock import patch

import runtime_profile_photos as photos
from legacy_private_media import target_key
from media_promotion_acknowledgement import SOURCE, VerifiedMediaPromotion
from private_media_s3 import PrivateMediaS3
from profile_photo_projector import verify_source_snapshot, VerifiedSourceSnapshot
from runtime_mutations import RuntimeMutationStore, RuntimeRejected, RuntimeInvalidRequest, RuntimeUnavailable
from test_private_media_s3 import Port, Reply, BUCKET, OWNER
from test_profile_photo_projector import source_verifier, PROOF
from test_profile_photo_review import source, url
from test_runtime_mutations import FakeDatabase, FakeConnection, FakeCursor, ENV, NOW, STAMP


KEY = bytes(range(32))
BODY = b"\xff\xd8" + b"synthetic profile original" * 4096


def doc_row(record, collection):
    return (record.firebase_path, collection, record.firebase_path.rsplit("/", 1)[1],
        record.encoded_payload, bytes.fromhex(record.payload_sha256))


class PhotoDatabase(FakeDatabase):
    def __init__(self):
        super().__init__()
        self.state.update(profiles={}, photos={}, roots={}, galleries={}, media={}, storage={})
        self.source = (SOURCE["project"], SOURCE["database"], SOURCE["bucket"])
        self.force_photos = None; self.after_photo_read = None; self.after_session_proof = None
        self.sql_permissions = set(photos.READ_TABLES) | {"device_sessions"}
        self.grant_rows = [("GRANT USAGE ON *.* TO 'fixture'@'%' REQUIRE SSL",),
            ("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.* TO 'fixture'@'%'",)]
        self.add_profile("actor"); self.add_profile("peer")

    def add_profile(self, uid, count=1):
        self.state["accounts"].setdefault(uid, [0, "active", 0, 1])
        path = "users/" + uid + "/photos/avatar.jpg"
        root = source("users/" + uid, uid={"stringValue": uid}, status={"stringValue": "active"},
            profilePic={"stringValue": url(path)}, email={"stringValue": "private@example.invalid"})
        self.state["profiles"][uid] = [0, 0, None, root.encoded_payload, STAMP]
        self.state["roots"][uid] = doc_row(root, "users")
        self.state["galleries"][uid] = []; self.state["photos"][uid] = []
        for ordinal in range(count):
            image_id = None if ordinal == 0 else f"image-{ordinal:02d}"
            current_path = path if ordinal == 0 else "users/" + uid + "/photos/" + image_id + ".jpg"
            if image_id is not None:
                gallery = source("users/" + uid + "/images/" + image_id, url={"stringValue": url(current_path)})
                self.state["galleries"][uid].append(doc_row(gallery, "users/" + uid + "/images"))
            key = target_key(SOURCE["project"], SOURCE["bucket"], current_path)
            media_id = "legacy-media-" + key.rsplit("/", 1)[1]
            digest = hashlib.sha256(BODY).digest()
            self.state["media"][media_id] = [media_id, uid, "profile", key, None,
                "image/jpeg", len(BODY), None, digest, "ready", current_path]
            self.state["storage"][current_path] = [SOURCE["bucket"], current_path,
                {"contentType": "image/jpeg", "bucket": SOURCE["bucket"]}, len(BODY), digest,
                key, digest, datetime(2026, 9, 1)]
            self.state["photos"][uid].append([uid, media_id, ordinal, int(ordinal == 0), image_id])

    def connect(self, **config):
        assert config["ssl"].verify_mode == ssl.CERT_REQUIRED and config["ssl"].check_hostname
        if self.before_connect: self.before_connect()
        connection = PhotoConnection(self); self.connections.append(connection)
        return connection


class PhotoConnection(FakeConnection):
    def cursor(self):
        return PhotoCursor(self)


class PhotoCursor(FakeCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); state = self.c.state; db = self.c.db
        if "FROM clrs_staging.device_sessions AS s" in sql:
            result = super().execute(statement, params)
            if db.after_session_proof: db.after_session_proof(self.c)
            return result
        matched = True
        if sql == " ".join(photos.TARGET_SQL.split()):
            assert params[0] == params[1]
            uid = params[0]; account = state["accounts"].get(uid); profile = state["profiles"].get(uid)
            self.rows = [(uid, *account[:2], uid, *profile)] if account and profile else []
        elif sql == " ".join(photos.PHOTOS_SQL.split()):
            assert params[0] == params[1]
            self.rows = copy.deepcopy(db.force_photos if db.force_photos is not None else state["photos"].get(params[0], []))
            if db.after_photo_read: db.after_photo_read(self.c)
        elif sql == " ".join(photos.SOURCE_SQL.split()):
            self.rows = [db.source]
        elif sql == " ".join(photos.ROOT_SQL.split()):
            assert params[0] == hashlib.sha256(params[1].encode()).digest()
            self.rows = [state["roots"][params[1][6:]]] if params[1][6:] in state["roots"] else []
        elif sql == " ".join(photos.GALLERY_SQL.split()):
            assert params[0] == hashlib.sha256(params[1].encode()).digest()
            self.rows = sorted(copy.deepcopy(state["galleries"].get(params[1][6:-7], [])),
                key=lambda row: row[2].encode())[:51]
        elif "FROM clrs_staging.media_objects WHERE media_id IN" in sql:
            self.rows = [state["media"][uid] for uid in params if uid in state["media"]]
        elif "FROM clrs_staging.legacy_storage_objects" in sql:
            assert params[0] == SOURCE["bucket"]
            self.rows = [row for path, row in state["storage"].items() if hashlib.sha256(path.encode()).digest() in params[1:]]
        else:
            matched = False
        if not matched: return super().execute(statement, params)
        assert self.c.readonly and self.c.held and sql.endswith(("FOR SHARE", "FOR SHARE OF a, p"))
        for table in photos.READ_TABLES:
            if "clrs_staging." + table + " " in sql and table not in db.sql_permissions:
                raise OSError("synthetic missing SELECT")
        db.calls.append((sql, params)); self.rowcount = len(self.rows)
        return self.rowcount


class CurrentProfilePhotoTests(unittest.TestCase):
    def setUp(self):
        self.db = PhotoDatabase(); self.now = NOW
        self.store = RuntimeMutationStore({**ENV, "CLRS_RUNTIME_PERMISSION_MODEL": "provider-database-v1"},
            self.db.tokens, connect=self.db.connect, clock=lambda: self.now)
        self.addCleanup(self.store.close)
        self.temp = tempfile.TemporaryDirectory(); os.chmod(self.temp.name, 0o700)
        self.addCleanup(self.temp.cleanup)
        self.port = Port(BODY)
        self.s3 = PrivateMediaS3(BUCKET, OWNER, self.port,
            lambda bucket, deadline, cancel: {"bucket": bucket, "type": "private", "checked_at": 0},
            monotonic=lambda: 0)
        self.cap = verify_source_snapshot(PROOF, trusted_verifier=source_verifier)
        self.options = {"private_s3": self.s3, "expected_bucket": BUCKET, "expected_owner": OWNER,
            "source_snapshot": self.cap, "media_promotion": VerifiedMediaPromotion("0" * 64, NOW, NOW - 10),
            "spool_directory": self.temp.name, "gallery_order_policy": photos.GALLERY_ORDER_POLICY,
            "clock": lambda: self.now, "monotonic": lambda: 0}
        self.service = photos.RuntimeProfilePhotosService(self.store, KEY, **self.options)
        self.addCleanup(self.service.close)

    def page(self, target="peer", **changes):
        return self.service.photos(self.db.identity, target, access_token=self.db.access, **changes)

    def open(self, reference, target="peer", **changes):
        return self.service.open_photo(self.db.identity, target, reference, access_token=self.db.access, **changes)

    def reference(self):
        return self.page()["items"][0]["reference"]

    def test_public_descriptors_and_full_verified_private_bytes_no_writes(self):
        before = copy.deepcopy(self.db.state)
        page = self.page(); item = page["items"][0]
        self.assertEqual({"ordinal", "isPrimary", "contentType", "byteSize", "reference"}, set(item))
        self.assertTrue(item["isPrimary"]); self.assertIsNone(page["nextCursor"])
        for forbidden in ("private@", "quarantine", "photos/", "firebase", "sha256", "email", "legacy_raw"):
            self.assertNotIn(forbidden, json.dumps(page))
        with self.open(item["reference"]) as lease:
            self.assertEqual(BODY, b"".join(lease.iter_bytes()))
            self.assertEqual("private, no-store", lease.headers["Cache-Control"])
        self.assertEqual(before, self.db.state)
        self.assertTrue(all(c.readonly and c.closed and c.rollbacks and c.commits == 0 for c in self.db.connections))
        self.assertTrue(all(not sql.startswith(("INSERT", "UPDATE", "DELETE")) for sql, _ in self.db.calls))
        self.assertEqual([], os.listdir(self.temp.name))

    def test_own_hidden_profile_allowed_public_hidden_disabled_or_missing_rejected(self):
        self.db.state["profiles"]["actor"][2] = "2030-01-01T00:00:00.000000Z"
        self.assertEqual(1, len(self.page("actor")["items"]))
        self.db.state["profiles"]["peer"][2] = "2030-01-01T00:00:00.000000Z"
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound): self.page()
        self.db.state["profiles"]["peer"][2] = None
        self.db.state["accounts"]["peer"][0] = 1
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound): self.page()
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound): self.page("absent")
        self.assertEqual([], self.port.calls)

    def test_native_empty_raw_has_no_guessed_photo_even_when_other_ready_media_exists(self):
        self.db.state["profiles"]["peer"][0:2] = [1, 1]
        self.db.state["profiles"]["peer"][3] = {}
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound): self.page()
        self.db.state["photos"]["peer"] = []
        self.assertEqual([], self.page()["items"])

    def test_three_current_proofs_before_fetch_after_spool_before_first_byte(self):
        reference = self.reference(); prior = len(self.db.connections)
        lease = self.open(reference)
        self.assertEqual(prior + 2, len(self.db.connections))
        self.db.state["accounts"]["peer"][0] = 1
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound): next(lease.iter_bytes())
        self.assertTrue(lease._closed)
        self.assertEqual(prior + 3, len(self.db.connections))

    def test_after_download_target_or_relation_change_returns_no_lease(self):
        reference = self.reference()
        def alter(operation):
            if operation == "GetObject":
                return Reply(BODY, content_type="image/jpeg", hook=lambda: self.db.state["photos"]["peer"].clear())
        self.port.override = alter
        with self.assertRaises(RuntimeInvalidRequest): self.open(reference)
        self.assertTrue(all(reply.closed for reply in self.port.replies))
        self.assertEqual([], os.listdir(self.temp.name))

    def test_changed_native_actor_or_revoked_session_rejects_reuse(self):
        reference = self.reference()
        other = replace(self.db.identity, uid="peer")
        with self.assertRaises(RuntimeRejected):
            self.service.open_photo(other, "peer", reference, access_token=self.db.access)
        self.db.state["sessions"][self.db.identity.session_id]["revoked_at"] = STAMP
        with self.assertRaises(RuntimeRejected): self.open(reference)
        self.assertEqual([], self.port.calls)

    def test_same_valid_B_session_cannot_reuse_A_reference(self):
        reference = self.reference()
        session, access = self.db.tokens.mint("peer", "other-device", 0, NOW)
        self.db.state["sessions"][session["session_id"]] = session
        identity = replace(self.db.identity, uid="peer", session_id=session["session_id"])
        with self.assertRaises(RuntimeInvalidRequest):
            self.service.open_photo(identity, "peer", reference, access_token=access["accessToken"])
        self.assertEqual([], self.port.calls)

    def test_current_session_post_check_blocks_descriptor(self):
        proofs = []
        def expire(connection):
            proofs.append(1)
            if len(proofs) == 1: self.now += 901
        self.db.after_session_proof = expire
        with self.assertRaises(RuntimeRejected): self.page()

    def test_wrong_target_expired_wrong_purpose_or_extra_token_never_fetches(self):
        reference = self.reference()
        with self.assertRaises(RuntimeInvalidRequest): self.open(reference, target="actor")
        opened = self.service._codec.open("media", reference)
        for token in ({**opened, "extra": True}, {**opened, "ordinal": True}, {**opened, "mediaId": "other"}):
            with self.assertRaises(RuntimeInvalidRequest): self.open(self.service._codec.seal("media", token))
        self.now += 60
        with self.assertRaises(RuntimeInvalidRequest): self.open(reference)
        self.assertEqual([], self.port.calls)

    def test_explicit_ordinal_paging_50_bound_and_cursor_context_actor_limit_expiry(self):
        self.db.add_profile("peer", 50)
        first = self.page(); second = self.page(cursor=first["nextCursor"])
        self.assertEqual(list(range(30)), [x["ordinal"] for x in first["items"]])
        self.assertEqual(list(range(30, 50)), [x["ordinal"] for x in second["items"]])
        self.assertIsNone(second["nextCursor"])
        self.assertLessEqual(len(json.dumps(first).encode()), photos.MAX_PUBLIC_BYTES)
        with self.assertRaises(RuntimeInvalidRequest): self.page(cursor=first["nextCursor"], limit=20)
        with self.assertRaises(RuntimeInvalidRequest): self.page("actor", cursor=first["nextCursor"])
        self.now += 60
        with self.assertRaises(RuntimeInvalidRequest): self.page(cursor=first["nextCursor"])
        self.db.force_photos = [self.db.state["photos"]["peer"][0]] * 51
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound): self.page()

    def test_exact_source_root_current_raw_ready_owner_purpose_hash_and_association(self):
        baseline = copy.deepcopy(self.db.state)
        media_id = self.db.state["photos"]["peer"][0][1]
        mutations = [lambda: self.db.state["roots"]["peer"][3]["fields"].update(profilePic={"stringValue": url("other.jpg")}),
            lambda: self.db.state["media"][media_id].__setitem__(1, "actor"),
            lambda: self.db.state["media"][media_id].__setitem__(2, "message"),
            lambda: self.db.state["media"][media_id].__setitem__(9, "pending"),
            lambda: self.db.state["media"][media_id].__setitem__(8, b"x" * 32),
            lambda: self.db.state["photos"]["peer"][0].__setitem__(2, 1),
            lambda: self.db.state["photos"]["peer"][0].__setitem__(3, 0)]
        for change in mutations:
            with self.subTest(change=mutations.index(change)):
                self.db.state = copy.deepcopy(baseline); change()
                with self.assertRaises(photos.RuntimeProfilePhotoNotFound): self.page()
        self.assertEqual([], self.port.calls)

    def test_maximal_unicode_source_ids_do_not_break_private_or_public_64k_bounds(self):
        uid = "\U0001f600" * 191
        self.db.add_profile(uid, 50)
        for ordinal in range(1, 50):
            image_id = "\U0001f603" * 188 + f"{ordinal:03d}"
            old = self.db.state["galleries"][uid][ordinal - 1]
            replacement = source("users/" + uid + "/images/" + image_id, **old[3]["fields"])
            self.db.state["galleries"][uid][ordinal - 1] = doc_row(replacement, "users/" + uid + "/images")
            self.db.state["photos"][uid][ordinal][4] = image_id
        page = self.page(uid)
        self.assertEqual(30, len(page["items"]))
        self.assertLessEqual(len(json.dumps(page, ensure_ascii=False).encode()), photos.MAX_PUBLIC_BYTES)
        self.assertEqual(20, len(self.page(uid, cursor=page["nextCursor"])["items"]))

    def test_explicit_source_policy_primary_gallery_alias_and_duplicate_gallery_refusal(self):
        self.db.add_profile("peer", 2)
        original = self.db.state["roots"]["peer"][3]["fields"]["profilePic"]
        image = source("users/peer/images/avatar-gallery", url=copy.deepcopy(original))
        self.db.state["galleries"]["peer"].append(doc_row(image, "users/peer/images"))
        self.db.state["photos"]["peer"][0][4] = "avatar-gallery"
        self.assertEqual([0, 1], [item["ordinal"] for item in self.page()["items"]])
        duplicate = source("users/peer/images/duplicate-gallery", url=copy.deepcopy(original))
        self.db.state["galleries"]["peer"].append(doc_row(duplicate, "users/peer/images"))
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound): self.page()
        with self.assertRaises(RuntimeUnavailable):
            photos.RuntimeProfilePhotosService(self.store, KEY,
                **{**self.options, "gallery_order_policy": "guess-from-current-relation"})

    def test_unconsumed_lease_deadline_and_service_close_hard_release_exactly_once(self):
        timers = []
        class Timer:
            def __init__(self, seconds, callback):
                self.seconds = seconds; self.callback = callback; self.cancelled = False
                timers.append(self)
            def start(self): pass
            def cancel(self): self.cancelled = True
            def fire(self): self.callback()
        reference = self.reference()
        self.now += 58
        with patch.object(photos.threading, "Timer", Timer):
            first = self.open(reference)
            self.assertEqual(2, timers[-1].seconds)
            self.assertEqual(1, len(self.service._leases))
            timers[0].fire(); timers[0].fire()
            self.assertTrue(first._file.closed)
            self.assertEqual(set(), self.service._leases)
            first.close()  # no second slot release
            second = self.open(reference); third = self.open(reference)
            self.assertEqual(2, len(self.service._leases))
            with self.assertRaises(RuntimeUnavailable): self.open(reference)
            self.service.close()
            self.assertTrue(second._file.closed and third._file.closed)
            self.assertEqual(set(), self.service._leases)
            for timer in timers: timer.fire()
            second.close(); third.close()
        self.assertEqual([], os.listdir(self.temp.name))

    def test_large_original_and_corrupt_length_hash_never_emit_bytes(self):
        media_id = self.db.state["photos"]["peer"][0][1]
        storage = next(row for row in self.db.state["storage"].values() if row[1] == self.db.state["media"][media_id][-1])
        self.db.state["media"][media_id][6] = storage[3] = photos.MAX_IMAGE_BYTES + 1
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound): self.page()
        self.db.state["media"][media_id][6] = storage[3] = len(BODY)
        reference = self.reference()
        for bad in (b"wrong length", b"x" * len(BODY)):
            self.port.body = bad
            with self.assertRaises(RuntimeUnavailable): self.open(reference)
        self.assertEqual([], os.listdir(self.temp.name))

    def test_required_select_capabilities_and_private_spool_fail_closed(self):
        for table in ("profile_photos", "media_objects", "legacy_documents", "legacy_storage_objects"):
            self.db.sql_permissions.remove(table)
            with self.assertRaises(RuntimeUnavailable): self.page()
            self.db.sql_permissions.add(table)
        for changes in ({"source_snapshot": VerifiedSourceSnapshot(self.cap.archive_sha256,
                self.cap.manifest_sha256, self.cap.receipt_digest, self.cap.counts, False)},
                {"media_promotion": None}, {"expected_owner": "different"}, {"private_s3": object()}):
            with self.assertRaises(RuntimeUnavailable):
                photos.RuntimeProfilePhotosService(self.store, KEY, **{**self.options, **changes})
        reference = self.reference(); os.chmod(self.temp.name, 0o755)
        with self.assertRaises(RuntimeUnavailable): self.open(reference)
        self.assertEqual([], self.port.calls)

    def test_cancel_close_deadline_and_two_spool_slots(self):
        reference = self.reference(); cancelled = threading.Event(); cancelled.set()
        with self.assertRaises(RuntimeUnavailable): self.open(reference, request_cancel=cancelled)
        with self.assertRaises(RuntimeInvalidRequest): self.open(reference, request_deadline=0)
        first = self.open(reference); second = self.open(reference)
        with self.assertRaises(RuntimeUnavailable): self.open(reference)
        self.service.close()
        for lease in (first, second):
            with self.assertRaises(RuntimeUnavailable): next(lease.iter_bytes())
            self.assertTrue(lease._closed)
        with self.assertRaises(RuntimeUnavailable): self.page()


if __name__ == "__main__":
    unittest.main()
