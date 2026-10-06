"""Native text/quote and read-receipt transactions on current canonical chats.

The authority flag is a deliberate final-delta/cutover gate. Neither imported
raw documents nor archived UI state are interpreted as current revocation.
"""
from __future__ import annotations

from datetime import datetime
import hashlib
import re

from runtime_mutations import (RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable,
                              MAX_INTEGER, canonical_json)


SEND_OPERATION = "chat.send-text.v1"
READ_OPERATION = "chat.mark-read.v1"
CHAT_QUERY = """SELECT chat_id, uid_low, uid_high, last_sequence, revision
 FROM clrs_staging.chats WHERE chat_id = %s LIMIT 1"""
MEMBERS_QUERY = """SELECT uid, read_through_sequence, notifications_enabled
 FROM clrs_staging.chat_members WHERE chat_id = %s ORDER BY BINARY uid LIMIT 3"""
ACCOUNT_QUERY = """SELECT uid, disabled, lifecycle FROM clrs_staging.accounts
 WHERE uid = %s LIMIT 1 FOR SHARE"""
QUOTE_QUERY = """SELECT message_id, sequence, sender_uid, body, deleted_at
 FROM clrs_staging.chat_messages WHERE chat_id = %s AND message_id = %s LIMIT 1 FOR SHARE"""


def _identifier(value):
    if (not isinstance(value, str) or not 1 <= len(value) <= 191
            or any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise RuntimeInvalidRequest()
    if len(value.encode("utf-8")) > 764:
        raise RuntimeInvalidRequest()
    return value


def _text(value, *, nullable=False):
    if nullable and value is None:
        return None
    if (not isinstance(value, str) or not 1 <= len(value) <= 4096 or not value.strip()
            or any((ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127
                   or 0xD800 <= ord(c) <= 0xDFFF for c in value)
            or len(value.encode("utf-8")) > 16384):
        raise RuntimeInvalidRequest()
    return value


def _integer(value):
    if type(value) is not int or not 0 <= value <= MAX_INTEGER:
        raise RuntimeUnavailable()
    return value


class _ChatFailure(Exception):
    def __init__(self, status, code):
        self.status = status; self.code = code


def _pair(cursor, execute, uid, chat_id, *, readonly=False):
    # All write operations lock receipt -> chat -> two membership rows ->
    # accounts in exact UTF-8 order -> event counter. Concurrent pair sends
    # serialize on the chat row while shared session/account locks coexist.
    lock = " FOR SHARE" if readonly else " FOR UPDATE"
    execute(CHAT_QUERY + lock, (chat_id,)); chat = cursor.fetchone()
    if chat is None:
        raise _ChatFailure(404, "chat_not_found")
    if not isinstance(chat, (tuple, list)) or len(chat) != 5:
        raise RuntimeUnavailable()
    if chat[0] != chat_id:
        raise RuntimeUnavailable()
    try:
        low, high = _identifier(chat[1]), _identifier(chat[2])
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None
    if low == high or uid not in (low, high):
        raise _ChatFailure(404, "chat_not_found")
    sequence, revision = _integer(chat[3]), _integer(chat[4])
    execute(MEMBERS_QUERY + lock, (chat_id,)); rows = cursor.fetchall()
    if len(rows) != 2 or {row[0] for row in rows if isinstance(row, (tuple, list)) and len(row) == 3} != {low, high}:
        raise _ChatFailure(409, "chat_unavailable")
    members = {}
    for row in rows:
        if (not isinstance(row, (tuple, list)) or len(row) != 3
                or type(row[2]) is not int or row[2] not in (0, 1)):
            raise RuntimeUnavailable()
        members[row[0]] = {"read": _integer(row[1]), "notifications": bool(row[2])}
        if members[row[0]]["read"] > sequence:
            raise RuntimeUnavailable()
    for member in sorted((low, high), key=lambda item: item.encode("utf-8")):
        execute(ACCOUNT_QUERY, (member,)); account = cursor.fetchone()
        if account is None or not isinstance(account, (tuple, list)) or len(account) != 3:
            raise _ChatFailure(409, "chat_unavailable")
        if account[0] != member or type(account[1]) is not int or account[1] not in (0, 1) or account[2] not in {"active", "blocked", "deleted"}:
            raise RuntimeUnavailable()
        if account[1] != 0 or account[2] != "active":
            raise _ChatFailure(409, "chat_unavailable")
    return {"peer": high if uid == low else low, "members": members,
            "sequence": sequence, "revision": revision}


def _events(cursor, execute, audiences, kind, payload):
    execute("SELECT last_id FROM clrs_staging.event_counter WHERE singleton = 1 FOR UPDATE")
    counter = cursor.fetchone()
    if not isinstance(counter, (tuple, list)) or len(counter) != 1:
        raise RuntimeUnavailable()
    previous = _integer(counter[0])
    if previous > MAX_INTEGER - len(audiences):
        raise RuntimeUnavailable()
    execute("UPDATE clrs_staging.event_counter SET last_id = %s WHERE singleton = 1 AND last_id = %s",
            (previous + len(audiences), previous))
    if cursor.rowcount != 1:
        raise RuntimeUnavailable()
    ids = []
    for offset, audience in enumerate(audiences, 1):
        event = previous + offset
        execute("""INSERT INTO clrs_staging.user_events (event_id, audience_uid, event_kind, payload)
 VALUES (%s, %s, %s, %s)""", (event, audience, kind, canonical_json(payload).decode()))
        if cursor.rowcount != 1:
            raise RuntimeUnavailable()
        ids.append(event)
    return ids


def _stamp(cursor, execute):
    execute("SELECT DATE_FORMAT(UTC_TIMESTAMP(6), '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')")
    row = cursor.fetchone()
    if not isinstance(row, (tuple, list)) or len(row) != 1 or not isinstance(row[0], str) or re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z", row[0]) is None:
        raise RuntimeUnavailable()
    try:
        datetime.strptime(row[0], "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        raise RuntimeUnavailable() from None
    return row[0]


class RuntimeChatService:
    def __init__(self, store):
        if store is None:
            raise RuntimeUnavailable()
        self._store = store
        store.register_replay_guard(SEND_OPERATION, self._replay_guard)
        store.register_replay_guard(READ_OPERATION, self._replay_guard)

    @staticmethod
    def _replay_guard(cursor, execute, uid, request):
        if type(request) is not dict or "chatId" not in request:
            raise RuntimeUnavailable()
        try:
            _pair(cursor, execute, uid, _identifier(request["chatId"]), readonly=True)
        except _ChatFailure:
            # Do not return saved text to a now-removed member or while either
            # participant is blocked. There is no stale receipt access bypass.
            raise RuntimeRejected() from None

    def send_text(self, identity, chat_id, operation_id, text, *, quote_message_id=None, access_token):
        chat_id = _identifier(chat_id); text = _text(text)
        if quote_message_id is not None:
            quote_message_id = _identifier(quote_message_id)
        request = {"chatId": chat_id, "text": text, "quoteMessageId": quote_message_id}
        def action(cursor, execute, uid):
            try:
                pair = _pair(cursor, execute, uid, chat_id)
                quote = None
                if quote_message_id is not None:
                    execute(QUOTE_QUERY, (chat_id, quote_message_id)); row = cursor.fetchone()
                    if row is None or not isinstance(row, (tuple, list)) or len(row) != 5:
                        raise _ChatFailure(409, "quote_unavailable")
                    if row[0] != quote_message_id or row[2] not in pair["members"] or row[4] is not None:
                        raise _ChatFailure(409, "quote_unavailable")
                    sequence = _integer(row[1])
                    if not 0 < sequence <= pair["sequence"]:
                        raise RuntimeUnavailable()
                    try:
                        quote_text = _text(row[3], nullable=True)
                    except RuntimeInvalidRequest:
                        raise _ChatFailure(409, "quote_unavailable") from None
                    quote = {"messageId": quote_message_id, "sequence": sequence,
                             "senderUid": row[2], "text": quote_text}
            except _ChatFailure as error:
                return error.status, {"error": error.code}, None
            if pair["sequence"] == MAX_INTEGER or pair["revision"] == MAX_INTEGER:
                raise RuntimeUnavailable()
            sequence, revision = pair["sequence"] + 1, pair["revision"] + 1
            created = _stamp(cursor, execute)
            sql_created = created[:-1].replace("T", " ")
            message_id = "tw-" + hashlib.sha256(canonical_json([uid, operation_id])).hexdigest()
            execute("""INSERT INTO clrs_staging.chat_messages
 (chat_id, message_id, sequence, sender_uid, body, reply_to_id, created_at, legacy_raw)
 VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""",
                (chat_id, message_id, sequence, uid, text, quote_message_id, sql_created,
                 canonical_json({"runtime": {"version": 1, "quote": quote}}).decode()))
            if cursor.rowcount != 1:
                raise RuntimeUnavailable()
            execute("""UPDATE clrs_staging.chats SET last_sequence = %s, revision = %s,
 updated_at = %s WHERE chat_id = %s AND last_sequence = %s AND revision = %s""",
                (sequence, revision, sql_created, chat_id, pair["sequence"], pair["revision"]))
            if cursor.rowcount != 1:
                raise RuntimeUnavailable()
            event_payload = {"chatId": chat_id, "messageId": message_id, "sequence": sequence,
                             "senderUid": uid, "chatRevision": revision, "createdAt": created}
            events = _events(cursor, execute, (uid, pair["peer"]), "chat.message.created.v1", event_payload)
            if pair["members"][pair["peer"]]["notifications"]:
                source_id = str(events[1])
                outbox_id = "tw-" + hashlib.sha256(canonical_json(["fcm", pair["peer"], source_id])).hexdigest()
                execute("""INSERT INTO clrs_staging.outbox
 (outbox_id, source_event_id, audience_uid, channel, event_kind, payload)
 VALUES (%s, %s, %s, 'fcm', 'chat.message.created.v1', %s)""",
                    (outbox_id, source_id, pair["peer"], canonical_json(event_payload).decode()))
                if cursor.rowcount != 1:
                    raise RuntimeUnavailable()
            return 201, {"chatId": chat_id, "messageId": message_id, "sequence": sequence,
                "senderUid": uid, "text": text, "quote": quote, "createdAt": created,
                "chatRevision": revision, "eventIds": events}, revision
        return self._store.mutate(identity, SEND_OPERATION, operation_id, request, action, access_token=access_token)

    def mark_read(self, identity, chat_id, operation_id, through_sequence, *, access_token):
        chat_id = _identifier(chat_id)
        if type(through_sequence) is not int or not 0 <= through_sequence <= MAX_INTEGER:
            raise RuntimeInvalidRequest()
        request = {"chatId": chat_id, "throughSequence": through_sequence}
        def action(cursor, execute, uid):
            try:
                pair = _pair(cursor, execute, uid, chat_id)
                if through_sequence > pair["sequence"]:
                    raise _ChatFailure(409, "sequence_ahead")
            except _ChatFailure as error:
                return error.status, {"error": error.code}, None
            previous = pair["members"][uid]["read"]
            changed = through_sequence > previous; events = []; revision = pair["revision"]
            if changed:
                if revision == MAX_INTEGER:
                    raise RuntimeUnavailable()
                revision += 1
                execute("""UPDATE clrs_staging.chat_members SET read_through_sequence = %s
 WHERE chat_id = %s AND uid = %s AND read_through_sequence = %s""",
                        (through_sequence, chat_id, uid, previous))
                if cursor.rowcount != 1:
                    raise RuntimeUnavailable()
                # A read receipt must not move the chat to the top as if a new
                # conversation happened. Preserve chats.updated_at exactly.
                execute("UPDATE clrs_staging.chats SET revision = %s WHERE chat_id = %s AND revision = %s",
                        (revision, chat_id, pair["revision"]))
                if cursor.rowcount != 1:
                    raise RuntimeUnavailable()
                events = _events(cursor, execute, (uid, pair["peer"]), "chat.read.updated.v1",
                    {"chatId": chat_id, "readerUid": uid, "readThroughSequence": through_sequence,
                     "chatRevision": revision})
            return 200, {"chatId": chat_id, "readThroughSequence": max(previous, through_sequence),
                         "changed": changed, "chatRevision": revision, "eventIds": events}, revision
        return self._store.mutate(identity, READ_OPERATION, operation_id, request, action, access_token=access_token)
