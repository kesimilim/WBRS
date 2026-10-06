"""Pure, private review plan for exact original profile-photo associations.

No SQL, file/network access, public descriptor, native authority or apply path.
Inputs must later be reread from the reviewed source and ready-media rows by a
trusted projector. A successful plan alone never authorizes serving a photo.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import re
from urllib.parse import unquote, urlsplit

from legacy_conversation_payload import document, payload_digest, LegacyInvalid
from legacy_private_media import target_key, _metadata, MIME_TYPES, MAX_OBJECT_BYTES
from legacy_conversation_read import LegacyReadUnavailable
from media_promotion_acknowledgement import PINS, SOURCE
from profile_visibility import VisibilityAccount


MAX_PHOTOS = 50
STRICT_GALLERY_POLICY = "strict-v1"
AVAILABLE_GALLERY_POLICY = "available-originals-v2"
_DIGEST = re.compile(r"[a-f0-9]{64}\Z")
_MEDIA_FIELDS = {"media_id", "owner_uid", "purpose", "object_key", "thumbnail_key",
    "mime_type", "byte_size", "thumbnail_byte_size", "sha256", "status", "legacy_storage_path"}
_STORAGE_FIELDS = {"source_bucket", "source_path", "source_metadata", "source_size",
    "source_sha256", "target_key", "target_sha256", "copied_at"}


class _Refusal(Exception):
    def __init__(self, reason):
        self.reason = reason


@dataclass(frozen=True, repr=False)
class SourcePhotoDocument:
    firebase_path: str
    encoded_payload: object
    payload_sha256: str


@dataclass(frozen=True, repr=False)
class ReadyPhotoEvidence:
    media: dict
    storage: dict


@dataclass(frozen=True, repr=False)
class ProfilePhotoAssociation:
    uid: str
    media_id: str
    ordinal: int
    is_primary: int
    firebase_image_id: str | None


@dataclass(frozen=True, repr=False)
class PhotoEvidencePin:
    source_path_sha256: str
    object_key_sha256: str
    content_sha256: str
    media_id: str


@dataclass(frozen=True, repr=False)
class ProfilePhotoReviewPlan:
    state: str
    reason: str
    rows: tuple[ProfilePhotoAssociation, ...] = ()
    document_pins: tuple[tuple[str, str], ...] = ()
    media_pins: tuple[PhotoEvidencePin, ...] = ()
    fingerprint: str | None = None

    def summary(self):
        # This is the only log-safe representation, with no UID/path/URL/raw.
        return {"state": self.state, "reason": self.reason,
            "candidateRows": len(self.rows), "originalAvatarCandidate": bool(self.rows),
            "thumbnailsMapped": False, "databaseWrites": 0, "httpEnabled": False}


def _sha(value):
    if type(value) is bytes and len(value) == 32:
        return value.hex()
    if type(value) is str and _DIGEST.fullmatch(value):
        return value
    raise _Refusal("invalid_digest")


def _identifier(value):
    if (type(value) is not str or not 1 <= len(value) <= 191 or value in {".", ".."}
            or "/" in value or any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)
            or len(value.encode("utf-8")) > 764):
        raise _Refusal("identifier_not_representable")
    return value


def _typed_string(fields, name):
    if name not in fields:
        return None
    value = fields[name]
    if type(value) is not dict or len(value) != 1:
        raise _Refusal("malformed_photo_field")
    if "nullValue" in value and value["nullValue"] in (None, "NULL_VALUE"):
        return None
    if set(value) != {"stringValue"} or type(value["stringValue"]) is not str:
        raise _Refusal("malformed_photo_field")
    text = value["stringValue"]
    if (len(text) > 4096 or any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in text)):
        raise _Refusal("malformed_photo_field")
    return text


def _storage_path(value):
    # Whole-value source URLs only. Query/download tokens are never retained.
    if type(value) is not str or re.fullmatch(r"[a-z]+://[^/?#]+[^?#]*(?:\?[^#]*)?", value) is None:
        raise _Refusal("unmapped_original_photo")
    if re.search(r"%(?![a-fA-F0-9]{2})", value) or "\\" in value:
        raise _Refusal("unmapped_original_photo")
    url = urlsplit(value)
    if url.username or url.password or url.fragment or url.port:
        raise _Refusal("unmapped_original_photo")
    raw = None
    if url.scheme == "gs" and url.netloc == SOURCE["bucket"]:
        raw = url.path[1:] if url.path.startswith("/") else None
    elif url.scheme == "https" and url.netloc == "firebasestorage.googleapis.com":
        prefix = "/v0/b/" + SOURCE["bucket"] + "/o/"
        if url.path.startswith(prefix): raw = url.path[len(prefix):]
    elif url.scheme == "https" and url.netloc == "storage.googleapis.com":
        prefix = "/" + SOURCE["bucket"] + "/"
        if url.path.startswith(prefix): raw = url.path[len(prefix):]
    path = unquote(raw, errors="strict") if raw is not None else None
    if (not path or len(path.encode("utf-8")) > 1024
            or any(part in {"", ".", ".."} for part in path.split("/"))
            or any(ord(c) < 32 or ord(c) == 127 for c in path) or "\\" in path):
        raise _Refusal("unmapped_original_photo")
    return path


def _document(record, expected_path):
    if type(record) is not SourcePhotoDocument or record.firebase_path != expected_path:
        raise _Refusal("source_document_mismatch")
    payload = document(record.encoded_payload)
    if payload_digest(payload) != _sha(record.payload_sha256):
        raise _Refusal("source_document_digest_mismatch")
    return payload


def _copied(value):
    if type(value) is datetime:
        if not 1000 <= value.year <= 9999 or value.tzinfo not in (None, timezone.utc):
            raise _Refusal("copy_marker_invalid")
        return
    if type(value) is str:
        for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S.%fZ"):
            pattern = (r"[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}"
                if " " in fmt else r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z")
            if re.fullmatch(pattern, value) is None:
                continue
            try:
                stamp = datetime.strptime(value, fmt)
                if stamp.year >= 1000: return
            except ValueError:
                pass
    raise _Refusal("copy_marker_invalid")


def _ready(evidence, owner):
    if type(evidence) is not ReadyPhotoEvidence:
        raise _Refusal("media_evidence_malformed")
    media, storage = evidence.media, evidence.storage
    if (type(media) is not dict or set(media) != _MEDIA_FIELDS
            or type(storage) is not dict or set(storage) != _STORAGE_FIELDS):
        raise _Refusal("media_evidence_malformed")
    path = storage["source_path"]
    if (type(path) is not str or not path or len(path.encode("utf-8")) > 1024
            or any(p in {"", ".", ".."} for p in path.split("/"))
            or any(ord(c) < 32 or ord(c) == 127 for c in path)):
        raise _Refusal("media_evidence_malformed")
    key = target_key(SOURCE["project"], SOURCE["bucket"], path)
    digest = _sha(storage["source_sha256"])
    size = storage["source_size"]
    if (storage["source_bucket"] != SOURCE["bucket"]
            or storage["target_key"] != key or _sha(storage["target_sha256"]) != digest
            or type(size) is not int or not 0 <= size <= MAX_OBJECT_BYTES):
        raise _Refusal("storage_provenance_mismatch")
    _copied(storage["copied_at"])
    metadata = _metadata(storage["source_metadata"])
    if metadata.get("bucket") not in (None, SOURCE["bucket"]):
        raise _Refusal("storage_provenance_mismatch")
    mime = metadata.get("contentType")
    if (mime not in MIME_TYPES or media["owner_uid"] != owner or media["purpose"] != "profile"
            or media["status"] != "ready" or media["object_key"] != key
            or media["legacy_storage_path"] != path or media["mime_type"] != mime
            or type(media["byte_size"]) is not int or media["byte_size"] != size
            or _sha(media["sha256"]) != digest
            or media["media_id"] != "legacy-media-" + key.rsplit("/", 1)[1]
            or media["thumbnail_key"] is not None or media["thumbnail_byte_size"] is not None):
        raise _Refusal("ready_media_binding_mismatch")
    return path, PhotoEvidencePin(hashlib.sha256(path.encode()).hexdigest(),
        hashlib.sha256(key.encode()).hexdigest(), digest, media["media_id"])


def _fingerprint(uid, rows, documents, media, gallery_original_policy=STRICT_GALLERY_POLICY):
    body = {"kind": "clrs-profile-photo-review-v1", "archiveSha256": PINS["archiveSha256"],
        "uid": uid, "rows": [vars(row) for row in rows],
        "documents": documents, "media": [vars(pin) for pin in media]}
    if gallery_original_policy == AVAILABLE_GALLERY_POLICY:
        body.update(kind="clrs-profile-photo-review-v2",
                    galleryOriginalPolicy=AVAILABLE_GALLERY_POLICY)
    return hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False,
        allow_nan=False, separators=(",", ":")).encode()).hexdigest()


def prepare_profile_photo_review(*, account, canonical_legacy_raw, root_document,
        gallery_documents, gallery_complete, ready_evidence, existing_rows,
        source_archive_sha256, reviewed_gallery_order=None,
        gallery_original_policy=STRICT_GALLERY_POLICY):
    """Plan only; supplied evidence is not an authentication/permission proof.

    The caller must supply a completed bounded gallery and actual existing rows.
    Multiple gallery images need an explicitly reviewed source-ID order: the
    schema has a required ordinal, while source photo docs store no ordinal.
    Missing/native/unknown inputs do not invent or replace associations.
    """
    try:
        if gallery_original_policy not in (STRICT_GALLERY_POLICY, AVAILABLE_GALLERY_POLICY):
            raise _Refusal("gallery_original_policy_unreviewed")
        if source_archive_sha256 != PINS["archiveSha256"]:
            raise _Refusal("source_snapshot_unreviewed")
        if (type(account) is not VisibilityAccount or type(account.disabled) is not int
                or account.disabled != 0 or account.lifecycle != "active"):
            raise _Refusal("owner_unavailable")
        uid = _identifier(account.uid)
        if type(canonical_legacy_raw) is dict and canonical_legacy_raw == {}:
            return ProfilePhotoReviewPlan("unchanged", "native_photo_mapping_unknown")
        root = _document(root_document, "users/" + uid)
        canonical = document(canonical_legacy_raw)
        if payload_digest(canonical) != payload_digest(root):
            raise _Refusal("canonical_source_binding_changed")
        saved_uid = _typed_string(root["fields"], "uid")
        if saved_uid is not None and saved_uid != uid:
            raise _Refusal("source_owner_mismatch")
        fields = root["fields"]
        if (_typed_string(fields, "status") not in (None, "active")
                or _typed_string(fields, "registrationStatus") in ("blocked", "deleted")):
            raise _Refusal("source_owner_unavailable")
        if "deleted" in fields:
            deleted = fields["deleted"]
            if (type(deleted) is not dict or set(deleted) != {"booleanValue"}
                    or deleted["booleanValue"] is not False):
                raise _Refusal("source_owner_unavailable")
        original = _typed_string(root["fields"], "profilePic")
        if original is None or original == "":
            return ProfilePhotoReviewPlan("unchanged", "original_avatar_unknown")
        avatar_path = _storage_path(original)
        if type(gallery_complete) is not bool:
            raise _Refusal("gallery_completion_malformed")
        if not gallery_complete:
            return ProfilePhotoReviewPlan("unchanged", "gallery_completeness_unknown")
        if existing_rows is None:
            return ProfilePhotoReviewPlan("unchanged", "existing_associations_unknown")
        if (type(gallery_documents) not in (tuple, list) or len(gallery_documents) > MAX_PHOTOS
                or type(ready_evidence) not in (tuple, list) or len(ready_evidence) > MAX_PHOTOS
                or type(existing_rows) not in (tuple, list) or len(existing_rows) > MAX_PHOTOS):
            raise _Refusal("photo_input_bound_or_shape")
        gallery = {}; by_path = {}; source_ids = set()
        documents = [(hashlib.sha256(root_document.firebase_path.encode()).hexdigest(), payload_digest(root))]
        for record in gallery_documents:
            if type(record) is not SourcePhotoDocument or type(record.firebase_path) is not str:
                raise _Refusal("gallery_document_mismatch")
            parts = record.firebase_path.split("/")
            if len(parts) != 4 or parts[:3] != ["users", uid, "images"]:
                raise _Refusal("gallery_document_mismatch")
            image_id = _identifier(parts[3])
            if image_id in source_ids: raise _Refusal("ambiguous_gallery_document")
            source_ids.add(image_id)
            payload = _document(record, record.firebase_path)
            # Even an omitted blank original remains in the complete source
            # proof. Its payload/ID change invalidates every prepared context.
            documents.append((hashlib.sha256(record.firebase_path.encode()).hexdigest(), payload_digest(payload)))
            url = _typed_string(payload["fields"], "url")
            if url is None or url == "":
                if gallery_original_policy == STRICT_GALLERY_POLICY:
                    return ProfilePhotoReviewPlan("unchanged", "gallery_original_unknown")
                continue
            path = _storage_path(url)
            if path in by_path: raise _Refusal("ambiguous_gallery_photo")
            if path == avatar_path and url != original:
                raise _Refusal("avatar_gallery_reference_conflict")
            gallery[image_id] = path; by_path[path] = image_id
        if reviewed_gallery_order is None:
            if len(source_ids) > 1:
                return ProfilePhotoReviewPlan("unchanged", "gallery_order_unreviewed")
            order = tuple(gallery)
        else:
            if (type(reviewed_gallery_order) not in (tuple, list)
                    or any(type(x) is not str for x in reviewed_gallery_order)
                    or len(reviewed_gallery_order) != len(source_ids)
                    or set(reviewed_gallery_order) != source_ids):
                raise _Refusal("reviewed_gallery_order_mismatch")
            order = tuple(image_id for image_id in reviewed_gallery_order if image_id in gallery)
        paths = [avatar_path, *(gallery[x] for x in order if gallery[x] != avatar_path)]
        if len(paths) > MAX_PHOTOS: raise _Refusal("photo_input_bound_or_shape")
        media = {}
        for evidence in ready_evidence:
            path, pin = _ready(evidence, uid)
            if path in media: raise _Refusal("ambiguous_ready_media")
            media[path] = pin
        if set(media) != set(paths): raise _Refusal("media_mapping_missing_or_extra")
        rows = tuple(ProfilePhotoAssociation(uid, media[path].media_id, index,
            int(index == 0), by_path.get(path)) for index, path in enumerate(paths))
        if existing_rows:
            if (any(type(row) is not ProfilePhotoAssociation for row in existing_rows)
                    or sorted(existing_rows, key=lambda x: x.ordinal) != list(rows)):
                raise _Refusal("existing_photo_association_conflict")
            return ProfilePhotoReviewPlan("unchanged", "already_matches")
        docs = tuple(sorted(documents)); pins = tuple(media[path] for path in paths)
        return ProfilePhotoReviewPlan("reviewable", "exact_original_associations", rows,
            docs, pins, _fingerprint(uid, rows, docs, pins, gallery_original_policy))
    except _Refusal as error:
        return ProfilePhotoReviewPlan("refused", error.reason)
    except (LegacyInvalid, LegacyReadUnavailable, UnicodeError, ValueError, TypeError, RecursionError):
        return ProfilePhotoReviewPlan("refused", "malformed_or_unsupported_evidence")
