"""One native upload module, real bounded store/HTTP, synthetic SQL/S3 only."""
import base64
import copy
from datetime import datetime, timezone, timedelta
import hashlib
import json
import unittest

from native_sessions import NativeIdentity
from runtime_mutations import (RuntimeMutationStore, RuntimeUnavailable, request_digest)
from runtime_profile_photo_uploads import (RuntimeProfilePhotoUploadsService,
    PhotoUploadVerificationFailed, PREPARE_OPERATION, COMMIT_OPERATION, PREFIX,
    MAX_BYTES, _PARTS, photo_identity)
from runtime_profile_photo_uploads_http import RuntimeProfilePhotoUploadsHttp
from test_runtime_mutations import FakeDatabase, FakeCursor, NOW, STAMP
from test_runtime_http import Native, env, OP


SECOND = "12345678-1234-4234-8234-123456789abd"
THIRD = "12345678-1234-4234-8234-123456789abe"
DATA = b"\x89PNG\r\n\x1a\nsynthetic object bytes"
PAYLOAD = {"sha256": hashlib.sha256(DATA).hexdigest(), "byteSize": len(DATA), "mimeType": "image/png"}
NEW_STAMP = "2027-01-15T08:00:00.000002Z"


class PhotoCursor(FakeCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); db = self.c.db; state = self.c.state
        if not any(part in sql for part in ("information_schema.statistics", "clrs_staging.profiles", "clrs_staging.media_objects", "clrs_staging.profile_photos")):
            return super().execute(statement, params)
        assert self.c.held
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if db.fail_contains and db.fail_contains in sql: raise OSError("synthetic denied write")
        if "information_schema.statistics" in sql:
            self.rows = [( *row, None) for row in sorted(_PARTS)] if db.indexes_ok else []
        elif sql.startswith("SELECT profile_details_saved, registration_complete"):
            assert params[0] == params[1]
            uid = params[0]
            if uid in state["profiles"]:
                initial = state.get("initial_profiles", {}).get(uid)
                values = (initial["profileDetailsSaved"], initial["isRegistrationEnd"]) if initial is not None else state["flags"][uid]
                self.rows = [(*values, state.get("native_origin", {}).get(uid, 1))]
        elif sql.startswith("SELECT p.media_id, p.ordinal, p.is_primary"):
            assert params[0] == params[1]
            for photo in sorted(state["photos"].get(params[0], []), key=lambda row: row[1]):
                media = state["media"].get(photo[0])
                if media is None: continue  # Actual SQL is an inner exact-MID join.
                copied = list(media)
                if len(copied[3].encode("utf-8")) > 128: copied[3] = None
                self.rows.append((*photo, state.get("firebase", {}).get(photo[0]), *copied))
            self.rows = self.rows[:51 if "LIMIT 51" in sql else 21]
        elif sql.startswith("SELECT uid, DATE_FORMAT"):
            assert params[0] == params[1]
            stamp = state["profiles"].get(params[0]); self.rows = [(params[0], stamp)] if stamp else []
        elif sql.startswith("SELECT media_id, ordinal"):
            self.rows = [tuple(row) for row in state["photos"].get(params[0], [])][:21]
        elif sql.startswith("SELECT media_id, owner_uid"):
            row = state["media"].get(params[0]); self.rows = [tuple(row)] if row else []
        elif sql.startswith("INSERT INTO clrs_staging.media_objects"):
            assert not self.c.readonly
            mid, uid, key, mime, size, sha = params
            assert mid not in state["media"] and key.startswith(PREFIX)
            state["media"][mid] = [mid, uid, "profile", key, mime, size, sha.hex(), "pending", 1, 1, 1]; self.rowcount = 1
        elif sql.startswith("UPDATE clrs_staging.media_objects"):
            assert not self.c.readonly
            mid, exact_mid, uid = params; assert mid == exact_mid
            row = state["media"].get(mid)
            if row and row[1] == uid and row[7] == "pending": row[7] = "ready"; self.rowcount = 1
        elif sql.startswith("INSERT INTO clrs_staging.profile_photos"):
            assert not self.c.readonly
            uid, mid, ordinal, primary = params
            assert state["media"][mid][1] == uid and state["media"][mid][7] == "ready"
            rows = state["photos"].setdefault(uid, []); assert ordinal == len(rows)
            rows.append([mid, ordinal, primary]); self.rowcount = 1
            if db.revoke_at_append: state["sessions"][db.identity.session_id]["revoked_at"] = STAMP
        elif sql.startswith("UPDATE clrs_staging.profiles"):
            assert not self.c.readonly
            uid, exact_uid, expected = params; assert uid == exact_uid
            if state["profiles"].get(uid) == expected.replace(" ", "T") + "Z":
                previous = datetime.strptime(state["profiles"][uid], "%Y-%m-%dT%H:%M:%S.%fZ")
                state["profiles"][uid] = (previous + timedelta(microseconds=1)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
                self.rowcount = 1
        else: raise AssertionError("unexpected photo SQL")
        return self.rowcount


class PhotoDatabase(FakeDatabase):
    def __init__(self):
        super().__init__(); self.env = {**__import__('test_runtime_mutations').ENV, "CLRS_RUNTIME_PERMISSION_MODEL": "provider-database-v1"}
        self.grant_rows = [("GRANT USAGE ON *.* TO 'fixture'@'%' REQUIRE SSL",),
            ("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.* TO 'fixture'@'%'",)]
        self.state.update(profiles={"actor": STAMP, "peer": STAMP}, photos={}, media={},
            flags={"actor": [0, 0], "peer": [0, 0]})
        self.indexes_ok = True; self.revoke_at_append = False

    def connect(self, **config):
        connection = super().connect(**config); connection.cursor = lambda: PhotoCursor(connection)
        return connection


class FakeWriter:
    """Trusted test injection, explicitly NOT a controlled provider proof."""
    def __init__(self):
        self.objects = {}; self.signs = 0; self.verifies = 0; self.evidence = {}
        self.supported = True; self.private = True; self.after_sign = None; self.fail_evidence = False

    def prepare_put(self, record, *, deadline, cancel):
        if not self.supported or not self.private: raise RuntimeUnavailable()
        self.signs += 1
        if self.after_sign: self.after_sign()
        return {"url": "https://s3.twcstorage.ru/fixture-bucket/" + record["key"] + "?X-Amz-Signature=" + "0" * 64,
            "headers": {"Content-Type": record["content_type"], "Content-Length": str(record["size"]), "If-None-Match": "*",
                "x-amz-checksum-sha256": base64.b64encode(bytes.fromhex(record["sha256"])).decode(), "x-amz-content-sha256": record["sha256"]},
            "expiresAt": datetime.fromtimestamp(NOW + 60, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")}

    def verify_ready(self, record, *, deadline, cancel):
        self.verifies += 1
        if not self.supported or not self.private or record["key"] not in self.objects: raise RuntimeUnavailable()
        data, mime = self.objects[record["key"]]
        if len(data) != record["size"] or hashlib.sha256(data).hexdigest() != record["sha256"] or mime != record["content_type"]:
            raise PhotoUploadVerificationFailed()
        cap = object(); self.evidence[cap] = dict(record); return cap

    def require_verified(self, evidence, record):
        if self.fail_evidence or evidence not in self.evidence or self.evidence[evidence] != record: raise RuntimeUnavailable()


class NativePhotoUploadTests(unittest.TestCase):
    def setup_service(self, writer=True):
        db = PhotoDatabase(); store = RuntimeMutationStore(db.env, db.tokens, connect=db.connect, clock=lambda: NOW)
        self.addCleanup(store.close)
        port = FakeWriter() if writer else None
        service = RuntimeProfilePhotoUploadsService(store, writer=port, clock=lambda: NOW)
        native = Native(); native.identity = db.identity
        adapter = RuntimeProfilePhotoUploadsHttp(db.env, service=service)
        def call(path, body=None, **values):
            request = env(path, body, **values); request["HTTP_AUTHORIZATION"] = "Bearer " + db.access
            return adapter.dispatch(request, native_service=native, native_configured=True)
        return db, store, service, port, call

    def prepare(self, call, op=OP):
        result = call("/v1/runtime/profile/photos/prepare", {"operationId": op, **PAYLOAD})
        self.assertEqual(result.status, "201 Created")
        return result.payload["result"]["mediaId"]

    def commit(self, call, mid, op=SECOND, prep=OP):
        return call("/v1/runtime/profile/photos/commit", {"operationId": op, "prepareOperationId": prep, "mediaId": mid})

    def lookup(self, call, operation, op, payload):
        return call(f"/v1/runtime/operations/{operation}/{op}", REQUEST_METHOD="GET", QUERY_STRING="requestHash=" + request_digest(payload).hex())

    def test_blank_profile_actual_upload_ready_append_and_original_receipts(self):
        db, store, service, writer, call = self.setup_service(); mid = self.prepare(call)
        self.assertEqual(mid, photo_identity("actor", OP)[0]); self.assertEqual(db.state["media"][mid][7], "pending")
        lease = call(f"/v1/runtime/profile/photos/uploads/{mid}/lease", REQUEST_METHOD="GET", QUERY_STRING="prepareOperationId=" + OP)
        self.assertEqual(lease.status, "200 OK"); self.assertEqual(lease.payload["headers"]["If-None-Match"], "*")
        self.assertNotIn("x-amz-acl", lease.payload["headers"])
        self.assertNotIn("url", "".join(row[3] for row in db.state["receipts"].values()))
        writer.objects[db.state["media"][mid][3]] = (DATA, "image/png")
        result = self.commit(call, mid)
        self.assertEqual((result.status, result.payload["entityRevision"]), ("200 OK", None))
        self.assertEqual(result.payload["result"], {"mediaId": mid, "ready": True, "ordinal": 0, "isPrimary": True,
            "updatedAt": NEW_STAMP, "profileAuthority": "canonical-current-v1"})
        original = self.lookup(call, COMMIT_OPERATION, SECOND, {"prepareOperationId": OP, "mediaId": mid})
        self.assertEqual(original.payload["result"], result.payload["result"]); self.assertEqual(writer.verifies, 1)
        self.assertEqual(self.lookup(call, PREPARE_OPERATION, OP, PAYLOAD).status, "201 Created")
        self.assertEqual(self.commit(call, mid, THIRD).payload["result"], {"error": "photo_unavailable"})
        self.assertEqual(writer.verifies, 1); self.assertEqual(len(db.state["photos"]["actor"]), 1)
        self.assertEqual(call(f"/v1/runtime/profile/photos/uploads/{mid}/lease", REQUEST_METHOD="GET", QUERY_STRING="prepareOperationId=" + OP).status, "404 Not Found")

    def test_unknown_prepare_and_commit_lookup_original_without_another_insert_or_s3(self):
        db, store, service, writer, call = self.setup_service(); db.commit_unknown_once = True
        lost = call("/v1/runtime/profile/photos/prepare", {"operationId": OP, **PAYLOAD})
        self.assertEqual(lost.payload, {"error": "outcome_unknown"})
        found = self.lookup(call, PREPARE_OPERATION, OP, PAYLOAD); mid = found.payload["result"]["mediaId"]
        writer.objects[db.state["media"][mid][3]] = (DATA, "image/png"); db.commit_unknown_once = True
        lost = self.commit(call, mid); self.assertEqual(lost.payload, {"error": "outcome_unknown"})
        found = self.lookup(call, COMMIT_OPERATION, SECOND, {"prepareOperationId": OP, "mediaId": mid})
        self.assertTrue(found.payload["result"]["ready"]); self.assertEqual(writer.verifies, 1)
        self.assertEqual(sum(sql.startswith("INSERT INTO clrs_staging.media_objects") for sql, _ in db.calls), 1)
        self.assertEqual(sum(sql.startswith("INSERT INTO clrs_staging.profile_photos") for sql, _ in db.calls), 1)
        missing = self.lookup(call, COMMIT_OPERATION, THIRD, {"prepareOperationId": OP, "mediaId": mid})
        self.assertEqual(missing.payload["state"], "not_found"); self.assertEqual(writer.verifies, 1)

    def test_finished_native_profile_append_lost_ack_retains_original_and_primary(self):
        db, store, service, writer, call = self.setup_service()
        for index in range(3):
            prep = f"12345678-1234-4234-8234-{100 + index:012d}"
            commit = f"12345678-1234-4234-8234-{200 + index:012d}"
            mid = self.prepare(call, prep)
            writer.objects[db.state["media"][mid][3]] = (DATA, "image/png")
            self.assertEqual(self.commit(call, mid, commit, prep).status, "200 OK")
        original_gallery = copy.deepcopy(db.state["photos"]["actor"])
        db.state["flags"]["actor"] = [1, 1]
        availability = call("/v1/runtime/profile/photos/upload-availability", REQUEST_METHOD="GET")
        self.assertEqual((availability.status, availability.payload), ("200 OK", {
            "canAppend": True, "photoCount": 3, "photoLimit": 20,
            "profileAuthority": "canonical-current-v1"}))
        mid = self.prepare(call)
        lease = call(f"/v1/runtime/profile/photos/uploads/{mid}/lease", REQUEST_METHOD="GET", QUERY_STRING="prepareOperationId=" + OP)
        self.assertEqual(lease.status, "200 OK")
        writer.objects[db.state["media"][mid][3]] = (DATA, "image/png")
        db.commit_unknown_once = True
        self.assertEqual(self.commit(call, mid).payload, {"error": "outcome_unknown"})
        found = self.lookup(call, COMMIT_OPERATION, SECOND, {"prepareOperationId": OP, "mediaId": mid})
        self.assertTrue(found.payload["result"]["ready"])
        self.assertEqual(found.payload["result"]["ordinal"], 3)
        self.assertFalse(found.payload["result"]["isPrimary"])
        self.assertEqual(db.state["photos"]["actor"], original_gallery + [[mid, 3, 0]])
        self.assertEqual(writer.verifies, 4)
        self.assertEqual(self.commit(call, mid).payload["result"], found.payload["result"])
        self.assertEqual(writer.verifies, 4)
        self.assertEqual(db.state["flags"]["actor"], [1, 1])

    def test_append_availability_current_target_and_session_are_not_cached(self):
        db, store, service, writer, call = self.setup_service()
        for flags in ([0, 0], [1, 0], [0, 1], [True, 1]):
            db.state["flags"]["actor"] = flags
            self.assertEqual(call("/v1/runtime/profile/photos/upload-availability", REQUEST_METHOD="GET").status, "404 Not Found")
        db.state["flags"]["actor"] = [1, 1]
        self.assertEqual(call("/v1/runtime/profile/photos/upload-availability", REQUEST_METHOD="GET").status, "404 Not Found")
        db.state["flags"]["actor"] = [0, 0]
        for index in range(3):
            prep = f"12345678-1234-4234-8234-{300 + index:012d}"
            commit = f"12345678-1234-4234-8234-{400 + index:012d}"
            seed_mid = self.prepare(call, prep)
            writer.objects[db.state["media"][seed_mid][3]] = (DATA, "image/png")
            self.assertEqual(self.commit(call, seed_mid, commit, prep).status, "200 OK")
        db.state["flags"]["actor"] = [1, 1]
        self.assertEqual(call("/v1/runtime/profile/photos/upload-availability", REQUEST_METHOD="GET").status, "200 OK")
        db.state["native_origin"] = {"actor": 0}
        self.assertEqual(call("/v1/runtime/profile/photos/upload-availability", REQUEST_METHOD="GET").status, "404 Not Found")
        db.state["native_origin"]["actor"] = 1
        original_photos = copy.deepcopy(db.state["photos"]["actor"])
        imported_mid, _ = photo_identity("actor", THIRD)
        db.state["media"][imported_mid] = [imported_mid, "actor", "profile", "clrs-import-quarantine/imported-original",
            PAYLOAD["mimeType"], PAYLOAD["byteSize"], PAYLOAD["sha256"], "ready", 0, 1, 1]
        db.state["photos"]["actor"] = [[imported_mid, 0, 1]]
        self.assertEqual(call("/v1/runtime/profile/photos/upload-availability", REQUEST_METHOD="GET").status, "404 Not Found")
        db.state["photos"]["actor"] = original_photos; db.state["media"].pop(imported_mid)
        mid = self.prepare(call)
        writer.after_sign = lambda: db.state["flags"].update(actor=[1, 0])
        self.assertEqual(call(f"/v1/runtime/profile/photos/uploads/{mid}/lease", REQUEST_METHOD="GET", QUERY_STRING="prepareOperationId=" + OP).status, "404 Not Found")
        self.assertEqual(db.state["media"][mid][7], "pending")
        self.assertEqual(db.state["photos"]["actor"], original_photos)
        db.state["flags"]["actor"] = [1, 1]
        db.state["sessions"][db.identity.session_id]["revoked_at"] = STAMP
        self.assertEqual(call("/v1/runtime/profile/photos/upload-availability", REQUEST_METHOD="GET").status, "401 Unauthorized")

    def test_owner_session_revocation_and_current_post_sign_authority(self):
        db, store, service, writer, call = self.setup_service(); mid = self.prepare(call)
        borrowed = self.commit(call, photo_identity("peer", OP)[0])
        self.assertEqual(borrowed.payload["result"], {"error": "photo_not_found"}); self.assertEqual(writer.verifies, 0)
        writer.after_sign = lambda: db.state["sessions"][db.identity.session_id].update(revoked_at=STAMP)
        lease = call(f"/v1/runtime/profile/photos/uploads/{mid}/lease", REQUEST_METHOD="GET", QUERY_STRING="prepareOperationId=" + OP)
        self.assertEqual(lease.status, "401 Unauthorized"); self.assertTrue(lease.authenticate)
        self.assertNotIn("url", lease.payload); self.assertEqual(db.state["media"][mid][7], "pending")
        # A fresh B identity cannot consume A's original receipt/hash.
        session, tokens = db.tokens.mint("peer", "device-b", 0, NOW)
        db.state["sessions"][session["session_id"]] = session
        peer = NativeIdentity("peer", True, session["session_id"], NOW, NOW + 900)
        context = service._read(peer, {"prepareOperationId": OP, "mediaId": mid}, tokens["accessToken"])
        self.assertEqual(context, {"error": "photo_not_found"})

    def test_actual_byte_size_mime_mismatch_are_receipted_privacy_and_missing_are_unknown(self):
        for data, mime in ((DATA + b"x", "image/png"), (b"x" * len(DATA), "image/png"), (DATA, "image/jpeg")):
            with self.subTest(mime=mime, bytes=len(data)):
                db, store, service, writer, call = self.setup_service(); mid = self.prepare(call)
                writer.objects[db.state["media"][mid][3]] = (data, mime)
                result = self.commit(call, mid)
                self.assertEqual((result.status, result.payload["result"]), ("409 Conflict", {"error": "photo_verification_failed"}))
                self.assertEqual(db.state["media"][mid][7], "pending"); self.assertFalse(db.state["photos"])
                self.assertEqual(self.lookup(call, COMMIT_OPERATION, SECOND, {"prepareOperationId": OP, "mediaId": mid}).payload["result"], result.payload["result"])
        for failure in ("missing", "privacy", "unsupported", "no-port"):
            with self.subTest(failure=failure):
                db, store, service, writer, call = self.setup_service(writer=failure != "no-port"); mid = self.prepare(call)
                if writer:
                    writer.private = failure != "privacy"; writer.supported = failure != "unsupported"
                result = self.commit(call, mid)
                self.assertEqual(result.status, "503 Service Unavailable"); self.assertNotIn("state", result.payload)
                self.assertEqual(self.lookup(call, COMMIT_OPERATION, SECOND, {"prepareOperationId": OP, "mediaId": mid}).payload["state"], "not_found")

    def test_atomic_rollback_on_association_failure_revocation_or_expired_proof(self):
        for failure in ("association", "revocation", "proof"):
            with self.subTest(failure=failure):
                db, store, service, writer, call = self.setup_service(); mid = self.prepare(call)
                writer.objects[db.state["media"][mid][3]] = (DATA, "image/png")
                if failure == "association": db.fail_contains = "INSERT INTO clrs_staging.profile_photos"
                if failure == "revocation": db.revoke_at_append = True
                if failure == "proof": writer.fail_evidence = True
                result = self.commit(call, mid)
                self.assertIn(result.status, ("503 Service Unavailable", "401 Unauthorized"))
                self.assertEqual(db.state["media"][mid][7], "pending"); self.assertFalse(db.state["photos"])
                self.assertEqual(db.state["profiles"]["actor"], STAMP)
                self.assertNotIn(("actor", COMMIT_OPERATION, SECOND), db.state["receipts"])

    def test_bounded_whitelist_index_photo_cap_and_default_closed_adapter(self):
        db, store, service, writer, call = self.setup_service()
        for changes in ({"byteSize": 0}, {"byteSize": MAX_BYTES + 1}, {"byteSize": True}, {"mimeType": {}},
                {"mimeType": "image/gif"}, {"sha256": "A" * 64}, {"ownerUid": "peer"}):
            result = call("/v1/runtime/profile/photos/prepare", {"operationId": OP, **PAYLOAD, **changes})
            self.assertEqual(result.status, "400 Bad Request")
        db.indexes_ok = False
        self.assertEqual(call("/v1/runtime/profile/photos/prepare", {"operationId": OP, **PAYLOAD}).status, "503 Service Unavailable")
        db.indexes_ok = True; db.state["photos"]["actor"] = []
        for ordinal in range(20):
            prepare_id = f"12345678-1234-4234-8234-{500 + ordinal:012d}"
            mid, key = photo_identity("actor", prepare_id)
            db.state["media"][mid] = [mid, "actor", "profile", key, PAYLOAD["mimeType"], PAYLOAD["byteSize"],
                PAYLOAD["sha256"], "ready", 1, 1, 1]
            db.state["photos"]["actor"].append([mid, ordinal, int(ordinal == 0)])
        limited = call("/v1/runtime/profile/photos/prepare", {"operationId": OP, **PAYLOAD})
        self.assertEqual(limited.payload["result"], {"error": "photo_limit_reached"})
        native = Native(); adapter = RuntimeProfilePhotoUploadsHttp(db.env)
        self.assertEqual(adapter.dispatch(env("/v1/runtime/profile/photos/prepare", {"operationId": OP, **PAYLOAD}), native_service=native, native_configured=True).status, "503 Service Unavailable")
        self.assertFalse(any("DELETE" in sql or "legacy_documents" in sql or "legacy_storage_objects" in sql for sql, _ in db.calls))


if __name__ == "__main__": unittest.main()
