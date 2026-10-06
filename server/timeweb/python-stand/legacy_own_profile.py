"""Default-off own full profile from retained users/{verified UID} only.

No HTTP route, registration, writes, public directory, role, financial field or
media promotion. Reuses the exact reviewed snapshot/account/readonly SQL gates.
"""
from __future__ import annotations

import re
import math

from legacy_conversation_discovery import LegacyConversationDiscoveryService

from legacy_conversation_read import (LegacyConversationReadService,
    LegacyReadRejected, LegacyReadUnavailable)
from legacy_conversation_payload import (LegacyInvalid, field, identifier,
    media_reference, text, timestamp_ns)

# Exact nonempty cases in Flutter core/utils/compatibility.dart. A different
# string never fabricates a completed questionnaire or a new compatibility.
GROUPS = frozenset({
    "коричнево-красная", "коричнево-синяя", "коричневая", "коричнево-белая",
    "бело-коричневая", "бело-красная", "бело-синяя", "белая", "сине-белая",
    "красно-синяя", "красно-белая", "красная", "красно-коричневая", "синяя",
    "сине-коричневая", "сине-красная",
})
TEXT_FIELDS = {
    "fullName": 1000, "country": 191, "countryCode": 20, "region": 1000,
    "city": 1000, "languageGroup": 191, "countrySegment": 191,
    "pol": 191, "about": 4096, "hobbi": 4096, "rost": 191,
    "relationStatus": 191,
}


def _value(fields, name, tag):
    value = field(fields, name, tag)
    # An explicit Firestore null is different from a malformed typed-null.
    if value is None and name in fields and "nullValue" not in fields[name]:
        raise LegacyInvalid()
    return value


def _string(fields, name, maximum=191, *, required=False):
    return text(_value(fields, name, "stringValue"), maximum, required=required)


def _boolean(fields, name):
    value = _value(fields, name, "booleanValue")
    if value is not None and type(value) is not bool:
        raise LegacyInvalid()
    return value


def _age(fields):
    value = fields.get("age")
    if value is None or (isinstance(value, dict) and set(value) == {"nullValue"}):
        return None
    if not isinstance(value, dict) or len(value) != 1:
        raise LegacyInvalid()
    if set(value) == {"doubleValue"}:
        number = value["doubleValue"]
        if type(number) not in {int, float} or not math.isfinite(number) or not 0 <= number <= 150:
            raise LegacyInvalid()
        return number  # Existing Flutter predicate accepts source numeric ages.
    if not set(value) <= {"integerValue", "stringValue"}:
        raise LegacyInvalid()
    raw = next(iter(value.values()))
    if not isinstance(raw, str) or re.fullmatch(r"[0-9]{1,3}", raw) is None:
        raise LegacyInvalid()
    age = int(raw)
    if not 0 <= age <= 150:
        raise LegacyInvalid()
    return age


def _preferences(fields):
    value = _value(fields, "notificationPreferences", "mapValue")
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) - {"fields"}:
        raise LegacyInvalid()
    source = value.get("fields", {})
    if not isinstance(source, dict):
        raise LegacyInvalid()
    # Never grant a capability through arbitrary source preference keys.
    return {name: _boolean(source, name) for name in ("messages", "meetings", "sound")}


def _onboarding(profile, unavailable):
    raw_group = profile["группа"]
    group = raw_group.strip().lower() if raw_group is not None else ""
    if profile["isRegistrationEnd"] is True or group in GROUPS:
        return "search"
    if profile["profileDetailsSaved"] is True:
        return "test"
    # The legacy fallback mirrors accountDestination's saved-details predicate;
    # malformed required optional content must not silently send an old user
    # back to registration. Missing fields remain truly missing.
    required = {"fullName", "age", "pol", "about", "hobbi"}
    if required.intersection(unavailable):
        raise LegacyReadUnavailable()
    if (profile["fullName"] is not None and profile["fullName"].strip()
            and profile["age"] is not None
            and all(profile[name] is not None and profile[name] != ""
                    for name in ("pol", "about", "hobbi"))):
        return "test"
    return "registration"


class LegacyOwnProfileService(LegacyConversationReadService):
    """Input is a verified Identity, never a target UID or caller-supplied path."""

    def own_profile(self, identity):
        def action(cursor, execute, uid, source, pin):
            parent = self._document(cursor, execute, "users/" + uid, optional=True)
            envelope = {"uid": uid, "profile": None, "onboarding": "registration",
                "profileExists": False, "sourceSnapshot": pin,
                "profileDocumentHash": None, "profileAuthority": "immutable-reviewed-snapshot",
                "accountAuthority": "active-local-account", "mediaReady": False,
                "readOnly": True, "unavailableFields": []}
            if parent is None:
                # Active imported Auth without a users document needs onboarding;
                # this read neither invents a profile nor creates an account.
                return envelope
            fields = parent[2]["fields"]
            try:
                if "uid" in fields and identifier(_string(fields, "uid", required=True), uid=True) != uid:
                    raise LegacyReadRejected()
                # Local active-account authority cannot revive a contradictory
                # retained deleted/blocked profile; malformed flags fail closed.
                status = _string(fields, "status", 191)
                registration_status = _string(fields, "registrationStatus", 191)
                deleted = _boolean(fields, "deleted")
                if deleted is True or status in {"deleted", "blocked"} or registration_status in {"deleted", "blocked"}:
                    raise LegacyReadRejected()
                if status not in {None, "", "active"}:
                    raise LegacyInvalid()
                completed = _boolean(fields, "isRegistrationEnd")
                saved = _boolean(fields, "profileDetailsSaved")
                group = _string(fields, "группа", 191)
                # Preserve the exact legacy field used by the current gate.
                # A source `group` alias alone does not assert legacy completion.
                group_alias = _string(fields, "group", 191)
            except LegacyInvalid:
                raise LegacyReadUnavailable() from None
            unavailable = []
            def optional(name, reader):
                try:
                    return reader()
                except LegacyInvalid:
                    unavailable.append(name)
                    return None
            profile = {"uid": uid, "status": status, "registrationStatus": registration_status,
                "deleted": deleted, "isRegistrationEnd": completed,
                "profileDetailsSaved": saved, "группа": group,
                "group": group if group is not None else group_alias}
            for name, maximum in TEXT_FIELDS.items():
                profile[name] = optional(name, lambda n=name, m=maximum: _string(fields, n, m))
            profile["age"] = optional("age", lambda: _age(fields))
            for name in ("deti", "online", "isUnVisible", "isUnvisible"):
                profile[name] = optional(name, lambda n=name: _boolean(fields, n))
            profile["notificationPreferences"] = optional("notificationPreferences", lambda: _preferences(fields))
            for name in ("lastOnlineTS", "unvisibleEnd"):
                def stamp(n=name):
                    value = _value(fields, n, "timestampValue")
                    if value is not None:
                        timestamp_ns(value)
                    return value
                profile[name] = optional(name, stamp)
            for name in ("profilePic", "profilePicThumb"):
                def media(n=name):
                    result = media_reference(_string(fields, n, 4096), bucket=source[2],
                        codec=self._codec, binding={"v": 1, "uid": uid, "source": pin,
                            "collection": "users", "parent": parent[3],
                            "purpose": "own-profile", "field": n}, now=int(self._clock()))
                    if result is not None and result.get("kind") == "bundled_gift":
                        return {"kind": "unavailable", "reason": "unmapped_profile_media"}
                    return result
                profile[name] = optional(name, media)
            envelope.update(profile=profile, profileExists=True,
                onboarding=_onboarding(profile, unavailable), profileDocumentHash=parent[3],
                unavailableFields=unavailable)
            return envelope
        return self._read(identity, action)


class LegacyReadApiService(LegacyOwnProfileService, LegacyConversationDiscoveryService):
    """One shared base/connector/codec for own profile and existing read routes."""
