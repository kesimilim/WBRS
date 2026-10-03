"""One bounded actual shared-store/private-S3 fixture; no TCP or real objects."""
import base64
import copy
import hashlib
import json
import ssl
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import runtime_post_media as media
from legacy_conversation_payload import payload_digest
from private_media_s3 import PrivateMediaS3, PrivateMediaUnavailable
from runtime_mutations import RuntimeMutationStore, RuntimeUnavailable
from runtime_profile_photos import RuntimeProfilePhotoNotFound
from runtime_profile_photos_http import RuntimeProfilePhotoMediaReply
from test_runtime_mutations import FakeDatabase, FakeConnection, FakeCursor, ENV, NOW, STAMP

BODY=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
BUCKET='fixture-private'; OWNER='fixture-provider-owner'
ACL=(f'<AccessControlPolicy><Owner><ID>{OWNER}</ID></Owner><AccessControlList><Grant><Grantee><ID>{OWNER}</ID><Type>CanonicalUser</Type></Grantee><Permission>FULL_CONTROL</Permission></Grant></AccessControlList></AccessControlPolicy>').encode()


class Reply:
    def __init__(self,status,body,mime):
        self.status=status; self.body=body; self.headers=[('Content-Length',str(len(body))),('Content-Type',mime)]
    def read(self,n):
        v=self.body[:n]; self.body=self.body[n:]; return v
    def close(self): pass


class S3Transport:
    def __init__(self): self.body=BODY; self.calls=[]
    def open(self,op,bucket,key,deadline,cancel):
        self.calls.append(op); assert bucket==BUCKET
        if op in ('GetBucketAcl','GetObjectAcl'): return Reply(200,ACL,'application/xml')
        if op=='GetBucketPolicy': return Reply(404,b'<Error><Code>NoSuchBucketPolicy</Code></Error>','application/xml')
        if op=='GetObject': return Reply(200,self.body,'image/png')
        raise AssertionError(op)


class Db(FakeDatabase):
    def __init__(self):
        super().__init__(); raw={'fields':{'authorId':{'stringValue':'peer'},'text':{'stringValue':'exact post'},
            'images':{'arrayValue':{'values':[{'stringValue':'gs://source-bucket/posts/original.png'},{'stringValue':'gs://source-bucket/posts/original.png'}]}}},'createTime':STAMP,'updateTime':STAMP}
        root=payload_digest(raw); meta={'size':str(len(BODY)),'contentType':'image/png','generation':'1'}; digest=hashlib.sha256(BODY).digest()
        mid='tw-post-media-'+hashlib.sha256(b'clrs-post-media-v1\0'+media.canonical_json(['post','posts/original.png',root])).hexdigest()
        self.state['post_media_row']=('post','peer','published',raw,'peer',0,'active',mid,'source-bucket','posts/original.png',bytes.fromhex(root),meta,bytes.fromhex(payload_digest(meta)),len(BODY),digest,'clrs-import-quarantine/'+'b'*64,len(BODY),digest,'image/png',bytes.fromhex('c'*64),bytes.fromhex('d'*64),['images[0]','images[1]'],'ready',bytes.fromhex('e'*64)); self.mid=mid
        self.grant_rows=[("GRANT USAGE ON *.* TO 'fixture'@'%' REQUIRE SSL",),("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.* TO 'fixture'@'%'",)]
    def connect(self,**config):
        assert config['ssl'].verify_mode==ssl.CERT_REQUIRED and config['ssl'].check_hostname
        c=Connection(self); self.connections.append(c); return c


class Connection(FakeConnection):
    def cursor(self): return Cursor(self)


class Cursor(FakeCursor):
    def execute(self,statement,params=()):
        sql=' '.join(statement.split())
        if sql==' '.join(media.SQL.split()):
            assert self.c.readonly and self.c.held
            self.c.db.calls.append((sql,params)); r=self.c.state['post_media_row']
            self.rows=[copy.deepcopy(r)] if params==(r[0],r[7]) else []; self.rowcount=len(self.rows); return self.rowcount
        return super().execute(statement,params)


class PostMediaTests(unittest.TestCase):
    def test_exact_published_reference_private_body_first_byte_and_revocation(self):
        db=Db(); store=RuntimeMutationStore({**ENV,'CLRS_RUNTIME_PERMISSION_MODEL':'provider-database-v1'},db.tokens,connect=db.connect,clock=lambda:NOW)
        transport=S3Transport(); s3=PrivateMediaS3(BUCKET,OWNER,transport,lambda b,d,c:{'bucket':b,'type':'private','checked_at':time.monotonic()})
        def decoded(args,**kwargs):
            self.assertEqual(args[1:3],['-I','-B']); self.assertTrue(args[3].endswith('native_photo_raster_worker.py')); self.assertEqual(kwargs['input'],BODY)
            kwargs['stdout'].write(json.dumps({'status':'ok','mime':'image/png','size':len(BODY),'sha256':hashlib.sha256(BODY).hexdigest(),'width':1,'height':1}).encode())
            return type('Result',(),{'returncode':0})()
        def options(): return {'access_token':db.access,'request_deadline':time.monotonic()+60,'request_cancel':threading.Event()}
        with tempfile.TemporaryDirectory() as directory,patch.object(media.subprocess,'run',side_effect=decoded) as worker:
            service=media.RuntimePostMediaService(store,private_s3=s3,spool_directory=directory)
            try:
                lease=service.open_media(db.identity,'post',db.mid,**options()); headers=[]; body=RuntimeProfilePhotoMediaReply(lease,service._check).respond(lambda status,h:headers.append((status,dict(h))))
                self.assertEqual(b''.join(body),BODY); self.assertEqual(headers[0][0],'200 OK'); self.assertEqual(headers[0][1]['Cache-Control'],'private, no-store'); self.assertEqual(worker.call_count,1)
                # Same publisher/ref proof never implies file owner UID. Wrong actual S3 bytes fail before raster/HTTP200.
                transport.body=BODY[:-1]+bytes([BODY[-1]^1])
                with self.assertRaises(PrivateMediaUnavailable): service.open_media(db.identity,'post',db.mid,**options())
                self.assertEqual(worker.call_count,1); transport.body=BODY
                changed=list(db.state['post_media_row']); changed[3]=copy.deepcopy(changed[3]); changed[3]['fields']['extra']={'stringValue':'changed'}; original=db.state['post_media_row']; db.state['post_media_row']=tuple(changed)
                with self.assertRaises(RuntimeUnavailable): service.open_media(db.identity,'post',db.mid,**options())
                db.state['post_media_row']=original
                lease=service.open_media(db.identity,'post',db.mid,**options()); db.state['sessions'][db.identity.session_id]['revoked_at']=STAMP
                self.assertEqual(RuntimeProfilePhotoMediaReply(lease,service._check).respond(lambda *_:self.fail('headers after revoke')).status,'401 Unauthorized')
                db.state['sessions'][db.identity.session_id]['revoked_at']=None; changed=list(original); changed[2]='hidden'; db.state['post_media_row']=tuple(changed)
                with self.assertRaises(RuntimeProfilePhotoNotFound): service.open_media(db.identity,'post',db.mid,**options())
                self.assertIsNone(media.create_post_media_http({},store))
                env={**ENV,'CLRS_RUNTIME_SOCIAL_ENABLED':'1'}; http=media.RuntimePostMediaHttp(env,service); path='/v1/runtime/posts/post/media/'+db.mid+'/content'
                self.assertEqual(http.dispatch({'PATH_INFO':path,'REQUEST_METHOD':'GET','QUERY_STRING':'arbitrary=1'}).status,'400 Bad Request')
                self.assertEqual(media.RuntimePostMediaHttp({},service).dispatch({'PATH_INFO':path,'REQUEST_METHOD':'GET'}).status,'404 Not Found')
            finally: service.close(); store.close()

if __name__=='__main__': unittest.main()
