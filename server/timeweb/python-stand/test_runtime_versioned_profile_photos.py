"""New actual store/HTTP/lease integration; SQL+HTTPS fixtures, no cloud."""
import copy
from dataclasses import replace
import hashlib
import hmac
import json
import os
import tempfile
import unittest
from unittest.mock import patch
import runtime_versioned_profile_photos as v
import runtime_versioned_profile_photos_factory as factory
from media_promotion_acknowledgement import VerifiedMediaPromotion
from runtime_mutations import RuntimeMutationStore, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_profile_photos import RuntimeProfilePhotoNotFound, RuntimeInvalidRequest
from runtime_profile_photos_http import RuntimeProfilePhotoMediaReply
from private_media_s3 import PrivateMediaS3
from test_runtime_profile_photos import PhotoDatabase, PhotoConnection, PhotoCursor, BODY, KEY
from test_private_media_s3 import Port, BUCKET, OWNER
from test_runtime_mutations import ENV, NOW
from test_profile_photo_review import url


class Cursor(PhotoCursor):
    def execute(self, statement, params=()):
        sql=' '.join(statement.split()); state=self.c.state
        if sql==' '.join(v.GENERATION_SQL.split()): self.rows=[('verified',86990,870)]
        elif sql==' '.join(v.PROFILE_SQL.split()):
            self.rows=[(state['versions'][params[1]],bytes.fromhex(state['profilePins'][params[1]]))]
        elif sql==' '.join(v.VERSION_SQL.split()):
            value=state['mediaVersions'][params[2]]
            self.rows=[(params[2],value,bytes.fromhex(hashlib.sha256(canonical_json(value)).hexdigest()))]
        else: return super().execute(statement,params)
        assert self.c.readonly and self.c.held and sql.endswith('FOR SHARE')
        self.c.db.calls.append((sql,params)); self.rowcount=len(self.rows); return self.rowcount


class Connection(PhotoConnection):
    def cursor(self): return Cursor(self)


class Database(PhotoDatabase):
    def connect(self, **config):
        connection=Connection(self); self.connections.append(connection); return connection


class VersionedTests(unittest.TestCase):
    def setUp(self):
        self.db=Database(); self.db.state.update(versions={},profilePins={},mediaVersions={})
        self.store=RuntimeMutationStore({**ENV,'CLRS_RUNTIME_PERMISSION_MODEL':'provider-database-v1'},
            self.db.tokens,connect=self.db.connect,clock=lambda:NOW); self.addCleanup(self.store.close)
        self.temp=tempfile.TemporaryDirectory(); os.chmod(self.temp.name,0o700);self.addCleanup(self.temp.cleanup)
        self.port=Port(BODY);self.s3=PrivateMediaS3(BUCKET,OWNER,self.port,
            lambda bucket,deadline,cancel:{'bucket':bucket,'type':'private','checked_at':0},monotonic=lambda:0)
        capProfiles={};capMedia={}
        for uid in ['actor','peer','spare1','spare2','spare3','spare4','spare5']:
            self.db.add_profile(uid); path='users/'+uid+'/photos/new.jpg'; baseline=self.db.state['profiles'][uid][3]
            root=copy.deepcopy(baseline);root['fields']['profilePic']={'stringValue':url(path)}
            digest=hashlib.sha256(BODY).hexdigest();generation='1234567'
            key='clrs-import-quarantine/'+hashlib.sha256(canonical_json(['clrs-final-storage-delta-v1',
                v.SOURCE['project'],v.SOURCE['bucket'],path,generation,digest])).hexdigest()
            record={'key':key,'size':len(BODY),'sha256':digest,'content_type':'image/jpeg'}
            value={'source':{'name':path,'metadata':{'size':str(len(BODY)),'contentType':'image/jpeg','generation':generation}},
                'target':{'targetKey':key,'size':len(BODY),'sha256':digest,'contentType':'image/jpeg'},'copyProofSha256':v.PINS['storageCopy']}
            pin=hashlib.sha256(canonical_json(value)).hexdigest();capMedia[v._digest(path)]=pin
            self.db.state['mediaVersions'][path]=value
            profile=self.db.state['profiles'][uid]
            guard=[uid,0,'active',uid,*profile[:3],v._digest(canonical_json(baseline).decode()),profile[4]]
            bundle={'uid':uid,'policy':v.POLICY,'root':root,'rootSha256':v.payload_digest(root),'gallery':[],
                'canonicalGuard':guard,'originalAssociations':copy.deepcopy(self.db.state['photos'][uid]),
                'referenceCohort':[{'name':path,'owner':uid,'purpose':'profile','validContext':True,'documentPath':'users/'+uid}],
                'photos':[{'path':path,'imageId':None,'mediaId':'version-media-'+key.split('/')[-1],
                    'record':record,'versionSha256':pin,'storageProof':None,'currentMetadata':value['source']['metadata']}]}
            bpin=hashlib.sha256(canonical_json(bundle)).hexdigest();self.db.state['versions'][uid]=bundle
            self.db.state['profilePins'][uid]=bpin;capProfiles[uid]=bpin
        for i in range(7):capMedia[hashlib.sha256(str(i).encode()).hexdigest()]='f'*64
        body={'kind':'clrs-captured-photo-versions-readback-v1','pins':v.PINS,'policy':v.POLICY,
            'sourceFingerprint':v.source_fingerprint(),'profiles':capProfiles,'media':capMedia,
            'freshReadbackVerified':True,'shadowGenerationVerified':True,'objectCopiesVerified':True,
            'sourceBarrierVerified':False,'canonicalWrites':0,'legacyPromotionCipherSha256':'a'*64,
            'targetBucket':BUCKET,'expectedOwner':OWNER}
        self.raw=canonical_json({'body':body,'hmacSha256':hmac.digest(KEY,b'clrs-captured-photo-versions-readback-v1\0'+canonical_json(body),'sha256').hex()})
        self.cap=v.verify_photo_versions(self.raw,KEY)
        self.reader=v.RuntimeVersionedProfilePhotosService(self.store,KEY,private_s3=self.s3,snapshot=self.cap,
            spool_directory=self.temp.name,media_promotion=VerifiedMediaPromotion('a'*64,NOW,NOW-1),clock=lambda:NOW,monotonic=lambda:0);self.addCleanup(self.reader.close)

    def page(self, uid='peer'):
        return self.reader.photos(self.db.identity,uid,access_token=self.db.access)

    def test_actual_session_versioned_original_stream_disconnect_and_current_guard(self):
        page=self.page();ref=page['items'][0]['reference']
        self.assertNotIn('quarantine',json.dumps(page));self.assertNotIn('sha256',json.dumps(page))
        lease=self.reader.open_photo(self.db.identity,'peer',ref,access_token=self.db.access)
        status=[];body=RuntimeProfilePhotoMediaReply(lease,lambda:None).respond(lambda s,h:status.append(s))
        self.assertEqual(status,['200 OK']);self.assertTrue(next(body));body.close();body.close()
        self.assertTrue(lease._file.closed);self.assertFalse(self.reader._leases)
        self.db.state['profiles']['peer'][4]='2026-10-04T00:00:00.000000Z'
        self.db.state['profiles']['peer'][:2]=[1,1]
        self.assertEqual(len(self.page()['items']),1)
        with self.assertRaises(RuntimeInvalidRequest):self.reader.open_photo(self.db.identity,'peer',ref,access_token=self.db.access)
        self.db.state['profiles']['peer'][3]['fields']['uid']={'stringValue':'different'}
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()
        self.assertTrue(all(not sql.startswith(('INSERT','UPDATE','DELETE')) for sql,_ in self.db.calls))

    def test_real_committed_native_replacement_current_branch_no_imported_fallback(self):
        from test_runtime_native_profile_photos import NativeGalleryTests, GalleryCursor
        import test_runtime_native_profile_photos as native_fixture
        import native_profile_photo_factory as native_factory
        helper=NativeGalleryTests();helper.addCleanup=self.addCleanup
        class InitialCursor(GalleryCursor):
            def execute(inner,statement,params=()):
                result=super().execute(statement,params)
                if statement.startswith('SELECT profile_details_saved'):
                    inner.rows=[(*inner.rows[0],1)]
                return result
        with patch.object(native_fixture,'GalleryCursor',InitialCursor):
            db,store,_,_,port,stub,_,_=helper.setup_gallery()
        guard=['actor',0,'active','actor',0,0,None,v._digest(canonical_json({}).decode()),db.state['profiles']['actor']]
        bundle=copy.deepcopy(self.db.state['versions']['actor']);bundle['canonicalGuard']=guard
        pin=hashlib.sha256(canonical_json(bundle)).hexdigest();v._CAPS[self.cap]['profiles']['actor']=pin
        class CapturedCursor(GalleryCursor):
            def execute(inner,statement,params=()):
                sql=' '.join(statement.split())
                if sql==' '.join(v.GENERATION_SQL.split()):inner.rows=[('verified',86990,870)]
                elif sql==' '.join(v.PROFILE_SQL.split()):inner.rows=[(bundle,bytes.fromhex(pin))]
                else:return super().execute(statement,params)
                self.assertTrue(inner.c.readonly and inner.c.held);inner.rowcount=len(inner.rows)
                return inner.rowcount
        original_connect=db.connect
        def connect(**values):
            connection=original_connect(**values);connection.cursor=lambda:CapturedCursor(connection);return connection
        read_store=RuntimeMutationStore(db.env,db.tokens,connect=connect,clock=lambda:NOW)
        self.addCleanup(read_store.close)
        versioned=v.RuntimeVersionedProfilePhotosService(read_store,KEY,private_s3=self.s3,snapshot=self.cap,
            spool_directory=self.temp.name,media_promotion=self.reader._promotion,clock=lambda:NOW,monotonic=lambda:0)
        self.addCleanup(versioned.close)
        class OldHttp:
            _enabled=True
            def _reader(inner):raise AssertionError('imported fallback forbidden')
            def close(inner):pass
        settings={**db.env,'CLRS_LEGACY_READ_CURSOR_KEY_B64':__import__('base64').b64encode(b'c'*32).decode(),
            'CLRS_NATIVE_SESSION_KEY_B64':__import__('base64').b64encode(bytes(range(32))).decode(),
            'CLRS_PREVIEW_ACCESS_KEY_B64':__import__('base64').b64encode(b'p'*32).decode()}
        with patch.object(native_factory.RuntimeMutationStore,'from_env',return_value=read_store):
            composite=native_factory._Composite(settings,OldHttp())
        self.addCleanup(composite.close)
        class NativeHttp:
            def _reader(inner):return composite
            def close(inner):composite.close()
        hybrid=factory._Hybrid(versioned,NativeHttp(),read_store,self.temp)
        with patch.object(native_factory,'create_native_photo_writer',return_value=port):
            page=hybrid.photos(db.identity,'actor',access_token=db.access)
        self.assertEqual(len(page['items']),1)
        with hybrid.open_photo(db.identity,'actor',page['items'][0]['reference'],access_token=db.access) as lease:
            self.assertEqual(b''.join(lease.iter_bytes()),stub.body)
        before=len(stub.calls)
        receipt=next(row for key,row in db.state['receipts'].items() if key[1]=='profile.photo.commit.v1')
        saved=receipt[3];value=json.loads(saved);value['response']['ordinal']=1;receipt[3]=json.dumps(value)
        with self.assertRaises(RuntimeProfilePhotoNotFound):hybrid.photos(db.identity,'actor',access_token=db.access)
        receipt[3]=saved
        db.state['media']['legacy-mixed']=['legacy-mixed','actor','profile','clrs-import-quarantine/'+'f'*64,
            'image/jpeg',1,'a'*64,'ready',0,1,1]
        db.state['photos']['actor'].append(['legacy-mixed',1,0])
        with self.assertRaises(RuntimeProfilePhotoNotFound):hybrid.photos(db.identity,'actor',access_token=db.access)
        db.state['photos']['actor'].pop()
        from native_sessions import NativeIdentity
        session,tokens=db.tokens.mint('peer','fixture-b',0,NOW)
        db.state['sessions'][session['session_id']]=session
        peer=NativeIdentity('peer',True,session['session_id'],NOW,NOW+900)
        db.state['flags']['actor']=[1,1]
        self.assertEqual(len(hybrid.photos(peer,'actor',access_token=tokens['accessToken'])['items']),1)
        db.state['accounts']['actor'][0]=1
        with self.assertRaises(RuntimeProfilePhotoNotFound):hybrid.photos(peer,'actor',access_token=tokens['accessToken'])
        with self.assertRaises(RuntimeRejected):hybrid.photos(db.identity,'actor',access_token=db.access)
        self.assertEqual(db.state['accounts']['peer'][0],0)
        self.assertEqual(len(stub.calls),before)

    def test_tamper_foreign_visibility_and_actor_revocation_after_spool_before_byte(self):
        before=copy.deepcopy(self.db.state)
        with self.assertRaises(RuntimeRejected):self.reader.photos(replace(self.db.identity,uid='peer'),'peer',access_token=self.db.access)
        self.db.state['photos']['peer'].append(['peer','native-media-'+'c'*64,1,0,None])
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()
        self.db.state=copy.deepcopy(before);self.db.state['profiles']['peer'][2]='2030-01-01T00:00:00.000000Z'
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()
        self.db.state=copy.deepcopy(before);self.db.state['versions']['peer']['photos'][0]['record']['key']='clrs-import-quarantine/'+'a'*64
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()
        self.db.state=copy.deepcopy(before);ref=self.page()['items'][0]['reference']
        lease=self.reader.open_photo(self.db.identity,'peer',ref,access_token=self.db.access)
        self.db.state['accounts']['actor'][0]=1
        with self.assertRaises(RuntimeRejected):next(lease.iter_bytes())
        self.assertTrue(lease._closed);self.assertFalse(self.reader._leases)

    def test_shared_unchanged_copy_uses_exact_current_reference_without_owner_guess(self):
        uid='peer'; bundle=self.db.state['versions'][uid]; baseline=self.db.state['profiles'][uid][3]
        bundle['root']=copy.deepcopy(baseline);bundle['rootSha256']=v.payload_digest(baseline)
        path=self.db.state['photos'][uid][0][1];media=self.db.state['media'][path]
        sourcePath=media[10];row=self.db.state['storage'][sourcePath]
        row[2].update(generation='1234567',size=str(len(BODY)),md5Hash='synthetic-md5',crc32c='synthetic-crc')
        proof=dict(zip(v._STORAGE_COLUMNS,row));proof['source_sha256']=row[4].hex();proof['target_sha256']=row[6].hex()
        proof['copied_at']=row[7].strftime('%Y-%m-%d %H:%M:%S.%f')
        bundle['photos']=[{'path':sourcePath,'imageId':None,'mediaId':'version-ref-'+'b'*64,
            'record':{'key':row[5],'size':len(BODY),'sha256':row[4].hex(),'content_type':'image/jpeg'},
            'versionSha256':None,'storageProof':proof,'currentMetadata':copy.deepcopy(row[2])}]
        bundle['referenceCohort']=[{'name':sourcePath,'owner':x,'purpose':'profile','validContext':True,
            'documentPath':'users/'+x} for x in ['peer','other-private-owner']]
        # The old media row remains raw/other owner; neither field is rewritten or used as access.
        media[1]='other-private-owner';media[9]='raw'
        pin=hashlib.sha256(canonical_json(bundle)).hexdigest();self.db.state['profilePins'][uid]=pin
        v._CAPS[self.cap]['profiles'][uid]=pin
        reference=self.page()['items'][0]['reference']
        with self.reader.open_photo(self.db.identity,uid,reference,access_token=self.db.access) as lease:
            self.assertEqual(BODY,b''.join(lease.iter_bytes()))
        self.assertEqual(media[1:2],['other-private-owner']);self.assertEqual(media[9],'raw')
        row[2]['generation']='different'
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()

    def test_default_closed_false_proof_and_literal_token_alias_only(self):
        legacy=object();self.assertIs(factory.create_versioned_profile_photos_http({},legacy),legacy)
        with self.assertRaises(RuntimeUnavailable):factory.create_versioned_profile_photos_http({},legacy,snapshot=v.VerifiedPhotoVersions())
        corrupt=bytearray(self.raw);corrupt[-2]^=1
        with self.assertRaises(RuntimeUnavailable):v.verify_photo_versions(bytes(corrupt),KEY)
        root=copy.deepcopy(self.db.state['versions']['peer']['root']);path=self.db.state['versions']['peer']['photos'][0]['path']
        payload=copy.deepcopy(root);payload['fields']={'url':{'stringValue':url(path).replace('never-public','rotated-token')}}
        gallery=[{'id':'photo','payload':payload,'sha256':v.payload_digest(payload)}]
        self.assertEqual(v.source_slots('peer',root,gallery),[[path,'photo']])
        payload['fields']['url']['stringValue']+='&generation=123';gallery[0]['sha256']=v.payload_digest(payload)
        with self.assertRaises(RuntimeProfilePhotoNotFound):v.source_slots('peer',root,gallery)

if __name__=='__main__':unittest.main()
