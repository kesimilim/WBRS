"""New registration leaves only: generated SQL transactions, no live resources."""
import copy
from dataclasses import replace
import json
import unittest

from native_credentials import CredentialUnavailable
from native_password_credentials import NativePasswordCodec, AuthChallengeCodec
from native_pending_account import (create_pending_account, validate_pending_account_capability,
    complete_pending_registration, _ACCOUNT, _EMPTY, _NATIVE, _PROFILE)
from native_auth_challenges import NativeAuthChallengeStore, ChallengeUnavailable, PENDING_CREDENTIAL_QUERY
from test_native_auth_challenges import (FakeDatabase, FakeCursor, ENV, CODE, NOW, REGISTER,
    identifier, _timestamp)

UID = 'native-pending-generated'; EMAIL = 'pending@example.invalid'


class Database(FakeDatabase):
    def __init__(self):
        super().__init__()
        self.fault = None
        self.state.update(native={}, identities={}, profiles={}, imported=set())

    def transaction(self, action):
        working = copy.deepcopy(self.state)
        cursor = Cursor(self, working)
        result = action(cursor, cursor.execute)
        self.state = working
        return result


class Cursor(FakeCursor):
    def fetchall(self):
        return self.result

    def execute(self, sql, params=()):
        norm = ' '.join(sql.split())
        known = (norm == ' '.join(_ACCOUNT.split()) or norm in (
            ' '.join(_EMPTY.split()), ' '.join(PENDING_CREDENTIAL_QUERY.split()),
            ' '.join(_NATIVE.split()), ' '.join(_PROFILE.split()))
            or norm.startswith(('SELECT uid FROM clrs_staging.accounts',
                'INSERT INTO clrs_staging.accounts', 'INSERT INTO clrs_staging.native_password_credentials',
                'INSERT INTO clrs_staging.auth_identities', 'INSERT INTO clrs_staging.profiles',
                'SELECT uid, provider, provider_subject', 'UPDATE clrs_staging.accounts')))
        if not known:
            return super().execute(sql, params)
        self.db.calls.append((sql, params)); self.rowcount = 0; self.result = None
        uid = params[0]
        if norm.startswith('SELECT uid FROM clrs_staging.accounts'):
            if 'email_normalized' in norm:
                found = next((a[0] for a in self.working['accounts'].values() if a[1] == uid), None)
            else:
                found = uid if uid in self.working['accounts'] else None
            self.result = None if found is None else (found,)
        elif norm.startswith('INSERT INTO clrs_staging.accounts'):
            uid, email = params
            assert uid not in self.working['accounts']
            assert not any(a[1] == email for a in self.working['accounts'].values())
            self.working['accounts'][uid] = (uid, email, 1, 'active', 0, 0, _timestamp(self.db.now))
            self.rowcount = 1
            if self.db.fault == 'account-readback':
                self.working['accounts'][uid] = (uid, email, 0, 'active', 0, 0, _timestamp(self.db.now))
        elif norm == ' '.join(_ACCOUNT.split()):
            self.result = self.working['accounts'].get(uid)
        elif norm in (' '.join(_EMPTY.split()), ' '.join(PENDING_CREDENTIAL_QUERY.split())):
            seeded = self.working['credential_counts'].get(uid, (0, 0, 0, 0))
            actual = (int(uid in self.working['imported']), int(uid in self.working['native']),
                      int(uid in self.working['identities']), int(uid in self.working['profiles']))
            self.result = tuple(max(a, b) for a, b in zip(seeded, actual))
        elif norm.startswith('INSERT INTO clrs_staging.native_password_credentials'):
            uid, scheme, cipher, parameters = params
            assert uid not in self.working['native']
            self.working['native'][uid] = {'uid': uid, 'scheme': scheme, 'password_version': 0,
                'material_ciphertext': bytes(cipher), 'parameters': json.loads(parameters)}
            self.rowcount = 1
        elif norm.startswith('INSERT INTO clrs_staging.auth_identities'):
            uid, subject, email = params
            assert uid not in self.working['identities']
            self.working['identities'][uid] = [(uid, 'password', subject, email, '{}')]
            self.rowcount = 1
        elif norm.startswith('INSERT INTO clrs_staging.profiles'):
            assert uid not in self.working['profiles']
            self.working['profiles'][uid] = (uid, *([None] * 15), '{}', 0, 0, None, None,
                                            _timestamp(self.db.now), '{}')
            self.rowcount = 1
        elif norm == ' '.join(_NATIVE.split()):
            row = self.working['native'].get(uid)
            self.result = None if row is None else tuple(row[k] for k in
                ['uid', 'scheme', 'password_version', 'material_ciphertext', 'parameters'])
            if self.db.fault == 'native-readback' and self.result:
                self.result = (*self.result[:3], bytes(80), self.result[4])
        elif norm.startswith('SELECT uid, provider, provider_subject'):
            self.result = self.working['identities'].get(uid, [])
            if self.db.fault == 'identity-readback':
                self.result = [(uid, 'google.com', uid, EMAIL, '{}')]
        elif norm == ' '.join(_PROFILE.split()):
            self.result = self.working['profiles'].get(uid)
            if self.db.fault == 'profile-readback' and self.result:
                self.result = (*self.result[:17], 1, *self.result[18:])
        elif norm.startswith('UPDATE clrs_staging.accounts'):
            uid, email, created = params
            account = self.working['accounts'].get(uid)
            if account == (uid, email, 1, 'active', 0, 0, created) and self.db.fault != 'activation-cas':
                self.working['accounts'][uid] = (uid, email, 0, 'active', 0, 1, created)
                self.rowcount = 1


class PendingAccountTests(unittest.TestCase):
    def setUp(self):
        self.db = Database()
        self.passwords = NativePasswordCodec(bytes([6]) * 32)
        self.challenges = NativeAuthChallengeStore(ENV, AuthChallengeCodec(bytes([7]) * 32))

    def reserve(self, c, e):
        return create_pending_account(c, e, uid=UID, email=EMAIL)

    def issue(self):
        def action(c, e):
            capability = self.reserve(c, e)
            result = self.challenges.issue(c, e, uid=UID, email=EMAIL, purpose=REGISTER,
                code=CODE, challenge_id=identifier(1), pending_account=capability)
            self.assertEqual(result.state, 'issued')
            return result
        return self.db.transaction(action)

    def prepared(self, *, uid=UID, version=0):
        return self.passwords.seal(uid, version, bytes([8]) * 16, bytes([9]) * 32)

    def complete(self, *, prepared=None, action=None):
        checked = self.db.transaction(lambda c, e: self.challenges.check(c, e, uid=UID,
            email=EMAIL, purpose=REGISTER, code=CODE, challenge_id=identifier(1)))
        self.assertEqual(checked.state, 'verified')
        def finish(c, e):
            consumed = self.challenges.consume(c, e, ticket=checked.ticket, code=CODE)
            self.assertEqual(consumed.state, 'consumed')
            if action:
                action(c, e)
            return complete_pending_registration(c, e, self.passwords,
                consumed_challenge=consumed.consumed,
                prepared_row=self.prepared() if prepared is None else prepared)
        return self.db.transaction(finish)

    def test_request_only_reserves_account_and_same_transaction_one_use_capability(self):
        def action(c, e):
            capability = self.reserve(c, e)
            self.assertNotIn(UID, repr(capability)); self.assertNotIn(EMAIL, repr(capability))
            binding = validate_pending_account_capability(capability, c, e)
            self.assertEqual((binding.uid, binding.email, binding.token_version), (UID, EMAIL, 0))
            self.assertEqual(binding.account_created_at, _timestamp(NOW))
            self.assertEqual(len(binding.marker), 32)
            with self.assertRaises(CredentialUnavailable):
                validate_pending_account_capability(capability, c, e)
        self.db.transaction(action)
        self.assertEqual(self.db.state['accounts'][UID][2:6], (1, 'active', 0, 0))
        for table in ['native', 'identities', 'profiles']:
            self.assertEqual(self.db.state[table], {})
        self.assertEqual(self.db.state['challenges'], {})

    def test_existing_uid_email_and_bad_input_never_write_or_activate(self):
        self.db.transaction(self.reserve)
        original = copy.deepcopy(self.db.state)
        for uid, email in [(UID, EMAIL), ('other-generated', EMAIL), (UID, 'other@example.invalid')]:
            self.db.calls.clear()
            with self.assertRaises(CredentialUnavailable):
                self.db.transaction(lambda c, e: create_pending_account(c, e, uid=uid, email=email))
            self.assertFalse(any(sql.startswith(('INSERT', 'UPDATE')) for sql, _ in self.db.calls))
            self.assertEqual(self.db.state, original)
        for uid, email in [('', EMAIL), (UID, EMAIL.upper()), (UID, ' pending@example.invalid'),
                           ('\ud800', EMAIL), (UID, 'bad email@example.invalid')]:
            self.db.calls.clear()
            with self.assertRaises(CredentialUnavailable):
                self.db.transaction(lambda c, e: create_pending_account(c, e, uid=uid, email=email))
            self.assertEqual(self.db.calls, [])

    def test_pending_proof_forged_cross_cursor_execute_or_changed_account_refused(self):
        def action(c, e):
            capability = self.reserve(c, e)
            for invalid, cursor, execute in [(object(), c, e), (replace(capability), c, e),
                                            (capability, object(), e), (capability, c, lambda *a: None)]:
                with self.assertRaises(CredentialUnavailable):
                    validate_pending_account_capability(invalid, cursor, execute)
            changed = list(c.working['accounts'][UID]); changed[4] = 1
            c.working['accounts'][UID] = tuple(changed)
            with self.assertRaises(CredentialUnavailable):
                validate_pending_account_capability(capability, c, e)
            raise RuntimeError('caller rolls back refusal')
        before = copy.deepcopy(self.db.state)
        with self.assertRaises(RuntimeError):
            self.db.transaction(action)
        self.assertEqual(self.db.state, before)
        self.db.fault = 'account-readback'
        with self.assertRaises(CredentialUnavailable):
            self.db.transaction(self.reserve)
        self.assertEqual(self.db.state, before)

    def test_real_challenge_consumption_completion_installs_only_new_native_account(self):
        self.issue()
        self.assertEqual(self.db.state['native'], {})
        result = self.complete()
        self.assertEqual((result.uid, result.token_version), (UID, 0))
        self.assertEqual(self.db.state['accounts'][UID][2:6], (0, 'active', 0, 1))
        self.assertEqual(self.passwords.decode(self.db.state['native'][UID]).password_version, 0)
        self.assertEqual(self.db.state['identities'][UID][0][:4], (UID, 'password', UID, EMAIL))
        self.assertEqual(self.db.state['profiles'][UID][17:19], (0, 0))
        self.assertIsNotNone(self.db.state['challenges'][(UID, REGISTER)]['consumed'])
        self.assertEqual(self.db.transaction(lambda c, e: self.challenges.check(c, e,
            uid=UID, email=EMAIL, purpose=REGISTER, code=CODE,
            challenge_id=identifier(1))).state, 'declined')
        forbidden = ('COMMIT', 'ROLLBACK', 'BEGIN', 'CREATE', 'ALTER', 'DELETE', 'GRANT')
        self.assertFalse(any(sql.startswith(forbidden) for sql, _ in self.db.calls))
        self.assertFalse(any('role_grants' in sql or 'balance' in sql or 'legacy_' in sql.split('FROM')[-1]
                             and sql.startswith('UPDATE') for sql, _ in self.db.calls))

    def test_prepared_uid_epoch_forged_consume_and_existing_children_refused_atomically(self):
        self.issue(); before = copy.deepcopy(self.db.state)
        for prepared in [self.prepared(uid='other'), self.prepared(version=1),
                         self.prepared() | {'material_ciphertext': bytes(80)}]:
            with self.assertRaises(CredentialUnavailable):
                self.complete(prepared=prepared)
            self.assertEqual(self.db.state, before)
        for index in range(4):
            def child(c, e):
                flags = [0] * 4; flags[index] = 1
                c.working['credential_counts'][UID] = tuple(flags)
            with self.assertRaises(CredentialUnavailable):
                self.complete(action=child)
            self.assertEqual(self.db.state, before)
        calls = len(self.db.calls)
        with self.assertRaises(CredentialUnavailable):
            self.db.transaction(lambda c, e: complete_pending_registration(c, e, self.passwords,
                consumed_challenge=object(), prepared_row=self.prepared()))
        self.assertEqual(len(self.db.calls), calls)

    def test_completion_readback_or_activation_cas_failure_rolls_back_consumption_and_all_inserts(self):
        self.issue(); before = copy.deepcopy(self.db.state)
        for fault in ['native-readback', 'identity-readback', 'profile-readback', 'activation-cas']:
            self.db.fault = fault
            with self.assertRaises(CredentialUnavailable):
                self.complete()
            self.assertEqual(self.db.state, before)


if __name__ == '__main__':
    unittest.main()
