"""Synthetic-only prepared codecs; no DB/SMTP/cloud/user credential reads."""
import copy
import hashlib
import threading
import time
import unittest
from unittest.mock import patch

from native_credentials import CredentialCodec, CredentialUnavailable, KdfBusy
from native_password_credentials import (AuthChallengeCodec, NativePasswordCodec,
    PasswordWorkPool, PARAMETERS, advance_issuance_history, revalidate_selection)
from test_native_auth import CONFIG, CONFIG_REF, UID, WRAPPING, synthetic_row


class NativePasswordTests(unittest.TestCase):
    def setUp(self):
        self.codec = NativePasswordCodec(WRAPPING)
        self.pool = PasswordWorkPool(CredentialCodec(CONFIG, CONFIG_REF, WRAPPING), self.codec)
        self.addCleanup(self.pool.close)

    def test_two_schemes_old_assertion_native_reset_and_logout_all(self):
        legacy = synthetic_row()
        old = self.pool.select(uid=UID, account_token_version=0, firebase_row=legacy)
        self.assertTrue(self.pool.verify(old.material, "user1password"))
        self.assertFalse(self.pool.verify(old.material, "wrong"))
        new = self.pool.prepare(UID, 1, "новый пароль  🔐")
        selected = self.pool.select(uid=UID, account_token_version=1, firebase_row=legacy, native_row=new)
        self.assertTrue(self.pool.verify(selected.material, "новый пароль  🔐"))
        self.assertFalse(self.pool.verify(selected.material, "user1password"))
        # Token revocation is independent of the encrypted password version.
        revoked = self.pool.select(uid=UID, account_token_version=2, firebase_row=legacy, native_row=new)
        self.assertTrue(self.pool.verify(revoked.material, "новый пароль  🔐"))
        self.assertEqual(selected.ciphertext_identity, revoked.ciphertext_identity)
        with self.assertRaises(CredentialUnavailable):
            revalidate_selection(selected, revoked)
        revalidate_selection(revoked, revoked)
        replaced = self.pool.prepare(UID, 3, "another new password")
        reset = self.pool.select(uid=UID, account_token_version=3, firebase_row=legacy, native_row=replaced)
        self.assertNotEqual(reset.ciphertext_identity, revoked.ciphertext_identity)
        with self.assertRaises(CredentialUnavailable):
            revalidate_selection(revoked, reset)
        self.assertFalse(self.pool.verify(reset.material, "новый пароль  🔐"))
        self.assertTrue(self.pool.verify(reset.material, "another new password"))
        self.assertEqual(legacy, synthetic_row())

    def test_native_presence_never_falls_back_even_corrupt_or_future_version(self):
        legacy = synthetic_row()
        native = self.pool.prepare(UID, 1, "synthetic new password")
        for bad in [{}, {**native, "scheme": "unknown"},
                    {**native, "material_ciphertext": b"x" * 80}]:
            with self.assertRaises(CredentialUnavailable):
                self.pool.select(uid=UID, account_token_version=1, firebase_row=legacy, native_row=bad)
        with self.assertRaises(CredentialUnavailable):
            self.pool.select(uid=UID, account_token_version=0, firebase_row=legacy, native_row=native)
        with self.assertRaises(CredentialUnavailable):
            self.pool.select(uid="another-uid", account_token_version=1, native_row=native)

    def test_exact_aad_fixed_parameters_ciphertext_and_separate_key(self):
        row = self.pool.prepare(UID, 4, "synthetic password")
        self.assertEqual(len(row["material_ciphertext"]), 80)
        for field, value in [("uid", UID.lower()), ("password_version", 5),
                             ("scheme", "firebase_scrypt"), ("password_version", True)]:
            with self.assertRaises(CredentialUnavailable):
                self.codec.decode({**row, field: value})
        for name in PARAMETERS:
            modified = copy.deepcopy(row)
            modified["parameters"][name] = True if name == "r" else "wrong"
            with self.assertRaises(CredentialUnavailable):
                self.codec.decode(modified)
        modified = {**row, "parameters": '{"n":32768,"n":32768}'}
        with self.assertRaises(CredentialUnavailable):
            self.codec.decode(modified)
        with self.assertRaises(CredentialUnavailable):
            NativePasswordCodec(bytes([8]) * 32).decode(row)
        second = self.pool.prepare(UID, 4, "synthetic password")
        self.assertNotEqual(self.codec.decode(row).salt, self.codec.decode(second).salt)
        self.assertNotEqual(row["material_ciphertext"], second["material_ciphertext"])

    def test_timeout_old_and_new_keep_shared_slots_until_actual_completion(self):
        entered = threading.Event(); release = threading.Event(); calls = []

        def blocked(password, **kwargs):
            calls.append(kwargs["p"])
            if len(calls) == 2:
                entered.set()
            release.wait(2)
            return bytes(kwargs["dklen"])

        pool = PasswordWorkPool(self.pool.codec, self.codec, derive=blocked)
        self.addCleanup(pool.close); self.addCleanup(release.set)
        material = self.pool.codec.decode(synthetic_row())
        with self.assertRaises(CredentialUnavailable):
            pool.verify(material, "public fixture", timeout=0.01)
        with self.assertRaises(CredentialUnavailable):
            pool.prepare(UID, 1, "public fixture", timeout=0.01)
        self.assertTrue(entered.wait(1)); self.assertEqual(calls, [1, 3])
        with self.assertRaises(KdfBusy):
            pool.prepare(UID, 1, "public fixture")
        pool.close()
        with self.assertRaises(CredentialUnavailable):
            pool.verify(material, "public fixture")
        self.assertFalse(pool._slots.acquire(blocking=False))
        release.set()
        deadline = time.monotonic() + 2
        acquired = False
        while time.monotonic() < deadline:
            if pool._slots.acquire(blocking=False):
                acquired = True; pool._slots.release(); break
            time.sleep(0.005)
        self.assertTrue(acquired)

    def test_late_result_and_submit_failure_no_adoption_or_leaked_slot(self):
        clock = [0.0]

        def late(password, **kwargs):
            clock[0] = 2.0
            return bytes(kwargs["dklen"])
        pool = PasswordWorkPool(self.pool.codec, self.codec, workers=1, derive=late, monotonic=lambda: clock[0])
        self.addCleanup(pool.close)
        with self.assertRaises(CredentialUnavailable):
            pool.prepare(UID, 1, "fixture", timeout=1.5)
        with patch.object(pool._pool, "submit", side_effect=RuntimeError("synthetic submit refusal")):
            with self.assertRaises(CredentialUnavailable):
                pool.prepare(UID, 1, "fixture")
        self.assertTrue(pool._slots.acquire(blocking=False)); pool._slots.release()

    def test_password_limits_preserve_exact_bytes_no_legacy_policy_change(self):
        calls = []

        def derive(raw, **kwargs):
            calls.append(raw)
            return hashlib.sha256(raw).digest() if kwargs["dklen"] == 32 else bytes(64)
        pool = PasswordWorkPool(self.pool.codec, self.codec, derive=derive)
        self.addCleanup(pool.close)
        for bad in [None, "", "x" * 4097, "\ud800"]:
            with self.assertRaises(CredentialUnavailable):
                pool.prepare(UID, 1, bad)
        native = pool.prepare(UID, 1, "  a\n\t😀  ")
        self.assertTrue(pool.verify(self.codec.decode(native), "  a\n\t😀  "))
        self.assertFalse(pool.verify(self.codec.decode(native), "a\n\t😀"))
        old = self.pool.codec.decode(synthetic_row())
        self.assertFalse(pool.verify(old, ""))
        self.assertIn(b"", calls)
        for bad in [True, float("nan"), float("inf"), 1.6, 0]:
            with self.assertRaises(CredentialUnavailable):
                pool.prepare(UID, 1, "fixture", timeout=bad)


class ChallengeTests(unittest.TestCase):
    def setUp(self):
        self.codec = AuthChallengeCodec(bytes([9]) * 32)
        self.binding = {"uid": UID, "email": "public@example.invalid", "purpose": "password-reset.v1",
            "challenge_id": "a20b020f-54cf-4655-a3a3-f1966f519d48", "account_token_version": 0,
            "issued_at": 1700000000, "expires_at": 1700000600, "code": "012345"}

    def test_bound_single_use_expiry_attempt_and_changed_identity(self):
        digest = self.codec.digest(**self.binding)
        def verify(**kwargs):
            return self.codec.verify(digest, now=1700000001, attempts=0, consumed=False,
                                     **{**self.binding, **kwargs})
        self.assertTrue(verify())
        for field, value in [("uid", "another"), ("email", "different@example.invalid"),
                             ("purpose", "register-email.v1"), ("account_token_version", 1),
                             ("challenge_id", "0f912eb5-5dcb-4417-a26c-af8e06b56d4e"), ("code", "012346")]:
            self.assertFalse(verify(**{field: value}))
        for now, attempts, consumed in [(1700000600, 0, False), (1699999999, 0, False),
                                        (1700000001, 5, False), (1700000001, 0, True)]:
            self.assertFalse(self.codec.verify(digest, now=now, attempts=attempts, consumed=consumed, **self.binding))
        for change in [{"expires_at": 1700000601}, {"code": "12345"},
                       {"email": " Public@example.invalid "}, {"email": "pub lic@example.invalid"},
                       {"email": "pub\u00a0lic@example.invalid"}, {"purpose": []}]:
            with self.assertRaises(CredentialUnavailable):
                self.codec.digest(**{**self.binding, **change})

    def test_issue_history_survives_new_ids_consumption_and_hour_boundaries(self):
        history = []
        for now in [10000, 10060, 10120, 10180, 10240]:
            history = advance_issuance_history(history, now)
        for now in [10299, 10300, 13599]:
            with self.assertRaises(CredentialUnavailable):
                advance_issuance_history(history, now)
        # Exactly one oldest issuance expires, not an entire fixed-hour count.
        history = advance_issuance_history(history, 13600)
        self.assertEqual(history, [10060, 10120, 10180, 10240, 13600])
        with self.assertRaises(CredentialUnavailable):
            advance_issuance_history(history, 13659)
        for malformed in [[True], [10000, 10000], [10000, 10001], [14000], [10000] * 6]:
            with self.assertRaises(CredentialUnavailable):
                advance_issuance_history(malformed, 13660)


if __name__ == "__main__":
    unittest.main()
