"""Synthetic pure photo associations; no connector, HTTP, SQL or S3 access."""
import copy
from dataclasses import replace
from datetime import datetime
import hashlib
import json
import unittest
from urllib.parse import quote

from legacy_conversation_payload import payload_digest
from legacy_private_media import target_key
from media_promotion_acknowledgement import PINS, SOURCE
from profile_photo_review import (prepare_profile_photo_review, SourcePhotoDocument,
    ReadyPhotoEvidence, ProfilePhotoAssociation, MAX_PHOTOS, AVAILABLE_GALLERY_POLICY)
from profile_visibility import VisibilityAccount


UID = "exact-owner"
STAMP = "2026-09-01T00:00:00.000000Z"
PATH = "users/exact-owner/photos/current.jpg"


def url(path):
    return "https://firebasestorage.googleapis.com/v0/b/" + SOURCE["bucket"] + "/o/" + quote(path, safe="") + "?alt=media&token=never-public"


def source(path, **fields):
    payload = {"fields": fields, "createTime": STAMP, "updateTime": STAMP}
    return SourcePhotoDocument(path, payload, payload_digest(payload))


def evidence(path=PATH):
    sha = hashlib.sha256(path.encode()).digest()
    key = target_key(SOURCE["project"], SOURCE["bucket"], path)
    return ReadyPhotoEvidence(
        {"media_id": "legacy-media-" + key.rsplit("/", 1)[1], "owner_uid": UID,
         "purpose": "profile", "object_key": key, "thumbnail_key": None,
         "mime_type": "image/jpeg", "byte_size": 400, "thumbnail_byte_size": None,
         "sha256": sha, "status": "ready", "legacy_storage_path": path},
        {"source_bucket": SOURCE["bucket"], "source_path": path,
         "source_metadata": {"contentType": "image/jpeg", "bucket": SOURCE["bucket"]},
         "source_size": 400, "source_sha256": sha, "target_key": key,
         "target_sha256": sha, "copied_at": datetime(2026, 9, 1)})


class ProfilePhotoReviewTests(unittest.TestCase):
    def setUp(self):
        self.root = source("users/" + UID, uid={"stringValue": UID},
            status={"stringValue": "active"}, profilePic={"stringValue": url(PATH)},
            profilePicThumb={"stringValue": url("different/thumb.jpg")},
            email={"stringValue": "private@example.invalid"})
        self.options = {"account": VisibilityAccount(UID, 0, "active"),
            "canonical_legacy_raw": copy.deepcopy(self.root.encoded_payload),
            "root_document": self.root, "gallery_documents": [], "gallery_complete": True,
            "ready_evidence": [evidence()], "existing_rows": [],
            "source_archive_sha256": PINS["archiveSha256"]}

    def review(self, **changes):
        return prepare_profile_photo_review(**{**self.options, **changes})

    def test_exact_original_avatar_not_thumbnail_auth_or_first_owned_object(self):
        before = copy.deepcopy(self.options)
        plan = self.review()
        self.assertEqual(plan.state, "reviewable")
        self.assertEqual(plan.rows, (ProfilePhotoAssociation(UID,
            self.options["ready_evidence"][0].media["media_id"], 0, 1, None),))
        self.assertEqual(len(plan.media_pins), 1)
        self.assertEqual(len(plan.document_pins), 1)
        self.assertEqual(len(plan.fingerprint), 64)
        self.assertEqual(self.options, before)
        for text in (json.dumps(plan.summary()), repr(plan)):
            for secret in (UID, "token", "private", "photos/", "thumb", "email"):
                self.assertNotIn(secret, text.replace("thumbnailsMapped", ""))
        # An unrelated ready profile file never becomes the current avatar.
        self.assertEqual(self.review(ready_evidence=[evidence("different/thumb.jpg")]).state, "refused")

    def test_null_missing_empty_and_native_are_unchanged_without_fallback(self):
        for value in (None, {"nullValue": None}, {"nullValue": "NULL_VALUE"}, {"stringValue": ""}):
            fields = copy.deepcopy(self.root.encoded_payload["fields"])
            fields.pop("profilePic")
            if value is not None: fields["profilePic"] = value
            root = source("users/" + UID, **fields)
            plan = self.review(root_document=root, canonical_legacy_raw=root.encoded_payload)
            self.assertEqual((plan.state, plan.reason, plan.rows), ("unchanged", "original_avatar_unknown", ()))
        self.assertEqual(self.review(canonical_legacy_raw={}).reason, "native_photo_mapping_unknown")
        self.assertEqual(self.review(gallery_complete=False).reason, "gallery_completeness_unknown")
        self.assertEqual(self.review(existing_rows=None).reason, "existing_associations_unknown")

    def test_source_snapshot_uid_digest_and_current_raw_binding_are_exact(self):
        for options in (
            {"source_archive_sha256": "0" * 64},
            {"account": VisibilityAccount("EXACT-owner", 0, "active")},
            {"account": VisibilityAccount(UID, 1, "active")},
            {"account": VisibilityAccount(UID, 0, "deleted")},
            {"account": VisibilityAccount(UID, False, "active")},
            {"root_document": replace(self.root, payload_sha256="0" * 64)},
            {"root_document": replace(self.root, firebase_path="users/other")},
        ):
            with self.subTest(options=options): self.assertEqual(self.review(**options).state, "refused")
        changed = copy.deepcopy(self.root.encoded_payload)
        changed["fields"]["profilePic"] = {"stringValue": url("different.jpg")}
        self.assertEqual(self.review(canonical_legacy_raw=changed).reason, "canonical_source_binding_changed")
        other = source("users/" + UID, uid={"stringValue": "other"}, profilePic={"stringValue": url(PATH)})
        self.assertEqual(self.review(root_document=other, canonical_legacy_raw=other.encoded_payload).reason, "source_owner_mismatch")
        for field, value in (("status", {"stringValue": "blocked"}),
                ("registrationStatus", {"stringValue": "deleted"}), ("deleted", {"booleanValue": True}),
                ("deleted", {"booleanValue": 0}), ("deleted", {"nullValue": None})):
            fields = {**self.root.encoded_payload["fields"], field: value}
            unavailable = source("users/" + UID, **fields)
            self.assertEqual(self.review(root_document=unavailable,
                canonical_legacy_raw=unavailable.encoded_payload).reason, "source_owner_unavailable")

    def test_original_urls_and_typed_values_refuse_external_traversal_and_aliases(self):
        unsupported = ["https://s3.twcstorage.ru/arbitrary.jpg", "https://outside.invalid/current.jpg",
            "gs://wrong-bucket/" + PATH, "gs://" + SOURCE["bucket"] + "/../current.jpg",
            url(PATH) + "#fragment", "gs://" + SOURCE["bucket"] + "/%GG.jpg",
            "gs://" + SOURCE["bucket"] + "/%2e%2e/current.jpg", " " + url(PATH),
            "https://user@firebasestorage.googleapis.com/v0/b/" + SOURCE["bucket"] + "/o/" + quote(PATH, safe="")]
        values = [{"stringValue": x} for x in unsupported] + [
            {"booleanValue": True}, {"stringValue": None}, {"nullValue": "wrong"},
            {"stringValue": url(PATH), "nullValue": None}]
        for value in values:
            with self.subTest(value=value):
                root = source("users/" + UID, uid={"stringValue": UID}, profilePic=value)
                self.assertEqual(self.review(root_document=root, canonical_legacy_raw=root.encoded_payload).state, "refused")

    def test_ready_owner_purpose_hash_mime_key_copy_marker_and_metadata_binding(self):
        media_changes = [{"owner_uid": "other"}, {"purpose": "message"}, {"status": "pending"},
            {"status": "deleted"}, {"object_key": "clrs-import-quarantine/" + "0" * 64},
            {"media_id": "arbitrary"}, {"legacy_storage_path": "other.jpg"},
            {"sha256": b"0" * 32}, {"mime_type": "image/png"}, {"byte_size": True},
            {"byte_size": 401}, {"thumbnail_key": "arbitrary"}, {"thumbnail_byte_size": 20}]
        storage_changes = [{"source_bucket": "wrong"}, {"source_sha256": None},
            {"target_sha256": b"0" * 32}, {"target_key": "arbitrary"}, {"source_size": True},
            {"source_size": 401}, {"copied_at": None}, {"copied_at": "2026-1-1 00:00:00.000000"},
            {"source_metadata": {"contentType": "image/jpeg", "bucket": "wrong"}},
            {"source_metadata": '{"contentType":"image/jpeg","contentType":"image/png"}'}]
        for kind, changes in [("media", x) for x in media_changes] + [("storage", x) for x in storage_changes]:
            with self.subTest(kind=kind, changes=changes):
                row = evidence()
                row = replace(row, **{kind: {**getattr(row, kind), **changes}})
                self.assertEqual(self.review(ready_evidence=[row]).state, "refused")

    def test_reviewed_gallery_order_primary_exact_link_and_no_source_order_guess(self):
        second = "users/exact-owner/photos/second.jpg"
        current = source("users/" + UID + "/images/z-primary", url={"stringValue": url(PATH)})
        other = source("users/" + UID + "/images/a-other", url={"stringValue": url(second)})
        options = {"gallery_documents": [other, current], "ready_evidence": [evidence(second), evidence()]}
        self.assertEqual(self.review(**options).reason, "gallery_order_unreviewed")
        plan = self.review(**options, reviewed_gallery_order=["a-other", "z-primary"])
        self.assertEqual(plan.state, "reviewable")
        self.assertEqual([(x.ordinal, x.is_primary, x.firebase_image_id) for x in plan.rows],
            [(0, 1, "z-primary"), (1, 0, "a-other")])
        reverse = self.review(**options, reviewed_gallery_order=["z-primary", "a-other"])
        self.assertEqual(plan.fingerprint, reverse.fingerprint)
        self.assertEqual(self.review(**options, reviewed_gallery_order=["a-other", "a-other"]).state, "refused")
        null = source("users/" + UID + "/images/null", url={"nullValue": None})
        self.assertEqual(self.review(gallery_documents=[null]).reason, "gallery_original_unknown")

    def test_ambiguous_gallery_or_ready_rows_and_unrepresentable_ids_refuse_whole_plan(self):
        doc = source("users/" + UID + "/images/one", url={"stringValue": url(PATH)})
        cases = [
            {"gallery_documents": [doc, doc]},
            {"gallery_documents": [doc, source("users/" + UID + "/images/two", url={"stringValue": url(PATH)})]},
            {"gallery_documents": [source("users/other/images/one", url={"stringValue": url(PATH)})]},
            {"gallery_documents": [source("users/" + UID + "/images/" + "x" * 192, url={"stringValue": url(PATH)})]},
            {"ready_evidence": [evidence(), evidence()]},
            {"ready_evidence": [evidence(), evidence("extra.jpg")]},
            {"gallery_documents": [doc] * (MAX_PHOTOS + 1)},
            {"ready_evidence": [evidence()] * (MAX_PHOTOS + 1)},
        ]
        for options in cases:
            with self.subTest(options=list(options)):
                plan = self.review(**options)
                self.assertEqual((plan.state, plan.rows, plan.fingerprint), ("refused", (), None))
        equivalent = source("users/" + UID + "/images/one", url={"stringValue": "gs://" + SOURCE["bucket"] + "/" + PATH})
        self.assertEqual(self.review(gallery_documents=[equivalent]).reason, "avatar_gallery_reference_conflict")

    def test_existing_associations_are_never_overwritten_and_all_matching_rows_noop(self):
        plan = self.review()
        self.assertEqual(self.review(existing_rows=plan.rows).reason, "already_matches")
        changed = replace(plan.rows[0], media_id="other-ready-id")
        refused = self.review(existing_rows=[changed])
        self.assertEqual((refused.state, refused.reason, refused.rows),
            ("refused", "existing_photo_association_conflict", ()))

    def test_available_gallery_skips_only_blank_preserving_full_order_and_document_pins(self):
        second_path = "users/exact-owner/photos/second.jpg"
        first = source("users/" + UID + "/images/a", url={"stringValue": url(PATH)})
        last = source("users/" + UID + "/images/c", url={"stringValue": url(second_path)})
        fingerprints = []
        for value in (None, {"nullValue": None}, {"nullValue": "NULL_VALUE"}, {"stringValue": ""}):
            fields = {"thumbnailUrl": {"stringValue": url("thumb-only.jpg")}}
            if value is not None: fields["url"] = value
            blank = source("users/" + UID + "/images/b", **fields)
            options = {"gallery_documents": [first, blank, last], "reviewed_gallery_order": ["a", "b", "c"],
                "ready_evidence": [evidence(), evidence(second_path)]}
            self.assertEqual(self.review(**options).reason, "gallery_original_unknown")
            plan = self.review(**options, gallery_original_policy=AVAILABLE_GALLERY_POLICY)
            self.assertEqual(plan.state, "reviewable")
            self.assertEqual([(row.ordinal, row.is_primary, row.firebase_image_id) for row in plan.rows],
                [(0, 1, "a"), (1, 0, "c")])
            self.assertEqual(len(plan.document_pins), 4)
            self.assertEqual(len(plan.media_pins), 2)
            self.assertEqual(self.review(**{**options, "reviewed_gallery_order": ["a", "c"]},
                gallery_original_policy=AVAILABLE_GALLERY_POLICY).reason, "reviewed_gallery_order_mismatch")
            self.assertEqual(self.review(**{**options, "gallery_documents": [first, blank, blank]},
                gallery_original_policy=AVAILABLE_GALLERY_POLICY).reason, "ambiguous_gallery_document")
            fingerprints.append(plan.fingerprint)
        self.assertEqual(len(set(fingerprints)), 4)

    def test_available_gallery_malformed_nonempty_unmapped_refuses_whole_plan(self):
        valid = source("users/" + UID + "/images/a", url={"stringValue": url(PATH)})
        blank = source("users/" + UID + "/images/b", url={"nullValue": None})
        values = [{"booleanValue": False}, {"stringValue": None}, {"nullValue": "wrong"},
            {"stringValue": "", "nullValue": None}, {"stringValue": " "},
            {"stringValue": "https://outside.invalid/photo.jpg"},
            {"stringValue": url("unpromoted/original.jpg")},
            {"stringValue": "gs://" + SOURCE["bucket"] + "/" + PATH}, {"stringValue": url(PATH)}]
        for value in values:
            malformed = source("users/" + UID + "/images/c", url=value)
            plan = self.review(gallery_documents=[valid, blank, malformed], reviewed_gallery_order=["a", "b", "c"],
                gallery_original_policy=AVAILABLE_GALLERY_POLICY)
            self.assertEqual((plan.state, plan.rows, plan.fingerprint), ("refused", (), None))


if __name__ == "__main__":
    unittest.main()
