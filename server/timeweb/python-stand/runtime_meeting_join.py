"""Self-only atomic join for reviewed native markers; imported rows stay closed.

The shared store owns native session locks, grants/deadlines, original receipts
and unknown-commit lookup. No rejoin, historical timestamp or source rewrite.
"""
from __future__ import annotations

from datetime import datetime, timezone
import time

from runtime_chat import _integer, _stamp
from runtime_meeting_create import (MEMBER_ORIGIN, MeetingAccessRejected,
    _indexes, _current_profile)
from runtime_meetings import (MEETING_SELECT, MEMBER_SELECT, _meeting_row,
    _member_row, _meeting_dto, RuntimeMeetingsService)
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, canonical_json
from runtime_people import RuntimePeopleService
from runtime_personal_chat import _uid


JOIN_OPERATION = "meeting.join.v1"
DECLARED_ERRORS = frozenset({"meeting_not_found", "meeting_unavailable",
                            "profile_not_found", "profile_not_ready"})


def validate_join(payload):
    if type(payload) is not dict or set(payload) != {"meetingId"}:
        raise RuntimeInvalidRequest()
    return {"meetingId": _uid(payload["meetingId"])}


class _JoinFailure(Exception):
    def __init__(self, status, error):
        self.status = status; self.error = error


def _member(cursor, execute, meeting_id, uid, *, readonly, allow_left=False):
    execute(MEMBER_SELECT + " WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY)"
        " AND mm.uid = %s AND CAST(mm.uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1"
        + (" FOR SHARE OF mm" if readonly else " FOR UPDATE"), (meeting_id, meeting_id, uid, uid))
    rows = cursor.fetchall()
    if len(rows) > 1:
        raise RuntimeUnavailable()
    if not rows:
        return None
    row = _member_row(rows[0])
    if row["meetingId"] != meeting_id or row["uid"] != uid:
        raise RuntimeUnavailable()
    if row["trusted"] != 1 or (row["leftAt"] is not None and not allow_left) or row["kickedAt"] is not None:
        raise _JoinFailure(409, "meeting_unavailable")
    return row


def _target(cursor, execute, uid, meeting_id, now, *, readonly, allow_left=False):
    # Existing PK equality and exact byte comparison; never browse/import scan.
    execute(MEETING_SELECT + " WHERE m.meeting_id = %s AND CAST(m.meeting_id AS BINARY) = CAST(%s AS BINARY) LIMIT 1"
        + (" FOR SHARE OF m" if readonly else " FOR UPDATE"), (meeting_id, meeting_id))
    rows = cursor.fetchall()
    if len(rows) > 1:
        raise RuntimeUnavailable()
    if not rows:
        raise _JoinFailure(404, "meeting_not_found")
    row = _meeting_row(rows[0])
    if row["meetingId"] != meeting_id:
        raise RuntimeUnavailable()
    if _meeting_dto(row) is None:
        raise _JoinFailure(404, "meeting_not_found")
    member = _member(cursor, execute, meeting_id, uid, readonly=readonly, allow_left=allow_left)
    actor = RuntimePeopleService._actor(cursor, execute, uid)
    profiles = RuntimeMeetingsService._profiles(cursor, execute,
        [target for target in (row["organizerUid"], row["invitedUid"]) if target is not None and target != uid])
    if not RuntimeMeetingsService._eligible(row, actor, profiles, member, now):
        raise _JoinFailure(409, "meeting_unavailable")
    # Creator membership already exists. A new individual participant must be
    # the exact current native invitation, never a client-supplied member list.
    if row["kind"] == "individual" and member is None and uid != row["invitedUid"]:
        raise _JoinFailure(409, "meeting_unavailable")
    return member


class RuntimeMeetingJoinService:
    def __init__(self, store, *, clock=time.time):
        self._store = store; self._clock = clock
        self._allow_join = getattr(store, "_env", {}).get("CLRS_RUNTIME_PERMISSION_MODEL") == "provider-database-v1"
        store.register_replay_guard(JOIN_OPERATION, self._replay_guard, response_guard=True)

    def _current(self, cursor, execute, uid, request, *, readonly, allow_left=False):
        if not self._allow_join:
            raise RuntimeUnavailable()
        _indexes(cursor, execute)
        now = datetime.fromtimestamp(self._clock(), timezone.utc)
        failure = _current_profile(cursor, execute, uid, {"type": "групповая"}, now)
        if failure:
            raise _JoinFailure(*failure)
        return _target(cursor, execute, uid, request["meetingId"], now, readonly=readonly, allow_left=allow_left)

    def _replay_guard(self, cursor, execute, uid, request, response):
        request = validate_join(request)
        if type(response) is dict and set(response) == {"error"} and response["error"] in DECLARED_ERRORS:
            return
        if (type(response) is not dict or set(response) != {"meetingId", "joined", "alreadyMember", "membershipRevision"}
                or response["meetingId"] != request["meetingId"] or response["joined"] is not True
                or type(response["alreadyMember"]) is not bool):
            raise RuntimeUnavailable()
        _integer(response["membershipRevision"])
        try:
            member = self._current(cursor, execute, uid, request, readonly=True)
            if member is None or member["membershipRevision"] < response["membershipRevision"]:
                raise _JoinFailure(409, "meeting_unavailable")
        except (_JoinFailure, RuntimeUnavailable):
            raise MeetingAccessRejected() from None

    def join(self, identity, operation_id, payload, *, access_token):
        request = validate_join(payload)
        def action(cursor, execute, uid):
            try:
                member = self._current(cursor, execute, uid, request, readonly=False, allow_left=True)
            except _JoinFailure as failure:
                return failure.status, {"error": failure.error}, None
            already = member is not None and member["leftAt"] is None
            if member is not None and member["leftAt"] is not None:
                previous = member["membershipRevision"]
                _integer(previous + 1)
                execute("""UPDATE clrs_staging.meeting_members SET left_at = NULL, membership_revision = %s
 WHERE meeting_id = %s AND CAST(meeting_id AS BINARY) = CAST(%s AS BINARY)
 AND uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)
 AND membership_revision = %s AND left_at IS NOT NULL AND kicked_at IS NULL""",
                    (previous + 1, request["meetingId"], request["meetingId"], uid, uid, previous))
                if cursor.rowcount != 1:
                    raise RuntimeUnavailable()
                member = _member(cursor, execute, request["meetingId"], uid, readonly=False)
                if member is None or member["membershipRevision"] != previous + 1:
                    raise RuntimeUnavailable()
            elif not already:
                stamp = _stamp(cursor, execute)
                execute("""INSERT INTO clrs_staging.meeting_members
 (meeting_id, uid, joined_at, left_at, kicked_at, membership_revision, legacy_raw)
 VALUES (%s, %s, %s, NULL, NULL, 0, %s)""", (request["meetingId"], uid,
                    stamp[:-1].replace("T", " "), canonical_json({"origin": MEMBER_ORIGIN}).decode()))
                if cursor.rowcount != 1:
                    raise RuntimeUnavailable()
                member = _member(cursor, execute, request["meetingId"], uid, readonly=False)
                if member is None or member["joinedAt"] != stamp or member["membershipRevision"] != 0:
                    raise RuntimeUnavailable()
            revision = member["membershipRevision"]
            return 200, {"meetingId": request["meetingId"], "joined": True,
                "alreadyMember": already, "membershipRevision": revision}, revision
        return self._store.mutate(identity, JOIN_OPERATION, operation_id, request, action, access_token=access_token)
