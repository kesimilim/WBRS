"""Current-visible native gallery proof; imported reader/HTTP/lease implementation unchanged."""
from __future__ import annotations
import hashlib
import hmac
import threading
import time
from datetime import datetime, timezone

from legacy_conversation_payload import OpaqueReferences
from native_credentials import unique_json
from native_photo_upload_s3 import NativePhotoUploadS3
from runtime_mutations import RECEIPT_QUERY, RuntimeUnavailable, canonical_json, request_digest
from runtime_profile_photo_uploads import (RuntimeProfilePhotoUploadsService, PREPARE_OPERATION,
    COMMIT_OPERATION, NATIVE_GALLERY_SQL, native_gallery, photo_record, validate_commit,
    validate_commit_response, _prepared, _uuid, PhotoUploadTargetRejected)
from runtime_profile_photos import (RuntimeProfilePhotosService, RuntimeProfilePhotoNotFound,
    _uid, _account, _rows, _target, ACTOR_SQL, _digest)

# Leading PK actor/operation range; never a JSON filter or a receipt-table scan.
COMMITS_SQL = """SELECT idempotency_key, request_hash, state, response_status,
 CASE WHEN OCTET_LENGTH(CAST(result AS CHAR CHARACTER SET utf8mb4)) <= 4096 THEN result ELSE NULL END,
 entity_revision, completed_at FROM clrs_staging.idempotency_receipts
 WHERE actor_uid = %s AND CAST(actor_uid AS BINARY) = CAST(%s AS BINARY)
 AND operation = %s AND state = 'completed' AND response_status = 200
 ORDER BY idempotency_key LIMIT 21 FOR SHARE"""


def profile_photo_branch(store, identity, target_uid, *, access_token, clock=time.time):
    target_uid = _uid(target_uid)
    def action(cursor, execute, uid):
        actor = _account(_rows(cursor, execute, ACTOR_SQL, (uid, uid)), uid)
        _, _, before = _target(cursor, execute, target_uid, actor, datetime.fromtimestamp(clock(), timezone.utc))
        execute(NATIVE_GALLERY_SQL.replace("LIMIT 21", "LIMIT 51"), (target_uid, target_uid)); rows = cursor.fetchall()
        if len(rows) > 50: raise RuntimeProfilePhotoNotFound()
        branch = "legacy" if rows and all(type(row[7]) is str and row[7].startswith("clrs-import-quarantine/")
            and type(row[12]) is int and row[12] == 0 for row in rows) else "native"
        if branch == "native":
            try: native_gallery(rows, target_uid)
            except Exception: raise RuntimeProfilePhotoNotFound() from None
        _, _, after = _target(cursor, execute, target_uid, actor, datetime.fromtimestamp(clock(), timezone.utc))
        if after != before: raise RuntimeProfilePhotoNotFound()
        return {"branch": branch}
    return store.read_authenticated(identity, action, access_token=access_token)["branch"]


class RuntimeNativeProfilePhotosService(RuntimeProfilePhotosService):
    def __init__(self, store, cursor_key, *, uploads, private_s3, spool_directory,
            clock=time.time, monotonic=time.monotonic):
        if (not isinstance(uploads, RuntimeProfilePhotoUploadsService) or uploads._store is not store
                or type(cursor_key) is not bytes or len(cursor_key) != 32
                or type(private_s3) is not NativePhotoUploadS3
                or not callable(getattr(private_s3, "require_private", None))):
            raise RuntimeUnavailable()
        self._store = store; self._uploads = uploads; self._s3 = private_s3
        self._directory = spool_directory; self._clock = clock; self._monotonic = monotonic
        self._codec = OpaqueReferences(hmac.digest(cursor_key, b"clrs-native-own-profile-photos-v1\0", "sha256"))
        self._slots = threading.BoundedSemaphore(2); self._lock = threading.Lock()
        self._inflight = set(); self._leases = set(); self._closed = False

    def _check(self):
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
        try: self._s3._proof()  # Separate mode; never a privacy substitute.
        except Exception: raise RuntimeUnavailable() from None

    def _context(self, cursor, execute, actor_uid, target_uid):
        self._check(); actor = _account(_rows(cursor, execute, ACTOR_SQL, (actor_uid, actor_uid)), actor_uid)
        _, _, before = _target(cursor, execute, target_uid, actor,
            datetime.fromtimestamp(self._clock(), timezone.utc))
        stamp = self._uploads._profile(cursor, execute, target_uid)
        photos = self._uploads._photos(cursor, execute, target_uid)
        execute(NATIVE_GALLERY_SQL, (target_uid, target_uid))
        try: rows = native_gallery(cursor.fetchall(), target_uid)
        except Exception: raise RuntimeProfilePhotoNotFound() from None
        if [row[:3] for row in rows] != photos or stamp is None: raise RuntimeProfilePhotoNotFound()
        receipts = {}
        if rows:
            execute(COMMITS_SQL, (target_uid, target_uid, COMMIT_OPERATION)); commits = cursor.fetchall()
            if len(commits) > 20: raise RuntimeProfilePhotoNotFound()
            for row in commits:
                if len(row) != 7: raise RuntimeUnavailable()
                if type(row[3]) is not int or row[3] != 200: continue
                _uuid(row[0]); wrapper = row[4]
                if isinstance(wrapper, bytes): wrapper = wrapper.decode('utf-8', 'strict')
                if isinstance(wrapper, str): wrapper = unique_json(wrapper)
                if type(wrapper) is not dict or set(wrapper) != {'request', 'response'}: raise RuntimeUnavailable()
                request = validate_commit(wrapper['request'])
                status, checked, revision = self._store._receipt(row[1:], request_digest(request))
                mid = request['mediaId']
                if status != 200 or revision is not None or mid in receipts: raise RuntimeProfilePhotoNotFound()
                receipts[mid] = (row[0], request, checked['response'])
        records = []; provenance = []
        for row in rows:
            receipt = receipts.get(row[0])
            if receipt is None: raise RuntimeProfilePhotoNotFound()
            operation_id, request, response = receipt
            try: fields, record = photo_record(target_uid, request, row[4:])
            except PhotoUploadTargetRejected: raise RuntimeProfilePhotoNotFound() from None
            execute(RECEIPT_QUERY + ' FOR SHARE', (target_uid, PREPARE_OPERATION, request['prepareOperationId']))
            original = cursor.fetchone()
            if original is None: raise RuntimeProfilePhotoNotFound()
            status, wrapper, revision = self._store._receipt(original, request_digest(fields))
            if status != 201 or revision is not None or wrapper != {'request': fields, 'response': _prepared(row[0], fields)}:
                raise RuntimeProfilePhotoNotFound()
            try: validate_commit_response(request, response, {'updatedAt': stamp}, row[:3])
            except PhotoUploadTargetRejected: raise RuntimeProfilePhotoNotFound() from None
            records.append(record); provenance.append([operation_id, request, response, wrapper])
        _, _, after = _target(cursor, execute, target_uid, actor,
            datetime.fromtimestamp(self._clock(), timezone.utc))
        if before != after: raise RuntimeProfilePhotoNotFound()
        self._check()
        return {'actorHash': _digest(actor_uid), 'targetHash': _digest(target_uid),
            'contextHash': hashlib.sha256(canonical_json([before, rows, provenance])).hexdigest(),
            'rows': photos, 'records': records}

    def open_photo(self, identity, target_uid, reference, **kwargs):
        lease = super().open_photo(identity, target_uid, reference, **kwargs)
        try:
            record = self._resource(identity, kwargs['access_token'], target_uid, reference)['record']
            original = lease._before_first_byte
            def before():
                original()
                self._s3.require_private(record, deadline=lease._deadline, cancel=lease._cancel)
            lease._before_first_byte = before
            return lease
        except BaseException:
            lease.close(); raise
