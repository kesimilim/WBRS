"""New delta-only tests: real current store/spool contracts, synthetic SQL/HTTPS."""
import copy
from dataclasses import replace
import hashlib
import hmac
import json
import os
import tempfile
import unittest
from unittest.mock import patch
import runtime_profile_photo_delta as delta
import runtime_profile_photo_delta_factory as factory
from media_promotion_acknowledgement import VerifiedMediaPromotion
from private_media_s3 import PrivateMediaS3
from runtime_mutations import RuntimeMutationStore, RuntimeRejected, RuntimeUnavailable, canonical_json
from runtime_profile_photos import RuntimeProfilePhotoNotFound, RuntimeInvalidRequest
from runtime_profile_photo_uploads import NATIVE_GALLERY_SQL
from test_runtime_profile_photos import PhotoDatabase, PhotoConnection, PhotoCursor, doc_row, BODY, KEY
from test_private_media_s3 import Port, BUCKET, OWNER
from test_profile_photo_review import source, url
from test_runtime_mutations import ENV, NOW

SIGNING = b'd' * 32
SEPARATE = (KEY, b's' * 32, b'p' * 32)


class Cursor(PhotoCursor):
    def execute(self, statement, params=()):
        if ' '.join(statement.split()) == ' '.join(NATIVE_GALLERY_SQL.split()):
            assert self.c.readonly and self.c.held
            self.rows=copy.deepcopy(self.c.state.get('native',{}).get(params[0],[]))
            self.rowcount=len(self.rows); self.c.db.calls.append((' '.join(statement.split()),params))
            return self.rowcount
        return super().execute(statement,params)


class Connection(PhotoConnection):
    def cursor(self): return Cursor(self)


class Database(PhotoDatabase):
    def connect(self, **values):
        connection=Connection(self); self.connections.append(connection); return connection


class DeltaTests(unittest.TestCase):
    def setUp(self):
        self.db=Database(); self.store=RuntimeMutationStore({**ENV,'CLRS_RUNTIME_PERMISSION_MODEL':'provider-database-v1'},
            self.db.tokens,connect=self.db.connect,clock=lambda:NOW); self.addCleanup(self.store.close)
        self.temp=tempfile.TemporaryDirectory(); os.chmod(self.temp.name,0o700); self.addCleanup(self.temp.cleanup)
        self.port=Port(BODY); self.s3=PrivateMediaS3(BUCKET,OWNER,self.port,
            lambda bucket,deadline,cancel:{'bucket':bucket,'type':'private','checked_at':0},monotonic=lambda:0)
        profiles={}
        for uid in ('actor','peer'):
            root=source('users/'+uid,uid={'stringValue':uid},status={'stringValue':'active'},
                profilePic={'stringValue':url('profile_images/'+uid+'/registration/draft/photo-0.jpg')})
            gallery=[]; photos=[]; stored=[]
            for i in range(3):
                path='profile_images/'+uid+'/registration/draft/photo-'+str(i)+'.jpg'; ident='registration_'+str(i)
                doc=source('users/'+uid+'/images/'+ident,url={'stringValue':url(path)})
                gallery.append({'id':ident,'payload':doc.encoded_payload,'sha256':doc.payload_sha256});stored.append(doc_row(doc,'users/'+uid+'/images'))
                digest=hashlib.sha256(BODY).hexdigest(); generation=str(100+i)
                key='clrs-import-quarantine/'+hashlib.sha256(canonical_json(['clrs-final-storage-delta-v1',
                    delta.SOURCE['project'],delta.SOURCE['bucket'],path,generation,digest])).hexdigest()
                photos.append({'path':path,'imageId':ident,'record':{'key':key,'size':len(BODY),'sha256':digest,'content_type':'image/jpeg'},
                    'sourceMetadata':{'bucket':delta.SOURCE['bucket'],'name':path,'generation':generation,'size':str(len(BODY)),'contentType':'image/jpeg'}})
            profiles[uid]={'root':root.encoded_payload,'rootSha256':root.payload_sha256,'gallery':gallery,'photos':photos}
            self.db.state['roots'][uid]=doc_row(root,'users'); self.db.state['galleries'][uid]=stored
            self.db.state['photos'][uid]=[]; self.db.state['profiles'][uid][3]=root.encoded_payload
        self.body={'kind':'clrs-source-profile-photo-delta-readback-v1','source':delta.SOURCE,'policy':delta.POLICY,
            'sourceFingerprint':delta.source_fingerprint(),'evidence':{name:'e'*64 for name in
                ('sourceCaptureCipherSha256','targetPlanSha256','sqlReadbackCipherSha256','objectReadbackCipherSha256')},
            'profiles':profiles,'targetBucket':BUCKET,'expectedOwner':OWNER,'legacyPromotionCipherSha256':'a'*64,
            'freshSqlReadbackVerified':True,'fullPrivateObjectReadbackVerified':True,'sourceBarrierVerified':False,
            'globallyConsistentFinalCapture':False,'finalAuthority':False}
        self.cap=delta.verify_profile_photo_delta(self.signed(self.body),SIGNING,separate_from=SEPARATE)
        self.reader=delta.RuntimeProfilePhotoDeltaService(self.store,KEY,private_s3=self.s3,snapshot=self.cap,
            spool_directory=self.temp.name,media_promotion=VerifiedMediaPromotion('a'*64,NOW,NOW-1),clock=lambda:NOW,monotonic=lambda:0)
        self.addCleanup(self.reader.close)

    def signed(self, body, key=SIGNING):
        return canonical_json({'body':body,'hmacSha256':hmac.digest(key,delta.DOMAIN+canonical_json(body),'sha256').hex()})

    def page(self, uid='peer'):
        return self.reader.photos(self.db.identity,uid,access_token=self.db.access)

    def test_review_domain_key_false_final_default_closed_and_real_full_originals(self):
        original=object()
        self.assertIs(factory.create_delta_profile_photos_http({},original),original)
        self.assertIs(factory.create_delta_profile_photos_http({},original,snapshot=self.cap),original)
        with self.assertRaises(RuntimeUnavailable): factory.create_delta_profile_photos_http({},original,snapshot=object())
        for change in ({'freshSqlReadbackVerified':False},{'fullPrivateObjectReadbackVerified':False},
                {'sourceBarrierVerified':True},{'finalAuthority':True},{'generation':'f'*64}):
            with self.assertRaises(RuntimeUnavailable): delta.verify_profile_photo_delta(self.signed({**self.body,**change}),SIGNING,separate_from=SEPARATE)
        with self.assertRaises(RuntimeUnavailable): delta.verify_profile_photo_delta(self.signed(self.body,KEY),KEY,separate_from=SEPARATE)
        tampered=copy.deepcopy(self.body);tampered['profiles']['peer']['photos'][0]['record']['key']='clrs-import-quarantine/'+'0'*64
        with self.assertRaises(RuntimeUnavailable): delta.verify_profile_photo_delta(self.signed(tampered),SIGNING,separate_from=SEPARATE)
        before=copy.deepcopy(self.db.state); page=self.page()
        self.assertEqual([x['ordinal'] for x in page['items']],[0,1,2])
        self.assertNotIn('quarantine',json.dumps(page)); self.assertTrue(self.reader.contains(self.db.identity,'peer',access_token=self.db.access))
        with self.reader.open_photo(self.db.identity,'peer',page['items'][0]['reference'],access_token=self.db.access) as lease:
            self.assertEqual(BODY,b''.join(lease.iter_bytes()))
        self.db.state['profiles']['peer'][4]='2026-10-04T00:00:00.000000Z'
        self.db.state['profiles']['peer'][:2]=[1,1]
        self.assertEqual(len(self.page()['items']),3)
        self.assertEqual(before['roots'],self.db.state['roots']);self.assertEqual(before['galleries'],self.db.state['galleries'])
        self.assertTrue(all(not sql.startswith(('INSERT','UPDATE','DELETE')) for sql,_ in self.db.calls))

    def test_ab_revoke_hidden_missing_mixed_source_change_and_disconnect(self):
        reference=self.page()['items'][0]['reference'];state=copy.deepcopy(self.db.state)
        session,tokens=self.db.tokens.mint('peer','fixture-b',0,NOW);self.db.state['sessions'][session['session_id']]=session
        identity=replace(self.db.identity,uid='peer',session_id=session['session_id'])
        with self.assertRaises(RuntimeInvalidRequest):self.reader.open_photo(identity,'peer',reference,access_token=tokens['accessToken'])
        self.db.state=copy.deepcopy(state);self.db.state['profiles']['peer'][2]='2030-01-01T00:00:00.000000Z'
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()
        self.db.state=copy.deepcopy(state);del self.db.state['profiles']['peer']
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()
        self.db.state=copy.deepcopy(state);self.db.state['photos']['peer']=[['peer','legacy-mixed',0,1,None]]
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()
        self.db.state=copy.deepcopy(state);self.db.state['galleries']['peer'].pop()
        with self.assertRaises(RuntimeProfilePhotoNotFound):self.page()
        self.db.state=copy.deepcopy(state);lease=self.reader.open_photo(self.db.identity,'peer',reference,access_token=self.db.access)
        self.db.state['accounts']['actor'][0]=1
        with self.assertRaises(RuntimeRejected):next(lease.iter_bytes())
        self.assertTrue(lease._closed);self.assertFalse(self.reader._leases)
        self.db.state=copy.deepcopy(state);lease=self.reader.open_photo(self.db.identity,'peer',reference,access_token=self.db.access)
        lease.close();lease.close();self.assertTrue(lease._file.closed);self.assertFalse(self.reader._leases)

    def test_real_driver_source_collection_shape_and_exact_source_guard(self):
        original=delta._rows
        expected=(delta.SOURCE['project'],delta.SOURCE['database'],delta.SOURCE['bucket'])
        for collection in ([expected],(expected,),[list(expected)],(list(expected),)):
            with self.subTest(collection=type(collection).__name__,row=type(collection[0]).__name__):
                def rows(cursor,execute,sql,params=()):
                    return collection if sql==delta.SOURCE_SQL else original(cursor,execute,sql,params)
                with patch.object(delta,'_rows',side_effect=rows):
                    self.assertEqual(len(self.page()['items']),3)
        for collection in ([],(),[expected,expected],(expected,expected),
                [('other-project',*expected[1:])],['invalid-row'],{'not':'rows'}):
            with self.subTest(refused=type(collection).__name__):
                def rows(cursor,execute,sql,params=()):
                    return collection if sql==delta.SOURCE_SQL else original(cursor,execute,sql,params)
                with patch.object(delta,'_rows',side_effect=rows):
                    with self.assertRaises(RuntimeProfilePhotoNotFound): self.page()
        # Passing the transport-shape guard does not bypass retained source pins.
        self.db.state['galleries']['peer']=self.db.state['galleries']['peer'][:-1]
        with patch.object(delta,'_rows',side_effect=lambda c,e,s,p=(): (expected,) if s==delta.SOURCE_SQL else original(c,e,s,p)):
            with self.assertRaises(RuntimeProfilePhotoNotFound): self.page()
        self.assertTrue(all(not sql.startswith(('INSERT','UPDATE','DELETE')) for sql,_ in self.db.calls))

    def test_native_precedence_resolves_real_committed_reader_and_no_legacy_fallback(self):
        from test_runtime_native_profile_photos import NativeGalleryTests, GalleryCursor
        import test_runtime_native_profile_photos as native_fixture
        helper=NativeGalleryTests();helper.addCleanup=self.addCleanup
        class InitialCursor(GalleryCursor):
            def execute(inner,statement,params=()):
                result=super().execute(statement,params)
                if statement.startswith('SELECT profile_details_saved'): inner.rows=[(*inner.rows[0],1)]
                return result
        with patch.object(native_fixture,'GalleryCursor',InitialCursor): db,store,_,reader,_,stub,_,_=helper.setup_gallery()
        class NativeComposite:
            def _reader(inner,identity,target,access):return reader
        class CapturedWrapper:
            def _select(inner,identity,target,access):return NativeComposite()
        class Http:
            def _reader(inner):return CapturedWrapper()
        class DeltaBranch:
            def contains(inner,*args,**kwargs):return False
            def has_target(inner,target):return True
        hybrid=factory._DeltaHybrid(DeltaBranch(),Http(),self.store,self.temp)
        selected=hybrid._select(db.identity,'actor',db.access)
        self.assertIs(selected,reader)
        page=selected.photos(db.identity,'actor',access_token=db.access)
        with selected.open_photo(db.identity,'actor',page['items'][0]['reference'],access_token=db.access) as lease:
            self.assertEqual(stub.body,b''.join(lease.iter_bytes()))
        class WrongComposite:
            def _reader(inner,*args):return self.reader
        with patch.object(Http,'_reader',return_value=WrongComposite()):
            with self.assertRaises(RuntimeUnavailable):hybrid._select(db.identity,'actor',db.access)
        with patch('runtime_profile_photo_delta.native_gallery',side_effect=ValueError()):
            self.db.state['native']={'peer':[('mixed',)]}
            with self.assertRaises(RuntimeProfilePhotoNotFound):self.reader.contains(self.db.identity,'peer',access_token=self.db.access)


if __name__=='__main__': unittest.main()
