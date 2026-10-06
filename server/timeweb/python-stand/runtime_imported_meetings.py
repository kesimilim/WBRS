"""Opt-in imported list/detail/roster only. No chat or mutation authority."""
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
        if self._authority.reviewed(meeting_id): return self._deny(identity, access_token)
        return super().messages(identity, meeting_id, access_token=access_token, **kwargs)

    def archived_messages(self, identity, meeting_id, *, access_token, **kwargs):
        if self._authority.reviewed(meeting_id): return self._deny(identity, access_token)
        return super().archived_messages(identity, meeting_id, access_token=access_token, **kwargs)


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
