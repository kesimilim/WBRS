"""Independent current-profile photo reads; no route, upload, grant or factory.

Only exact retained original-photo associations are supported. SQL authority is
fresh on every descriptor/fetch and again immediately before the first byte.
The private S3 adapter verifies the entire object into an anonymous private
spool; neither an object key nor a URL is a public response field.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import hmac
import math
import os
import stat
import tempfile
import threading
import time

from legacy_conversation_payload import OpaqueReferences, LegacyInvalid, document, payload_digest
from legacy_private_media import VerifiedMediaLease, CHUNK_BYTES, _metadata
from media_promotion_acknowledgement import VerifiedMediaPromotion, SOURCE
from native_credentials import unique_json
from private_media_s3 import PrivateMediaS3
from profile_photo_projector import VerifiedSourceSnapshot, _SOURCE_CAPS
from profile_photo_review import (SourcePhotoDocument, ReadyPhotoEvidence,
    ProfilePhotoAssociation, prepare_profile_photo_review, _identifier, _sha,
    MAX_PHOTOS, STRICT_GALLERY_POLICY, AVAILABLE_GALLERY_POLICY)
from profile_visibility import VisibilityAccount, CanonicalVisibility, evaluate_profile_visibility
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_reads import _timestamp


MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_PAGE = 30
MAX_PUBLIC_BYTES = 65_536
REFERENCE_SECONDS = 60
DOWNLOAD_SECONDS = 50
MAX_TOKEN_CHARS = 4096
GALLERY_ORDER_POLICY = "reviewed-source-document-id-binary-asc-v1"
GALLERY_AVAILABLE_ORDER_POLICY = "reviewed-source-document-id-binary-asc-available-originals-v2"
READ_TABLES = frozenset({"accounts", "profiles", "profile_photos", "media_objects",
    "legacy_source", "legacy_documents", "legacy_storage_objects"})
_MEDIA_COLUMNS = ("media_id", "owner_uid", "purpose", "object_key", "thumbnail_key",
    "mime_type", "byte_size", "thumbnail_byte_size", "sha256", "status", "legacy_storage_path")
_STORAGE_COLUMNS = ("source_bucket", "source_path", "source_metadata", "source_size",
    "source_sha256", "target_key", "target_sha256", "copied_at")


class RuntimeProfilePhotoNotFound(RuntimeRejected):
    """No currently authorized, proven photo resource; map to 404, not logout."""


ACTOR_SQL = """SELECT uid, disabled, lifecycle FROM clrs_staging.accounts
 WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE"""
TARGET_SQL = """SELECT a.uid, a.disabled, a.lifecycle, p.uid,
 p.profile_details_saved, p.registration_complete,
 DATE_FORMAT(p.invisible_until, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),
 CASE WHEN JSON_TYPE(p.legacy_raw) = 'OBJECT' AND
 OCTET_LENGTH(CAST(p.legacy_raw AS CHAR CHARACTER SET utf8mb4)) <= 131072
 THEN p.legacy_raw ELSE NULL END,
 DATE_FORMAT(p.updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')
 FROM clrs_staging.accounts AS a JOIN clrs_staging.profiles AS p
 ON p.uid = a.uid AND CAST(p.uid AS BINARY) = CAST(a.uid AS BINARY)
 WHERE a.uid = %s AND CAST(a.uid AS BINARY) = CAST(%s AS BINARY)
 LIMIT 1 FOR SHARE OF a, p"""
PHOTOS_SQL = """SELECT uid, media_id, ordinal, is_primary, firebase_image_id
 FROM clrs_staging.profile_photos WHERE uid = %s
 AND CAST(uid AS BINARY) = CAST(%s AS BINARY) ORDER BY ordinal LIMIT 51 FOR SHARE"""
SOURCE_SQL = "SELECT source_project, source_database, source_bucket FROM clrs_staging.legacy_source WHERE singleton = 1 LIMIT 1 FOR SHARE"
_DOC_COLUMNS = "CASE WHEN OCTET_LENGTH(firebase_path) <= 2048 THEN firebase_path ELSE NULL END, CASE WHEN OCTET_LENGTH(collection_path) <= 1024 THEN collection_path ELSE NULL END, CASE WHEN CHAR_LENGTH(document_id) <= 191 AND OCTET_LENGTH(document_id) <= 764 THEN document_id ELSE NULL END, CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= 131072 THEN encoded_payload ELSE NULL END, payload_sha256"
ROOT_SQL = "SELECT " + _DOC_COLUMNS + " FROM clrs_staging.legacy_documents WHERE firebase_path_sha256 = %s AND CAST(firebase_path AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE"
GALLERY_SQL = "SELECT " + _DOC_COLUMNS + " FROM clrs_staging.legacy_documents WHERE collection_path_sha256 = %s AND CAST(collection_path AS BINARY) = CAST(%s AS BINARY) ORDER BY CAST(document_id AS BINARY) LIMIT 51 FOR SHARE"


def media_sql(count):
    if type(count) is not int or not 1 <= count <= MAX_PHOTOS:
        raise RuntimeUnavailable()
    columns = list(_MEDIA_COLUMNS)
    columns[3] = "CASE WHEN OCTET_LENGTH(object_key) <= 128 THEN object_key ELSE NULL END"
    columns[4] = "CASE WHEN thumbnail_key IS NULL THEN NULL ELSE '' END"
    columns[10] = "CASE WHEN OCTET_LENGTH(legacy_storage_path) <= 1024 THEN legacy_storage_path ELSE NULL END"
    return "SELECT " + ", ".join(columns) + " FROM clrs_staging.media_objects WHERE media_id IN (" + ",".join("%s" for _ in range(count)) + ") LIMIT 51 FOR SHARE"


def storage_sql(count):
    if type(count) is not int or not 1 <= count <= MAX_PHOTOS:
        raise RuntimeUnavailable()
    columns = list(_STORAGE_COLUMNS)
    columns[1] = "CASE WHEN OCTET_LENGTH(source_path) <= 1024 THEN source_path ELSE NULL END"
    columns[2] = "CASE WHEN OCTET_LENGTH(CAST(source_metadata AS CHAR CHARACTER SET utf8mb4)) <= 65536 THEN source_metadata ELSE NULL END"
    columns[5] = "CASE WHEN OCTET_LENGTH(target_key) <= 128 THEN target_key ELSE NULL END"
    return "SELECT " + ", ".join(columns) + " FROM clrs_staging.legacy_storage_objects WHERE source_bucket = %s AND source_path_sha256 IN (" + ",".join("%s" for _ in range(count)) + ") LIMIT 51 FOR SHARE"


def _uid(value):
    try:
        return _identifier(value)
    except Exception:
        raise RuntimeInvalidRequest() from None


def _digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _hash(value):
    return hashlib.sha256(value.encode("utf-8")).digest()


def _rows(cursor, execute, sql, params=()):
    try:
        execute(sql, params)
        return cursor.fetchall()
    except (RuntimeRejected, RuntimeUnavailable):
        raise
    except Exception:
        # Missing SELECT, transport failure and SQL/schema mismatch describe
        # an unavailable adapter, not evidence that a user's photo is absent.
        raise RuntimeUnavailable() from None


def _account(rows, uid):
    if (len(rows) != 1 or not isinstance(rows[0], (tuple, list)) or len(rows[0]) != 3
            or rows[0][0] != uid or type(rows[0][1]) is not int or rows[0][1] != 0
            or type(rows[0][2]) is not str or rows[0][2] != "active"):
        raise RuntimeProfilePhotoNotFound()
    return VisibilityAccount(*rows[0])


def _target(cursor, execute, target_uid, actor, now):
    rows = _rows(cursor, execute, TARGET_SQL, (target_uid, target_uid))
    if (len(rows) != 1 or not isinstance(rows[0], (tuple, list)) or len(rows[0]) != 9
            or rows[0][0] != target_uid or rows[0][3] != target_uid):
        raise RuntimeProfilePhotoNotFound()
    row = rows[0]
    account = _account([row[:3]], target_uid)
    raw = row[7]
    try:
        if type(raw) is bytes:
            raw = raw.decode("utf-8", "strict")
        if type(raw) is str:
            if len(raw.encode("utf-8")) > 131072: raise ValueError()
            raw = unique_json(raw)
        if type(raw) is not dict: raise ValueError()
        canonical_json(raw, max_bytes=131072)
        _timestamp(row[8])
        if (type(row[4]) is not int or row[4] not in (0, 1)
                or type(row[5]) is not int or row[5] not in (0, 1)):
            raise ValueError()
        _timestamp(row[6], nullable=True)
        if target_uid != actor.uid:
            decision = evaluate_profile_visibility(target=account, actor=actor,
                current_actor_uid=actor.uid,
                canonical=CanonicalVisibility(target_uid, row[4], row[5], row[6]),
                legacy_raw=raw, origin="native" if raw == {} else "legacy", now=now)
            if not decision.visible: raise ValueError()
    except Exception:
        raise RuntimeProfilePhotoNotFound() from None
    # These internal values never form a public DTO or log entry.
    return account, raw, [*row[:7], _digest(canonical_json(raw, max_bytes=131072).decode()), row[8]]


def _associations(cursor, execute, uid):
    rows = _rows(cursor, execute, PHOTOS_SQL, (uid, uid))
    if len(rows) > MAX_PHOTOS: raise RuntimeProfilePhotoNotFound()
    result = []; ids = set(); image_ids = set()
    for ordinal, row in enumerate(rows):
        if (not isinstance(row, (tuple, list)) or len(row) != 5 or row[0] != uid
                or type(row[2]) is not int or row[2] != ordinal
                or type(row[3]) is not int or row[3] != int(ordinal == 0)):
            raise RuntimeProfilePhotoNotFound()
        try:
            _identifier(row[1])
            if row[4] is not None: _identifier(row[4])
        except Exception:
            raise RuntimeProfilePhotoNotFound() from None
        if row[1] in ids or row[4] is not None and row[4] in image_ids:
            raise RuntimeProfilePhotoNotFound()
        ids.add(row[1]); image_ids.add(row[4])
        result.append(ProfilePhotoAssociation(*row))
    return tuple(result)


def _source_document(row, collection):
    if (not isinstance(row, (tuple, list)) or len(row) != 5
            or row[1] != collection or type(row[2]) is not str
            or row[0] != collection + "/" + row[2]):
        raise RuntimeProfilePhotoNotFound()
    _identifier(row[2])
    return SourcePhotoDocument(row[0], document(row[3]), _sha(row[4]))


class _PhotoLease(VerifiedMediaLease):
    def __init__(self, *args, before_first_byte, **kwargs):
        super().__init__(*args, **kwargs)
        self._before_first_byte = before_first_byte

    def iter_bytes(self):
        try:
            # Even an entered lease may wait before iteration. Do not rely on
            # the earlier post-download proof to authorize its first byte.
            self._before_first_byte()
            yield from super().iter_bytes()
        except (RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable):
            self.close()
            raise
        except Exception:
            self.close()
            raise RuntimeUnavailable() from None


class RuntimeProfilePhotosService:
    def __init__(self, store, cursor_key, *, private_s3, expected_bucket,
            expected_owner, source_snapshot, media_promotion, spool_directory,
            gallery_order_policy,
            clock=time.time, monotonic=time.monotonic):
        if (store is None or not callable(getattr(store, "read_authenticated", None))
                or type(cursor_key) is not bytes or len(cursor_key) != 32
                or type(private_s3) is not PrivateMediaS3
                or private_s3._bucket != expected_bucket or private_s3._owner != expected_owner
                or type(source_snapshot) is not VerifiedSourceSnapshot or source_snapshot not in _SOURCE_CAPS
                or type(media_promotion) is not VerifiedMediaPromotion
                or gallery_order_policy not in (GALLERY_ORDER_POLICY, GALLERY_AVAILABLE_ORDER_POLICY)
                or not callable(clock) or not callable(monotonic)):
            raise RuntimeUnavailable()
        self._store = store; self._s3 = private_s3; self._source = source_snapshot
        self._promotion = media_promotion; self._directory = spool_directory
        self._clock = clock; self._monotonic = monotonic; self._gallery_policy = gallery_order_policy
        self._gallery_original_policy = (AVAILABLE_GALLERY_POLICY
            if gallery_order_policy == GALLERY_AVAILABLE_ORDER_POLICY else STRICT_GALLERY_POLICY)
        self._codec = OpaqueReferences(hmac.digest(cursor_key,
            b"clrs-runtime-current-profile-photos-v1\0", "sha256"))
        self._slots = threading.BoundedSemaphore(2)
        self._lock = threading.Lock(); self._inflight = set(); self._leases = set(); self._closed = False

    def _check(self):
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
        try:
            self._promotion.require_current(self._clock())
        except Exception:
            raise RuntimeUnavailable() from None

    def _context(self, cursor, execute, actor_uid, target_uid):
        self._check()
        actor = _account(_rows(cursor, execute, ACTOR_SQL, (actor_uid, actor_uid)), actor_uid)
        account, raw, before = _target(cursor, execute, target_uid, actor,
            datetime.fromtimestamp(self._clock(), timezone.utc))
        associations = _associations(cursor, execute, target_uid)
        records = []
        context = {"sourceProof": self._source.receipt_digest, "galleryOrderPolicy": self._gallery_policy, "target": before,
            "rows": [list(vars(row).values()) for row in associations]}
        if associations:
            if _rows(cursor, execute, SOURCE_SQL) != [(SOURCE["project"], SOURCE["database"], SOURCE["bucket"])]:
                raise RuntimeProfilePhotoNotFound()
            root_path = "users/" + target_uid
            roots = _rows(cursor, execute, ROOT_SQL, (_hash(root_path), root_path))
            if len(roots) != 1: raise RuntimeProfilePhotoNotFound()
            root = _source_document(roots[0], "users")
            collection = root_path + "/images"
            gallery_rows = _rows(cursor, execute, GALLERY_SQL, (_hash(collection), collection))
            if len(gallery_rows) > MAX_PHOTOS: raise RuntimeProfilePhotoNotFound()
            gallery = [_source_document(row, collection) for row in gallery_rows]
            media_rows = _rows(cursor, execute, media_sql(len(associations)), tuple(row.media_id for row in associations))
            if len(media_rows) != len(associations): raise RuntimeProfilePhotoNotFound()
            media = {}
            for row in media_rows:
                if (not isinstance(row, (tuple, list)) or len(row) != 11
                        or row[0] not in {x.media_id for x in associations} or row[0] in media):
                    raise RuntimeProfilePhotoNotFound()
                media[row[0]] = dict(zip(_MEDIA_COLUMNS, row))
            paths = [media[row.media_id]["legacy_storage_path"] for row in associations]
            if (any(type(path) is not str for path in paths) or len(set(paths)) != len(paths)):
                raise RuntimeProfilePhotoNotFound()
            storage_rows = _rows(cursor, execute, storage_sql(len(paths)), (SOURCE["bucket"], *(_hash(path) for path in paths)))
            if len(storage_rows) != len(paths): raise RuntimeProfilePhotoNotFound()
            storage = {}
            for row in storage_rows:
                if (not isinstance(row, (tuple, list)) or len(row) != 8
                        or row[1] not in paths or row[1] in storage):
                    raise RuntimeProfilePhotoNotFound()
                storage[row[1]] = dict(zip(_STORAGE_COLUMNS, row))
            evidence = [ReadyPhotoEvidence(media[row.media_id], storage[path])
                for row, path in zip(associations, paths)]
            # The trusted caller opts into the SAME explicitly reviewed policy
            # as the projector. Include every source ID, including the gallery
            # original that coincides with the primary. Never reverse-infer a
            # source order from a possibly edited/deduplicated relation.
            order = [row[2] for row in gallery_rows]
            if order != sorted(order, key=lambda value: value.encode("utf-8")):
                raise RuntimeProfilePhotoNotFound()
            plan = prepare_profile_photo_review(account=account, canonical_legacy_raw=raw,
                root_document=root, gallery_documents=gallery, gallery_complete=True,
                ready_evidence=evidence, existing_rows=[],
                source_archive_sha256=self._source.archive_sha256, reviewed_gallery_order=order,
                gallery_original_policy=self._gallery_original_policy)
            if plan.state != "reviewable" or plan.rows != associations:
                raise RuntimeProfilePhotoNotFound()
            provenance = []
            for item in evidence:
                value = {"media": {key: _sha(val) if key == "sha256" else val for key, val in item.media.items()},
                    "storage": {key: _sha(val) if key in {"source_sha256", "target_sha256"}
                        else _metadata(val) if key == "source_metadata"
                        else val.isoformat() if type(val) is datetime else val
                        for key, val in item.storage.items()}}
                provenance.append(_digest(canonical_json(value, max_bytes=262144).decode()))
                record = {"key": item.media["object_key"], "size": item.media["byte_size"],
                    "sha256": _sha(item.media["sha256"]), "content_type": item.media["mime_type"]}
                if not 0 < record["size"] <= MAX_IMAGE_BYTES:
                    raise RuntimeProfilePhotoNotFound()
                records.append(record)
            context.update(plan=plan.fingerprint, provenance=provenance)
        _, _, after = _target(cursor, execute, target_uid, actor,
            datetime.fromtimestamp(self._clock(), timezone.utc))
        if after != before or _associations(cursor, execute, target_uid) != associations:
            raise RuntimeProfilePhotoNotFound()
        self._check()
        return {"actorHash": _digest(actor_uid), "targetHash": _digest(target_uid),
            "contextHash": _digest(canonical_json(context, max_bytes=262144).decode()),
            # Full UID/source image IDs are already committed by contextHash.
            # Keeping only the token resource here bounds the store's private
            # 64 KiB result even for fifty maximal Unicode source identifiers.
            "rows": [[row.media_id, row.ordinal, row.is_primary] for row in associations], "records": records}

    def _proof(self, identity, access_token, target_uid):
        def action(cursor, execute, actor_uid):
            try:
                return self._context(cursor, execute, _uid(actor_uid), target_uid)
            except (RuntimeRejected, RuntimeUnavailable):
                raise
            except Exception:
                raise RuntimeProfilePhotoNotFound() from None
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def _open(self, purpose, value, proof, expected_kind):
        try:
            if type(value) is not str or not 1 <= len(value) <= MAX_TOKEN_CHARS: raise ValueError()
            token = self._codec.open(purpose, value)
            now = int(self._clock())
            if (token.get("kind") != expected_kind or token.get("v") != 1 or type(token.get("v")) is not int
                    or token.get("actorHash") != proof["actorHash"] or token.get("targetHash") != proof["targetHash"]
                    or token.get("contextHash") != proof["contextHash"]
                    or type(token.get("exp")) is not int or not now < token["exp"] <= now + REFERENCE_SECONDS):
                raise ValueError()
            return token
        except (LegacyInvalid, ValueError, TypeError):
            raise RuntimeInvalidRequest() from None

    def _base(self, proof, kind):
        return {"v": 1, "kind": kind, "actorHash": proof["actorHash"],
            "targetHash": proof["targetHash"], "contextHash": proof["contextHash"],
            "exp": int(self._clock()) + REFERENCE_SECONDS}

    def photos(self, identity, target_uid, *, access_token, limit=30, cursor=None):
        target_uid = _uid(target_uid)
        if type(limit) is not int or not 1 <= limit <= MAX_PAGE: raise RuntimeInvalidRequest()
        proof = self._proof(identity, access_token, target_uid)
        start = 0
        if cursor is not None:
            token = self._open("cursor", cursor, proof, "profile-photo-page")
            if (set(token) != {*self._base(proof, "profile-photo-page"), "after", "limit"}
                    or type(token["limit"]) is not int or token["limit"] != limit
                    or type(token["after"]) is not int or not 0 <= token["after"] < len(proof["rows"])):
                raise RuntimeInvalidRequest()
            start = token["after"] + 1
        items = []
        for row, record in zip(proof["rows"][start:start + limit], proof["records"][start:start + limit]):
            reference = self._codec.seal("media", {**self._base(proof, "profile-photo-original"),
                "mediaId": row[0], "ordinal": row[1], "primary": row[2]})
            items.append({"ordinal": row[1], "isPrimary": bool(row[2]),
                "contentType": record["content_type"], "byteSize": record["size"], "reference": reference})
        end = start + len(items)
        next_cursor = None if end == len(proof["rows"]) else self._codec.seal("cursor",
            {**self._base(proof, "profile-photo-page"), "after": end - 1, "limit": limit})
        result = {"kind": "canonical-profile-photos", "targetUid": target_uid,
            "ordering": "ordinal_asc", "items": items, "nextCursor": next_cursor}
        try:
            canonical_json(result, max_bytes=MAX_PUBLIC_BYTES)
        except RuntimeInvalidRequest:
            raise RuntimeUnavailable() from None
        return result

    def _resource(self, identity, access_token, target_uid, reference):
        proof = self._proof(identity, access_token, target_uid)
        token = self._open("media", reference, proof, "profile-photo-original")
        if (set(token) != {*self._base(proof, "profile-photo-original"), "mediaId", "ordinal", "primary"}
                or type(token["ordinal"]) is not int or not 0 <= token["ordinal"] < len(proof["rows"])):
            raise RuntimeInvalidRequest()
        row = proof["rows"][token["ordinal"]]
        if (type(token["primary"]) is not int or token["primary"] != row[2]
                or type(token["mediaId"]) is not str or token["mediaId"] != row[0]):
            raise RuntimeInvalidRequest()
        return {"record": proof["records"][token["ordinal"]], "token": token}

    def _spool(self):
        try:
            path = self._directory
            if type(path) is not str or not os.path.isabs(path): raise ValueError()
            info = os.lstat(path)
            if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
                    or info.st_uid != os.getuid()): raise ValueError()
            return tempfile.TemporaryFile(mode="w+b", dir=path)
        except Exception:
            raise RuntimeUnavailable() from None

    def open_photo(self, identity, target_uid, reference, *, access_token,
            request_cancel=None, request_deadline=None):
        target_uid = _uid(target_uid); self._check()
        now = self._monotonic()
        if (request_cancel is not None and not isinstance(request_cancel, threading.Event)
                or request_deadline is not None and (type(request_deadline) not in (int, float)
                    or not math.isfinite(request_deadline) or request_deadline <= now)):
            raise RuntimeInvalidRequest()
        cancel = request_cancel if request_cancel is not None else threading.Event()
        deadline = min(now + REFERENCE_SECONDS, request_deadline) if request_deadline is not None else now + REFERENCE_SECONDS
        if not self._slots.acquire(blocking=False): raise RuntimeUnavailable()
        with self._lock:
            if self._closed:
                self._slots.release(); raise RuntimeUnavailable()
            self._inflight.add(cancel)
        file = None; timer = None; handed_off = False; before = None
        owner_lock = threading.Lock(); lease_holder = [None]
        def release():
            with self._lock:
                self._inflight.discard(cancel)
                if lease_holder[0] is not None: self._leases.discard(lease_holder[0])
            self._slots.release()
        def expire():
            cancel.set()
            # During S3 setup, cancellation lets the synchronous adapter finish
            # and its owner clean up. After handoff, no absent HTTP consumer is
            # needed to close the anonymous file and release its slot.
            with owner_lock: lease = lease_holder[0]
            if lease is not None: lease.close()
        def check():
            self._check()
            if (cancel.is_set() or self._monotonic() >= deadline
                    or before is not None and int(self._clock()) >= before["token"]["exp"]):
                raise RuntimeUnavailable()
        def fresh():
            check()
            if self._resource(identity, access_token, target_uid, reference) != before:
                raise RuntimeProfilePhotoNotFound()
            check()
        try:
            timer = threading.Timer(max(0, deadline - self._monotonic()), expire)
            timer.daemon = True; timer.start()
            check(); before = self._resource(identity, access_token, target_uid, reference)
            # A reference minted earlier may have less than sixty seconds left.
            # Its expiry must also cancel a storage fetch, not merely reject
            # output once an otherwise longer download has finished.
            deadline = min(deadline, self._monotonic() + before["token"]["exp"] - self._clock())
            timer.cancel()
            timer = threading.Timer(max(0, deadline - self._monotonic()), expire)
            timer.daemon = True; timer.start()
            file = self._spool(); check()
            self._s3.get_verified_to_file(before["record"], file,
                deadline=min(deadline, self._monotonic() + DOWNLOAD_SECONDS), cancel=cancel)
            check(); file.seek(0, os.SEEK_END)
            if file.tell() != before["record"]["size"]: raise RuntimeUnavailable()
            file.seek(0); digest = hashlib.sha256()
            while True:
                check(); block = file.read(CHUNK_BYTES)
                if not block: break
                digest.update(block)
            if not hmac.compare_digest(digest.hexdigest(), before["record"]["sha256"]):
                raise RuntimeUnavailable()
            fresh(); file.seek(0)
            lease = _PhotoLease(file, before["record"], before_first_byte=fresh,
                check=check, cancel=cancel, deadline=deadline, monotonic=self._monotonic,
                timer=timer, release=release)
            with owner_lock:
                check()
                with self._lock:
                    if self._closed: raise RuntimeUnavailable()
                    lease_holder[0] = lease; self._leases.add(lease)
                    handed_off = True
            return lease
        except (RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable):
            raise
        except Exception:
            raise RuntimeUnavailable() from None
        finally:
            if not handed_off:
                cancel.set()
                if timer is not None: timer.cancel()
                if file is not None: file.close()
                release()

    def close(self):
        with self._lock:
            self._closed = True; active = list(self._inflight); leases = list(self._leases)
        for cancel in active: cancel.set()
        # Lease.close invokes release(), which takes this service lock. Never
        # hold it while closing, and let lease idempotence handle timer races.
        for lease in leases: lease.close()
