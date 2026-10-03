"""One connected native push fixture plus fixed FCM port; no TCP/real credentials."""
import base64,io,json,unittest
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from native_sessions import NativeIdentity
from runtime_mutations import RuntimeMutationStore,RuntimeCommitUnknown,request_digest
from runtime_chat import RuntimeChatService
from runtime_push import RuntimePushService,PushCodec,RuntimePushWorker,REGISTER,REVOKE,token_hash,rotate_session_token,revoke_session_token
from runtime_push_http import RuntimePushHttp
from native_fcm import NativeFCM,create_native_fcm
from test_runtime_mutations import FakeDatabase,FakeConnection,FakeCursor,ENV,NOW,STAMP

A='10000000-0000-4000-8000-000000000001';B='10000000-0000-4000-8000-000000000002';C='10000000-0000-4000-8000-000000000003'
TOKEN='synthetic-fcm-token-1234567890'
class PushConnection(FakeConnection):
 def cursor(self):return PushCursor(self)
class PushDB(FakeDatabase):
 def __init__(self):
  super().__init__();self.state.update(tokens={},push_outbox={},prefs={})
 def connect(self,**kwargs):
  c=PushConnection(self);self.connections.append(c);return c
 def peer(self,device='peer-device'):
  s,t=self.tokens.mint('peer',device,0,NOW);self.state['sessions'][s['session_id']]=s
  return NativeIdentity('peer',True,s['session_id'],NOW,NOW+900),t['accessToken']
class PushCursor(FakeCursor):
 def execute(self,statement,params=()):
  sql=' '.join(statement.split());s=self.c.state;self.rows=[];self.rowcount=0
  if 'clrs_staging.device_push_tokens' in sql:
   t=s['tokens']
   if sql.startswith('SELECT uid,device_id'):
    self.rows=[(u,d) for (u,d),(h,_) in t.items() if h==params[0]]
   elif sql.startswith('SELECT device_id'):
    self.rows=[(d,*v) for (u,d),v in sorted(t.items()) if u==params[0]][:5]
   elif sql.startswith('SELECT fcm_token_hash'):
    v=t.get(tuple(params));self.rows=[tuple(v)] if v else []
   elif sql.startswith('INSERT'):
    u,d,h,cipher=params;assert (u,d) not in t and all(v[0]!=h for v in t.values());t[(u,d)]=[h,cipher];self.rowcount=1
   elif sql.startswith('UPDATE'):
    if 'SET device_id=' in sql:
     new,h,cipher,u,d,empty,old=params
     if t.get((u,d))==[old,empty]:del t[(u,d)];t[(u,new)]=[h,cipher];self.rowcount=1
    elif 'SET fcm_token_ciphertext=' in sql:
     cipher,u,d,h=params
     if t.get((u,d),[None])[0]==h:t[(u,d)][1]=cipher;self.rowcount=1
    else:
     h,cipher,u,d,*before=params
     if (u,d) in t and (not before or t[(u,d)][0]==before[0]):t[(u,d)]=[h,cipher];self.rowcount=1
  elif sql.startswith('SELECT uid,device_id FROM clrs_staging.device_sessions'):
   v=s['sessions'].get(params[0]);self.rows=[(v['uid'],v['device_id'])] if v else []
  elif sql.startswith('SELECT s.uid,s.device_id'):
   v=s['sessions'].get(params[0]);a=s['accounts'].get(v['uid']) if v else None
   self.rows=[(v['uid'],v['device_id'],v['refresh_token_hash'],v['issued_at'],v['expires_at'],v['revoked_at'],*a[:3])] if a else []
  elif sql.startswith('SELECT messages,meetings,sound'):
   v=s['prefs'].get(params[0]);self.rows=[(*v,1,STAMP)] if v else []
  elif sql.startswith('SELECT legacy_raw FROM clrs_staging.profiles'):pass
  elif sql.startswith('SELECT sender_uid,sequence,deleted_at'):
   m=s['messages'].get(tuple(params));self.rows=[(m['sender'],m['sequence'],m['deleted'])] if m else []
  elif sql.startswith('SELECT outbox_id,source_event_id'):
   self.rows=[(k,*v[:2],'chat.message.created.v1',json.dumps(v[2])) for k,v in s['outbox'].items() if s['push_outbox'].get(k,{}).get('attempts',0)==0][:1]
  elif sql.startswith('SELECT audience_uid,event_kind,payload'):
   v=s['events'].get(params[0]);self.rows=[v] if v else []
  elif sql.startswith('UPDATE clrs_staging.outbox SET attempts'):
   v=s['push_outbox'].setdefault(params[0],{})
   if not v.get('attempts'):v.update(attempts=1,code='fcm.sending.v1',delivered=False);self.rowcount=1
  elif sql.startswith('UPDATE clrs_staging.outbox SET delivered_at'):
   code,k=params;v=s['push_outbox'][k]
   if v['code']=='fcm.sending.v1':v.update(code=code,delivered=code=='fcm.sent.v1');self.rowcount=1
  else:return super().execute(statement,params)
  self.c.db.calls.append((sql,params));return self.rowcount
class Provider:
 def __init__(self,fail=False):self.calls=[];self.fail=fail
 def prepare(self,*args):pass
 def send(self,token,data,**kwargs):
  self.calls.append((token,data,kwargs['sound']))
  if self.fail:raise OSError('synthetic unknown')
  return True
 def close(self):pass
class Push(unittest.TestCase):
 def test_connected_original_session_ownership_preferences_and_unknown_delivery(self):
  db=PushDB();store=RuntimeMutationStore(ENV,db.tokens,connect=db.connect,clock=lambda:NOW);codec=PushCodec(bytes(range(32,64)));service=RuntimePushService(store,codec)
  db.commit_unknown_once=True
  with self.assertRaises(RuntimeCommitUnknown):service.register(db.identity,A,TOKEN,access_token=db.access)
  receipt=store.lookup(db.identity,REGISTER,A,access_token=db.access,request_hash=request_digest({'sessionId':db.identity.session_id,'tokenHash':token_hash(TOKEN).hex()}))
  self.assertEqual(receipt.payload['result']['sessionId'],db.identity.session_id)
  self.assertEqual(len(db.state['tokens']),1)
  self.assertNotIn(TOKEN,json.dumps([json.loads(r[3]) for r in db.state['receipts'].values()]))
  self.assertNotIn(TOKEN.encode(),db.state['tokens'][('actor','device')][1])
  peer,access=db.peer();blocked=service.register(peer,B,TOKEN,access_token=access)
  self.assertEqual(blocked.payload['result'],{'error':'token_in_use'})
  service.revoke(db.identity,C,access_token=db.access)
  self.assertEqual(db.state['tokens'][('actor','device')][1],b'')
  service.register(peer,C,TOKEN,access_token=access)
  # Atomic same-owner refresh rotation preserves only new session binding.
  old=db.state['sessions'][peer.session_id];new,tokens=db.tokens.mint('peer','peer-device',0,NOW)
  db.state['sessions'][new['session_id']]=new;db.state['sessions'][peer.session_id]['revoked_at']=STAMP
  connection=db.connect();connection.begin()
  with connection.cursor() as c:rotate_session_token(c,c.execute,codec,'peer','peer-device',peer.session_id,new['session_id'])
  connection.commit();connection.close()
  self.assertEqual(codec.open('peer','peer-device',db.state['tokens'][('peer','peer-device')][1])['sessionId'],new['session_id'])
  connection=db.connect();connection.begin()
  with connection.cursor() as c:revoke_session_token(c,c.execute,codec,'peer','peer-device',peer.session_id)
  connection.commit();connection.close()
  self.assertTrue(db.state['tokens'][('peer','peer-device')][1])
  fresh=NativeIdentity('peer',True,new['session_id'],NOW,NOW+900)
  historical=store.lookup(fresh,REGISTER,C,access_token=tokens['accessToken'],request_hash=request_digest({'sessionId':peer.session_id,'tokenHash':token_hash(TOKEN).hex()}))
  self.assertEqual(historical.payload['result']['sessionId'],peer.session_id)
  chat=RuntimeChatService(store);chat.send_text(db.identity,'chat',B,'original text',access_token=db.access)
  db.state['prefs']['peer']=(0,1,1);provider=Provider();worker=RuntimePushWorker(store,codec,provider,clock=lambda:NOW)
  self.assertEqual(worker.run_once()['state'],'skipped');self.assertEqual(provider.calls,[])
  db.state['prefs']['peer']=(1,1,0);chat.send_text(db.identity,'chat','10000000-0000-4000-8000-000000000004','second',access_token=db.access)
  self.assertEqual(worker.run_once()['state'],'sent');self.assertFalse(provider.calls[0][2])
  chat.send_text(db.identity,'chat','10000000-0000-4000-8000-000000000005','unknown',access_token=db.access)
  failing=Provider(True);unknown=RuntimePushWorker(store,codec,failing,clock=lambda:NOW)
  self.assertEqual(unknown.run_once()['state'],'unknown');self.assertEqual(len(failing.calls),1)
  restarted=RuntimePushWorker(store,codec,failing,clock=lambda:NOW)
  self.assertEqual(restarted.run_once()['state'],'empty');self.assertEqual(len(failing.calls),1)
  chat.send_text(db.identity,'chat','10000000-0000-4000-8000-000000000007','revoked recipient',access_token=db.access)
  db.state['sessions'][new['session_id']]['revoked_at']=STAMP
  self.assertEqual(worker.run_once()['state'],'skipped');self.assertEqual(len(provider.calls),1)
  # Actual source event is preserved; no token/raw text enters the provider data.
  self.assertNotIn('original text',json.dumps(provider.calls[0][1]));self.assertEqual(db.state['legacy'],{'retained':{'typed':['unchanged']}})
  http=RuntimePushHttp(ENV,service=service)
  class Native:
   def authorize(self,*args,**kwargs):return db.identity
  body=json.dumps({'operationId':A,'token':TOKEN,'sessionId':'forged'}).encode()
  env={'PATH_INFO':'/v1/runtime/me/push-token/register','REQUEST_METHOD':'POST','CONTENT_LENGTH':str(len(body)),'CONTENT_TYPE':'application/json','wsgi.input':io.BytesIO(body),'HTTP_AUTHORIZATION':'Bearer '+db.access}
  self.assertEqual(http.handle(env,native_service=Native(),native_configured=True).status,'400 Bad Request')
  db.state['sessions'][db.identity.session_id]['revoked_at']=STAMP
  with self.assertRaises(Exception):service.register(db.identity,'10000000-0000-4000-8000-000000000006','another-valid-synthetic-token',access_token=db.access)
  worker.close();unknown.close();restarted.close();store.close()
 def test_fixed_fcm_service_account_port_no_retry_or_operator_credential(self):
  self.assertIsNone(create_native_fcm({}));self.assertIsNone(create_native_fcm({'CLRS_NATIVE_FCM_SERVICE_ACCOUNT_B64':base64.b64encode(b'{"type":"authorized_user"}').decode()}))
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048);credential={'type':'service_account','project_id':'chatapp-4e347','client_email':'synthetic@chatapp-4e347.iam.gserviceaccount.com','token_uri':'https://oauth2.googleapis.com/token','private_key':key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()};calls=[]
  def post(host,path,body,headers,*args):
   calls.append((host,path,body,headers))
   return {'access_token':'synthetic-oauth','token_type':'Bearer','expires_in':3600} if host=='oauth2.googleapis.com' else {'name':'projects/chatapp-4e347/messages/0:synthetic'}
  p=NativeFCM(credential,post=post,clock=lambda:NOW);import threading,time
  p.prepare(time.monotonic()+8,threading.Event());self.assertTrue(p.send(TOKEN,{'recipientUid':'peer','kind':'native-chat'},sound=False,tag='tw-fixture',deadline=time.monotonic()+8,cancel=threading.Event()))
  self.assertEqual([x[0] for x in calls],['oauth2.googleapis.com','fcm.googleapis.com']);self.assertEqual(calls[1][3]['Authorization'],'Bearer synthetic-oauth');self.assertNotIn('firebase',calls[1][3]['Authorization'])
  p.close()
if __name__=='__main__':unittest.main()
