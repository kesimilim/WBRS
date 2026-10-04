"""One connected real store/HTTP/reader scenario; SQL/S3/source witness are synthetic."""
import base64
import copy
from datetime import datetime, timezone, timedelta
import hashlib
import io
import unittest
from unittest.mock import patch
from PIL import Image

import native_profile_photo_factory as factory
import runtime_profile_photo_uploads as uploads_module
import runtime_profile_photos as photo_reads
from native_photo_raster import BoundedRasterVerifier
from native_photo_upload_s3 import NativePhotoUploadS3, ENDPOINT, PREFIX
from private_media_s3 import TimewebPrivateBucketState
from runtime_mutations import RuntimeMutationStore, RuntimeRejected, RuntimeInvalidRequest, RuntimeUnavailable, request_digest, canonical_json
from runtime_http import RuntimeMutationHttp, _create
from runtime_profile_photos_http import RuntimeProfilePhotosHttp, RuntimeProfilePhotoMediaReply
from runtime_profile_photos import RuntimeProfilePhotoNotFound
from runtime_profile_photo_uploads import PREPARE_OPERATION, COMMIT_OPERATION, PhotoUploadTargetRejected, photo_identity, _PARTS
from test_runtime_mutations import FakeCursor, FakeConnection, NOW
from test_runtime_http import Native, env, OP
from test_runtime_profile_photo_uploads import SECOND
from test_runtime_profile_photo_delta import DeltaTests, KEY
from test_native_photo_upload_s3 import HTTPSStub, KEY as OBJECT, BUCKET, OWNER, ACCESS, SECRET, PROOF_KEY, signed_proof


class Cursor(FakeCursor):
    def fetchall(self): return tuple(super().fetchall())  # Actual PyMySQL shape.
    def execute(self, statement, params=()):
        sql = ' '.join(statement.split()); state = self.c.state; db = self.c.db
        self.c.query_count = getattr(self.c, 'query_count', 0) + 1
        self.rows = []; self.rowcount = 0
        handled = True
        if 'information_schema.statistics' in sql:
            self.rows = [(*row, None) for row in sorted(_PARTS)]
        elif sql.startswith('SELECT profile_details_saved, registration_complete'):
            p = state['profiles'].get(params[0]); self.rows = [(*p[:2], int(p[3] == {}))] if p else []
        elif sql.startswith('SELECT uid, DATE_FORMAT'):
            p = state['profiles'].get(params[0]); self.rows = [(params[0], p[4])] if p else []
        elif sql.startswith('SELECT p.media_id, p.ordinal, p.is_primary'):
            for a in sorted(state['photos'].get(params[0], []), key=lambda a:a[2]):
                m = state['media'].get(a[1])
                if m is not None:
                    if not a[1].startswith('tw-profile-photo-'):
                        m = [*m[:4], m[5], m[6], m[8].hex(), m[9], int(m[10] is None), int(m[4] is None), int(m[7] is None)]
                    self.rows.append((*a[1:], *m))
        elif sql.startswith('SELECT media_id, ordinal, is_primary'):
            self.rows = [tuple(a[1:4]) for a in state['photos'].get(params[0], [])]
        elif sql.startswith('SELECT uid, media_id, ordinal, is_primary, firebase_image_id'):
            self.rows = [tuple(a) for a in state['photos'].get(params[0], []) if 'LEFT(CAST(media_id' not in sql or not a[1].startswith('tw-profile-photo-')]
        elif sql == ' '.join(photo_reads.TARGET_SQL.split()):
            uid = params[0]; self.rows = [(uid, *state['accounts'][uid][:2], uid, *state['profiles'][uid])]
        elif sql == ' '.join(photo_reads.SOURCE_SQL.split()): self.rows = [db.source]
        elif sql == ' '.join(photo_reads.ROOT_SQL.split()):
            self.rows = [state['roots'][params[1][6:]]] if params[1][6:] in state['roots'] else []
        elif sql == ' '.join(photo_reads.GALLERY_SQL.split()):
            self.rows = sorted(copy.deepcopy(state['galleries'].get(params[1][6:-7], [])),key=lambda r:r[2].encode())[:51]
        elif 'FROM clrs_staging.media_objects WHERE media_id IN' in sql:
            self.rows = [state['media'][mid] for mid in params if mid in state['media']]
        elif 'FROM clrs_staging.legacy_storage_objects' in sql:
            self.rows = [r for path,r in state['storage'].items() if hashlib.sha256(path.encode()).digest() in params[1:]]
        elif sql.startswith('SELECT media_id, owner_uid'):
            row = state['media'].get(params[0]); self.rows = [tuple(row)] if row else []
        elif sql.startswith('SELECT idempotency_key, request_hash'):
            self.rows = [(key[2], *r) for key, r in sorted(state['receipts'].items())
                if key[:2] == (params[0], params[2]) and r[1] == 'completed' and r[2] == 200][:21]
        elif sql.startswith('INSERT INTO clrs_staging.media_objects'):
            mid, uid, key, mime, size, sha = params
            state['media'][mid] = [mid,uid,'profile',key,mime,size,sha.hex(),'pending',1,1,1]; self.rowcount = 1
        elif sql.startswith('UPDATE clrs_staging.media_objects'):
            mid, exact, uid = params; assert mid == exact
            row = state['media'][mid]
            if row[1] == uid and row[7] == 'pending': row[7] = 'ready'; self.rowcount = 1
        elif sql.startswith('INSERT INTO clrs_staging.profile_photos'):
            uid, mid, ordinal, primary = params
            assert state['media'][mid][1] == uid and state['media'][mid][7] == 'ready'
            assert all(a[2] != ordinal for a in state['photos'][uid])
            state['photos'][uid].append([uid,mid,ordinal,primary,None]); self.rowcount = 1
        elif sql.startswith('UPDATE clrs_staging.profiles'):
            uid, exact, expected = params; assert uid == exact
            p = state['profiles'][uid]
            if p[4] == expected.replace(' ','T') + 'Z':
                p[4] = (datetime.strptime(p[4],'%Y-%m-%dT%H:%M:%S.%fZ') + timedelta(microseconds=1)).strftime('%Y-%m-%dT%H:%M:%S.%fZ'); self.rowcount = 1
        else: handled = False
        if not handled: return super().execute(statement, params)
        assert self.c.held
        if sql.startswith(('INSERT', 'UPDATE')): assert not self.c.readonly
        db.calls.append((sql, params)); return self.rowcount


class Connection(FakeConnection):
    def cursor(self): return Cursor(self)


class ImportedAppendTests(unittest.TestCase):
    def test_imported_virtual_originals_append_unknown_mixed_private_and_current_guards(self):
        fixture = DeltaTests(); fixture.addCleanup = self.addCleanup; fixture.setUp()
        db, store = fixture.db, fixture.store
        def connect(**configuration):
            c = Connection(db); db.connections.append(c); return c
        db.connect = connect; store._connect = connect
        db.state['profiles']['actor'][:2] = [1,1]; db.state['profiles']['peer'][:2] = [1,1]
        original = copy.deepcopy(db.state)
        file = io.BytesIO(); Image.new('RGB',(16,12),'orange').save(file,format='JPEG'); data = file.getvalue()
        class HTTPS(HTTPSStub):
            def reply(self, path, api):
                if path.startswith('/'+BUCKET+'/'+PREFIX): path = '/'+BUCKET+'/'+OBJECT+('?acl=' if path.endswith('?acl=') else '')
                return super().reply(path,api)
        stub = HTTPS(); stub.body = data; wall = datetime.fromtimestamp(NOW,timezone.utc)
        port = NativePhotoUploadS3(ENDPOINT,'ru-1',BUCKET,OWNER,ACCESS,SECRET,
            bucket_state=TimewebPrivateBucketState(1,BUCKET,'synthetic-control-token',connection_factory=lambda:stub.connect(True)),
            provider_proof=lambda:signed_proof(checked_at=wall.strftime('%Y-%m-%dT%H:%M:%S.%fZ')),
            proof_key=PROOF_KEY,image_verifier=BoundedRasterVerifier(),connection_factory=stub.connect,wall_clock=lambda:wall)
        settings = {**store._env,'CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED':'1','CLRS_RUNTIME_NATIVE_PHOTO_UPLOADS_ENABLED':'1',
            'CLRS_LEGACY_READ_CURSOR_KEY_B64':base64.b64encode(b'c'*32).decode(),
            'CLRS_NATIVE_SESSION_KEY_B64':base64.b64encode(bytes(range(32))).decode(),
            'CLRS_PREVIEW_ACCESS_KEY_B64':base64.b64encode(b'p'*32).decode()}
        legacy = RuntimeProfilePhotosHttp(settings,service_factory=lambda:fixture.reader)
        self.assertIs(factory.create_append_profile_photos_http({},legacy),legacy)
        reader_store = RuntimeMutationStore(store._env, db.tokens, connect=connect, clock=lambda:NOW)
        self.addCleanup(reader_store.close)
        with patch.object(RuntimeMutationStore,'from_env',side_effect=[store, reader_store]), patch.object(factory,'create_native_photo_writer',return_value=port):
            # Actual production tuple/core, not a whole-tuple stand-in.
            http = RuntimeMutationHttp(settings,service_factory=_create)
            self.addCleanup(http.close)
            mixed_http = factory.create_append_profile_photos_http(settings,legacy); self.addCleanup(mixed_http.close)
            http.bind_imported_photo_context(mixed_http.imported_append_context)
            core = http._services[8]._photos; core._wall = lambda:NOW
            native = Native(); native.identity = db.identity
            def call(path, body=None, **values):
                request = env(path,body,**values); request['HTTP_AUTHORIZATION']='Bearer '+db.access
                return http.dispatch(request,native_service=native,native_configured=True)
            self.assertIs(http._services[9]._service,core)
            self.assertEqual(call('/v1/runtime/profile/photos/upload-availability',REQUEST_METHOD='GET').payload['photoCount'],3)
            fields = {'sha256':hashlib.sha256(data).hexdigest(),'byteSize':len(data),'mimeType':'image/jpeg'}
            prepared = call('/v1/runtime/profile/photos/prepare',{'operationId':OP,**fields}); self.assertEqual(prepared.status,'201 Created')
            mid = prepared.payload['result']['mediaId']; self.assertEqual(mid,photo_identity('actor',OP)[0])
            request = {'prepareOperationId':OP,'mediaId':mid}; db.commit_unknown_once = True
            lost = call('/v1/runtime/profile/photos/commit',{'operationId':SECOND,**request})
            self.assertEqual(lost.payload,{'error':'outcome_unknown'})
            found = call('/v1/runtime/operations/'+COMMIT_OPERATION+'/'+SECOND,REQUEST_METHOD='GET',QUERY_STRING='requestHash='+request_digest(request).hex())
            self.assertEqual((found.payload['result']['ordinal'],found.payload['result']['isPrimary']),(3,False))
            page = mixed_http._reader()._select(db.identity,'actor',db.access)
            page._clock = lambda:NOW
            actual = page.photos(db.identity,'actor',access_token=db.access)
            self.assertEqual([x['ordinal'] for x in actual['items']],[0,1,2,3])
            self.assertEqual([x['isPrimary'] for x in actual['items']],[True,False,False,False])
            with page.open_photo(db.identity,'actor',actual['items'][3]['reference'],access_token=db.access) as stream:
                self.assertEqual(data,b''.join(stream.iter_bytes()))
            self.assertEqual(db.state['profiles']['actor'][3],original['profiles']['actor'][3])
            self.assertEqual((db.state['roots'],db.state['galleries']),(original['roots'],original['galleries']))
            self.assertEqual(db.state['photos']['actor'],[['actor',mid,3,0,None]])
            self.assertEqual(sum(s.startswith('INSERT INTO clrs_staging.profile_photos') for s,_ in db.calls),1)
            self.assertFalse(any(s.startswith('DELETE') for s,_ in db.calls))
            # Full source change fails both append and held public read authority.
            saved = copy.deepcopy(db.state); db.state['galleries']['actor'].pop()
            self.assertEqual(call('/v1/runtime/profile/photos/upload-availability',REQUEST_METHOD='GET').status,'404 Not Found')
            with self.assertRaises(RuntimeProfilePhotoNotFound): page.photos(db.identity,'actor',access_token=db.access)
            db.state = copy.deepcopy(saved)
            db.state['media'][mid][1] = 'peer'
            self.assertEqual(call('/v1/runtime/profile/photos/upload-availability',REQUEST_METHOD='GET').status,'404 Not Found')
            db.state = copy.deepcopy(saved)
            db.state['profiles']['actor'][:2] = [0,0]
            self.assertEqual(call('/v1/runtime/profile/photos/upload-availability',REQUEST_METHOD='GET').status,'404 Not Found')
            db.state = copy.deepcopy(saved)
            # A configured photo gate with no proven writer must not break initialization.
            adapter = http._services[9]; adapter._service = None
            http.bind_imported_photo_context(mixed_http.imported_append_context)
            adapter._service = core
            # No healthy logout: actor B cannot use an actor A opaque reference.
            session, tokens = db.tokens.mint('peer','fixture-b',0,NOW); db.state['sessions'][session['session_id']] = session
            from dataclasses import replace
            b = replace(db.identity,uid='peer',session_id=session['session_id'])
            with self.assertRaises(RuntimeInvalidRequest): page.open_photo(b,'actor',actual['items'][3]['reference'],access_token=tokens['accessToken'])
            db.state['accounts']['actor'][0] = 1
            with self.assertRaises(RuntimeRejected): page.photos(db.identity,'actor',access_token=db.access)
        # The same hook proves a canonical imported prefix without weakening its
        # archived root/media/storage proof, including tuple-of-tuples transport.
        from test_runtime_profile_photos import CurrentProfilePhotoTests
        canonical = CurrentProfilePhotoTests(); canonical.addCleanup = self.addCleanup; canonical.setUp()
        def canonical_connect(**config):
            c = Connection(canonical.db); canonical.db.connections.append(c); return c
        canonical.store._connect = canonical_connect
        canonical.db.state['profiles']['actor'][:2] = [1,1]
        source_http = RuntimeProfilePhotosHttp(settings, service_factory=lambda:canonical.service)
        self.addCleanup(source_http.close)
        context = factory.ImportedPhotoAppendContext(source_http)
        core = uploads_module.RuntimeProfilePhotoUploadsService(canonical.store, writer=port, imported_context=context, clock=lambda:NOW)
        self.assertEqual(core.upload_availability(canonical.db.identity, access_token=canonical.db.access)['photoCount'],1)
        # Maximal mixed READ only: one proven imported primary + nineteen exact
        # native original receipt pairs. No extra POST/INSERT trajectory.
        for ordinal in range(1,20):
            prepare_id = '00000000-0000-4000-8000-%012d' % (ordinal * 2)
            commit_id = '00000000-0000-4000-8000-%012d' % (ordinal * 2 + 1)
            mid, object_key = photo_identity('actor',prepare_id)
            canonical.db.state['media'][mid] = [mid,'actor','profile',object_key,'image/jpeg',len(data),fields['sha256'],'ready',1,1,1]
            canonical.db.state['photos']['actor'].append(['actor',mid,ordinal,0,None])
            commit_fields = {'prepareOperationId':prepare_id,'mediaId':mid}
            ready = {'mediaId':mid,'ready':True,'ordinal':ordinal,'isPrimary':False,
                'updatedAt':canonical.db.state['profiles']['actor'][4],'profileAuthority':'canonical-current-v1'}
            for operation, operation_id, request, response, status in (
                    (PREPARE_OPERATION,prepare_id,fields,uploads_module._prepared(mid,fields),201),
                    (COMMIT_OPERATION,commit_id,commit_fields,ready,200)):
                canonical.db.state['receipts'][('actor',operation,operation_id)] = [request_digest(request),'completed',status,
                    canonical_json({'request':request,'response':response}).decode(),None,'synthetic-completed']
        reader = factory._AppendReader(canonical.store,b'c'*32,source_context=context,uploads=core,
            private_s3=port,imported_s3=canonical.service._s3,spool_directory=canonical.temp.name,clock=lambda:NOW)
        self.addCleanup(reader.close)
        maximal = reader.photos(canonical.db.identity,'actor',access_token=canonical.db.access)
        self.assertEqual([x['ordinal'] for x in maximal['items']],list(range(20)))
        self.assertEqual([x['isPrimary'] for x in maximal['items']],[True]+[False]*19)
        maximum_read_queries = canonical.db.connections[-1].query_count
        self.assertLessEqual(maximum_read_queries,64)
        print('bounded_sql_queries: max_mixed_read=%d; connected_max=%d' %
            (maximum_read_queries,max(c.query_count for c in db.connections if hasattr(c,'query_count'))))
        self.assertTrue(all(c.closed for c in db.connections))
        # Actual shared 64-statement deadline stays unchanged for each transaction.
        self.assertLessEqual(max(c.query_count for c in db.connections if hasattr(c,'query_count')),64)


if __name__=='__main__': unittest.main()
