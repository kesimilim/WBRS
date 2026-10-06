"""Default-off current-authority mutations; retained legacy tables are immutable.

Only trusted server callbacks receive the transaction cursor. Native access
proof is validated on locked SQL rows, not merely on an identity DTO. A COMMIT
with an uncertain result is never repeated: callers must use lookup instead.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import threading
import time

from native_credentials import decode_base64
from native_sessions import NativeIdentity, SessionTokens, SessionRejected, SESSION_QUERY, _parse
from profile_store import _database_config, BUNDLED_CA_FILE


class RuntimeInvalidRequest(ValueError):
    pass


class RuntimeRejected(Exception):
    pass


class RuntimeConflict(Exception):
    pass


class RuntimeUnavailable(Exception):
    pass


class RuntimeCommitUnknown(RuntimeUnavailable):
    """Only an authenticated receipt lookup may reconcile this outcome."""


@dataclass(frozen=True)
class MutationOutcome:
    status: int
    payload: dict


MAX_INTEGER = 2 ** 63 - 1
MAX_JSON_BYTES = 65536
MAX_RECEIPT_BYTES = 131072
OPERATIONS = frozenset({"profile.finish-registration.v1", "profile.photo.prepare.v1", "profile.photo.commit.v1", "chat.send-text.v1", "chat.mark-read.v1", "chat.open-personal.v1", "meeting.create.v1", "meeting.join.v1", "meeting.leave.v1", "meeting.kick.v1", "meeting.send-text.v1", "profile.edit.v1", "profile.complete-test.v1", "profile.edit-geography.v1"})
RECEIPT_QUERY = """SELECT request_hash, state, response_status, result, entity_revision,
 completed_at FROM clrs_staging.idempotency_receipts
 WHERE actor_uid = %s AND operation = %s AND idempotency_key = %s LIMIT 1"""
_TABLE_GRANTS = {
    "accounts": {"SELECT"}, "device_sessions": {"SELECT"},
    "profiles": {"SELECT", "UPDATE"}, "chats": {"SELECT", "UPDATE"},
    "chat_members": {"SELECT", "UPDATE"}, "chat_messages": {"SELECT", "INSERT"},
    "idempotency_receipts": {"SELECT", "INSERT", "UPDATE"},
    "event_counter": {"SELECT", "UPDATE"}, "user_events": {"SELECT", "INSERT"},
    "outbox": {"SELECT", "INSERT"},
}


def canonical_json(value, *, max_bytes=MAX_JSON_BYTES):
    # Keep the original input. In particular, whitespace and Unicode are not
    # normalized before computing the operation's immutable request hash.
    def check(item, depth=0):
        if depth > 16:
            raise RuntimeInvalidRequest()
        if type(item) is dict:
            for key, child in item.items():
                if not isinstance(key, str):
                    raise RuntimeInvalidRequest()
                check(key, depth + 1); check(child, depth + 1)
        elif type(item) is list:
            for child in item:
                check(child, depth + 1)
        elif item is not None and type(item) not in (str, int, bool, float):
            raise RuntimeInvalidRequest()
        elif type(item) is int and not -MAX_INTEGER <= item <= MAX_INTEGER:
            raise RuntimeInvalidRequest()
    try:
        check(value)
        raw = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                         allow_nan=False).encode("utf-8")
        if len(raw) > max_bytes:
            raise RuntimeInvalidRequest()
        return raw
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise RuntimeInvalidRequest() from None


def request_digest(payload):
    if type(payload) is not dict:
        raise RuntimeInvalidRequest()
    return hashlib.sha256(canonical_json(payload)).digest()


def _operation(operation, operation_id):
    if (operation not in OPERATIONS or not isinstance(operation_id, str)
            or re.fullmatch(r"[A-Za-z0-9_-]{1,128}", operation_id) is None):
        raise RuntimeInvalidRequest()


def _json_dict(value):
    try:
        if isinstance(value, (str, bytes)):
            value = json.loads(value)
        if type(value) is not dict:
            raise RuntimeUnavailable()
        canonical_json(value, max_bytes=MAX_RECEIPT_BYTES)
        return value
    except (TypeError, ValueError, UnicodeError):
        raise RuntimeUnavailable() from None


class _Work:
    def __init__(self):
        self.lock = threading.Lock(); self.done = threading.Event()
        self.cancel = threading.Event(); self.connection = None
        self.committing = False; self.value = None; self.error = None

    def abort(self):
        with self.lock:
            self.cancel.set(); connection = self.connection
        # PyMySQL.close can write/flush. Shutdown the actual socket so a blocked
        # query or COMMIT cannot outlive the deadline silently. The worker owns
        # rollback/close and retains its slot until all I/O has settled.
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


class RuntimeMutationStore:
    def __init__(self, env, tokens, *, connect=None, clock=time.time,
                 monotonic=time.monotonic, request_seconds=8, concurrency=4):
        if (not isinstance(tokens, SessionTokens) or not 0 < request_seconds <= 8
                or type(concurrency) is not int or not 1 <= concurrency <= 4):
            raise RuntimeUnavailable()
        self._env = dict(env); self.tokens = tokens; self._connect = connect
        self._clock = clock; self._monotonic = monotonic; self._seconds = request_seconds
        self._slots = threading.BoundedSemaphore(concurrency)
        self._lock = threading.Lock(); self._active = set(); self._closed = False
        self._replay_guards = {}

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        if env.get("CLRS_RUNTIME_WRITES_ENABLED") != "1":
            return None
        try:
            store = cls(env, SessionTokens(decode_base64(
                env.get("CLRS_NATIVE_SESSION_KEY_B64"), max_bytes=32)))
            store._configuration()  # Pure validation; no connection or probe.
            return store
        except Exception:
            raise RuntimeUnavailable() from None

    def _configuration(self):
        if (self._env.get("CLRS_RUNTIME_WRITES_ENABLED") != "1"
                or self._env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") != "canonical-current-v1"
                or self._env.get("CLRS_RUNTIME_PERMISSION_MODEL", "strict-tables-v1")
                   not in {"strict-tables-v1", "provider-database-v1"}):
            raise RuntimeUnavailable()
        try:
            config = _database_config({"CLRS_DB_URL": self._env.get("CLRS_RUNTIME_DB_URL", ""),
                "CLRS_DB_CA_FILE": self._env.get("CLRS_RUNTIME_DB_CA_FILE", BUNDLED_CA_FILE)})
        except Exception:
            raise RuntimeUnavailable() from None
        config.update(connect_timeout=2, read_timeout=2, write_timeout=2,
                      autocommit=False, charset="utf8mb4")
        return config

    def register_replay_guard(self, operation, callback, *, response_guard=False, operation_id_guard=False):
        if operation not in OPERATIONS or not callable(callback) or operation in self._replay_guards:
            raise RuntimeUnavailable()
        # Trusted service setup only, before HTTP dispatch. The stored original
        # request lets hash-only reconciliation check current chat membership.
        if (type(response_guard) is not bool or type(operation_id_guard) is not bool
                or operation_id_guard and not response_guard):
            raise RuntimeUnavailable()
        self._replay_guards[operation] = (callback, response_guard, operation_id_guard)

    def _grants(self, rows):
        model = self._env.get("CLRS_RUNTIME_PERMISSION_MODEL", "strict-tables-v1")
        found = {table: set() for table in _TABLE_GRANTS}; usage = False; database = False
        for row in rows:
            if not isinstance(row, (tuple, list)) or len(row) != 1 or not isinstance(row[0], str):
                raise RuntimeUnavailable()
            match = re.fullmatch(r"GRANT ([A-Z ,]+) ON (\*\.\*|`clrs_staging`\.\*|`clrs_staging`\.`([a-z_]+)`) TO (?:`[^`]+`|'[^']+')@(?:`[^`]+`|'[^']+')( REQUIRE SSL)?", row[0])
            if not match:
                raise RuntimeUnavailable()
            items = [item.strip() for item in match[1].split(",")]; privileges = set(items)
            if len(items) != len(privileges):
                raise RuntimeUnavailable()
            if match[2] == "*.*":
                if privileges != {"USAGE"} or usage:
                    raise RuntimeUnavailable()
                usage = True
            elif match[4]:
                raise RuntimeUnavailable()
            elif match[2] == "`clrs_staging`.*":
                if model != "provider-database-v1" or database or privileges != {"SELECT", "INSERT", "UPDATE"}:
                    raise RuntimeUnavailable()
                database = True
            else:
                table = match[3]
                if (model != "strict-tables-v1" or table not in found
                        or not privileges <= _TABLE_GRANTS[table] or privileges & found[table]):
                    raise RuntimeUnavailable()
                found[table].update(privileges)
        if not usage or (model == "provider-database-v1" and not database) or (
                model == "strict-tables-v1" and found != _TABLE_GRANTS):
            raise RuntimeUnavailable()

    def _authenticated(self, cursor, execute, identity, token):
        if type(identity) is not NativeIdentity:
            raise RuntimeRejected()
        try:
            sid, _ = _parse(token, "na1")
            if sid != identity.session_id:
                raise RuntimeRejected()
            execute(SESSION_QUERY + " FOR SHARE OF s, a", (sid,))
            values = cursor.fetchone()
            if values is None:
                raise RuntimeRejected()
            if not isinstance(values, (tuple, list)) or len(values) != 12:
                raise RuntimeUnavailable()
            row = dict(zip(["session_id", "uid", "device_id", "refresh_token_hash", "issued_at",
                            "expires_at", "revoked_at", "rotated_from"], values[:8]))
            if (type(values[8]) is not int or values[8] not in (0, 1)
                    or values[9] not in ("active", "blocked", "deleted")
                    or type(values[10]) is not int or not 0 <= values[10] <= MAX_INTEGER
                    or type(values[11]) is not int or values[11] not in (0, 1)):
                raise RuntimeUnavailable()
            version, issued, expires = self.tokens.validate(row, token, access=True, now=int(self._clock()))
            if (values[8] != 0 or values[9] != "active" or version != values[10]
                    or identity.uid != row["uid"] or identity.issued_at != issued
                    or identity.expires_at != expires or type(identity.email_verified) is not bool
                    or identity.email_verified != bool(values[11])):
                raise RuntimeRejected()
            return row["uid"]
        except SessionRejected:
            raise RuntimeRejected() from None

    def _run(self, identity, access_token, action, *, readonly=False):
        configuration = self._configuration()
        if type(identity) is not NativeIdentity:
            raise RuntimeRejected()
        try:
            sid, _ = _parse(access_token, "na1")
            if sid != identity.session_id:
                raise RuntimeRejected()
        except SessionRejected:
            raise RuntimeRejected() from None
        with self._lock:
            if self._closed or not self._slots.acquire(blocking=False):
                raise RuntimeUnavailable()
            work = _Work(); self._active.add(work)
        deadline = self._monotonic() + self._seconds

        def worker():
            connection = None; commit_started = False
            try:
                connect = self._connect
                if connect is None:
                    import pymysql
                    connect = pymysql.connect
                connection = connect(**configuration)
                with work.lock:
                    work.connection = connection
                statements = 0
                with connection.cursor() as cursor:
                    def execute(sql, params=()):
                        nonlocal statements
                        statements += 1
                        if work.cancel.is_set() or self._monotonic() >= deadline or statements > 64:
                            raise RuntimeUnavailable()
                        # Callbacks are fixed server SQL, but never permit a
                        # retained import write even if a future callback errs.
                        verb = sql.lstrip().split(None, 1)[0].upper()
                        if (verb not in {"SELECT", "SHOW", "SET", "INSERT", "UPDATE"}
                                or (readonly and verb not in {"SELECT", "SHOW", "SET"})
                                or re.search(r"\b(?:INSERT\s+INTO|UPDATE)\s+(?:`?clrs_staging`?\s*\.\s*)?`?legacy_[a-z_]+", sql, re.I)):
                            raise RuntimeUnavailable()
                        count = cursor.execute(sql, params)
                        if work.cancel.is_set() or self._monotonic() >= deadline:
                            raise RuntimeUnavailable()
                        return cursor.rowcount if count is None else count
                    execute("SHOW GRANTS"); self._grants(cursor.fetchall())
                    execute("SELECT DATABASE(), VERSION()")
                    version = cursor.fetchone()
                    if not version or version[0] != "clrs_staging" or not isinstance(version[1], str) or not version[1].startswith("8.4."):
                        raise RuntimeUnavailable()
                    execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
                    tls = cursor.fetchone()
                    if not tls or len(tls) != 2 or not tls[1]:
                        raise RuntimeUnavailable()
                    execute("SET SESSION time_zone = '+00:00'")
                    execute("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'")
                    execute("SET SESSION innodb_lock_wait_timeout = 2")
                    execute("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
                    execute("SET TRANSACTION READ ONLY" if readonly else "SET TRANSACTION READ WRITE")
                    connection.begin()
                    uid = self._authenticated(cursor, execute, identity, access_token)
                    value = action(cursor, execute, uid)
                    # Locks protect account/version/revocation; this second
                    # proof also detects access expiry while the action ran.
                    self._authenticated(cursor, execute, identity, access_token)
                    if readonly:
                        connection.rollback()
                    else:
                        with work.lock:
                            if work.cancel.is_set() or self._monotonic() >= deadline:
                                raise RuntimeUnavailable()
                            commit_started = True; work.committing = True
                        try:
                            connection.commit()
                        except Exception:
                            raise RuntimeCommitUnknown() from None
                    if work.cancel.is_set() or self._monotonic() >= deadline:
                        raise RuntimeCommitUnknown() if commit_started else RuntimeUnavailable()
                    work.value = value
            except (RuntimeInvalidRequest, RuntimeRejected, RuntimeConflict, RuntimeUnavailable) as error:
                work.error = error
            except Exception:
                work.error = RuntimeCommitUnknown() if commit_started else RuntimeUnavailable()
            finally:
                if connection is not None:
                    if not commit_started:
                        try:
                            connection.rollback()
                        except Exception:
                            pass
                    try:
                        connection.close()
                    except Exception:
                        pass
                with self._lock:
                    self._active.discard(work)
                self._slots.release(); work.done.set()

        try:
            threading.Thread(target=worker, daemon=True, name="clrs-runtime-transaction").start()
        except Exception:
            with self._lock:
                self._active.discard(work)
            self._slots.release()
            raise RuntimeUnavailable() from None
        if not work.done.wait(max(0, deadline - self._monotonic())):
            work.abort()
            with work.lock:
                unknown = work.committing
            raise RuntimeCommitUnknown() if unknown else RuntimeUnavailable()
        if work.error is not None:
            raise work.error from None
        return work.value

    def _receipt(self, row, expected_hash):
        if (not isinstance(row, (tuple, list)) or len(row) != 6
                or not isinstance(row[0], (bytes, bytearray, memoryview)) or len(row[0]) != 32):
            raise RuntimeUnavailable()
        if not hmac.compare_digest(bytes(row[0]), expected_hash):
            raise RuntimeConflict()
        if row[1] != "completed":
            raise RuntimeUnavailable()
        if (type(row[2]) is not int or not 200 <= row[2] <= 499 or row[5] is None
                or (row[4] is not None and (type(row[4]) is not int or not 0 <= row[4] <= MAX_INTEGER))):
            raise RuntimeUnavailable()
        wrapper = _json_dict(row[3])
        if set(wrapper) != {"request", "response"} or type(wrapper["response"]) is not dict:
            raise RuntimeUnavailable()
        try:
            canonical_json(wrapper["response"])
            if not hmac.compare_digest(request_digest(wrapper["request"]), expected_hash):
                raise RuntimeUnavailable()
        except RuntimeInvalidRequest:
            raise RuntimeUnavailable() from None
        return row[2], wrapper, row[4]

    @staticmethod
    def _outcome(operation, operation_id, digest, status, response, revision, *, replayed):
        payload = {"operation": operation, "operationId": operation_id,
            "requestHash": digest.hex(), "state": "committed", "replayed": replayed,
            "result": response, "entityRevision": revision}
        try:
            canonical_json(payload)
        except RuntimeInvalidRequest:
            raise RuntimeUnavailable() from None
        return MutationOutcome(status, payload)

    def _replayed(self, cursor, execute, uid, operation, operation_id, digest, row):
        status, wrapper, revision = self._receipt(row, digest)
        guard = self._replay_guards.get(operation)
        if operation.startswith(("chat.", "meeting.")) and guard is None:
            raise RuntimeUnavailable()
        if guard is not None:
            callback, response_guard, operation_id_guard = guard
            if operation_id_guard:
                callback(cursor, execute, uid, operation_id, wrapper["request"], wrapper["response"])
            elif response_guard:
                callback(cursor, execute, uid, wrapper["request"], wrapper["response"])
            else:
                callback(cursor, execute, uid, wrapper["request"])
        return self._outcome(operation, operation_id, digest, status, wrapper["response"], revision, replayed=True)

    def mutate(self, identity, operation, operation_id, payload, action, *, access_token):
        _operation(operation, operation_id)
        raw = canonical_json(payload); frozen = json.loads(raw); digest = request_digest(frozen)
        if not callable(action):
            raise RuntimeInvalidRequest()
        def transaction(cursor, execute, uid):
            reservation = {"reservation": secrets.token_hex(16)}
            execute("""INSERT INTO clrs_staging.idempotency_receipts
 (actor_uid, operation, idempotency_key, request_hash, state, result)
 VALUES (%s, %s, %s, %s, 'processing', %s)
 ON DUPLICATE KEY UPDATE actor_uid = actor_uid""",
                (uid, operation, operation_id, digest, canonical_json(reservation).decode()))
            execute(RECEIPT_QUERY + " FOR UPDATE", (uid, operation, operation_id)); row = cursor.fetchone()
            if not isinstance(row, (tuple, list)) or len(row) != 6:
                raise RuntimeUnavailable()
            if not isinstance(row[0], (bytes, bytearray, memoryview)) or not hmac.compare_digest(bytes(row[0]), digest):
                raise RuntimeConflict()
            if row[1] == "completed":
                return self._replayed(cursor, execute, uid, operation, operation_id, digest, row)
            if row[1] != "processing" or _json_dict(row[3]) != reservation or row[5] is not None:
                raise RuntimeUnavailable()
            status, response, revision = action(cursor, execute, uid)
            if (type(status) is not int or not 200 <= status <= 499 or type(response) is not dict
                    or (revision is not None and (type(revision) is not int or not 0 <= revision <= MAX_INTEGER))):
                raise RuntimeUnavailable()
            wrapper = {"request": frozen, "response": response}
            try:
                canonical_json(response)
                encoded = canonical_json(wrapper, max_bytes=MAX_RECEIPT_BYTES).decode()
            except RuntimeInvalidRequest:
                raise RuntimeUnavailable() from None
            execute("""UPDATE clrs_staging.idempotency_receipts SET state = 'completed',
 response_status = %s, result = %s, entity_revision = %s, completed_at = UTC_TIMESTAMP(6)
 WHERE actor_uid = %s AND operation = %s AND idempotency_key = %s
 AND request_hash = %s AND state = 'processing'""",
                (status, encoded, revision, uid, operation, operation_id, digest))
            if cursor.rowcount != 1:
                raise RuntimeUnavailable()
            execute(RECEIPT_QUERY + " FOR UPDATE", (uid, operation, operation_id))
            stored_status, retained, stored_revision = self._receipt(cursor.fetchone(), digest)
            if stored_status != status or stored_revision != revision or retained != wrapper:
                raise RuntimeUnavailable()
            return self._outcome(operation, operation_id, digest, status, retained["response"], revision, replayed=False)
        return self._run(identity, access_token, transaction)

    def lookup(self, identity, operation, operation_id, *, access_token, payload=None, request_hash=None):
        _operation(operation, operation_id)
        if (payload is None) == (request_hash is None):
            raise RuntimeInvalidRequest()
        digest = request_digest(payload) if payload is not None else request_hash
        if not isinstance(digest, bytes) or len(digest) != 32:
            raise RuntimeInvalidRequest()
        def transaction(cursor, execute, uid):
            execute(RECEIPT_QUERY + " FOR SHARE", (uid, operation, operation_id))
            row = cursor.fetchone()
            if row is None:
                return MutationOutcome(200, {"operation": operation, "operationId": operation_id,
                    "requestHash": digest.hex(), "state": "not_found", "replayed": False,
                    "result": None, "entityRevision": None})
            return self._replayed(cursor, execute, uid, operation, operation_id, digest, row)
        return self._run(identity, access_token, transaction, readonly=True)

    def read_authenticated(self, identity, action, *, access_token):
        if not callable(action):
            raise RuntimeInvalidRequest()
        def transaction(cursor, execute, uid):
            result = action(cursor, execute, uid)
            if type(result) is not dict:
                raise RuntimeUnavailable()
            return json.loads(canonical_json(result))
        return self._run(identity, access_token, transaction, readonly=True)

    def close(self):
        with self._lock:
            self._closed = True; active = list(self._active)
        for work in active:
            work.abort()
