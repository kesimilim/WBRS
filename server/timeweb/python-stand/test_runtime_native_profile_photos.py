"""New integrated owner-gallery cases: actual core/store/raster/S3, synthetic SQL/HTTPS only."""
from datetime import datetime, timezone, timedelta
import base64
import copy
import hashlib
import hmac
import io
import json
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from PIL import Image

import native_photo_upload_s3 as s3
import native_profile_photo_factory as factory
from native_photo_raster import BoundedRasterVerifier
from native_sessions import NativeIdentity
from private_media_s3 import TimewebPrivateBucketState, PrivateMediaUnavailable
from runtime_mutations import RuntimeMutationStore, RuntimeRejected, request_digest, canonical_json
from runtime_profile_photo_uploads import (RuntimeProfilePhotoUploadsService, PhotoUploadTargetRejected,
    PREPARE_OPERATION, COMMIT_OPERATION, photo_identity)
from runtime_native_profile_photos import RuntimeNativeProfilePhotosService, profile_photo_branch
from runtime_profile_photos import RuntimeProfilePhotoNotFound
from runtime_profile_photos_http import RuntimeProfilePhotosHttp, RuntimeProfilePhotoMediaReply
from test_native_photo_upload_s3 import HTTPSStub, Response, KEY, BUCKET, OWNER, ACCESS, SECRET, PROOF_KEY, signed_proof
from test_runtime_profile_photo_uploads import PhotoDatabase, PhotoCursor, SECOND
from test_runtime_mutations import NOW, STAMP
from test_runtime_http import OP


class GalleryCursor(PhotoCursor):
    def execute(self, statement, params=()):
        sql = ' '.join(statement.split()); state = self.c.state; db = self.c.db
        if not sql.startswith(('SELECT p.media_id', 'SELECT profile_details_saved', 'SELECT a.uid', 'SELECT idempotency_key')):
            return super().execute(statement, params)
        assert self.c.held; db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        uid = params[0]
        if sql.startswith('SELECT profile_details_saved'):
            self.rows = [tuple(state['flags'][uid])]
        elif sql.startswith('SELECT a.uid'):
            account = state['accounts'][uid]
            self.rows = [(uid, *account[:2], uid, *state['flags'][uid], state.get('invisible', {}).get(uid), {}, state['profiles'][uid])]
        elif sql.startswith('SELECT p.media_id'):
            for photo in state['photos'].get(uid, []):
                media = state['media'][photo[0]]
                self.rows.append((*photo, state.get('firebase', {}).get(photo[0]), *media))
            self.rows = self.rows[:51 if 'LIMIT 51' in sql else 21]
        elif sql.startswith('SELECT idempotency_key'):
            self.rows = [(key[2], *row) for key, row in sorted(state['receipts'].items()) if key[:2] == (uid, params[2]) and row[1] == 'completed' and row[2] == 200][:21]
        return self.rowcount


class GalleryDatabase(PhotoDatabase):
    def __init__(self):
        super().__init__(); self.state['flags'] = {'actor': [0, 0], 'peer': [0, 0]}
    def connect(self, **values):
        connection = super().connect(**values); connection.cursor = lambda: GalleryCursor(connection)
        return connection


class NativeGalleryTests(unittest.TestCase):
    def setup_gallery(self):
        db = GalleryDatabase(); wall = datetime.fromtimestamp(NOW, timezone.utc)
        spool = io.BytesIO(); Image.new('RGB', (16, 12), 'orange').save(spool, format='JPEG'); data = spool.getvalue()
        class DerivedHTTPS(HTTPSStub):
            def reply(self, path, api):
                if path.startswith('/' + BUCKET + '/' + s3.PREFIX):
                    path = '/' + BUCKET + '/' + KEY + ('?acl=' if path.endswith('?acl=') else '')
                return super().reply(path, api)
        stub = DerivedHTTPS(); stub.body = data
        proof = [signed_proof(checked_at=wall.strftime('%Y-%m-%dT%H:%M:%S.%fZ'))]
        port = s3.NativePhotoUploadS3(s3.ENDPOINT, 'ru-1', BUCKET, OWNER, ACCESS, SECRET,
            bucket_state=TimewebPrivateBucketState(1, BUCKET, 'synthetic-control-token', connection_factory=lambda: stub.connect(True)),
            provider_proof=lambda: proof[0], proof_key=PROOF_KEY, image_verifier=BoundedRasterVerifier(),
            connection_factory=stub.connect, wall_clock=lambda: wall)
        store = RuntimeMutationStore(db.env, db.tokens, connect=db.connect, clock=lambda: NOW)
        self.addCleanup(store.close)
        uploads = RuntimeProfilePhotoUploadsService(store, writer=port, clock=lambda: NOW)
        directory = tempfile.TemporaryDirectory(); self.addCleanup(directory.cleanup)
        reader = RuntimeNativeProfilePhotosService(store, b'c' * 32, uploads=uploads, private_s3=port,
            spool_directory=directory.name, clock=lambda: NOW)
        self.addCleanup(reader.close)
        fields = {'sha256': hashlib.sha256(data).hexdigest(), 'byteSize': len(data), 'mimeType': 'image/jpeg'}
        uploads.prepare(db.identity, OP, fields, access_token=db.access)
        mid, _ = photo_identity('actor', OP)
        uploads.commit(db.identity, SECOND, {'mediaId': mid, 'prepareOperationId': OP}, access_token=db.access)
        self.addCleanup(lambda: self.assertTrue(all(value.closed for value in stub.connections + stub.replies)))
        return db, store, uploads, reader, port, stub, fields, proof

    def test_twenty_native_original_receipts_page_and_verified_disconnect(self):
        db, store, uploads, reader, port, stub, fields, _ = self.setup_gallery()
        # Synthetic compact gallery clones retain exact original receipt hashes/UUID derivation.
        for i in range(1, 20):
            prep = f'12345678-1234-4234-8234-{100+i:012d}'; commit = f'12345678-1234-4234-8234-{200+i:012d}'
            mid, key = photo_identity('actor', prep); request = {'mediaId': mid, 'prepareOperationId': prep}
            old = copy.deepcopy(next(iter(db.state['media'].values()))); old[:4] = [mid, 'actor', 'profile', key]
            db.state['media'][mid] = old; db.state['photos']['actor'].append([mid, i, 0])
            prepared = {'mediaId': mid, **fields, 'status': 'pending', 'profileAuthority': 'canonical-current-v1'}
            ready = {'mediaId': mid, 'ready': True, 'ordinal': i, 'isPrimary': False,
                'updatedAt': db.state['profiles']['actor'], 'profileAuthority': 'canonical-current-v1'}
            for operation, op, request_fields, response, status in ((PREPARE_OPERATION, prep, fields, prepared, 201),
                    (COMMIT_OPERATION, commit, request, ready, 200)):
                db.state['receipts'][('actor', operation, op)] = [request_digest(request_fields), 'completed', status,
                    canonical_json({'request': request_fields, 'response': response}).decode(), None, STAMP]
        # Valid committed refusals are not successful photo provenance.
        rejected_request = {'mediaId': photo_identity('actor', OP)[0], 'prepareOperationId': OP}
        for i in range(21):
            op = f'12345678-1234-4234-8234-{300+i:012d}'
            db.state['receipts'][('actor', COMMIT_OPERATION, op)] = [request_digest(rejected_request), 'completed', 409,
                canonical_json({'request': rejected_request, 'response': {'error': 'photo_unavailable'}}).decode(), None, STAMP]
        self.assertEqual(sum(key[1] == COMMIT_OPERATION for key in db.state['receipts']), 41)
        before = len(db.calls)
        page = reader.photos(db.identity, 'actor', access_token=db.access, limit=7)
        self.assertLessEqual(len(db.calls) - before, 40)
        self.assertEqual([item['ordinal'] for item in page['items']], list(range(7)))
        self.assertNotIn('url', json.dumps(page)); self.assertIsNotNone(page['nextCursor'])
        second = reader.photos(db.identity, 'actor', access_token=db.access, limit=7, cursor=page['nextCursor'])
        self.assertEqual(second['items'][0]['ordinal'], 7)
        lease = reader.open_photo(db.identity, 'actor', page['items'][0]['reference'], access_token=db.access)
        statuses = []; body = RuntimeProfilePhotoMediaReply(lease, lambda: None).respond(lambda status, headers: statuses.append(status))
        self.assertEqual(statuses, ['200 OK']); self.assertEqual(hashlib.sha256(next(body)).hexdigest(), fields['sha256'])
        body.close(); body.close(); self.assertTrue(lease._file.closed)
        self.assertFalse(reader._leases); self.assertFalse(reader._inflight)
        self.assertEqual(stub.object_acl_count, 5)  # commit pre/post + download pre/post + fresh first byte.

    def test_mixed_foreign_key_and_receipt_tamper_never_fallback_or_return_bytes(self):
        db, _, _, reader, _, stub, _, _ = self.setup_gallery(); original = copy.deepcopy(db.state)
        mid = db.state['photos']['actor'][0][0]
        for change in ('mixed', 'owner', 'key', 'receipt'):
            db.state = copy.deepcopy(original)
            if change == 'mixed':
                db.state['media']['legacy'] = ['legacy', 'actor', 'profile', 'clrs-import-quarantine/'+'a'*64,
                    'image/jpeg', 1, 'a'*64, 'ready', 0, 1, 1]
                db.state['photos']['actor'].append(['legacy', 1, 0])
            elif change == 'owner': db.state['media'][mid][1] = 'peer'
            elif change == 'key': db.state['media'][mid][3] = s3.PREFIX + 'f'*64
            else:
                row = db.state['receipts'][('actor', COMMIT_OPERATION, SECOND)]; value = json.loads(row[3])
                value['response']['ordinal'] = 1; row[3] = json.dumps(value)
            calls = len(stub.calls)
            with self.assertRaises(RuntimeProfilePhotoNotFound): reader.photos(db.identity, 'actor', access_token=db.access)
            self.assertEqual(len(stub.calls), calls)
        db.state = original
        with self.assertRaises(RuntimeProfilePhotoNotFound): reader.photos(db.identity, 'peer', access_token=db.access)

    def test_current_a_to_b_and_revoke_before_first_byte_purge_spool_without_200(self):
        db, _, _, reader, _, _, _, _ = self.setup_gallery()
        page = reader.photos(db.identity, 'actor', access_token=db.access)
        lease = reader.open_photo(db.identity, 'actor', page['items'][0]['reference'], access_token=db.access)
        db.state['sessions'][db.identity.session_id]['revoked_at'] = STAMP
        statuses = []; refused = RuntimeProfilePhotoMediaReply(lease, lambda: None).respond(lambda status, headers: statuses.append(status))
        self.assertEqual(refused.status, '401 Unauthorized'); self.assertFalse(statuses); self.assertTrue(lease._file.closed)
        session, tokens = db.tokens.mint('peer', 'b', 0, NOW); db.state['sessions'][session['session_id']] = session
        peer = NativeIdentity('peer', True, session['session_id'], NOW, NOW+900)
        with self.assertRaises(RuntimeProfilePhotoNotFound): reader.open_photo(peer, 'actor', page['items'][0]['reference'], access_token=tokens['accessToken'])
        self.assertEqual(db.state['accounts']['peer'][0], 0)

    def test_initial_only_new_upload_but_original_ready_lookup_after_finish(self):
        db, store, uploads, reader, _, stub, fields, _ = self.setup_gallery(); mid = photo_identity('actor', OP)[0]
        db.state['flags']['actor'] = [1, 1]
        calls = len(stub.calls)
        for action in (lambda: uploads.prepare(db.identity, '12345678-1234-4234-8234-123456789abf', fields, access_token=db.access),
                lambda: uploads.upload_lease(db.identity, mid, OP, access_token=db.access),
                lambda: uploads.commit(db.identity, '12345678-1234-4234-8234-123456789abf', {'mediaId': mid, 'prepareOperationId': OP}, access_token=db.access)):
            with self.assertRaises(PhotoUploadTargetRejected): action()
        self.assertEqual(len(stub.calls), calls)
        for operation, op, request in ((PREPARE_OPERATION, OP, fields),
                (COMMIT_OPERATION, SECOND, {'mediaId': mid, 'prepareOperationId': OP})):
            self.assertEqual(store.lookup(db.identity, operation, op, payload=request, access_token=db.access).payload['state'], 'committed')
        self.assertEqual(len(reader.photos(db.identity, 'actor', access_token=db.access)['items']), 1)
        db.state['flags']['actor'] = [0, 0]
        db.state['media']['legacy'] = ['legacy', 'actor', 'profile', 'clrs-import-quarantine/'+'a'*64,
            'image/jpeg', 1, 'a'*64, 'ready', 0, 1, 1]
        db.state['photos']['actor'].append(['legacy', 1, 0])
        with self.assertRaises(PhotoUploadTargetRejected):
            uploads.prepare(db.identity, '12345678-1234-4234-8234-123456789abf', fields, access_token=db.access)
        self.assertEqual(len(stub.calls), calls)

    def test_factory_composite_own_native_and_legacy_closed_resources(self):
        db, store, _, _, port, stub, _, _ = self.setup_gallery()
        class LegacyReader:
            def __init__(self): self.calls = 0
            def photos(self, *args, **kwargs): self.calls += 1; return {'legacy': True}
        class LegacyHttp:
            _enabled = True
            def __init__(self): self.service = LegacyReader(); self.closed = 0
            def _reader(self): return self.service
            def close(self): self.closed += 1
        legacy = LegacyHttp()
        db.state['flags']['peer'] = [1, 1]
        db.state['media']['legacy-peer'] = ['legacy-peer', 'peer', 'profile', 'clrs-import-quarantine/'+'b'*64,
            'image/jpeg', 1, 'b'*64, 'ready', 0, 1, 1]
        db.state['photos']['peer'] = [['legacy-peer', 0, 1]]
        read_store = RuntimeMutationStore(db.env, db.tokens, connect=db.connect, clock=lambda: NOW)
        self.addCleanup(read_store.close)
        settings = {**db.env, factory.GATE: '1',
            'CLRS_LEGACY_READ_CURSOR_KEY_B64': base64.b64encode(b'c'*32).decode(),
            'CLRS_NATIVE_SESSION_KEY_B64': base64.b64encode(bytes(range(32))).decode(),
            'CLRS_PREVIEW_ACCESS_KEY_B64': base64.b64encode(PROOF_KEY).decode()}
        with patch.object(factory.RuntimeMutationStore, 'from_env', return_value=read_store), patch.object(factory, 'create_native_photo_writer', return_value=port):
            http = factory.create_native_profile_photos_http(settings, legacy)
            self.assertIsInstance(http, RuntimeProfilePhotosHttp)
            service = http._reader()
            own = service.photos(db.identity, 'actor', access_token=db.access)
            self.assertEqual(own['kind'], 'canonical-profile-photos'); self.assertEqual(legacy.service.calls, 0)
            self.assertEqual(service.photos(db.identity, 'peer', access_token=db.access), {'legacy': True})
            self.assertEqual(legacy.service.calls, 1)
            mid = db.state['photos']['actor'][0][0]
            db.state['media'][mid][3] = 'clrs-import-quarantine/'+'a'*64; db.state['media'][mid][8] = 0
            self.assertEqual(service.photos(db.identity, 'actor', access_token=db.access), {'legacy': True})
            directory = service._directory.name; http.close(); http.close()
            self.assertFalse(__import__('os').path.exists(directory)); self.assertEqual(legacy.closed, 1)
            with self.assertRaises(Exception): service.photos(db.identity, 'actor', access_token=db.access)
        self.assertTrue(read_store._closed)

    def test_default_off_bad_proof_and_release_binding_are_closed_without_cloud(self):
        legacy = object()
        self.assertIs(factory.create_native_profile_photos_http({}, legacy), legacy)
        self.assertIsNone(factory.create_native_photo_writer({}))
        self.assertIsNone(factory.create_native_photo_writer({factory.GATE: '1'}))
        db, _, _, reader, port, stub, _, proof = self.setup_gallery()
        old_calls = len(stub.calls); original = proof[0]; proof[0] = (original[0], '0'*64)
        with self.assertRaises(Exception): reader.photos(db.identity, 'actor', access_token=db.access)
        self.assertEqual(len(stub.calls), old_calls); proof[0] = original
        binding = {'buildSha256': 'a'*64, 'sourceSha256': 'b'*64, 'configSha256': 'c'*64}
        released = {'version': 1, 'kind': 'native-photo-upload-release', 'binding': dict(binding),
            'providerProofSha256': hashlib.sha256(original[0]).hexdigest(), 'issuedAt': '2027-01-15T08:00:00.000000Z'}
        raw = canonical_json(released); mac = hmac.digest(PROOF_KEY, s3.RELEASE_DOMAIN+raw, 'sha256').hex()
        port._mode = 'release'; port._binding = lambda: binding; port._proof_loader = lambda: (raw, mac, *original)
        port._wall = lambda: datetime.fromtimestamp(NOW, timezone.utc)+timedelta(days=2)
        self.assertIsNone(port._proof()[1], 'Release witness is not an enlarged pilot TTL')
        binding['buildSha256'] = 'd'*64
        with self.assertRaises(PrivateMediaUnavailable): port._proof()
        self.assertEqual(len(stub.calls), old_calls)


if __name__ == '__main__': unittest.main()
