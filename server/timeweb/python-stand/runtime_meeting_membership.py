"""Bounded native leave/kick. Rows remain; archived-chat parity is separate.

A retained receipt proves the original action, not current chat access. Shared
account/session authorization still runs before and after every lookup.
"""
from __future__ import annotations

from datetime import datetime, timezone
import re
import time

from runtime_chat import _integer, _stamp
from runtime_meeting_create import MeetingAccessRejected, _indexes, _current_profile
from runtime_meetings import (MEETING_SELECT, MEMBER_SELECT, _meeting_row,
    _member_row, _meeting_dto, RuntimeMeetingsService)
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, canonical_json
from runtime_people import RuntimePeopleService
from runtime_personal_chat import _uid
from runtime_reads import _timestamp


LEAVE_OPERATION = "meeting.leave.v1"
KICK_OPERATION = "meeting.kick.v1"
DECLARED_ERRORS = frozenset({"meeting_not_found", "meeting_unavailable", "profile_not_found",
    "profile_not_ready", "participant_not_found", "organizer_required", "cannot_kick_self"})


def validate_membership(payload, *, kick=False):
    fields = {"meetingId", "targetUid"} if kick else {"meetingId"}
    if type(payload) is not dict or set(payload) != fields:
        raise RuntimeInvalidRequest()
    return {key: _uid(payload[key]) for key in fields}


class _MembershipFailure(Exception):
    def __init__(self, status, error):
        self.status = status; self.error = error


def _meeting(cursor, execute, meeting_id, *, readonly):
    execute(MEETING_SELECT + " WHERE m.meeting_id = %s AND CAST(m.meeting_id AS BINARY) = CAST(%s AS BINARY) LIMIT 1"
        + (" FOR SHARE OF m" if readonly else " FOR UPDATE"), (meeting_id, meeting_id))
    rows = cursor.fetchall()
    if len(rows) > 1:
        raise RuntimeUnavailable()
    if not rows:
        raise _MembershipFailure(404, "meeting_not_found")
    row = _meeting_row(rows[0])
    if row["meetingId"] != meeting_id:
        raise RuntimeUnavailable()
    if _meeting_dto(row) is None:
        raise _MembershipFailure(404, "meeting_not_found")
    return row


def _affected(cursor, execute, meeting_id, uid, *, readonly):
    execute(MEMBER_SELECT + " WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY)"
        " AND mm.uid = %s AND CAST(mm.uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1"
        + (" FOR SHARE OF mm" if readonly else " FOR UPDATE"), (meeting_id, meeting_id, uid, uid))
    rows = cursor.fetchall()
    if len(rows) > 1:
        raise RuntimeUnavailable()
    if not rows:
        return None
    row = _member_row(rows[0])
    if row["meetingId"] != meeting_id or row["uid"] != uid or row["trusted"] != 1:
        raise RuntimeUnavailable()
    return row


def _utc(value):
    if type(value) is not str or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z", value) is None:
        raise RuntimeUnavailable()
    _timestamp(value)
    return value


class RuntimeMeetingMembershipService:
    def __init__(self, store, *, clock=time.time):
        self._store = store; self._clock = clock
        self._allowed = getattr(store, "_env", {}).get("CLRS_RUNTIME_PERMISSION_MODEL") == "provider-database-v1"
        for operation in (LEAVE_OPERATION, KICK_OPERATION):
            store.register_replay_guard(operation,
                self._kick_guard if operation == KICK_OPERATION else self._leave_guard, response_guard=True)

    def _base(self, cursor, execute, uid, request, *, readonly, authorize=True):
        if not self._allowed:
            raise RuntimeUnavailable()
        _indexes(cursor, execute)
        now = datetime.fromtimestamp(self._clock(), timezone.utc)
        if authorize:
            failure = _current_profile(cursor, execute, uid, {"type": "групповая"}, now)
            if failure:
                raise _MembershipFailure(*failure)
        row = _meeting(cursor, execute, request["meetingId"], readonly=readonly)
        member = _affected(cursor, execute, request["meetingId"], uid, readonly=readonly)
        if authorize:
            actor = RuntimePeopleService._actor(cursor, execute, uid)
            profiles = RuntimeMeetingsService._profiles(cursor, execute,
                [target for target in (row["organizerUid"], row["invitedUid"]) if target is not None and target != uid])
            if not RuntimeMeetingsService._eligible(row, actor, profiles, member, now):
                raise _MembershipFailure(409, "meeting_unavailable")
        return row, member

    @staticmethod
    def _update(cursor, execute, member, *, kick, operation_id=None):
        previous = member["membershipRevision"]; revision = _integer(previous + 1)
        stamp = _utc(_stamp(cursor, execute)); left = member["leftAt"] or stamp
        if stamp < member["joinedAt"] or (member["leftAt"] is not None and stamp < member["leftAt"]):
            raise RuntimeUnavailable()
        kicked = stamp if kick else member["kickedAt"]
        sql_time = lambda value: value[:-1].replace("T", " ") if value is not None else None
        raw_assignment = ""
        values = [sql_time(left), sql_time(kicked), revision]
        if not kick:
            from runtime_meeting_archive import capture_window
            marker = capture_window(cursor, execute, member, operation_id, revision, stamp)
            raw_assignment = ", legacy_raw = %s"; values.append(canonical_json(marker).decode())
        execute("""UPDATE clrs_staging.meeting_members SET left_at = %s, kicked_at = %s, membership_revision = %s""" + raw_assignment + """
 WHERE meeting_id = %s AND CAST(meeting_id AS BINARY) = CAST(%s AS BINARY)
 AND uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) AND membership_revision = %s""",
            (*values, member["meetingId"], member["meetingId"], member["uid"], member["uid"], previous))
        if cursor.rowcount != 1:
            raise RuntimeUnavailable()
        current = _affected(cursor, execute, member["meetingId"], member["uid"], readonly=False)
        expected = {**member, "leftAt": left, "kickedAt": kicked, "membershipRevision": revision}
        if current != expected:
            raise RuntimeUnavailable()
        return current

    def leave(self, identity, operation_id, payload, *, access_token):
        request = validate_membership(payload)
        def action(cursor, execute, uid):
            try:
                _, member = self._base(cursor, execute, uid, request, readonly=False)
            except _MembershipFailure as failure:
                return failure.status, {"error": failure.error}, None
            already = member is None or member["leftAt"] is not None
            if not already:
                member = self._update(cursor, execute, member, kick=False, operation_id=operation_id)
            revision = member["membershipRevision"] if member is not None else None
            return 200, {"meetingId": request["meetingId"], "left": True, "alreadyLeft": already,
                "membershipRevision": revision, "leftAt": member["leftAt"] if member is not None else None}, revision
        return self._store.mutate(identity, LEAVE_OPERATION, operation_id, request, action, access_token=access_token)

    def kick(self, identity, operation_id, payload, *, access_token):
        request = validate_membership(payload, kick=True)
        def action(cursor, execute, uid):
            try:
                row, _ = self._base(cursor, execute, uid, request, readonly=False)
                if row["organizerUid"] != uid:
                    raise _MembershipFailure(409, "organizer_required")
                if request["targetUid"] == uid:
                    raise _MembershipFailure(409, "cannot_kick_self")
                member = _affected(cursor, execute, request["meetingId"], request["targetUid"], readonly=False)
                if member is None:
                    raise _MembershipFailure(404, "participant_not_found")
                if row["kind"] == "individual" and request["targetUid"] != row["invitedUid"]:
                    raise _MembershipFailure(409, "meeting_unavailable")
            except _MembershipFailure as failure:
                return failure.status, {"error": failure.error}, None
            already = member["kickedAt"] is not None
            if not already:
                member = self._update(cursor, execute, member, kick=True)
            revision = member["membershipRevision"]
            return 200, {"meetingId": request["meetingId"], "targetUid": request["targetUid"], "kicked": True,
                "alreadyKicked": already, "membershipRevision": revision,
                "kickedAt": member["kickedAt"], "leftAt": member["leftAt"]}, revision
        return self._store.mutate(identity, KICK_OPERATION, operation_id, request, action, access_token=access_token)

    def _leave_guard(self, cursor, execute, uid, request, response):
        self._replay(cursor, execute, uid, request, response, kick=False)

    def _kick_guard(self, cursor, execute, uid, request, response):
        self._replay(cursor, execute, uid, request, response, kick=True)

    def _replay(self, cursor, execute, uid, request, response, *, kick):
        request = validate_membership(request, kick=kick)
        if type(response) is dict and set(response) == {"error"} and response["error"] in DECLARED_ERRORS:
            return
        expected = {"meetingId", "targetUid", "kicked", "alreadyKicked", "membershipRevision", "kickedAt", "leftAt"} if kick else {
            "meetingId", "left", "alreadyLeft", "membershipRevision", "leftAt"}
        if (type(response) is not dict or set(response) != expected or response["meetingId"] != request["meetingId"]
                or response["kicked" if kick else "left"] is not True
                or type(response["alreadyKicked" if kick else "alreadyLeft"]) is not bool
                or (kick and response["targetUid"] != request["targetUid"])):
            raise RuntimeUnavailable()
        revision = response["membershipRevision"]
        if revision is None:
            if kick or response["alreadyLeft"] is not True or response["leftAt"] is not None:
                raise RuntimeUnavailable()
        else:
            _integer(revision); _utc(response["leftAt"])
        if kick:
            _utc(response["kickedAt"])
            if response["kickedAt"] < response["leftAt"]:
                raise RuntimeUnavailable()
        try:
            row, own = self._base(cursor, execute, uid, request, readonly=True, authorize=False)
            if kick and row["organizerUid"] != uid:
                raise RuntimeUnavailable()
            member = _affected(cursor, execute, request["meetingId"], request["targetUid"], readonly=True) if kick else own
            if revision is not None:
                if member is None or member["membershipRevision"] < revision or response["leftAt"] < member["joinedAt"]:
                    raise RuntimeUnavailable()
                # At the same revision the current row must prove the action.
                # A later rejoin may clear left_at; the original receipt remains
                # historical confirmation and grants no message/roster access.
                if member["membershipRevision"] == revision and (member["leftAt"] != response["leftAt"]
                        or (kick and member["kickedAt"] != response["kickedAt"])):
                    raise RuntimeUnavailable()
        except (_MembershipFailure, RuntimeUnavailable):
            raise MeetingAccessRejected() from None
