"""Caller-owned, per-user photo association transactions, not an HTTP service.

No environment/credential/file/network factory. Real use requires the private
source verifier, connection/recovery verifier and durable encrypted journal.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import ipaddress
import json
import re
import secrets
import threading
import time
import uuid
import weakref
from datetime import datetime

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from native_credentials import unique_json
from legacy_conversation_payload import document, payload_digest
from media_promotion_acknowledgement import PINS, SOURCE, VerifiedMediaPromotion
from profile_photo_review import (SourcePhotoDocument, ReadyPhotoEvidence,
    ProfilePhotoAssociation, prepare_profile_photo_review, _typed_string,
    _storage_path, _identifier, _sha, MAX_PHOTOS,
    STRICT_GALLERY_POLICY, AVAILABLE_GALLERY_POLICY)
from profile_visibility import VisibilityAccount
from runtime_reads import _timestamp


COUNTS = {"authUsers": 8208, "firestoreDocuments": 70486,
    "storageObjects": 6478, "storageBytes": 6932196752}
READ_TABLES = {"accounts", "profiles", "legacy_source", "legacy_documents",
    "legacy_storage_objects", "media_objects", "profile_photos"}
ROW_COLUMNS = ("uid", "media_id", "ordinal", "is_primary", "firebase_image_id")
MAX_RECEIPT_BYTES = 65536
MAX_STATEMENTS = 48
PROVIDER_MODEL = "existing-provider-role"
STRICT_MODEL = "strict-tables-v1"
MIGRATE_PERMISSIONS = ("CREATE", "INSERT", "REFERENCES", "SELECT", "UPDATE")
_SOURCE_CAPS = weakref.WeakSet()
_RECOVERY_CAPS = weakref.WeakSet()
_AAD = b"clrs-profile-photo-projector-receipt-v1\0"


class PhotoProjectionRefused(Exception):
    def __init__(self, reason="projection_refused"):
        self.reason = reason
        super().__init__(reason)


class PhotoCommitUnknown(PhotoProjectionRefused):
    def __init__(self):
        super().__init__("commit_outcome_unknown_reconcile_only")


@dataclass(frozen=True, repr=False, eq=False)
class VerifiedSourceSnapshot:
    archive_sha256: str
    manifest_sha256: str
    receipt_digest: str
    counts: tuple
    consistent: bool


def verify_source_snapshot(receipt_bytes, *, trusted_verifier):
    """Private adapter after existing completed source/import proof verification.

    The callback owns HMAC/archive authenticity. It must never be HTTP input.
    SQL legacy_source cannot supply archive/completion facts itself.
    """
    if (type(receipt_bytes) is not bytes or not 1 <= len(receipt_bytes) <= 262144
            or not callable(trusted_verifier)):
        raise PhotoProjectionRefused("source_completion_capability_missing")
    try:
        facts = trusted_verifier(receipt_bytes)
        if (type(facts) is not dict or set(facts) != {"archiveSha256", "manifestSha256",
                "receiptDigest", "source", "counts", "consistent", "completion"}
                or facts["archiveSha256"] != PINS["archiveSha256"]
                or facts["manifestSha256"] != PINS["inventoryManifestSha256"]
                or facts["receiptDigest"] != hashlib.sha256(receipt_bytes).hexdigest()
                or facts["source"] != SOURCE or facts["counts"] != COUNTS
                or type(facts["counts"]) is not dict
                or any(type(x) is not int for x in facts["counts"].values())
                or facts["consistent"] is not False
                or facts["completion"] != "verified_completed_archival_import_readback"):
            raise PhotoProjectionRefused("source_completion_binding_mismatch")
        cap = VerifiedSourceSnapshot(facts["archiveSha256"], facts["manifestSha256"],
            facts["receiptDigest"], tuple(sorted(COUNTS.items())), False)
        _SOURCE_CAPS.add(cap)
        return cap
    except PhotoProjectionRefused:
        raise
    except Exception:
        raise PhotoProjectionRefused("source_completion_verification_failed") from None


@dataclass(frozen=True, repr=False, eq=False)
class VerifiedPhotoRecovery:
    connect: object
    verify_connection: object
    pinned_host: str
    permission_model: str
    provider_permissions: tuple


def _host(value):
    if (type(value) is not str or len(value) > 253 or value != value.lower()
            or not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", value)
            or any(not label or len(label) > 63 or label.startswith("-")
                or label.endswith("-") for label in value.split("."))
            or "." not in value or value.endswith(".localhost")):
        raise PhotoProjectionRefused("connection_host_pin_invalid")
    try: ipaddress.ip_address(value)
    except ValueError: return value
    raise PhotoProjectionRefused("connection_host_pin_invalid")


def verify_photo_recovery(*, connect, trusted_connection_verifier, pinned_host,
        permission_model=STRICT_MODEL, underlying_provider_permissions=()):
    """Bind a SEPARATE private recovery connection and fresh verifier.

    Provider-model permissions declare actual broad existing database grants;
    they never claim a narrow SQL role. The trusted verifier must inspect fresh
    TLS/hostname/grants and the enforced runner allowlist on every connection.
    Minting this capability is not itself a real DELETE permission witness.
    """
    if not callable(connect) or not callable(trusted_connection_verifier):
        raise PhotoProjectionRefused("recovery_capability_missing")
    host = _host(pinned_host)
    if permission_model not in (STRICT_MODEL, PROVIDER_MODEL):
        raise PhotoProjectionRefused("permission_model_invalid")
    permissions = underlying_provider_permissions
    if (type(permissions) not in (tuple, list) or len(permissions) > 32
            or any(type(x) is not str or len(x) > 64
                or not re.fullmatch(r"[A-Z]+(?: [A-Z]+)*", x) for x in permissions)
            or len(set(permissions)) != len(permissions)
            or (permission_model == STRICT_MODEL and permissions)
            or (permission_model == PROVIDER_MODEL and not
                ({"SELECT", "DELETE"} <= set(permissions) or "ALL PRIVILEGES" in permissions))):
        raise PhotoProjectionRefused("recovery_permission_declaration_invalid")
    cap = VerifiedPhotoRecovery(connect, trusted_connection_verifier, host,
        permission_model, tuple(sorted(permissions)))
    _RECOVERY_CAPS.add(cap)
    return cap


@dataclass(frozen=True, repr=False, eq=False)
class PreparedPhotoProjection:
    uid: str
    order: tuple
    context_digest: str
    plan: object

    def summary(self):
        return self.plan.summary()


def _hash(value):
    return hashlib.sha256(value.encode()).digest()


def _encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
        allow_nan=False, separators=(",", ":")).encode()


def _rows(values):
    result = []
    if len(values) > MAX_PHOTOS: raise PhotoProjectionRefused("associations_over_limit")
    for row in values:
        if (not isinstance(row, (tuple, list)) or len(row) != 5
                or type(row[2]) is not int or not 0 <= row[2] < MAX_PHOTOS
                or type(row[3]) is not int or row[3] not in (0, 1)):
            raise PhotoProjectionRefused("association_malformed")
        _identifier(row[0]); _identifier(row[1])
        if row[4] is not None: _identifier(row[4])
        result.append(ProfilePhotoAssociation(*row))
    return tuple(sorted(result, key=lambda x: x.ordinal))


SOURCE_SQL = "SELECT source_project, source_database, source_bucket FROM clrs_staging.legacy_source WHERE singleton = 1 LIMIT 1 FOR SHARE"
OWNER_SQL = """SELECT a.uid, a.disabled, a.lifecycle, p.uid,
 CASE WHEN OCTET_LENGTH(CAST(p.legacy_raw AS CHAR CHARACTER SET utf8mb4)) <= 131072 THEN p.legacy_raw ELSE NULL END,
 DATE_FORMAT(p.updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')
 FROM clrs_staging.accounts AS a JOIN clrs_staging.profiles AS p
 ON p.uid = a.uid AND CAST(p.uid AS BINARY) = CAST(a.uid AS BINARY)
 WHERE a.uid = %s AND CAST(a.uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE OF a, p"""
DOC_COLUMNS = "firebase_path, collection_path, document_id, CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= 131072 THEN encoded_payload ELSE NULL END, payload_sha256"
ROOT_SQL = "SELECT " + DOC_COLUMNS + " FROM clrs_staging.legacy_documents WHERE firebase_path_sha256 = %s AND CAST(firebase_path AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE"
GALLERY_SQL = "SELECT " + DOC_COLUMNS + " FROM clrs_staging.legacy_documents WHERE collection_path_sha256 = %s AND CAST(collection_path AS BINARY) = CAST(%s AS BINARY) ORDER BY CAST(document_id AS BINARY) LIMIT 51 FOR SHARE"
PHOTOS_SQL = "SELECT uid, media_id, ordinal, is_primary, firebase_image_id FROM clrs_staging.profile_photos WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) ORDER BY ordinal LIMIT 51 FOR UPDATE"


def _storage_sql(count):
    return "SELECT source_bucket, source_path, CASE WHEN OCTET_LENGTH(CAST(source_metadata AS CHAR CHARACTER SET utf8mb4)) <= 65536 THEN source_metadata ELSE NULL END, source_size, source_sha256, target_key, target_sha256, copied_at FROM clrs_staging.legacy_storage_objects WHERE source_bucket = %s AND source_path_sha256 IN (" + ",".join("%s" for _ in range(count)) + ") LIMIT 51 FOR SHARE"


def _media_sql(count):
    return "SELECT media_id, owner_uid, purpose, object_key, thumbnail_key, mime_type, byte_size, thumbnail_byte_size, sha256, status, legacy_storage_path FROM clrs_staging.media_objects WHERE object_key_sha256 IN (" + ",".join("%s" for _ in range(count)) + ") LIMIT 51 FOR SHARE"


def _insert_sql(count):
    return "INSERT INTO clrs_staging.profile_photos (uid, media_id, ordinal, is_primary, firebase_image_id) VALUES " + ",".join("(%s,%s,%s,%s,%s)" for _ in range(count))


def _delete_sql(count):
    terms = " OR ".join("(media_id = %s AND CAST(media_id AS BINARY) = CAST(%s AS BINARY) AND ordinal = %s AND is_primary = %s AND firebase_image_id <=> %s)" for _ in range(count))
    return "DELETE FROM clrs_staging.profile_photos WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) AND (" + terms + ") LIMIT %s"


_SESSION_SQL = frozenset({"SET SESSION time_zone = '+00:00'",
    "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'",
    "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"})
_SELECT_SQL = frozenset({SOURCE_SQL, OWNER_SQL, ROOT_SQL, GALLERY_SQL, PHOTOS_SQL,
    *(_storage_sql(n) for n in range(1, MAX_PHOTOS + 1)),
    *(_media_sql(n) for n in range(1, MAX_PHOTOS + 1))})
_INSERT_SQL = frozenset(_insert_sql(n) for n in range(1, MAX_PHOTOS + 1))
_DELETE_SQL = frozenset(_delete_sql(n) for n in range(1, MAX_PHOTOS + 1))


class ProfilePhotoProjector:
    def __init__(self, *, connect, trusted_connection_verifier, pinned_host,
            source_snapshot, media_promotion, recovery, receipt_key,
            load_pending_receipt, permission_model=STRICT_MODEL, clock=time.time,
            gallery_original_policy=STRICT_GALLERY_POLICY):
        if (type(source_snapshot) is not VerifiedSourceSnapshot or source_snapshot not in _SOURCE_CAPS
                or type(recovery) is not VerifiedPhotoRecovery or recovery not in _RECOVERY_CAPS
                or type(media_promotion) is not VerifiedMediaPromotion
                or type(receipt_key) is not bytes or len(receipt_key) != 32
                or not callable(connect) or not callable(trusted_connection_verifier)
                or not callable(load_pending_receipt)):
            raise PhotoProjectionRefused("projector_capability_missing")
        self._host = _host(pinned_host)
        if permission_model not in (STRICT_MODEL, PROVIDER_MODEL):
            raise PhotoProjectionRefused("permission_model_invalid")
        if gallery_original_policy not in (STRICT_GALLERY_POLICY, AVAILABLE_GALLERY_POLICY):
            raise PhotoProjectionRefused("gallery_original_policy_unreviewed")
        if recovery.pinned_host != self._host:
            raise PhotoProjectionRefused("recovery_host_binding_mismatch")
        self._connect = connect; self._source = source_snapshot
        self._verify_connection = trusted_connection_verifier
        self._permission_model = permission_model
        self._gallery_original_policy = gallery_original_policy
        self._media = media_promotion; self._recovery = recovery
        self._cipher = AESGCM(receipt_key); self._pending = load_pending_receipt
        self._clock = clock; self._prepared = weakref.WeakSet()
        self._unknown = set(); self._closed_connections = weakref.WeakSet()
        self._active_connections = weakref.WeakSet()
        self._rollback_pending = set()

    def _verify(self, connection, *, recovery):
        cap = self._recovery
        model = cap.permission_model if recovery else self._permission_model
        read = sorted(READ_TABLES)
        inserts = [] if recovery else ["profile_photos"]
        deletes = ["profile_photos"] if recovery else []
        if model == STRICT_MODEL:
            scope = "strict-table-role"
            underlying = {"readTables": read, "insertTables": inserts,
                "updateTables": [] if recovery else ["profile_photos"],
                "deleteTables": deletes, "otherWriteTables": []}
        else:
            scope = "existing-approved-provider-database"
            underlying = {"database": "clrs_staging",
                "privileges": list(cap.provider_permissions if recovery else MIGRATE_PERMISSIONS),
                "globalPrivileges": [], "grantOption": False}
        verifier = cap.verify_connection if recovery else self._verify_connection
        facts = verifier(connection)
        expected = {"host": self._host, "database": "clrs_staging", "mysql": "8.4",
            "verifiedTLS": True, "verifiedHostname": True, "strict": True,
            "socketTimeoutSeconds": 2, "fresh_grants_verified": True,
            "underlying_permissions_scope": scope, "underlying_permissions": underlying,
            "executed_sql_scope": "profile-photo-projector-v1",
            "execution_mode": "recovery" if recovery else "apply",
            "runner_allowlist_enforced": True}
        if (type(facts) is not dict or set(facts) != {*expected, "grants_sha256"}
                or type(facts["grants_sha256"]) is not str
                or not re.fullmatch(r"[0-9a-f]{64}", facts["grants_sha256"])
                or {key: value for key, value in facts.items() if key != "grants_sha256"} != expected
                or any(type(facts[k]) is not bool for k in ("verifiedTLS", "verifiedHostname",
                    "strict", "fresh_grants_verified", "runner_allowlist_enforced"))
                or (model == PROVIDER_MODEL and facts["underlying_permissions"]["grantOption"] is not False)
                or type(facts["socketTimeoutSeconds"]) is not int):
            raise PhotoProjectionRefused("connection_or_recovery_role_unverified")

    def _transaction(self, action, *, readonly=False, recovery=False):
        connection = None; timer = None; commit_started = False; rolled_back = False
        deadline = time.monotonic() + 8
        try:
            self._media.require_current(self._clock())
            connection = (self._recovery.connect if recovery else self._connect)()
            if connection in self._closed_connections or connection in self._active_connections:
                connection = None
                raise PhotoProjectionRefused("fresh_connection_required")
            self._active_connections.add(connection)
            timer = threading.Timer(max(0, deadline - time.monotonic()), connection.close)
            timer.daemon = True; timer.start()
            self._verify(connection, recovery=recovery)
            cursor = connection.cursor(); statements = 0
            def execute(sql, params=()):
                nonlocal statements
                if time.monotonic() >= deadline or statements >= MAX_STATEMENTS:
                    raise PhotoProjectionRefused("transaction_bound")
                start = "START TRANSACTION" + (" READ ONLY" if readonly else "")
                if (sql not in _SESSION_SQL and sql != start and sql not in _SELECT_SQL
                        and (readonly or sql not in (_DELETE_SQL if recovery else _INSERT_SQL))):
                    raise PhotoProjectionRefused("sql_scope_refused")
                statements += 1
                return cursor.execute(sql.replace("FOR UPDATE", "FOR SHARE") if readonly else sql, params)
            execute("SET SESSION time_zone = '+00:00'")
            execute("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'")
            execute("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
            execute("START TRANSACTION" + (" READ ONLY" if readonly else ""))
            result, before_commit = action(cursor, execute)
            if before_commit is None:
                connection.rollback()
                rolled_back = True
            else:
                if readonly: raise PhotoProjectionRefused("readonly_commit_forbidden")
                before_commit()
                self._media.require_current(self._clock())
                if time.monotonic() >= deadline: raise PhotoProjectionRefused("transaction_bound")
                commit_started = True
                try: connection.commit()
                except Exception: raise PhotoCommitUnknown() from None
            return result
        except PhotoProjectionRefused:
            raise
        except Exception:
            raise PhotoProjectionRefused("transaction_unavailable") from None
        finally:
            if timer is not None: timer.cancel()
            if connection is not None:
                if not commit_started and not rolled_back:
                    try: connection.rollback()
                    except Exception: pass
                try: connection.close()
                finally:
                    self._active_connections.discard(connection)
                    self._closed_connections.add(connection)

    @staticmethod
    def _document(row, collection):
        if (not isinstance(row, (tuple, list)) or len(row) != 5
                or row[1] != collection or type(row[2]) is not str
                or row[0] != collection + "/" + row[2]):
            raise PhotoProjectionRefused("source_document_shape")
        _identifier(row[2])
        return SourcePhotoDocument(row[0], document(row[3]), _sha(row[4]))

    def _context(self, cursor, execute, uid, order):
        # PyMySQL returns a tuple of rows; synthetic adapters may use a list.
        # Normalize the container while retaining the exact source tuple.
        execute(SOURCE_SQL); source = list(cursor.fetchall())
        if source != [(SOURCE["project"], SOURCE["database"], SOURCE["bucket"])]:
            raise PhotoProjectionRefused("source_identity_mismatch")
        execute(OWNER_SQL, (uid, uid)); owner = cursor.fetchall()
        if len(owner) != 1 or len(owner[0]) != 6 or owner[0][0] != uid or owner[0][3] != uid:
            raise PhotoProjectionRefused("owner_identity_mismatch")
        account = VisibilityAccount(*owner[0][:3])
        raw_value = owner[0][4]
        if type(raw_value) is bytes: raw_value = raw_value.decode("utf-8", "strict")
        if type(raw_value) is str: raw_value = unique_json(raw_value)
        if raw_value == {}: raise PhotoProjectionRefused("native_photo_mapping_unknown")
        raw = document(raw_value)
        if owner[0][5] is None: raise PhotoProjectionRefused("canonical_context_unknown")
        _timestamp(owner[0][5])
        root_path = "users/" + uid
        execute(ROOT_SQL, (_hash(root_path), root_path)); roots = cursor.fetchall()
        if len(roots) != 1: raise PhotoProjectionRefused("root_source_missing")
        root = self._document(roots[0], "users")
        collection = root_path + "/images"
        execute(GALLERY_SQL, (_hash(collection), collection)); images = cursor.fetchall()
        if len(images) > MAX_PHOTOS: raise PhotoProjectionRefused("gallery_over_limit")
        gallery = [self._document(row, collection) for row in images]
        image_ids = tuple(row[2] for row in images)
        if order != image_ids: raise PhotoProjectionRefused("reviewed_source_id_order_mismatch")
        paths = []
        for record, field in [(root, "profilePic"), *((x, "url") for x in gallery)]:
            value = _typed_string(record.encoded_payload["fields"], field)
            if value:
                path = _storage_path(value)
                if path not in paths: paths.append(path)
        if len(paths) > MAX_PHOTOS: raise PhotoProjectionRefused("gallery_over_limit")
        evidence = []
        if paths:
            execute(_storage_sql(len(paths)), (SOURCE["bucket"], *(_hash(x) for x in paths)))
            storage_rows = cursor.fetchall()
            if len(storage_rows) != len(paths): raise PhotoProjectionRefused("storage_mapping_missing")
            storage = {}; keys = []
            for row in storage_rows:
                if len(row) != 8 or row[1] not in paths or row[1] in storage:
                    raise PhotoProjectionRefused("storage_mapping_conflict")
                storage[row[1]] = dict(zip(("source_bucket", "source_path", "source_metadata", "source_size", "source_sha256", "target_key", "target_sha256", "copied_at"), row))
                keys.append(row[5])
            execute(_media_sql(len(paths)), tuple(_hash(x) for x in keys))
            media_rows = cursor.fetchall()
            if len(media_rows) != len(paths): raise PhotoProjectionRefused("ready_mapping_missing")
            seen = set()
            for row in media_rows:
                if len(row) != 11 or row[10] not in storage or row[10] in seen:
                    raise PhotoProjectionRefused("ready_mapping_conflict")
                seen.add(row[10])
                media = dict(zip(("media_id", "owner_uid", "purpose", "object_key", "thumbnail_key", "mime_type", "byte_size", "thumbnail_byte_size", "sha256", "status", "legacy_storage_path"), row))
                evidence.append(ReadyPhotoEvidence(media, storage[row[10]]))
        execute(PHOTOS_SQL, (uid, uid)); existing = _rows(cursor.fetchall())
        if any(row.uid != uid for row in existing): raise PhotoProjectionRefused("association_owner_mismatch")
        plan = prepare_profile_photo_review(account=account, canonical_legacy_raw=raw,
            root_document=root, gallery_documents=gallery, gallery_complete=True,
            ready_evidence=evidence, existing_rows=[], source_archive_sha256=self._source.archive_sha256,
            reviewed_gallery_order=order, gallery_original_policy=self._gallery_original_policy)
        if plan.state != "reviewable": raise PhotoProjectionRefused(plan.reason)
        from legacy_private_media import _metadata
        provenance = []
        for item in sorted(evidence, key=lambda x: x.storage["source_path"]):
            provenance.append({"media": {key: _sha(value) if key == "sha256" else value for key, value in item.media.items()},
                "storage": {key: _sha(value) if key in {"source_sha256", "target_sha256"}
                    else _metadata(value) if key == "source_metadata"
                    else value.isoformat() if type(value) is datetime else value
                    for key, value in item.storage.items()}})
        context = {"sourceProof": self._source.receipt_digest, "owner": list(owner[0][:4]),
            "raw": payload_digest(raw), "updatedAt": owner[0][5], "plan": plan.fingerprint}
        context["provenance"] = provenance
        return plan, hashlib.sha256(_encoded(context)).hexdigest(), existing

    def prepare(self, uid, *, reviewed_source_id_order):
        try:
            uid = _identifier(uid)
            if type(reviewed_source_id_order) not in (tuple, list) or len(reviewed_source_id_order) > MAX_PHOTOS:
                raise ValueError()
            order = tuple(_identifier(value) for value in reviewed_source_id_order)
        except Exception:
            raise PhotoProjectionRefused("projection_input_invalid") from None
        def action(cursor, execute):
            plan, context, existing = self._context(cursor, execute, uid, order)
            if existing and existing != plan.rows:
                raise PhotoProjectionRefused("existing_photo_association_conflict")
            prepared = PreparedPhotoProjection(uid, order, context, plan)
            self._prepared.add(prepared)
            return prepared, None
        return self._transaction(action, readonly=True)

    def _seal(self, record):
        plain = _encoded(record)
        if len(plain) > MAX_RECEIPT_BYTES: raise PhotoProjectionRefused("receipt_bound")
        nonce = secrets.token_bytes(12)
        return nonce + self._cipher.encrypt(nonce, plain, _AAD)

    def _open(self, encrypted):
        try:
            if type(encrypted) is not bytes or not 29 <= len(encrypted) <= MAX_RECEIPT_BYTES + 28:
                raise ValueError()
            record = unique_json(self._cipher.decrypt(encrypted[:12], encrypted[12:], _AAD).decode())
            if (set(record) != {"kind", "v", "operation", "operationId", "sourceProof", "archiveSha256", "consistent", "uid", "order", "context", "fingerprint", "before", "after", "parentReceipt"}
                    or record["kind"] != "clrs-profile-photo-projection-receipt"
                    or type(record["v"]) is not int or record["v"] != 1
                    or record["operation"] not in {"apply", "rollback"}
                    or str(uuid.UUID(record["operationId"])) != record["operationId"]
                    or record["sourceProof"] != self._source.receipt_digest
                    or record["archiveSha256"] != self._source.archive_sha256 or record["consistent"] is not False):
                raise ValueError()
            _identifier(record["uid"]); _sha(record["context"]); _sha(record["fingerprint"])
            if type(record["order"]) is not list or len(record["order"]) > MAX_PHOTOS: raise ValueError()
            for value in record["order"]: _identifier(value)
            before = _rows(record["before"]); after = _rows(record["after"])
            if any(x.uid != record["uid"] for x in (*before, *after)): raise ValueError()
            if (record["operation"] == "apply" and (before or not after or record["parentReceipt"] is not None)
                    or record["operation"] == "rollback" and (not before or after or _sha(record["parentReceipt"]) is None)):
                raise ValueError()
            return record, before, after
        except Exception:
            raise PhotoProjectionRefused("receipt_binding_invalid") from None

    def _receipt(self, prepared, operation, before, after, parent=None):
        return self._seal({"kind": "clrs-profile-photo-projection-receipt", "v": 1,
            "operation": operation, "operationId": str(uuid.uuid4()), "sourceProof": self._source.receipt_digest,
            "archiveSha256": self._source.archive_sha256, "consistent": False,
            "uid": prepared.uid, "order": list(prepared.order), "context": prepared.context_digest,
            "fingerprint": prepared.plan.fingerprint, "before": [list(vars(x).values()) for x in before],
            "after": [list(vars(x).values()) for x in after], "parentReceipt": parent})

    @staticmethod
    def _persist(callback, encrypted):
        if callback(encrypted) != hashlib.sha256(encrypted).hexdigest():
            raise PhotoProjectionRefused("durable_receipt_unconfirmed")

    def _preflight_recovery(self, prepared=None):
        # BEFORE opening apply: execute the full exact mixed-lock context in a
        # zero-DML WRITE transaction + ROLLBACK, proving actual query/lock rights.
        # Before COMMIT: fresh TLS/grants only, with NO target locks; relocking
        # profile_photos in another connection would deadlock our apply itself.
        def action(cursor, execute):
            if prepared is not None:
                plan, context, rows = self._context(cursor, execute, prepared.uid, prepared.order)
                if (plan != prepared.plan or context != prepared.context_digest
                        or (rows and rows != plan.rows)):
                    raise PhotoProjectionRefused("recovery_probe_context_changed")
            return None, None
        self._transaction(action, readonly=prepared is None, recovery=True)

    def apply(self, prepared, *, persist_receipt):
        if (type(prepared) is not PreparedPhotoProjection or prepared not in self._prepared
                or not callable(persist_receipt)):
            raise PhotoProjectionRefused("prepared_plan_or_durable_receipt_missing")
        if prepared.uid in self._unknown or self._pending(prepared.uid) is not None:
            raise PhotoProjectionRefused("pending_receipt_reconcile_required")
        self._preflight_recovery(prepared)
        def action(cursor, execute):
            plan, context, existing = self._context(cursor, execute, prepared.uid, prepared.order)
            if context != prepared.context_digest or plan != prepared.plan:
                raise PhotoProjectionRefused("prepared_context_changed")
            if existing == plan.rows: return {"state": "unchanged", "reason": "already_matches", "rows": len(existing)}, None
            if existing: raise PhotoProjectionRefused("existing_photo_association_conflict")
            # Fresh locked complete context before the first mutation.
            again, digest, rows = self._context(cursor, execute, prepared.uid, prepared.order)
            if again != plan or digest != context or rows:
                raise PhotoProjectionRefused("preinsert_context_changed")
            execute(_insert_sql(len(plan.rows)), tuple(value for row in plan.rows for value in vars(row).values()))
            if cursor.rowcount != len(plan.rows): raise PhotoProjectionRefused("insert_count_mismatch")
            checked, digest, rows = self._context(cursor, execute, prepared.uid, prepared.order)
            if checked != plan or digest != context or rows != plan.rows:
                raise PhotoProjectionRefused("full_readback_mismatch")
            encrypted = self._receipt(prepared, "apply", (), rows)
            def commit_guard():
                self._preflight_recovery()
                self._unknown.add(prepared.uid)
                self._persist(persist_receipt, encrypted)
                checked, digest, rows = self._context(cursor, execute, prepared.uid, prepared.order)
                if checked != plan or digest != context or rows != plan.rows:
                    raise PhotoProjectionRefused("precommit_context_changed")
            return {"state": "applied", "reason": "exact_rows_verified", "rows": len(rows)}, commit_guard
        return self._transaction(action)

    def reconcile(self, encrypted_receipt):
        record, before, after = self._open(encrypted_receipt)
        def action(cursor, execute):
            plan, context, rows = self._context(cursor, execute, record["uid"], tuple(record["order"]))
            if context != record["context"] or plan.fingerprint != record["fingerprint"]:
                raise PhotoProjectionRefused("reconcile_context_changed")
            expected = after if record["operation"] == "apply" else before
            if expected != plan.rows:
                raise PhotoProjectionRefused("receipt_plan_rows_mismatch")
            if rows == after: state = "present_verified"
            elif rows == before: state = "not_committed_verified"
            else: raise PhotoProjectionRefused("reconcile_rows_conflict")
            return {"state": state, "reason": "receipt_bound_readback", "rows": len(rows)}, None
        # No INSERT, deletion, pending-journal clearing or retry authority.
        return self._transaction(action, readonly=True, recovery=record["operation"] == "rollback")

    def rollback(self, encrypted_apply_receipt, *, persist_receipt):
        if not callable(persist_receipt): raise PhotoProjectionRefused("durable_receipt_missing")
        record, before, after = self._open(encrypted_apply_receipt)
        if record["operation"] != "apply" or before:
            raise PhotoProjectionRefused("rollback_receipt_scope_invalid")
        pending = self._pending(record["uid"])
        if record["uid"] in self._rollback_pending or pending not in (None, encrypted_apply_receipt):
            raise PhotoProjectionRefused("pending_rollback_reconcile_required")
        def action(cursor, execute):
            plan, context, rows = self._context(cursor, execute, record["uid"], tuple(record["order"]))
            if (context != record["context"] or plan.fingerprint != record["fingerprint"]
                    or rows != after or after != plan.rows):
                raise PhotoProjectionRefused("rollback_exact_after_changed")
            execute(_delete_sql(len(after)),
                (record["uid"], record["uid"], *(value for row in after for value in (row.media_id, row.media_id, row.ordinal, row.is_primary, row.firebase_image_id)), len(after)))
            if cursor.rowcount != len(after): raise PhotoProjectionRefused("rollback_delete_mismatch")
            checked, digest, rows = self._context(cursor, execute, record["uid"], tuple(record["order"]))
            if checked != plan or digest != context or rows: raise PhotoProjectionRefused("rollback_readback_mismatch")
            prepared = PreparedPhotoProjection(record["uid"], tuple(record["order"]), context, plan)
            encrypted = self._receipt(prepared, "rollback", after, (), hashlib.sha256(encrypted_apply_receipt).hexdigest())
            def commit_guard():
                self._unknown.add(prepared.uid)
                self._rollback_pending.add(prepared.uid)
                self._persist(persist_receipt, encrypted)
                checked, digest, rows = self._context(cursor, execute, prepared.uid, prepared.order)
                if checked != plan or digest != context or rows: raise PhotoProjectionRefused("rollback_precommit_context_changed")
            return {"state": "rolled_back", "reason": "exact_recorded_rows_removed", "rows": 0}, commit_guard
        return self._transaction(action, recovery=True)
