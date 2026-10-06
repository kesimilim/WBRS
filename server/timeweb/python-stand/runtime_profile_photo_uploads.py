"""Native-only pending/ready photos. No S3 credentials, route mount or activation.

The trusted injected writer must prove conditional private PUT/checksum support;
None is the production default. Neither a PUT ACK nor a client URL proves ready.
Existing imported media/readers and their provenance remain untouched.
"""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import re
import threading
import time
from urllib.parse import urlsplit

from runtime_mutations import (RuntimeInvalidRequest, RuntimeRejected,
    RuntimeUnavailable, RECEIPT_QUERY, canonical_json, request_digest)
from runtime_profile import _stamp


PREPARE_OPERATION = "profile.photo.prepare.v1"
COMMIT_OPERATION = "profile.photo.commit.v1"
PREFIX = "clrs-native-profile/"
MAX_BYTES = 5 * 1024 * 1024
MAX_PHOTOS = 20
AUTHORITY = "canonical-current-v1"
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
_MID = re.compile(r"tw-profile-photo-[0-9a-f]{64}")
_MIMES = frozenset({"image/jpeg", "image/png", "image/webp"})
_PROFILE = """SELECT uid, DATE_FORMAT(updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')
 FROM clrs_staging.profiles WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)
 LIMIT 1 FOR SHARE"""
_MEDIA = """SELECT media_id, owner_uid, purpose,
 CASE WHEN OCTET_LENGTH(object_key) <= 128 THEN object_key ELSE NULL END,
 mime_type, byte_size, LOWER(HEX(sha256)), status, legacy_storage_path IS NULL,
 thumbnail_key IS NULL, thumbnail_byte_size IS NULL FROM clrs_staging.media_objects
 WHERE media_id = %s AND CAST(media_id AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE"""
_PHOTOS = """SELECT media_id, ordinal, is_primary FROM clrs_staging.profile_photos
 WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)
 ORDER BY ordinal LIMIT 21 FOR SHARE"""
_PARTS = frozenset({("media_objects", "PRIMARY", 0, 1, "media_id"),
    ("media_objects", "media_objects_object_key_uq", 0, 1, "object_key_sha256"),
    ("profile_photos", "PRIMARY", 0, 1, "uid"), ("profile_photos", "PRIMARY", 0, 2, "media_id"),
    ("profile_photos", "profile_photos_ordinal_uq", 0, 1, "uid"),
    ("profile_photos", "profile_photos_ordinal_uq", 0, 2, "ordinal"),
    ("profile_photos", "profile_one_primary_photo_uq", 0, 1, "uid"),
    ("profile_photos", "profile_one_primary_photo_uq", 0, 2, "primary_slot")})
_INDEXES = """SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, SUB_PART
 FROM information_schema.statistics WHERE TABLE_SCHEMA = 'clrs_staging'
 AND ((TABLE_NAME = 'media_objects' AND INDEX_NAME IN ('PRIMARY', 'media_objects_object_key_uq'))
 OR (TABLE_NAME = 'profile_photos' AND INDEX_NAME IN
 ('PRIMARY', 'profile_photos_ordinal_uq', 'profile_one_primary_photo_uq'))) LIMIT 21"""
NATIVE_GALLERY_SQL = """SELECT p.media_id, p.ordinal, p.is_primary, p.firebase_image_id,
 m.media_id, m.owner_uid, m.purpose, CASE WHEN OCTET_LENGTH(m.object_key) <= 128 THEN m.object_key ELSE NULL END, m.mime_type, m.byte_size,
 LOWER(HEX(m.sha256)), m.status, m.legacy_storage_path IS NULL,
 m.thumbnail_key IS NULL, m.thumbnail_byte_size IS NULL
 FROM clrs_staging.profile_photos p JOIN clrs_staging.media_objects m
 ON m.media_id = p.media_id AND CAST(m.media_id AS BINARY) = CAST(p.media_id AS BINARY)
 WHERE p.uid = %s AND CAST(p.uid AS BINARY) = CAST(%s AS BINARY)
 ORDER BY p.ordinal LIMIT 21 FOR SHARE OF p, m"""
_INITIAL = """SELECT profile_details_saved, registration_complete,
 JSON_TYPE(legacy_raw) = 'OBJECT' AND JSON_LENGTH(legacy_raw) = 0 FROM clrs_staging.profiles
 WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE"""
_ERRORS = {"profile_not_found": 404, "photo_not_found": 404, "photo_limit_reached": 409,
    "photo_verification_failed": 409, "photo_unavailable": 409}


class PhotoUploadTargetRejected(RuntimeRejected):
    """Healthy actor has no current upload target; HTTP 404, never logout."""


class PhotoUploadVerificationFailed(Exception):
    """Only a proved actual-object size/checksum/MIME mismatch, not IO failure."""


def _uuid(value):
    if not isinstance(value, str) or _UUID.fullmatch(value) is None:
        raise RuntimeInvalidRequest()
    return value


def validate_prepare(payload):
    if (type(payload) is not dict or set(payload) != {"sha256", "byteSize", "mimeType"}
            or not isinstance(payload["sha256"], str) or re.fullmatch(r"[0-9a-f]{64}", payload["sha256"]) is None
            or type(payload["byteSize"]) is not int or not 1 <= payload["byteSize"] <= MAX_BYTES
            or not isinstance(payload["mimeType"], str) or payload["mimeType"] not in _MIMES):
        raise RuntimeInvalidRequest()
    return dict(payload)


def validate_commit(payload):
    if (type(payload) is not dict or set(payload) != {"prepareOperationId", "mediaId"}
            or not isinstance(payload["mediaId"], str) or _MID.fullmatch(payload["mediaId"]) is None):
        raise RuntimeInvalidRequest()
    _uuid(payload["prepareOperationId"])
    return dict(payload)


def photo_identity(uid, operation_id):
    digest = hashlib.sha256(b"clrs-native-profile-photo-v1\0" + canonical_json([uid, _uuid(operation_id)])).hexdigest()
    return "tw-profile-photo-" + digest, PREFIX + digest


def _prepared(mid, payload):
    return {"mediaId": mid, **payload, "status": "pending", "profileAuthority": AUTHORITY}


def native_gallery(rows, uid):
    if len(rows) > MAX_PHOTOS: raise PhotoUploadTargetRejected()
    ids = set()
    for ordinal, row in enumerate(rows):
        if (len(row) != 15 or row[0] in ids or row[0] != row[4] or row[3] is not None
                or type(row[1]) is not int or row[1] != ordinal or type(row[2]) is not int or row[2] != int(ordinal == 0)
                or row[5] != uid or row[6] != "profile" or row[11] != "ready"
                or any(type(value) is not int or value != 1 for value in row[12:])
                or not isinstance(row[0], str) or _MID.fullmatch(row[0]) is None
                or row[7] != PREFIX + row[0][len("tw-profile-photo-"):]):
            raise PhotoUploadTargetRejected()
        validate_prepare({"mimeType": row[8], "byteSize": row[9], "sha256": row[10]}); ids.add(row[0])
    return [list(row) for row in rows]


def photo_record(uid, request, row):
    mid, key = photo_identity(uid, request["prepareOperationId"])
    if (request["mediaId"] != mid or len(row) != 11 or tuple(row[:4]) != (mid, uid, "profile", key)
            or any(type(value) is not int or value != 1 for value in row[8:]) or row[7] not in ("pending", "ready")):
        raise PhotoUploadTargetRejected()
    fields = validate_prepare({"mimeType": row[4], "byteSize": row[5], "sha256": row[6]})
    return fields, {"key": key, "size": fields["byteSize"], "sha256": fields["sha256"], "content_type": fields["mimeType"]}


def validate_commit_response(request, response, context, photo):
    if (photo is None or set(response) != {"mediaId", "ready", "ordinal", "isPrimary", "updatedAt", "profileAuthority"}
            or response["mediaId"] != request["mediaId"] or response["ready"] is not True
            or type(response["ordinal"]) is not int or response["ordinal"] != photo[1]
            or type(response["isPrimary"]) is not bool or response["isPrimary"] != bool(photo[2])
            or response["profileAuthority"] != AUTHORITY or _stamp(response["updatedAt"]) > context["updatedAt"]):
        raise PhotoUploadTargetRejected()


class RuntimeProfilePhotoUploadsService:
    def __init__(self, store, *, writer=None, monotonic=time.monotonic, clock=time.time):
        # Strict-table legacy roles do not grant the needed photo writes.
        if (store is None or store._env.get("CLRS_RUNTIME_PERMISSION_MODEL") != "provider-database-v1"
                or not callable(monotonic) or not callable(clock) or writer is not None and not all(callable(getattr(writer, name, None))
                    for name in ("prepare_put", "verify_ready", "require_verified"))):
            raise RuntimeUnavailable()
        self._store = store; self._writer = writer; self._clock = monotonic; self._wall = clock
        self._slots = threading.BoundedSemaphore(2)
        for operation, guard in ((PREPARE_OPERATION, self._prepare_guard), (COMMIT_OPERATION, self._commit_guard)):
            store.register_replay_guard(operation, guard, response_guard=True, operation_id_guard=True)

    def _profile(self, cursor, execute, uid, write=False):
        execute(_INDEXES); rows = cursor.fetchall()
        if (len(rows) != len(_PARTS) or any(len(row) != 6 or row[-1] is not None for row in rows)
                or {tuple(row[:5]) for row in rows} != _PARTS):
            raise RuntimeUnavailable()
        execute(_PROFILE.replace("FOR SHARE", "FOR UPDATE") if write else _PROFILE, (uid, uid))
        row = cursor.fetchone()
        if row is None: return None
        if len(row) != 2 or row[0] != uid: raise RuntimeUnavailable()
        return _stamp(row[1])

    @staticmethod
    def _photos(cursor, execute, uid, write=False):
        execute(_PHOTOS.replace("FOR SHARE", "FOR UPDATE") if write else _PHOTOS, (uid, uid))
        rows = cursor.fetchall()
        if (len(rows) > MAX_PHOTOS or any(len(row) != 3 or type(row[1]) is not int or row[1] != ordinal
                or type(row[2]) is not int or row[2] != int(ordinal == 0) for ordinal, row in enumerate(rows))
                or len({row[0] for row in rows}) != len(rows)):
            raise RuntimeUnavailable()
        return [list(row) for row in rows]

    def _upload_target(self, cursor, execute, uid, write=False, *, completed_only=False):
        execute(_INITIAL.replace("FOR SHARE", "FOR UPDATE") if write else _INITIAL, (uid, uid))
        row = cursor.fetchone()
        # A finished native gallery remains writable. Transitional flags and
        # imported/mixed galleries have no append authority in this adapter.
        if (row is None or len(row) != 3 or any(type(value) is not int for value in row)
                or row[2] != 1 or tuple(row[:2]) not in ((0, 0), (1, 1))
                or completed_only and tuple(row[:2]) != (1, 1)):
            raise PhotoUploadTargetRejected()
        sql = NATIVE_GALLERY_SQL.replace("FOR SHARE OF p, m", "FOR UPDATE OF p, m") if write else NATIVE_GALLERY_SQL
        execute(sql, (uid, uid)); rows = native_gallery(cursor.fetchall(), uid)
        if [row[:3] for row in rows] != self._photos(cursor, execute, uid, write): raise PhotoUploadTargetRejected()
        if tuple(row[:2]) == (1, 1) and len(rows) < 3: raise PhotoUploadTargetRejected()
        return rows

    def upload_availability(self, identity, *, access_token):
        if self._writer is None: raise RuntimeUnavailable()
        def action(cursor, execute, uid):
            if self._profile(cursor, execute, uid) is None: raise PhotoUploadTargetRejected()
            photos = self._upload_target(cursor, execute, uid, completed_only=True)
            return {"canAppend": len(photos) < MAX_PHOTOS, "photoCount": len(photos),
                "photoLimit": MAX_PHOTOS, "profileAuthority": AUTHORITY}
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def _context(self, cursor, execute, uid, payload, write=False):
        stamp = self._profile(cursor, execute, uid, write)
        if stamp is None: return {"error": "profile_not_found"}
        mid, key = photo_identity(uid, payload["prepareOperationId"])
        if payload["mediaId"] != mid: return {"error": "photo_not_found"}
        execute(_MEDIA.replace("FOR SHARE", "FOR UPDATE") if write else _MEDIA, (mid, mid))
        row = cursor.fetchone()
        if row is None: return {"error": "photo_not_found"}
        fields, record = photo_record(uid, payload, row)
        execute(RECEIPT_QUERY + " FOR SHARE", (uid, PREPARE_OPERATION, payload["prepareOperationId"]))
        receipt = cursor.fetchone()
        if receipt is None: raise PhotoUploadTargetRejected()
        status, wrapper, revision = self._store._receipt(receipt, request_digest(fields))
        if (status != 201 or revision is not None or wrapper != {"request": fields, "response": _prepared(mid, fields)}):
            raise PhotoUploadTargetRejected()
        return {"record": record,
            "status": row[7], "updatedAt": stamp, "photos": self._photos(cursor, execute, uid, write)}

    def _prepare_guard(self, cursor, execute, uid, op, request, response):
        validate_prepare(request); _uuid(op)
        if set(response) == {"error"} and response["error"] in ("profile_not_found", "photo_limit_reached"): return
        mid, _ = photo_identity(uid, op)
        context = self._context(cursor, execute, uid, {"prepareOperationId": op, "mediaId": mid})
        if "error" in context or response != _prepared(mid, request): raise PhotoUploadTargetRejected()

    def _commit_guard(self, cursor, execute, uid, op, request, response):
        validate_commit(request); _uuid(op)
        if set(response) == {"error"} and response["error"] in _ERRORS: return
        context = self._context(cursor, execute, uid, request)
        if "error" in context or context["status"] != "ready": raise PhotoUploadTargetRejected()
        photo = next((row for row in context["photos"] if row[0] == request["mediaId"]), None)
        validate_commit_response(request, response, context, photo)

    def prepare(self, identity, operation_id, payload, *, access_token):
        _uuid(operation_id); request = validate_prepare(payload)
        def action(cursor, execute, uid):
            self._upload_target(cursor, execute, uid, True)
            if self._profile(cursor, execute, uid, True) is None: return 404, {"error": "profile_not_found"}, None
            if len(self._photos(cursor, execute, uid, True)) >= MAX_PHOTOS: return 409, {"error": "photo_limit_reached"}, None
            mid, key = photo_identity(uid, operation_id)
            execute("""INSERT INTO clrs_staging.media_objects
 (media_id, owner_uid, purpose, object_key, mime_type, byte_size, sha256, status, legacy_storage_path)
 VALUES (%s, %s, 'profile', %s, %s, %s, %s, 'pending', NULL)""",
                (mid, uid, key, request["mimeType"], request["byteSize"], bytes.fromhex(request["sha256"])))
            if cursor.rowcount != 1: raise RuntimeUnavailable()
            execute(_MEDIA.replace("FOR SHARE", "FOR UPDATE"), (mid, mid))
            row = cursor.fetchone()
            if tuple(row or ()) != (mid, uid, "profile", key, request["mimeType"], request["byteSize"], request["sha256"], "pending", 1, 1, 1):
                raise RuntimeUnavailable()
            return 201, _prepared(mid, request), None
        return self._store.mutate(identity, PREPARE_OPERATION, operation_id, request, action, access_token=access_token)

    def _read(self, identity, request, token, *, upload_target=False):
        def action(cursor, execute, uid):
            if upload_target: self._upload_target(cursor, execute, uid)
            return self._context(cursor, execute, uid, request)
        return self._store.read_authenticated(identity, action, access_token=token)

    def upload_lease(self, identity, media_id, prepare_operation_id, *, access_token):
        request = validate_commit({"mediaId": media_id, "prepareOperationId": prepare_operation_id})
        before = self._read(identity, request, access_token, upload_target=True)
        if "error" in before or before["status"] != "pending": raise PhotoUploadTargetRejected()
        if self._writer is None or not self._slots.acquire(blocking=False): raise RuntimeUnavailable()
        cancel = threading.Event(); deadline = self._clock() + 5
        try:
            lease = self._writer.prepare_put(dict(before["record"]), deadline=deadline, cancel=cancel)
            if self._clock() >= deadline or type(lease) is not dict or set(lease) != {"url", "headers", "expiresAt"}: raise RuntimeUnavailable()
            record = before["record"]
            headers = {"Content-Type": record["content_type"], "Content-Length": str(record["size"]),
                "If-None-Match": "*", "x-amz-checksum-sha256": base64.b64encode(bytes.fromhex(record["sha256"])).decode(),
                "x-amz-content-sha256": record["sha256"]}
            if type(lease["url"]) is not str or len(lease["url"]) > 4096 or lease["headers"] != headers: raise RuntimeUnavailable()
            url = urlsplit(lease["url"])
            if (url.scheme != "https" or url.netloc != "s3.twcstorage.ru" or url.fragment or not url.query
                    or not url.path.endswith("/" + record["key"]) or len(url.path.split("/")) != 4): raise RuntimeUnavailable()
            _stamp(lease["expiresAt"])
            remaining = datetime.strptime(lease["expiresAt"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp() - self._wall()
            if not 0 < remaining <= 60: raise RuntimeUnavailable()
            # The port owns TTL/proof checking. Repeat SQL authority after signing.
            after = self._read(identity, request, access_token, upload_target=True)
            if "error" in after or after["status"] != "pending" or after["record"] != record: raise PhotoUploadTargetRejected()
            return {"mediaId": media_id, "method": "PUT", **lease, "byteSize": record["size"], "mimeType": record["content_type"], "sha256": record["sha256"]}
        finally:
            cancel.set(); self._slots.release()

    def commit(self, identity, operation_id, payload, *, access_token):
        _uuid(operation_id); request = validate_commit(payload)
        original = self._store.lookup(identity, COMMIT_OPERATION, operation_id, payload=request, access_token=access_token)
        if original.payload["state"] != "not_found": return original
        cancel = None; slot_owned = False
        try:
            before = self._read(identity, request, access_token, upload_target=True); evidence = None; mismatch = False
            if "error" not in before and before["status"] == "pending":
                if self._writer is None or not self._slots.acquire(blocking=False): raise RuntimeUnavailable()
                cancel = threading.Event(); deadline = self._clock() + 8
                slot_owned = True
                try: evidence = self._writer.verify_ready(dict(before["record"]), deadline=deadline, cancel=cancel)
                except PhotoUploadVerificationFailed: mismatch = True
                if self._clock() >= deadline: raise RuntimeUnavailable()
            def action(cursor, execute, uid):
                self._upload_target(cursor, execute, uid, True)
                current = self._context(cursor, execute, uid, request, True)
                if "error" in current: return _ERRORS[current["error"]], {"error": current["error"]}, None
                if "error" in before or current["record"] != before["record"]: raise PhotoUploadTargetRejected()
                # Ready is replayable only through its already stored ORIGINAL
                # commit receipt. A different operation never promotes a ready row.
                if current["status"] == "ready": return 409, {"error": "photo_unavailable"}, None
                mid = request["mediaId"]
                photo = next((row for row in current["photos"] if row[0] == mid), None)
                if current["status"] == "pending":
                    if mismatch: return 409, {"error": "photo_verification_failed"}, None
                    if len(current["photos"]) >= MAX_PHOTOS: return 409, {"error": "photo_limit_reached"}, None
                    if photo is not None or evidence is None: raise RuntimeUnavailable()
                    self._writer.require_verified(evidence, current["record"])
                    ordinal = len(current["photos"])
                    execute("""UPDATE clrs_staging.media_objects SET status = 'ready', updated_at = UTC_TIMESTAMP(6)
     WHERE media_id = %s AND CAST(media_id AS BINARY) = CAST(%s AS BINARY)
     AND owner_uid = %s AND purpose = 'profile' AND status = 'pending'""", (mid, mid, uid))
                    if cursor.rowcount != 1: raise RuntimeUnavailable()
                    execute("""INSERT INTO clrs_staging.profile_photos (uid, media_id, ordinal, is_primary, firebase_image_id)
     VALUES (%s, %s, %s, %s, NULL)""", (uid, mid, ordinal, int(ordinal == 0)))
                    if cursor.rowcount != 1: raise RuntimeUnavailable()
                    execute("""UPDATE clrs_staging.profiles SET updated_at = GREATEST(UTC_TIMESTAMP(6), updated_at + INTERVAL 1 MICROSECOND)
     WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) AND updated_at = CAST(%s AS DATETIME(6))""",
                        (uid, uid, current["updatedAt"][:-1].replace("T", " ")))
                    if cursor.rowcount != 1: raise RuntimeUnavailable()
                    after = self._context(cursor, execute, uid, request, True)
                    self._writer.require_verified(evidence, after["record"])
                    if (after["status"] != "ready" or after["updatedAt"] <= current["updatedAt"]
                            or after["photos"] != current["photos"] + [[mid, ordinal, int(ordinal == 0)]]): raise RuntimeUnavailable()
                    current = after; photo = current["photos"][-1]
                if photo is None: raise PhotoUploadTargetRejected()
                return 200, {"mediaId": mid, "ready": True, "ordinal": photo[1], "isPrimary": bool(photo[2]),
                    "updatedAt": current["updatedAt"], "profileAuthority": AUTHORITY}, None
            return self._store.mutate(identity, COMMIT_OPERATION, operation_id, request, action, access_token=access_token)
        finally:
            if cancel is not None: cancel.set()
            if slot_owned: self._slots.release()
