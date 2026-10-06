"""Pure private proposals for reviewed imported root meeting documents.

No SQL, file/network/environment access, apply path or public serving authority.
Retained raw remains nonempty. A typed review pin is trusted caller evidence,
not evidence inferred from an archived document's existence or missing fields.
"""
from __future__ import annotations

from dataclasses import dataclass, asdict
from copy import deepcopy
from datetime import datetime
import hashlib
import json
import re

from legacy_conversation_payload import document, payload_digest, timestamp_ns, LegacyInvalid
from profile_visibility import VisibilityAccount
from runtime_geography import _decode_catalog, CATALOG_SHA256
from runtime_mutations import RuntimeUnavailable


SOURCE_CONTRACT = "reviewed-imported-meets-v1"
VISIBILITY_POLICY = "reviewed-imported-current-meetings-v1"
SOURCE_PROJECT = "chatapp-4e347"
SOURCE_DATABASE = "(default)"
MAX_MEMBERS = 1000
MAX_PLAN_BYTES = 2 * 1024 * 1024
_DIGEST = re.compile(r"[a-f0-9]{64}\Z")
_LOCAL_DATE = re.compile(r"([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4}) ([0-9]{1,2}):([0-9]{2})\Z")
_ROOT_FIELDS = frozenset({"name", "description", "admin", "type", "invitedUid",
    "invitedName", "inviterName", "users", "kicked", "usersWithoutNotification",
    "datetime", "timeStamp", "country", "countryCode", "region", "city",
    "recentMessage", "recentMessageSender", "recentMessageTime", "creationRequestId", "clientWriteReceipts",
    "imageUrl", "meetingImageUrl"})


class _Refusal(Exception):
    def __init__(self, reason):
        self.reason = reason


@dataclass(frozen=True, repr=False)
class SourceMeetingDocument:
    firebase_path: str
    encoded_payload: object
    payload_sha256: str
    archive_sha256: str
    project: str = SOURCE_PROJECT
    database: str = SOURCE_DATABASE


@dataclass(frozen=True, repr=False)
class MeetingSourceReviewPin:
    firebase_path: str
    payload_sha256: str
    archive_sha256: str
    source_contract: str
    complete_root_document: bool = False
    current_document_exists: bool | None = None
    current_payload_sha256: str | None = None
    missing_kicked_reviewed_as_empty: bool = False
    member_observed_at: str | None = None


@dataclass(frozen=True, repr=False)
class CurrentMeetingPerson:
    account: VisibilityAccount
    profile_uid: str
    profile_updated_at: str


@dataclass(frozen=True, repr=False)
class ProposedMeetingRow:
    meeting_id: str
    organizer_uid: str
    invited_uid: str | None
    kind: str
    title: str | None
    description: str | None
    country_code: str | None
    region: str | None
    starts_at: str | None
    created_at: str
    updated_at: str
    media_id: None
    creation_request_id: str | None
    revision: int
    deleted_at: None
    legacy_raw: str


@dataclass(frozen=True, repr=False)
class ProposedMeetingMemberRow:
    meeting_id: str
    uid: str
    joined_at: str
    left_at: None
    kicked_at: None
    membership_revision: int
    legacy_raw: str


@dataclass(frozen=True, repr=False)
class ImportedMeetingVisibilityPolicy:
    version: str
    source_contract: str
    firebase_path: str
    payload_sha256: str
    archive_sha256: str
    current_payload_sha256: str
    metadata_audience: str
    audience_uids: tuple[str, ...]
    active_uids: tuple[str, ...]
    kicked_uids: tuple[str, ...]
    not_current_member_uids: tuple[str, ...]
    canonical_people_pins: tuple[tuple[str, str], ...]
    geography_basis: str
    geography_catalog_sha256: str
    scheduled_local: str | None
    scheduled_basis: str
    member_observed_at: str
    scheduled_timezone: None = None
    require_current_account_profile: bool = True
    require_current_foreign_profile_visibility: bool = True
    require_current_root_and_provenance: bool = True
    membership_event_times_known: bool = False
    public_serving_enabled: bool = False


@dataclass(frozen=True, repr=False)
class ImportedMeetingReviewPlan:
    state: str
    reason: str
    meeting: ProposedMeetingRow | None = None
    members: tuple[ProposedMeetingMemberRow, ...] = ()
    visibility_policy: ImportedMeetingVisibilityPolicy | None = None
    fingerprint: str | None = None

    def summary(self):
        # UID/path/raw/profile and the source-local date must stay private.
        return {"state": self.state, "reason": self.reason,
                "proposedMeetings": int(self.meeting is not None), "proposedActiveMembers": len(self.members),
                "applyAllowed": False, "databaseWrites": 0, "httpEnabled": False,
                "scheduledUtcKnown": self.meeting is not None and self.meeting.starts_at is not None,
                "membershipEventTimesKnown": False}


def _sha(value):
    if type(value) is bytes and len(value) == 32:
        return value.hex()
    if type(value) is str and _DIGEST.fullmatch(value):
        return value
    raise _Refusal("invalid_digest")


def _text(value, maximum, *, controls=False):
    if (type(value) is not str or len(value) > maximum
            or any((ord(c) < 32 and (not controls or c not in "\n\r\t"))
                   or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise _Refusal("field_not_representable")
    if len(value.encode("utf-8")) > maximum * 4:
        raise _Refusal("field_not_representable")
    return value


def _uid(value):
    value = _text(value, 191)
    if not value or value in {".", ".."} or "/" in value:
        raise _Refusal("identifier_not_representable")
    return value


def _string(fields, name, maximum=191, *, required=False, controls=False):
    if name not in fields:
        if required:
            raise _Refusal("required_field_missing")
        return None
    value = fields[name]
    if type(value) is not dict or len(value) != 1:
        raise _Refusal("malformed_typed_field")
    if set(value) == {"nullValue"} and value["nullValue"] in (None, "NULL_VALUE"):
        if required:
            raise _Refusal("required_field_missing")
        return None
    if set(value) != {"stringValue"}:
        raise _Refusal("malformed_typed_field")
    result = _text(value["stringValue"], maximum, controls=controls)
    if required and not result:
        raise _Refusal("required_field_missing")
    return result


def _uids(fields, name, *, required=False):
    if name not in fields:
        if required:
            raise _Refusal("membership_unavailable")
        return None
    value = fields[name]
    if (type(value) is not dict or set(value) != {"arrayValue"}
            or type(value["arrayValue"]) is not dict
            or set(value["arrayValue"]) - {"values"}):
        raise _Refusal("malformed_membership")
    values = value["arrayValue"].get("values", [])
    if type(values) is not list or len(values) > MAX_MEMBERS:
        raise _Refusal("membership_bound_exceeded")
    result = []
    for item in values:
        if type(item) is not dict or set(item) != {"stringValue"}:
            raise _Refusal("malformed_membership")
        uid = _uid(item["stringValue"])
        if uid in result:
            raise _Refusal("duplicate_membership")
        result.append(uid)
    return tuple(sorted(result, key=lambda uid: uid.encode()))


def _sql_stamp(value):
    # SQL DATETIME(6) cannot faithfully hold a nonzero nanosecond remainder.
    ns = timestamp_ns(value)
    if ns % 1000:
        raise _Refusal("timestamp_not_representable")
    base = datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
    if base.year < 1000:
        raise _Refusal("timestamp_not_representable")
    fraction = value[20:-1] if "." in value else ""
    return value[:19] + "." + fraction.ljust(6, "0")[:6] + "Z"


def _scheduled_local(value):
    if value is None:
        return None
    match = _LOCAL_DATE.fullmatch(value)
    if match is None:
        raise _Refusal("scheduled_local_invalid")
    try:
        day, month, year, hour, minute = (int(part) for part in match.groups())
        datetime(year, month, day, hour, minute)
    except ValueError:
        raise _Refusal("scheduled_local_invalid") from None
    return value


def _schedule(fields):
    value = fields.get("datetime")
    if type(value) is dict and set(value) == {"timestampValue"}:
        # Both current Flutter meeting readers explicitly accept Timestamp.
        # This is actual UTC evidence, distinct from the local string form.
        return None, _sql_stamp(value["timestampValue"]), "source_timestamp_utc"
    local = _scheduled_local(_string(fields, "datetime", 100))
    return local, None, "unavailable" if local is None else "source_local_datetime_timezone_unknown"


def _source(record, pin):
    if type(record) is not SourceMeetingDocument or type(pin) is not MeetingSourceReviewPin:
        raise _Refusal("source_review_unavailable")
    if record.project != SOURCE_PROJECT or record.database != SOURCE_DATABASE:
        raise _Refusal("source_namespace_mismatch")
    if type(record.firebase_path) is not str or not record.firebase_path.startswith("meets/"):
        raise _Refusal("source_root_mismatch")
    meeting_id = _uid(record.firebase_path[6:])
    if record.firebase_path != "meets/" + meeting_id:
        raise _Refusal("source_root_mismatch")
    digest = _sha(record.payload_sha256); archive = _sha(record.archive_sha256)
    if (pin.firebase_path != record.firebase_path or _sha(pin.payload_sha256) != digest
            or _sha(pin.archive_sha256) != archive or pin.source_contract != SOURCE_CONTRACT):
        raise _Refusal("source_pin_mismatch")
    for value in (pin.complete_root_document, pin.missing_kicked_reviewed_as_empty):
        if type(value) is not bool:
            raise _Refusal("source_review_unavailable")
    if not pin.complete_root_document:
        raise _Refusal("source_completeness_unproven")
    if type(pin.current_document_exists) is not bool:
        raise _Refusal("deletion_unproven")
    if not pin.current_document_exists:
        raise _Refusal("source_deleted")
    if pin.current_payload_sha256 is None or _sha(pin.current_payload_sha256) != digest:
        raise _Refusal("current_source_changed")
    if pin.member_observed_at is None:
        raise _Refusal("member_observation_unproven")
    observed = _sql_stamp(pin.member_observed_at)
    if observed != pin.member_observed_at:
        raise _Refusal("member_observation_invalid")
    # Seal a private snapshot before hash validation. A caller changing its
    # input dictionary after validation cannot change the retained proposal.
    payload = deepcopy(document(record.encoded_payload))
    if payload_digest(payload) != digest:
        raise _Refusal("source_digest_mismatch")
    if timestamp_ns(observed) < timestamp_ns(payload["updateTime"]):
        raise _Refusal("member_observation_invalid")
    if set(payload["fields"]) - _ROOT_FIELDS:
        # Actual writer deletes physically; it has no meeting status/private/
        # hide/deleted flag. Unknown root fields are not guessed as harmless.
        raise _Refusal("unreviewed_root_field")
    return meeting_id, payload, digest, archive, observed


def _geography(fields, catalog_bytes):
    country = _string(fields, "country")
    code = _string(fields, "countryCode")
    region = _string(fields, "region")
    _string(fields, "city")  # retain as raw only; never use city as region
    if country is None and code is None:
        if region is not None:
            raise _Refusal("geography_unproven")
        return None, None, "unavailable"
    try:
        catalog = _decode_catalog(catalog_bytes)
    except RuntimeUnavailable:
        raise _Refusal("catalog_unavailable") from None
    basis = "source_country_code_exact"
    if code is None:
        matches = [candidate for candidate, (name, _) in catalog.items() if name == country]
        if len(matches) != 1:
            raise _Refusal("geography_unproven")
        code = matches[0]; basis = "source_country_name_catalog_exact"
    selected = catalog.get(code)
    if selected is None or (country is not None and country != selected[0]):
        raise _Refusal("geography_conflict")
    if region is not None and region not in selected[1]:
        raise _Refusal("geography_conflict")
    return code, region, basis


def _current_people(people, uids):
    if type(people) is not dict or len(people) > MAX_MEMBERS + 2:
        raise _Refusal("current_people_unavailable")
    pins = []
    for uid in sorted(set(uids), key=lambda uid: uid.encode()):
        person = people.get(uid)
        if (type(person) is not CurrentMeetingPerson or type(person.account) is not VisibilityAccount
                or person.account.uid != uid or person.profile_uid != uid
                or type(person.account.disabled) is not int or person.account.disabled != 0
                or person.account.lifecycle != "active"):
            raise _Refusal("current_person_inactive_or_missing")
        _uid(person.profile_uid)
        # Canonical profile timestamp pins identity/current projection, not a
        # public eligibility exemption. The later consumer must reread it.
        stamp = _sql_stamp(person.profile_updated_at)
        if stamp != person.profile_updated_at:
            raise _Refusal("current_profile_stamp_invalid")
        pins.append((uid, stamp))
    return tuple(pins)


def _opaque_fields(fields):
    # These actual read/writer fields remain private, but wrong typed wrappers
    # still must not slip into an otherwise "reviewed" root document.
    for name in ("invitedName", "inviterName", "creationRequestId", "recentMessageSender"):
        _string(fields, name)
    for name in ("imageUrl", "meetingImageUrl"):
        _string(fields, name, 4096)
    _string(fields, "recentMessage", 32768, controls=True)
    if "recentMessageTime" in fields:
        value = fields["recentMessageTime"]
        # Actual message writers use DateTime/Timestamp.toString(). This private
        # display cache is not a UTC creation/schedule/join timestamp authority.
        if type(value) is not dict or set(value) != {"stringValue"}:
            raise _Refusal("malformed_typed_field")
        _string(fields, "recentMessageTime", 191)
    if "timeStamp" in fields:
        value = fields["timeStamp"]
        if type(value) is not dict or set(value) != {"timestampValue"}:
            raise _Refusal("malformed_typed_field")
        _sql_stamp(value["timestampValue"])
    _uids(fields, "usersWithoutNotification")
    if "clientWriteReceipts" in fields:
        value = fields["clientWriteReceipts"]
        if (type(value) is not dict or set(value) != {"mapValue"}
                or type(value["mapValue"]) is not dict or set(value["mapValue"]) - {"fields"}):
            raise _Refusal("malformed_typed_field")
        receipts = value["mapValue"].get("fields", {})
        if type(receipts) is not dict or len(receipts) > MAX_MEMBERS:
            raise _Refusal("malformed_typed_field")
        for key, receipt in receipts.items():
            _uid(key)
            if type(receipt) is not dict or set(receipt) != {"booleanValue"} or type(receipt["booleanValue"]) is not bool:
                raise _Refusal("malformed_typed_field")


def review_imported_meeting(record, pin, people, *, catalog_bytes=None):
    """Return a private immutable proposal or a bounded refusal, never apply.

    The trusted caller must supply independently obtained complete/current root
    review evidence and current canonical account/profile identity rows. Missing
    evidence remains unknown. Inputs are never rewritten and no I/O is done.
    """
    try:
        meeting_id, payload, digest, archive, observed = _source(record, pin)
        fields = payload["fields"]
        organizer = _uid(_string(fields, "admin", required=True))
        source_kind = _string(fields, "type", required=True)
        if source_kind not in {"групповая", "индивидуальная"}:
            raise _Refusal("meeting_kind_unproven")
        kind = "group" if source_kind == "групповая" else "individual"
        invited = _string(fields, "invitedUid")
        if kind == "individual":
            invited = _uid(invited)
            if invited == organizer:
                raise _Refusal("individual_audience_conflict")
        elif invited is not None:
            # Even an empty invitee string is not silently rewritten to NULL.
            raise _Refusal("group_audience_conflict")
        users = _uids(fields, "users", required=True)
        kicked = _uids(fields, "kicked")
        if kicked is None:
            if not pin.missing_kicked_reviewed_as_empty:
                raise _Refusal("kick_absence_unproven")
            kicked = ()
        if set(users) & set(kicked):
            raise _Refusal("membership_conflict")
        if kind == "individual" and (set(users) | set(kicked)) - {organizer, invited}:
            raise _Refusal("individual_audience_conflict")
        canonical_pins = _current_people(people, (*users, organizer, *(() if invited is None else (invited,))))
        title = _string(fields, "name", 1000, controls=True)
        description = _string(fields, "description", 4096, controls=True)
        scheduled, starts, schedule_basis = _schedule(fields)
        code, region, geography_basis = _geography(fields, catalog_bytes)
        _opaque_fields(fields)
        created = _sql_stamp(payload["createTime"]); updated = _sql_stamp(payload["updateTime"])
        if timestamp_ns(payload["updateTime"]) < timestamp_ns(payload["createTime"]):
            raise _Refusal("source_time_conflict")
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        creation_request = _string(fields, "creationRequestId")
        if creation_request is not None:
            creation_request = _uid(creation_request)
        row = ProposedMeetingRow(meeting_id, organizer, invited, kind, title, description,
            code, region, starts, created, updated, None, creation_request, 0, None, raw)
        members = []
        for uid in users:
            provenance = json.dumps({"kind": "imported-root-meeting-member-proof-v1",
                "firebasePath": record.firebase_path, "payloadSha256": digest,
                "archiveSha256": archive, "uid": uid, "sourceField": "users",
                "sourceState": "active_at_reviewed_snapshot", "eventTimesKnown": False,
                "joinedAtBasis": "migration_first_observed", "memberObservedAt": observed,
                "historicalJoinedAt": None},
                ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            members.append(ProposedMeetingMemberRow(meeting_id, uid, observed, None, None, 0, provenance))
        audience = (organizer,) if invited is None else tuple(sorted((organizer, invited), key=lambda uid: uid.encode()))
        not_members = tuple(uid for uid in audience if uid not in users and uid not in kicked)
        policy = ImportedMeetingVisibilityPolicy(VISIBILITY_POLICY, SOURCE_CONTRACT,
            record.firebase_path, digest, archive, digest,
            "public_group" if kind == "group" else "organizer_invitee_only", audience,
            users, kicked, not_members, canonical_pins, geography_basis,
            CATALOG_SHA256, scheduled, schedule_basis, observed)
        encoded = json.dumps({"meeting": asdict(row), "members": [asdict(member) for member in members],
                              "visibilityPolicy": asdict(policy)}, ensure_ascii=False,
                             sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        if len(encoded) > MAX_PLAN_BYTES:
            raise _Refusal("plan_bound_exceeded")
        return ImportedMeetingReviewPlan("ready_for_review", "source_bound", row,
            tuple(members), policy, hashlib.sha256(encoded).hexdigest())
    except _Refusal as error:
        return ImportedMeetingReviewPlan("refused", error.reason)
    except (LegacyInvalid, RuntimeUnavailable, ValueError, TypeError, UnicodeError,
            OverflowError, RecursionError, AttributeError, RuntimeError):
        return ImportedMeetingReviewPlan("refused", "malformed_source_or_evidence")
