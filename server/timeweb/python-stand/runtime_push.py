"""Native token ownership, original receipts and at-most-once bounded delivery."""
import hashlib
import re
import secrets
import threading
import time
from datetime import datetime, timezone
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from native_credentials import decode_base64, unique_json
from native_sessions import _date
from runtime_chat import _pair, _ChatFailure, _integer, _identifier
from runtime_mutations import (RuntimeUnavailable, RuntimeInvalidRequest, RuntimeRejected,
    RuntimeCommitUnknown, MAX_INTEGER, canonical_json, _Work)
from runtime_preferences import _read as preferences

REGISTER='push.register.v1';REVOKE='push.revoke.v1';MAX_DEVICES=4
TOKEN_ROW='SELECT device_id,fcm_token_hash,fcm_token_ciphertext FROM clrs_staging.device_push_tokens WHERE uid=%s ORDER BY BINARY device_id LIMIT 5 FOR UPDATE'

class PushCodec:
    def __init__(self,key):
        if type(key) is not bytes or len(key)!=32:raise RuntimeUnavailable()
        self.aes=AESGCM(key)
    def seal(self,uid,device,sid,token):
        n=secrets.token_bytes(12);return n+self.aes.encrypt(n,canonical_json({'sessionId':sid,'token':token}),canonical_json(['clrs-native-push-token-v1',uid,device]))
    def open(self,uid,device,cipher):
        try:
            raw=bytes(cipher)
            if not 28<len(raw)<=8192:raise ValueError()
            v=unique_json(self.aes.decrypt(raw[:12],raw[12:],canonical_json(['clrs-native-push-token-v1',uid,device])).decode())
            if set(v)!={'sessionId','token'} or type(v['sessionId']) is not str or re.fullmatch(r'[A-Za-z0-9_-]{32}',v['sessionId']) is None:raise ValueError()
            token_text(v['token']);return v
        except Exception:raise RuntimeUnavailable() from None

def token_text(value):
    if type(value) is not str or not 20<=len(value)<=4096 or any(not 33<=ord(c)<=126 for c in value):raise RuntimeInvalidRequest()
    return value

def token_hash(value):return hashlib.sha256(token_text(value).encode()).digest()
def tombstone(uid,device,sid):return hashlib.sha256(b'clrs-native-push-revoked-v1\0'+canonical_json([uid,device,sid])).digest()

def _device(c,ex,uid,sid):
    ex('SELECT uid,device_id FROM clrs_staging.device_sessions WHERE session_id=%s LIMIT 1 FOR SHARE',(sid,));r=c.fetchone()
    if r is None or len(r)!=2 or r[0]!=uid or type(r[1]) is not str or not 1<=len(r[1])<=191:raise RuntimeUnavailable()
    return r[1]

def _token_rows(c,ex,uid):
    ex(TOKEN_ROW,(uid,));rows=c.fetchall()
    if len(rows)>MAX_DEVICES:raise RuntimeUnavailable()
    if any(len(r)!=3 or type(r[0]) is not str or not isinstance(r[1],(bytes,bytearray)) or len(r[1])!=32 or not isinstance(r[2],(bytes,bytearray)) or len(r[2])>8192 for r in rows):raise RuntimeUnavailable()
    return rows

def revoke_session_token(c,ex,codec,uid,device,sid):
    """Trusted native_sessions hook, INSIDE its existing transaction."""
    for d,digest,cipher in _token_rows(c,ex,uid):
        if d!=device or not cipher:continue
        if codec.open(uid,d,cipher)['sessionId']!=sid:continue
        ex('UPDATE clrs_staging.device_push_tokens SET fcm_token_hash=%s,fcm_token_ciphertext=%s,updated_at=UTC_TIMESTAMP(6) WHERE uid=%s AND device_id=%s AND fcm_token_hash=%s',
            (tombstone(uid,d,sid),b'',uid,d,digest))
        if c.rowcount!=1:raise RuntimeUnavailable()

def rotate_session_token(c,ex,codec,uid,device,old_sid,new_sid):
    """Same-owner refresh hook after new session INSERT, before native COMMIT."""
    for d,digest,cipher in _token_rows(c,ex,uid):
        if d!=device or not cipher:continue
        value=codec.open(uid,d,cipher)
        if value['sessionId']!=old_sid:continue
        ex('UPDATE clrs_staging.device_push_tokens SET fcm_token_ciphertext=%s,updated_at=UTC_TIMESTAMP(6) WHERE uid=%s AND device_id=%s AND fcm_token_hash=%s',
            (codec.seal(uid,d,new_sid,value['token']),uid,d,digest))
        if c.rowcount!=1:raise RuntimeUnavailable()

def revoke_owner_tokens(c,ex,codec,uid,device=None):
    """Trusted all-session logout/refresh-replay hook in native auth transaction."""
    for d,digest,cipher in _token_rows(c,ex,uid):
        if not cipher or device is not None and d!=device:continue
        sid=codec.open(uid,d,cipher)['sessionId']
        ex('UPDATE clrs_staging.device_push_tokens SET fcm_token_hash=%s,fcm_token_ciphertext=%s,updated_at=UTC_TIMESTAMP(6) WHERE uid=%s AND device_id=%s AND fcm_token_hash=%s',(tombstone(uid,d,sid),b'',uid,d,digest))
        if c.rowcount!=1:raise RuntimeUnavailable()

class RuntimePushService:
    def __init__(self,store,codec):
        self.store=store;self.codec=codec
        store.register_replay_guard(REGISTER,self._register_replay,response_guard=True)
        store.register_replay_guard(REVOKE,self._revoke_replay,response_guard=True)
    def _register_replay(self,c,ex,uid,request,response):
        if type(request) is not dict or set(request)!={'sessionId','tokenHash'} or type(request['tokenHash']) is not str or re.fullmatch(r'[a-f0-9]{64}',request['tokenHash']) is None or type(request['sessionId']) is not str or re.fullmatch(r'[A-Za-z0-9_-]{32}',request['sessionId']) is None:raise RuntimeUnavailable()
        if response in ({'error':'token_in_use'},{'error':'device_limit'}):return
        if type(response) is not dict or set(response)!={'kind','sessionId','registered'} or response['kind']!='canonical-native-push' or response['sessionId']!=request['sessionId'] or response['registered'] is not True:raise RuntimeUnavailable()
    def _revoke_replay(self,c,ex,uid,request,response):
        if type(request) is not dict or set(request)!={'sessionId'} or type(request['sessionId']) is not str or re.fullmatch(r'[A-Za-z0-9_-]{32}',request['sessionId']) is None or type(response) is not dict or set(response)!={'kind','sessionId','revoked'} or response['kind']!='canonical-native-push' or response['sessionId']!=request['sessionId'] or response['revoked'] is not True:raise RuntimeUnavailable()
    def register(self,identity,operation_id,token,*,access_token):
        digest=token_hash(token);request={'sessionId':identity.session_id,'tokenHash':digest.hex()}
        def action(c,ex,uid):
            device=_device(c,ex,uid,identity.session_id);rows=_token_rows(c,ex,uid)
            ex('SELECT uid,device_id FROM clrs_staging.device_push_tokens WHERE fcm_token_hash=%s LIMIT 2 FOR UPDATE',(digest,));owners=c.fetchall()
            if len(owners)>1:raise RuntimeUnavailable()
            if owners and tuple(owners[0])!=(uid,device):return 409,{'error':'token_in_use'},None
            before=next((r for r in rows if r[0]==device),None)
            empty=next((r for r in rows if not r[2]),None)
            if before is None and len(rows)>=MAX_DEVICES and empty is None:return 409,{'error':'device_limit'},None
            cipher=self.codec.seal(uid,device,identity.session_id,token)
            if before is None and empty is not None:
                ex('UPDATE clrs_staging.device_push_tokens SET device_id=%s,fcm_token_hash=%s,fcm_token_ciphertext=%s,updated_at=UTC_TIMESTAMP(6) WHERE uid=%s AND device_id=%s AND fcm_token_ciphertext=%s AND fcm_token_hash=%s',(device,digest,cipher,uid,empty[0],b'',empty[1]))
            elif before is None:ex('INSERT INTO clrs_staging.device_push_tokens(uid,device_id,fcm_token_hash,fcm_token_ciphertext) VALUES(%s,%s,%s,%s)',(uid,device,digest,cipher))
            else:ex('UPDATE clrs_staging.device_push_tokens SET fcm_token_hash=%s,fcm_token_ciphertext=%s,updated_at=UTC_TIMESTAMP(6) WHERE uid=%s AND device_id=%s',(digest,cipher,uid,device))
            if c.rowcount!=1:raise RuntimeUnavailable()
            if next((r for r in _token_rows(c,ex,uid) if r[0]==device),None)!=(device,digest,cipher):raise RuntimeUnavailable()
            return 200,{'kind':'canonical-native-push','sessionId':identity.session_id,'registered':True},None
        return self.store.mutate(identity,REGISTER,operation_id,request,action,access_token=access_token)
    def revoke(self,identity,operation_id,*,access_token):
        def action(c,ex,uid):
            device=_device(c,ex,uid,identity.session_id);revoke_session_token(c,ex,self.codec,uid,device,identity.session_id)
            return 200,{'kind':'canonical-native-push','sessionId':identity.session_id,'revoked':True},None
        return self.store.mutate(identity,REVOKE,operation_id,{'sessionId':identity.session_id},action,access_token=access_token)

def create_push_codec(env):
    try:return PushCodec(decode_base64(env.get('CLRS_NATIVE_PUSH_TOKEN_KEY_B64'),max_bytes=32))
    except Exception:return None

def enqueue_event(c,ex,audience,event_id,kind,payload):
    """Call only inside the original committed domain operation, never its replay."""
    if kind not in {'chat.message.created.v1','meeting.message.created.v1'}:raise RuntimeUnavailable()
    event_id=_integer(event_id)
    if not event_id:raise RuntimeUnavailable()
    outbox_id='tw-'+hashlib.sha256(canonical_json(['fcm',audience,str(event_id)])).hexdigest()
    ex('INSERT INTO clrs_staging.outbox(outbox_id,source_event_id,audience_uid,channel,event_kind,payload) VALUES(%s,%s,%s,\'fcm\',%s,%s)',
        (outbox_id,str(event_id),audience,kind,canonical_json(payload).decode()))
    if c.rowcount!=1:raise RuntimeUnavailable()

def enqueue_meeting_message(c,ex,payload):
    """Bounded same-transaction fanout; worker re-proves each current member."""
    if type(payload) is not dict or set(payload)!={'meetingId','messageId','sequence','senderUid','chatRevision','createdAt'}:raise RuntimeUnavailable()
    ex('SELECT uid FROM clrs_staging.meeting_members WHERE meeting_id=%s AND left_at IS NULL AND kicked_at IS NULL AND uid<>%s ORDER BY BINARY uid LIMIT 129 FOR SHARE',(payload['meetingId'],payload['senderUid']))
    audiences=[r[0] for r in c.fetchall()]
    if len(audiences)>128 or len(set(audiences))!=len(audiences):raise RuntimeUnavailable()
    if not audiences:return
    ex('SELECT last_id FROM clrs_staging.event_counter WHERE singleton=1 FOR UPDATE');r=c.fetchone()
    if r is None or len(r)!=1:raise RuntimeUnavailable()
    previous=_integer(r[0])
    if previous>MAX_INTEGER-len(audiences):raise RuntimeUnavailable()
    ex('UPDATE clrs_staging.event_counter SET last_id=%s WHERE singleton=1 AND last_id=%s',(previous+len(audiences),previous))
    if c.rowcount!=1:raise RuntimeUnavailable()
    kind='meeting.message.created.v1';encoded=canonical_json(payload).decode()
    rows=[(previous+n,uid,kind,encoded) for n,uid in enumerate(audiences,1)]
    ex('INSERT INTO clrs_staging.user_events(event_id,audience_uid,event_kind,payload) VALUES '+','.join(['(%s,%s,%s,%s)']*len(rows)),tuple(v for r in rows for v in r))
    if c.rowcount!=len(rows):raise RuntimeUnavailable()
    out=[]
    for event,uid,_,_ in rows:
        out.append(('tw-'+hashlib.sha256(canonical_json(['fcm',uid,str(event)])).hexdigest(),str(event),uid,kind,encoded))
    ex('INSERT INTO clrs_staging.outbox(outbox_id,source_event_id,audience_uid,channel,event_kind,payload) VALUES '+','.join(["(%s,%s,%s,'fcm',%s,%s)"]*len(out)),tuple(v for r in out for v in r))
    if c.rowcount!=len(out):raise RuntimeUnavailable()

class RuntimePushWorker:
    """No principal impersonation: trusted worker SQL borrows the same four slots."""
    def __init__(self,store,codec,provider,*,imported_authority=None,clock=time.time,monotonic=time.monotonic):
        self.store=store;self.codec=codec;self.provider=provider;self.authority=imported_authority
        self.clock=clock;self.mono=monotonic;self.closed=threading.Event();self.run_lock=threading.Lock();self.works=set();self.work_lock=threading.Lock()
    def _sql(self,action,deadline):
        store=self.store;deadline=min(deadline,self.mono()+store._seconds)
        with store._lock:
            if store._closed or self.closed.is_set() or not store._slots.acquire(False):raise RuntimeUnavailable()
            work=_Work();store._active.add(work)
        with self.work_lock:self.works.add(work)
        def worker():
            connection=None;committing=False
            try:
                connect=store._connect
                if connect is None:
                    import pymysql
                    connect=pymysql.connect
                connection=connect(**store._configuration())
                with work.lock:work.connection=connection
                if work.cancel.is_set():raise RuntimeUnavailable()
                with connection.cursor() as c:
                    count=0
                    def ex(sql,p=()):
                        nonlocal count
                        count+=1
                        if count>64 or work.cancel.is_set() or self.mono()>=deadline:raise RuntimeUnavailable()
                        if sql.lstrip().split()[0] not in {'SELECT','SHOW','SET','UPDATE'}:raise RuntimeUnavailable()
                        c.execute(sql,p)
                        if work.cancel.is_set() or self.mono()>=deadline:raise RuntimeUnavailable()
                    ex('SHOW GRANTS');store._grants(c.fetchall());ex('SELECT DATABASE(), VERSION()');r=c.fetchone()
                    if r[0]!='clrs_staging' or not r[1].startswith('8.4.'):raise RuntimeUnavailable()
                    ex("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
                    if not c.fetchone()[1]:raise RuntimeUnavailable()
                    ex("SET SESSION time_zone = '+00:00'");ex('SET SESSION innodb_lock_wait_timeout = 2');ex('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE')
                    connection.begin();value=action(c,ex,work.cancel)
                    if work.cancel.is_set() or self.mono()>=deadline:raise RuntimeUnavailable()
                    with work.lock:committing=True;work.committing=True
                    connection.commit();work.value=value
            except Exception:work.error=RuntimeCommitUnknown() if committing else RuntimeUnavailable()
            finally:
                if connection is not None:
                    if not committing:
                        try:connection.rollback()
                        except Exception:pass
                    try:connection.close()
                    except Exception:pass
                with store._lock:store._active.discard(work)
                with self.work_lock:self.works.discard(work)
                store._slots.release();work.done.set()
        try:threading.Thread(target=worker,daemon=True,name='clrs-push-transaction').start()
        except Exception:
            with store._lock:store._active.discard(work)
            with self.work_lock:self.works.discard(work)
            store._slots.release();raise RuntimeUnavailable() from None
        if not work.done.wait(max(0,deadline-self.mono())):work.abort();raise RuntimeUnavailable()
        if work.error is not None:raise work.error
        return work.value
    def _recipient(self,c,ex,uid,device,digest,cipher,payload,kind):
        value=self.codec.open(uid,device,cipher)
        if hashlib.sha256(value['token'].encode()).digest()!=digest:raise RuntimeUnavailable()
        ex('SELECT s.uid,s.device_id,s.refresh_token_hash,DATE_FORMAT(s.issued_at,\'%%Y-%%m-%%d %%H:%%i:%%s.%%f\'),DATE_FORMAT(s.expires_at,\'%%Y-%%m-%%d %%H:%%i:%%s.%%f\'),s.revoked_at,a.disabled,a.lifecycle,a.token_version FROM clrs_staging.device_sessions s JOIN clrs_staging.accounts a ON a.uid=s.uid AND CAST(a.uid AS BINARY)=CAST(s.uid AS BINARY) WHERE s.session_id=%s LIMIT 1 FOR SHARE OF s,a',(value['sessionId'],));r=c.fetchone()
        if r is None or len(r)!=9:return None
        if r[0]!=uid or r[1]!=device or r[5] is not None or r[6]!=0 or r[7]!='active' or _date(r[4])<=int(self.clock()):return None
        row={'session_id':value['sessionId'],'uid':uid,'device_id':device,'refresh_token_hash':r[2],'issued_at':r[3],'expires_at':r[4]}
        metadata=self.store.tokens._metadata(row)
        if metadata[1]!=r[8] or metadata[3]>int(self.clock())+30:return None
        prefs=preferences(c,ex,uid)
        if prefs['messages' if kind=='chat.message.created.v1' else 'meetings'] is not True:return None
        if kind=='chat.message.created.v1':
            try:pair=_pair(c,ex,uid,payload['chatId'],readonly=True)
            except _ChatFailure:return None
            if pair['peer']!=payload['senderUid'] or pair['revision']<payload['chatRevision'] or not pair['members'][uid]['notifications']:return None
            ex('SELECT sender_uid,sequence,deleted_at FROM clrs_staging.chat_messages WHERE chat_id=%s AND message_id=%s LIMIT 1 FOR SHARE',(payload['chatId'],payload['messageId']));m=c.fetchone()
            if m is None or tuple(m)!=(payload['senderUid'],payload['sequence'],None):return None
        else:
            from runtime_meeting_chat import _state,_SELECT
            from runtime_meeting_join import _JoinFailure
            try:state=_state(self.store,c,ex,uid,payload['meetingId'],datetime.fromtimestamp(self.clock(),timezone.utc),readonly=True,authority=self.authority)
            except _JoinFailure:return None
            if state[1]<payload['chatRevision']:return None
            ex(_SELECT+' WHERE mm.meeting_id=%s AND mm.message_id=%s LIMIT 1 FOR SHARE OF mm',(payload['meetingId'],payload['messageId']));rows=c.fetchall()
            from runtime_imported_meetings import proved_messages
            messages=proved_messages(c,ex,rows,payload['meetingId'],self.authority)
            if len(messages)!=1 or messages[0]['senderUid']!=payload['senderUid'] or messages[0]['sequence']!=payload['sequence']:return None
        return value['token'],prefs['sound']
    def run_once(self):
        if self.provider is None or self.closed.is_set():return {'state':'provider_unconfigured','claimed':0}
        if not self.run_lock.acquire(False):return {'state':'busy','claimed':0}
        deadline=self.mono()+8
        try:
            self.provider.prepare(deadline,self.closed)
            def claim(c,ex,cancel):
                ex("SELECT outbox_id,source_event_id,audience_uid,event_kind,payload FROM clrs_staging.outbox FORCE INDEX(outbox_ready_idx) WHERE channel='fcm' AND delivered_at IS NULL AND attempts=0 AND available_at<=UTC_TIMESTAMP(6) ORDER BY available_at,outbox_id LIMIT 1 FOR UPDATE");r=c.fetchone()
                if r is None:return None
                outbox,event,uid,kind,raw=r
                if type(event) is not str or not event.isdigit() or not 0<int(event)<=MAX_INTEGER or kind not in {'chat.message.created.v1','meeting.message.created.v1'}:raise RuntimeUnavailable()
                payload=unique_json(raw.decode() if type(raw) is bytes else raw) if type(raw) in (str,bytes) else raw
                keys={'messageId','sequence','senderUid','chatRevision','createdAt', 'chatId' if kind.startswith('chat.') else 'meetingId'}
                if type(payload) is not dict or set(payload)!=keys or type(payload['sequence']) is not int or not 1<=payload['sequence']<=MAX_INTEGER:raise RuntimeUnavailable()
                if _integer(payload['chatRevision'])<payload['sequence']:raise RuntimeUnavailable()
                for key in ('messageId','senderUid','chatId' if kind.startswith('chat.') else 'meetingId'):_identifier(payload[key])
                stamp=payload['createdAt']
                if type(stamp) is not str or re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z',stamp) is None or _date(stamp[:-1].replace('T',' '))>int(self.clock())+30:raise RuntimeUnavailable()
                ex('SELECT audience_uid,event_kind,payload FROM clrs_staging.user_events WHERE event_id=%s LIMIT 1 FOR SHARE',(int(event),));original=c.fetchone()
                if original is None or len(original)!=3 or original[0]!=uid or original[1]!=kind or canonical_json(unique_json(original[2].decode() if type(original[2]) is bytes else original[2]) if type(original[2]) in (str,bytes) else original[2])!=canonical_json(payload):raise RuntimeUnavailable()
                ex("UPDATE clrs_staging.outbox SET attempts=1,available_at='9999-12-31 23:59:59.999999',last_error_code='fcm.sending.v1' WHERE outbox_id=%s AND attempts=0 AND delivered_at IS NULL",(outbox,))
                if c.rowcount!=1:raise RuntimeUnavailable()
                ex('SELECT device_id,fcm_token_hash,fcm_token_ciphertext FROM clrs_staging.device_push_tokens WHERE uid=%s ORDER BY BINARY device_id LIMIT 5 FOR SHARE',(uid,));tokens=c.fetchall()
                if len(tokens)>MAX_DEVICES:raise RuntimeUnavailable()
                return outbox,uid,kind,payload,[tuple(t) for t in tokens if t[2]]
            original=self._sql(claim,deadline)
            if original is None:return {'state':'empty','claimed':0}
            outbox,uid,kind,payload,targets=original;confirmed=0;attempted=0;unknown=False
            for device,digest,cipher in targets:
                if self.mono()>=deadline or self.closed.is_set():unknown=True;break
                def send(c,ex,cancel):
                    ex('SELECT fcm_token_hash,fcm_token_ciphertext FROM clrs_staging.device_push_tokens WHERE uid=%s AND device_id=%s LIMIT 1 FOR SHARE',(uid,device));current=c.fetchone()
                    if current is None or tuple(current)!=(digest,cipher):return False
                    recipient=self._recipient(c,ex,uid,device,digest,cipher,payload,kind)
                    if recipient is None:return False
                    data={'kind':'native-chat' if kind.startswith('chat.') else 'native-meeting','recipientUid':uid,'messageId':payload['messageId'], 'chatId' if kind.startswith('chat.') else 'meetingId':payload.get('chatId',payload.get('meetingId'))}
                    nonlocal attempted
                    attempted+=1
                    if self.provider.send(recipient[0],data,sound=recipient[1],tag=outbox,deadline=deadline,cancel=cancel) is not True:raise RuntimeUnavailable()
                    return True
                try:confirmed+=int(self._sql(send,deadline))
                except Exception:unknown=True;break
            def finish(c,ex,cancel):
                if unknown:code='fcm.partial_unknown.v1' if confirmed else 'fcm.unknown.v1'
                elif confirmed:code='fcm.sent.v1'
                else:code='fcm.skipped.v1'
                ex('UPDATE clrs_staging.outbox SET delivered_at='+('UTC_TIMESTAMP(6)' if code=='fcm.sent.v1' else 'NULL')+',last_error_code=%s WHERE outbox_id=%s AND attempts=1 AND last_error_code=\'fcm.sending.v1\'',(code,outbox))
                if c.rowcount!=1:raise RuntimeUnavailable()
            if self.mono()<deadline:self._sql(finish,deadline)
            return {'state':'unknown' if unknown else 'sent' if confirmed else 'skipped','claimed':1,'confirmedDevices':confirmed,'attemptedDevices':attempted,'automaticRetry':False}
        finally:self.run_lock.release()
    def start(self):
        if hasattr(self,'thread') or self.provider is None:return
        def run():
            while not self.closed.is_set():
                try:self.run_once()
                except Exception:pass
                self.closed.wait(5)
        self.thread=threading.Thread(target=run,daemon=True,name='clrs-native-push');self.thread.start()
    def close(self):
        self.closed.set()
        with self.work_lock:works=list(self.works)
        for work in works:work.abort()
        if self.provider is not None:self.provider.close()
