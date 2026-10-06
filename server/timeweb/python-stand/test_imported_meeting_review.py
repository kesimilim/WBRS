"""Focused private synthetic imported-meeting proposals; no user scan or SQL."""
import copy
from dataclasses import asdict, FrozenInstanceError, replace
import json
from pathlib import Path
import socket
import unittest
from unittest.mock import patch

from imported_meeting_review import (SourceMeetingDocument, MeetingSourceReviewPin,
    CurrentMeetingPerson, SOURCE_CONTRACT, VISIBILITY_POLICY, SOURCE_PROJECT,
    SOURCE_DATABASE, MAX_MEMBERS, review_imported_meeting)
from legacy_conversation_payload import payload_digest
from profile_visibility import VisibilityAccount


STAMP = "2026-10-01T12:00:00.000001Z"
OBSERVED = "2026-10-02T12:00:00.000002Z"
ARCHIVE = "a" * 64


def string(value):
    return {"stringValue": value}


def array(*uids):
    return {"arrayValue": {"values": [string(uid) for uid in uids]}}


def payload(**changes):
    return {"fields": {"admin": string("organizer"), "type": string("групповая"),
        "name": string("  Встреча\t "), "description": string("Описание\n"),
        "users": array("organizer", "member"), "kicked": array(),
        "country": string("Россия"), "countryCode": string("RU"),
        "region": string("Москва"), "city": string("Москва"),
        "datetime": string("03.10.2026 12:35"), "timeStamp": {"timestampValue": STAMP},
        "creationRequestId": string("operation-original"), "recentMessage": string("private recent"),
        "recentMessageSender": string("private sender"),
        "imageUrl": string("https://example.invalid/private-image?token=private"), **changes},
        "createTime": STAMP, "updateTime": STAMP}


def evidence(raw=None, *, path="meets/m"):
    raw = payload() if raw is None else raw
    digest = payload_digest(raw)
    source = SourceMeetingDocument(path, raw, digest, ARCHIVE)
    pin = MeetingSourceReviewPin(path, digest, ARCHIVE, SOURCE_CONTRACT,
        complete_root_document=True, current_document_exists=True,
        current_payload_sha256=digest, member_observed_at=OBSERVED)
    return source, pin


def person(uid):
    return CurrentMeetingPerson(VisibilityAccount(uid, 0, "active"), uid, STAMP)


class ImportedMeetingReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The pure function accepts already-loaded pinned bytes; only this test
        # harness reads the bundled catalog, never actual archived user data.
        cls.catalog = Path(__file__).with_name("geo_catalog.json").read_bytes()

    def setUp(self):
        self.people = {uid: person(uid) for uid in ("organizer", "member", "invitee")}

    def review(self, raw=None, *, source_changes=None, pin_changes=None, people=None):
        source, pin = evidence(raw)
        if source_changes: source = replace(source, **source_changes)
        if pin_changes: pin = replace(pin, **pin_changes)
        return review_imported_meeting(source, pin, self.people if people is None else people,
                                       catalog_bytes=self.catalog)

    def assertRefused(self, plan, reason=None):
        self.assertEqual(plan.state, "refused")
        self.assertIsNone(plan.meeting); self.assertEqual(plan.members, ())
        self.assertIsNone(plan.visibility_policy); self.assertIsNone(plan.fingerprint)
        self.assertIs(plan.summary()["applyAllowed"], False)
        if reason is not None: self.assertEqual(plan.reason, reason)

    def test_exact_canonical_proposals_retained_raw_source_kick_policy_and_observed_basis(self):
        raw = payload(kicked=array("kicked-past"), users=array("member"))
        original = copy.deepcopy(raw)
        plan = self.review(raw)
        self.assertEqual(plan.state, "ready_for_review")
        self.assertEqual(set(asdict(plan.meeting)), {"meeting_id", "organizer_uid", "invited_uid", "kind",
            "title", "description", "country_code", "region", "starts_at", "created_at", "updated_at",
            "media_id", "creation_request_id", "revision", "deleted_at", "legacy_raw"})
        self.assertEqual(plan.meeting.meeting_id, "m"); self.assertEqual(plan.meeting.organizer_uid, "organizer")
        self.assertEqual(plan.meeting.title, "  Встреча\t "); self.assertEqual(plan.meeting.description, "Описание\n")
        self.assertEqual(json.loads(plan.meeting.legacy_raw), original)
        self.assertNotEqual(json.loads(plan.meeting.legacy_raw), {})
        self.assertEqual(plan.meeting.created_at, STAMP); self.assertEqual(plan.meeting.updated_at, STAMP)
        self.assertIsNone(plan.meeting.starts_at); self.assertIsNone(plan.meeting.media_id)
        self.assertEqual(plan.meeting.creation_request_id, "operation-original"); self.assertEqual(plan.meeting.revision, 0)
        self.assertEqual([m.uid for m in plan.members], ["member"])
        member = plan.members[0]
        self.assertEqual(set(asdict(member)), {"meeting_id", "uid", "joined_at", "left_at", "kicked_at", "membership_revision", "legacy_raw"})
        self.assertEqual(member.joined_at, OBSERVED); self.assertIsNone(member.left_at); self.assertIsNone(member.kicked_at)
        proof = json.loads(member.legacy_raw)
        self.assertEqual(proof["joinedAtBasis"], "migration_first_observed")
        self.assertIsNone(proof["historicalJoinedAt"])
        self.assertEqual(proof["payloadSha256"], payload_digest(raw)); self.assertEqual(proof["uid"], "member")
        policy = plan.visibility_policy
        self.assertEqual(policy.version, VISIBILITY_POLICY); self.assertEqual(policy.metadata_audience, "public_group")
        self.assertEqual(policy.kicked_uids, ("kicked-past",)); self.assertEqual(policy.active_uids, ("member",))
        self.assertEqual(policy.not_current_member_uids, ("organizer",))
        self.assertEqual(policy.member_observed_at, OBSERVED)
        self.assertTrue(policy.require_current_foreign_profile_visibility)
        self.assertTrue(policy.require_current_root_and_provenance)
        self.assertFalse(policy.public_serving_enabled)
        self.assertEqual(raw, original)

    def test_root_exact_hash_namespace_archive_and_nested_path_fail_closed(self):
        for changes in ({"firebase_path": "users/m/removed_meets/m"}, {"firebase_path": "meets/m/messages/x"},
                        {"firebase_path": "Meets/m"}, {"firebase_path": "meets/.."},
                        {"project": "other"}, {"database": "other"},
                        {"payload_sha256": "b" * 64}, {"archive_sha256": "b" * 64},
                        {"payload_sha256": "A" * 64}):
            with self.subTest(changes=changes): self.assertRefused(self.review(source_changes=changes))
        for changes in ({"firebase_path": "meets/other"}, {"payload_sha256": "b" * 64},
                        {"archive_sha256": "b" * 64}, {"source_contract": "guess"},
                        {"current_payload_sha256": "b" * 64}):
            with self.subTest(changes=changes): self.assertRefused(self.review(pin_changes=changes))
        source, pin = evidence()
        changed = copy.deepcopy(source.encoded_payload); changed["fields"]["admin"] = string("invitee")
        self.assertRefused(review_imported_meeting(replace(source, encoded_payload=changed), pin,
            self.people, catalog_bytes=self.catalog), "source_digest_mismatch")

    def test_completeness_deletion_current_presence_and_observation_are_never_inferred(self):
        for changes, reason in (({"complete_root_document": False}, "source_completeness_unproven"),
                ({"current_document_exists": None}, "deletion_unproven"),
                ({"current_document_exists": False}, "source_deleted"),
                ({"current_document_exists": 1}, "deletion_unproven"),
                ({"current_payload_sha256": None}, "current_source_changed"),
                ({"member_observed_at": None}, "member_observation_unproven"),
                ({"member_observed_at": "2026-09-01T00:00:00.000000Z"}, "member_observation_invalid"),
                ({"member_observed_at": "2026-10-02T12:00:00Z"}, "member_observation_invalid")):
            with self.subTest(changes=changes): self.assertRefused(self.review(pin_changes=changes), reason)
        source, pin = evidence()
        default = MeetingSourceReviewPin(pin.firebase_path, pin.payload_sha256, pin.archive_sha256, SOURCE_CONTRACT)
        self.assertRefused(review_imported_meeting(source, default, self.people, catalog_bytes=self.catalog))

    def test_missing_kicked_requires_explicit_review_and_unknown_privacy_status_never_guessed(self):
        raw = payload(); del raw["fields"]["kicked"]
        self.assertRefused(self.review(raw), "kick_absence_unproven")
        reviewed = self.review(raw, pin_changes={"missing_kicked_reviewed_as_empty": True})
        self.assertEqual(reviewed.state, "ready_for_review"); self.assertEqual(reviewed.visibility_policy.kicked_uids, ())
        for key, value in (("deleted", {"booleanValue": False}), ("deleted", {"booleanValue": True}),
                           ("status", string("active")), ("status", string("deleted")),
                           ("private", {"booleanValue": False}), ("hidden", {"booleanValue": True}),
                           ("unreviewedFutureField", string("anything"))):
            with self.subTest(key=key, value=value):
                self.assertRefused(self.review(payload(**{key: value})), "unreviewed_root_field")

    def test_strict_membership_no_dedup_coercion_overlap_or_invented_leave_time(self):
        raw = payload(users=array(), kicked=array("organizer"))
        plan = self.review(raw)
        self.assertEqual(plan.state, "ready_for_review"); self.assertEqual(plan.members, ())
        self.assertEqual(plan.visibility_policy.kicked_uids, ("organizer",))
        self.assertFalse(plan.visibility_policy.membership_event_times_known)
        self.assertEqual(plan.visibility_policy.not_current_member_uids, ())
        for changes in ({"users": string("member")}, {"users": array("member", "member")},
                        {"users": {"arrayValue": {"values": [{"integerValue": "1"}]}}},
                        {"users": array("bad/uid")}, {"users": array("member"), "kicked": array("member")},
                        {"kicked": {"nullValue": None}}, {"kicked": array("x", "x")},
                        {"users": {"arrayValue": {"values": [], "other": True}}}):
            with self.subTest(changes=changes): self.assertRefused(self.review(payload(**changes)))
        raw = payload(); del raw["fields"]["users"]
        self.assertRefused(self.review(raw), "membership_unavailable")

    def test_individual_exact_pair_and_invited_not_joined_remains_unknown_not_left(self):
        raw = payload(type=string("индивидуальная"), invitedUid=string("invitee"), users=array("organizer"))
        plan = self.review(raw)
        self.assertEqual(plan.state, "ready_for_review"); self.assertEqual(plan.meeting.kind, "individual")
        self.assertEqual(plan.meeting.invited_uid, "invitee")
        self.assertEqual(plan.visibility_policy.metadata_audience, "organizer_invitee_only")
        self.assertEqual(plan.visibility_policy.audience_uids, ("invitee", "organizer"))
        self.assertEqual(plan.visibility_policy.not_current_member_uids, ("invitee",))
        self.assertEqual([m.uid for m in plan.members], ["organizer"])
        for changes in ({"invitedUid": string("organizer")}, {"invitedUid": {"nullValue": None}},
                        {"invitedUid": string("")}, {"users": array("member")}, {"kicked": array("member")}):
            with self.subTest(changes=changes): self.assertRefused(self.review({**raw, "fields": {**raw["fields"], **changes}}))
        for value in (string("коллективная"), string("group"), {"integerValue": "1"}):
            self.assertRefused(self.review(payload(type=value)))
        self.assertRefused(self.review(payload(invitedUid=string(""))), "group_audience_conflict")

    def test_canonical_current_people_identity_active_profile_and_timestamp_pins(self):
        for replacement in (replace(person("member"), account=VisibilityAccount("member", 1, "active")),
                            replace(person("member"), account=VisibilityAccount("member", 0, "blocked")),
                            replace(person("member"), account=VisibilityAccount("other", 0, "active")),
                            replace(person("member"), account=VisibilityAccount("member", False, "active")),
                            replace(person("member"), profile_uid="other"),
                            replace(person("member"), profile_updated_at="not-a-date")):
            people = {**self.people, "member": replacement}
            self.assertRefused(self.review(people=people))
        self.assertRefused(self.review(people={"organizer": person("organizer")}), "current_person_inactive_or_missing")
        self.assertRefused(self.review(people={"organizer": person("organizer"), "member": {"uid": "member"}}))
        plan = self.review()
        self.assertEqual(plan.visibility_policy.canonical_people_pins, (("member", STAMP), ("organizer", STAMP)))
        other = self.review(people={**self.people, "member": replace(person("member"), profile_updated_at=OBSERVED)})
        self.assertNotEqual(plan.fingerprint, other.fingerprint)

    def test_exact_catalog_country_name_mapping_no_city_region_fallback(self):
        plan = self.review()
        self.assertEqual((plan.meeting.country_code, plan.meeting.region), ("RU", "Москва"))
        self.assertEqual(plan.visibility_policy.geography_basis, "source_country_code_exact")
        raw = payload(); del raw["fields"]["countryCode"]
        plan = self.review(raw)
        self.assertEqual(plan.meeting.country_code, "RU")
        self.assertEqual(plan.visibility_policy.geography_basis, "source_country_name_catalog_exact")
        raw = payload(); del raw["fields"]["region"]
        self.assertIsNone(self.review(raw).meeting.region)
        for changes in ({"countryCode": string("ru")}, {"countryCode": string("ZZ")},
                        {"country": string(" Россия")}, {"country": string("США")},
                        {"region": string(" Москва")}, {"region": string("not a region")}):
            with self.subTest(changes=changes): self.assertRefused(self.review(payload(**changes)))
        source, pin = evidence()
        self.assertRefused(review_imported_meeting(source, pin, self.people, catalog_bytes=b"{}"), "catalog_unavailable")
        raw = payload()
        for key in ("country", "countryCode", "region"): del raw["fields"][key]
        plan = self.review(raw)
        self.assertEqual(plan.state, "ready_for_review"); self.assertIsNone(plan.meeting.country_code)
        self.assertIsNone(plan.meeting.region); self.assertEqual(plan.visibility_policy.geography_basis, "unavailable")
        raw["fields"]["region"] = string("Москва")
        self.assertRefused(self.review(raw), "geography_unproven")

    def test_local_scheduled_datetime_preserved_without_utc_or_created_time_substitution(self):
        plan = self.review(payload(datetime=string("3.10.2026 2:05")))
        self.assertEqual(plan.state, "ready_for_review")
        self.assertEqual(plan.visibility_policy.scheduled_local, "3.10.2026 2:05")
        self.assertIsNone(plan.meeting.starts_at); self.assertIsNone(plan.visibility_policy.scheduled_timezone)
        self.assertEqual(plan.visibility_policy.scheduled_basis, "source_local_datetime_timezone_unknown")
        utc = self.review(payload(datetime={"timestampValue": "2026-10-03T12:35:00.000003Z"}))
        self.assertEqual(utc.state, "ready_for_review")
        self.assertEqual(utc.meeting.starts_at, "2026-10-03T12:35:00.000003Z")
        self.assertEqual(utc.visibility_policy.scheduled_basis, "source_timestamp_utc")
        self.assertIsNone(utc.visibility_policy.scheduled_local)
        self.assertTrue(utc.summary()["scheduledUtcKnown"])
        self.assertRefused(self.review(payload(datetime={"timestampValue": "2026-10-03T12:35:00.000000001Z"})), "timestamp_not_representable")
        for value in ("31.02.2026 12:00", "03.10.2026 24:00", "2026-10-03T12:00:00Z", " 03.10.2026 12:00"):
            self.assertRefused(self.review(payload(datetime=string(value))), "scheduled_local_invalid")
        raw = payload(); del raw["fields"]["datetime"]
        plan = self.review(raw)
        self.assertIsNone(plan.meeting.starts_at); self.assertIsNone(plan.visibility_policy.scheduled_local)
        self.assertEqual(plan.visibility_policy.scheduled_basis, "unavailable")

    def test_exact_utc_precision_bounds_and_source_time_conflict_fail_closed(self):
        raw = payload(); raw["createTime"] = "2026-10-01T12:00:00Z"
        plan = self.review(raw)
        self.assertEqual(plan.meeting.created_at, "2026-10-01T12:00:00.000000Z")
        for stamp in ("2026-10-01T12:00:00.000000001Z", "2026-10-01T12:00:00+03:00",
                      "0999-10-01T12:00:00.000000Z", "invalid"):
            raw = payload(); raw["createTime"] = stamp
            # Malformed archive timestamp may be refused before proposal parse.
            source = SourceMeetingDocument("meets/m", raw, payload_digest(raw), ARCHIVE)
            pin = MeetingSourceReviewPin("meets/m", source.payload_sha256, ARCHIVE, SOURCE_CONTRACT,
                True, True, source.payload_sha256, False, OBSERVED)
            self.assertRefused(review_imported_meeting(source, pin, self.people, catalog_bytes=self.catalog))
        raw = payload(); raw["createTime"] = OBSERVED
        self.assertRefused(self.review(raw), "source_time_conflict")

    def test_original_strings_typed_nulls_controls_overflow_and_opaque_fields_validation(self):
        raw = payload(name={"nullValue": "NULL_VALUE"}, description=string("строка\r\n\t "))
        plan = self.review(raw)
        self.assertIsNone(plan.meeting.title); self.assertEqual(plan.meeting.description, "строка\r\n\t ")
        for changes in ({"name": string("x" * 1001)}, {"description": string("🙂" * 4097)},
                        {"name": string("bad\x00")}, {"name": {"integerValue": "5"}},
                        {"creationRequestId": string("")},
                        {"recentMessage": {"booleanValue": True}}, {"timeStamp": string(STAMP)},
                        {"usersWithoutNotification": string("member")},
                        {"clientWriteReceipts": {"mapValue": {"fields": {"operation": string("true")}}}}):
            with self.subTest(changes=changes): self.assertRefused(self.review(payload(**changes)))
        raw = payload(); raw["fields"]["admin"] = string("bad/uid")
        self.assertRefused(self.review(raw))

    def test_recent_message_time_private_string_never_creation_schedule_or_join_authority(self):
        for value in ("2026-10-02 23:41:09.123456", "Timestamp(seconds=1790984469, nanoseconds=123000000)",
                      "", "x" * 191):
            with self.subTest(value=value):
                raw = payload(recentMessageTime=string(value))
                plan = self.review(raw)
                self.assertEqual(plan.state, "ready_for_review")
                self.assertEqual(json.loads(plan.meeting.legacy_raw)["fields"]["recentMessageTime"], string(value))
                self.assertEqual(plan.meeting.created_at, STAMP); self.assertEqual(plan.meeting.updated_at, STAMP)
                self.assertIsNone(plan.meeting.starts_at)
                self.assertEqual(plan.members[0].joined_at, OBSERVED)
                self.assertIsNone(json.loads(plan.members[0].legacy_raw)["historicalJoinedAt"])
        for value in ({"timestampValue": STAMP}, {"integerValue": "1790984469"}, {"booleanValue": True},
                      {"nullValue": "NULL_VALUE"}, {"stringValue": "safe", "timestampValue": STAMP},
                      {"stringValue": 1}, string("x" * 192), string("🙂" * 192), string("bad\x00"),
                      string("bad\n"), [], "plain-untyped"):
            with self.subTest(value=value):
                self.assertRefused(self.review(payload(recentMessageTime=value)))

    def test_fingerprint_deterministic_immutable_snapshots_and_redacted_summary(self):
        raw = payload(); original = copy.deepcopy(raw)
        plan = self.review(raw); same = self.review(raw)
        self.assertEqual(plan.fingerprint, same.fingerprint); self.assertEqual(raw, original)
        raw["fields"]["name"] = string("changed after review")
        self.assertEqual(json.loads(plan.meeting.legacy_raw), original)
        self.assertEqual(plan.meeting.title, "  Встреча\t ")
        with self.assertRaises(FrozenInstanceError): plan.meeting.title = "modified"
        later = self.review(original, pin_changes={"member_observed_at": "2026-10-02T12:00:01.000002Z"})
        self.assertNotEqual(plan.fingerprint, later.fingerprint)
        summary = json.dumps(plan.summary()) + repr(plan) + repr(plan.meeting)
        for secret in ("organizer", "member\"", "meets/", "private", "token=", "Описание", "03.10.2026"):
            self.assertNotIn(secret, summary)
        self.assertEqual(plan.summary()["databaseWrites"], 0)
        self.assertFalse(plan.summary()["httpEnabled"])
        original = payload(); raw = copy.deepcopy(original); source, pin = evidence(raw)
        def hash_then_change_callers_input(value):
            digest = payload_digest(value)
            raw["fields"]["name"] = string("changed between hash and proposal")
            return digest
        with patch("imported_meeting_review.payload_digest", side_effect=hash_then_change_callers_input):
            retained = review_imported_meeting(source, pin, self.people, catalog_bytes=self.catalog)
        self.assertEqual(retained.state, "ready_for_review")
        self.assertEqual(json.loads(retained.meeting.legacy_raw), original)
        self.assertEqual(retained.meeting.title, "  Встреча\t ")

    def test_pure_function_no_file_network_or_environment_reads_and_bounded_members(self):
        source, pin = evidence()
        with patch("builtins.open", side_effect=AssertionError("pure review opened file")), \
             patch.object(Path, "open", side_effect=AssertionError("pure review opened path")), \
             patch.object(socket, "socket", side_effect=AssertionError("pure review opened network")):
            plan = review_imported_meeting(source, pin, self.people, catalog_bytes=self.catalog)
        self.assertEqual(plan.state, "ready_for_review")
        self.assertRefused(self.review(payload(users=array(*[f"u{i}" for i in range(MAX_MEMBERS + 1)]))), "membership_bound_exceeded")
        self.assertRefused(self.review(people={str(i): person(str(i)) for i in range(MAX_MEMBERS + 3)}), "current_people_unavailable")
        source, pin = evidence()
        duplicate_json = '{"fields":{},"fields":{},"createTime":"' + STAMP + '","updateTime":"' + STAMP + '"}'
        self.assertRefused(review_imported_meeting(replace(source, encoded_payload=duplicate_json), pin,
            self.people, catalog_bytes=self.catalog))


if __name__ == "__main__":
    unittest.main()
