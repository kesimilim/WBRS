"""Composite native/legacy login transactions; synthetic data, no cloud."""
import base64
import copy
import json
import unittest
from unittest.mock import patch

from native_auth import NativeAuthService, NativeRejected, NativeUnavailable, BoundedRateLimiter
from native_credentials import CredentialCodec, CredentialUnavailable
from native_password_credentials import NativePasswordCodec, PasswordWorkPool
from native_password_transition import apply_prepared_reset
from native_sessions import NativeSessionStore, SessionTokens
from test_native_auth import (FakeDatabase, FakeConnection, CONFIG, CONFIG_REF, WRAPPING,
    SESSION_KEY, UID, EMAIL, NOW, enabled_env, synthetic_row)


def factory_env():
    return enabled_env() | {'CLRS_NATIVE_SCRYPT_CONFIG_JSON': json.dumps(CONFIG),
        'CLRS_NATIVE_CREDENTIAL_CONFIG_REF': CONFIG_REF,
        'CLRS_NATIVE_CREDENTIAL_WRAPPING_KEY_B64': base64.b64encode(WRAPPING).decode(),
        'CLRS_NATIVE_SESSION_KEY_B64': base64.b64encode(SESSION_KEY).decode()}


class PasswordDatabase(FakeDatabase):
    def __init__(self):
        super().__init__()
        self.state['native_passwords'] = {}
        self.allow_native_select = True

    def connect(self, **kwargs):
        self.configs.append(kwargs)
        return PasswordConnection(self)


class PasswordConnection(FakeConnection):
    def _account_row(self, account):
        old = super()._account_row(account)
        row = self.working['native_passwords'].get(account['uid'])
        values = [row[k] for k in ['scheme', 'password_version', 'material_ciphertext', 'parameters']] if row else [None] * 4
        return (*old, *values)

    def execute(self, sql, params=()):
        super().execute(sql, params)
        if sql == 'SHOW GRANTS' and self.db.allow_native_select:
            self.result.append(('GRANT SELECT ON `clrs_staging`.`native_password_credentials` TO `native`@`%`',))


class PasswordLoginTests(unittest.TestCase):
    def setUp(self):
        self.env = enabled_env() | {'CLRS_NATIVE_PASSWORD_ENABLED': '1'}
        self.db = PasswordDatabase()
        self.codec = CredentialCodec(CONFIG, CONFIG_REF, WRAPPING)
        self.pool = PasswordWorkPool(self.codec, NativePasswordCodec(WRAPPING))
        self.addCleanup(self.pool.close)
        self.store = NativeSessionStore(self.env, self.codec, SessionTokens(SESSION_KEY),
            password_selector=self.pool, connect=self.db.connect, clock=lambda: self.db.clock)
        self.service = NativeAuthService(self.env, self.store, self.pool, BoundedRateLimiter(SESSION_KEY))

    def row(self, password=' New native password ', version=0):
        return self.pool.prepare(UID, version, password)

    def login(self, password=' New native password '):
        return self.service.login({'email': EMAIL, 'password': password, 'deviceId': 'synthetic-device'}, peer='synthetic-peer')

    def test_native_only_login_issues_session_and_locks_authoritative_material(self):
        self.db.state['credentials'].clear()
        self.db.state['native_passwords'][UID] = self.row()
        result = self.login()
        self.assertEqual(result['uid'], UID)
        self.assertTrue(result['accessToken'].startswith('na1.'))
        self.assertEqual(len(self.db.state['sessions']), 1)
        account_query = [sql for sql, _ in self.db.calls if 'WHERE a.uid = %s' in sql][0]
        self.assertIn('FOR SHARE OF a, c, n', account_query)
        self.assertFalse(any('UPDATE clrs_staging.accounts' in sql for sql, _ in self.db.calls))

    def test_retained_firebase_verifier_cannot_restore_old_password_or_trim_new_one(self):
        self.db.state['native_passwords'][UID] = self.row()
        for password in ['user1password', 'New native password']:
            with self.assertRaises(NativeRejected):
                self.login(password)
        self.assertEqual(len(self.db.state['sessions']), 0)
        self.assertEqual(self.login()['uid'], UID)

    def test_corrupt_or_future_native_material_never_falls_back(self):
        row = self.row()
        bad = copy.deepcopy(row)
        bad['material_ciphertext'] = bytes(80)
        for invalid in [bad, self.row(version=1)]:
            self.db.state['native_passwords'][UID] = invalid
            with self.assertRaises(NativeUnavailable):
                self.login('user1password')
        self.assertEqual(len(self.db.state['sessions']), 0)

    def test_reset_ciphertext_and_account_changes_during_kdf_block_session_issue(self):
        first = self.row()
        replacement = self.row('Replacement password')
        original = self.pool.verify
        for change in ['ciphertext', 'token-version', 'blocked']:
            self.db.state['native_passwords'][UID] = first
            self.db.state['accounts'][UID].update(token_version=0, lifecycle='active')
            def verify_then_change(*args, **kwargs):
                valid = original(*args, **kwargs)
                if change == 'ciphertext':
                    self.db.state['native_passwords'][UID] = replacement
                elif change == 'token-version':
                    self.db.state['accounts'][UID]['token_version'] += 1
                else:
                    self.db.state['accounts'][UID]['lifecycle'] = 'blocked'
                return valid
            with patch.object(self.pool, 'verify', side_effect=verify_then_change):
                with self.assertRaises(NativeRejected):
                    self.login()
        self.assertEqual(len(self.db.state['sessions']), 0)

    def test_session_revocation_preserves_password_reset_replaces_it(self):
        self.db.state['native_passwords'][UID] = self.row()
        first = self.login()
        # Revocation version is not the password version. This models a
        # reviewed account revocation, without claiming reset API integration.
        self.db.state['accounts'][UID]['token_version'] = 1
        with self.assertRaises(NativeRejected):
            self.service.authorize(first['accessToken'], peer='synthetic-peer')
        self.assertEqual(self.login()['uid'], UID)
        self.db.state['accounts'][UID]['token_version'] = 2
        self.db.state['native_passwords'][UID] = self.row('Replacement password', 2)
        with self.assertRaises(NativeRejected):
            self.login()
        self.assertEqual(self.login('Replacement password')['uid'], UID)

    def test_legacy_path_in_composite_mode_and_missing_select_fail_closed(self):
        self.assertEqual(self.login('user1password')['uid'], UID)
        self.db.state['credentials'][UID] = synthetic_row(disabled=True)
        with self.assertRaises(NativeRejected):
            self.login('user1password')
        self.db.allow_native_select = False
        with self.assertRaises(NativeUnavailable):
            self.login('user1password')

    def test_from_env_default_off_does_not_reference_new_tables_and_invalid_flag_rejects(self):
        env = factory_env()
        database = FakeDatabase()
        service = NativeAuthService.from_env(env, connect=database.connect)
        self.addCleanup(service.close)
        service.store._clock = lambda: database.clock
        result = service.login({'email': EMAIL, 'password': 'user1password', 'deviceId': 'synthetic-device'}, peer='synthetic-peer')
        self.assertEqual(result['uid'], UID)
        self.assertFalse(any('native_password_credentials' in sql for sql, _ in database.calls))
        with self.assertRaises(NativeUnavailable):
            NativeAuthService.from_env(env | {'CLRS_NATIVE_PASSWORD_ENABLED': 'true'}, connect=database.connect)
        service = NativeAuthService.from_env(env | {'CLRS_NATIVE_PASSWORD_ENABLED': '1'}, connect=self.db.connect)
        self.addCleanup(service.close)
        self.assertIsInstance(service.verifier, PasswordWorkPool)
        self.assertIs(service.store._password_selector, service.verifier)

    def test_retired_imported_verifier_cannot_resurrect_after_cold_flag_rollback(self):
        retired = synthetic_row() | {'scheme': 'bridge_only', 'password_hash': None, 'password_salt': None}
        for flag in [None, '0']:
            database = FakeDatabase()
            database.state['credentials'][UID] = retired
            database.state['accounts'][UID]['token_version'] = 1
            env = factory_env()
            if flag is not None:
                env['CLRS_NATIVE_PASSWORD_ENABLED'] = flag
            service = NativeAuthService.from_env(env, connect=database.connect)
            self.addCleanup(service.close)
            with self.assertRaises(NativeUnavailable):
                service.login({'email': EMAIL, 'password': 'user1password', 'deviceId': 'synthetic-device'}, peer='synthetic-peer')
            self.assertEqual(database.state['sessions'], {})
            self.assertFalse(any('native_password_credentials' in sql for sql, _ in database.calls))
        self.db.state['credentials'][UID] = retired
        self.db.state['accounts'][UID]['token_version'] = 1
        self.db.state['native_passwords'][UID] = self.row(version=1)
        self.assertEqual(self.login()['uid'], UID)

    def test_mismatched_prepared_password_epoch_has_no_sql_side_effect(self):
        statements = []
        row = self.row(version=2)
        with self.assertRaises(CredentialUnavailable):
            apply_prepared_reset(None, lambda *args: statements.append(args), self.pool.native_codec,
                uid=UID, email=EMAIL, expected_token_version=0, prepared_row=row)
        self.assertEqual(statements, [])


if __name__ == '__main__':
    unittest.main()
