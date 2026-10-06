"""Own current profile reads, edits and test completion under native authority.

The mutation store revalidates the access token in the same transaction. This
module does not modify the retained Firebase archive, roles, balance or media.
Field/geography edits preserve onboarding; explicit test completion changes only the
current group, canonical test result and completion flag. Updated-at CAS prevents one device from
silently overwriting another device's edit; an operation receipt handles an
uncertain response without a second mutation.
"""
from __future__ import annotations

from datetime import datetime
import re

from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, canonical_json
from runtime_geography import resolve_geography


class ProfileEditInvalid(ValueError):
    pass


PROFILE_EDIT_OPERATION = "profile.edit.v1"
PROFILE_TEST_OPERATION = "profile.complete-test.v1"
PROFILE_GEOGRAPHY_OPERATION = "profile.edit-geography.v1"
_SCORES = ("brown", "red", "blue", "white")
_STAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z")
_FIELDS = {
    "fullName": "full_name", "age": "age", "rost": "height_cm",
    "about": "about_text", "hobbi": "interests_text", "deti": "has_children",
    "pol": "gender", "relationStatus": "relationship_status",
}
_SELECT = """SELECT full_name, age, height_cm, about_text, interests_text,
 has_children, gender, relationship_status, profile_details_saved,
 registration_complete, DATE_FORMAT(updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')
 FROM clrs_staging.profiles WHERE uid = %s LIMIT 1 FOR UPDATE"""

# Current projection maps the exact legacy `группа` to primary_group. Keep the
# accepted cases local: importing a snapshot reader would mix authorities.
_CURRENT_GROUPS = frozenset({
    "коричнево-красная", "коричнево-синяя", "коричневая", "коричнево-белая",
    "бело-коричневая", "бело-красная", "бело-синяя", "белая", "сине-белая",
    "красно-синяя", "красно-белая", "красная", "красно-коричневая", "синяя",
    "сине-коричневая", "сине-красная",
})
_FULL_FIELDS = {
    **_FIELDS, "country": "country", "countryCode": "country_code",
    "region": "region", "city": "city", "languageCode": "language_code",
    "primaryGroup": "primary_group", "secondaryGroup": "secondary_group",
    "profileDetailsSaved": "profile_details_saved",
    "isRegistrationEnd": "registration_complete",
}
_FULL_TEXT_LIMITS = {
    "fullName": 1000, "about": 4096, "hobbi": 4096, "pol": 191,
    "relationStatus": 191, "country": 191, "countryCode": 191,
    "region": 191, "city": 191, "languageCode": 191,
    "primaryGroup": 191, "secondaryGroup": 191,
}


def _full_select():
    # TEXT/LONGTEXT values are bounded before crossing the SQL connector. The
    # extra validity bit distinguishes a real SQL NULL from oversized content.
    columns = []
    valid = []
    for name, column in _FULL_FIELDS.items():
        if name in _FULL_TEXT_LIMITS:
            maximum = _FULL_TEXT_LIMITS[name]
            predicate = (f"({column} IS NULL OR (CHAR_LENGTH({column}) <= {maximum}"
                         f" AND OCTET_LENGTH({column}) <= {maximum * 4}))")
            columns.append(f"CASE WHEN {predicate} THEN {column} ELSE NULL END")
            valid.append(predicate)
        else:
            columns.append(column)
    columns.append("DATE_FORMAT(updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')")
    columns.append("(" + " AND ".join(valid) + ")")
    return ("SELECT " + ",\n ".join(columns) +
            " FROM clrs_staging.profiles WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)"
            " LIMIT 1 FOR SHARE")


_FULL_SELECT = _full_select()


def _legacy_details_proof_select():
    # The importer alone retains the original Firestore typed fields here;
    # native registration starts with {} and edit8 cannot write this archive.
    # Return only one bounded Boolean, while the own profile UPDATE lock is
    # held. Do not put retained content in the current public profile decoder.
    predicates = []
    # Exact Python str.strip whitespace, including U+001C..U+001F which a
    # SQL TRIM or an ICU whitespace class would not necessarily remove.
    whitespace = ("\t\n\v\f\r\x1c\x1d\x1e\x1f \x85\xa0\u1680"
                  "\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a"
                  "\u2028\u2029\u202f\u205f\u3000")
    nonblank = ("[^" + whitespace + "]").encode("utf-8").hex()
    for name, maximum in (("fullName", 1000), ("pol", 191), ("about", 4096), ("hobbi", 4096)):
        field = f"JSON_EXTRACT(legacy_raw, '$.fields.{name}')"
        scalar = f"JSON_EXTRACT(legacy_raw, '$.fields.{name}.stringValue')"
        value = f"JSON_UNQUOTE({scalar})"
        present = (f"REGEXP_LIKE({value}, CONVERT(0x{nonblank} USING utf8mb4), 'c')"
                   if name == "fullName" else f"CHAR_LENGTH({value}) > 0")
        predicates.append(
            f"CASE WHEN JSON_TYPE({field}) = 'OBJECT' AND JSON_LENGTH({field}) = 1"
            f" AND JSON_TYPE({scalar}) = 'STRING' AND CHAR_LENGTH({value}) <= {maximum}"
            f" AND OCTET_LENGTH({value}) <= {maximum * 4} THEN {present} ELSE 0 END")
    age = "JSON_EXTRACT(legacy_raw, '$.fields.age')"
    forms = []
    for tag in ("integerValue", "stringValue"):
        scalar = f"JSON_EXTRACT(legacy_raw, '$.fields.age.{tag}')"
        value = f"JSON_UNQUOTE({scalar})"
        forms.append(
            f"CASE WHEN JSON_TYPE({scalar}) = 'STRING' AND CHAR_LENGTH({value}) BETWEEN 1 AND 3"
            f" AND NOT REGEXP_LIKE({value}, '[^0-9]', 'c')"
            f" THEN CAST({value} AS UNSIGNED) <= 150 ELSE 0 END")
    number = "JSON_EXTRACT(legacy_raw, '$.fields.age.doubleValue')"
    # MySQL JSON permits only finite numeric values. JSON_TYPE rejects a
    # string NaN/Infinity or numeric-looking string before the numeric CAST.
    forms.append(f"CASE WHEN JSON_TYPE({number}) IN ('INTEGER', 'DOUBLE')"
                 f" THEN CAST(JSON_UNQUOTE({number}) AS DOUBLE) BETWEEN 0 AND 150 ELSE 0 END")
    predicates.append(f"(JSON_TYPE({age}) = 'OBJECT' AND JSON_LENGTH({age}) = 1"
                      " AND (" + " OR ".join(forms) + "))")
    return ("SELECT COALESCE((JSON_TYPE(legacy_raw) = 'OBJECT'"
            " AND JSON_TYPE(JSON_EXTRACT(legacy_raw, '$.fields')) = 'OBJECT' AND "
            + " AND ".join(predicates) + "), 0) FROM clrs_staging.profiles"
            " WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE")


_LEGACY_DETAILS_PROOF = _legacy_details_proof_select()


def _full_profile(row):
    if (not isinstance(row, (tuple, list)) or len(row) != len(_FULL_FIELDS) + 2
            or type(row[-1]) is not int or row[-1] != 1):
        raise RuntimeUnavailable()
    result = dict(zip(_FULL_FIELDS, row))
    for name, maximum in _FULL_TEXT_LIMITS.items():
        value = result[name]
        if value is None:
            continue
        if (not isinstance(value, str) or len(value) > maximum
                or any((ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127
                       or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
            raise RuntimeUnavailable()
        try:
            if len(value.encode("utf-8")) > maximum * 4:
                raise RuntimeUnavailable()
        except UnicodeError:
            raise RuntimeUnavailable() from None
    for name, maximum in (("age", 130), ("rost", 300)):
        value = result[name]
        if value is not None and (type(value) is not int or not 0 <= value <= maximum):
            raise RuntimeUnavailable()
    for name in ("deti", "profileDetailsSaved", "isRegistrationEnd"):
        value = result[name]
        if value is not None and (type(value) is not int or value not in (0, 1)):
            raise RuntimeUnavailable()
        result[name] = None if value is None else bool(value)
    try:
        result["updatedAt"] = _stamp(row[-2])
    except ProfileEditInvalid:
        raise RuntimeUnavailable() from None
    return result


def _has_profile_details(profile):
    return (profile["fullName"] is not None and bool(profile["fullName"].strip())
            and profile["age"] is not None
            and all(profile[name] is not None and profile[name] != ""
                    for name in ("pol", "about", "hobbi")))


def _full_onboarding(profile):
    if profile is None:
        return "registration"
    primary = profile["primaryGroup"]
    if (profile["isRegistrationEnd"] is True
            or (primary is not None and primary.strip().lower() in _CURRENT_GROUPS)):
        return "search"
    if profile["profileDetailsSaved"] is True or _has_profile_details(profile):
        return "test"
    return "registration"


def _stamp(value):
    if not isinstance(value, str) or _STAMP.fullmatch(value) is None:
        raise ProfileEditInvalid()
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        raise ProfileEditInvalid() from None
    return value


def _text(value, minimum, maximum, *, multiline):
    if not isinstance(value, str):
        raise ProfileEditInvalid()
    value = value.strip()
    if (not minimum <= len(value) <= maximum
            or any((ord(c) < 32 and (not multiline or c not in "\n\r\t"))
                   or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise ProfileEditInvalid()
    return value


def validate_profile_edit(payload):
    if (type(payload) is not dict or set(payload) != {"expectedUpdatedAt", "changes"}
            or type(payload["changes"]) is not dict
            or not payload["changes"] or set(payload["changes"]) - _FIELDS.keys()):
        raise ProfileEditInvalid()
    expected = _stamp(payload["expectedUpdatedAt"])
    changes = {}
    for name in sorted(payload["changes"]):
        value = payload["changes"][name]
        if name == "deti":
            if type(value) is not bool:
                raise ProfileEditInvalid()
        elif name in {"age", "rost"}:
            lower, upper = (18, 100) if name == "age" else (1, 300)
            if type(value) is not int or not lower <= value <= upper:
                raise ProfileEditInvalid()
        else:
            minimum, maximum = (20, 4096) if name in {"about", "hobbi"} else (
                (1, 1000) if name == "fullName" else (1, 191))
            value = _text(value, minimum, maximum, multiline=name in {"about", "hobbi"})
        changes[name] = value
    return {"expectedUpdatedAt": expected, "changes": changes}


def validate_temperament(payload):
    if (type(payload) is not dict or set(payload) != {"expectedUpdatedAt", "scores"}
            or type(payload["scores"]) is not dict or set(payload["scores"]) != set(_SCORES)
            or any(type(value) is not int or not 0 <= value <= 20
                   for value in payload["scores"].values())
            or sum(payload["scores"].values()) < 20):
        raise RuntimeInvalidRequest()
    try:
        expected = _stamp(payload["expectedUpdatedAt"])
    except ProfileEditInvalid:
        raise RuntimeInvalidRequest() from None
    return {"expectedUpdatedAt": expected,
            "scores": {name: payload["scores"][name] for name in _SCORES}}


def validate_geography(payload):
    if type(payload) is not dict or set(payload) != {"expectedUpdatedAt", "changes"}:
        raise RuntimeInvalidRequest()
    try:
        expected = _stamp(payload["expectedUpdatedAt"])
    except ProfileEditInvalid:
        raise RuntimeInvalidRequest() from None
    return {"expectedUpdatedAt": expected, "geography": resolve_geography(payload["changes"])}


def _temperament(scores):
    # Exact existing temperament.dart order. Max ties resolve white > blue >
    # red > brown. Secondary ties have a different order for each primary.
    maximum = max(scores.values())
    second = max((value for value in scores.values() if value != maximum), default=0)
    primary = next(name for name in ("white", "blue", "red", "brown") if scores[name] == maximum)
    secondary_order = {"brown": ("white", "blue", "red"),
        "red": ("white", "blue", "brown"), "blue": ("white", "brown", "red"),
        "white": ("brown", "blue", "red")}
    pure = {"brown": "коричневая", "red": "красная", "blue": "синяя", "white": "белая"}
    prefix = {"brown": "коричнево", "red": "красно", "blue": "сине", "white": "бело"}
    if second == 0:
        return pure[primary]
    secondary = next(name for name in secondary_order[primary] if scores[name] == second)
    return prefix[primary] + "-" + pure[secondary]


def _profile(row):
    if not isinstance(row, (tuple, list)) or len(row) != 11:
        raise ProfileEditInvalid()
    result = dict(zip(_FIELDS, row[:8]))
    # Source absence is retained. bool conversion must not interpret a malformed
    # string or an unknown status as completed registration.
    for index in (5, 8, 9):
        if row[index] is not None and (type(row[index]) is not int or row[index] not in (0, 1)):
            raise ProfileEditInvalid()
    result["deti"] = None if row[5] is None else bool(row[5])
    result["profileDetailsSaved"] = None if row[8] is None else bool(row[8])
    result["isRegistrationEnd"] = None if row[9] is None else bool(row[9])
    result["updatedAt"] = _stamp(row[10])
    return result


class RuntimeProfileService:
    def __init__(self, store):
        self._store = store

    def read_full(self, identity, *, access_token):
        def action(cursor, execute, uid):
            execute(_FULL_SELECT, (uid, uid))
            row = cursor.fetchone()
            profile = None if row is None else _full_profile(row)
            return {"uid": uid, "profileExists": row is not None,
                    "profile": profile, "onboarding": _full_onboarding(profile),
                    "profileAuthority": "canonical-current-v1", "mediaReady": False}
        try:
            return self._store.read_authenticated(identity, action, access_token=access_token)
        except RuntimeInvalidRequest:
            # This GET accepts no JSON input. A store serialization/budget error
            # is unavailable server content rather than a malformed request.
            raise RuntimeUnavailable() from None

    def read_for_edit(self, identity, *, access_token):
        def action(cursor, execute, uid):
            # SHARE locks are compatible with the primitive's READ ONLY
            # transaction; the edit route obtains its own exclusive lock.
            execute(_SELECT.replace("FOR UPDATE", "FOR SHARE"), (uid,))
            row = cursor.fetchone()
            return {"uid": uid, "profile": None if row is None else _profile(row),
                    "profileExists": row is not None,
                    "profileAuthority": "canonical-current-v1",
                    "editableFields": list(_FIELDS)}
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def complete_test(self, identity, operation_id, payload, *, access_token):
        checked = validate_temperament(payload)
        request = {"expectedUpdatedAt": payload["expectedUpdatedAt"], "scores": dict(payload["scores"])}
        primary = _temperament(checked["scores"])
        test_result = canonical_json({"scores": checked["scores"], "primaryGroup": primary}).decode()
        select = _FULL_SELECT.replace("FOR SHARE", "FOR UPDATE")

        def action(cursor, execute, uid):
            execute(select, (uid, uid))
            row = cursor.fetchone()
            if row is None:
                return 404, {"error": "profile_not_found"}, None
            before = _full_profile(row)
            if before["updatedAt"] != checked["expectedUpdatedAt"]:
                return 409, {"error": "profile_changed", "updatedAt": before["updatedAt"]}, None
            if _full_onboarding(before) == "search":
                return 409, {"error": "test_already_completed", "updatedAt": before["updatedAt"]}, None
            if not _has_profile_details(before):
                return 409, {"error": "profile_incomplete"}, None
            if before["profileDetailsSaved"] is not True:
                execute(_LEGACY_DETAILS_PROOF, (uid, uid))
                proof = cursor.fetchone()
                if (not isinstance(proof, (tuple, list)) or len(proof) != 1
                        or type(proof[0]) is not int or proof[0] not in (0, 1)):
                    raise RuntimeUnavailable()
                if proof[0] != 1:
                    return 409, {"error": "profile_incomplete"}, None
            execute("""UPDATE clrs_staging.profiles SET primary_group = %s,
 test_result = %s, registration_complete = 1,
 updated_at = GREATEST(UTC_TIMESTAMP(6), updated_at + INTERVAL 1 MICROSECOND)
 WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)
 AND updated_at = CAST(%s AS DATETIME(6))""",
                (primary, test_result, uid, uid, checked["expectedUpdatedAt"][:-1].replace("T", " ")))
            if cursor.rowcount != 1:
                raise RuntimeUnavailable()
            execute(select, (uid, uid))
            after = _full_profile(cursor.fetchone())
            if (after["primaryGroup"] != primary or after["isRegistrationEnd"] is not True
                    or after["updatedAt"] <= before["updatedAt"]
                    or any(after[name] != value for name, value in before.items()
                           if name not in {"primaryGroup", "isRegistrationEnd", "updatedAt"})):
                raise RuntimeUnavailable()
            # Verify the written JSON without returning its raw contents.
            execute("""SELECT JSON_TYPE(test_result), JSON_LENGTH(test_result),
 (test_result = CAST(%s AS JSON)) FROM clrs_staging.profiles
 WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE""",
                (test_result, uid, uid))
            proof = cursor.fetchone()
            if (not isinstance(proof, (tuple, list)) or len(proof) != 3 or proof[0] != "OBJECT"
                    or type(proof[1]) is not int or proof[1] != 2
                    or type(proof[2]) is not int or proof[2] != 1):
                raise RuntimeUnavailable()
            return 200, {"uid": uid, "primaryGroup": primary, "isRegistrationEnd": True,
                         "onboarding": "search", "updatedAt": after["updatedAt"],
                         "profileAuthority": "canonical-current-v1"}, None

        return self._store.mutate(identity, PROFILE_TEST_OPERATION, operation_id,
                                  request, action, access_token=access_token)

    def reconcile_test(self, identity, operation_id, payload, *, access_token):
        validate_temperament(payload)
        request = {"expectedUpdatedAt": payload["expectedUpdatedAt"], "scores": dict(payload["scores"])}
        return self._store.lookup(identity, PROFILE_TEST_OPERATION, operation_id,
                                  payload=request, access_token=access_token)

    def edit_geography(self, identity, operation_id, payload, *, access_token):
        checked = validate_geography(payload)
        request = {"expectedUpdatedAt": payload["expectedUpdatedAt"], "changes": dict(payload["changes"])}
        geography = checked["geography"]
        select = _FULL_SELECT.replace("FOR SHARE", "FOR UPDATE")

        def action(cursor, execute, uid):
            execute(select, (uid, uid))
            row = cursor.fetchone()
            if row is None:
                return 404, {"error": "profile_not_found"}, None
            before = _full_profile(row)
            if before["updatedAt"] != checked["expectedUpdatedAt"]:
                return 409, {"error": "profile_changed", "updatedAt": before["updatedAt"]}, None
            if not (_full_onboarding(before) == "search"
                    or (before["profileDetailsSaved"] is True and _has_profile_details(before))):
                return 409, {"error": "profile_not_ready"}, None
            changed = any(before[name] != value for name, value in geography.items())
            if changed:
                execute("""UPDATE clrs_staging.profiles SET country = %s, country_code = %s,
 region = %s, updated_at = GREATEST(UTC_TIMESTAMP(6), updated_at + INTERVAL 1 MICROSECOND)
 WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)
 AND updated_at = CAST(%s AS DATETIME(6))""",
                    (geography["country"], geography["countryCode"], geography["region"], uid, uid,
                     checked["expectedUpdatedAt"][:-1].replace("T", " ")))
                if cursor.rowcount != 1:
                    raise RuntimeUnavailable()
            execute(select, (uid, uid))
            after = _full_profile(cursor.fetchone())
            if (any(after[name] != value for name, value in geography.items())
                    or (changed and after["updatedAt"] <= before["updatedAt"])
                    or (not changed and after["updatedAt"] != before["updatedAt"])
                    or any(after[name] != value for name, value in before.items()
                           if name not in {"country", "countryCode", "region", "updatedAt"})
                    or _full_onboarding(after) != _full_onboarding(before)):
                raise RuntimeUnavailable()
            return 200, {"uid": uid, **geography, "updatedAt": after["updatedAt"],
                         "profileAuthority": "canonical-current-v1"}, None

        return self._store.mutate(identity, PROFILE_GEOGRAPHY_OPERATION, operation_id,
                                  request, action, access_token=access_token)

    def reconcile_geography(self, identity, operation_id, payload, *, access_token):
        validate_geography(payload)
        request = {"expectedUpdatedAt": payload["expectedUpdatedAt"], "changes": dict(payload["changes"])}
        return self._store.lookup(identity, PROFILE_GEOGRAPHY_OPERATION, operation_id,
                                  payload=request, access_token=access_token)

    def edit(self, identity, operation_id, payload, *, access_token):
        checked = validate_profile_edit(payload)
        request = {"expectedUpdatedAt": payload["expectedUpdatedAt"],
                   "changes": dict(payload["changes"])}

        def action(cursor, execute, uid):
            execute(_SELECT, (uid,))
            before = cursor.fetchone()
            if before is None:
                return 404, {"error": "profile_not_found"}, None
            before_view = _profile(before)
            if before_view["updatedAt"] != checked["expectedUpdatedAt"]:
                return 409, {"error": "profile_changed", "updatedAt": before_view["updatedAt"]}, None
            # A true no-op keeps the revision rather than causing spurious CAS
            # failures on the second device. The receipt still completes.
            changed = {name: value for name, value in checked["changes"].items()
                       if before_view[name] != value}
            if changed:
                names = sorted(changed)
                assignments = ", ".join(_FIELDS[name] + " = %s" for name in names)
                execute("UPDATE clrs_staging.profiles SET " + assignments +
                        ", updated_at = GREATEST(UTC_TIMESTAMP(6), updated_at + INTERVAL 1 MICROSECOND)"
                        " WHERE uid = %s", tuple(changed[name] for name in names) + (uid,))
                if cursor.rowcount != 1:
                    raise ProfileEditInvalid()
            execute(_SELECT, (uid,))
            after = _profile(cursor.fetchone())
            if (any(after[name] != value for name, value in checked["changes"].items())
                    or (changed and after["updatedAt"] <= before_view["updatedAt"])
                    or after["profileDetailsSaved"] != before_view["profileDetailsSaved"]
                    or after["isRegistrationEnd"] != before_view["isRegistrationEnd"]):
                raise ProfileEditInvalid()
            return 200, {"uid": uid, "profile": after, "operationId": operation_id,
                         "profileAuthority": "canonical-current-v1"}, None

        return self._store.mutate(identity, PROFILE_EDIT_OPERATION, operation_id,
                                  request, action, access_token=access_token)

    def reconcile(self, identity, operation_id, payload, *, access_token):
        validate_profile_edit(payload)
        request = {"expectedUpdatedAt": payload["expectedUpdatedAt"],
                   "changes": dict(payload["changes"])}
        return self._store.lookup(identity, PROFILE_EDIT_OPERATION, operation_id,
                                  payload=request, access_token=access_token)
