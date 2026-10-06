"""Synthetic pure visibility proof. No connector, account or profile writes."""
import copy
from dataclasses import asdict, replace
from datetime import datetime, timedelta, timezone
import json
import unittest

from profile_visibility import (CanonicalVisibility, VisibilityAccount,
                                VisibilityDecision, evaluate_profile_visibility)


NOW = datetime(2026, 10, 2, 12, 0, tzinfo=timezone.utc)
STAMP = "2026-10-02T12:00:00.000000Z"
ACTOR = VisibilityAccount("actor", 0, "active")
TARGET = VisibilityAccount("peer", 0, "active")
CANONICAL = CanonicalVisibility("peer", 0, 0)


def s(value):
    return {"stringValue": value}


def b(value):
    return {"booleanValue": value}


def source(**changes):
    return {"fields": {"uid": s("peer"), "status": s("active"), **changes},
            "createTime": "2026-01-01T00:00:00Z", "updateTime": STAMP}


class ProfileVisibilityTests(unittest.TestCase):
    def evaluate(self, raw=None, **changes):
        values = {"target": TARGET, "actor": ACTOR, "current_actor_uid": "actor",
            "canonical": CANONICAL, "legacy_raw": source() if raw is None else raw,
            "origin": "legacy", "now": NOW, **changes}
        return evaluate_profile_visibility(**values)

    def assert_refused(self, raw=None, *, reason=None, **changes):
        result = self.evaluate(raw, **changes)
        self.assertIs(result.visible, False)
        if reason is not None:
            self.assertEqual(result.reason, reason)
        return result

    def test_legacy_search_requires_exact_source_active_even_if_account_active(self):
        self.assertEqual(self.evaluate(), VisibilityDecision(True, "visible"))
        for value in (None, s(""), s("Active"), s("enabled"), s("pending"), {"nullValue": None}):
            with self.subTest(value=value):
                raw = source()
                if value is None:
                    del raw["fields"]["status"]
                else:
                    raw["fields"]["status"] = value
                self.assert_refused(raw, reason="source_status_unavailable")

    def test_optional_absence_and_typed_null_follow_existing_predicate(self):
        names = ("uid", "registrationStatus", "deleted", "isUnVisible", "isUnvisible", "unvisibleEnd")
        raw = source()
        del raw["fields"]["uid"]
        self.assertIs(self.evaluate(raw).visible, True)
        for name in names:
            with self.subTest(name=name):
                raw = source(**{name: {"nullValue": None}})
                self.assertIs(self.evaluate(raw).visible, True)

    def test_deleted_blocked_and_unknown_registration_never_show(self):
        for changes, reason in (
            ({"deleted": b(True)}, "source_deleted"),
            ({"status": s("deleted")}, "source_deleted"),
            ({"registrationStatus": s("deleted")}, "source_deleted"),
            ({"status": s("blocked")}, "source_blocked"),
            ({"registrationStatus": s("blocked")}, "source_blocked"),
            ({"registrationStatus": s("completed")}, "source_registration_unavailable"),
        ):
            with self.subTest(changes=changes):
                self.assert_refused(source(**changes), reason=reason)
        for value in ("", "active"):
            self.assertIs(self.evaluate(source(registrationStatus=s(value))).visible, True)

    def test_both_spellings_are_or_and_missing_expiration_means_indefinite(self):
        for changes in (
            {"isUnVisible": b(True)}, {"isUnvisible": b(True)},
            {"isUnVisible": b(False), "isUnvisible": b(True)},
            {"isUnVisible": b(True), "isUnvisible": b(False)},
            {"isUnVisible": b(True), "unvisibleEnd": {"nullValue": None}},
        ):
            with self.subTest(changes=changes):
                # The canonical NULL was never proof of absence of invisibility.
                self.assert_refused(source(**changes), reason="indefinitely_invisible")

    def test_expiration_utc_exact_boundary_and_nanoseconds(self):
        cases = (
            ("2026-10-02T11:59:59.999999999Z", True),
            ("2026-10-02T12:00:00Z", True),
            ("2026-10-02T12:00:00.000000001Z", False),
            ("2027-01-01T00:00:00Z", False),
        )
        for expiry, visible in cases:
            with self.subTest(expiry=expiry):
                result = self.evaluate(source(isUnvisible=b(True), unvisibleEnd={"timestampValue": expiry}))
                self.assertIs(result.visible, visible)
        raw = source(isUnVisible=b(True), unvisibleEnd=s("2026-10-02T15:00:00+03:00"))
        self.assertIs(self.evaluate(raw).visible, True)
        self.assertIs(self.evaluate(raw, now=NOW.astimezone(timezone(timedelta(hours=3)))).visible, True)

    def test_valid_expiry_alone_does_not_enable_invisibility(self):
        self.assertIs(self.evaluate(source(unvisibleEnd={"timestampValue": "2027-01-01T00:00:00Z"})).visible, True)
        self.assertIs(self.evaluate(source(isUnVisible=b(False), isUnvisible=b(False),
            unvisibleEnd={"timestampValue": "2027-01-01T00:00:00Z"})).visible, True)

    def test_malformed_flags_and_wrappers_refuse_instead_of_bool_coercion(self):
        bad_booleans = (None, b(None), b(1), b("true"), s("false"), {},
                        {"booleanValue": False, "nullValue": None}, {"nullValue": "bad"})
        for name in ("deleted", "isUnVisible", "isUnvisible"):
            for value in bad_booleans:
                with self.subTest(name=name, value=value):
                    self.assert_refused(source(**{name: value}), reason="malformed_visibility_input")
        for name in ("uid", "status", "registrationStatus"):
            for value in (b(False), s(None), s(1), s("\x00"), s("x" * 192)):
                with self.subTest(name=name, value=value):
                    self.assert_refused(source(**{name: value}), reason="malformed_visibility_input")

    def test_malformed_expiry_refuses_even_with_false_visibility_flags(self):
        values = (s("2026-10-02T12:00:00"), s("tomorrow"), b(False),
            {"integerValue": "1790942400000"}, {"timestampValue": "2026-02-30T12:00:00Z"},
            {"timestampValue": "2026-10-02T12:00:00+03:00"}, s("2026-10-02T12:00:00+24:00"),
            {"timestampValue": None}, {"timestampValue": STAMP, "stringValue": STAMP})
        for value in values:
            with self.subTest(value=value):
                self.assert_refused(source(isUnVisible=b(False), unvisibleEnd=value),
                                    reason="malformed_visibility_input")

    def test_actor_changes_and_account_lifecycle_are_separate_authority(self):
        self.assert_refused(current_actor_uid="other", reason="actor_changed")
        for state in (replace(ACTOR, disabled=1), replace(ACTOR, lifecycle="blocked"),
                      replace(ACTOR, lifecycle="deleted")):
            self.assert_refused(actor=state, reason="actor_inactive")
        for state in (replace(TARGET, disabled=1), replace(TARGET, lifecycle="blocked"),
                      replace(TARGET, lifecycle="deleted")):
            self.assert_refused(target=state, reason="account_inactive")
        for state in (replace(TARGET, disabled=False), replace(TARGET, disabled="0"),
                      replace(TARGET, lifecycle="enabled"), replace(TARGET, uid="a/b")):
            self.assert_refused(target=state, reason="malformed_visibility_input")
        self.assert_refused(target=ACTOR, canonical=replace(CANONICAL, uid="actor"), reason="own_profile")

    def test_profile_uid_binding_is_exact_and_does_not_expose_self_alias(self):
        self.assert_refused(source(uid=s("actor")), reason="source_identity_conflict")
        self.assert_refused(source(uid=s("Peer")), reason="source_identity_conflict")
        self.assert_refused(canonical=replace(CANONICAL, uid="other"), reason="profile_identity_unavailable")

    def test_native_empty_source_needs_explicit_origin_and_both_completion_flags(self):
        complete = CanonicalVisibility("peer", 1, 1)
        self.assert_refused({}, canonical=complete, reason="malformed_visibility_input")
        self.assertIs(self.evaluate({}, origin="native", canonical=complete).visible, True)
        self.assertIs(self.evaluate("{}", origin="native", canonical=complete).visible, True)
        self.assert_refused(source(), origin="native", canonical=complete, reason="origin_conflict")
        self.assert_refused({}, origin="auto", canonical=complete, reason="origin_unavailable")
        for saved, completed in ((0, 0), (0, 1), (1, 0)):
            self.assert_refused({}, origin="native", canonical=CanonicalVisibility("peer", saved, completed),
                                reason="native_incomplete")
        for value in (None, True, "1", 2):
            self.assert_refused({}, origin="native", canonical=replace(complete, registration_complete=value),
                                reason="malformed_visibility_input")

    def test_native_expiry_and_unmapped_legacy_canonical_visibility_are_explicit(self):
        for stamp, visible in ((STAMP, True), ("2027-01-01T00:00:00.000000Z", False)):
            state = CanonicalVisibility("peer", 1, 1, stamp)
            self.assertIs(self.evaluate({}, origin="native", canonical=state).visible, visible)
            self.assert_refused(canonical=state, reason="visibility_authority_unmapped")
        self.assert_refused({}, origin="native", canonical=CanonicalVisibility("peer", 1, 1, "2027-01-01"),
                            reason="malformed_visibility_input")

    def test_current_profile_edit_cannot_erase_retained_visibility(self):
        raw = source(isUnvisible=b(True), isRegistrationEnd=b(False))
        before = copy.deepcopy(raw)
        state = CanonicalVisibility("peer", 1, 1)
        self.assert_refused(raw, canonical=state, reason="indefinitely_invisible")
        self.assertEqual(raw, before)
        # Legacy search did not require completion; native completion is separate.
        self.assertIs(self.evaluate(source(isRegistrationEnd=b(False))).visible, True)

    def test_bounded_source_clock_and_decision_never_return_private_content(self):
        raw = source(email=s("private@example.invalid"), balance={"integerValue": "123"},
                     profilePic=s("https://example.invalid/?token=secret"))
        before = copy.deepcopy(raw)
        result = self.evaluate(json.dumps(raw))
        self.assertEqual(asdict(result), {"visible": True, "reason": "visible"})
        self.assertEqual(raw, before)
        self.assertNotIn("peer", repr(result))
        self.assertNotIn("private", json.dumps(asdict(result)))
        for value in (None, {}, [], {"fields": {}},
                      json.dumps(raw).replace('"status":', '"status": {"stringValue":"blocked"}, "status":'),
                      source(email=s("x" * 131_073))):
            with self.subTest(value_type=type(value).__name__):
                # Pass directly: the test helper deliberately defaults None.
                result = evaluate_profile_visibility(target=TARGET, actor=ACTOR,
                    current_actor_uid="actor", canonical=CANONICAL, legacy_raw=value,
                    origin="legacy", now=NOW)
                self.assertIs(result.visible, False)
                self.assertEqual(set(asdict(result)), {"visible", "reason"})
        self.assert_refused(now=NOW.replace(tzinfo=None), reason="malformed_visibility_input")


if __name__ == "__main__":
    unittest.main()
