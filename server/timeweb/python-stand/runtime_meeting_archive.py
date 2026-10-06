"""Owner-only immutable native history capped by an atomic voluntary exit.

No retroactive time cutoff, imported rows, cloning or live-access capability.
"""
from __future__ import annotations

import json
import re

from legacy_own_profile import LegacyInvalid
from runtime_chat import _integer, _stamp
from runtime_meeting_create import MEMBER_ORIGIN, _indexes, member_archive_window
from runtime_meeting_membership import _meeting, _affected, _MembershipFailure, _utc
from runtime_meeting_chat import _message_indexes, _SELECT, _row, _message, MESSAGE_ORDER
from runtime_mutations import (RuntimeInvalidRequest, RuntimeUnavailable, RECEIPT_QUERY,
    request_digest, canonical_json)
from runtime_people import _uid
from runtime_reads import RuntimeReadRejected, _pack


_WINDOW_SELECT = """SELECT DATE_FORMAT(mm.joined_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),
 mm.membership_revision, CASE WHEN OCTET_LENGTH(CAST(JSON_EXTRACT(mm.legacy_raw, '$.archiveWindow') AS CHAR CHARACTER SET utf8mb4)) <= 512
 THEN JSON_EXTRACT(mm.legacy_raw, '$.archiveWindow') ELSE NULL END
 FROM clrs_staging.meeting_members AS mm WHERE mm.meeting_id = %s
 AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY) AND mm.uid = %s
 AND CAST(mm.uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE OF mm"""


def capture_window(cursor, execute, member, operation_id, revision, stamp):
    _message_indexes(cursor, execute)
    execute(_SELECT + " FORCE INDEX (meeting_messages_page_idx) WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY) ORDER BY mm.sequence DESC LIMIT 1 FOR SHARE OF mm",
        (member["meetingId"], member["meetingId"]))
    rows = cursor.fetchall()
    if len(rows) > 1:
        raise RuntimeUnavailable()
    cap = _row(rows[0], member["meetingId"])["sequence"] if rows else 0
    marker = {"origin": MEMBER_ORIGIN, "archiveWindow": {"throughSequence": cap,
        "capturedAt": stamp, "operationId": operation_id, "membershipRevision": revision}}
    member_archive_window(marker, revision, member["joinedAt"], stamp)
    return marker


def _owner_profile(cursor, execute, uid):
    # Existence, not current search visibility or active meeting membership.
    execute("SELECT p.uid FROM clrs_staging.profiles AS p WHERE p.uid = %s AND CAST(p.uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE OF p", (uid, uid))
    rows = cursor.fetchall()
    if len(rows) > 1 or rows and rows[0] != (uid,):
        raise RuntimeUnavailable()
    if not rows:
        raise RuntimeReadRejected()


def _window(reader, cursor, execute, uid, meeting_id):
    if getattr(reader._store, "_env", {}).get("CLRS_RUNTIME_PERMISSION_MODEL") != "provider-database-v1":
        raise RuntimeUnavailable()
    _indexes(cursor, execute); _message_indexes(cursor, execute)
    _owner_profile(cursor, execute, uid)
    try:
        _meeting(cursor, execute, meeting_id, readonly=True)
    except _MembershipFailure:
        raise RuntimeReadRejected() from None
    member = _affected(cursor, execute, meeting_id, uid, readonly=True)
    if member is None:
        raise RuntimeReadRejected()
    execute(_WINDOW_SELECT, (meeting_id, meeting_id, uid, uid)); rows = cursor.fetchall()
    if len(rows) != 1 or not isinstance(rows[0], (tuple, list)) or len(rows[0]) != 3:
        raise RuntimeUnavailable()
    joined, revision, raw = rows[0]
    if joined != member["joinedAt"] or revision != member["membershipRevision"]:
        raise RuntimeUnavailable()
    if raw is None:
        raise RuntimeReadRejected()
    try:
        window = json.loads(raw) if type(raw) is str else raw
    except ValueError:
        raise RuntimeUnavailable() from None
    window = member_archive_window({"origin": MEMBER_ORIGIN, "archiveWindow": window},
        revision, joined, _stamp(cursor, execute))
    # A marker alone is insufficient: prove its exact original owner action.
    digest = request_digest({"meetingId": meeting_id})
    execute(RECEIPT_QUERY + " FOR SHARE", (uid, "meeting.leave.v1", window["operationId"]))
    retained = cursor.fetchone()
    if retained is None:
        raise RuntimeReadRejected()
    status, wrapper, entity = reader._store._receipt(retained, digest)
    expected = {"meetingId": meeting_id, "left": True, "alreadyLeft": False,
        "membershipRevision": window["membershipRevision"], "leftAt": window["capturedAt"]}
    if (status != 200 or wrapper["request"] != {"meetingId": meeting_id}
            or wrapper["response"] != expected or entity != window["membershipRevision"]):
        raise RuntimeReadRejected()
    return window


def _cursor(reader, token, uid, meeting_id, limit, window):
    now = int(reader._clock())
    if token is None:
        return {"v": 1, "uid": uid, "purpose": "meeting_archive_sequence_desc", "meetingId": meeting_id,
            "limit": limit, "window": window, "after": None, "exp": now + 300}
    try:
        if type(token) is not str or not 1 <= len(token) <= 4096:
            raise RuntimeInvalidRequest()
        claim = reader._codec.open("cursor", token)
        if (set(claim) != {"v", "uid", "purpose", "meetingId", "limit", "window", "after", "exp"}
                or type(claim["v"]) is not int or claim["v"] != 1 or claim["uid"] != uid
                or claim["purpose"] != "meeting_archive_sequence_desc" or claim["meetingId"] != meeting_id
                or type(claim["limit"]) is not int or claim["limit"] != limit or claim["window"] != window
                or type(claim["exp"]) is not int or not now < claim["exp"] <= now + 300
                or type(claim["after"]) is not int or not 1 <= claim["after"] <= window["throughSequence"]):
            raise RuntimeInvalidRequest()
        return claim
    except LegacyInvalid:
        raise RuntimeInvalidRequest() from None


def validate_archive_page(value, meeting_id, limit, previous_cursor=None):
    if (type(value) is not dict or set(value) != {"kind", "meetingId", "archiveWindow", "ordering", "items", "nextCursor", "mediaReady"}
            or value["kind"] != "canonical-current" or value["meetingId"] != meeting_id
            or value["ordering"] != MESSAGE_ORDER or value["mediaReady"] is not False
            or type(value["items"]) is not list or len(value["items"]) > limit):
        raise RuntimeUnavailable()
    window = value["archiveWindow"]
    # Full date/UUID/type validation also applies at the HTTP adapter boundary.
    member_archive_window({"origin": MEMBER_ORIGIN, "archiveWindow": window},
        window.get("membershipRevision") if type(window) is dict else None,
        "0001-01-01T00:00:00.000000Z", "9999-12-31T23:59:59.999999Z")
    previous = window["throughSequence"] + 1
    for item in value["items"]:
        _message(item); _utc(item["createdAt"])
        if item["meetingId"] != meeting_id or not 0 < item["sequence"] < previous:
            raise RuntimeUnavailable()
        previous = item["sequence"]
    token = value["nextCursor"]
    if token is not None and (type(token) is not str or re.fullmatch(r"[A-Za-z0-9_-]{1,4096}", token) is None or token == previous_cursor or not value["items"]):
        raise RuntimeUnavailable()
    try:
        canonical_json(value, max_bytes=65536)
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None
    return value


def read_archive(reader, identity, meeting_id, *, limit=30, cursor=None, access_token):
    meeting_id = _uid(meeting_id)
    if type(limit) is not int or not 1 <= limit <= 30:
        raise RuntimeInvalidRequest()
    def action(sql_cursor, execute, uid):
        window = _window(reader, sql_cursor, execute, uid, meeting_id)
        claim = _cursor(reader, cursor, uid, meeting_id, limit, window)
        cap = window["throughSequence"]
        if cap:
            execute(_SELECT + " FORCE INDEX (meeting_messages_page_idx) WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY) AND mm.sequence = %s LIMIT 1 FOR SHARE OF mm", (meeting_id, meeting_id, cap))
            sources = sql_cursor.fetchall()
            if len(sources) != 1 or _row(sources[0], meeting_id)["sequence"] != cap:
                raise RuntimeUnavailable()
        sql = _SELECT + " FORCE INDEX (meeting_messages_page_idx) WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY) AND mm.sequence <= %s"
        params = [meeting_id, meeting_id, cap]
        if claim["after"] is not None:
            sql += " AND mm.sequence < %s"; params.append(claim["after"])
        execute(sql + " ORDER BY mm.sequence DESC LIMIT %s FOR SHARE OF mm", (*params, limit + 1))
        rows = sql_cursor.fetchall()
        if len(rows) > limit + 1:
            raise RuntimeUnavailable()
        items = [_row(row, meeting_id) for row in rows]
        previous = claim["after"] or cap + 1
        for item in items:
            if not 0 < item["sequence"] < previous or item["sequence"] > cap:
                raise RuntimeUnavailable()
            previous = item["sequence"]
        base = {"kind": "canonical-current", "meetingId": meeting_id, "archiveWindow": window,
            "ordering": MESSAGE_ORDER, "mediaReady": False}
        page = _pack(items, limit, base, lambda item: item, "nextCursor",
            lambda item: reader._codec.seal("cursor", {**claim, "after": item["sequence"]}))
        _owner_profile(sql_cursor, execute, uid)
        return validate_archive_page(page, meeting_id, limit, cursor)
    return reader._store.read_authenticated(identity, action, access_token=access_token)
