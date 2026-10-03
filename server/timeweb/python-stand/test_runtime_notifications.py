"""Only the new native notification projection/adapter; no live SQL or cloud."""
import base64,json,unittest
from unittest.mock import patch
from runtime_social import SocialAccessDenied
from native_sessions import NativeIdentity
from runtime_mutations import RuntimeRejected,RuntimeUnavailable,RuntimeInvalidRequest
from runtime_notifications import RuntimeNotificationsService,RuntimeNotificationsHttp,NotificationUnavailable

NOW=1791028800;STAMP='2026-10-03T12:00:00.000001Z'
def event(n,sender='peer',kind='chat.message.created.v1'):
 return (n,kind,json.dumps({'chatId':'chat','messageId':'message','senderUid':sender,'sequence':1,'chatRevision':1,'createdAt':STAMP}),STAMP)
class Store:
 def __init__(self):self.events={'A':[event(4),event(3),event(2),event(1)],'B':[]};self.notices={'A':[('unknown','legacy',None,None,None,{})],'B':[]};self.revoked=False;self.after=None;self.calls=[]
 def read_authenticated(self,identity,action,*,access_token):
  if self.revoked:raise RuntimeRejected()
  c=Cursor(self);value=action(c,c.execute,identity.uid)
  if self.after:self.after()
  if self.revoked:raise RuntimeRejected()
  return value
class Cursor:
 def __init__(self,store):self.s=store;self.rows=[]
 def execute(self,sql,p=()):
  self.s.calls.append((sql,p));assert sql.startswith('SELECT');assert 'FOR SHARE' in sql
  uid=p[0];assert p[1]==uid
  source=self.s.events if 'user_events' in sql else self.s.notices
  rows=list(source.get(uid,[]))
  if 'user_events' in sql:
   if 'event_id=%s' in sql:rows=[r for r in rows if r[0]==p[2]]
   elif 'event_id<=%s' in sql:rows=[r for r in rows if r[0]<=p[2] and r[0]<p[3]]
   self.rows=sorted(rows,reverse=True)[:p[-1]] if 'LIMIT %s' in sql else sorted(rows,reverse=True)[:1]
  else:
   if 'notification_id=%s' in sql:rows=[r for r in rows if r[0]==p[2]]
   self.rows=rows[:p[-1]] if 'LIMIT %s' in sql else rows[:1]
 def fetchall(self):return self.rows
class Native:
 def authorize(self,token,peer=''):return NativeIdentity('A',True,'A'*32,NOW,NOW+900)
class Checks(unittest.TestCase):
 def setUp(self):
  self.store=Store();self.time=NOW;self.visible=True
  self.s=RuntimeNotificationsService(self.store,b'k'*32,clock=lambda:self.time,target=lambda *args:self.visible)
  self.a=NativeIdentity('A',True,'A'*32,NOW,NOW+900);self.b=NativeIdentity('B',True,'B'*32,NOW,NOW+900)
 def test_original_cursor_owner_expiry_sparse_and_partial(self):
  p=self.s.page(self.a,access_token='fixture',limit=3);self.assertEqual([x['id'] for x in p['items']],['e:4','e:3','e:2']);self.assertIsNone(p['items'][0]['read'])
  original=self.s.codec.open('cursor',p['nextCursor']);self.time+=290
  second=self.s.page(self.a,access_token='fixture',limit=3,cursor=p['nextCursor']);self.assertEqual([x['id'] for x in second['items']],['e:1']);self.assertEqual(self.s.codec.open('cursor',second['nextCursor'])['exp'],original['exp'])
  third=self.s.page(self.a,access_token='fixture',limit=3,cursor=second['nextCursor']);self.assertEqual(third['items'][0],{'id':'n:unknown','type':'legacy','targetKind':None,'targetId':None,'createdAt':None,'read':None});self.assertIsNone(third['nextCursor'])
  for who,limit in [(self.b,3),(self.a,2)]:
   with self.assertRaises(RuntimeInvalidRequest):self.s.page(who,access_token='fixture',limit=limit,cursor=p['nextCursor'])
  self.time+=11
  with self.assertRaises(RuntimeInvalidRequest):self.s.page(self.a,access_token='fixture',limit=3,cursor=p['nextCursor'])
  self.store.events['A']=[event(4,'A'),event(3,'A'),event(2,'A'),event(1)]
  self.time=NOW;sparse=self.s.page(self.a,access_token='fixture',limit=3);self.assertEqual(sparse['items'],[]);self.assertIsNotNone(sparse['nextCursor'])
 def test_current_target_source_types_and_actor_postcheck(self):
  self.assertEqual(self.s.one(self.a,'e:1',access_token='fixture')['targetId'],'chat')
  meeting=(7,'meeting.message.created.v1',json.dumps({'meetingId':'meeting','messageId':'retained','senderUid':'peer','sequence':154,'chatRevision':2,'createdAt':STAMP}),STAMP)
  self.assertEqual(self.s._row(None,None,'A','event',meeting)['targetKind'],'meeting')
  null_payload=json.loads(meeting[2]);null_payload['createdAt']=None
  for invalid in [(7,meeting[1],json.dumps(null_payload),STAMP),(7,meeting[1],meeting[2],None)]:
   with self.assertRaises(RuntimeUnavailable):self.s._row(None,None,'A','event',invalid)
  with patch('runtime_social._post',side_effect=SocialAccessDenied()):
   self.assertFalse(self.s._target(None,None,'A','post','deleted'))
  self.visible=False
  with self.assertRaises(NotificationUnavailable):self.s.one(self.a,'e:1',access_token='fixture')
  self.visible=True;self.store.after=lambda:setattr(self.store,'revoked',True)
  with self.assertRaises(RuntimeRejected):self.s.one(self.a,'e:1',access_token='fixture')
  self.store.after=None;self.store.revoked=False;self.store.events['A']=[(1,'chat.message.created.v1','{}',STAMP)]
  with self.assertRaises(RuntimeUnavailable):self.s.one(self.a,'e:1',access_token='fixture')
  self.store.events['A']=[]
  self.store.notices['A']=[('notice','legacy',None,None,None,{'fields':{'read':{'booleanValue':False}}})]
  first=self.s.page(self.a,access_token='fixture')
  self.assertIs(self.s.page(self.a,access_token='fixture',cursor=first['nextCursor'])['items'][0]['read'],False)
 def test_adapter_no_native_fallback_and_strict_bounds(self):
  env={'CLRS_RUNTIME_WRITES_ENABLED':'1','CLRS_RUNTIME_MEMBERSHIP_AUTHORITY':'canonical-current-v1','CLRS_LEGACY_READ_CURSOR_KEY_B64':base64.b64encode(b'k'*32).decode()}
  h=RuntimeNotificationsHttp(env,self.store);h.service=self.s
  e={'PATH_INFO':'/v1/runtime/me/notifications','REQUEST_METHOD':'GET','HTTP_AUTHORIZATION':'Bearer na1.'+'A'*32+'.secret'}
  self.assertEqual(h.dispatch(e,native_service=Native(),native_configured=True).status,'200 OK')
  for query in ['limit=31','limit=01','limit=2&limit=2','cursor=%zz','cursor=é']:
   self.assertEqual(h.dispatch({**e,'QUERY_STRING':query},native_service=Native(),native_configured=True).status,'400 Bad Request')
  self.assertEqual(h.dispatch({**e,'HTTP_AUTHORIZATION':'Bearer firebase-fixture'},native_service=Native(),native_configured=True).status,'401 Unauthorized')
  self.assertEqual(h.dispatch(e,native_service=Native(),native_configured=False).status,'503 Service Unavailable')
  self.visible=False;reply=h.dispatch({**e,'PATH_INFO':e['PATH_INFO']+'/e:1'},native_service=Native(),native_configured=True);self.assertEqual(reply.status,'404 Not Found');self.assertFalse(reply.authenticate)
if __name__=='__main__':unittest.main()
