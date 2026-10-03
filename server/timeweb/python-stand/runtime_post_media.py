"""Reviewed retained-post attachments; private GET bytes, never a source URL.

Only a private reviewed projector may insert post_media. The runtime requires
SELECT only; each ready row binds one exact retained post reference and full
source/target byte proof. Publication grants post-scoped use, not file ownership.
"""
import hashlib
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time

from legacy_conversation_payload import document, media_reference, payload_digest
from legacy_private_media import _metadata, CHUNK_BYTES
from private_media_s3 import PrivateMediaS3, _key
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, canonical_json
from runtime_profile_photos import _PhotoLease, RuntimeProfilePhotoNotFound
from runtime_profile_photos_http import (RuntimeProfilePhotoMediaReply,
    RuntimeProfilePhotosHttpReply, _error, _target)
from native_auth import NativeRejected, NativeUnavailable
from native_sessions import NativeIdentity

MAX_BYTES = 5 * 1024 * 1024
MIMES = {'image/jpeg', 'image/png', 'image/webp'}
MEDIA_ID = re.compile(r'tw-post-media-[a-f0-9]{64}\Z')
PATH = re.compile(r'/v1/runtime/posts/([^/]+)/media/(tw-post-media-[a-f0-9]{64})/content\Z')
SQL = """SELECT p.post_id,p.author_uid,p.status,p.legacy_raw,
 a.uid,a.disabled,a.lifecycle,m.media_id,m.source_bucket,m.source_path,
 m.source_root_sha256,m.source_metadata,m.source_metadata_sha256,
 m.source_byte_size,m.source_sha256,m.target_key,m.target_byte_size,
 m.target_sha256,m.mime_type,m.source_archive_sha256,m.verified_bytes_proof_sha256,
 m.reference_fields,m.status,m.source_generation_id FROM clrs_staging.posts p
 JOIN clrs_staging.accounts a ON a.uid=p.author_uid AND CAST(a.uid AS BINARY)=CAST(p.author_uid AS BINARY)
 JOIN clrs_staging.post_media m ON m.post_id=p.post_id
 JOIN clrs_staging.legacy_source l ON l.singleton=1 AND l.source_bucket=m.source_bucket
 JOIN clrs_staging.clrs_final_generations g ON g.generation_id=m.source_generation_id AND g.state='verified'
 WHERE p.post_id=%s AND m.media_id=%s LIMIT 1 FOR SHARE OF p,a,m,l,g"""


def _sha(value):
    if not isinstance(value,(bytes,bytearray,memoryview)) or len(value)!=32:
        raise RuntimeUnavailable()
    return bytes(value).hex()


class _CapturePath:
    # Reuse existing exact URL parser, without pretending its parse is authority.
    def seal(self,kind,value):
        if kind!='media': raise RuntimeUnavailable()
        return value


def references(raw,bucket):
    f=raw['fields']; result=[]
    if 'imageUrl' in f:
        v=f['imageUrl']
        if type(v) is not dict or set(v)!={'stringValue'}: raise RuntimeUnavailable()
        result.append(('imageUrl',v['stringValue']))
    if 'images' in f:
        v=f['images']
        if (type(v) is not dict or set(v)!={'arrayValue'} or type(v['arrayValue']) is not dict
                or set(v['arrayValue'])!={'values'} or type(v['arrayValue']['values']) is not list
                or not 1<=len(v['arrayValue']['values'])<=4): raise RuntimeUnavailable()
        for n,item in enumerate(v['arrayValue']['values']):
            if type(item) is not dict or set(item)!={'stringValue'}: raise RuntimeUnavailable()
            result.append((f'images[{n}]',item['stringValue']))
    paths=[]
    for field,value in result:
        ref=media_reference(value,bucket=bucket,codec=_CapturePath(),binding={},now=0)
        if type(ref) is not dict or ref.get('kind')!='legacy_storage': raise RuntimeUnavailable()
        paths.append((field,ref['reference']['path']))
    if not paths or len(set(path for _,path in paths))!=1: raise RuntimeUnavailable()
    return [field for field,_ in paths],paths[0][1]


def _raster(file,record,deadline,cancel,clock):
    if cancel.is_set() or clock()>=deadline: raise RuntimeUnavailable()
    file.seek(0); raw=file.read(record['size']+1)
    if len(raw)!=record['size'] or hashlib.sha256(raw).hexdigest()!=record['sha256']:
        raise RuntimeUnavailable()
    worker=Path(__file__).with_name('native_photo_raster_worker.py')
    with tempfile.TemporaryFile(mode='w+b') as out:
        done=subprocess.run([sys.executable,'-I','-B',str(worker),record['content_type'],str(record['size']),record['sha256']],
            input=raw,stdout=out,stderr=subprocess.DEVNULL,timeout=min(2,deadline-clock()),check=False,env={'PATH':os.defpath})
        out.seek(0); encoded=out.read(513)
    value=_metadata(encoded)
    if (done.returncode or set(value)!={'status','mime','size','sha256','width','height'} or value['status']!='ok'
            or value['mime']!=record['content_type'] or value['size']!=record['size'] or value['sha256']!=record['sha256']
            or any(type(value[k]) is not int or not 1<=value[k]<=4096 for k in ('width','height'))
            or value['width']*value['height']>16_000_000 or cancel.is_set() or clock()>=deadline):
        raise RuntimeUnavailable()
    file.seek(0)


class RuntimePostMediaService:
    def __init__(self,store,*,private_s3,spool_directory,monotonic=time.monotonic):
        if type(private_s3) is not PrivateMediaS3 or not callable(getattr(store,'read_authenticated',None)):
            raise RuntimeUnavailable()
        self.store=store; self.s3=private_s3; self.directory=spool_directory; self.clock=monotonic
        self.lock=threading.Lock(); self.leases=set(); self.active=set(); self.closed=False
        self.slots=threading.BoundedSemaphore(2)

    def _check(self):
        with self.lock:
            if self.closed: raise RuntimeUnavailable()

    def _proof(self,identity,token,post_id,media_id):
        def read(c,ex,uid):
            ex(SQL,(post_id,media_id)); r=c.fetchone()
            if r is None: raise RuntimeProfilePhotoNotFound()
            if (len(r)!=24 or r[0]!=post_id or r[1]!=r[4] or r[2]!='published' or r[5]!=0
                    or r[6]!='active' or r[7]!=media_id or r[22]!='ready'):
                raise RuntimeProfilePhotoNotFound()
            raw=document(r[3]); root_sha=_sha(r[10]); fields=raw['fields']
            author=fields.get('authorUid',fields.get('authorId'))
            if type(author) is not dict or author!={'stringValue':r[1]}: raise RuntimeUnavailable()
            if 'authorUid' in fields:
                if 'authorId' in fields and fields['authorId']!=author: raise RuntimeUnavailable()
                if fields.get('status')!={'stringValue':'published'}: raise RuntimeUnavailable()
            elif 'authorId' not in fields or 'status' in fields: raise RuntimeUnavailable()
            if payload_digest(raw)!=root_sha: raise RuntimeUnavailable()
            refs,path=references(raw,r[8]); recorded=_metadata({'fields':r[21]})['fields']
            if isinstance(recorded,str):
                import json
                recorded=json.loads(recorded)
            meta=_metadata(r[11])
            if (path!=r[9] or recorded!=refs or payload_digest(meta)!=_sha(r[12])
                    or type(r[13]) is not int or not 1<=r[13]<=MAX_BYTES or r[16]!=r[13]
                    or _sha(r[14])!=_sha(r[17]) or r[18] not in MIMES
                    or meta.get('contentType')!=r[18] or str(r[13])!=str(meta.get('size'))):
                raise RuntimeUnavailable()
            _sha(r[19]); _sha(r[20]); _key(r[15])
            derived='tw-post-media-'+hashlib.sha256(b'clrs-post-media-v1\0'+canonical_json([post_id,path,root_sha])).hexdigest()
            if derived!=media_id: raise RuntimeUnavailable()
            return {'record':{'key':r[15],'size':r[13],'sha256':_sha(r[14]),'content_type':r[18]},
                'context':[root_sha,path,payload_digest(meta),_sha(r[19]),_sha(r[20]),refs,_sha(r[23])]}
        return self.store.read_authenticated(identity,read,access_token=token)

    def open_media(self,identity,post_id,media_id,*,access_token,request_deadline,request_cancel):
        post_id=_target(post_id)
        if not MEDIA_ID.fullmatch(media_id): raise RuntimeInvalidRequest()
        now=self.clock()
        if (type(request_deadline) not in (int,float) or not math.isfinite(request_deadline)
                or not now<request_deadline<=now+60 or not isinstance(request_cancel,threading.Event)
                or request_cancel.is_set()): raise RuntimeInvalidRequest()
        self._check()
        if not self.slots.acquire(blocking=False): raise RuntimeUnavailable()
        file=None; handed=False; holder=[None]; timer=None; before=None; cancel=request_cancel
        with self.lock: self.active.add(cancel)
        def release():
            with self.lock:
                self.active.discard(cancel); self.leases.discard(holder[0])
            self.slots.release()
        def check():
            self._check()
            if cancel.is_set() or self.clock()>=request_deadline: raise RuntimeUnavailable()
        def fresh():
            check()
            if self._proof(identity,access_token,post_id,media_id)!=before: raise RuntimeProfilePhotoNotFound()
            check()
        def expire():
            cancel.set()
            with self.lock: lease=holder[0]
            if lease is not None: lease.close()
        try:
            timer=threading.Timer(request_deadline-now,expire); timer.daemon=True; timer.start()
            check(); before=self._proof(identity,access_token,post_id,media_id)
            info=os.lstat(self.directory)
            if (not os.path.isabs(self.directory) or not stat.S_ISDIR(info.st_mode)
                    or stat.S_IMODE(info.st_mode)!=0o700 or info.st_uid!=os.getuid()): raise RuntimeUnavailable()
            file=tempfile.TemporaryFile(mode='w+b',dir=self.directory)
            self.s3.get_verified_to_file(before['record'],file,deadline=min(request_deadline,self.clock()+50),cancel=cancel)
            check(); _raster(file,before['record'],request_deadline,cancel,self.clock); fresh()
            lease=_PhotoLease(file,before['record'],before_first_byte=fresh,check=check,cancel=cancel,
                deadline=request_deadline,monotonic=self.clock,timer=timer,release=release)
            with self.lock:
                if self.closed or cancel.is_set(): raise RuntimeUnavailable()
                holder[0]=lease; self.leases.add(lease); handed=True
            return lease
        finally:
            if not handed:
                cancel.set()
                if timer is not None: timer.cancel()
                if file is not None: file.close()
                release()

    def close(self):
        with self.lock:
            self.closed=True; active=list(self.active); leases=list(self.leases)
        for c in active: c.set()
        for lease in leases: lease.close()


class RuntimePostMediaHttp:
    def __init__(self,env,service):
        self.enabled=(env.get('CLRS_RUNTIME_WRITES_ENABLED')=='1'
            and env.get('CLRS_RUNTIME_MEMBERSHIP_AUTHORITY')=='canonical-current-v1'
            and env.get('CLRS_RUNTIME_SOCIAL_ENABLED')=='1' and service is not None)
        self.service=service

    def close(self):
        if self.service is not None: self.service.close()
        directory=getattr(self,'_owned_directory',None)
        if directory is not None: directory.cleanup()

    def dispatch(self,environ,*,native_service=None,native_configured=False):
        path=environ.get('PATH_INFO',''); match=PATH.fullmatch(path) if type(path) is str else None
        if match is None: return None
        if not self.enabled: return RuntimeProfilePhotosHttpReply('404 Not Found',{'error':'not_found'})
        if environ.get('REQUEST_METHOD')!='GET': return RuntimeProfilePhotosHttpReply('405 Method Not Allowed',{'error':'method_not_allowed'})
        lease=None
        try:
            if (environ.get('QUERY_STRING','')!='' or environ.get('CONTENT_LENGTH','') not in ('','0')
                    or any(k in environ for k in ('HTTP_RANGE','HTTP_IF_RANGE')) or environ.get('HTTP_TRANSFER_ENCODING')):
                raise RuntimeInvalidRequest()
            header=environ.get('HTTP_AUTHORIZATION','')
            if type(header) is not str or not header.startswith('Bearer na1.') or len(header)>135 or any(c.isspace() for c in header[7:]):
                raise NativeRejected()
            if not native_configured: raise NativeRejected()
            if native_service is None: raise NativeUnavailable()
            token=header[7:]; identity=native_service.authorize(token,peer=environ.get('REMOTE_ADDR',''))
            if type(identity) is not NativeIdentity: raise NativeUnavailable()
            begin=environ.get('clrs.media_request_budget')
            if not callable(begin): raise RuntimeUnavailable()
            deadline,cancel=begin(); lease=self.service.open_media(identity,match[1],match[2],access_token=token,
                request_deadline=deadline,request_cancel=cancel)
            return RuntimeProfilePhotoMediaReply(lease,self.service._check)
        except Exception as error:
            if lease is not None: lease.close()
            return _error(error)


def create_post_media_http(env,store):
    """Trusted setup only; no new flag, cloud request or owned SQL store."""
    if (env.get('CLRS_RUNTIME_WRITES_ENABLED')!='1'
            or env.get('CLRS_RUNTIME_MEMBERSHIP_AUTHORITY')!='canonical-current-v1'
            or env.get('CLRS_RUNTIME_SOCIAL_ENABLED')!='1'
            or env.get('CLRS_LEGACY_MEDIA_S3_USER_MODE')!='dedicated-read-only'):
        return None
    directory=None
    try:
        from private_media_s3 import SigV4HTTPSReadTransport, TimewebPrivateBucketState
        bucket_id=env.get('CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID','')
        if type(bucket_id) is not str or re.fullmatch(r'[1-9][0-9]{0,18}',bucket_id) is None:
            raise RuntimeUnavailable()
        bucket=env.get('CLRS_LEGACY_MEDIA_TARGET_BUCKET')
        transport=SigV4HTTPSReadTransport('https://s3.twcstorage.ru/',env.get('CLRS_LEGACY_MEDIA_S3_REGION'),
            env.get('CLRS_LEGACY_MEDIA_S3_ACCESS_KEY'),env.get('CLRS_LEGACY_MEDIA_S3_SECRET_KEY'))
        state=TimewebPrivateBucketState(int(bucket_id),bucket,env.get('CLRS_LEGACY_MEDIA_CONTROL_TOKEN'))
        s3=PrivateMediaS3(bucket,env.get('CLRS_LEGACY_MEDIA_EXPECTED_OWNER'),transport,state)
        directory=tempfile.TemporaryDirectory(prefix='clrs-post-media-'); os.chmod(directory.name,0o700)
        http=RuntimePostMediaHttp(env,RuntimePostMediaService(store,private_s3=s3,spool_directory=directory.name))
        http._owned_directory=directory
        return http
    except Exception:
        if directory is not None: directory.cleanup()
        return None
