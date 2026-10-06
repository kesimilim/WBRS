"""Offline synthetic tests; no production secret, DB, HTTP or Firebase write."""
import base64
import copy
import json
import os
import re
from pathlib import Path
import shutil
import ssl
import subprocess
import threading
import time
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from native_credentials import (CredentialCodec, CredentialUnavailable, FirebaseScryptVerifier,
                                KdfBusy, compact_json)
from native_sessions import (NativeSessionStore, SessionTokens, SessionRejected, SessionUnavailable,
                             _timestamp, ACCOUNT_QUERY, SESSION_QUERY)
from native_auth import (NativeAuthService, NativeRejected, NativeUnavailable, NativeRateLimited,
                         BoundedRateLimiter, parse_login_body)
from profile_store import BUNDLED_CA_FILE

CONFIG = {"algorithm": "SCRYPT",
    "signerKey": "jxspr8Ki0RYycVU8zykbdLGjFQ3McFUH0uiiTvC8pVMXAn210wjLNmdZJzxUECKbm0QsEmYUSDzZvpjeJ9WmXA==",
    "saltSeparator": "Bw==", "rounds": 8, "memoryCost": 14}
PUBLIC_HASH = "lSrfV15cpx95/sZS2W9c9Kp6i/LVgQNDNC/qzrCnh1SAyZvqmZqAjTdn3aoItz+VHjoZilo78198JAdRuid5lQ=="
PUBLIC_SALT = "42xEC+ixf3L2lw=="
WRAPPING = bytes([7]) * 32
SESSION_KEY = bytes([9]) * 32
CONFIG_REF = "public-synthetic-scrypt-v0"
UID = "Case-Ä-Uid"
EMAIL = "public@example.invalid"
NOW = 1700000000
ROOT = Path(__file__).resolve().parents[3]


def node(script, data=None):
    executable = os.environ.get("CLRS_TEST_NODE_BIN") or shutil.which("node")
    if not executable:
        raise AssertionError("Node runtime is required for the cross-language fixture")
    result = subprocess.run([executable, "--input-type=module", "-e", script],
        input=json.dumps(data) if data is not None else None, text=True, capture_output=True,
        cwd=ROOT, timeout=10, check=True)
    return json.loads(result.stdout)


def synthetic_row(version=0, disabled=False):
    parameters = {"material_format": "aes256gcm-v1", "config_ref": CONFIG_REF,
        "config_identity": CredentialCodec(CONFIG, CONFIG_REF, WRAPPING).config_identity,
        "password_version": version, "providers": ["password"], "disabled": disabled,
        "email_verified": True, "valid_since": "1508893925"}
    codec = CredentialCodec(CONFIG, CONFIG_REF, WRAPPING)
    row = {"uid": UID, "scheme": "firebase_scrypt", "parameters": parameters}
    for name, part, plain, nonce in [("password_hash", "hash", PUBLIC_HASH, bytes([1]) * 12),
                                      ("password_salt", "salt", PUBLIC_SALT, bytes([2]) * 12)]:
        combined = AESGCM(WRAPPING).encrypt(nonce, plain.encode(), codec._aad(UID, parameters, part))
        row[name] = nonce + combined[-16:] + combined[:-16]
    return row


def enabled_env():
    return {"CLRS_NATIVE_AUTH_ENABLED": "1", "CLRS_NATIVE_AUTH_WRITES_ENABLED": "1",
        "CLRS_NATIVE_AUTH_DB_URL": "mysql://synthetic:synthetic@synthetic-db.example.invalid/clrs_staging?sslmode=verify-full",
        "CLRS_NATIVE_AUTH_DB_CA_FILE": str(Path(__file__).parent / "timeweb-ca.pem")}


class FakeDatabase:
    """mysql-shaped transaction double; no connector can reach the network."""
    def __init__(self):
        self.state = {"accounts": {UID: {"uid": UID, "email": EMAIL, "disabled": 0,
            "lifecycle": "active", "token_version": 0, "email_verified": 1}},
            "credentials": {UID: synthetic_row()}, "sessions": {}}
        self.calls = []; self.commits = 0; self.fail_commit = False; self.extra_grant = False
        self.fail_write_commit = False; self._lock = threading.RLock()
        self.require_ssl = False
        self.target = "clrs_staging"; self.clock = NOW; self.configs = []

    def connect(self, **kwargs):
        self.configs.append(kwargs)
        return FakeConnection(self)


class FakeConnection:
    def __init__(self, db):
        self.db = db; self.working = None; self.result = []; self.rowcount = 0
        self._held = False

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def begin(self):
        self.db._lock.acquire(); self._held = True
        self.working = copy.deepcopy(self.db.state)

    def commit(self):
        changed = self.working != self.db.state
        self.db.state = self.working
        self.working = None; self.db.commits += 1
        if self._held:
            self.db._lock.release(); self._held = False
        if self.db.fail_commit or (changed and self.db.fail_write_commit):
            self.db.fail_commit = False; self.db.fail_write_commit = False
            raise RuntimeError("Synthetic lost COMMIT response")

    def rollback(self):
        self.working = None
        if self._held:
            self.db._lock.release(); self._held = False

    def close(self):
        pass

    def fetchone(self):
        return self.result[0] if self.result else None

    def fetchall(self):
        return self.result

    def _account_row(self, account):
        credential = self.working["credentials"].get(account["uid"])
        parts = [credential[name] for name in ["scheme", "password_hash", "password_salt", "parameters"]] if credential else [None] * 4
        return (account["uid"], account["disabled"], account["lifecycle"], account["token_version"], account["email_verified"], *parts)

    def execute(self, sql, params=()):
        self.db.calls.append((sql, copy.deepcopy(params)))
        self.rowcount = 0; self.result = []
        # Model MySQL8.4 lock privileges: accounts/credentials are SELECT-only.
        # An unqualified FOR UPDATE on their joined query is forbidden.
        if "FOR UPDATE" in sql:
            clause = re.search(r"FOR UPDATE(?: OF ([a-z, ]+?)(?= FOR SHARE|$))?", sql)
            locked = set(clause[1].replace(" ", "").split(",")) if clause[1] else {"s", "a", "c"}
            if not locked <= {"s"}:
                raise RuntimeError("Synthetic denied locking a SELECT-only table for update")
        if sql == "SHOW GRANTS":
            suffix = " REQUIRE SSL" if self.db.require_ssl else ""
            self.result = [("GRANT USAGE ON *.* TO `native`@`%`" + suffix,),
                ("GRANT SELECT ON `clrs_staging`.`accounts` TO `native`@`%`",),
                ("GRANT SELECT ON `clrs_staging`.`auth_credentials` TO `native`@`%`",),
                ("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.`device_sessions` TO `native`@`%`",)]
            if self.db.extra_grant:
                self.result.append(("GRANT DELETE ON `clrs_staging`.`device_sessions` TO `native`@`%`",))
        elif sql == "SELECT DATABASE(), VERSION()":
            self.result = [(self.db.target, "8.4.6")]
        elif sql.startswith("SHOW SESSION STATUS"):
            self.result = [("Ssl_cipher", "TLS_AES_256_GCM_SHA384")]
        elif sql.startswith("SET "):
            pass
        elif "WHERE a.email_normalized = %s" in sql:
            self.result = [self._account_row(row) for row in self.working["accounts"].values() if row["email"] == params[0]]
        elif "WHERE a.uid = %s" in sql:
            row = self.working["accounts"].get(params[0])
            self.result = [self._account_row(row)] if row else []
        elif "WHERE s.session_id = %s" in sql:
            session = self.working["sessions"].get(params[0])
            if session:
                account = self.working["accounts"][session["uid"]]
                self.result = [tuple(session[name] for name in ["session_id", "uid", "device_id", "refresh_token_hash",
                    "issued_at", "expires_at", "revoked_at", "rotated_from"]) +
                    tuple(account[name] for name in ["disabled", "lifecycle", "token_version", "email_verified"])]
        elif sql.startswith("INSERT INTO clrs_staging.device_sessions"):
            row = dict(zip(["session_id", "uid", "device_id", "refresh_token_hash", "rotated_from", "issued_at", "expires_at"], params))
            self.assert_not_duplicate(row["session_id"])
            row["revoked_at"] = None
            self.working["sessions"][row["session_id"]] = row; self.rowcount = 1
        elif sql.startswith("UPDATE clrs_staging.device_sessions"):
            for row in self.working["sessions"].values():
                if row["revoked_at"] is not None:
                    continue
                if "WHERE session_id" in sql:
                    matches = row["session_id"] == params[0]
                elif "AND device_id" in sql:
                    matches = row["uid"] == params[0] and row["device_id"] == params[1]
                else:
                    matches = row["uid"] == params[0]
                if matches:
                    row["revoked_at"] = _timestamp(self.db.clock); self.rowcount += 1
        else:
            raise AssertionError("Unexpected synthetic SQL")

    def assert_not_duplicate(self, session_id):
        if session_id in self.working["sessions"]:
            raise AssertionError("duplicate synthetic session")


class NativeAuthTests(unittest.TestCase):
    def setUp(self):
        self.codec = CredentialCodec(CONFIG, CONFIG_REF, WRAPPING)
        self.db = FakeDatabase()
        self.env = enabled_env()
        self.store = NativeSessionStore(self.env, self.codec, SessionTokens(SESSION_KEY),
            connect=self.db.connect, clock=lambda: self.db.clock)
        self.verifier = FirebaseScryptVerifier(self.codec)
        self.service = NativeAuthService(self.env, self.store, self.verifier, BoundedRateLimiter(SESSION_KEY))
        self.body = {"email": EMAIL, "password": "user1password", "deviceId": "synthetic-device"}

    def tearDown(self):
        self.service.close()

    def login(self, device="synthetic-device"):
        return self.service.login({**self.body, "deviceId": device}, peer="synthetic-peer")

    def test_absent_ca_uses_bundled_verified_tls_and_bad_explicit_ca_never_connects(self):
        self.env.pop("CLRS_NATIVE_AUTH_DB_CA_FILE")
        with patch("profile_store.ssl.create_default_context", wraps=ssl.create_default_context) as create_context:
            self.assertEqual("configured", self.store._transaction(lambda cursor: "configured",
                deadline=time.monotonic() + 5))
            create_context.assert_called_once_with(cafile=BUNDLED_CA_FILE)
        config = self.db.configs[-1]
        self.assertTrue(Path(BUNDLED_CA_FILE).is_absolute())
        self.assertTrue(config["ssl"].check_hostname)
        self.assertEqual(ssl.CERT_REQUIRED, config["ssl"].verify_mode)
        for key in ["CLRS_NATIVE_AUTH_DB_CA_FILE", "CLRS_DB_CA_FILE"]:
            for value in ["", "relative-ca.pem", "/__clrs_synthetic__/missing-ca.pem"]:
                with self.subTest(key=key, value=value):
                    self.env[key] = value
                    before = len(self.db.configs)
                    with self.assertRaises(SessionUnavailable):
                        self.store._transaction(lambda cursor: self.fail("invalid CA reached action"),
                            deadline=time.monotonic() + 5)
                    self.assertEqual(before, len(self.db.configs))
                    self.env.pop(key)

    def test_require_ssl_usage_grant_allows_login_but_other_suffixes_and_scopes_fail(self):
        self.db.require_ssl = True
        tokens = self.login()
        self.assertEqual(UID, self.store.authorize(tokens["accessToken"], deadline=time.monotonic() + 5).uid)
        rows = [("GRANT USAGE ON *.* TO `native`@`%` REQUIRE SSL",),
            ("GRANT SELECT ON `clrs_staging`.`accounts` TO `native`@`%`",),
            ("GRANT SELECT ON `clrs_staging`.`auth_credentials` TO `native`@`%`",),
            ("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.`device_sessions` TO `native`@`%`",)]
        self.store._grants(rows)
        for index, bad in [
            (0, rows[0][0] + " WITH GRANT OPTION"),
            (0, rows[0][0].replace("REQUIRE SSL", "REQUIRE X509")),
            (0, rows[0][0].replace("USAGE", "SELECT")),
            (1, rows[1][0] + " REQUIRE SSL"),
            (1, rows[1][0].replace("`clrs_staging`.`accounts`", "`clrs_staging`.*")),
            (3, rows[3][0].replace("SELECT, INSERT, UPDATE", "SELECT, INSERT, UPDATE, DELETE")),
        ]:
            with self.subTest(grant=index):
                altered = list(rows); altered[index] = (bad,)
                with self.assertRaises(SessionUnavailable):
                    self.store._grants(altered)

    def test_limited_grants_shared_account_lock_and_exclusive_session_lock_keep_rechecks(self):
        # Demonstrate the original query's concrete privilege failure.
        connection = self.db.connect(); connection.begin()
        try:
            with self.assertRaises(RuntimeError):
                connection.execute(ACCOUNT_QUERY.replace("FOR SHARE OF a, c", "FOR UPDATE"), (UID,))
        finally:
            connection.rollback()
        tokens = self.login()
        rotated = self.service.refresh(tokens["refreshToken"], peer="synthetic-peer")
        self.assertEqual(UID, self.store.authorize(rotated["accessToken"], deadline=time.monotonic() + 5).uid)
        locking_sql = [sql for sql, _ in self.db.calls if "FOR SHARE OF a, c" in sql or "FOR UPDATE OF s" in sql]
        self.assertIn(ACCOUNT_QUERY, locking_sql)
        self.assertIn(SESSION_QUERY + " FOR UPDATE OF s FOR SHARE OF a", locking_sql)
        self.db.state["accounts"][UID]["disabled"] = 1
        with self.assertRaises(SessionRejected):
            self.store.authorize(rotated["accessToken"], deadline=time.monotonic() + 5)
        self.db.state["accounts"][UID]["disabled"] = 0
        self.db.state["accounts"][UID]["token_version"] += 1
        with self.assertRaises(SessionRejected):
            self.store.authorize(rotated["accessToken"], deadline=time.monotonic() + 5)

    def test_official_firebase_vector_and_exact_whitespace(self):
        material = self.codec.decode(synthetic_row())
        self.assertTrue(self.verifier.verify(material, "user1password"))
        self.assertFalse(self.verifier.verify(material, "wrong-password"))
        self.assertFalse(self.verifier.verify(material, " user1password "))

    def test_node_ciphertext_decodes_in_python_for_both_version_types(self):
        script = """
        import { prepareEncryptedCredentialRow } from './server/timeweb/auth-credential-storage.mjs';
        import { credentialRecord } from './server/timeweb/auth-credentials-core.mjs';
        const data = JSON.parse(await new Promise(r => { let s=''; process.stdin.on('data',x=>s+=x);process.stdin.on('end',()=>r(s)); }));
        const rows = [0,'0'].map(version => {
          const record=credentialRecord({localId:data.uid,providerUserInfo:[{providerId:'password'}],
            passwordHash:data.hash,salt:data.salt,version,disabled:false,emailVerified:true,validSince:'1508893925'},'SCRYPT');
          const row=prepareEncryptedCredentialRow(record,{hashConfig:data.config,configRef:data.ref,wrappingKey:Buffer.alloc(32,7)});
          return {...row,password_hash:row.password_hash.toString('base64'),password_salt:row.password_salt.toString('base64')};
        });console.log(JSON.stringify(rows));
        """
        fixture = node(script, {"uid": UID, "hash": PUBLIC_HASH, "salt": PUBLIC_SALT, "config": CONFIG, "ref": CONFIG_REF})
        for row in fixture:
            row["password_hash"] = base64.b64decode(row["password_hash"])
            row["password_salt"] = base64.b64decode(row["password_salt"])
            row["parameters"] = dict(sorted(row["parameters"].items()))
            material = self.codec.decode(row)
            self.assertEqual(material.password_hash, PUBLIC_HASH)
            self.assertEqual(material.password_salt, PUBLIC_SALT)
            self.assertTrue(self.verifier.verify(material, "user1password"))

    def test_python_ciphertext_decodes_in_existing_node_adapter(self):
        script = """
        import { decodeEncryptedCredentialRow } from './server/timeweb/auth-credential-storage.mjs';
        const data=JSON.parse(await new Promise(r=>{let s='';process.stdin.on('data',x=>s+=x);process.stdin.on('end',()=>r(s));}));
        const row={...data.row,password_hash:Buffer.from(data.row.password_hash,'base64'),password_salt:Buffer.from(data.row.password_salt,'base64')};
        const record=decodeEncryptedCredentialRow(row,{hashConfig:data.config,configRef:data.ref,wrappingKey:Buffer.alloc(32,7)});
        console.log(JSON.stringify({uid:record.uid,hash:record.material.passwordHash,salt:record.material.passwordSalt,version:record.material.passwordVersion}));
        """
        row = synthetic_row("0")
        for name in ["password_hash", "password_salt"]:
            row[name] = base64.b64encode(row[name]).decode()
        result = node(script, {"row": row, "config": CONFIG, "ref": CONFIG_REF})
        self.assertEqual(result, {"uid": UID, "hash": PUBLIC_HASH, "salt": PUBLIC_SALT, "version": "0"})

    def test_gcm_wrong_uid_version_status_key_and_unknown_fields_fail(self):
        for kind in ["uid", "version", "status", "tag", "unknown"]:
            row = synthetic_row()
            if kind == "uid": row["uid"] = "different-uid"
            if kind == "version": row["parameters"]["password_version"] = "0"
            if kind == "status": row["parameters"]["disabled"] = True
            if kind == "tag": row["password_hash"] = bytes(100)
            if kind == "unknown": row["parameters"]["extra"] = True
            with self.assertRaises(CredentialUnavailable): self.codec.decode(row)
        with self.assertRaises(CredentialUnavailable):
            CredentialCodec(CONFIG, CONFIG_REF, bytes([8]) * 32).decode(synthetic_row())
        with self.assertRaises(CredentialUnavailable):
            CredentialCodec({**CONFIG, "memoryCost": 18}, CONFIG_REF, WRAPPING)

    def test_login_stores_no_raw_tokens_and_verifies_tls_and_private_role(self):
        result = self.login()
        identity = self.service.authorize(result["accessToken"], peer="synthetic-peer")
        self.assertEqual(identity.uid, UID)
        self.assertEqual(identity.expires_at, NOW + 900)
        self.assertEqual(len(self.db.state["sessions"]), 1)
        row = next(iter(self.db.state["sessions"].values()))
        self.assertEqual(len(row["refresh_token_hash"]), 52)
        self.assertEqual(row["refresh_token_hash"][:4], b"NS1\0")
        for token in [result["accessToken"], result["refreshToken"]]:
            self.assertNotIn(token.encode(), row["refresh_token_hash"])
            for _, params in self.db.calls: self.assertNotIn(token, params)
        for config in self.db.configs:
            self.assertTrue(config["ssl"].check_hostname)
            self.assertEqual(config["ssl"].verify_mode, ssl.CERT_REQUIRED)
            self.assertEqual(config["database"], "clrs_staging")
            self.assertEqual(config["read_timeout"], 2)
        self.assertFalse(any("DELETE" in sql or "UPDATE clrs_staging.accounts" in sql or "CREATE TABLE" in sql for sql, _ in self.db.calls))

    def test_wrong_password_and_missing_email_have_same_rejection_no_session(self):
        for body in [{**self.body, "password": "wrong-password"}, {**self.body, "email": "missing@example.invalid"}]:
            with self.assertRaises(NativeRejected): self.service.login(body, peer="synthetic-peer")
        self.assertEqual(self.db.state["sessions"], {})

    def test_blocked_deleted_disabled_and_credential_disabled_reject_login(self):
        for state in ["blocked", "deleted", "disabled", "credential-disabled"]:
            self.db.state["accounts"][UID].update(disabled=0, lifecycle="active")
            self.db.state["credentials"][UID] = synthetic_row()
            if state in ["blocked", "deleted"]: self.db.state["accounts"][UID]["lifecycle"] = state
            if state == "disabled": self.db.state["accounts"][UID]["disabled"] = 1
            if state == "credential-disabled": self.db.state["credentials"][UID] = synthetic_row(disabled=True)
            with self.assertRaises(NativeRejected): self.login()
        self.assertEqual(self.db.state["sessions"], {})

    def test_account_blocked_during_kdf_cannot_create_session(self):
        original = self.verifier.verify
        def changed(material, password, **kwargs):
            result = original(material, password, **kwargs)
            self.db.state["accounts"][UID]["lifecycle"] = "blocked"
            return result
        self.verifier.verify = changed
        with self.assertRaises(NativeRejected): self.login()
        self.assertEqual(self.db.state["sessions"], {})

    def test_credential_changed_during_kdf_cannot_create_session(self):
        original = self.verifier.verify
        def changed(material, password, **kwargs):
            result = original(material, password, **kwargs)
            # Re-encryption is enough to prove the snapshot no longer matches.
            self.db.state["credentials"][UID]["password_hash"] = bytes(100)
            return result
        self.verifier.verify = changed
        with self.assertRaises(NativeUnavailable): self.login()
        self.assertEqual(self.db.state["sessions"], {})

    def test_current_lifecycle_disabled_and_token_version_checked_on_every_access(self):
        result = self.login()
        for key, value in [("lifecycle", "blocked"), ("lifecycle", "deleted"), ("disabled", 1), ("token_version", 1)]:
            before = self.db.state["accounts"][UID][key]
            self.db.state["accounts"][UID][key] = value
            with self.assertRaises(NativeRejected): self.service.authorize(result["accessToken"], peer="synthetic-peer")
            self.db.state["accounts"][UID][key] = before

    def test_access_expiry_and_refresh_expiry(self):
        result = self.login()
        self.db.clock = NOW + 900
        with self.assertRaises(NativeRejected): self.service.authorize(result["accessToken"], peer="synthetic-peer")
        rotated = self.service.refresh(result["refreshToken"], peer="synthetic-peer")
        self.assertEqual(self.service.authorize(rotated["accessToken"], peer="synthetic-peer").uid, UID)
        self.db.clock += SessionTokens.REFRESH_TTL
        with self.assertRaises(NativeRejected): self.service.refresh(rotated["refreshToken"], peer="synthetic-peer")

    def test_refresh_rotates_atomically_and_valid_replay_revokes_device_before_401(self):
        first = self.login()
        rotated = self.service.refresh(first["refreshToken"], peer="synthetic-peer")
        self.assertNotEqual(first["refreshToken"], rotated["refreshToken"])
        self.assertEqual(len(self.db.state["sessions"]), 2)
        with self.assertRaises(NativeRejected): self.service.authorize(first["accessToken"], peer="synthetic-peer")
        commits = self.db.commits
        with self.assertRaises(NativeRejected): self.service.refresh(first["refreshToken"], peer="synthetic-peer")
        self.assertEqual(self.db.commits, commits + 1)
        self.assertTrue(all(row["revoked_at"] is not None for row in self.db.state["sessions"].values()))
        with self.assertRaises(NativeRejected): self.service.authorize(rotated["accessToken"], peer="synthetic-peer")

    def test_invalid_refresh_proof_does_not_revoke_sessions(self):
        first = self.login()
        rotated = self.service.refresh(first["refreshToken"], peer="synthetic-peer")
        parts = first["refreshToken"].split(".")
        wrong = parts[0] + "." + parts[1] + "." + base64.urlsafe_b64encode(bytes(32)).decode().rstrip("=")
        before = copy.deepcopy(self.db.state["sessions"])
        with self.assertRaises(NativeRejected): self.service.refresh(wrong, peer="synthetic-peer")
        self.assertEqual(self.db.state["sessions"], before)
        self.assertEqual(self.service.authorize(rotated["accessToken"], peer="synthetic-peer").uid, UID)

    def test_parallel_refresh_has_one_rotation_then_authenticated_replay_revocation(self):
        first = self.login(); barrier = threading.Barrier(2); results = []; rejected = []
        def refresh():
            barrier.wait(1)
            try: results.append(self.service.refresh(first["refreshToken"], peer="synthetic-peer"))
            except NativeRejected: rejected.append(1)
        threads = [threading.Thread(target=refresh) for _ in range(2)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(2)
        self.assertEqual(len(results), 1); self.assertEqual(len(rejected), 1)
        self.assertTrue(all(row["revoked_at"] is not None for row in self.db.state["sessions"].values()))

    def test_lost_write_commit_returns_no_tokens_and_never_retries_insert(self):
        self.db.fail_write_commit = True
        with self.assertRaises(NativeUnavailable): self.login()
        self.assertEqual(len(self.db.state["sessions"]), 1)
        self.assertEqual(sum(sql.startswith("INSERT") for sql, _ in self.db.calls), 1)

    def test_logout_current_and_all_sessions(self):
        first = self.login("device-one"); second = self.login("device-two")
        self.service.logout(first["accessToken"], peer="synthetic-peer")
        with self.assertRaises(NativeRejected): self.service.authorize(first["accessToken"], peer="synthetic-peer")
        self.assertEqual(self.service.authorize(second["accessToken"], peer="synthetic-peer").uid, UID)
        self.service.logout(second["accessToken"], peer="synthetic-peer", all_sessions=True)
        self.assertTrue(all(row["revoked_at"] is not None for row in self.db.state["sessions"].values()))

    def test_wrong_role_target_flags_and_uncertain_commit_fail_closed(self):
        for kind in ["role", "target", "off"]:
            self.db.extra_grant = kind == "role"
            self.db.target = "default_db" if kind == "target" else "clrs_staging"
            self.env["CLRS_NATIVE_AUTH_ENABLED"] = "0" if kind == "off" else "1"
            with self.assertRaises(NativeUnavailable): self.login()
            self.assertEqual(self.db.state["sessions"], {})
        self.env["CLRS_NATIVE_AUTH_ENABLED"] = "1"
        self.db.fail_commit = True
        with self.assertRaises(NativeUnavailable): self.login()
        self.assertEqual(self.db.state["sessions"], {})  # read_login COMMIT was lost, before any INSERT

    def test_session_envelope_uid_device_timestamps_and_refresh_hash_are_access_bound(self):
        first = self.login(); original = copy.deepcopy(self.db.state["sessions"])
        session_id = first["accessToken"].split(".")[1]
        for name, value in [("device_id", "foreign-device"), ("issued_at", _timestamp(NOW - 1)),
                            ("refresh_token_hash", b"NS1\0" + bytes(48))]:
            self.db.state["sessions"] = copy.deepcopy(original)
            self.db.state["sessions"][session_id][name] = value
            with self.assertRaises((NativeRejected, NativeUnavailable)):
                self.service.authorize(first["accessToken"], peer="synthetic-peer")

    def test_request_duplicate_keys_unknown_fields_and_byte_limits(self):
        valid = json.dumps(self.body).encode()
        self.assertEqual(parse_login_body(valid), self.body)
        for raw in [b'{"email":"a","email":"b"}', b'{}', b'x' * 8193, b'{"uid":"target"}',
                    b'{"x":' + b'[' * 2000 + b'0' + b']' * 2000 + b'}']:
            with self.assertRaises(NativeRejected): parse_login_body(raw)
        with self.assertRaises(NativeRejected): self.service.login({**self.body, "password": "Ю" * 2049}, peer="synthetic-peer")
        with self.assertRaises(NativeRejected): self.service.login({**self.body, "uid": UID}, peer="synthetic-peer")
        with self.assertRaises(NativeRejected): self.service.login({**self.body, "password": "\ud800"}, peer="synthetic-peer")

    def test_email_rate_limit_and_capacity_are_bounded(self):
        limiter = BoundedRateLimiter(SESSION_KEY, capacity=2, clock=lambda: 0)
        limiter.consume("peer", "one", 1)
        limiter.consume("peer", "two", 1)
        with self.assertRaises(NativeRateLimited): limiter.consume("peer", "one", 1)
        with self.assertRaises(NativeRateLimited): limiter.consume("peer", "three", 1)
        for _ in range(5):
            with self.assertRaises(NativeRejected): self.service.login({**self.body, "password": "wrong"}, peer="synthetic-peer")
        with self.assertRaises(NativeRateLimited): self.login()

    def test_default_off_from_env_never_initializes_secret_or_db(self):
        self.assertIsNone(NativeAuthService.from_env({}))
        self.assertIsNone(NativeAuthService.from_env({"CLRS_NATIVE_AUTH_ENABLED": "1"}))
        with self.assertRaises(NativeUnavailable): NativeAuthService.from_env(enabled_env())

    def test_kdf_timeout_keeps_bounded_worker_slots_until_completion(self):
        release = threading.Event(); started = threading.Event(); calls = []
        def derive(*args, **kwargs):
            calls.append(1)
            if len(calls) == 2: started.set()
            release.wait(2)
            return bytes(64)
        verifier = FirebaseScryptVerifier(self.codec, derive=derive)
        material = self.codec.decode(synthetic_row())
        errors = []
        def run():
            try: verifier.verify(material, "synthetic", timeout=0.02)
            except CredentialUnavailable: errors.append(1)
        threads = [threading.Thread(target=run) for _ in range(2)]
        try:
            for thread in threads: thread.start()
            self.assertTrue(started.wait(1))
            for thread in threads: thread.join(1)
            self.assertEqual(len(errors), 2)
            with self.assertRaises(KdfBusy): verifier.verify(material, "synthetic", timeout=0.02)
        finally:
            release.set()
            verifier.close()


if __name__ == "__main__":
    unittest.main()
