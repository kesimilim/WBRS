"""Visible native targets: actual current store/reader/S3/raster; SQL and HTTPS are synthetic."""
import copy
from datetime import datetime, timezone
import hashlib
import json
import unittest

from native_sessions import NativeIdentity
from runtime_mutations import canonical_json, request_digest, RuntimeInvalidRequest
from runtime_profile_photo_uploads import photo_identity, PREPARE_OPERATION, COMMIT_OPERATION
from runtime_native_profile_photos import profile_photo_branch
from runtime_profile_photos import RuntimeProfilePhotoNotFound
from runtime_profile_photos_http import RuntimeProfilePhotoMediaReply
from test_runtime_native_profile_photos import NativeGalleryTests
from test_runtime_mutations import NOW, STAMP
from test_runtime_http import OP
from test_runtime_profile_photo_uploads import SECOND


class NativePublicPhotoTests(unittest.TestCase):
    def public_fixture(self):
        db, store, uploads, reader, port, stub, fields, proof = NativeGalleryTests.setup_gallery(self)
        actor_mid = photo_identity('actor', OP)[0]; target_mid, key = photo_identity('peer', OP)
        db.state['flags']['peer'] = [1, 1]
        db.state['profiles']['peer'] = db.state['profiles']['actor']
        row = copy.deepcopy(db.state['media'][actor_mid]); row[:4] = [target_mid, 'peer', 'profile', key]
        db.state['media'][target_mid] = row; db.state['photos']['peer'] = [[target_mid, 0, 1]]
        for operation, op in ((PREPARE_OPERATION, OP), (COMMIT_OPERATION, SECOND)):
            copied = copy.deepcopy(db.state['receipts'][('actor', operation, op)])
            wrapper = json.loads(copied[3]); wrapper['response']['mediaId'] = target_mid
            if operation == COMMIT_OPERATION: wrapper['request']['mediaId'] = target_mid
            copied[0] = request_digest(wrapper['request']); copied[3] = canonical_json(wrapper).decode()
            db.state['receipts'][('peer', operation, op)] = copied
        return db, store, reader, stub, fields, target_mid

    def test_foreign_visible_native_descriptor_and_complete_private_original(self):
        db, store, reader, stub, fields, target_mid = self.public_fixture()
        self.assertEqual(profile_photo_branch(store, db.identity, 'peer', access_token=db.access, clock=lambda: NOW), 'native')
        page = reader.photos(db.identity, 'peer', access_token=db.access)
        self.assertEqual(page['targetUid'], 'peer'); self.assertEqual(len(page['items']), 1)
        self.assertEqual(set(page['items'][0]), {'ordinal', 'isPrimary', 'contentType', 'byteSize', 'reference'})
        public = json.dumps(page)
        for forbidden in ('url', 'object_key', 'owner_uid', target_mid, 'email', 'legacy_raw', 'role'):
            self.assertNotIn(forbidden, public)
        lease = reader.open_photo(db.identity, 'peer', page['items'][0]['reference'], access_token=db.access)
        statuses = []; body = RuntimeProfilePhotoMediaReply(lease, lambda: None).respond(lambda status, headers: statuses.append(status))
        self.assertEqual(statuses, ['200 OK'])
        raw = b''.join(body); self.assertEqual(len(raw), fields['byteSize'])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), fields['sha256'])
        self.assertTrue(lease._file.closed); self.assertFalse(reader._leases)
        self.assertTrue(all(method == 'GET' for method, *_ in stub.calls))

    def test_hidden_disabled_deleted_target_denies_selector_descriptor_and_late_first_byte(self):
        db, store, reader, stub, _, _ = self.public_fixture(); baseline = copy.deepcopy(db.state)
        hidden_until = datetime.fromtimestamp(NOW+60, timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
        for failure in ('hidden', 'disabled', 'deleted', 'incomplete'):
            with self.subTest(failure=failure):
                db.state = copy.deepcopy(baseline)
                if failure == 'hidden': db.state['invisible'] = {'peer': hidden_until}
                if failure == 'disabled': db.state['accounts']['peer'][0] = 1
                if failure == 'deleted': db.state['accounts']['peer'][1] = 'deleted'
                if failure == 'incomplete': db.state['flags']['peer'] = [1, 0]
                calls = len(stub.calls)
                with self.assertRaises(RuntimeProfilePhotoNotFound):
                    profile_photo_branch(store, db.identity, 'peer', access_token=db.access, clock=lambda: NOW)
                with self.assertRaises(RuntimeProfilePhotoNotFound): reader.photos(db.identity, 'peer', access_token=db.access)
                self.assertEqual(len(stub.calls), calls)
        db.state = baseline
        page = reader.photos(db.identity, 'peer', access_token=db.access)
        lease = reader.open_photo(db.identity, 'peer', page['items'][0]['reference'], access_token=db.access)
        db.state['invisible'] = {'peer': hidden_until}
        statuses = []; result = RuntimeProfilePhotoMediaReply(lease, lambda: None).respond(lambda status, headers: statuses.append(status))
        self.assertEqual(result.status, '404 Not Found'); self.assertFalse(result.authenticate); self.assertFalse(statuses)
        self.assertTrue(lease._file.closed); self.assertIsNone(db.state['sessions'][db.identity.session_id]['revoked_at'])

    def test_a_to_b_actor_bound_reference_and_actor_revoke_after_spool(self):
        db, _, reader, _, _, _ = self.public_fixture()
        page = reader.photos(db.identity, 'peer', access_token=db.access); reference = page['items'][0]['reference']
        session, tokens = db.tokens.mint('peer', 'device-b', 0, NOW); db.state['sessions'][session['session_id']] = session
        actor_b = NativeIdentity('peer', True, session['session_id'], NOW, NOW+900)
        with self.assertRaises(RuntimeInvalidRequest): reader.open_photo(actor_b, 'peer', reference, access_token=tokens['accessToken'])
        self.assertEqual(len(reader.photos(actor_b, 'peer', access_token=tokens['accessToken'])['items']), 1)
        lease = reader.open_photo(db.identity, 'peer', reference, access_token=db.access)
        db.state['sessions'][db.identity.session_id]['revoked_at'] = STAMP
        statuses = []; result = RuntimeProfilePhotoMediaReply(lease, lambda: None).respond(lambda status, headers: statuses.append(status))
        self.assertEqual(result.status, '401 Unauthorized'); self.assertTrue(result.authenticate); self.assertFalse(statuses)
        self.assertTrue(lease._file.closed); self.assertFalse(reader._leases); self.assertEqual(db.state['accounts']['peer'][0], 0)

    def test_foreign_mixed_or_other_owners_original_receipt_has_no_fallback(self):
        db, store, reader, stub, _, target_mid = self.public_fixture(); baseline = copy.deepcopy(db.state)
        for failure in ('mixed', 'wrong-owner', 'wrong-original'):
            db.state = copy.deepcopy(baseline)
            if failure == 'mixed':
                db.state['media']['legacy'] = ['legacy', 'peer', 'profile', 'clrs-import-quarantine/'+'a'*64,
                    'image/jpeg', 1, 'a'*64, 'ready', 0, 1, 1]
                db.state['photos']['peer'].append(['legacy', 1, 0])
                with self.assertRaises(RuntimeProfilePhotoNotFound):
                    profile_photo_branch(store, db.identity, 'peer', access_token=db.access, clock=lambda: NOW)
            elif failure == 'wrong-owner': db.state['media'][target_mid][1] = 'actor'
            else:
                row = db.state['receipts'][('peer', COMMIT_OPERATION, SECOND)]
                wrapper = json.loads(row[3]); wrapper['request']['mediaId'] = photo_identity('actor', OP)[0]
                row[0] = request_digest(wrapper['request']); row[3] = canonical_json(wrapper).decode()
            calls = len(stub.calls)
            with self.assertRaises(RuntimeProfilePhotoNotFound): reader.photos(db.identity, 'peer', access_token=db.access)
            self.assertEqual(len(stub.calls), calls)


if __name__ == '__main__': unittest.main()
