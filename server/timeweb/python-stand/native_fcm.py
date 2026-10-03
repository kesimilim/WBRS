"""Fixed-host FCM HTTP v1. Service-account credentials stay only on the server."""
import base64
import http.client
import json
import re
import ssl
import threading
import time
from urllib.parse import urlencode
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from native_credentials import decode_base64, unique_json
from runtime_mutations import RuntimeUnavailable, canonical_json

_SCOPE='https://www.googleapis.com/auth/firebase.messaging'
_SLOTS=threading.BoundedSemaphore(2)

def _b64(value):return base64.urlsafe_b64encode(value).decode().rstrip('=')

def _post(host,path,body,headers,deadline,cancel,clock):
    # At most two daemon DNS/connect jobs; late results close without retry.
    if cancel.is_set() or clock()>=deadline or not _SLOTS.acquire(False):raise RuntimeUnavailable()
    try:
        context=ssl.create_default_context();context.minimum_version=ssl.TLSVersion.TLSv1_2
        c=http.client.HTTPSConnection(host,443,timeout=max(.001,min(2,deadline-clock())),context=context)
    except Exception:_SLOTS.release();raise RuntimeUnavailable() from None
    done=threading.Event();result=[]
    def request():
        try:
            c.connect()
            if cancel.is_set() or clock()>=deadline:raise RuntimeUnavailable()
            c.sock.settimeout(max(.001,min(2,deadline-clock())))
            c.request('POST',path,body=body,headers={**headers,'Content-Length':str(len(body)),
                'Connection':'close','Accept-Encoding':'identity'})
            stream=c.sock;r=c.getresponse();raw=bytearray()
            if r.status!=200 or r.getheader('Content-Encoding') not in (None,'identity'):raise RuntimeUnavailable()
            while True:
                if cancel.is_set() or clock()>=deadline:raise RuntimeUnavailable()
                if r.isclosed():break
                stream.settimeout(max(.001,min(2,deadline-clock())))
                chunk=r.read(min(4096,16385-len(raw)))
                if not chunk:break
                raw.extend(chunk)
                if len(raw)>16384:raise RuntimeUnavailable()
            value=unique_json(raw.decode())
            if not cancel.is_set() and clock()<deadline:result.append(value)
        except Exception:pass
        finally:c.close();_SLOTS.release();done.set()
    try:threading.Thread(target=request,daemon=True,name='clrs-fcm-tls').start()
    except Exception:c.close();_SLOTS.release();raise RuntimeUnavailable() from None
    while not done.wait(.02):
        if cancel.is_set() or clock()>=deadline:
            c.close();raise RuntimeUnavailable()
    if len(result)!=1:raise RuntimeUnavailable()
    return result[0]

class NativeFCM:
    def __init__(self,credential,*,post=_post,clock=time.time,monotonic=time.monotonic):
        if (type(credential) is not dict or credential.get('type')!='service_account'
                or credential.get('project_id')!='chatapp-4e347'
                or credential.get('token_uri')!='https://oauth2.googleapis.com/token'
                or type(credential.get('client_email')) is not str
                or re.fullmatch(r'[a-z0-9-]+@chatapp-4e347\.iam\.gserviceaccount\.com',credential['client_email']) is None
                or type(credential.get('private_key')) is not str):raise RuntimeUnavailable()
        try:self.key=serialization.load_pem_private_key(credential['private_key'].encode(),password=None)
        except Exception:raise RuntimeUnavailable() from None
        if not isinstance(self.key,rsa.RSAPrivateKey) or self.key.key_size<2048:raise RuntimeUnavailable()
        self.email=credential['client_email'];self.post=post;self.clock=clock;self.mono=monotonic
        self.lock=threading.Lock();self.access=None;self.expires=0;self.closed=False
    def prepare(self,deadline,cancel):
        with self.lock:
            if self.closed:raise RuntimeUnavailable()
            now=int(self.clock())
            if self.access is not None and self.expires>now+10:return
            head=_b64(canonical_json({'alg':'RS256','typ':'JWT'}))
            claims=_b64(canonical_json({'iss':self.email,'scope':_SCOPE,'aud':'https://oauth2.googleapis.com/token','iat':now,'exp':now+3600}))
            signed=head+'.'+claims
            assertion=signed+'.'+_b64(self.key.sign(signed.encode(),padding.PKCS1v15(),hashes.SHA256()))
            raw=urlencode({'grant_type':'urn:ietf:params:oauth:grant-type:jwt-bearer','assertion':assertion}).encode()
            value=self.post('oauth2.googleapis.com','/token',raw,{'Content-Type':'application/x-www-form-urlencoded'},deadline,cancel,self.mono)
            if (not {'access_token','token_type','expires_in'}<=set(value) or value['token_type']!='Bearer'
                    or type(value['expires_in']) is not int or not 1<=value['expires_in']<=3600
                    or type(value['access_token']) is not str or not 1<=len(value['access_token'])<=4096
                    or any(ord(c)<33 or ord(c)>126 for c in value['access_token'])):raise RuntimeUnavailable()
            self.access=value['access_token'];self.expires=now+value['expires_in']
    def send(self,token,data,*,sound,tag,deadline,cancel):
        with self.lock:
            if self.closed or self.access is None or self.expires<=self.clock()+1:raise RuntimeUnavailable()
            access=self.access
        body=canonical_json({'message':{'token':token,'notification':{'title':'CLRS','body':'У вас новое сообщение'},
            'data':{**data,'soundEnabled':str(sound).lower()},
            'android':{'priority':'high','ttl':'86400s','notification':{'channel_id':'wbrs' if sound else 'wbrs_silent','tag':tag}},
            'apns':{'headers':{'apns-collapse-id':tag[:64]},'payload':{'aps':{'sound':'default'} if sound else {}}}}})
        value=self.post('fcm.googleapis.com','/v1/projects/chatapp-4e347/messages:send',body,
            {'Content-Type':'application/json','Authorization':'Bearer '+access},deadline,cancel,self.mono)
        if set(value)!={'name'} or type(value['name']) is not str or re.fullmatch(r'projects/chatapp-4e347/messages/[A-Za-z0-9%:_-]{1,512}',value['name']) is None:raise RuntimeUnavailable()
        return True
    def close(self):
        with self.lock:self.closed=True;self.access=None;self.key=None;self.expires=0

def create_native_fcm(env):
    try:
        value=env.get('CLRS_NATIVE_FCM_SERVICE_ACCOUNT_B64')
        if not value:return None
        return NativeFCM(unique_json(decode_base64(value,max_bytes=32768).decode()))
    except Exception:return None
