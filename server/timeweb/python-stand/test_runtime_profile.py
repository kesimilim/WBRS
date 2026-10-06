"""Focused own-edit contract tests without real users or cloud connections."""
import unittest
from runtime_profile import RuntimeProfileService, ProfileEditInvalid, validate_profile_edit


STAMP = "2026-10-01T18:00:00.000000Z"
NEXT = "2026-10-01T18:00:00.000001Z"


class Cursor:
    def __init__(self, row):
        self.row = row
        self.rowcount = 0
        self.calls = []

    def execute(self, sql, params=()):
        self.calls.append((sql, params))
        if sql.startswith("UPDATE"):
            names = sql.split(" SET ", 1)[1].split(", updated_at", 1)[0].split(", ")
            columns = ["full_name", "age", "height_cm", "about_text", "interests_text",
                       "has_children", "gender", "relationship_status"]
            for assignment, value in zip(names, params[:-1]):
                self.row[columns.index(assignment.split(" = ")[0])] = int(value) if type(value) is bool else value
            self.row[10] = NEXT
            self.rowcount = 1

    def fetchone(self):
        return None if self.row is None else tuple(self.row)


class Store:
    def __init__(self, row):
        self.cursor = Cursor(row)
        self.last = None

    def mutate(self, identity, operation, operation_id, payload, action, *, access_token):
        self.last = (identity, operation, operation_id, payload, access_token)
        return action(self.cursor, self.cursor.execute, "self-uid")

    def lookup(self, identity, operation, operation_id, *, access_token, payload):
        self.last = (identity, operation, operation_id, payload, access_token)
        return {"lookup": True}

    def read_authenticated(self, identity, action, *, access_token):
        self.last = (identity, access_token)
        return action(self.cursor, self.cursor.execute, "self-uid")


def row():
    return ["Имя", 28, 180, "Описание длиной более двадцати", "Интересы длиной более двадцати",
            0, "мужской", "не женат", 1, 1, STAMP]


class OwnProfileEditTests(unittest.TestCase):
    def test_own_update_exact_fields_and_completion_retained(self):
        store = Store(row()); service = RuntimeProfileService(store)
        status, result, revision = service.edit(object(), "op", {
            "expectedUpdatedAt": STAMP, "changes": {"fullName": "  Другое имя  ", "deti": True}},
            access_token="test-access")
        self.assertEqual(status, 200)
        self.assertEqual(result["uid"], "self-uid")
        self.assertEqual(result["profile"]["fullName"], "Другое имя")
        self.assertEqual(result["profile"]["updatedAt"], NEXT)
        self.assertTrue(result["profile"]["isRegistrationEnd"])
        self.assertTrue(result["profile"]["profileDetailsSaved"])
        self.assertIsNone(revision)
        updates = [(s, p) for s, p in store.cursor.calls if s.startswith("UPDATE")]
        self.assertEqual(len(updates), 1)
        self.assertEqual(updates[0][1][-1], "self-uid")
        self.assertNotIn("legacy_raw", updates[0][0])
        self.assertEqual(store.last[3]["changes"]["fullName"], "  Другое имя  ")

    def test_second_device_conflict_does_not_write(self):
        store = Store(row()); service = RuntimeProfileService(store)
        status, result, _ = service.edit(object(), "op", {
            "expectedUpdatedAt": "2026-09-30T18:00:00.000000Z", "changes": {"age": 29}}, access_token="test-access")
        self.assertEqual((status, result["error"]), (409, "profile_changed"))
        self.assertFalse(any(s.startswith("UPDATE") for s, _ in store.cursor.calls))

    def test_noop_retains_version_and_never_changes_onboarding(self):
        store = Store(row())
        status, result, _ = RuntimeProfileService(store).edit(object(), "op", {
            "expectedUpdatedAt": STAMP, "changes": {"age": 28}}, access_token="test-access")
        self.assertEqual(status, 200)
        self.assertEqual(result["profile"]["updatedAt"], STAMP)
        self.assertFalse(any(s.startswith("UPDATE") for s, _ in store.cursor.calls))

    def test_missing_profile_does_not_create_or_revive_account(self):
        store = Store(None)
        status, result, _ = RuntimeProfileService(store).edit(object(), "op", {
            "expectedUpdatedAt": STAMP, "changes": {"age": 28}}, access_token="test-access")
        self.assertEqual((status, result["error"]), (404, "profile_not_found"))
        self.assertEqual(len(store.cursor.calls), 1)

    def test_privileged_or_foreign_fields_rejected_before_store(self):
        store = Store(row()); service = RuntimeProfileService(store)
        for key in ("uid", "email", "balance", "admin", "status", "group", "группа", "isRegistrationEnd", "profilePic", "countryCode"):
            with self.subTest(field=key), self.assertRaises(ProfileEditInvalid):
                service.edit(object(), "op", {"expectedUpdatedAt": STAMP, "changes": {key: "x"}}, access_token="test-access")
        self.assertIsNone(store.last)

    def test_content_type_bounds_and_invalid_calendar(self):
        invalid = ({"about": "short"}, {"hobbi": "short"}, {"age": True}, {"age": 17},
                   {"rost": 301}, {"deti": 1}, {"fullName": "bad\x00name"},
                   {"pol": ""}, {"fullName": "\ud800"}, {})
        for changes in invalid:
            with self.subTest(changes=repr(changes)), self.assertRaises(ProfileEditInvalid):
                validate_profile_edit({"expectedUpdatedAt": STAMP, "changes": changes})
        with self.assertRaises(ProfileEditInvalid):
            validate_profile_edit({"expectedUpdatedAt": "2026-02-30T18:00:00.000000Z", "changes": {"age": 28}})

    def test_reconcile_preserves_original_payload_and_token_boundary(self):
        store = Store(row()); payload = {"expectedUpdatedAt": STAMP, "changes": {"fullName": " имя "}}
        result = RuntimeProfileService(store).reconcile(object(), "op", payload, access_token="test-access")
        self.assertEqual(result, {"lookup": True})
        self.assertEqual(store.last[3], payload)
        self.assertEqual(store.last[4], "test-access")
        self.assertEqual(store.cursor.calls, [])

    def test_editor_read_is_own_bounded_and_not_financial_hydration(self):
        store = Store(row())
        result = RuntimeProfileService(store).read_for_edit(object(), access_token="test-access")
        self.assertEqual(result["uid"], "self-uid")
        self.assertEqual(result["profile"]["updatedAt"], STAMP)
        self.assertNotIn("balance", result["profile"])
        self.assertNotIn("email", result["profile"])
        self.assertNotIn("group", result["editableFields"])
        self.assertEqual(store.cursor.calls[0][1], ("self-uid",))
        self.assertTrue(store.cursor.calls[0][0].endswith("FOR SHARE"))


if __name__ == "__main__":
    unittest.main()
