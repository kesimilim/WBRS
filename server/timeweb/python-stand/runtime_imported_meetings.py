"""Opt-in imported reads and bounded operation adapters from final authority."""
import time

from imported_meeting_authority import ImportedMeetingAuthority
from native_credentials import decode_base64
from runtime_mutations import RuntimeUnavailable
from runtime_reads import RuntimeReadRejected
from runtime_meetings import (RuntimeMeetingsService, TRUSTED_POLICY, SCAN_CHUNK,
    MEETING_FIELDS, MEMBER_FIELDS, _meeting_row, _member_row, actor_members_query)


def _proofs(cursor, execute, keys, *, member=False):
    if not keys: return {}
    if len(keys) > SCAN_CHUNK or len(keys) != len(set(keys)): raise RuntimeUnavailable()
    alias = "mm" if member else "m"; table = "meeting_members" if member else "meetings"
    columns = f"{alias}.meeting_id" + (f", {alias}.uid" if member else "")
    maximum = 2048 if member else 131072
    columns += f", CASE WHEN OCTET_LENGTH(CAST({alias}.legacy_raw AS CHAR CHARACTER SET utf8mb4)) <= {maximum} THEN {alias}.legacy_raw ELSE NULL END"
    predicates = []; params = []
    for key in keys:
        parts = [f"{alias}.meeting_id = %s", f"CAST({alias}.meeting_id AS BINARY) = CAST(%s AS BINARY)"]
        params.extend((key[0], key[0]))
        if member:
            parts += [f"{alias}.uid = %s", f"CAST({alias}.uid AS BINARY) = CAST(%s AS BINARY)"]
            params.extend((key[1], key[1]))
        predicates.append("(" + " AND ".join(parts) + ")")
    execute(f"SELECT {columns} FROM clrs_staging.{table} AS {alias} WHERE "
        + " OR ".join(predicates) + f" LIMIT %s FOR SHARE OF {alias}", (*params, len(keys)))
    rows = cursor.fetchall(); result = {}
    if len(rows) > len(keys): raise RuntimeUnavailable()
    for row in rows:
        if not isinstance(row, (tuple, list)) or len(row) != (3 if member else 2): raise RuntimeUnavailable()
        key = tuple(row[:-1])
        if key not in keys or key in result: raise RuntimeUnavailable()
        result[key] = row[-1]
    return result


def proved_meeting(cursor, execute, source, authority):
    if authority is None: return _meeting_row(source)
    authority.require()
    values = list(source)
    if len(values) == len(MEETING_FIELDS) and authority.reviewed(values[0]):
        values[MEETING_FIELDS.index("trusted")] = 0
    row = _meeting_row(values)
    if authority.reviewed(row["meetingId"]):
        proof = _proofs(cursor, execute, [(row["meetingId"],)])
        row = authority.meeting(row, proof.get((row["meetingId"],)))
    return row


def proved_member(cursor, execute, source, authority):
    if authority is None: return _member_row(source)
    authority.require()
    values = list(source)
    if len(values) == len(MEMBER_FIELDS) and authority.reviewed(values[0]):
        values[MEMBER_FIELDS.index("trusted")] = 0
    row = _member_row(values)
    if authority.reviewed(row["meetingId"]):
        proof = _proofs(cursor, execute, [(row["meetingId"], row["uid"])], member=True)
        row = authority.member(row, proof.get((row["meetingId"], row["uid"])))
    return row


def proved_messages(cursor, execute, sources, meeting_id, authority):
    from runtime_meeting_chat import _row, _message
    if authority is None or not authority.reviewed(meeting_id):
        return [_row(source, meeting_id) for source in sources]
    authority.require(); authority.message_tail(meeting_id)
    if len(sources) > 31: raise RuntimeUnavailable()
    items = []; keys = []
    for source in sources:
        if (not isinstance(source, (tuple, list)) or len(source) != 8 or source[0] != meeting_id
                or type(source[6]) is not int or source[6] != 1 or type(source[7]) is not int
                or source[7] not in (0, 1)):
            raise RuntimeUnavailable()
        if source[7] == 1:
            items.append(_row(source, meeting_id))
        else:
            items.append(_message(dict(zip(("meetingId", "messageId", "sequence", "senderUid", "text", "createdAt"), source[:6])), legacy_id=True))
            keys.append((meeting_id, source[1]))
    if keys:
        if len(keys) != len(set(keys)): raise RuntimeUnavailable()
        predicates = []; params = []
        for mid, message_id in keys:
            predicates.append("(mm.meeting_id = %s AND CAST(mm.meeting_id AS BINARY) = CAST(%s AS BINARY)"
                " AND mm.message_id = %s AND CAST(mm.message_id AS BINARY) = CAST(%s AS BINARY))")
            params.extend((mid, mid, message_id, message_id))
        execute("SELECT mm.meeting_id, mm.message_id, CASE WHEN OCTET_LENGTH(CAST(mm.legacy_raw AS CHAR CHARACTER SET utf8mb4)) <= 131072 THEN mm.legacy_raw ELSE NULL END"
            " FROM clrs_staging.meeting_messages AS mm WHERE " + " OR ".join(predicates)
            + " LIMIT %s FOR SHARE OF mm", (*params, len(keys)))
        proof = {}
        for row in cursor.fetchall():
            if not isinstance(row, (tuple, list)) or len(row) != 3 or tuple(row[:2]) not in keys or tuple(row[:2]) in proof:
                raise RuntimeUnavailable()
            proof[tuple(row[:2])] = row[2]
        if len(proof) != len(keys): raise RuntimeUnavailable()
        for item in items:
            key = (meeting_id, item["messageId"])
            if key in proof: authority.message(item, proof[key])
    return items


class RuntimeImportedMeetingsService(RuntimeMeetingsService):
    def __init__(self, store, cursor_key, *, authority, reviewed_binding, clock=time.time):
        if type(authority) is not ImportedMeetingAuthority or reviewed_binding is None: raise RuntimeUnavailable()
        authority.require(reviewed_binding)
        super().__init__(store, cursor_key, trusted_policy=TRUSTED_POLICY, clock=clock)
        self._authority = authority

    def _read_policy(self):
        self._authority.require()
        return self._authority.fingerprint

    def _meeting_rows(self, cursor, execute, sources):
        self._authority.require()
        rows = []
        for source in sources:
            # Native row parsing remains unchanged. Imported schedules are only
            # adopted after exact source proof, never native-marker fabrication.
            values = list(source)
            if len(values) == len(MEETING_FIELDS) and self._authority.reviewed(values[0]):
                values[MEETING_FIELDS.index("trusted")] = 0
            rows.append(_meeting_row(values))
        keys = [(row["meetingId"],) for row in rows if self._authority.reviewed(row["meetingId"])]
        proof = _proofs(cursor, execute, keys)
        return [self._authority.meeting(row, proof.get((row["meetingId"],))) for row in rows]

    def _member_rows(self, cursor, execute, sources):
        rows = []
        for source in sources:
            values = list(source)
            if len(values) == len(MEMBER_FIELDS) and self._authority.reviewed(values[0]):
                values[MEMBER_FIELDS.index("trusted")] = 0
            rows.append(_member_row(values))
        keys = [(row["meetingId"], row["uid"]) for row in rows if self._authority.reviewed(row["meetingId"])]
        proof = _proofs(cursor, execute, keys, member=True)
        return [self._authority.member(row, proof.get((row["meetingId"], row["uid"]))) for row in rows]

    def _read_actor_members(self, cursor, execute, meeting_ids, uid):
        if not meeting_ids: return {}
        sql, params = actor_members_query(meeting_ids, uid)
        execute(sql, params); sources = cursor.fetchall()
        if len(sources) > len(meeting_ids): raise RuntimeUnavailable()
        result = {}
        for row in self._member_rows(cursor, execute, sources):
            if row["uid"] != uid or row["meetingId"] not in meeting_ids or row["meetingId"] in result:
                raise RuntimeUnavailable()
            result[row["meetingId"]] = row
        return result

    def _eligible(self, row, actor, profiles, member, now, *, participants=False):
        if self._authority.kicked(row["meetingId"], actor.uid): return False
        return super()._eligible(row, actor, profiles, member, now, participants=participants)

    def _read(self, method, *args, **kwargs):
        self._authority.require()
        result = method(*args, **kwargs)
        self._authority.require()
        return result

    def meetings(self, *args, **kwargs):
        return self._read(super().meetings, *args, **kwargs)

    def meeting(self, *args, **kwargs):
        return self._read(super().meeting, *args, **kwargs)

    def participants(self, *args, **kwargs):
        return self._read(super().participants, *args, **kwargs)

    def _deny(self, identity, access_token):
        def action(cursor, execute, uid): raise RuntimeReadRejected()
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def messages(self, identity, meeting_id, *, access_token, **kwargs):
        if self._authority.reviewed(meeting_id) and "messages" not in (self._authority.entry(meeting_id) or {}):
            return self._deny(identity, access_token)
        return self._read(super().messages, identity, meeting_id, access_token=access_token, **kwargs)

    def archived_messages(self, identity, meeting_id, *, access_token, **kwargs):
        if self._authority.reviewed(meeting_id) and "messages" not in (self._authority.entry(meeting_id) or {}):
            return self._deny(identity, access_token)
        return self._read(super().archived_messages, identity, meeting_id, access_token=access_token, **kwargs)


def imported_meetings_factory(authority=None, *, reviewed_binding=None):
    """Unwired assembler seam; env alone cannot supply imported authority.

    The caller owns the same current transaction store, grants and close/drain.
    Missing proof stays closed. Construction performs source-only verification.
    """
    if authority is None: return lambda store, env: None
    if type(authority) is not ImportedMeetingAuthority or reviewed_binding is None: raise RuntimeUnavailable()
    authority.require(reviewed_binding)
    def create(store, env):
        if (env.get("CLRS_RUNTIME_WRITES_ENABLED") != "1"
                or env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") != "canonical-current-v1"):
            return None
        return RuntimeImportedMeetingsService(store,
            decode_base64(env.get("CLRS_LEGACY_READ_CURSOR_KEY_B64"), max_bytes=32),
            authority=authority, reviewed_binding=reviewed_binding)
    return create
