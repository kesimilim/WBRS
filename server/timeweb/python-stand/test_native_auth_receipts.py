"""Sensitive receipt leaf tests; generated data and transactional SQL double."""
from contextlib import contextmanager
import copy
from dataclasses import replace
from datetime import datetime
import hashlib
import json
import unittest

from native_auth_receipts import (SensitiveAuthReceipts, AuthReceiptOutcome,
    AuthReceiptResolution, AuthReceiptInvalid, AuthReceiptConflict,
    AuthReceiptUnavailable, MAX_PAYLOAD_BYTES)

KEY = b"r" * 32
EMAIL_IDENTITY = b"e" * 32
OTHER_EMAIL = b"f" * 32
UID = "generated-receipt-actor"
EMAIL = " Synthetic@example.invalid "
PASSWORD = " secret \U0001f49c password\n "
CODE = "123456"
OP_ID = "11111111-1111-4111-8111-111111111111"
CHALLENGE_ID = "22222222-2222-4222-8222-222222222222"
OTHER_CHALLENGE = "33333333-3333-4333-8333-333333333333"


class Database:
    def __init__(self):
        self.rows = {}; self.effects = 0; self.calls = []; self.fault = None

    @contextmanager
    def transaction(self):
        cursor = Cursor(self)
        try:
            yield cursor
        except Exception:
            raise
        else:
            self.rows = cursor.rows; self.effects = cursor.effects


class Cursor:
    def __init__(self, database):
        self.db = database; self.rows = copy.deepcopy(database.rows)
        self.effects = database.effects; self.rowcount = 0; self.result = None

    def execute(self, sql, params):
        self.db.calls.append((sql, params))
        self.rowcount = 0
        if sql.startswith("SELECT context_hmac"):
            self.result = copy.deepcopy(self.rows.get(tuple(params)))
        elif sql.startswith("INSERT INTO clrs_staging.native_auth_receipts"):
            actor, operation, operation_id, context, request = params
            key = (actor, operation, operation_id)
            if key in self.rows:
                raise RuntimeError("synthetic duplicate")
            self.rows[key] = (context, request, "started", None, None, None)
            self.rowcount = 1
            if self.db.fault == "insert-readback":
                self.rows[key] = (bytes(32), request, "started", None, None, None)
        elif sql.startswith("UPDATE clrs_staging.native_auth_receipts"):
            status, response, actor, operation, operation_id, context, request = params
            key = (actor, operation, operation_id); row = self.rows.get(key)
            if row and row[:2] == (context, request) and row[2] == "started":
                self.rows[key] = (context, request, "completed", status, response, datetime(2026, 10, 1))
                self.rowcount = 1
                if self.db.fault == "finish-readback":
                    self.rows[key] = (*self.rows[key][:4], '{"status":"completed","password":"hidden"}',
                                      self.rows[key][5])
        else:
            raise AssertionError("unexpected SQL")

    def fetchone(self):
        return self.result


class SensitiveReceiptTests(unittest.TestCase):
    def setUp(self):
        self.receipts = SensitiveAuthReceipts(KEY)
        self.database = Database()

    def bind(self, operation="password-reset.complete.v1", *, operation_id=OP_ID,
             actor_uid=UID, email_identity=EMAIL_IDENTITY, challenge_id=CHALLENGE_ID,
             password=PASSWORD, code=CODE):
        purpose = operation.rsplit(".", 2)[0] + ".v1"
        request = operation.endswith(".request.v1")
        return self.receipts.bind(operation, operation_id, actor_uid=actor_uid,
            email_identity=email_identity, purpose=purpose,
            challenge_id=None if request else challenge_id,
            payload={"email": EMAIL} if request else {
                "challengeId": challenge_id, "code": code, "password": password})

    def complete(self, fingerprint, *, outcome=None):
        with self.database.transaction() as cursor:
            lease = self.receipts.begin(cursor, cursor.execute, fingerprint)
            if type(lease) is AuthReceiptResolution:
                return lease
            cursor.effects += 1
            return self.receipts.finish(lease, outcome or AuthReceiptOutcome("completed"))

    def test_exact_replay_precedes_effects_and_original_payload_is_not_retained(self):
        payload = {"challengeId": CHALLENGE_ID, "code": CODE, "password": PASSWORD}
        fingerprint = self.receipts.bind("password-reset.complete.v1", OP_ID,
            actor_uid=UID, email_identity=EMAIL_IDENTITY, purpose="password-reset.v1",
            challenge_id=CHALLENGE_ID, payload=payload)
        payload["password"] = "caller later changed local dictionary"
        self.assertEqual(self.complete(fingerprint).outcome.result, {"status": "completed"})
        replay = self.complete(self.bind())
        self.assertEqual(replay.state, "completed")
        self.assertEqual(self.database.effects, 1)
        self.assertTrue(all("FOR UPDATE" in sql for sql, _ in self.database.calls
                            if sql.startswith("SELECT context_hmac")))
        parameters = repr([params for _, params in self.database.calls])
        for sensitive in (UID, EMAIL, CODE, PASSWORD, "caller later changed local dictionary"):
            self.assertNotIn(sensitive, parameters)
            self.assertNotIn(sensitive, repr(fingerprint))
        self.assertNotEqual(fingerprint.request_digest,
                            hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).digest())

    def test_changed_password_code_email_challenge_conflicts_but_actor_and_stage_are_scoped(self):
        fingerprint = self.bind()
        self.complete(fingerprint)
        for changed in [self.bind(password=PASSWORD.strip()), self.bind(code="654321"),
                        self.bind(email_identity=OTHER_EMAIL), self.bind(challenge_id=OTHER_CHALLENGE)]:
            with self.database.transaction() as cursor:
                with self.assertRaises(AuthReceiptConflict):
                    self.receipts.begin(cursor, cursor.execute, changed)
        for scoped in [self.bind(actor_uid="other-generated-actor"),
                       self.bind(operation="register-email.complete.v1")]:
            with self.database.transaction() as cursor:
                self.assertEqual(self.receipts.lookup(cursor, cursor.execute, scoped).state, "not_found")
        with self.assertRaises(AuthReceiptInvalid):
            self.receipts.bind(fingerprint.operation, OP_ID, actor_uid=UID,
                email_identity=EMAIL_IDENTITY, purpose="register-email.v1", challenge_id=CHALLENGE_ID,
                payload={"challengeId": CHALLENGE_ID, "code": CODE, "password": PASSWORD})
        self.assertEqual(self.database.effects, 1)

    def test_fixed_safe_request_refusal_and_corrupt_unknown_duplicate_fields_fail_closed(self):
        request = self.bind(operation="register-email.request.v1", actor_uid=None)
        accepted = self.complete(request, outcome=AuthReceiptOutcome("accepted", CHALLENGE_ID))
        self.assertEqual(accepted.outcome.status, 202)
        self.assertEqual(accepted.outcome.result, {"status": "accepted", "challengeId": CHALLENGE_ID})
        refused = self.bind(operation_id="44444444-4444-4444-8444-444444444444")
        self.assertEqual(self.complete(refused, outcome=AuthReceiptOutcome("refused")).outcome.status, 400)
        key = (refused.actor_identity, refused.operation, refused.operation_id)
        original = self.database.rows[key]
        for response in ['{"status":"refused","email":"secret"}',
                         '{"status":"refused","status":"completed"}',
                         '{"status":"completed"}', '{"status":"refused","challengeId":null}']:
            self.database.rows[key] = (*original[:4], response, original[5])
            with self.database.transaction() as cursor:
                with self.assertRaises(AuthReceiptUnavailable):
                    self.receipts.lookup(cursor, cursor.execute, refused)
        self.database.rows[key] = (*original[:3], True, original[4], original[5])
        with self.database.transaction() as cursor:
            with self.assertRaises(AuthReceiptUnavailable):
                self.receipts.lookup(cursor, cursor.execute, refused)

    def test_readback_failure_rolls_back_receipt_and_effects_in_callers_transaction(self):
        self.database.fault = "finish-readback"
        with self.assertRaises(AuthReceiptUnavailable):
            self.complete(self.bind())
        self.assertEqual(self.database.rows, {})
        self.assertEqual(self.database.effects, 0)
        self.database.fault = "insert-readback"
        with self.assertRaises(AuthReceiptConflict):
            self.complete(self.bind())
        self.assertEqual(self.database.rows, {})
        self.assertEqual(self.database.effects, 0)

    def test_unknown_commit_lookup_only_completed_pending_absent_no_retry_authority(self):
        fingerprint = self.bind()
        self.complete(fingerprint)  # SQL committed; model lost outward response.
        count = len(self.database.calls)
        with self.database.transaction() as cursor:
            self.assertEqual(self.receipts.lookup(cursor, cursor.execute, fingerprint).state, "completed")
        self.assertTrue(all(sql.startswith("SELECT") and "FOR UPDATE" not in sql
                            for sql, _ in self.database.calls[count:]))
        pending = self.bind(operation_id="55555555-5555-4555-8555-555555555555")
        with self.database.transaction() as cursor:
            self.receipts.begin(cursor, cursor.execute, pending)  # Caller committed only 'started'.
        count = len(self.database.calls)
        with self.database.transaction() as cursor:
            self.assertEqual(self.receipts.lookup(cursor, cursor.execute, pending).state, "pending")
            self.assertEqual(self.receipts.begin(cursor, cursor.execute, pending).state, "pending")
            absent = self.bind(operation_id="66666666-6666-4666-8666-666666666666")
            self.assertEqual(self.receipts.lookup(cursor, cursor.execute, absent).state, "not_found")
        self.assertTrue(all(sql.startswith("SELECT") for sql, _ in self.database.calls[count:]))
        self.assertEqual(self.database.effects, 1)

    def test_foreign_key_forged_fingerprint_wrong_outcome_and_cross_owner_lease_rejected(self):
        fingerprint = self.bind()
        initial = len(self.database.calls)
        for invalid in [replace(fingerprint, request_digest=bytes(32)),
                        replace(fingerprint, operation_id="not-a-uuid")]:
            with self.database.transaction() as cursor:
                with self.assertRaises(AuthReceiptInvalid):
                    self.receipts.begin(cursor, cursor.execute, invalid)
        other = SensitiveAuthReceipts(b"s" * 32)
        with self.database.transaction() as cursor:
            with self.assertRaises(AuthReceiptInvalid):
                other.lookup(cursor, cursor.execute, fingerprint)
        self.assertEqual(len(self.database.calls), initial)
        with self.database.transaction() as cursor:
            lease = self.receipts.begin(cursor, cursor.execute, fingerprint)
            count = len(self.database.calls)
            for invalid in [{"password": PASSWORD}, AuthReceiptOutcome("accepted", CHALLENGE_ID),
                            AuthReceiptOutcome("completed", CHALLENGE_ID)]:
                with self.assertRaises(AuthReceiptInvalid):
                    self.receipts.finish(lease, invalid)
            with self.assertRaises(AuthReceiptInvalid):
                other.finish(lease, AuthReceiptOutcome("completed"))
            self.assertEqual(len(self.database.calls), count)

    def test_uuid4_limits_original_unicode_spaces_and_no_operation_payload_collision(self):
        for invalid in ["ABCDEF00-1111-4111-8111-111111111111",
                        "11111111-1111-1111-8111-111111111111", None]:
            with self.assertRaises(AuthReceiptInvalid):
                self.bind(operation_id=invalid)
        for password in ["x" * 4097, "\ud800", b"not-text"]:
            with self.assertRaises(AuthReceiptInvalid):
                self.bind(password=password)
        self.assertEqual(self.bind().request_digest, self.bind().request_digest)
        self.assertNotEqual(self.bind().request_digest, self.bind(password=PASSWORD.strip()).request_digest)
        self.assertNotEqual(self.bind().request_digest, self.bind(
            operation="register-email.complete.v1").request_digest)
        # UTF-8 bound succeeds but heavily escaped JSON exceeds the body cap.
        with self.assertRaises(AuthReceiptInvalid):
            self.bind(password="\0" * 4096)
        self.assertEqual(MAX_PAYLOAD_BYTES, 8192)

    def test_malformed_operation_and_unstable_actor_scope_reject_before_sql(self):
        fingerprint = self.bind()
        for invalid in (None, []):
            with self.assertRaises(AuthReceiptInvalid):
                self.receipts.bind(invalid, OP_ID, actor_uid=UID,
                    email_identity=EMAIL_IDENTITY, purpose="password-reset.v1",
                    challenge_id=CHALLENGE_ID,
                    payload={"challengeId": CHALLENGE_ID, "code": CODE, "password": PASSWORD})
            with self.database.transaction() as cursor:
                with self.assertRaises(AuthReceiptInvalid):
                    self.receipts.begin(cursor, cursor.execute, replace(fingerprint, operation=invalid))
        for operation, actor_uid in [("register-email.request.v1", UID),
                                     ("password-reset.complete.v1", None)]:
            with self.assertRaises(AuthReceiptInvalid):
                self.bind(operation=operation, actor_uid=actor_uid)
        self.assertEqual(self.database.calls, [])


if __name__ == "__main__":
    unittest.main()
