"""Current canonical chat/message/event READs under locked native authority.

No legacy payload, credential, arbitrary audience, media URL or write is used.
All callers share the RuntimeMutationStore's bounded authenticated read pool.
"""
from __future__ import annotations

from datetime import datetime
import hmac
import json
import os
import re
import time

from native_credentials import decode_base64, unique_json
from legacy_conversation_payload import OpaqueReferences, LegacyInvalid
from runtime_mutations import (RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable,
                              MAX_INTEGER, MAX_JSON_BYTES, canonical_json)
from runtime_chat import _pair, _ChatFailure, _identifier


class RuntimeReadRejected(RuntimeRejected):
    """An authenticated caller cannot read the requested canonical pair."""


CHAT_ORDER = "updated_at_desc_chat_id_asc_null_last"
_PAIR_JOINS = """JOIN clrs_staging.chat_members AS ml
 ON ml.chat_id = c.chat_id AND CAST(ml.uid AS BINARY) = CAST(c.uid_low AS BINARY)
 JOIN clrs_staging.chat_members AS mh
 ON mh.chat_id = c.chat_id AND CAST(mh.uid AS BINARY) = CAST(c.uid_high AS BINARY)
 JOIN clrs_staging.accounts AS al ON CAST(al.uid AS BINARY) = CAST(c.uid_low AS BINARY)
 JOIN clrs_staging.accounts AS ah ON CAST(ah.uid AS BINARY) = CAST(c.uid_high AS BINARY)"""
_OWN_PAIR = """(CAST(c.uid_low AS BINARY) = CAST(%s AS BINARY)
 OR CAST(c.uid_high AS BINARY) = CAST(%s AS BINARY))
 AND al.disabled = 0 AND al.lifecycle = 'active'
 AND ah.disabled = 0 AND ah.lifecycle = 'active'
 AND NOT EXISTS (SELECT 1 FROM clrs_staging.chat_members AS extra
 WHERE extra.chat_id = c.chat_id AND CAST(extra.uid AS BINARY)
 NOT IN (CAST(c.uid_low AS BINARY), CAST(c.uid_high AS BINARY)))"""


def chats_query(anchor=None):
    continuation = ""
    if anchor is not None:
        continuation = (" AND c.updated_at IS NULL AND CAST(c.chat_id AS BINARY) > CAST(%s AS BINARY)"
            if anchor[0] is None else """ AND (c.updated_at < CAST(%s AS DATETIME(6))
 OR (c.updated_at = CAST(%s AS DATETIME(6)) AND CAST(c.chat_id AS BINARY) > CAST(%s AS BINARY))
 OR c.updated_at IS NULL)""")
    return f"""SELECT c.chat_id, c.uid_low, c.uid_high,
 DATE_FORMAT(c.updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'), c.last_sequence, c.revision,
 ml.read_through_sequence, mh.read_through_sequence,
 ml.notifications_enabled, mh.notifications_enabled,
 (ml.archived_at IS NOT NULL), (mh.archived_at IS NOT NULL),
 CASE WHEN CAST(c.uid_low AS BINARY) = CAST(%s AS BINARY)
 THEN CASE WHEN CHAR_LENGTH(ph.full_name) <= 1000 AND OCTET_LENGTH(ph.full_name) <= 4000 THEN ph.full_name ELSE NULL END
 ELSE CASE WHEN CHAR_LENGTH(pl.full_name) <= 1000 AND OCTET_LENGTH(pl.full_name) <= 4000 THEN pl.full_name ELSE NULL END END
 FROM clrs_staging.chats AS c {_PAIR_JOINS}
 LEFT JOIN clrs_staging.profiles AS pl ON pl.uid = c.uid_low
 LEFT JOIN clrs_staging.profiles AS ph ON ph.uid = c.uid_high
 WHERE {_OWN_PAIR}{continuation}
 ORDER BY c.updated_at DESC, CAST(c.chat_id AS BINARY) ASC LIMIT %s
 FOR SHARE OF c, ml, mh, al, ah"""


def messages_query(before=False):
    return """SELECT m.chat_id, m.message_id, m.sequence, m.sender_uid,
 CASE WHEN OCTET_LENGTH(m.body) <= 16384 AND CHAR_LENGTH(m.body) <= 4096 THEN m.body ELSE NULL END,
 DATE_FORMAT(m.created_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),
 q.message_id, q.sequence, q.sender_uid,
 CASE WHEN OCTET_LENGTH(q.body) <= 16384 AND CHAR_LENGTH(q.body) <= 4096 THEN q.body ELSE NULL END,
 (m.body IS NULL OR (OCTET_LENGTH(m.body) <= 16384 AND CHAR_LENGTH(m.body) <= 4096)),
 (q.body IS NULL OR (OCTET_LENGTH(q.body) <= 16384 AND CHAR_LENGTH(q.body) <= 4096))
 FROM clrs_staging.chat_messages AS m
 LEFT JOIN clrs_staging.chat_messages AS q ON q.chat_id = m.chat_id
 AND CAST(q.message_id AS BINARY) = CAST(m.reply_to_id AS BINARY) AND q.deleted_at IS NULL
 WHERE CAST(m.chat_id AS BINARY) = CAST(%s AS BINARY) AND m.deleted_at IS NULL""" + (
        " AND m.sequence < %s" if before else "") + " ORDER BY m.sequence DESC LIMIT %s FOR SHARE OF m, q"


EVENTS_QUERY = f"""SELECT e.event_id, e.event_kind,
 CASE WHEN OCTET_LENGTH(CAST(e.payload AS CHAR CHARACTER SET utf8mb4)) <= 8192 THEN e.payload ELSE NULL END,
 DATE_FORMAT(e.created_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),
 c.chat_id, c.uid_low, c.uid_high, c.last_sequence, c.revision
 FROM clrs_staging.user_events AS e JOIN clrs_staging.chats AS c
 ON JSON_TYPE(JSON_EXTRACT(e.payload, '$.chatId')) = 'STRING'
 AND CAST(c.chat_id AS BINARY) = CAST(JSON_UNQUOTE(JSON_EXTRACT(e.payload, '$.chatId')) AS BINARY)
 {_PAIR_JOINS}
 WHERE CAST(e.audience_uid AS BINARY) = CAST(%s AS BINARY)
 AND e.event_id > %s AND e.event_kind IN ('chat.message.created.v1', 'chat.read.updated.v1')
 AND {_OWN_PAIR}
 ORDER BY e.event_id ASC LIMIT %s FOR SHARE OF e, c, ml, mh, al, ah"""


def _number(value, *, minimum=0):
    if type(value) is not int or not minimum <= value <= MAX_INTEGER:
        raise RuntimeUnavailable()
    return value


def _limit(value):
    if type(value) is not int or not 1 <= value <= 100:
        raise RuntimeInvalidRequest()
    return value


def _timestamp(value, *, nullable=False):
    if value is None and nullable:
        return None
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z", value) is None:
        raise RuntimeUnavailable()
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        raise RuntimeUnavailable() from None
    return value


def _text(value, maximum, *, nullable=False):
    if value is None and nullable:
        return None
    if (not isinstance(value, str) or len(value) > maximum or len(value.encode("utf-8", errors="surrogatepass")) > maximum * 4
            or any((ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise RuntimeUnavailable()
    return value


def _id(value):
    try:
        return _identifier(value)
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None


def _pair_values(uid, low, high):
    low, high = _id(low), _id(high)
    if low == high or uid not in (low, high):
        raise RuntimeUnavailable()
    return {low, high}


def _pack(rows, limit, base, converter, continuation_key, continuation):
    """Never cut a body/quote: continuation always follows the last emitted row."""
    page = {**base, "items": [], continuation_key: None}
    for index, row in enumerate(rows[:limit]):
        candidate = {**base, "items": [*page["items"], converter(row)],
            continuation_key: continuation(row) if index + 1 < len(rows) else None}
        if len(canonical_json(candidate, max_bytes=4 * 1024 * 1024)) > MAX_JSON_BYTES:
            if not page["items"]:
                raise RuntimeUnavailable()
            return page
        page = candidate
    return page


class RuntimeReadService:
    def __init__(self, store, cursor_key, *, clock=time.time):
        if store is None or not isinstance(cursor_key, bytes) or len(cursor_key) != 32:
            raise RuntimeUnavailable()
        # Existing deployment key, separate subkey/domain. Legacy cursors/media
        # cannot be adopted as a current-authority discovery cursor.
        self._codec = OpaqueReferences(hmac.digest(cursor_key, b"clrs-runtime-current-read-cursor-v1\0", "sha256"))
        self._store = store; self._clock = clock

    @classmethod
    def from_env(cls, store, env=None):
        env = os.environ if env is None else env
        if (env.get("CLRS_RUNTIME_WRITES_ENABLED") != "1"
                or env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") != "canonical-current-v1"):
            return None
        try:
            return cls(store, decode_base64(env.get("CLRS_LEGACY_READ_CURSOR_KEY_B64"), max_bytes=32))
        except Exception:
            raise RuntimeUnavailable() from None

    def _cursor(self, value, uid, limit):
        if value is None:
            return None
        try:
            opened = self._codec.open("cursor", value)
            if (set(opened) != {"v", "uid", "purpose", "limit", "after", "exp"}
                    or type(opened["v"]) is not int or opened["v"] != 1
                    or opened["uid"] != uid or opened["purpose"] != CHAT_ORDER
                    or type(opened["limit"]) is not int or opened["limit"] != limit
                    or type(opened["exp"]) is not int
                    or not int(self._clock()) < opened["exp"] <= int(self._clock()) + 300
                    or type(opened["after"]) is not list or len(opened["after"]) != 2):
                raise RuntimeInvalidRequest()
            after = opened["after"]
            _timestamp(after[0], nullable=True); _identifier(after[1])
            return after
        except (LegacyInvalid, RuntimeUnavailable, RuntimeInvalidRequest):
            raise RuntimeInvalidRequest() from None

    def _next(self, uid, limit, row):
        return self._codec.seal("cursor", {"v": 1, "uid": uid, "purpose": CHAT_ORDER,
            "limit": limit, "after": [row[3], row[0]], "exp": int(self._clock()) + 300})

    def own_chats(self, identity, *, limit=50, cursor=None, access_token):
        limit = _limit(limit)
        def action(sql_cursor, execute, uid):
            anchor = self._cursor(cursor, uid, limit); parameters = [uid, uid, uid]
            if anchor is not None:
                if anchor[0] is None:
                    parameters.append(anchor[1])
                else:
                    stamp = anchor[0][:-1].replace("T", " ")
                    parameters.extend((stamp, stamp, anchor[1]))
            parameters.append(limit + 1)
            execute(chats_query(anchor), tuple(parameters)); rows = sql_cursor.fetchall()
            if len(rows) > limit + 1:
                raise RuntimeUnavailable()
            def convert(row):
                if not isinstance(row, (tuple, list)) or len(row) != 13:
                    raise RuntimeUnavailable()
                pair = _pair_values(uid, row[1], row[2]); own = 0 if uid == row[1] else 1
                last, revision = _number(row[4]), _number(row[5])
                if any(type(flag) is not int or flag not in (0, 1) for flag in row[8:12]):
                    raise RuntimeUnavailable()
                read = _number(row[6 + own]); _number(row[7 - own])
                if row[6] > last or row[7] > last:
                    raise RuntimeUnavailable()
                return {"chatId": _id(row[0]), "counterpartUid": next(iter(pair - {uid})),
                    "name": _text(row[12], 1000, nullable=True), "avatar": None,
                    "updatedAt": _timestamp(row[3], nullable=True), "lastSequence": last,
                    "revision": revision, "readThrough": read, "archived": bool(row[10 + own]),
                    "notifications": bool(row[8 + own])}
            return _pack(rows, limit, {"kind": "canonical-current", "ordering": CHAT_ORDER},
                         convert, "nextCursor", lambda row: self._next(uid, limit, row))
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def messages(self, identity, chat_id, *, limit=50, before_sequence=None, access_token):
        chat_id = _identifier(chat_id); limit = _limit(limit)
        if before_sequence is not None and (type(before_sequence) is not int or not 1 <= before_sequence <= MAX_INTEGER):
            raise RuntimeInvalidRequest()
        def action(cursor, execute, uid):
            try:
                pair = _pair(cursor, execute, uid, chat_id, readonly=True)
            except _ChatFailure:
                raise RuntimeReadRejected() from None
            parameters = (chat_id, limit + 1) if before_sequence is None else (chat_id, before_sequence, limit + 1)
            execute(messages_query(before_sequence is not None), parameters); rows = cursor.fetchall()
            if len(rows) > limit + 1:
                raise RuntimeUnavailable()
            def convert(row):
                if not isinstance(row, (tuple, list)) or len(row) != 12 or row[0] != chat_id or row[3] not in pair["members"]:
                    raise RuntimeUnavailable()
                sequence = _number(row[2], minimum=1)
                if sequence > pair["sequence"] or row[10] != 1:
                    raise RuntimeUnavailable()
                quote = None
                if row[6] is not None:
                    quoted_sequence = _number(row[7], minimum=1)
                    if row[8] not in pair["members"] or quoted_sequence > pair["sequence"] or row[11] != 1:
                        raise RuntimeUnavailable()
                    quote = {"messageId": _id(row[6]), "sequence": quoted_sequence,
                             "senderUid": _id(row[8]), "text": _text(row[9], 4096, nullable=True)}
                return {"chatId": chat_id, "messageId": _id(row[1]), "sequence": sequence,
                    "senderUid": _id(row[3]), "text": _text(row[4], 4096, nullable=True),
                    "quote": quote, "createdAt": _timestamp(row[5], nullable=True)}
            return _pack(rows, limit, {"kind": "canonical-current", "chatId": chat_id,
                "chatRevision": pair["revision"], "ordering": "sequence_desc"}, convert,
                "nextBeforeSequence", lambda row: row[2])
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def own_events(self, identity, *, limit=50, after_event_id=0, access_token):
        limit = _limit(limit)
        if type(after_event_id) is not int or not 0 <= after_event_id <= MAX_INTEGER:
            raise RuntimeInvalidRequest()
        def action(cursor, execute, uid):
            execute(EVENTS_QUERY, (uid, after_event_id, uid, uid, limit + 1)); rows = cursor.fetchall()
            if len(rows) > limit + 1:
                raise RuntimeUnavailable()
            def convert(row):
                if not isinstance(row, (tuple, list)) or len(row) != 9:
                    raise RuntimeUnavailable()
                pair = _pair_values(uid, row[5], row[6]); last, revision = _number(row[7]), _number(row[8])
                try:
                    payload = unique_json(row[2]) if isinstance(row[2], str) else row[2]
                    if type(payload) is not dict:
                        raise RuntimeUnavailable()
                    descriptor = {"eventId": _number(row[0], minimum=1), "kind": row[1],
                        "chatId": _id(row[4]), "messageId": None, "sequence": None, "senderUid": None,
                        "readerUid": None, "readThroughSequence": None,
                        "chatRevision": _number(payload.get("chatRevision")), "createdAt": _timestamp(row[3])}
                    if payload.get("chatId") != row[4] or descriptor["chatRevision"] > revision:
                        raise RuntimeUnavailable()
                    if row[1] == "chat.message.created.v1":
                        if set(payload) != {"chatId", "messageId", "sequence", "senderUid", "chatRevision", "createdAt"}:
                            raise RuntimeUnavailable()
                        _timestamp(payload["createdAt"])
                        descriptor.update(messageId=_id(payload["messageId"]),
                            sequence=_number(payload["sequence"], minimum=1), senderUid=_id(payload["senderUid"]))
                        if descriptor["senderUid"] not in pair or descriptor["sequence"] > last:
                            raise RuntimeUnavailable()
                    elif row[1] == "chat.read.updated.v1":
                        if set(payload) != {"chatId", "readerUid", "readThroughSequence", "chatRevision"}:
                            raise RuntimeUnavailable()
                        descriptor.update(readerUid=_id(payload["readerUid"]), readThroughSequence=_number(payload["readThroughSequence"]))
                        if descriptor["readerUid"] not in pair or descriptor["readThroughSequence"] > last:
                            raise RuntimeUnavailable()
                    else:
                        raise RuntimeUnavailable()
                    return descriptor
                except RuntimeUnavailable:
                    raise
                except Exception:
                    raise RuntimeUnavailable() from None
            return _pack(rows, limit, {"kind": "canonical-current", "ordering": "event_id_asc"},
                         convert, "nextAfterEventId", lambda row: row[0])
        return self._store.read_authenticated(identity, action, access_token=access_token)
