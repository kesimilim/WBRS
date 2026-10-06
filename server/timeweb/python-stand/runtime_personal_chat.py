"""Open one current personal chat, without trusting public DTOs or legacy names.

The existing mutation store owns authentication, TLS, grants, transaction and
idempotency. This action locks the unique exact pair and checks both current
profiles with the same eligibility evaluator as the people reader.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import time

from native_credentials import unique_json, CredentialUnavailable
from profile_visibility import (CanonicalVisibility, VisibilityAccount,
                                evaluate_profile_visibility)
from runtime_chat import _identifier, _integer, _stamp
from runtime_mutations import (RuntimeInvalidRequest, RuntimeRejected,
                               RuntimeUnavailable, canonical_json)


OPEN_OPERATION = "chat.open-personal.v1"
MAX_SOURCE_BYTES = 131_072
PAIR_QUERY = """SELECT chat_id, uid_low, uid_high, last_sequence, revision
 FROM clrs_staging.chats WHERE uid_low = %s AND uid_high = %s
 AND CAST(uid_low AS BINARY) = CAST(%s AS BINARY)
 AND CAST(uid_high AS BINARY) = CAST(%s AS BINARY) LIMIT 2"""
MEMBERS_QUERY = """SELECT uid, read_through_sequence, notifications_enabled
 FROM clrs_staging.chat_members WHERE chat_id = %s
 AND CAST(chat_id AS BINARY) = CAST(%s AS BINARY) ORDER BY BINARY uid LIMIT 3"""
PROFILE_QUERY = f"""SELECT p.uid, a.disabled, a.lifecycle, p.profile_details_saved,
 p.registration_complete,
 DATE_FORMAT(p.invisible_until, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),
 CASE WHEN JSON_TYPE(p.legacy_raw) = 'OBJECT'
 AND OCTET_LENGTH(CAST(p.legacy_raw AS CHAR CHARACTER SET utf8mb4)) <= {MAX_SOURCE_BYTES}
 THEN p.legacy_raw ELSE NULL END
 FROM clrs_staging.profiles AS p JOIN clrs_staging.accounts AS a
 ON a.uid = p.uid AND CAST(a.uid AS BINARY) = CAST(p.uid AS BINARY)
 WHERE p.uid = %s AND CAST(p.uid AS BINARY) = CAST(%s AS BINARY)
 LIMIT 1 FOR SHARE OF p, a"""
# Exact indexes only; six rows means unexpected extra index parts. Taking the
# pair lock first also holds the tables' metadata locks until the transaction
# ends. No wide schema scan or assumed uniqueness from an env flag.
INDEX_QUERY = """SELECT s.TABLE_NAME, s.INDEX_NAME, s.NON_UNIQUE,
 s.SEQ_IN_INDEX, s.COLUMN_NAME, s.SUB_PART, c.COLLATION_NAME
 FROM information_schema.STATISTICS AS s JOIN information_schema.COLUMNS AS c
 ON c.TABLE_SCHEMA = s.TABLE_SCHEMA AND c.TABLE_NAME = s.TABLE_NAME
 AND c.COLUMN_NAME = s.COLUMN_NAME
 WHERE s.TABLE_SCHEMA = 'clrs_staging'
 AND ((s.TABLE_NAME = 'chats' AND s.INDEX_NAME IN ('PRIMARY', 'chats_pair_uq'))
 OR (s.TABLE_NAME = 'chat_members' AND s.INDEX_NAME = 'PRIMARY'))
 ORDER BY s.TABLE_NAME, s.INDEX_NAME, s.SEQ_IN_INDEX LIMIT 6"""
_INDEX_PARTS = {
    ("chats", "PRIMARY", 1, "chat_id"),
    ("chats", "chats_pair_uq", 1, "uid_low"),
    ("chats", "chats_pair_uq", 2, "uid_high"),
    ("chat_members", "PRIMARY", 1, "chat_id"),
    ("chat_members", "PRIMARY", 2, "uid"),
}


class _PersonalFailure(Exception):
    def __init__(self, status, code):
        self.status = status; self.code = code


def _uid(value):
    if type(value) is not str:
        raise RuntimeInvalidRequest()
    value = _identifier(value)
    if value in {".", ".."} or "/" in value:
        raise RuntimeInvalidRequest()
    return value


def personal_pair(actor_uid, target_uid):
    """Pure exact ordering and stable ID, independent of caller or operation ID."""
    actor_uid, target_uid = _uid(actor_uid), _uid(target_uid)
    if actor_uid == target_uid:
        raise RuntimeInvalidRequest()
    low, high = sorted((actor_uid, target_uid), key=lambda value: value.encode("utf-8"))
    chat_id = "tw-pair-" + hashlib.sha256(
        b"clrs-current-personal-chat-v1\0" + canonical_json([low, high])).hexdigest()
    return low, high, chat_id


def _indexes(cursor, execute):
    execute(INDEX_QUERY); rows = cursor.fetchall()
    if len(rows) != len(_INDEX_PARTS):
        raise RuntimeUnavailable()
    actual = set()
    for row in rows:
        if (not isinstance(row, (tuple, list)) or len(row) != 7
                or type(row[2]) is not int or row[2] != 0
                or type(row[3]) is not int or row[5] is not None
                or row[6] != "utf8mb4_0900_bin"):
            raise RuntimeUnavailable()
        actual.add((row[0], row[1], row[3], row[4]))
    if actual != _INDEX_PARTS:
        raise RuntimeUnavailable()


def _chat(cursor, execute, low, high, *, readonly=False):
    execute(PAIR_QUERY + (" FOR SHARE" if readonly else " FOR UPDATE"), (low, high, low, high))
    rows = cursor.fetchall()
    if not rows:
        return None
    if len(rows) != 1 or not isinstance(rows[0], (tuple, list)) or len(rows[0]) != 5:
        raise RuntimeUnavailable()
    row = rows[0]
    try:
        _identifier(row[0])
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None
    if type(row[0]) is not str or tuple(row[1:3]) != (low, high):
        raise RuntimeUnavailable()
    return {"chatId": row[0], "sequence": _integer(row[3]), "revision": _integer(row[4])}


def _members(cursor, execute, chat, low, high, *, readonly=False):
    chat_id = chat["chatId"]
    execute(MEMBERS_QUERY + (" FOR SHARE" if readonly else " FOR UPDATE"), (chat_id, chat_id))
    rows = cursor.fetchall()
    if len(rows) != 2:
        raise _PersonalFailure(409, "chat_unavailable")
    found = set()
    for row in rows:
        if (not isinstance(row, (tuple, list)) or len(row) != 3
                or type(row[0]) is not str or row[0] not in (low, high)
                or row[0] in found or type(row[2]) is not int or row[2] not in (0, 1)):
            raise _PersonalFailure(409, "chat_unavailable")
        found.add(row[0])
        if _integer(row[1]) > chat["sequence"]:
            raise RuntimeUnavailable()
    if found != {low, high}:
        raise _PersonalFailure(409, "chat_unavailable")


def _raw(value):
    try:
        if type(value) is bytes:
            if len(value) > MAX_SOURCE_BYTES:
                raise ValueError()
            value = value.decode("utf-8", "strict")
        if type(value) is str:
            if len(value.encode("utf-8")) > MAX_SOURCE_BYTES:
                raise ValueError()
            value = unique_json(value)
        if type(value) is not dict:
            raise ValueError()
        return value
    except (CredentialUnavailable, UnicodeError, ValueError, TypeError, RecursionError):
        raise _PersonalFailure(404, "person_unavailable") from None


def _visible_pair(cursor, execute, low, high, now):
    profiles = {}
    for uid in (low, high):
        execute(PROFILE_QUERY, (uid, uid)); row = cursor.fetchone()
        if (not isinstance(row, (tuple, list)) or len(row) != 7
                or type(row[0]) is not str or row[0] != uid):
            raise _PersonalFailure(404, "person_unavailable")
        profiles[uid] = (VisibilityAccount(row[0], row[1], row[2]),
            CanonicalVisibility(row[0], row[3], row[4], row[5]), _raw(row[6]))
    # Eligibility is symmetric: each current account/profile must be visible
    # to the other. This does not authorize a peer token or return a peer DTO.
    for uid, peer in ((low, high), (high, low)):
        target, canonical, raw = profiles[uid]
        decision = evaluate_profile_visibility(target=target, actor=profiles[peer][0],
            current_actor_uid=peer, canonical=canonical, legacy_raw=raw,
            origin="native" if raw == {} else "legacy", now=now)
        if not decision.visible:
            raise _PersonalFailure(404, "person_unavailable")


def personal_action(target_uid, *, allow_create=False, clock=time.time):
    """Build the bounded SQL action; no connections, retries or writes on its own."""
    target_uid = _uid(target_uid)
    if type(allow_create) is not bool or not callable(clock):
        raise RuntimeInvalidRequest()
    def action(cursor, execute, actor_uid):
        low, high, candidate_id = personal_pair(actor_uid, target_uid)
        try:
            chat = _chat(cursor, execute, low, high)
            if chat is not None:
                _members(cursor, execute, chat, low, high)
            else:
                execute(MEMBERS_QUERY + " FOR UPDATE", (candidate_id, candidate_id))
                if cursor.fetchall():
                    raise RuntimeUnavailable()
            _indexes(cursor, execute)
            _visible_pair(cursor, execute, low, high, datetime.fromtimestamp(clock(), timezone.utc))
        except _PersonalFailure as error:
            return error.status, {"error": error.code}, None
        if chat is not None:
            return 200, {"chatId": chat["chatId"], "peerUid": target_uid,
                         "created": False, "chatRevision": chat["revision"]}, chat["revision"]
        if not allow_create:
            # strict-tables-v1 has no INSERT on these two tables. Do not widen
            # its shared grant verifier or risk a partial conversation.
            raise RuntimeUnavailable()
        stamp = _stamp(cursor, execute)[:-1].replace("T", " ")
        execute("""INSERT INTO clrs_staging.chats
 (chat_id, uid_low, uid_high, created_at, updated_at, last_sequence, revision, legacy_raw)
 VALUES (%s, %s, %s, %s, %s, 0, 0, %s)""", (candidate_id, low, high, stamp, stamp, "{}"))
        if cursor.rowcount != 1:
            raise RuntimeUnavailable()
        for uid in (low, high):
            execute("""INSERT INTO clrs_staging.chat_members
 (chat_id, uid, read_through_sequence, notifications_enabled, archived_at)
 VALUES (%s, %s, 0, 1, NULL)""", (candidate_id, uid))
            if cursor.rowcount != 1:
                raise RuntimeUnavailable()
        created = _chat(cursor, execute, low, high)
        if (created is None or created["chatId"] != candidate_id
                or created["sequence"] != 0 or created["revision"] != 0):
            raise RuntimeUnavailable()
        _members(cursor, execute, created, low, high)
        return 201, {"chatId": candidate_id, "peerUid": target_uid,
                     "created": True, "chatRevision": 0}, 0
    return action


class PersonalChatAccessRejected(RuntimeRejected):
    """The session remains valid; current access to this target is unavailable."""


class RuntimePersonalChatService:
    def __init__(self, store, *, clock=time.time):
        if store is None or not callable(clock):
            raise RuntimeUnavailable()
        self._store = store; self._clock = clock
        # _configuration + SHOW GRANTS are verified by the store every time.
        self._allow_create = getattr(store, "_env", {}).get(
            "CLRS_RUNTIME_PERMISSION_MODEL", "strict-tables-v1") == "provider-database-v1"
        store.register_replay_guard(OPEN_OPERATION, self._replay_guard, response_guard=True)

    def _replay_guard(self, cursor, execute, actor_uid, request, response):
        if type(request) is not dict or set(request) != {"targetUid"} or type(response) is not dict:
            raise RuntimeUnavailable()
        try:
            target_uid = _uid(request["targetUid"])
            low, high, _ = personal_pair(actor_uid, target_uid)
        except RuntimeInvalidRequest:
            raise RuntimeUnavailable() from None
        if set(response) == {"error"}:
            if response["error"] not in {"person_unavailable", "chat_unavailable"}:
                raise RuntimeUnavailable()
            # The store still checks the actor's current session/account. An
            # error-only receipt exposes no target data and must remain a
            # declared failure, rather than turn into an unknown operation.
            return
        elif (set(response) != {"chatId", "peerUid", "created", "chatRevision"}
                or type(response["chatId"]) is not str or response["peerUid"] != target_uid
                or type(response["created"]) is not bool
                or type(response["chatRevision"]) is not int or response["chatRevision"] < 0):
            raise RuntimeUnavailable()
        try:
            chat = _chat(cursor, execute, low, high, readonly=True)
            _indexes(cursor, execute)
            if chat is not None:
                _members(cursor, execute, chat, low, high, readonly=True)
            _visible_pair(cursor, execute, low, high,
                          datetime.fromtimestamp(self._clock(), timezone.utc))
            if "chatId" in response and (chat is None or response["chatId"] != chat["chatId"]
                    or response["chatRevision"] > chat["revision"]):
                raise RuntimeUnavailable()
        except _PersonalFailure:
            # A receipt is never an authorization bypass after profile hiding,
            # disable, removal, or malformed current source/membership.
            raise PersonalChatAccessRejected() from None

    def open_personal(self, identity, target_uid, operation_id, *, access_token):
        target_uid = _uid(target_uid)
        request = {"targetUid": target_uid}
        action = personal_action(target_uid, allow_create=self._allow_create, clock=self._clock)
        return self._store.mutate(identity, OPEN_OPERATION, operation_id, request, action,
                                  access_token=access_token)
