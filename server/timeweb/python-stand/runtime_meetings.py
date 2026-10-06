"""Isolated, disabled-by-default current meeting read projection.

The policy argument is a trusted integration prerequisite, NOT evidence that
a retained source marker proves native origin. No HTTP factory is wired here.
See TIMEWEB_NATIVE_MEETINGS.md before enabling any production caller.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import hmac
import os
import time

from legacy_conversation_payload import OpaqueReferences, LegacyInvalid
from native_credentials import decode_base64
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, canonical_json
from runtime_people import (RuntimePeopleService, _SELECT as PROFILE_SELECT,
                            _row as profile_row, _decode_person, _uid,
                            validate_people_filters)
from runtime_reads import RuntimeReadRejected, _number, _text, _timestamp
from runtime_meeting_create import native_origin_sql, local_datetime
from runtime_geography import resolve_geography


TRUSTED_POLICY = "reviewed-native-marker-v1"
MEETING_ORDER = "starts_at_asc_meeting_id_asc_null_first"
PARTICIPANT_ORDER = "uid_binary_asc"
MAX_PAGE = 30
SCAN_CHUNK = 32
MAX_SCAN_ROWS = 128
MAX_PUBLIC_BYTES = 65_536
MAX_CURSOR_CHARS = 4096
CURSOR_SECONDS = 300
MEETING_FIELDS = ("meetingId", "organizerUid", "invitedUid", "kind", "title",
    "description", "countryCode", "region", "startsAt", "createdAt", "updatedAt",
    "revision", "deletedAt", "trusted", "valid", "localDatetime")
MEMBER_FIELDS = ("meetingId", "uid", "joinedAt", "leftAt", "kickedAt",
                 "membershipRevision", "trusted")


def _stamp(column):
    return f"DATE_FORMAT({column}, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')"


def _native_source(alias):
    return native_origin_sql(alias, member=alias == "mm")


def _meeting_selection():
    columns = ["m.meeting_id", "m.organizer_uid", "m.invited_uid", "m.kind"]
    valid = []
    for column, maximum in (("title", 1000), ("description", 4096),
                            ("country_code", 191), ("region", 191)):
        predicate = f"(m.{column} IS NULL OR (CHAR_LENGTH(m.{column}) <= {maximum} AND OCTET_LENGTH(m.{column}) <= {maximum * 4}))"
        columns.append(f"CASE WHEN {predicate} THEN m.{column} ELSE NULL END")
        valid.append(predicate)
    columns += [_stamp("m." + column) for column in ("starts_at", "created_at", "updated_at")]
    columns += ["m.revision", _stamp("m.deleted_at"), _native_source("m"),
                "(" + " AND ".join(valid) + ")",
                "CASE WHEN " + _native_source("m") + " = 1 THEN JSON_UNQUOTE(JSON_EXTRACT(m.legacy_raw, '$.localDatetime')) ELSE NULL END"]
    return "SELECT " + ",\n ".join(columns) + "\n FROM clrs_staging.meetings AS m"


MEETING_SELECT = _meeting_selection()
MEMBER_SELECT = "SELECT mm.meeting_id, mm.uid, " + ", ".join(
    _stamp("mm." + column) for column in ("joined_at", "left_at", "kicked_at")) + ", mm.membership_revision, " + _native_source("mm") + " FROM clrs_staging.meeting_members AS mm"


def meetings_query(scope, anchor=None):
    # Direct equality/range/order columns use the frozen browse index. Individual
    # organizer OR invitee and geography are bounded postfilters, not table scans.
    sql = MEETING_SELECT + " FORCE INDEX (meetings_browse_idx) WHERE m.kind = %s AND m.deleted_at IS NULL"
    params = [scope]
    if anchor is not None:
        if anchor[0] is None:
            sql += " AND ((m.starts_at IS NULL AND m.meeting_id > %s) OR m.starts_at IS NOT NULL)"
            params.append(anchor[1])
        else:
            sql += " AND (m.starts_at > CAST(%s AS DATETIME(6)) OR (m.starts_at = CAST(%s AS DATETIME(6)) AND m.meeting_id > %s))"
            stamp = anchor[0][:-1].replace("T", " ")
            params.extend((stamp, stamp, anchor[1]))
    sql += " ORDER BY m.starts_at ASC, m.meeting_id ASC LIMIT %s FOR SHARE OF m"
    return sql, tuple([*params, SCAN_CHUNK])


def meeting_query(meeting_id):
    return (MEETING_SELECT + " WHERE m.meeting_id = %s AND CAST(m.meeting_id AS BINARY) = CAST(%s AS BINARY) AND m.deleted_at IS NULL LIMIT 1 FOR SHARE OF m", (meeting_id, meeting_id))


def profiles_query(uids):
    if not 1 <= len(uids) <= 2 * SCAN_CHUNK:
        raise RuntimeUnavailable()
    placeholders = ",".join("%s" for _ in uids)
    exact = ",".join("CAST(%s AS BINARY)" for _ in uids)
    return (PROFILE_SELECT + f" AND p.uid IN ({placeholders}) AND CAST(p.uid AS BINARY) IN ({exact}) LIMIT %s FOR SHARE OF p, a",
            (*uids, *uids, len(uids)))


def actor_members_query(meeting_ids, uid):
    if not 1 <= len(meeting_ids) <= SCAN_CHUNK:
        raise RuntimeUnavailable()
    placeholders = ",".join("%s" for _ in meeting_ids)
    exact = ",".join("CAST(%s AS BINARY)" for _ in meeting_ids)
    return (MEMBER_SELECT + f" WHERE mm.meeting_id IN ({placeholders}) AND CAST(mm.meeting_id AS BINARY) IN ({exact}) AND mm.uid = %s AND CAST(mm.uid AS BINARY) = CAST(%s AS BINARY) LIMIT %s FOR SHARE OF mm",
            (*meeting_ids, *meeting_ids, uid, uid, len(meeting_ids)))


def participants_query(meeting_id, anchor=None):
    sql = MEMBER_SELECT + " FORCE INDEX (meeting_members_active_idx) WHERE mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY) AND mm.left_at IS NULL"
    params = [meeting_id, meeting_id]
    if anchor is not None:
        sql += " AND mm.uid > %s"
        params.append(anchor)
    sql += " ORDER BY mm.uid ASC LIMIT %s FOR SHARE OF mm"
    return sql, (*params, SCAN_CHUNK)


def _source_id(value):
    try:
        return _uid(value)
    except RuntimeInvalidRequest:
        raise RuntimeUnavailable() from None


def _meeting_row(source):
    if not isinstance(source, (tuple, list)) or len(source) != len(MEETING_FIELDS):
        raise RuntimeUnavailable()
    row = dict(zip(MEETING_FIELDS, source))
    _source_id(row["meetingId"]); _source_id(row["organizerUid"])
    if row["invitedUid"] is not None:
        _source_id(row["invitedUid"])
    if not ((row["kind"] == "group" and row["invitedUid"] is None)
            or (row["kind"] == "individual" and row["invitedUid"] is not None
                and row["invitedUid"] != row["organizerUid"])):
        raise RuntimeUnavailable()
    for field in ("startsAt", "createdAt", "updatedAt", "deletedAt"):
        _timestamp(row[field], nullable=True)
    _number(row["revision"])
    for field in ("trusted", "valid"):
        if type(row[field]) is not int or row[field] not in (0, 1):
            raise RuntimeUnavailable()
    if row["trusted"] == 1:
        try:
            local_datetime(row["localDatetime"])
        except RuntimeInvalidRequest:
            raise RuntimeUnavailable() from None
        if row["startsAt"] is not None:
            raise RuntimeUnavailable()
    return row


def _meeting_dto(row):
    if row["deletedAt"] is not None or row["trusted"] != 1 or row["valid"] != 1:
        return None
    result = {field: row[field] for field in MEETING_FIELDS[:12]}
    try:
        for field, maximum in (("title", 1000), ("description", 4096),
                               ("countryCode", 191), ("region", 191)):
            result[field] = _text(row[field], maximum, nullable=True)
    except RuntimeUnavailable:
        return None
    try:
        if not isinstance(result["title"], str) or not result["title"].strip() or type(result["description"]) is not str:
            return None
        resolve_geography({key: result[key] for key in ("countryCode", "region")})
    except RuntimeInvalidRequest:
        return None
    result.update(localDatetime=row["localDatetime"], media=None, mediaReady=False)
    return result


def _member_row(source):
    if not isinstance(source, (tuple, list)) or len(source) != len(MEMBER_FIELDS):
        raise RuntimeUnavailable()
    row = dict(zip(MEMBER_FIELDS, source))
    _source_id(row["meetingId"]); _source_id(row["uid"])
    for field in ("joinedAt", "leftAt", "kickedAt"):
        _timestamp(row[field], nullable=True)
    _number(row["membershipRevision"])
    if row["trusted"] == 1:
        _timestamp(row["joinedAt"])
    if type(row["trusted"]) is not int or row["trusted"] not in (0, 1):
        raise RuntimeUnavailable()
    if row["kickedAt"] is not None and row["leftAt"] is None:
        raise RuntimeUnavailable()
    return row


def _after(row, anchor):
    if anchor is None:
        return True
    if anchor[0] is None:
        return row["startsAt"] is not None or row["meetingId"].encode() > anchor[1].encode()
    return (row["startsAt"] is not None and (row["startsAt"] > anchor[0]
        or (row["startsAt"] == anchor[0] and row["meetingId"].encode() > anchor[1].encode())))


def _own_summary(row):
    result = {"fullName": None, "primaryGroup": None}
    if row is not None:
        for field, maximum in (("fullName", 1000), ("primaryGroup", 191)):
            try:
                result[field] = _text(row[field], maximum, nullable=True)
            except RuntimeUnavailable:
                pass
    return result


class RuntimeMeetingsService:
    def __init__(self, store, cursor_key, *, trusted_policy, clock=time.time):
        if (store is None or type(cursor_key) is not bytes or len(cursor_key) != 32
                or trusted_policy != TRUSTED_POLICY):
            raise RuntimeUnavailable()
        self._store = store; self._clock = clock
        self._codec = OpaqueReferences(hmac.digest(cursor_key, b"clrs-runtime-current-meetings-cursor-v1\0", "sha256"))

    @classmethod
    def from_env(cls, store, env=None, *, trusted_policy=None):
        # No environment flag can establish meeting origin/public visibility.
        # An independently reviewed production integration must supply policy.
        env = os.environ if env is None else env
        if (trusted_policy is None or env.get("CLRS_RUNTIME_WRITES_ENABLED") != "1"
                or env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") != "canonical-current-v1"):
            return None
        try:
            return cls(store, decode_base64(env.get("CLRS_LEGACY_READ_CURSOR_KEY_B64"), max_bytes=32),
                       trusted_policy=trusted_policy)
        except Exception:
            raise RuntimeUnavailable() from None

    def _cursor(self, value, uid, purpose, limit, digest, *, participant=False):
        if value is None:
            return None, int(self._clock()) + CURSOR_SECONDS
        try:
            if type(value) is not str or not 1 <= len(value) <= MAX_CURSOR_CHARS:
                raise RuntimeInvalidRequest()
            opened = self._codec.open("cursor", value)
            if (set(opened) != {"v", "uid", "purpose", "limit", "filterHash", "after", "exp"}
                    or type(opened["v"]) is not int or opened["v"] != 1
                    or opened["uid"] != uid or opened["purpose"] != purpose
                    or type(opened["limit"]) is not int or opened["limit"] != limit
                    or opened["filterHash"] != digest or type(opened["exp"]) is not int
                    or not int(self._clock()) < opened["exp"] <= int(self._clock()) + CURSOR_SECONDS):
                raise RuntimeInvalidRequest()
            anchor = opened["after"]
            if participant:
                _uid(anchor)
            else:
                if type(anchor) is not list or len(anchor) != 2:
                    raise RuntimeInvalidRequest()
                _timestamp(anchor[0], nullable=True); _uid(anchor[1])
            return anchor, opened["exp"]
        except (LegacyInvalid, RuntimeInvalidRequest, RuntimeUnavailable):
            raise RuntimeInvalidRequest() from None

    def _next(self, uid, purpose, limit, digest, anchor, expiry):
        return self._codec.seal("cursor", {"v": 1, "uid": uid, "purpose": purpose,
            "limit": limit, "filterHash": digest, "after": anchor, "exp": expiry})

    @staticmethod
    def _limit(value):
        if type(value) is not int or not 1 <= value <= MAX_PAGE:
            raise RuntimeInvalidRequest()

    @staticmethod
    def _profiles(cursor, execute, uids):
        if not uids:
            return {}
        uids = sorted(set(uids), key=lambda uid: uid.encode())
        sql, params = profiles_query(uids)
        execute(sql, params); sources = cursor.fetchall()
        if len(sources) > len(uids):
            raise RuntimeUnavailable()
        result = {}
        for source in sources:
            row = profile_row(source)
            if row["uid"] not in uids or row["uid"] in result:
                raise RuntimeUnavailable()
            result[row["uid"]] = row
        return result

    @staticmethod
    def _actor_members(cursor, execute, meeting_ids, uid):
        if not meeting_ids:
            return {}
        sql, params = actor_members_query(meeting_ids, uid)
        execute(sql, params); sources = cursor.fetchall()
        if len(sources) > len(meeting_ids):
            raise RuntimeUnavailable()
        result = {}
        for source in sources:
            row = _member_row(source)
            if row["uid"] != uid or row["meetingId"] not in meeting_ids or row["meetingId"] in result:
                raise RuntimeUnavailable()
            result[row["meetingId"]] = row
        return result

    def _meeting_rows(self, cursor, execute, sources):
        return [_meeting_row(source) for source in sources]

    def _member_rows(self, cursor, execute, sources):
        return [_member_row(source) for source in sources]

    def _read_actor_members(self, cursor, execute, meeting_ids, uid):
        return self._actor_members(cursor, execute, meeting_ids, uid)

    def _read_policy(self):
        return TRUSTED_POLICY

    @staticmethod
    def _eligible(row, actor, profiles, member, now, *, participants=False):
        if _meeting_dto(row) is None:
            return False
        # Current kick applies even to group metadata. Leaving a public group
        # does not make its metadata private. Imported member provenance is not
        # silently treated as a trusted no-kick decision.
        if member is not None and (member["trusted"] != 1 or member["kickedAt"] is not None):
            return False
        if row["kind"] == "individual":
            if actor.uid not in (row["organizerUid"], row["invitedUid"]):
                return False
            if participants and actor.uid != row["organizerUid"] and (member is None or member["leftAt"] is not None):
                return False
        for uid in (row["organizerUid"], row["invitedUid"]):
            # Own relation grants metadata access; it is not a self public
            # eligibility claim. Foreign accounts use the existing evaluator.
            if uid is not None and uid != actor.uid:
                profile = profiles.get(uid)
                if profile is None or _decode_person(profile, actor, now) is None:
                    return False
        return True

    def _meeting(self, cursor, execute, uid, actor, meeting_id, now, *, participants=False):
        sql, params = meeting_query(meeting_id)
        execute(sql, params); sources = cursor.fetchall()
        if not sources:
            raise RuntimeReadRejected()
        if len(sources) != 1:
            raise RuntimeUnavailable()
        row = self._meeting_rows(cursor, execute, sources)[0]
        if row["meetingId"] != meeting_id:
            raise RuntimeUnavailable()
        profiles = self._profiles(cursor, execute, [target for target in (row["organizerUid"], row["invitedUid"])
                                                    if target is not None and target != uid])
        member = self._read_actor_members(cursor, execute, [meeting_id], uid).get(meeting_id)
        if not self._eligible(row, actor, profiles, member, now, participants=participants):
            raise RuntimeReadRejected()
        return row

    @staticmethod
    def _page(scope, items, next_cursor=None):
        return {"kind": "canonical-current", "ordering": MEETING_ORDER, "scope": scope,
                "items": items, "nextCursor": next_cursor, "mediaReady": False}

    @staticmethod
    def _participants_page(meeting_id, items, next_cursor=None):
        return {"kind": "canonical-current", "meetingId": meeting_id, "ordering": PARTICIPANT_ORDER,
                "items": items, "nextCursor": next_cursor, "mediaReady": False}

    @staticmethod
    def _fits(page):
        return len(canonical_json(page, max_bytes=4 * 1024 * 1024)) <= MAX_PUBLIC_BYTES

    def messages(self, identity, meeting_id, *, limit=30, cursor=None, access_token):
        from runtime_meeting_chat import read_messages
        return read_messages(self, identity, meeting_id, limit=limit, cursor=cursor, access_token=access_token)

    def archived_messages(self, identity, meeting_id, *, limit=30, cursor=None, access_token):
        from runtime_meeting_archive import read_archive
        return read_archive(self, identity, meeting_id, limit=limit, cursor=cursor, access_token=access_token)

    def meetings(self, identity, *, access_token, scope="group", limit=30, cursor=None,
                 country_code=None, region=None):
        self._limit(limit)
        if type(scope) is not str or scope not in {"group", "individual"}:
            raise RuntimeInvalidRequest()
        geo = validate_people_filters(country_code=country_code, region=region)
        filters = {"scope": scope, "countryCode": geo["countryCode"], "region": geo["region"],
                   "policy": self._read_policy()}
        digest = hashlib.sha256(canonical_json(filters)).hexdigest()
        def action(sql_cursor, execute, uid):
            anchor, expiry = self._cursor(cursor, uid, MEETING_ORDER, limit, digest)
            actor = RuntimePeopleService._actor(sql_cursor, execute, uid)
            now = datetime.fromtimestamp(self._clock(), timezone.utc)
            items = []; scanned = 0
            while scanned < MAX_SCAN_ROWS:
                sql, params = meetings_query(scope, anchor)
                execute(sql, params); sources = sql_cursor.fetchall()
                if len(sources) > SCAN_CHUNK:
                    raise RuntimeUnavailable()
                rows = self._meeting_rows(sql_cursor, execute, sources)
                candidates = [row for row in rows if _meeting_dto(row) is not None
                    and (scope != "individual" or uid in (row["organizerUid"], row["invitedUid"]))
                    and (country_code is None or row["countryCode"] == country_code)
                    and (region is None or row["region"] == region)]
                profiles = self._profiles(sql_cursor, execute, [target for row in candidates
                    for target in (row["organizerUid"], row["invitedUid"]) if target is not None and target != uid])
                members = self._read_actor_members(sql_cursor, execute, [row["meetingId"] for row in candidates], uid)
                candidate_ids = {row["meetingId"] for row in candidates}
                for row in rows:
                    if row["kind"] != scope or not _after(row, anchor):
                        raise RuntimeUnavailable()
                    previous = anchor; anchor = [row["startsAt"], row["meetingId"]]; scanned += 1
                    if row["meetingId"] in candidate_ids and self._eligible(row, actor, profiles,
                            members.get(row["meetingId"]), now):
                        item = _meeting_dto(row)
                        if len(items) == limit or not self._fits(self._page(scope, [*items, item], "x" * MAX_CURSOR_CHARS)):
                            if previous is None:
                                raise RuntimeUnavailable()
                            return self._page(scope, items, self._next(uid, MEETING_ORDER, limit, digest, previous, expiry))
                        items.append(item)
                    if scanned == MAX_SCAN_ROWS:
                        return self._page(scope, items, self._next(uid, MEETING_ORDER, limit, digest, anchor, expiry))
                if len(rows) < SCAN_CHUNK:
                    return self._page(scope, items)
            raise RuntimeUnavailable()
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def meeting(self, identity, meeting_id, *, access_token):
        meeting_id = _uid(meeting_id)
        def action(cursor, execute, uid):
            actor = RuntimePeopleService._actor(cursor, execute, uid)
            row = self._meeting(cursor, execute, uid, actor, meeting_id,
                                datetime.fromtimestamp(self._clock(), timezone.utc))
            return {"kind": "canonical-current", "meeting": _meeting_dto(row), "mediaReady": False}
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def participants(self, identity, meeting_id, *, access_token, limit=30, cursor=None):
        meeting_id = _uid(meeting_id); self._limit(limit)
        digest = hashlib.sha256(canonical_json({"meetingId": meeting_id, "policy": self._read_policy()})).hexdigest()
        def action(sql_cursor, execute, uid):
            anchor, expiry = self._cursor(cursor, uid, PARTICIPANT_ORDER, limit, digest, participant=True)
            actor = RuntimePeopleService._actor(sql_cursor, execute, uid)
            now = datetime.fromtimestamp(self._clock(), timezone.utc)
            meeting = self._meeting(sql_cursor, execute, uid, actor, meeting_id, now, participants=True)
            items = []; scanned = 0
            while scanned < MAX_SCAN_ROWS:
                sql, params = participants_query(meeting_id, anchor)
                execute(sql, params); sources = sql_cursor.fetchall()
                if len(sources) > SCAN_CHUNK:
                    raise RuntimeUnavailable()
                rows = self._member_rows(sql_cursor, execute, sources)
                profiles = self._profiles(sql_cursor, execute, [row["uid"] for row in rows
                    if row["trusted"] == 1 and row["leftAt"] is None and row["kickedAt"] is None
                    and (meeting["kind"] == "group" or row["uid"] in (meeting["organizerUid"], meeting["invitedUid"]))])
                for row in rows:
                    if row["meetingId"] != meeting_id or row["leftAt"] is not None or (anchor is not None and row["uid"].encode() <= anchor.encode()):
                        raise RuntimeUnavailable()
                    previous = anchor; anchor = row["uid"]; scanned += 1
                    person = None
                    if row["trusted"] == 1 and row["kickedAt"] is None and (meeting["kind"] == "group"
                            or row["uid"] in (meeting["organizerUid"], meeting["invitedUid"])):
                        profile = profiles.get(row["uid"])
                        person = _own_summary(profile) if row["uid"] == uid else (
                            None if profile is None else _decode_person(profile, actor, now))
                    if person is not None:
                        item = {"uid": row["uid"], "fullName": person["fullName"], "primaryGroup": person["primaryGroup"],
                            "joinedAt": row["joinedAt"], "membershipRevision": row["membershipRevision"],
                            "avatar": None, "mediaReady": False}
                        if len(items) == limit or not self._fits(self._participants_page(meeting_id, [*items, item], "x" * MAX_CURSOR_CHARS)):
                            if previous is None:
                                raise RuntimeUnavailable()
                            return self._participants_page(meeting_id, items, self._next(uid, PARTICIPANT_ORDER, limit, digest, previous, expiry))
                        items.append(item)
                    if scanned == MAX_SCAN_ROWS:
                        return self._participants_page(meeting_id, items, self._next(uid, PARTICIPANT_ORDER, limit, digest, anchor, expiry))
                if len(rows) < SCAN_CHUNK:
                    return self._participants_page(meeting_id, items)
            raise RuntimeUnavailable()
        return self._store.read_authenticated(identity, action, access_token=access_token)
