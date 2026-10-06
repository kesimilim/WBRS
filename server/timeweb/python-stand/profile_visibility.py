"""Pure, fail-closed eligibility for a future authenticated people directory.

This is not an HTTP service or a public profile decoder. Inputs must come from
the same trusted current-account/session read. No email, raw source, identifier
or profile content is returned. See TIMEWEB_PROFILE_VISIBILITY.md for authority
and the difference between legacy search eligibility and native onboarding.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import re
from typing import Optional


@dataclass(frozen=True)
class VisibilityAccount:
    uid: str
    disabled: int
    lifecycle: str


@dataclass(frozen=True)
class CanonicalVisibility:
    uid: str
    profile_details_saved: int
    registration_complete: int
    invisible_until: Optional[str] = None


@dataclass(frozen=True)
class VisibilityDecision:
    visible: bool
    reason: str


class _Invalid(Exception):
    pass


_MAX_SOURCE_BYTES = 131_072
_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
_STAMP = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})"
                    r"(?:\.([0-9]{1,9}))?(Z|[+-][0-9]{2}:[0-9]{2})")
_LIFECYCLES = frozenset({"active", "blocked", "deleted"})


def _text(value, maximum=191):
    if (type(value) is not str or len(value) > maximum
            or any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise _Invalid()
    if len(value.encode("utf-8")) > maximum * 4:
        raise _Invalid()
    return value


def _uid(value):
    value = _text(value)
    if not value or value in {".", ".."} or "/" in value:
        raise _Invalid()
    return value


def _sql_bool(value):
    # bool is an int subclass; a decoder must not silently coerce source types.
    if type(value) is not int or value not in (0, 1):
        raise _Invalid()


def _account(value):
    if type(value) is not VisibilityAccount:
        raise _Invalid()
    _uid(value.uid); _sql_bool(value.disabled)
    if type(value.lifecycle) is not str or value.lifecycle not in _LIFECYCLES:
        raise _Invalid()


def _stamp_ns(value, *, offset_allowed=False):
    if type(value) is not str or len(value) > 35:
        raise _Invalid()
    match = _STAMP.fullmatch(value)
    if match is None or (not offset_allowed and match[3] != "Z"):
        raise _Invalid()
    try:
        date = datetime.strptime(match[1], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        offset = match[3]
        if offset != "Z":
            hours, minutes = int(offset[1:3]), int(offset[4:6])
            if hours > 23 or minutes > 59:
                raise _Invalid()
            delta = timedelta(hours=hours, minutes=minutes)
            date -= delta if offset[0] == "+" else -delta
        elapsed = date - _EPOCH
        return (elapsed.days * 86_400 + elapsed.seconds) * 1_000_000_000 + int((match[2] or "").ljust(9, "0"))
    except (ValueError, OverflowError):
        raise _Invalid() from None


def _now_ns(value):
    if type(value) is not datetime or value.tzinfo is None or value.utcoffset() is None:
        raise _Invalid()
    elapsed = value.astimezone(timezone.utc) - _EPOCH
    return (elapsed.days * 86_400 + elapsed.seconds) * 1_000_000_000 + elapsed.microseconds * 1000


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise _Invalid()
        result[key] = value
    return result


def _source(value):
    if type(value) in (str, bytes):
        if type(value) is bytes:
            value = value.decode("utf-8", "strict")
        if len(value.encode("utf-8")) > _MAX_SOURCE_BYTES:
            raise _Invalid()
        value = json.loads(value, object_pairs_hook=_pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(_Invalid()))
    if type(value) is not dict:
        raise _Invalid()
    encoded = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
    if len(encoded) > _MAX_SOURCE_BYTES:
        raise _Invalid()
    return value


def _typed(fields, name, tag):
    if name not in fields:
        return None
    value = fields[name]
    if type(value) is not dict or len(value) != 1:
        raise _Invalid()
    if set(value) == {"nullValue"} and value["nullValue"] is None:
        return None
    if set(value) != {tag}:
        raise _Invalid()
    result = value[tag]
    if tag == "booleanValue":
        if type(result) is not bool:
            raise _Invalid()
    else:
        _text(result)
    return result


def _legacy_fields(raw):
    if (set(raw) != {"fields", "createTime", "updateTime"}
            or type(raw["fields"]) is not dict
            or any(type(key) is not str for key in raw["fields"])):
        raise _Invalid()
    _stamp_ns(raw["createTime"]); _stamp_ns(raw["updateTime"])
    return raw["fields"]


def _legacy_end(fields):
    if "unvisibleEnd" not in fields:
        return None
    value = fields["unvisibleEnd"]
    if type(value) is not dict or len(value) != 1:
        raise _Invalid()
    if set(value) == {"nullValue"} and value["nullValue"] is None:
        return None
    if set(value) == {"timestampValue"}:
        return _stamp_ns(value["timestampValue"])
    if set(value) == {"stringValue"}:
        # Dart also accepts strings, but an unzoned local date is not UTC proof.
        return _stamp_ns(value["stringValue"], offset_allowed=True)
    raise _Invalid()


def evaluate_profile_visibility(*, target: VisibilityAccount, actor: VisibilityAccount,
        current_actor_uid: str, canonical: CanonicalVisibility, legacy_raw,
        origin: str, now: datetime) -> VisibilityDecision:
    """Return a bounded decision, never a profile or raw validation error.

    origin is a trusted reader's explicit 'legacy'/'native' classification, not
    a client option. A native classification requires the actual empty {} raw
    value and both canonical completion flags. Authorization, token revocation,
    paging/filtering and a redacted public DTO remain the future route's job.
    """
    def refuse(reason):
        return VisibilityDecision(False, reason)
    try:
        _account(actor); _uid(current_actor_uid)
        if actor.uid != current_actor_uid:
            return refuse("actor_changed")
        if actor.disabled != 0 or actor.lifecycle != "active":
            return refuse("actor_inactive")
        _account(target)
        if target.disabled != 0 or target.lifecycle != "active":
            return refuse("account_inactive")
        if type(canonical) is not CanonicalVisibility or canonical.uid != target.uid:
            return refuse("profile_identity_unavailable")
        _sql_bool(canonical.profile_details_saved); _sql_bool(canonical.registration_complete)
        current = _now_ns(now)
        end = None if canonical.invisible_until is None else _stamp_ns(canonical.invisible_until)
        if target.uid == actor.uid:
            return refuse("own_profile")
        raw = _source(legacy_raw)
        if type(origin) is not str or origin not in {"legacy", "native"}:
            return refuse("origin_unavailable")
        if origin == "native":
            if raw != {}:
                return refuse("origin_conflict")
            if canonical.profile_details_saved != 1 or canonical.registration_complete != 1:
                return refuse("native_incomplete")
            if end is not None and end > current:
                return refuse("temporarily_invisible")
            return VisibilityDecision(True, "visible")

        fields = _legacy_fields(raw)
        saved_uid = _typed(fields, "uid", "stringValue")
        if saved_uid is not None and (_uid(saved_uid) != target.uid):
            return refuse("source_identity_conflict")
        status = _typed(fields, "status", "stringValue")
        registration = _typed(fields, "registrationStatus", "stringValue")
        deleted = _typed(fields, "deleted", "booleanValue")
        upper = _typed(fields, "isUnVisible", "booleanValue")
        lower = _typed(fields, "isUnvisible", "booleanValue")
        source_end = _legacy_end(fields)
        if deleted is True or status == "deleted" or registration == "deleted":
            return refuse("source_deleted")
        if status == "blocked" or registration == "blocked":
            return refuse("source_blocked")
        # Firestore search has where('status', isEqualTo: 'active'). The importer
        # defaults an absent lifecycle to active; that is not directory proof.
        if status != "active":
            return refuse("source_status_unavailable")
        if registration not in (None, "", "active"):
            return refuse("source_registration_unavailable")
        if canonical.invisible_until is not None:
            # Current projection never maps visibility. A later canonical edit
            # needs an explicit authority contract; do not guess precedence.
            return refuse("visibility_authority_unmapped")
        if upper is True or lower is True:
            if source_end is None:
                return refuse("indefinitely_invisible")
            if source_end > current:
                return refuse("temporarily_invisible")
        return VisibilityDecision(True, "visible")
    except (_Invalid, ValueError, TypeError, UnicodeError, OverflowError, RecursionError):
        return refuse("malformed_visibility_input")
