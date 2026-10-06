"""One server-owned native meeting creation; no imported-origin inference.

The existing store owns current-session checks, transaction, receipt and unknown
commit lookup. Local wall-clock text is retained without assigning a timezone.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import re
import time

from runtime_chat import _integer, _stamp
from runtime_geography import resolve_geography
from runtime_mutations import (RuntimeInvalidRequest, RuntimeRejected,
                               RuntimeUnavailable, canonical_json)
from runtime_personal_chat import _uid, _raw, _visible_pair, _PersonalFailure
from runtime_profile import _FULL_SELECT, _full_profile, _full_onboarding
from runtime_reads import _text


CREATE_OPERATION = "meeting.create.v1"
MEETING_ORIGIN = "clrs-native-meeting-v1"
MEMBER_ORIGIN = "clrs-native-meeting-member-v1"
_FIELDS = {"name", "description", "countryCode", "region", "datetime", "type"}
_COLUMNS = ("meetingId", "organizerUid", "invitedUid", "kind", "title",
    "description", "countryCode", "region", "startsAt", "createdAt", "updatedAt",
    "revision", "deletedAt", "requestId", "raw")
_SELECT = """SELECT meeting_id, organizer_uid, invited_uid, kind,
 CASE WHEN CHAR_LENGTH(title) <= 1000 AND OCTET_LENGTH(title) <= 4000 THEN title ELSE NULL END,
 CASE WHEN CHAR_LENGTH(description) <= 4096 AND OCTET_LENGTH(description) <= 16384 THEN description ELSE NULL END,
 country_code, region, DATE_FORMAT(starts_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),
 DATE_FORMAT(created_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),
 DATE_FORMAT(updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'), revision,
 DATE_FORMAT(deleted_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'), creation_request_id,
 CASE WHEN OCTET_LENGTH(CAST(legacy_raw AS CHAR CHARACTER SET utf8mb4)) <= 128
 THEN legacy_raw ELSE NULL END FROM clrs_staging.meetings
 WHERE meeting_id = %s AND CAST(meeting_id AS BINARY) = CAST(%s AS BINARY) LIMIT 1"""
_MEMBER = """SELECT uid, joined_at, left_at, kicked_at, membership_revision,
 CASE WHEN OCTET_LENGTH(CAST(legacy_raw AS CHAR CHARACTER SET utf8mb4)) <= 128
 THEN legacy_raw ELSE NULL END FROM clrs_staging.meeting_members
 WHERE meeting_id = %s AND CAST(meeting_id AS BINARY) = CAST(%s AS BINARY)
 AND uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1"""
_INDEX = """SELECT s.TABLE_NAME, s.INDEX_NAME, s.NON_UNIQUE, s.SEQ_IN_INDEX,
 s.COLUMN_NAME, s.SUB_PART, c.COLLATION_NAME FROM information_schema.STATISTICS AS s
 JOIN information_schema.COLUMNS AS c ON c.TABLE_SCHEMA = s.TABLE_SCHEMA
 AND c.TABLE_NAME = s.TABLE_NAME AND c.COLUMN_NAME = s.COLUMN_NAME
 WHERE s.TABLE_SCHEMA = 'clrs_staging' AND
 ((s.TABLE_NAME = 'meetings' AND s.INDEX_NAME IN ('PRIMARY', 'meetings_creation_request_uq'))
 OR (s.TABLE_NAME = 'meeting_members' AND s.INDEX_NAME = 'PRIMARY'))
 ORDER BY s.TABLE_NAME, s.INDEX_NAME, s.SEQ_IN_INDEX LIMIT 6"""
_INDEX_PARTS = {("meetings", "PRIMARY", 1, "meeting_id"),
    ("meetings", "meetings_creation_request_uq", 1, "organizer_uid"),
    ("meetings", "meetings_creation_request_uq", 2, "creation_request_id"),
    ("meeting_members", "PRIMARY", 1, "meeting_id"), ("meeting_members", "PRIMARY", 2, "uid")}


def local_datetime(value):
    """Exact current MeetingForm output, never a UTC conversion or chronology."""
    if type(value) is not str or re.fullmatch(r"[0-9]{2}\.[0-9]{2}\.[0-9]{4} [0-9]{2}:[0-9]{2}", value) is None:
        raise RuntimeInvalidRequest()
    try:
        datetime(int(value[6:10]), int(value[3:5]), int(value[:2]), int(value[11:13]), int(value[14:]))
    except ValueError:
        raise RuntimeInvalidRequest() from None
    return value


def member_archive_window(raw, revision, joined_at, now_stamp):
    """Only the two reviewed server forms; no source/raw-origin guessing."""
    if raw == {"origin": MEMBER_ORIGIN}:
        return None
    if type(raw) is not dict or set(raw) != {"origin", "archiveWindow"} or raw["origin"] != MEMBER_ORIGIN:
        raise RuntimeUnavailable()
    window = raw["archiveWindow"]
    if type(window) is not dict or set(window) != {"throughSequence", "capturedAt", "operationId", "membershipRevision"}:
        raise RuntimeUnavailable()
    _integer(window["throughSequence"]); _integer(window["membershipRevision"]); _integer(revision)
    if (not 1 <= window["membershipRevision"] <= revision or type(window["operationId"]) is not str
            or re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", window["operationId"]) is None):
        raise RuntimeUnavailable()
    captured = window["capturedAt"]
    if type(captured) is not str or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z", captured) is None:
        raise RuntimeUnavailable()
    try:
        parsed = datetime.strptime(captured, "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        raise RuntimeUnavailable() from None
    if parsed.year < 1 or type(joined_at) is not str or not joined_at <= captured <= now_stamp:
        raise RuntimeUnavailable()
    return window


def native_origin_sql(alias, *, member=False):
    """Exact server-built flat forms; original typed imports and {} never match."""
    origin = MEMBER_ORIGIN if member else MEETING_ORIGIN
    raw = alias + ".legacy_raw"
    parts = [f"JSON_TYPE({raw}) = 'OBJECT'",
        f"JSON_TYPE(JSON_EXTRACT({raw}, '$.origin')) = 'STRING'",
        f"CAST(JSON_UNQUOTE(JSON_EXTRACT({raw}, '$.origin')) AS BINARY) = CAST('{origin}' AS BINARY)"]
    if member:
        window = f"JSON_EXTRACT({raw}, '$.archiveWindow')"
        extract = lambda key: f"JSON_EXTRACT({window}, '$.{key}')"
        stamp = f"JSON_UNQUOTE({extract('capturedAt')})"
        date_format = "'%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'"
        bounds = [f"JSON_LENGTH({raw}) = 2", f"JSON_TYPE({window}) = 'OBJECT'", f"JSON_LENGTH({window}) = 4"]
        for key, minimum, maximum in (("throughSequence", 0, str(2**63-1)), ("membershipRevision", 1, f"{alias}.membership_revision")):
            value = extract(key)
            bounds += [f"JSON_TYPE({value}) = 'INTEGER'", f"CAST(JSON_UNQUOTE({value}) AS DECIMAL(20,0)) BETWEEN {minimum} AND {maximum}"]
        operation = extract('operationId')
        bounds += [f"JSON_TYPE({operation}) = 'STRING'", f"OCTET_LENGTH(JSON_UNQUOTE({operation})) = 36",
            f"REGEXP_LIKE(JSON_UNQUOTE({operation}), '^[0-9a-f]{{8}}-[0-9a-f]{{4}}-[1-8][0-9a-f]{{3}}-[89ab][0-9a-f]{{3}}-[0-9a-f]{{12}}$', 'c')",
            f"JSON_TYPE({extract('capturedAt')}) = 'STRING'", f"OCTET_LENGTH({stamp}) = 27",
            f"REGEXP_LIKE({stamp}, '^[0-9]{{4}}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9].[0-9]{{6}}Z$', 'c')",
            f"SUBSTRING({stamp}, 20, 1) = '.'",
            f"CAST(SUBSTRING({stamp}, 9, 2) AS UNSIGNED) <= DAYOFMONTH(LAST_DAY(CONCAT(SUBSTRING({stamp}, 1, 7), '-01')))",
            f"{alias}.joined_at IS NOT NULL", f"CAST({stamp} AS BINARY) >= CAST(DATE_FORMAT({alias}.joined_at, {date_format}) AS BINARY)",
            f"CAST({stamp} AS BINARY) <= CAST(DATE_FORMAT(UTC_TIMESTAMP(6), {date_format}) AS BINARY)"]
        parts.append(f"(JSON_LENGTH({raw}) = 1 OR (" + " AND ".join(bounds) + "))")
    else:
        parts.append(f"JSON_LENGTH({raw}) = 2")
    if not member:
        date = f"JSON_EXTRACT({raw}, '$.localDatetime')"
        parts += [f"JSON_TYPE({date}) = 'STRING'", f"OCTET_LENGTH(JSON_UNQUOTE({date})) = 16", f"{alias}.starts_at IS NULL"]
    return "CASE WHEN " + " AND ".join(parts) + " THEN 1 ELSE 0 END"


def validate_creation(payload):
    if type(payload) is not dict or payload.get("type") not in ("групповая", "индивидуальная"):
        raise RuntimeInvalidRequest()
    individual = payload["type"] == "индивидуальная"
    if set(payload) != (_FIELDS | ({"invitedUid"} if individual else set())):
        raise RuntimeInvalidRequest()
    try:
        for name, maximum in (("name", 1000), ("description", 4096)):
            _text(payload[name], maximum)
    except RuntimeUnavailable:
        raise RuntimeInvalidRequest() from None
    if not payload["name"].strip():
        raise RuntimeInvalidRequest()
    local_datetime(payload["datetime"])
    resolve_geography({key: payload[key] for key in ("countryCode", "region")})
    if individual:
        _uid(payload["invitedUid"])
    return {**payload}


def _indexes(cursor, execute):
    execute(_INDEX); rows = cursor.fetchall()
    if len(rows) != len(_INDEX_PARTS) or any(not isinstance(row, (tuple, list)) or len(row) != 7
            or type(row[2]) is not int or row[2] != 0 or type(row[3]) is not int
            or row[5] is not None or row[6] != "utf8mb4_0900_bin" for row in rows):
        raise RuntimeUnavailable()
    if {(row[0], row[1], row[3], row[4]) for row in rows} != _INDEX_PARTS:
        raise RuntimeUnavailable()


def _current_profile(cursor, execute, uid, request, now):
    execute(_FULL_SELECT, (uid, uid)); row = cursor.fetchone()
    if row is None:
        return 404, "profile_not_found"
    if _full_onboarding(_full_profile(row)) != "search":
        return 409, "profile_not_ready"
    if request["type"] == "индивидуальная":
        peer = request["invitedUid"]
        if peer == uid:
            raise RuntimeInvalidRequest()
        try:
            _visible_pair(cursor, execute, *sorted((uid, peer), key=lambda value: value.encode()), now)
        except _PersonalFailure:
            return 404, "person_unavailable"
    return None


def _meeting(cursor, execute, meeting_id, *, readonly=False):
    execute(_SELECT + (" FOR SHARE" if readonly else " FOR UPDATE"), (meeting_id, meeting_id))
    row = cursor.fetchone()
    if row is None:
        return None
    if not isinstance(row, (tuple, list)) or len(row) != len(_COLUMNS):
        raise RuntimeUnavailable()
    return dict(zip(_COLUMNS, row))


def _check(cursor, execute, uid, request, row, operation_id, *, readonly=False):
    try:
        expected = {"organizerUid": uid, "invitedUid": request.get("invitedUid"),
            "kind": "individual" if "invitedUid" in request else "group", "title": request["name"],
            "description": request["description"], "countryCode": request["countryCode"],
            "region": request["region"], "startsAt": None, "deletedAt": None, "requestId": operation_id}
        if (row is None or any(row[key] != value for key, value in expected.items())
                or _raw(row["raw"]) != {"origin": MEETING_ORIGIN, "localDatetime": request["datetime"]}
                or row["meetingId"] != _meeting_id(uid, operation_id)):
            raise RuntimeUnavailable()
        _integer(row["revision"])
        execute(_MEMBER + (" FOR SHARE" if readonly else " FOR UPDATE"),
                (row["meetingId"], row["meetingId"], uid, uid))
        member = cursor.fetchone()
        if (not isinstance(member, (tuple, list)) or len(member) != 6 or member[0] != uid
                or member[1] is None or member[2] is not None or member[3] is not None
                or type(_raw(member[5])) is not dict):
            raise RuntimeUnavailable()
        _integer(member[4])
        raw_member = _raw(member[5])
        if raw_member != {"origin": MEMBER_ORIGIN}:
            member_archive_window(raw_member, member[4], member[1], _stamp(cursor, execute))
    except _PersonalFailure:
        raise RuntimeUnavailable() from None


def _meeting_id(uid, operation_id):
    return "tw-meeting-" + hashlib.sha256(b"clrs-native-meeting-v1\0" + canonical_json([uid, _uid(operation_id)])).hexdigest()


class MeetingAccessRejected(RuntimeRejected):
    """Target receipt denied while the current native session remains healthy."""


class RuntimeMeetingCreateService:
    def __init__(self, store, *, clock=time.time):
        self._store = store; self._clock = clock
        self._allow_create = getattr(store, "_env", {}).get("CLRS_RUNTIME_PERMISSION_MODEL") == "provider-database-v1"
        store.register_replay_guard(CREATE_OPERATION, self._replay_guard, response_guard=True, operation_id_guard=True)

    def _replay_guard(self, cursor, execute, uid, operation_id, request, response):
        request = validate_creation(request)
        if type(response) is dict and set(response) == {"error"}:
            if response["error"] in {"profile_not_found", "profile_not_ready", "person_unavailable"}:
                return
        if (type(response) is not dict or set(response) != {"meetingId", "created", "meetingRevision", "localDatetime"}
                or response["created"] is not True or type(response["meetingRevision"]) is not int
                or response["meetingRevision"] != 0 or response["localDatetime"] != request["datetime"]
                or response["meetingId"] != _meeting_id(uid, operation_id)):
            raise RuntimeUnavailable()
        try:
            _indexes(cursor, execute)
            if _current_profile(cursor, execute, uid, request, datetime.fromtimestamp(self._clock(), timezone.utc)):
                raise RuntimeUnavailable()
            _check(cursor, execute, uid, request, _meeting(cursor, execute, _uid(response["meetingId"]), readonly=True), operation_id, readonly=True)
        except RuntimeUnavailable:
            raise MeetingAccessRejected() from None

    def create(self, identity, operation_id, payload, *, access_token):
        request = validate_creation(payload)
        def action(cursor, execute, uid):
            if not self._allow_create:
                raise RuntimeUnavailable()
            failure = _current_profile(cursor, execute, uid, request, datetime.fromtimestamp(self._clock(), timezone.utc))
            if failure:
                return failure[0], {"error": failure[1]}, None
            meeting_id = _meeting_id(uid, operation_id)
            if _meeting(cursor, execute, meeting_id) is not None:
                raise RuntimeUnavailable()
            _indexes(cursor, execute)
            stamp = _stamp(cursor, execute); sql_stamp = stamp[:-1].replace("T", " ")
            raw = canonical_json({"origin": MEETING_ORIGIN, "localDatetime": request["datetime"]}).decode()
            execute("""INSERT INTO clrs_staging.meetings
 (meeting_id, organizer_uid, invited_uid, kind, title, description, country_code,
 region, starts_at, created_at, updated_at, creation_request_id, revision, legacy_raw)
 VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NULL, %s, %s, %s, 0, %s)""",
                (meeting_id, uid, request.get("invitedUid"), "individual" if "invitedUid" in request else "group",
                 request["name"], request["description"], request["countryCode"], request["region"],
                 sql_stamp, sql_stamp, operation_id, raw))
            if cursor.rowcount != 1:
                raise RuntimeUnavailable()
            execute("""INSERT INTO clrs_staging.meeting_members
 (meeting_id, uid, joined_at, left_at, kicked_at, membership_revision, legacy_raw)
 VALUES (%s, %s, %s, NULL, NULL, 0, %s)""", (meeting_id, uid, sql_stamp,
                canonical_json({"origin": MEMBER_ORIGIN}).decode()))
            if cursor.rowcount != 1:
                raise RuntimeUnavailable()
            row = _meeting(cursor, execute, meeting_id); _check(cursor, execute, uid, request, row, operation_id)
            if row["createdAt"] != stamp or row["updatedAt"] != stamp or row["revision"] != 0:
                raise RuntimeUnavailable()
            return 201, {"meetingId": meeting_id, "created": True, "meetingRevision": 0,
                         "localDatetime": request["datetime"]}, 0
        return self._store.mutate(identity, CREATE_OPERATION, operation_id, request, action, access_token=access_token)
