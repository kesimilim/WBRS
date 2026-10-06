"""Immutable, read-only authority from a separately reviewed final cutover pack.

This verifies authenticated assertions and their reviewed binding; it neither
obtains a source barrier/final delta nor issues a production manifest.
"""
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
from pathlib import Path
import re
from types import MappingProxyType
import weakref

from native_credentials import unique_json
from legacy_conversation_payload import document, payload_digest
from imported_meeting_review import (_ROOT_FIELDS, _uids, _string, _schedule,
                                     SOURCE_PROJECT, SOURCE_DATABASE, SOURCE_CONTRACT)
from runtime_mutations import RuntimeUnavailable, canonical_json
from runtime_meetings import MEETING_FIELDS, _meeting_row, _meeting_dto
from meeting_schedule import read_schedule
from runtime_people import _uid

POLICY = "reviewed-imported-meetings-read-schedules-v2"
DOMAIN = b"clrs-imported-meeting-final-authority-v1\0"
MAX_BYTES = 8 * 1024 * 1024
MAX_ROOTS = 4096
MAX_MEMBERS = 65536
_CAPS = weakref.WeakSet()
_SOURCE_FILES = ("imported_meeting_authority.py", "runtime_imported_meetings.py",
    "runtime_meetings.py", "imported_meeting_review.py", "runtime_mutations.py",
    "runtime_people.py", "profile_visibility.py", "runtime_meeting_create.py",
    "runtime_geography.py", "geo_catalog.json", "legacy_conversation_payload.py",
    "native_credentials.py", "runtime_reads.py", "meeting_schedule.py", "runtime_meetings_http.py",
    "app.py", "runtime_http.py", "runtime_read_http.py")
_BINDING_KEYS = {"generation", "sourceSha256", "cohortSha256", "policy",
                 "barrierSha256", "finalDeltaSha256"}


def digest(value):
    return hashlib.sha256(canonical_json(value, max_bytes=MAX_BYTES)).hexdigest()


def source_fingerprint():
    root = Path(__file__).parent
    return digest({name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                   for name in _SOURCE_FILES})


def _shape(value, keys):
    if type(value) is not dict or set(value) != keys:
        raise RuntimeUnavailable()


def _sha(value):
    if type(value) is not str or re.fullmatch(r"[a-f0-9]{64}", value) is None:
        raise RuntimeUnavailable()
    return value


def _stamp(value):
    if type(value) is not str or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z", value) is None:
        raise RuntimeUnavailable()
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)


def _ids(values, maximum=MAX_ROOTS, *, ordered=False):
    if type(values) is not list or len(values) > maximum:
        raise RuntimeUnavailable()
    result = [_uid(value) for value in values]
    if len(result) != len(set(result)) or (ordered and result != sorted(result, key=lambda uid: uid.encode())):
        raise RuntimeUnavailable()
    return result


@dataclass(frozen=True, repr=False, eq=False)
class ImportedMeetingAuthority:
    _binding: bytes
    _roots: object
    _tombstones: frozenset
    fingerprint: str

    def require(self, expected_binding=None):
        if (type(self) is not ImportedMeetingAuthority or self not in _CAPS
                or unique_json(self._binding.decode())["sourceSha256"] != source_fingerprint()
                or (expected_binding is not None and canonical_json(expected_binding) != self._binding)):
            raise RuntimeUnavailable()

    def entry(self, meeting_id):
        raw = self._roots.get(meeting_id)
        return None if raw is None else unique_json(raw.decode())

    def reviewed(self, meeting_id):
        return meeting_id in self._roots or meeting_id in self._tombstones

    def kicked(self, meeting_id, uid):
        entry = self.entry(meeting_id)
        return entry is not None and uid in entry["kicked"]

    def meeting(self, row, raw):
        entry = self.entry(row["meetingId"])
        if entry is None:
            return {**row, "trusted": 0} if row["meetingId"] in self._tombstones else row
        try:
            payload = document(raw); fields = payload["fields"]; wanted = entry["canonical"]
            if (payload_digest(payload) != entry["payloadSha256"] or set(fields) - _ROOT_FIELDS
                    or _uids(fields, "users", required=True) != tuple(entry["users"])
                    or (_uids(fields, "kicked") if "kicked" in fields else (
                        () if entry["missingKickedReviewed"] else None)) != tuple(entry["kicked"])
                    or _string(fields, "admin", required=True) != wanted["organizerUid"]
                    or _string(fields, "type", required=True) != ("групповая" if wanted["kind"] == "group" else "индивидуальная")
                    or _string(fields, "invitedUid") != wanted["invitedUid"]
                    or _schedule(fields)[:2] != (wanted["localDatetime"], wanted["startsAt"])
                    or row["revision"] < wanted["revision"] or row["updatedAt"] is None
                    or row["updatedAt"] < wanted["updatedAt"] or row["deletedAt"] is not None
                    or any(row[key] != wanted[key] for key in MEETING_FIELDS[:12]
                           if key not in {"revision", "updatedAt"})):
                raise RuntimeUnavailable()
            return {**row, "trusted": 1, "localDatetime": wanted["localDatetime"]}
        except Exception:
            return {**row, "trusted": 0}

    def member(self, row, raw):
        entry = self.entry(row["meetingId"])
        if entry is None:
            return {**row, "trusted": 0} if row["meetingId"] in self._tombstones else row
        try:
            if type(raw) in (str, bytes):
                raw = unique_json(raw.decode() if type(raw) is bytes else raw)
            _shape(raw, {"source_path", "source_index", "source_field", "source_payload_hash"})
            if (row["uid"] not in entry["users"] or row["uid"] in entry["kicked"]
                    or row["joinedAt"] is not None or raw["source_path"] != entry["firebasePath"]
                    or raw["source_field"] != "users" or raw["source_payload_hash"] != entry["payloadSha256"]
                    or type(raw["source_index"]) is not int
                    or raw["source_index"] != entry["users"].index(row["uid"])):
                raise RuntimeUnavailable()
            return {**row, "trusted": 1}
        except Exception:
            return {**row, "trusted": 0}


def load_imported_authority(raw, signature, key, *, reviewed_binding, clock=None):
    """Only a trusted cutover assembler supplies reviewed_binding; never HTTP/env.

    The signing key must authenticate the separately approved final pack, not
    old current-root observations. No producer or release activation exists here.
    """
    try:
        if (type(raw) is not bytes or not 1 <= len(raw) <= MAX_BYTES or type(key) is not bytes or len(key) < 32
                or type(signature) is not bytes or len(signature) != 32
                or not hmac.compare_digest(hmac.digest(key, DOMAIN + raw, "sha256"), signature)):
            raise RuntimeUnavailable()
        body = unique_json(raw.decode("utf-8"))
        _shape(body, {"v", "kind", "namespace", "binding", "barrier", "finalDelta", "issuedAt", "finalRoots", "tombstones", "meetings"})
        binding = body["binding"]; _shape(binding, _BINDING_KEYS); _shape(reviewed_binding, _BINDING_KEYS)
        if (type(body["v"]) is not int or body["v"] != 1 or body["kind"] != "imported-meeting-final-authority"
                or body["namespace"] != {"project": SOURCE_PROJECT, "database": SOURCE_DATABASE, "collection": "meets"}
                or binding != reviewed_binding or binding["policy"] != POLICY
                or binding["sourceSha256"] != source_fingerprint()):
            raise RuntimeUnavailable()
        for name in _BINDING_KEYS - {"policy"}: _sha(binding[name])
        barrier = body["barrier"]; delta = body["finalDelta"]
        _shape(barrier, {"enforced", "allWritersStopped", "verified", "receiptSha256", "writerSetSha256", "enforcementSha256", "verifiedAt", "generation"})
        _shape(delta, {"consistent", "final", "complete", "readbackVerified", "receiptSha256", "barrierSha256", "rootSetSha256", "tombstonesSha256", "completedAt"})
        if (any(barrier[key] is not True for key in ("enforced", "allWritersStopped", "verified"))
                or any(delta[key] is not True for key in ("consistent", "final", "complete", "readbackVerified"))
                or barrier["receiptSha256"] != binding["barrierSha256"] or barrier["generation"] != binding["generation"]
                or delta["receiptSha256"] != binding["finalDeltaSha256"] or delta["barrierSha256"] != binding["barrierSha256"]):
            raise RuntimeUnavailable()
        _sha(barrier["writerSetSha256"]); _sha(barrier["enforcementSha256"])
        now = datetime.now(timezone.utc) if clock is None else clock()
        if not _stamp(barrier["verifiedAt"]) <= _stamp(delta["completedAt"]) <= _stamp(body["issuedAt"]) <= now:
            raise RuntimeUnavailable()
        tombstones = _ids(body["tombstones"], ordered=True)
        final = body["finalRoots"]
        if type(final) is not list or not 1 <= len(final) <= MAX_ROOTS:
            raise RuntimeUnavailable()
        final_map = {}
        for item in final:
            if type(item) is not list or len(item) != 2: raise RuntimeUnavailable()
            uid = _uid(item[0]); final_map[uid] = _sha(item[1])
        if (len(final_map) != len(final) or list(final_map) != sorted(final_map, key=lambda uid: uid.encode())
                or set(final_map) & set(tombstones) or delta["rootSetSha256"] != digest(final)
                or delta["tombstonesSha256"] != digest(tombstones)
                or binding["cohortSha256"] != digest({"meetings": body["meetings"], "tombstones": tombstones})):
            raise RuntimeUnavailable()
        entries = body["meetings"]; roots = {}; member_count = 0
        if type(entries) is not list or not 1 <= len(entries) <= MAX_ROOTS: raise RuntimeUnavailable()
        for entry in entries:
            _shape(entry, {"meetingId", "firebasePath", "payloadSha256", "metadataReviewSha256", "sourceContract", "canonical", "users", "kicked", "missingKickedReviewed"})
            uid = _uid(entry["meetingId"]); _sha(entry["metadataReviewSha256"])
            if (uid in roots or entry["firebasePath"] != "meets/" + uid or final_map.get(uid) != entry["payloadSha256"]
                    or entry["sourceContract"] != SOURCE_CONTRACT or type(entry["missingKickedReviewed"]) is not bool):
                raise RuntimeUnavailable()
            users = _ids(entry["users"], 1000); kicked = _ids(entry["kicked"], 1000); member_count += len(users) + len(kicked)
            wanted = entry["canonical"]; _shape(wanted, set(MEETING_FIELDS[:12]) | {"localDatetime"})
            row = _meeting_row(tuple({**wanted, "trusted": 0, "valid": 1, "deletedAt": None}[key] for key in MEETING_FIELDS))
            read_schedule(wanted["localDatetime"], wanted["startsAt"])
            if (wanted["meetingId"] != uid or _meeting_dto({**row, "trusted": 1}) is None
                    or wanted["createdAt"] is None or wanted["updatedAt"] is None or set(users) & set(kicked)
                    or (wanted["kind"] == "individual" and (set(users) | set(kicked)) - {wanted["organizerUid"], wanted["invitedUid"]})
                    or member_count > MAX_MEMBERS):
                raise RuntimeUnavailable()
            roots[uid] = canonical_json(entry, max_bytes=MAX_BYTES)
        if list(roots) != sorted(roots, key=lambda uid: uid.encode()): raise RuntimeUnavailable()
        cap = ImportedMeetingAuthority(canonical_json(binding), MappingProxyType(roots), frozenset(tombstones), hashlib.sha256(raw).hexdigest())
        _CAPS.add(cap); return cap
    except Exception:
        raise RuntimeUnavailable() from None
