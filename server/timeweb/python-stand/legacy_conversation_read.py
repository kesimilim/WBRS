"""Default-off compatibility reads from the verified immutable import snapshot.

No HTTP routes, DDL, writes, public Storage URL, Firebase call or account
creation. Only identities returned by the existing server verifiers are input.
This is not a current membership authority after join/leave/block mutations.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import socket
import threading
import time

from auth_bridge import AuthenticatedIdentity
from native_sessions import NativeIdentity
from native_auth import BoundedRateLimiter, NativeRateLimited
from profile_store import _database_config, BUNDLED_CA_FILE
from legacy_conversation_payload import (LegacyInvalid, MAX_DOCUMENT_BYTES,
    OpaqueReferences, document, field, identifier, message_time, message_view,
    media_reference, payload_digest, profile_view, string_field, uid_list)


class LegacyReadRejected(Exception):
    """No resource/owner existence or connector detail is disclosed."""


class LegacyReadUnavailable(Exception):
    pass


class LegacyReadRateLimited(Exception):
    """Future HTTP integration may return a generic 429; fixed 60s retry."""


MAX_PAGE = 50
MAX_HISTORY = 10_000
MAX_RESPONSE_BYTES = 262_144
MAX_INFLIGHT = 4
REQUEST_SECONDS = 8
TABLES = {"accounts", "legacy_source", "legacy_documents"}
_SLOTS = threading.BoundedSemaphore(MAX_INFLIGHT)


def _sha(value):
    return hashlib.sha256(value.encode()).digest()


def _stamp_sql(path):
    # All JSON paths and format strings below are constants, never request SQL.
    raw = f"JSON_UNQUOTE(JSON_EXTRACT(encoded_payload, '{path}'))"
    fraction = f"CASE WHEN LOCATE('.', {raw}) = 0 THEN 0 ELSE CAST(RPAD(SUBSTRING_INDEX(SUBSTRING_INDEX({raw}, '.', -1), 'Z', 1), 9, '0') AS DECIMAL(30,0)) END"
    return (f"CAST(TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00', "
        f"STR_TO_DATE(SUBSTRING({raw}, 1, 19), '%%Y-%%m-%%dT%%H:%%i:%%s')) AS DECIMAL(30,0)) "
        f"* 1000000000 + ({fraction})")


def message_order_sql(time_field):
    if time_field not in {"ts", "time"}:
        raise LegacyReadRejected()
    base = f"$.fields.{time_field}"
    stamp = f"JSON_EXTRACT(encoded_payload, '{base}.timestampValue')"
    millis = f"JSON_EXTRACT(encoded_payload, '{base}.integerValue')"
    value = f"JSON_EXTRACT(encoded_payload, '{base}')"
    regexp = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?Z$"
    return (f"CASE WHEN JSON_TYPE({value}) = 'OBJECT' AND JSON_LENGTH({value}) = 1 "
        f"AND JSON_TYPE({stamp}) = 'STRING' AND JSON_UNQUOTE({stamp}) REGEXP '{regexp}' "
        f"THEN {_stamp_sql(base + '.timestampValue')} "
        f"WHEN JSON_TYPE({value}) = 'OBJECT' AND JSON_LENGTH({value}) = 1 "
        f"AND JSON_TYPE({millis}) = 'STRING' AND JSON_UNQUOTE({millis}) REGEXP '^[0-9]{{1,15}}$' "
        f"AND CAST(JSON_UNQUOTE({millis}) AS DECIMAL(30,0)) BETWEEN 100000000000 AND 253402300799999 "
        f"THEN CAST(JSON_UNQUOTE({millis}) AS DECIMAL(30,0)) * 1000000 "
        f"ELSE {_stamp_sql('$.createTime')} END")


def messages_query(time_field, *, after):
    # MySQL numeric/string comparisons use DOUBLE; cursor nanos require exact
    # DECIMAL on both boundaries to avoid losing messages at close timestamps.
    condition = "WHERE (order_ns < CAST(%s AS DECIMAL(30,0)) OR (order_ns = CAST(%s AS DECIMAL(30,0)) AND CAST(document_id AS BINARY) < %s))" if after else ""
    return f"""SELECT firebase_path, collection_path, document_id, safe_payload, payload_sha256, order_ns
    FROM (SELECT firebase_path, collection_path, document_id, payload_sha256,
       CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= {MAX_DOCUMENT_BYTES}
         THEN encoded_payload ELSE NULL END AS safe_payload,
       ({message_order_sql(time_field)}) AS order_ns
       FROM clrs_staging.legacy_documents
       WHERE collection_path_sha256 = %s AND CAST(collection_path AS BINARY) = %s) AS history
    {condition} ORDER BY order_ns DESC, CAST(document_id AS BINARY) DESC LIMIT %s"""


DOCUMENT_QUERY = f"""SELECT firebase_path, collection_path, document_id,
  CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= {MAX_DOCUMENT_BYTES}
    THEN encoded_payload ELSE NULL END AS safe_payload, payload_sha256
  FROM clrs_staging.legacy_documents WHERE firebase_path_sha256 = %s LIMIT 1"""
COUNT_QUERY = """SELECT COUNT(*) FROM (SELECT archive_id FROM clrs_staging.legacy_documents
  WHERE collection_path_sha256 = %s AND CAST(collection_path AS BINARY) = %s LIMIT %s) AS bounded_history"""


class LegacyConversationReadService:
    def __init__(self, env, cursor_key, *, connect=None, clock=time.time, monotonic=time.monotonic):
        self._env = dict(env); self._connect = connect
        self._clock = clock; self._monotonic = monotonic
        try:
            self._codec = OpaqueReferences(cursor_key)
            self._limiter = BoundedRateLimiter(hmac.digest(cursor_key,
                b"clrs-legacy-read-rate-v1", "sha256"), clock=monotonic, capacity=2048)
        except LegacyInvalid:
            raise LegacyReadUnavailable() from None

    def _configuration(self):
        if (self._env.get("CLRS_LEGACY_READ_ENABLED") != "1"
                or self._env.get("CLRS_LEGACY_READ_SNAPSHOT_REVIEWED") != "1"
                or self._env.get("CLRS_LEGACY_READ_MEMBERSHIP_MODE") != "immutable-reviewed-snapshot"):
            raise LegacyReadUnavailable()
        self.permission_model
        pin = self._env.get("CLRS_LEGACY_READ_SOURCE_SHA256", "")
        if not re.fullmatch(r"[a-f0-9]{64}", pin):
            raise LegacyReadUnavailable()
        source = tuple(self._env.get("CLRS_LEGACY_READ_SOURCE_" + name, "")
            for name in ["PROJECT", "DATABASE", "BUCKET"])
        if not all(isinstance(part, str) and 1 <= len(part) <= 191 for part in source):
            raise LegacyReadUnavailable()
        config = _database_config({"CLRS_DB_URL": self._env.get("CLRS_LEGACY_READ_DB_URL", ""),
            "CLRS_DB_CA_FILE": self._env.get("CLRS_LEGACY_READ_DB_CA_FILE", BUNDLED_CA_FILE)})
        config.update(autocommit=False, charset="utf8mb4", connect_timeout=2, read_timeout=2, write_timeout=2)
        return config, source, pin

    def _uid(self, identity):
        if type(identity) not in {AuthenticatedIdentity, NativeIdentity}:
            raise LegacyReadRejected()
        try:
            uid = identifier(identity.uid, uid=True)
        except LegacyInvalid:
            raise LegacyReadRejected() from None
        now = int(self._clock())
        if (type(identity.issued_at) is not int or type(identity.expires_at) is not int
                or not identity.issued_at <= now < identity.expires_at):
            raise LegacyReadRejected()
        return uid

    @property
    def permission_model(self):
        model = self._env.get("CLRS_LEGACY_READ_PERMISSION_MODEL", "strict-tables-v1")
        if not isinstance(model, str) or model not in {"strict-tables-v1", "provider-database-v1"}:
            raise LegacyReadUnavailable()
        return model

    def _grants(self, rows):
        if self.permission_model == "provider-database-v1":
            return self._database_grants(rows)
        found = set(); usage = False
        for row in rows:
            if len(row) != 1 or not isinstance(row[0], str):
                raise LegacyReadUnavailable()
            match = re.fullmatch(r"GRANT (USAGE|SELECT) ON (\*\.\*|`clrs_staging`\.`(accounts|legacy_source|legacy_documents)`) TO (?:`[^`]+`|'[^']+')@(?:`[^`]+`|'[^']+')( REQUIRE SSL)?", row[0])
            if not match:
                raise LegacyReadUnavailable()
            if match[2] == "*.*":
                if match[1] != "USAGE" or usage:
                    raise LegacyReadUnavailable()
                usage = True
            else:
                if match[4]:
                    raise LegacyReadUnavailable()
                if match[1] != "SELECT" or match[3] in found:
                    raise LegacyReadUnavailable()
                found.add(match[3])
        if not usage or found != TABLES:
            raise LegacyReadUnavailable()

    @staticmethod
    def _database_grants(rows):
        usage = False; database = False
        pattern = (r"GRANT (USAGE|SELECT) ON (\*\.\*|`clrs_staging`\.\*) TO "
            r"(?:`[^`]+`|'[^']+')@(?:`[^`]+`|'[^']+')( REQUIRE SSL)?")
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
                if match[1] != "SELECT" or database or match[3]:
                    raise LegacyReadUnavailable()
                database = True
        if not usage or not database:
            raise LegacyReadUnavailable()

    def _read(self, identity, action):
        uid = self._uid(identity)
        try:
            self._limiter.consume("legacy-uid", uid, 60)
            self._limiter.consume("legacy-process", "singleton", 240)
        except NativeRateLimited:
            raise LegacyReadRateLimited() from None
        if not _SLOTS.acquire(blocking=False):
            raise LegacyReadUnavailable()
        connection = None; timer = None
        deadline = self._monotonic() + REQUEST_SECONDS
        expired = threading.Event()
        try:
            config, source, pin = self._configuration()
            connect = self._connect
            if connect is None:
                import pymysql
                connect = pymysql.connect
            connection = connect(**config)
            def abort():
                expired.set()
                # PyMySQL's read timeout alone is not an overall request limit.
                # Closing the existing socket cannot create/retry a SQL write.
                stream = getattr(connection, "_sock", None)
                if stream is not None:
                    try:
                        stream.shutdown(socket.SHUT_RDWR)
                    except Exception:
                        pass
                    try:
                        stream.close()
                    except Exception:
                        pass
            remaining = deadline - self._monotonic()
            if remaining <= 0:
                raise LegacyReadUnavailable()
            timer = threading.Timer(remaining, abort); timer.daemon = True; timer.start()
            with connection.cursor() as cursor:
                def execute(sql, parameters=()):
                    if expired.is_set() or self._monotonic() >= deadline:
                        raise LegacyReadUnavailable()
                    cursor.execute(sql, parameters)
                    if expired.is_set() or self._monotonic() >= deadline:
                        raise LegacyReadUnavailable()
                execute("SHOW GRANTS"); self._grants(cursor.fetchall())
                execute("SELECT DATABASE(), VERSION()")
                target = cursor.fetchone()
                if not target or target[0] != "clrs_staging" or not isinstance(target[1], str) or not target[1].startswith("8.4."):
                    raise LegacyReadUnavailable()
                execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
                tls = cursor.fetchone()
                if not tls or not tls[1]:
                    raise LegacyReadUnavailable()
                execute("SET SESSION time_zone = '+00:00'")
                execute("SET SESSION max_execution_time = 1000")
                execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
                execute("START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY")
                execute("SELECT source_project, source_database, source_bucket FROM clrs_staging.legacy_source WHERE singleton = 1")
                if cursor.fetchone() != source:
                    raise LegacyReadUnavailable()
                execute("SELECT uid, disabled, lifecycle FROM clrs_staging.accounts WHERE uid = %s LIMIT 1", (uid,))
                account = cursor.fetchone()
                if account != (uid, 0, "active"):
                    raise LegacyReadRejected()
                result = action(cursor, execute, uid, source, pin)
                self._uid(identity)  # Expiry can pass while the read is running.
                if len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()) > MAX_RESPONSE_BYTES:
                    raise LegacyReadUnavailable()
                if expired.is_set() or self._monotonic() >= deadline:
                    raise LegacyReadUnavailable()
                return result
        except LegacyReadRejected:
            raise
        except Exception:
            raise LegacyReadUnavailable() from None
        finally:
            if timer is not None:
                timer.cancel()
            if connection is not None:
                # READ ONLY has no COMMIT or changes to persist.
                try:
                    connection.rollback()
                except Exception:
                    pass
                try:
                    connection.close()
                except Exception:
                    pass
            _SLOTS.release()

    @staticmethod
    def _row(row, *, path=None, collection=None):
        if row is None or len(row) < 5:
            raise LegacyReadRejected()
        source_path, source_collection, message_id, raw, digest = row[:5]
        try:
            identifier(message_id)
            if (not isinstance(source_path, str) or not isinstance(source_collection, str)
                    or source_path != source_collection + "/" + message_id
                    or (path is not None and source_path != path)
                    or (collection is not None and source_collection != collection)
                    or not isinstance(digest, (bytes, bytearray, memoryview)) or len(digest) != 32):
                raise LegacyInvalid()
            payload = document(raw)
            expected_hash = bytes(digest).hex()
            if payload_digest(payload) != expected_hash:
                raise LegacyInvalid()
            return source_path, message_id, payload, expected_hash
        except LegacyInvalid:
            raise LegacyReadUnavailable() from None

    def _document(self, cursor, execute, path, *, optional=False):
        execute(DOCUMENT_QUERY, (_sha(path),))
        row = cursor.fetchone()
        if row is None and optional:
            return None
        return self._row(row, path=path)

    @staticmethod
    def _chat_members(parent, uid):
        fields = parent[2]["fields"]
        users = [identifier(string_field(fields, name, required=True), uid=True) for name in ["user1", "user2"]]
        if uid not in users:
            raise LegacyReadRejected()
        return users

    @staticmethod
    def _meet_members(parent, uid):
        fields = parent[2]["fields"]
        users = uid_list(fields, "users")
        kicked = uid_list(fields, "kicked")
        if uid not in users or uid in kicked:
            raise LegacyReadRejected()
        return users

    @staticmethod
    def _limit(limit):
        if type(limit) is not int or not 1 <= limit <= MAX_PAGE:
            raise LegacyReadRejected()
        return limit

    def _binding(self, uid, pin, collection, parent_digest, purpose):
        return {"v": 1, "uid": uid, "source": pin, "collection": collection,
            "parent": parent_digest, "purpose": purpose}

    def _cursor(self, token, binding):
        if token is None:
            return None
        try:
            value = self._codec.open("cursor", token)
            if (set(value) != set(binding) | {"after", "exp"}
                    or any(value.get(key) != expected for key, expected in binding.items())
                    or type(value["exp"]) is not int or not int(self._clock()) < value["exp"] <= int(self._clock()) + 300):
                raise LegacyInvalid()
            return value["after"]
        except LegacyInvalid:
            raise LegacyReadRejected() from None

    def _next(self, binding, after):
        return self._codec.seal("cursor", {**binding, "after": after, "exp": int(self._clock()) + 300})

    def _messages(self, identity, resource_id, *, meeting, archived, limit, cursor_token):
        try:
            resource_id = identifier(resource_id); self._limit(limit)
        except LegacyInvalid:
            raise LegacyReadRejected() from None
        if type(archived) is not bool or (archived and not meeting):
            raise LegacyReadRejected()
        def action(cursor, execute, uid, source, pin):
            parent_path = ("meets/" if meeting else "chats/") + resource_id
            if archived:
                # The only owner path is built from verified identity, never a
                # target UID argument. Sparse missing archive parents are valid.
                collection = f"users/{uid}/removed_meets/{resource_id}/messages"
                parent_digest = hashlib.sha256(("owned-removed-history\0" + collection).encode()).hexdigest()
            else:
                parent = self._document(cursor, execute, parent_path)
                (self._meet_members if meeting else self._chat_members)(parent, uid)
                collection = parent_path + ("/messages" if meeting else "/chats")
                parent_digest = parent[3]
            muted = None
            if not archived:
                try:
                    muted = uid in uid_list(parent[2]["fields"], "usersWithoutNotification" if meeting else "usersWOutNotifications")
                except LegacyInvalid:
                    pass  # Optional preferences never grant or deny membership.
            binding = self._binding(uid, pin, collection, parent_digest, "messages")
            after = self._cursor(cursor_token, binding)
            parameters = [_sha(collection), collection.encode()]
            if after is not None:
                if (not isinstance(after, list) or len(after) != 2 or not isinstance(after[0], str)
                        or not re.fullmatch(r"-?[0-9]{1,30}", after[0])):
                    raise LegacyReadRejected()
                try:
                    after_id = identifier(after[1])
                except LegacyInvalid:
                    raise LegacyReadRejected() from None
                parameters.extend([after[0], after[0], after_id.encode()])
            execute(COUNT_QUERY, (_sha(collection), collection.encode(), MAX_HISTORY + 1))
            count = cursor.fetchone()
            if not count or type(count[0]) is not int or not 0 <= count[0] <= MAX_HISTORY:
                raise LegacyReadUnavailable()
            parameters.append(limit + 1)
            execute(messages_query("time" if meeting else "ts", after=after is not None), tuple(parameters))
            rows = cursor.fetchall()
            if len(rows) > limit + 1:
                raise LegacyReadUnavailable()
            items = []; previous = None; last = None
            for index, row in enumerate(rows):
                path, message_id, payload, _ = self._row(row, collection=collection)
                order, _, _ = message_time(payload, "time" if meeting else "ts")
                if row[5] is None or str(row[5]) != str(order):
                    raise LegacyReadUnavailable()
                key = (order, message_id.encode())
                if previous is not None and key >= previous:
                    raise LegacyReadUnavailable()
                if after is not None and key >= (int(after[0]), after[1].encode()):
                    raise LegacyReadUnavailable()
                previous = key
                if index >= limit:
                    continue
                # A hidden message still advances the underlying source cursor.
                last = [str(order), message_id]
                view = message_view(payload, message_id, uid=uid, group=meeting,
                    bucket=source[2], codec=self._codec, binding={**binding, "message": path}, now=int(self._clock()))
                if view is not None:
                    items.append(view)
            return {"items": items, "nextCursor": self._next(binding, last) if len(rows) > limit and last is not None else None,
                "history": "own_removed_meeting" if archived else "current_import_snapshot",
                "sourceSnapshot": pin, "membershipAuthority": "immutable-reviewed-snapshot",
                "notificationsMuted": muted, "mediaReady": False, "readReceiptsWritten": False}
        return self._read(identity, action)

    def personal_messages(self, identity, chat_id, *, limit=MAX_PAGE, cursor=None):
        return self._messages(identity, chat_id, meeting=False, archived=False, limit=limit, cursor_token=cursor)

    def meeting_messages(self, identity, meeting_id, *, own_removed=False, limit=MAX_PAGE, cursor=None):
        return self._messages(identity, meeting_id, meeting=True, archived=own_removed, limit=limit, cursor_token=cursor)

    def meeting_participants(self, identity, meeting_id, *, limit=MAX_PAGE, cursor=None):
        try:
            meeting_id = identifier(meeting_id); self._limit(limit)
        except LegacyInvalid:
            raise LegacyReadRejected() from None
        def action(sql_cursor, execute, uid, source, pin):
            parent = self._document(sql_cursor, execute, "meets/" + meeting_id)
            fields = parent[2]["fields"]; users = uid_list(fields, "users"); kicked = uid_list(fields, "kicked")
            organizer = string_field(fields, "admin")
            if organizer is not None:
                organizer = identifier(organizer, uid=True)
            if uid in kicked or (uid not in users and uid != organizer):
                raise LegacyReadRejected()
            display_ids = sorted(set(users) | ({organizer} if organizer else set()),
                key=lambda item: (0 if item == organizer else 1, item.encode()))
            binding = self._binding(uid, pin, parent[0], parent[3], "participants")
            after = self._cursor(cursor, binding)
            if after is not None:
                if not isinstance(after, str) or after not in display_ids:
                    raise LegacyReadRejected()
                display_ids = display_ids[display_ids.index(after) + 1:]
            page = display_ids[:limit]; items = []
            accounts = {}; profiles = {}
            if page:
                placeholders = ",".join(["%s"] * len(page))
                execute("SELECT uid, disabled, lifecycle FROM clrs_staging.accounts WHERE uid IN (" + placeholders + ")", tuple(page))
                for row in sql_cursor.fetchall():
                    if len(row) != 3 or row[0] not in page or row[0] in accounts:
                        raise LegacyReadUnavailable()
                    accounts[row[0]] = row
                paths = {"users/" + item: item for item in page}
                execute(f"""SELECT firebase_path, collection_path, document_id,
                    CASE WHEN OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= {MAX_DOCUMENT_BYTES}
                      THEN encoded_payload ELSE NULL END AS safe_payload, payload_sha256
                    FROM clrs_staging.legacy_documents WHERE firebase_path_sha256 IN ({placeholders})""",
                    tuple(_sha(path) for path in paths))
                for row in sql_cursor.fetchall():
                    if row[0] not in paths or row[0] in profiles:
                        raise LegacyReadUnavailable()
                    profiles[row[0]] = self._row(row, path=row[0])
            for participant_uid in page:
                account = accounts.get(participant_uid)
                profile = profiles.get("users/" + participant_uid)
                public = profile_view(profile[2]["fields"]) if profile is not None else {"name": None, "deleted": False}
                profile_state = "missing_profile" if profile is None else "legacy_only" if account is None else "deleted" if public["deleted"] or account[1:] != (0, "active") else "active"
                avatar = None
                if profile is not None:
                    try:
                        avatar_value = (string_field(profile[2]["fields"], "profilePicThumb", 4096)
                            or string_field(profile[2]["fields"], "profilePic", 4096))
                        avatar = media_reference(avatar_value,
                            bucket=source[2], codec=self._codec,
                            binding={**binding, "profile": profile[0], "profileDigest": profile[3]}, now=int(self._clock()))
                    except LegacyInvalid:
                        avatar = {"kind": "unavailable", "reason": "malformed_profile_media"}
                items.append({"uid": participant_uid, **public, "profileState": profile_state,
                    "organizer": participant_uid == organizer, "member": participant_uid in users,
                    "interactive": profile_state == "active" and participant_uid not in kicked, "avatar": avatar})
            return {"items": items, "nextCursor": self._next(binding, page[-1]) if len(display_ids) > limit and page else None,
                "ordering": "organizer_then_utf8_uid", "membershipAuthority": "immutable-reviewed-snapshot", "sourceSnapshot": pin}
        return self._read(identity, action)
