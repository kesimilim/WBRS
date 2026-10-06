"""Targeted provider-role tests; only synthetic connectors and account data."""
import time
import unittest

import test_native_auth as native_fixture
import test_legacy_conversation_read as legacy_fixture
from native_credentials import CredentialCodec
from native_sessions import NativeSessionStore, SessionTokens, SessionRejected, SessionUnavailable
from legacy_conversation_read import LegacyReadRejected, LegacyReadUnavailable


NATIVE_FLAG = "CLRS_NATIVE_AUTH_PERMISSION_MODEL"
LEGACY_FLAG = "CLRS_LEGACY_READ_PERMISSION_MODEL"
PROVIDER_MODEL = "provider-database-v1"
STRICT_MODEL = "strict-tables-v1"


def grants(privileges, *, require_ssl=False):
    return [("GRANT USAGE ON *.* TO `synthetic`@`%`" + (" REQUIRE SSL" if require_ssl else ""),),
        (f"GRANT {privileges} ON `clrs_staging`.* TO `synthetic`@`%`",)]


class ProviderNativeConnection(native_fixture.FakeConnection):
    def execute(self, sql, params=()):
        if sql == "SHOW GRANTS":
            self.db.calls.append((sql, ()))
            self.result = grants("SELECT, INSERT, UPDATE", require_ssl=True)
        else:
            super().execute(sql, params)


class ProviderNativeDatabase(native_fixture.FakeDatabase):
    def connect(self, **config):
        self.configs.append(config)
        return ProviderNativeConnection(self)


class ProviderLegacyConnection(legacy_fixture.FakeConnection):
    def execute(self, sql, parameters=()):
        if sql == "SHOW GRANTS":
            self.db.calls.append((sql, ()))
            self.result = grants("SELECT", require_ssl=True)
        else:
            super().execute(sql, parameters)


class ProviderLegacyDatabase(legacy_fixture.FakeDatabase):
    def connect(self, **config):
        self.configs.append(config)
        connection = ProviderLegacyConnection(self)
        self.connections.append(connection)
        return connection


class RuntimePermissionModelTests(unittest.TestCase):
    def native(self, model=None, *, provider=False):
        db = ProviderNativeDatabase() if provider else native_fixture.FakeDatabase()
        env = native_fixture.enabled_env()
        if model is not None:
            env[NATIVE_FLAG] = model
        codec = CredentialCodec(native_fixture.CONFIG, native_fixture.CONFIG_REF, native_fixture.WRAPPING)
        store = NativeSessionStore(env, codec, SessionTokens(native_fixture.SESSION_KEY),
            connect=db.connect, clock=lambda: db.clock)
        return db, store

    def legacy(self, model=None, *, provider=False):
        db = ProviderLegacyDatabase() if provider else legacy_fixture.FakeDatabase()
        db.base()
        env = legacy_fixture.enabled()
        if model is not None:
            env[LEGACY_FLAG] = model
        return db, db.service(env=env)

    def test_default_and_explicit_strict_models_preserve_exact_tables_and_reject_database_grants(self):
        for model in [None, STRICT_MODEL]:
            with self.subTest(model=model):
                db, store = self.native(model)
                self.assertEqual(STRICT_MODEL, store.permission_model)
                self.assertIsNotNone(store.read_login(native_fixture.EMAIL, deadline=time.monotonic() + 5))
                with self.assertRaises(SessionUnavailable):
                    store._grants(grants("SELECT, INSERT, UPDATE"))
                legacy_db, service = self.legacy(model)
                self.assertEqual(STRICT_MODEL, service.permission_model)
                self.assertEqual([], service.personal_messages(legacy_fixture.identity(), "old-room")["items"])
                with self.assertRaises(LegacyReadUnavailable):
                    service._grants(grants("SELECT"))

    def test_provider_model_accepts_only_its_exact_database_role_and_reports_auditable_label(self):
        _, store = self.native(PROVIDER_MODEL)
        _, service = self.legacy(PROVIDER_MODEL)
        self.assertEqual(PROVIDER_MODEL, store.permission_model)
        self.assertEqual(PROVIDER_MODEL, service.permission_model)
        for require_ssl in [False, True]:
            store._grants(grants("UPDATE, SELECT, INSERT", require_ssl=require_ssl))
            service._grants(grants("SELECT", require_ssl=require_ssl))

    def test_native_provider_model_rejects_global_other_database_roles_ddl_delete_options_and_mixed_grants(self):
        _, store = self.native(PROVIDER_MODEL)
        allowed = grants("SELECT, INSERT, UPDATE", require_ssl=True)
        variants = [
            [allowed[1]], [allowed[0]], allowed + [allowed[0]], allowed + [allowed[1]],
            [allowed[0], (allowed[1][0].replace("`clrs_staging`.*", "*.*"),)],
            [allowed[0], (allowed[1][0].replace("clrs_staging", "default_db"),)],
            allowed + [("GRANT SELECT ON `clrs_staging`.`accounts` TO `synthetic`@`%`",)],
            allowed + [("GRANT `synthetic_role`@`%` TO `synthetic`@`%`",)],
            [allowed[0], (allowed[1][0] + " WITH GRANT OPTION",)],
            [allowed[0], (allowed[1][0] + " REQUIRE SSL",)],
            [(allowed[0][0].replace("REQUIRE SSL", "REQUIRE X509"),), allowed[1]],
        ]
        for privileges in ["SELECT", "SELECT, INSERT", "SELECT, UPDATE", "SELECT, INSERT, UPDATE, DELETE",
                "SELECT, INSERT, UPDATE, CREATE", "SELECT, INSERT, UPDATE, REFERENCES",
                "SELECT, INSERT, UPDATE, CREATE USER", "ALL PRIVILEGES", "SELECT, INSERT, UPDATE, SELECT"]:
            variants.append(grants(privileges))
        for index, rows in enumerate(variants):
            with self.subTest(index=index):
                with self.assertRaises(SessionUnavailable):
                    store._grants(rows)

    def test_legacy_provider_model_rejects_global_other_database_roles_extra_permissions_and_mixed_grants(self):
        _, service = self.legacy(PROVIDER_MODEL)
        allowed = grants("SELECT", require_ssl=True)
        variants = [
            [allowed[1]], [allowed[0]], allowed + [allowed[0]], allowed + [allowed[1]],
            [allowed[0], (allowed[1][0].replace("`clrs_staging`.*", "*.*"),)],
            [allowed[0], (allowed[1][0].replace("clrs_staging", "default_db"),)],
            allowed + [("GRANT SELECT ON `clrs_staging`.`accounts` TO `synthetic`@`%`",)],
            allowed + [("GRANT `synthetic_role`@`%` TO `synthetic`@`%`",)],
            [allowed[0], (allowed[1][0] + " WITH GRANT OPTION",)],
            [allowed[0], (allowed[1][0] + " REQUIRE SSL",)],
        ]
        for privileges in ["SELECT, INSERT", "SELECT, UPDATE", "SELECT, DELETE", "SELECT, CREATE",
                "SELECT, REFERENCES", "SELECT, CREATE USER", "ALL PRIVILEGES", "SELECT, SELECT", "USAGE"]:
            variants.append(grants(privileges))
        for index, rows in enumerate(variants):
            with self.subTest(index=index):
                with self.assertRaises(LegacyReadUnavailable):
                    service._grants(rows)

    def test_unknown_permission_models_fail_before_connect_and_each_flag_is_service_specific(self):
        for model in ["", "1", "database", "provider-database-v2", True, []]:
            with self.subTest(model=model):
                db, store = self.native(STRICT_MODEL)
                store._env[NATIVE_FLAG] = model
                with self.assertRaises(SessionUnavailable):
                    store.read_login(native_fixture.EMAIL, deadline=time.monotonic() + 5)
                self.assertEqual([], db.configs)
                legacy_db, service = self.legacy(STRICT_MODEL)
                service._env[LEGACY_FLAG] = model
                with self.assertRaises(LegacyReadUnavailable):
                    service.personal_messages(legacy_fixture.identity(), "old-room")
                self.assertEqual([], legacy_db.configs)
        _, store = self.native()
        store._env[LEGACY_FLAG] = PROVIDER_MODEL
        self.assertEqual(STRICT_MODEL, store.permission_model)
        _, service = self.legacy()
        service._env[NATIVE_FLAG] = PROVIDER_MODEL
        self.assertEqual(STRICT_MODEL, service.permission_model)

    def test_provider_flag_does_not_enable_routes_or_bypass_existing_snapshot_gates(self):
        db, store = self.native(PROVIDER_MODEL, provider=True)
        store._env["CLRS_NATIVE_AUTH_ENABLED"] = "0"
        with self.assertRaises(SessionUnavailable):
            store.read_login(native_fixture.EMAIL, deadline=time.monotonic() + 5)
        self.assertEqual([], db.configs)
        for flag, value in [("CLRS_LEGACY_READ_ENABLED", "0"),
                ("CLRS_LEGACY_READ_SNAPSHOT_REVIEWED", "0"),
                ("CLRS_LEGACY_READ_SOURCE_SHA256", "invalid")]:
            legacy_db, service = self.legacy(PROVIDER_MODEL, provider=True)
            service._env[flag] = value
            with self.assertRaises(LegacyReadUnavailable):
                service.personal_messages(legacy_fixture.identity(), "old-room")
            self.assertEqual([], legacy_db.configs)

    def test_provider_native_transaction_keeps_account_version_disabled_and_snapshot_rechecks(self):
        db, store = self.native(PROVIDER_MODEL, provider=True)
        snapshot = store.read_login(native_fixture.EMAIL, deadline=time.monotonic() + 5)
        # This exercises the post-password-verification transaction; no KDF/mock login is implied.
        tokens = store.issue(snapshot, "synthetic-device", deadline=time.monotonic() + 5)
        rotated = store.refresh(tokens["refreshToken"], deadline=time.monotonic() + 5)
        self.assertEqual(native_fixture.UID, store.authorize(rotated["accessToken"], deadline=time.monotonic() + 5).uid)
        for change in ["disabled", "token_version"]:
            db.state["accounts"][native_fixture.UID][change] += 1
            with self.assertRaises(SessionRejected):
                store.authorize(rotated["accessToken"], deadline=time.monotonic() + 5)
            with self.assertRaises(SessionRejected):
                store.issue(snapshot, "synthetic-device", deadline=time.monotonic() + 5)
            db.state["accounts"][native_fixture.UID][change] -= 1
        writes = [sql for sql, _ in db.calls if sql.startswith(("INSERT", "UPDATE"))]
        self.assertTrue(writes)
        self.assertTrue(all(sql.startswith(("INSERT INTO clrs_staging.device_sessions",
            "UPDATE clrs_staging.device_sessions")) for sql in writes))

    def test_provider_legacy_read_preserves_own_membership_active_account_tls_and_read_only_transaction(self):
        db, service = self.legacy(PROVIDER_MODEL, provider=True)
        db.message("chats/old-room/chats/one")
        self.assertEqual(1, len(service.personal_messages(legacy_fixture.identity(), "old-room")["items"]))
        with self.assertRaises(LegacyReadRejected):
            service.personal_messages(legacy_fixture.identity(legacy_fixture.UID_X), "old-room")
        db.accounts[legacy_fixture.UID_A] = (legacy_fixture.UID_A, 1, "active")
        with self.assertRaises(LegacyReadRejected):
            service.personal_messages(legacy_fixture.identity(), "old-room")
        db.accounts[legacy_fixture.UID_A] = (legacy_fixture.UID_A, 0, "active")
        db.tls = False
        with self.assertRaises(LegacyReadUnavailable):
            service.personal_messages(legacy_fixture.identity(), "old-room")
        self.assertIn("START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY", [sql for sql, _ in db.calls])
        self.assertFalse(any(sql.startswith(("INSERT", "UPDATE", "DELETE", "CREATE", "ALTER")) for sql, _ in db.calls))


if __name__ == "__main__":
    unittest.main()
