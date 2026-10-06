"""Bounded current-account people reads. Retained raw is eligibility-only.

No write, public media URL, email, financial field or source content is returned.
The existing runtime store owns token revalidation, locks, TLS and the deadline.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import hmac
import os
import re
import time

from native_credentials import decode_base64, unique_json, CredentialUnavailable
from legacy_conversation_payload import OpaqueReferences, LegacyInvalid
from profile_visibility import (CanonicalVisibility, VisibilityAccount,
                                evaluate_profile_visibility)
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_reads import RuntimeReadRejected, _text, _timestamp
from runtime_chat import _identifier
from runtime_geography import _catalog


PEOPLE_ORDER = "last_online_at_desc_uid_binary_asc_null_last"
MAX_PAGE = 30
MAX_SCAN_ROWS = 128
SCAN_CHUNK = 32
MAX_SOURCE_BYTES = 131_072
MAX_PUBLIC_BYTES = 65_536
MAX_CURSOR_CHARS = 4096

# Exact getListOfGroup cases in Flutter core/utils/compatibility.dart. primary
# group is the retained combined string; never split it or invent an alias.
_BROWN = ("коричнево-красная", "коричнево-синяя", "коричневая", "коричнево-белая",
          "бело-коричневая", "бело-красная", "бело-синяя", "белая", "сине-белая")
_WHITE = ("коричнево-красная", "коричнево-синяя", "коричневая", "коричнево-белая",
          "сине-белая", "красно-коричневая")
COMPATIBLE_GROUPS = {
    "коричнево-красная": _BROWN, "коричнево-синяя": _BROWN, "коричневая": _BROWN,
    "красно-синяя": ("синяя", "сине-коричневая"),
    "красно-белая": ("синяя", "сине-коричневая"), "красная": ("синяя", "сине-коричневая"),
    "красно-коричневая": ("коричнево-белая", "сине-белая", "бело-коричневая",
                           "бело-красная", "бело-синяя", "белая"),
    "коричнево-белая": _BROWN + ("красно-коричневая",),
    "синяя": ("красная", "красно-белая", "сине-красная", "красно-синяя"),
    "сине-коричневая": ("красная", "красно-белая", "сине-красная", "красно-синяя"),
    "сине-белая": _BROWN[:-1] + ("красно-коричневая",),
    "сине-красная": ("синяя", "сине-коричневая"),
    "бело-красная": _WHITE, "бело-синяя": _WHITE,
    "белая": _WHITE, "бело-коричневая": _WHITE,
}

_TEXT_FIELDS = {
    "fullName": ("full_name", 1000), "about": ("about_text", 4096),
    "hobbi": ("interests_text", 4096), "pol": ("gender", 191),
    "relationStatus": ("relationship_status", 191), "country": ("country", 191),
    "countryCode": ("country_code", 191), "region": ("region", 191),
    "city": ("city", 191), "primaryGroup": ("primary_group", 191),
    "secondaryGroup": ("secondary_group", 191),
}
_SUMMARY_FIELDS = ("uid", "fullName", "age", "pol", "country", "countryCode",
                   "region", "city", "primaryGroup", "secondaryGroup", "lastOnlineAt")
ROW_FIELDS = ("uid", "disabled", "lifecycle", "profile_details_saved", "registration_complete",
              "invisible_until", "lastOnlineAt", "legacy_raw", "age", "rost", "deti",
              *_TEXT_FIELDS, "valid")


def _selection():
    columns = ["p.uid", "a.disabled", "a.lifecycle", "p.profile_details_saved", "p.registration_complete",
        "DATE_FORMAT(p.invisible_until, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')",
        "DATE_FORMAT(p.last_online_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')"]
    raw_valid = ("(JSON_TYPE(p.legacy_raw) = 'OBJECT' AND "
                 f"OCTET_LENGTH(CAST(p.legacy_raw AS CHAR CHARACTER SET utf8mb4)) <= {MAX_SOURCE_BYTES})")
    columns += [f"CASE WHEN {raw_valid} THEN p.legacy_raw ELSE NULL END", "p.age", "p.height_cm", "p.has_children"]
    valid = [raw_valid]
    for column, maximum in _TEXT_FIELDS.values():
        predicate = f"(p.{column} IS NULL OR (CHAR_LENGTH(p.{column}) <= {maximum} AND OCTET_LENGTH(p.{column}) <= {maximum * 4}))"
        columns.append(f"CASE WHEN {predicate} THEN p.{column} ELSE NULL END")
        valid.append(predicate)
    columns.append("(" + " AND ".join(valid) + ")")
    return "SELECT " + ",\n ".join(columns) + "\n FROM clrs_staging.profiles AS p JOIN clrs_staging.accounts AS a\n ON a.uid = p.uid AND CAST(a.uid AS BINARY) = CAST(p.uid AS BINARY)\n WHERE a.disabled = 0 AND a.lifecycle = 'active'"


_SELECT = _selection()
ACTOR_QUERY = """SELECT uid, disabled, lifecycle FROM clrs_staging.accounts
 WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE"""


def _uid(value):
    value = _identifier(value)
    if value in {".", ".."} or "/" in value:
        raise RuntimeInvalidRequest()
    return value


def _option_text(value):
    if (type(value) is not str or not 1 <= len(value) <= 191
            or any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise RuntimeInvalidRequest()
    if len(value.encode("utf-8")) > 764:
        raise RuntimeInvalidRequest()
    return value


def validate_people_filters(*, min_age=18, max_age=100, country_code=None,
        region=None, gender=None, compatible_group=None):
    if (type(min_age) is not int or type(max_age) is not int
            or not 18 <= min_age <= max_age <= 100):
        raise RuntimeInvalidRequest()
    country = None
    if country_code is not None:
        if type(country_code) is not str or re.fullmatch(r"[A-Z]{2}", country_code) is None:
            raise RuntimeInvalidRequest()
        selected = _catalog().get(country_code)
        if selected is None:
            raise RuntimeInvalidRequest()
        country = selected[0]
        if region is not None and _option_text(region) not in selected[1]:
            raise RuntimeInvalidRequest()
    elif region is not None:
        raise RuntimeInvalidRequest()
    if gender is not None and (type(gender) is not str or gender not in {"м", "ж"}):
        raise RuntimeInvalidRequest()
    if compatible_group is not None and (type(compatible_group) is not str or compatible_group not in COMPATIBLE_GROUPS):
        raise RuntimeInvalidRequest()
    return {"minAge": min_age, "maxAge": max_age, "countryCode": country_code,
            "country": country, "region": region, "pol": gender, "compatibleGroup": compatible_group}


def people_query(uid, filters, anchor=None):
    sql = _SELECT + " AND CAST(p.uid AS BINARY) <> CAST(%s AS BINARY) AND p.age BETWEEN %s AND %s"
    params = [uid, filters["minAge"], filters["maxAge"]]
    # Flutter queries the catalog country NAME. This also preserves matching of
    # legacy profiles whose canonical country_code is genuinely NULL.
    for key, column in (("country", "country"), ("region", "region"), ("pol", "gender")):
        if filters[key] is not None:
            sql += f" AND CAST(p.{column} AS BINARY) = CAST(%s AS BINARY)"
            params.append(filters[key])
    if filters["compatibleGroup"] is not None:
        groups = COMPATIBLE_GROUPS[filters["compatibleGroup"]]
        sql += " AND CAST(p.primary_group AS BINARY) IN (" + ",".join("CAST(%s AS BINARY)" for _ in groups) + ")"
        params.extend(groups)
    if anchor is not None:
        if anchor[0] is None:
            sql += " AND p.last_online_at IS NULL AND CAST(p.uid AS BINARY) > CAST(%s AS BINARY)"
            params.append(anchor[1])
        else:
            sql += """ AND (p.last_online_at < CAST(%s AS DATETIME(6))
 OR (p.last_online_at = CAST(%s AS DATETIME(6)) AND CAST(p.uid AS BINARY) > CAST(%s AS BINARY))
 OR p.last_online_at IS NULL)"""
            stamp = anchor[0][:-1].replace("T", " ")
            params.extend((stamp, stamp, anchor[1]))
    sql += " ORDER BY p.last_online_at DESC, CAST(p.uid AS BINARY) ASC LIMIT %s FOR SHARE OF p, a"
    params.append(SCAN_CHUNK)
    return sql, tuple(params)


def person_query(uid):
    return (_SELECT + " AND p.uid = %s AND CAST(p.uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE OF p, a", (uid, uid))


def _row(row):
    if not isinstance(row, (tuple, list)) or len(row) != len(ROW_FIELDS):
        raise RuntimeUnavailable()
    result = dict(zip(ROW_FIELDS, row))
    try:
        _uid(result["uid"])
        _timestamp(result["lastOnlineAt"], nullable=True)
    except (RuntimeInvalidRequest, RuntimeUnavailable):
        raise RuntimeUnavailable() from None
    return result


def _after(row, anchor):
    if anchor is None:
        return True
    if anchor[0] is None:
        return row["lastOnlineAt"] is None and row["uid"].encode("utf-8") > anchor[1].encode("utf-8")
    return (row["lastOnlineAt"] is None or row["lastOnlineAt"] < anchor[0]
            or (row["lastOnlineAt"] == anchor[0] and row["uid"].encode("utf-8") > anchor[1].encode("utf-8")))


def _decode_person(row, actor, now):
    if type(row["valid"]) is not int or row["valid"] != 1:
        return None
    raw = row["legacy_raw"]
    try:
        if type(raw) is bytes:
            if len(raw) > MAX_SOURCE_BYTES:
                return None
            raw = raw.decode("utf-8", "strict")
        if type(raw) is str:
            if len(raw.encode("utf-8")) > MAX_SOURCE_BYTES:
                return None
            raw = unique_json(raw)
        target = VisibilityAccount(row["uid"], row["disabled"], row["lifecycle"])
        canonical = CanonicalVisibility(row["uid"], row["profile_details_saved"],
            row["registration_complete"], row["invisible_until"])
        # Current native creation stores {}, and profile mutations retain raw.
        # No query/body parameter can select or erase this trusted SQL evidence.
        origin = "native" if type(raw) is dict and raw == {} else "legacy"
        decision = evaluate_profile_visibility(target=target, actor=actor,
            current_actor_uid=actor.uid, canonical=canonical, legacy_raw=raw, origin=origin, now=now)
        if not decision.visible:
            return None
        result = {"uid": row["uid"], "lastOnlineAt": row["lastOnlineAt"]}
        for field, (_, maximum) in _TEXT_FIELDS.items():
            result[field] = _text(row[field], maximum, nullable=True)
        for field, maximum in (("age", 130), ("rost", 300)):
            value = row[field]
            if value is not None and (type(value) is not int or not 0 <= value <= maximum):
                return None
            result[field] = value
        value = row["deti"]
        if value is not None and (type(value) is not int or value not in (0, 1)):
            return None
        result["deti"] = None if value is None else bool(value)
        result.update(avatar=None, mediaReady=False)
        return result
    except (CredentialUnavailable, RuntimeUnavailable, UnicodeError, ValueError, TypeError, RecursionError):
        return None


class RuntimePeopleService:
    def __init__(self, store, cursor_key, *, clock=time.time):
        if store is None or type(cursor_key) is not bytes or len(cursor_key) != 32:
            raise RuntimeUnavailable()
        self._store = store; self._clock = clock
        self._codec = OpaqueReferences(hmac.digest(cursor_key, b"clrs-runtime-current-people-cursor-v1\0", "sha256"))

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

    @staticmethod
    def _actor(cursor, execute, uid):
        execute(ACTOR_QUERY, (uid, uid)); row = cursor.fetchone()
        if (not isinstance(row, (tuple, list)) or len(row) != 3 or row[0] != uid
                or type(row[1]) is not int or row[1] not in (0, 1)
                or row[2] not in {"active", "blocked", "deleted"}):
            raise RuntimeUnavailable()
        if row[1] != 0 or row[2] != "active":
            raise RuntimeRejected()
        return VisibilityAccount(*row)

    def _cursor(self, value, uid, limit, digest):
        if value is None:
            return None
        try:
            if type(value) is not str or not 1 <= len(value) <= MAX_CURSOR_CHARS:
                raise RuntimeInvalidRequest()
            opened = self._codec.open("cursor", value)
            if (set(opened) != {"v", "uid", "purpose", "limit", "filterHash", "after", "exp"}
                    or type(opened["v"]) is not int or opened["v"] != 1
                    or opened["uid"] != uid or opened["purpose"] != PEOPLE_ORDER
                    or type(opened["limit"]) is not int or opened["limit"] != limit
                    or opened["filterHash"] != digest or type(opened["exp"]) is not int
                    or not int(self._clock()) < opened["exp"] <= int(self._clock()) + 300
                    or type(opened["after"]) is not list or len(opened["after"]) != 2):
                raise RuntimeInvalidRequest()
            anchor = opened["after"]
            _timestamp(anchor[0], nullable=True); _uid(anchor[1])
            return anchor
        except (LegacyInvalid, RuntimeUnavailable, RuntimeInvalidRequest):
            raise RuntimeInvalidRequest() from None

    def _next(self, uid, limit, digest, anchor):
        return self._codec.seal("cursor", {"v": 1, "uid": uid, "purpose": PEOPLE_ORDER,
            "limit": limit, "filterHash": digest, "after": list(anchor), "exp": int(self._clock()) + 300})

    @staticmethod
    def _page(items, next_cursor=None):
        return {"kind": "canonical-current", "ordering": PEOPLE_ORDER, "items": items,
                "nextCursor": next_cursor, "mediaReady": False}

    def people(self, identity, *, access_token, limit=30, cursor=None, **options):
        if type(limit) is not int or not 1 <= limit <= MAX_PAGE:
            raise RuntimeInvalidRequest()
        try:
            filters = validate_people_filters(**options)
        except TypeError:
            raise RuntimeInvalidRequest() from None
        digest = hashlib.sha256(canonical_json(filters)).hexdigest()
        def action(sql_cursor, execute, uid):
            anchor = self._cursor(cursor, uid, limit, digest)
            actor = self._actor(sql_cursor, execute, uid)
            now = datetime.fromtimestamp(self._clock(), timezone.utc)
            items = []; scanned = 0
            while scanned < MAX_SCAN_ROWS:
                sql, params = people_query(uid, filters, anchor)
                execute(sql, params); rows = sql_cursor.fetchall()
                if len(rows) > SCAN_CHUNK:
                    raise RuntimeUnavailable()
                for source in rows:
                    row = _row(source)
                    if not _after(row, anchor):
                        raise RuntimeUnavailable()
                    previous = anchor
                    anchor = (row["lastOnlineAt"], row["uid"]); scanned += 1
                    person = _decode_person(row, actor, now)
                    if person is not None:
                        summary = {field: person[field] for field in _SUMMARY_FIELDS}
                        summary.update(avatar=None, mediaReady=False)
                        packed = self._page([*items, summary], "x" * MAX_CURSOR_CHARS)
                        if len(items) == limit or len(canonical_json(packed, max_bytes=4 * 1024 * 1024)) > MAX_PUBLIC_BYTES:
                            if previous is None:
                                raise RuntimeUnavailable()
                            return self._page(items, self._next(uid, limit, digest, previous))
                        items.append(summary)
                    if scanned == MAX_SCAN_ROWS:
                        return self._page(items, self._next(uid, limit, digest, anchor))
                if len(rows) < SCAN_CHUNK:
                    return self._page(items)
            raise RuntimeUnavailable()
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def public_person(self, identity, target_uid, *, access_token):
        target_uid = _uid(target_uid)
        def action(cursor, execute, uid):
            actor = self._actor(cursor, execute, uid)
            sql, params = person_query(target_uid)
            execute(sql, params); rows = cursor.fetchall()
            if not rows:
                raise RuntimeReadRejected()
            if len(rows) != 1:
                raise RuntimeUnavailable()
            row = _row(rows[0])
            if row["uid"] != target_uid:
                raise RuntimeReadRejected()
            person = _decode_person(row, actor, datetime.fromtimestamp(self._clock(), timezone.utc))
            if person is None:
                raise RuntimeReadRejected()
            result = {"kind": "canonical-current", "profile": person, "mediaReady": False}
            try:
                canonical_json(result)
            except RuntimeInvalidRequest:
                raise RuntimeUnavailable() from None
            return result
        return self._store.read_authenticated(identity, action, access_token=access_token)
