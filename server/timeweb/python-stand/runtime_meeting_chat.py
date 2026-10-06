"""Member-only native meeting text; no imported authority, quotes or side effects."""
from __future__ import annotations
from datetime import datetime, timezone
import hashlib
import re
import time
from legacy_conversation_payload import LegacyInvalid
from runtime_chat import _integer, _text, _stamp
from runtime_meeting_create import _indexes, _current_profile, MeetingAccessRejected
from runtime_meeting_join import _target, _JoinFailure, DECLARED_ERRORS
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, MAX_INTEGER, canonical_json
from runtime_personal_chat import _uid
from runtime_reads import _timestamp, _pack, RuntimeReadRejected

SEND_OPERATION = "meeting.send-text.v1"
MESSAGE_ORIGIN = "clrs-native-meeting-message-v1"
MESSAGE_ORDER = "sequence_desc"
MESSAGE_KEYS = {"meetingId", "messageId", "sequence", "senderUid", "text", "createdAt"}
_INDEX_PARTS = {("PRIMARY", 0, 1, "meeting_id", "A"), ("PRIMARY", 0, 2, "message_id", "A"),
    ("meeting_messages_sequence_uq", 0, 1, "meeting_id", "A"), ("meeting_messages_sequence_uq", 0, 2, "sequence", "A"),
    ("meeting_messages_page_idx", 1, 1, "meeting_id", "A"), ("meeting_messages_page_idx", 1, 2, "sequence", "D")}
_INDEX = """SELECT s.INDEX_NAME, s.NON_UNIQUE, s.SEQ_IN_INDEX, s.COLUMN_NAME, s.COLLATION,
 s.SUB_PART, c.COLLATION_NAME FROM information_schema.STATISTICS AS s
 JOIN information_schema.COLUMNS AS c ON c.TABLE_SCHEMA = s.TABLE_SCHEMA
 AND c.TABLE_NAME = s.TABLE_NAME AND c.COLUMN_NAME = s.COLUMN_NAME
 WHERE s.TABLE_SCHEMA = 'clrs_staging' AND s.TABLE_NAME = 'meeting_messages'
 AND s.INDEX_NAME IN ('PRIMARY','meeting_messages_sequence_uq','meeting_messages_page_idx')
 ORDER BY s.INDEX_NAME, s.SEQ_IN_INDEX LIMIT 7"""
_SELECT = """SELECT mm.meeting_id, mm.message_id, mm.sequence, mm.sender_uid,
 CASE WHEN CHAR_LENGTH(mm.body) <= 4096 AND OCTET_LENGTH(mm.body) <= 16384 THEN mm.body ELSE NULL END,
 DATE_FORMAT(mm.created_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'), (mm.media_id IS NULL),
 CASE WHEN JSON_TYPE(mm.legacy_raw) = 'OBJECT' AND JSON_LENGTH(mm.legacy_raw) = 1
 AND JSON_TYPE(JSON_EXTRACT(mm.legacy_raw, '$.origin')) = 'STRING'
 AND CAST(JSON_UNQUOTE(JSON_EXTRACT(mm.legacy_raw, '$.origin')) AS BINARY)
 = CAST('clrs-native-meeting-message-v1' AS BINARY) THEN 1 ELSE 0 END
 FROM clrs_staging.meeting_messages AS mm"""


def _message_id(meeting_id, uid, operation_id):
    return "tw-meet-msg-" + hashlib.sha256(b"clrs-native-meeting-message-v1\0" + canonical_json([meeting_id, uid, _uid(operation_id)])).hexdigest()


def _message(value):
    if type(value) is not dict or set(value) != MESSAGE_KEYS:
        raise RuntimeUnavailable()
    try:
        _uid(value["meetingId"]); _uid(value["senderUid"]); _text(value["text"])
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None
    if type(value["messageId"]) is not str or re.fullmatch(r"tw-meet-msg-[0-9a-f]{64}", value["messageId"]) is None:
        raise RuntimeUnavailable()
    if _integer(value["sequence"]) == 0:
        raise RuntimeUnavailable()
    _timestamp(value["createdAt"])
    return value


def _row(source, meeting_id):
    if (not isinstance(source, (tuple, list)) or len(source) != 8
            or source[0] != meeting_id or type(source[6]) is not int or source[6] != 1
            or type(source[7]) is not int or source[7] != 1):
        raise RuntimeUnavailable()
    return _message(dict(zip(("meetingId", "messageId", "sequence", "senderUid", "text", "createdAt"), source[:6])))


def validate_page(value, meeting_id, limit, previous_cursor=None):
    if (type(value) is not dict or set(value) != {"kind","meetingId","chatRevision","ordering","items","nextCursor","mediaReady"}
            or value["kind"] != "canonical-current" or value["meetingId"] != meeting_id
            or value["ordering"] != MESSAGE_ORDER or value["mediaReady"] is not False
            or type(value["items"]) is not list or len(value["items"]) > limit):
        raise RuntimeUnavailable()
    revision = _integer(value["chatRevision"]); previous = MAX_INTEGER + 1
    for item in value["items"]:
        _message(item)
        if item["meetingId"] != meeting_id or not 0 < item["sequence"] < previous or item["sequence"] > revision:
            raise RuntimeUnavailable()
        previous = item["sequence"]
    cursor = value["nextCursor"]
    if cursor is not None and (type(cursor) is not str or re.fullmatch(r"[A-Za-z0-9_-]{1,4096}", cursor) is None
            or cursor == previous_cursor or not value["items"]):
        raise RuntimeUnavailable()
    try:
        canonical_json(value, max_bytes=65536)
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None
    return value


def _message_indexes(cursor, execute):
    execute(_INDEX); indexes = cursor.fetchall()
    if (len(indexes) != 6 or any(not isinstance(row, (tuple, list)) or len(row) != 7
            or type(row[1]) is not int or type(row[2]) is not int or row[5] is not None
            or row[6] != (None if row[3] == "sequence" else "utf8mb4_0900_bin") for row in indexes)
            or {tuple(row[:5]) for row in indexes} != _INDEX_PARTS):
        raise RuntimeUnavailable()


def _state(store, cursor, execute, uid, meeting_id, now, *, readonly):
    if getattr(store, "_env", {}).get("CLRS_RUNTIME_PERMISSION_MODEL") != "provider-database-v1":
        raise RuntimeUnavailable()
    _indexes(cursor, execute); _message_indexes(cursor, execute)
    failure = _current_profile(cursor, execute, uid, {"type": "групповая"}, now)
    if failure: raise _JoinFailure(*failure)
    if _target(cursor, execute, uid, meeting_id, now, readonly=readonly) is None:
        raise _JoinFailure(409, "meeting_unavailable")
    execute("SELECT revision FROM clrs_staging.meetings WHERE meeting_id = %s AND CAST(meeting_id AS BINARY) = CAST(%s AS BINARY) LIMIT 1", (meeting_id, meeting_id))
    row = cursor.fetchone()
    if not isinstance(row, (tuple, list)) or len(row) != 1: raise RuntimeUnavailable()
    revision = _integer(row[0])
    execute(_SELECT + " FORCE INDEX (meeting_messages_page_idx) WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY) ORDER BY mm.sequence DESC LIMIT 1 FOR SHARE OF mm", (meeting_id, meeting_id))
    rows = cursor.fetchall()
    if len(rows) > 1: raise RuntimeUnavailable()
    tail = _row(rows[0], meeting_id)["sequence"] if rows else 0
    if tail > revision: raise RuntimeUnavailable()
    return tail, revision


def _cursor(reader, value, uid, meeting_id, limit, tail, revision):
    now = int(reader._clock())
    if value is None:
        return {"v":1,"uid":uid,"purpose":"meeting_messages_sequence_desc","meetingId":meeting_id,
            "limit":limit,"capSequence":tail,"initialRevision":revision,"after":None,"exp":now+300}
    try:
        if type(value) is not str or not 1 <= len(value) <= 4096: raise RuntimeInvalidRequest()
        claim = reader._codec.open("cursor", value)
        if (set(claim) != {"v","uid","purpose","meetingId","limit","capSequence","initialRevision","after","exp"}
                or type(claim["v"]) is not int or claim["v"] != 1 or claim["uid"] != uid
                or claim["purpose"] != "meeting_messages_sequence_desc" or claim["meetingId"] != meeting_id
                or type(claim["limit"]) is not int or claim["limit"] != limit
                or type(claim["exp"]) is not int or not now < claim["exp"] <= now+300
                or type(claim["capSequence"]) is not int or not 1 <= claim["capSequence"] <= tail
                or type(claim["initialRevision"]) is not int or not claim["capSequence"] <= claim["initialRevision"] <= revision
                or type(claim["after"]) is not int or not 1 <= claim["after"] <= claim["capSequence"]):
            raise RuntimeInvalidRequest()
        return claim
    except LegacyInvalid:
        raise RuntimeInvalidRequest() from None


def read_messages(reader, identity, meeting_id, *, limit=30, cursor=None, access_token):
    meeting_id = _uid(meeting_id)
    if type(limit) is not int or not 1 <= limit <= 30: raise RuntimeInvalidRequest()
    def action(sql_cursor, execute, uid):
        try:
            tail, revision = _state(reader._store, sql_cursor, execute, uid, meeting_id,
                datetime.fromtimestamp(reader._clock(), timezone.utc), readonly=True)
        except _JoinFailure:
            raise RuntimeReadRejected() from None
        claim = _cursor(reader, cursor, uid, meeting_id, limit, tail, revision)
        sql = _SELECT + " FORCE INDEX (meeting_messages_page_idx) WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY) AND mm.sequence <= %s"
        params = [meeting_id, meeting_id, claim["capSequence"]]
        if claim["after"] is not None: sql += " AND mm.sequence < %s"; params.append(claim["after"])
        execute(sql + " ORDER BY mm.sequence DESC LIMIT %s FOR SHARE OF mm", (*params, limit+1))
        rows = sql_cursor.fetchall()
        if len(rows) > limit+1: raise RuntimeUnavailable()
        items = [_row(row, meeting_id) for row in rows]
        previous = claim["after"] or claim["capSequence"]+1
        for item in items:
            if not 0 < item["sequence"] < previous or item["sequence"] > claim["capSequence"]: raise RuntimeUnavailable()
            previous = item["sequence"]
        base = {"kind":"canonical-current","meetingId":meeting_id,"chatRevision":revision,"ordering":MESSAGE_ORDER,"mediaReady":False}
        page = _pack(items, limit, base, lambda item:item, "nextCursor",
            lambda item:reader._codec.seal("cursor", {**claim,"after":item["sequence"]}))
        return validate_page(page, meeting_id, limit, cursor)
    return reader._store.read_authenticated(identity, action, access_token=access_token)


class RuntimeMeetingChatService:
    def __init__(self, store, *, clock=time.time):
        self._store = store; self._clock = clock
        store.register_replay_guard(SEND_OPERATION, self._replay_guard, response_guard=True, operation_id_guard=True)

    def _replay_guard(self, cursor, execute, uid, operation_id, request, response):
        if type(request) is not dict or set(request) != {"meetingId","text"}: raise RuntimeUnavailable()
        meeting_id = _uid(request["meetingId"]); text = _text(request["text"])
        if type(response) is dict and set(response) == {"error"} and response["error"] in DECLARED_ERRORS: return
        if type(response) is not dict or set(response) != MESSAGE_KEYS | {"chatRevision"}: raise RuntimeUnavailable()
        expected = _message_id(meeting_id, uid, operation_id)
        _message({key:response[key] for key in MESSAGE_KEYS}); receipt_revision = _integer(response["chatRevision"])
        if response["meetingId"] != meeting_id or response["messageId"] != expected or response["senderUid"] != uid or response["text"] != text: raise RuntimeUnavailable()
        try:
            tail, revision = _state(self._store, cursor, execute, uid, meeting_id,
                datetime.fromtimestamp(self._clock(), timezone.utc), readonly=True)
            if revision < receipt_revision or not response["sequence"] <= tail: raise RuntimeUnavailable()
            execute(_SELECT + " WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY) AND mm.message_id = %s AND CAST(mm.message_id AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE OF mm", (meeting_id,meeting_id,expected,expected))
            rows = cursor.fetchall()
            if len(rows) != 1 or _row(rows[0],meeting_id) != {key:response[key] for key in MESSAGE_KEYS}: raise RuntimeUnavailable()
        except (_JoinFailure, RuntimeUnavailable):
            raise MeetingAccessRejected() from None

    def send_text(self, identity, meeting_id, operation_id, text, *, access_token):
        meeting_id = _uid(meeting_id); text = _text(text); request = {"meetingId":meeting_id,"text":text}
        def action(cursor, execute, uid):
            try:
                tail, revision = _state(self._store,cursor,execute,uid,meeting_id,
                    datetime.fromtimestamp(self._clock(),timezone.utc),readonly=False)
            except _JoinFailure as error: return error.status,{"error":error.error},None
            if tail == MAX_INTEGER or revision == MAX_INTEGER: raise RuntimeUnavailable()
            sequence = tail+1; revision += 1; created = _stamp(cursor,execute)
            message_id = _message_id(meeting_id,uid,operation_id)
            execute("""INSERT INTO clrs_staging.meeting_messages
 (meeting_id,message_id,sequence,sender_uid,body,media_id,created_at,legacy_raw)
 VALUES (%s,%s,%s,%s,%s,NULL,%s,%s)""", (meeting_id,message_id,sequence,uid,text,created[:-1].replace("T"," "),canonical_json({"origin":MESSAGE_ORIGIN}).decode()))
            if cursor.rowcount != 1: raise RuntimeUnavailable()
            execute("UPDATE clrs_staging.meetings SET revision = %s, updated_at = %s WHERE meeting_id = %s AND CAST(meeting_id AS BINARY) = CAST(%s AS BINARY) AND revision = %s", (revision,created[:-1].replace("T"," "),meeting_id,meeting_id,revision-1))
            if cursor.rowcount != 1: raise RuntimeUnavailable()
            return 201,{"meetingId":meeting_id,"messageId":message_id,"sequence":sequence,
                "senderUid":uid,"text":text,"createdAt":created,"chatRevision":revision},revision
        return self._store.mutate(identity,SEND_OPERATION,operation_id,request,action,access_token=access_token)
