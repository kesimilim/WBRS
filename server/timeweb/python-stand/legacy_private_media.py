"""Default-off, explicitly reviewed immutable-object alias media reads.

Raw quarantine imports are never automatically published. A separately reviewed
media_objects ready row is required, as are a completed full readback pin and a
dedicated S3 read adapter. No route, promotion, SQL/S3 write or public URL here.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import stat
import tempfile
import threading
import time

from legacy_conversation_discovery import LegacyConversationDiscoveryService
from legacy_conversation_read import (LegacyReadRejected, LegacyReadUnavailable,
    LegacyReadRateLimited, _sha)
from native_auth import NativeRateLimited
from profile_store import BUNDLED_CA_FILE
from legacy_conversation_payload import (LegacyInvalid, MAX_DOCUMENT_BYTES,
    field, identifier, media_reference, string_field, uid_list)


MAX_OBJECT_BYTES = 64_000_000
CHUNK_BYTES = 65_536
REQUEST_SECONDS = 60
DOWNLOAD_SECONDS = 50
MAX_CANDIDATE_PARENTS = 50
TABLES = {"accounts", "legacy_source", "legacy_documents",
    "legacy_storage_objects", "media_objects"}
MIME_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif"}
_SLOTS = threading.BoundedSemaphore(2)
_DIGEST = re.compile(r"[a-f0-9]{64}\Z")
_BASE_KEYS = {"v", "uid", "source", "collection", "parent", "purpose", "bucket", "path", "exp"}

STORAGE_QUERY = """SELECT source_bucket, source_path,
    CASE WHEN OCTET_LENGTH(CAST(source_metadata AS CHAR CHARACTER SET utf8mb4)) <= 65536
        THEN source_metadata ELSE NULL END AS safe_metadata,
    source_size, source_sha256, target_key, target_sha256, copied_at
    FROM clrs_staging.legacy_storage_objects
    WHERE source_bucket = %s AND source_path_sha256 = %s LIMIT 1"""
PROMOTION_QUERY = """SELECT owner_uid, purpose, object_key, mime_type,
    byte_size, sha256, status, legacy_storage_path
    FROM clrs_staging.media_objects WHERE object_key_sha256 = %s LIMIT 1"""


def target_key(project, bucket, path):
    # This is the existing raw-import source-identity key, not the content hash.
    digest = hashlib.sha256((project + "\0" + bucket + "\0" + path).encode()).hexdigest()
    return "clrs-import-quarantine/" + digest


def _source_path(value):
    if (not isinstance(value, str) or not value or len(value.encode()) > 1024
            or any(ord(char) < 32 or ord(char) == 127 for char in value)
            or any(part in {"", ".", ".."} for part in value.split("/"))):
        raise LegacyReadRejected()
    return value


def _hash(value):
    if not isinstance(value, (bytes, bytearray, memoryview)) or len(value) != 32:
        raise LegacyReadUnavailable()
    return bytes(value).hex()


def _metadata(value):
    try:
        if isinstance(value, (bytes, bytearray)):
            value = bytes(value).decode("utf-8", "strict")
        if isinstance(value, str):
            if len(value.encode()) > 65536:
                raise ValueError()
            def pairs(items):
                result = {}
                for key, item in items:
                    if key in result:
                        raise ValueError()
                    result[key] = item
                return result
            value = json.loads(value, object_pairs_hook=pairs,
                parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if (not isinstance(value, dict) or len(json.dumps(value,
                ensure_ascii=False, allow_nan=False).encode()) > 65536):
            raise ValueError()
        return value
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise LegacyReadUnavailable() from None


class VerifiedMediaLease:
    """Use `with`; chunk iteration provides backpressure, never a public key.

    The file has already been fully hashed before constructing this object.
    The HTTP owner must close the context after success, disconnect or failure
    and bound socket writes. An abandoned generator does not cancel native I/O.
    """
    def __init__(self, file, record, *, check, cancel, deadline, monotonic,
            timer, release):
        self.content_type = record["content_type"]
        self.size = record["size"]
        self._file = file; self._check_identity = check; self._cancel = cancel
        self._deadline = deadline; self._monotonic = monotonic
        self._timer = timer; self._release = release
        self._closed = False; self._started = False; self._lock = threading.Lock()

    @property
    def headers(self):
        return {"Content-Length": str(self.size), "Content-Type": self.content_type,
            "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
            "Content-Disposition": "attachment; filename=media"}

    def _check(self):
        if self._closed or self._cancel.is_set() or self._monotonic() >= self._deadline:
            raise LegacyReadUnavailable()
        self._check_identity()

    def iter_bytes(self):
        with self._lock:
            if self._started or self._closed:
                raise LegacyReadUnavailable()
            self._started = True
        remaining = self.size
        try:
            while remaining:
                self._check()
                block = self._file.read(min(CHUNK_BYTES, remaining))
                if not block or len(block) > remaining:
                    raise LegacyReadUnavailable()
                remaining -= len(block)
                yield block
            self._check()
            if self._file.read(1):
                raise LegacyReadUnavailable()
        finally:
            self.close()

    def __enter__(self):
        try:
            self._check(); return self
        except Exception:
            self.close()
            raise

    def __exit__(self, *_):
        self.close()

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True
        self._cancel.set(); self._timer.cancel()
        try:
            self._file.close()
        finally:
            self._release()


class LegacyPrivateMediaService(LegacyConversationDiscoveryService):
    """Only the already emitted profile/message/meeting opaque references.

    Own-profile references authorize only the current user's exact avatar field.
    Independent gallery/wall routes and quoted/shared wall images are unsupported.
    Deleted, blocked, missing owners fail closed.
    """
    def __init__(self, env, cursor_key, *, private_s3, connect=None,
            clock=time.time, monotonic=time.monotonic):
        super().__init__(env, cursor_key, connect=connect, clock=clock, monotonic=monotonic)
        self._private_s3 = private_s3
        self._spool_lifetime_lock = threading.Lock()
        self._http_spool_directory = None
        self._env["CLRS_LEGACY_READ_DB_URL"] = env.get("CLRS_LEGACY_MEDIA_DB_URL", "")
        self._env["CLRS_LEGACY_READ_DB_CA_FILE"] = env.get("CLRS_LEGACY_MEDIA_DB_CA_FILE", BUNDLED_CA_FILE)
        self._env["CLRS_LEGACY_READ_PERMISSION_MODEL"] = env.get(
            "CLRS_LEGACY_MEDIA_PERMISSION_MODEL", "strict-tables-v1")

    @classmethod
    def from_env(cls, env=None, *, private_s3=None, cursor_key=None, connect=None,
            clock=time.time, monotonic=time.monotonic):
        env = os.environ if env is None else env
        if env.get("CLRS_LEGACY_MEDIA_ENABLED") != "1":
            return None
        try:
            from native_credentials import decode_base64
            from media_promotion_acknowledgement import (
                verify_media_promotion_acknowledgement, MediaPromotionUnavailable)
            if cursor_key is None:
                cursor_key = decode_base64(env.get("CLRS_LEGACY_CURSOR_KEY_B64"), max_bytes=32)
            if not isinstance(cursor_key, bytes) or len(cursor_key) != 32:
                raise LegacyReadUnavailable()
            acknowledgement = verify_media_promotion_acknowledgement(env,
                clock=clock, separate_from=(cursor_key,))
            if (getattr(private_s3, "_bucket", None) != env.get("CLRS_LEGACY_MEDIA_TARGET_BUCKET")
                    or getattr(private_s3, "_owner", None) != env.get("CLRS_LEGACY_MEDIA_EXPECTED_OWNER")
                    or not callable(getattr(private_s3, "get_verified_to_file", None))):
                raise LegacyReadUnavailable()
            def reviewed_clock():
                try:
                    return acknowledgement.require_current(clock())
                except MediaPromotionUnavailable:
                    raise LegacyReadUnavailable() from None
            # A clock regression must not turn a future receipt into proof.
            # Completed migration proof itself has no arbitrary expiry.
            settings = dict(env)
            settings.pop("CLRS_LEGACY_MEDIA_PROMOTION_RECEIPT_KEY_B64", None)
            settings.pop("CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64", None)
            service = cls(settings, cursor_key, private_s3=private_s3, connect=connect,
                clock=reviewed_clock, monotonic=monotonic)
            service._configuration()
            return service
        except Exception:
            raise LegacyReadUnavailable() from None

    def _configuration(self):
        if (self._env.get("CLRS_LEGACY_MEDIA_ENABLED") != "1"
                or self._env.get("CLRS_LEGACY_MEDIA_PROMOTION_REVIEWED") != "1"
                or self._env.get("CLRS_LEGACY_MEDIA_PROMOTION_MODE") != "reviewed-immutable-object-alias"
                or self._env.get("CLRS_LEGACY_MEDIA_S3_USER_MODE") != "dedicated-read-only"
                or self._env.get("CLRS_LEGACY_MEDIA_FULL_READBACK_SOURCE_SHA256")
                    != self._env.get("CLRS_LEGACY_READ_SOURCE_SHA256")):
            raise LegacyReadUnavailable()
        return super()._configuration()

    def _grants(self, rows):
        if self.permission_model == "provider-database-v1":
            return self._database_grants(rows)
        found = set(); usage = False
        names = "|".join(sorted(TABLES))
        pattern = (r"GRANT (USAGE|SELECT) ON (\*\.\*|`clrs_staging`\.`(" + names
            + r")`) TO (?:`[^`]+`|'[^']+')@(?:`[^`]+`|'[^']+')( REQUIRE SSL)?")
        for row in rows:
            if not isinstance(row, (tuple, list)) or len(row) != 1 or not isinstance(row[0], str):
                raise LegacyReadUnavailable()
            match = re.fullmatch(pattern, row[0])
            if match is None:
                raise LegacyReadUnavailable()
            if match[2] == "*.*":
                if match[1] != "USAGE" or usage:
                    raise LegacyReadUnavailable()
                usage = True
            else:
                if match[1] != "SELECT" or match[4] or match[3] in found:
                    raise LegacyReadUnavailable()
                found.add(match[3])
        if not usage or found != TABLES:
            raise LegacyReadUnavailable()

    def _reference(self, identity, token):
        uid = self._uid(identity)
        try:
            ref = self._codec.open("media", token)
            purpose = ref.get("purpose")
            if not isinstance(purpose, str):
                raise LegacyInvalid()
            if purpose == "messages":
                extras = {"message"}
            elif purpose == "participants" or (purpose in {"personal_chats", "own_meetings"} and "profile" in ref):
                extras = {"profile", "profileDigest"}
            elif purpose in {"own_meetings", "meeting_details"}:
                extras = {"meeting", "parentDigest"}
            elif purpose == "own-profile":
                extras = {"field"}
                if ref.get("field") not in {"profilePic", "profilePicThumb"}:
                    raise LegacyInvalid()
            else:
                raise LegacyInvalid()
            now = int(self._clock())
            if (set(ref) != _BASE_KEYS | extras or type(ref["v"]) is not int or ref["v"] != 1
                    or ref["uid"] != uid or ref["source"] != self._env.get("CLRS_LEGACY_READ_SOURCE_SHA256")
                    or not isinstance(ref["source"], str) or not _DIGEST.fullmatch(ref["source"])
                    or ref["bucket"] != self._env.get("CLRS_LEGACY_READ_SOURCE_BUCKET")
                    or type(ref["exp"]) is not int or not now < ref["exp"] <= now + 300
                    or not isinstance(ref["parent"], str) or not _DIGEST.fullmatch(ref["parent"])):
                raise LegacyInvalid()
            _source_path(ref["path"])
            _source_path(ref["collection"])
            for name in extras & {"profileDigest", "parentDigest"}:
                if not isinstance(ref[name], str) or not _DIGEST.fullmatch(ref[name]):
                    raise LegacyInvalid()
            return ref
        except (LegacyInvalid, LegacyReadRejected, UnicodeError):
            raise LegacyReadRejected() from None

    def _same_image(self, value, ref, source):
        candidate = media_reference(value, bucket=source[2], codec=self._codec,
            binding={}, now=int(self._clock()))
        if not candidate or candidate.get("kind") != "legacy_storage":
            raise LegacyReadRejected()
        match = self._codec.open("media", candidate["reference"])
        if match.get("bucket") != ref["bucket"] or match.get("path") != ref["path"]:
            raise LegacyReadRejected()

    @staticmethod
    def _owner_active(cursor, execute, owner):
        execute("SELECT uid, disabled, lifecycle FROM clrs_staging.accounts WHERE uid = %s LIMIT 1", (owner,))
        if cursor.fetchone() != (owner, 0, "active"):
            raise LegacyReadRejected()

    def _candidate_relation(self, cursor, execute, ref, uid, owner, *, meeting):
        collection = "meets" if meeting else "chats"
        if ref["collection"] != collection or ref["parent"] != hashlib.sha256(
                ("immutable-discovery\0" + ref["purpose"]).encode()).hexdigest():
            raise LegacyReadRejected()
        if meeting:
            condition = """CAST(JSON_UNQUOTE(JSON_EXTRACT(encoded_payload, '$.fields.admin.stringValue')) AS BINARY) = %s
                AND (CAST(JSON_UNQUOTE(JSON_EXTRACT(encoded_payload, '$.fields.admin.stringValue')) AS BINARY) = %s
                OR JSON_CONTAINS(JSON_EXTRACT(encoded_payload, '$.fields.users.arrayValue.values'), JSON_OBJECT('stringValue', %s)) = 1)"""
            params = (owner.encode(), uid.encode(), uid)
        else:
            a = "CAST(JSON_UNQUOTE(JSON_EXTRACT(encoded_payload, '$.fields.user1.stringValue')) AS BINARY)"
            b = "CAST(JSON_UNQUOTE(JSON_EXTRACT(encoded_payload, '$.fields.user2.stringValue')) AS BINARY)"
            condition = f"(({a} = %s AND {b} = %s) OR ({a} = %s AND {b} = %s))"
            params = (uid.encode(), owner.encode(), owner.encode(), uid.encode())
        execute(f"""SELECT firebase_path, collection_path, document_id,
            CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= {MAX_DOCUMENT_BYTES}
                THEN encoded_payload ELSE NULL END AS safe_payload, payload_sha256
            FROM clrs_staging.legacy_documents WHERE collection_path_sha256 = %s
                AND CAST(collection_path AS BINARY) = %s AND {condition}
            LIMIT %s""", (_sha(collection), collection.encode(), *params, MAX_CANDIDATE_PARENTS + 1))
        rows = cursor.fetchall()
        if not 1 <= len(rows) <= MAX_CANDIDATE_PARENTS:
            raise LegacyReadRejected()
        allowed = False; seen = set(); proofs = []
        for row in rows:
            parent = self._row(row, collection=collection)
            if parent[0] in seen:
                raise LegacyReadUnavailable()
            seen.add(parent[0])
            if meeting:
                organizer, _, candidate, kicked = self._meeting_membership(parent, uid)
                if organizer != owner or not candidate:
                    raise LegacyReadUnavailable()
                allowed |= not kicked
            else:
                users = self._chat_members(parent, uid)
                if owner not in users:
                    raise LegacyReadUnavailable()
                allowed = True
            proofs.append([parent[0], parent[3]])
        if not allowed:
            raise LegacyReadRejected()
        return hashlib.sha256(json.dumps(sorted(proofs, key=lambda item: item[0].encode()),
            ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()

    def _context(self, cursor, execute, ref, uid, source):
        purpose = ref["purpose"]; collection = ref["collection"]
        if purpose == "own-profile":
            if collection != "users":
                raise LegacyReadRejected()
            profile = self._document(cursor, execute, "users/" + uid)
            if profile[3] != ref["parent"]:
                raise LegacyReadRejected()
            fields = profile[2]["fields"]
            saved_uid = string_field(fields, "uid")
            deleted = field(fields, "deleted", "booleanValue")
            if (saved_uid not in {None, uid}
                    or (deleted is not None and type(deleted) is not bool)
                    or deleted is True
                    or string_field(fields, "status") not in {None, "", "active"}
                    or string_field(fields, "registrationStatus") in {"deleted", "blocked"}):
                raise LegacyReadRejected()
            # The full-profile producer binds an exact source field, so a full
            # avatar never silently substitutes its different thumbnail.
            self._same_image(string_field(fields, ref["field"], 4096, required=True), ref, source)
            owner = uid; ready_purpose = "profile"; context_digest = profile[3]
        elif purpose == "messages":
            parts = collection.split("/")
            if len(parts) == 3 and parts[0] in {"chats", "meets"}:
                meeting = parts[0] == "meets"
                if parts[2] != ("messages" if meeting else "chats"):
                    raise LegacyReadRejected()
                identifier(parts[1]); parent = self._document(cursor, execute, "/".join(parts[:2]))
                (self._meet_members if meeting else self._chat_members)(parent, uid)
                if parent[3] != ref["parent"]:
                    raise LegacyReadRejected()
            elif len(parts) == 5 and parts[:2] == ["users", uid] and parts[2] == "removed_meets" and parts[4] == "messages":
                identifier(parts[3]); meeting = True
                if ref["parent"] != hashlib.sha256(("owned-removed-history\0" + collection).encode()).hexdigest():
                    raise LegacyReadRejected()
            else:
                raise LegacyReadRejected()
            message = self._document(cursor, execute, _source_path(ref["message"]))
            if message[0] != collection + "/" + message[1]:
                raise LegacyReadRejected()
            fields = message[2]["fields"]
            if string_field(fields, "deleteFor") == uid or uid in uid_list(fields, "deletedFor"):
                raise LegacyReadRejected()
            self._same_image(string_field(fields, "image", 4096, required=True), ref, source)
            owner = identifier(string_field(fields, "sender" if meeting else "sendByID", required=True), uid=True)
            context_digest = message[3]
            ready_purpose = "message"
        elif "profile" in ref:
            profile_path = _source_path(ref["profile"])
            parts = profile_path.split("/")
            if len(parts) != 2 or parts[0] != "users":
                raise LegacyReadRejected()
            owner = identifier(parts[1], uid=True)
            profile = self._document(cursor, execute, profile_path)
            if profile[3] != ref["profileDigest"]:
                raise LegacyReadRejected()
            fields = profile[2]["fields"]
            deleted = field(fields, "deleted", "booleanValue")
            if (deleted is not None and type(deleted) is not bool):
                raise LegacyInvalid()
            if (deleted is True or string_field(fields, "status") in {"deleted", "blocked"}
                    or string_field(fields, "registrationStatus") in {"deleted", "blocked"}):
                raise LegacyReadRejected()
            if purpose == "participants":
                parts = collection.split("/")
                if len(parts) != 2 or parts[0] != "meets":
                    raise LegacyReadRejected()
                identifier(parts[1]); parent = self._document(cursor, execute, collection)
                organizer, members, candidate, kicked = self._meeting_membership(parent, uid)
                if (not candidate or kicked or parent[3] != ref["parent"]
                        or owner not in set(members) | {organizer}
                        or owner in uid_list(parent[2]["fields"], "kicked")):
                    raise LegacyReadRejected()
                relation_digest = parent[3]
            else:
                relation_digest = self._candidate_relation(cursor, execute, ref, uid, owner, meeting=purpose == "own_meetings")
            self._same_image(string_field(fields, "profilePicThumb", 4096)
                or string_field(fields, "profilePic", 4096, required=True), ref, source)
            context_digest = hashlib.sha256((profile[3] + "\0" + relation_digest).encode()).hexdigest()
            ready_purpose = "profile"
        else:
            path = _source_path(ref["meeting"])
            parts = path.split("/")
            if len(parts) != 2 or parts[0] != "meets":
                raise LegacyReadRejected()
            identifier(parts[1]); parent = self._document(cursor, execute, path)
            owner, _, candidate, kicked = self._meeting_membership(parent, uid)
            if not candidate or kicked or parent[3] != ref["parentDigest"]:
                raise LegacyReadRejected()
            if purpose == "meeting_details":
                if collection != path or ref["parent"] != parent[3]:
                    raise LegacyReadRejected()
            elif (collection != "meets" or ref["parent"] != hashlib.sha256(
                    b"immutable-discovery\0own_meetings").hexdigest()):
                raise LegacyReadRejected()
            fields = parent[2]["fields"]
            self._same_image(string_field(fields, "imageUrl", 4096)
                or string_field(fields, "meetingImageUrl", 4096, required=True), ref, source)
            context_digest = parent[3]; ready_purpose = "meeting"
        self._owner_active(cursor, execute, owner)
        return owner, ready_purpose, context_digest

    def _authorize(self, identity, ref):
        def action(cursor, execute, uid, source, pin):
            if uid != ref["uid"] or pin != ref["source"] or source[2] != ref["bucket"] or int(self._clock()) >= ref["exp"]:
                raise LegacyReadRejected()
            owner, purpose, context_digest = self._context(cursor, execute, ref, uid, source)
            execute(STORAGE_QUERY, (ref["bucket"], _sha(ref["path"])))
            raw = cursor.fetchone()
            if (raw is None or len(raw) != 8 or raw[0] != ref["bucket"] or raw[1] != ref["path"]
                    or type(raw[3]) is not int or not 0 <= raw[3] <= MAX_OBJECT_BYTES or raw[7] is None):
                raise LegacyReadUnavailable()
            sha = _hash(raw[4]); expected_key = target_key(source[0], source[2], ref["path"])
            if raw[5] != expected_key or _hash(raw[6]) != sha:
                raise LegacyReadUnavailable()
            mime = _metadata(raw[2]).get("contentType")
            if mime not in MIME_TYPES:
                raise LegacyReadRejected()
            execute(PROMOTION_QUERY, (_sha(expected_key),))
            ready = cursor.fetchone()
            if ready is None:
                raise LegacyReadRejected()
            if (len(ready) != 8 or ready[0] != owner or ready[1] != purpose or ready[2] != expected_key
                    or ready[3] != mime or type(ready[4]) is not int or ready[4] != raw[3]
                    or _hash(ready[5]) != sha or ready[6] != "ready" or ready[7] != ref["path"]):
                raise LegacyReadRejected()
            return {"record": {"key": expected_key, "size": raw[3], "sha256": sha, "content_type": mime},
                "owner": owner, "purpose": purpose, "contextDigest": context_digest}
        return self._read(identity, action)

    def _spool(self):
        path = self._env.get("CLRS_LEGACY_MEDIA_SPOOL_DIR", "")
        try:
            if not isinstance(path, str) or not os.path.isabs(path):
                raise ValueError()
            info = os.lstat(path)
            if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
                    or info.st_uid != os.getuid()):
                raise ValueError()
            return tempfile.TemporaryFile(mode="w+b", dir=path)
        except Exception:
            raise LegacyReadUnavailable() from None

    def close(self):
        with self._spool_lifetime_lock:
            directory = self._http_spool_directory
            self._http_spool_directory = None
        if directory is not None:
            directory.cleanup()

    def open_media(self, identity, reference, *, request_cancel=None, request_deadline=None):
        uid = self._uid(identity)
        try:
            # Bound malformed opaque values before AES/SQL, separately from the
            # inherited 60/min UID and 240/min process SQL-read limits.
            self._limiter.consume("legacy-media-uid", uid, 30)
            self._limiter.consume("legacy-media-process", "singleton", 120)
        except NativeRateLimited:
            raise LegacyReadRateLimited() from None
        ref = self._reference(identity, reference)
        now = self._monotonic()
        if (request_cancel is not None and not isinstance(request_cancel, threading.Event)):
            raise LegacyReadUnavailable()
        if (request_deadline is not None and (type(request_deadline) not in (int, float)
                or not math.isfinite(request_deadline) or request_deadline <= now)):
            raise LegacyReadUnavailable()
        if not _SLOTS.acquire(blocking=False):
            raise LegacyReadUnavailable()
        cancel = request_cancel if request_cancel is not None else threading.Event()
        file = None; handed_off = False; timer = None
        deadline = min(now + REQUEST_SECONDS, request_deadline) if request_deadline is not None else now + REQUEST_SECONDS
        def check():
            self._uid(identity)
            if cancel.is_set() or self._monotonic() >= deadline or int(self._clock()) >= ref["exp"]:
                raise LegacyReadRejected()
        try:
            timer = threading.Timer(max(0, deadline - self._monotonic()), cancel.set)
            timer.daemon = True; timer.start()
            check(); before = self._authorize(identity, ref)
            file = self._spool()
            self._private_s3.get_verified_to_file(before["record"], file,
                deadline=min(deadline, self._monotonic() + DOWNLOAD_SECONDS), cancel=cancel)
            check()
            file.seek(0, os.SEEK_END)
            if file.tell() != before["record"]["size"]:
                raise LegacyReadUnavailable()
            file.seek(0); digest = hashlib.sha256()
            while True:
                check(); chunk = file.read(CHUNK_BYTES)
                if not chunk:
                    break
                digest.update(chunk)
            if digest.hexdigest() != before["record"]["sha256"]:
                raise LegacyReadUnavailable()
            # A download can outlive a block, profile change or parent change.
            # A NEW READ ONLY transaction must reconfirm the complete context
            # after all bytes have been verified and before any response bytes.
            after = self._authorize(identity, ref)
            if after != before:
                raise LegacyReadRejected()
            file.seek(0); check()
            lease = VerifiedMediaLease(file, before["record"], check=check, cancel=cancel,
                deadline=deadline, monotonic=self._monotonic, timer=timer, release=_SLOTS.release)
            handed_off = True
            return lease
        except LegacyReadRejected:
            raise
        except Exception:
            raise LegacyReadUnavailable() from None
        finally:
            # Successful handoff transfers ownership to the lease. On failure
            # the actual synchronous download has ended before releasing slot.
            if not handed_off:
                cancel.set()
                if timer is not None:
                    timer.cancel()
                try:
                    if file is not None:
                        file.close()
                finally:
                    _SLOTS.release()
