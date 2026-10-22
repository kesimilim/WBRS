"""Native friends/guest isolation and retry scenarios; no customer mutations."""
import base64
import json
import unittest
from native_sessions import NativeIdentity
from runtime_contacts import RuntimeContactsService, ContactUnavailable, OPERATION
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeCommitUnknown, request_digest
from runtime_http import RuntimeMutationHttp
from test_runtime_http import env
from test_runtime_mutations import FakeConnection, FakeCursor, store_for, NOW, STAMP, ENV
from test_runtime_people import PeopleDatabase, ROW_FIELDS, Native, source
from contacts_migration import guest_row
from legacy_conversation_payload import payload_digest
UUID = lambda n: f'12345678-1234-4234-8234-{n:012d}'

class ContactsCursor(FakeCursor):
    def execute(self, statement, params=()):
        sql=' '.join(statement.split()); state=self.c.state
        if sql.startswith('SELECT p.uid, a.disabled'):
            assert 'p.uid IN (' in sql and sql.endswith('FOR SHARE OF p,a') and len(params)<=30
            self.c.db.calls.append((sql,params)); self.rows=[]
            for uid in params:
                p=state['profiles'].get(uid); a=state['accounts'].get(uid)
                if p and a and a[:2]==[0,'active']:
                    data={**p,'disabled':a[0],'lifecycle':a[1],'valid':1}
                    self.rows.append(tuple(data[f] for f in ROW_FIELDS))
            self.rowcount=len(self.rows); return self.rowcount
        if 'clrs_staging.contact_relationships' not in sql and 'clrs_staging.profile_visits' not in sql:
            return super().execute(statement,params)
        assert self.c.held
        self.c.db.calls.append((sql,params)); self.rows=[]; self.rowcount=0
        pairs=state['relations']; visits=state['visits']
        if sql.startswith('SELECT state,requester_uid,revision'):
            row=pairs.get(tuple(params));self.rows=[] if row is None else [tuple(row[:3])]
        elif sql.startswith('INSERT INTO clrs_staging.contact_relationships'):
            assert not self.c.readonly
            if tuple(params) not in pairs:
                pairs[tuple(params)]=['none',None,1,STAMP];self.rowcount=1
        elif sql.startswith('UPDATE clrs_staging.contact_relationships'):
            assert not self.c.readonly
            pairs[tuple(params[-2:])]=[*params[:3],STAMP];self.rowcount=1
        elif sql.startswith('INSERT INTO clrs_staging.profile_visits'):
            assert not self.c.readonly
            visits[tuple(params)]=STAMP;self.rowcount=1
        elif sql.startswith('SELECT peer,DATE_FORMAT'):
            owner=params[0]; rows=[]
            if 'profile_visits' in sql:
                rows=[(peer,stamp,None,None,0) for (uid,peer),stamp in visits.items() if uid==owner]
            else:
                for (lo,hi), row in pairs.items():
                    if owner not in (lo,hi) or row[0]!=params[1]:continue
                    if 'requester_uid<>%s' in sql and row[1]==owner:continue
                    if 'requester_uid=%s' in sql and row[1]!=owner:continue
                    rows.append((hi if lo==owner else lo,row[3],*row[:3]))
            if 'WHERE stamp IS NULL' in sql:
                rows=[r for r in rows if r[1] is None and r[0]>params[-2]]
            elif 'WHERE (stamp<' in sql:
                stamp=params[-4].replace(' ','T')+'Z'; peer=params[-2]
                rows=[r for r in rows if r[1] is None or r[1]<stamp or r[1]==stamp and r[0]>peer]
            rows.sort(key=lambda r:r[0]);rows.sort(key=lambda r:r[1] or '',reverse=True)
            self.rows=rows[:params[-1]]
        else: raise AssertionError('Unexpected contacts SQL')
        return self.rowcount or len(self.rows)

class ContactsConnection(FakeConnection):
    def cursor(self):return ContactsCursor(self)

class ContactsDatabase(PeopleDatabase):
    def __init__(self):
        super().__init__();self.state.update(relations={},visits={})
    def connect(self,**config):
        c=ContactsConnection(self);self.connections.append(c);return c
    def login(self,uid):
        revision=self.state['accounts'][uid][2]
        session,tokens=self.tokens.mint(uid,'device',revision,NOW)
        self.state['sessions'][session['session_id']]=session
        return NativeIdentity(uid,True,session['session_id'],NOW,NOW+900),tokens['accessToken']

class ContactsTests(unittest.TestCase):
    def setUp(self):
        self.db=ContactsDatabase();self.store=store_for(self.db);self.addCleanup(self.store.close)
        self.svc=RuntimeContactsService(self.store,bytes(range(32)),clock=lambda:NOW)
        self.a=(self.db.identity,self.db.access);self.b=self.db.login('peer');self.n=0
    def action(self,actor,kind,target,rev,ident=None):
        self.n+=1
        return self.svc.perform(actor[0],ident or UUID(self.n),
            {'kind':kind,'targetUid':target,'expectedRevision':rev},access_token=actor[1])
    def page(self,actor,kind,**kw):
        return self.svc.list(actor[0],kind,access_token=actor[1],**kw)
    def test_request_accept_remove_and_stale_request_cannot_resurrect(self):
        self.assertEqual(self.action(self.a,'send','peer',0).payload['result']['status'],'outgoing')
        self.assertEqual([p['uid'] for p in self.page(self.b,'incoming')['items']],['actor'])
        self.assertEqual(self.action(self.a,'accept','peer',1).status,409)
        self.assertEqual(self.action(self.b,'accept','actor',1).payload['entityRevision'],2)
        self.assertEqual(len(self.page(self.a,'friends')['items']),1)
        self.assertEqual(self.action(self.a,'remove','peer',2).status,200)
        self.assertEqual(self.action(self.b,'send','actor',0).status,409)
        self.assertFalse(self.page(self.a,'friends')['items'])
        self.assertEqual(self.action(self.b,'send','actor',3).status,200)
    def test_lost_ack_reconciles_original_without_second_state_change(self):
        self.db.commit_unknown_once=True
        value={'kind':'send','targetUid':'peer','expectedRevision':0}
        with self.assertRaises(RuntimeCommitUnknown):self.action(self.a,'send','peer',0,UUID(99))
        result=self.store.lookup(self.a[0],OPERATION,UUID(99),access_token=self.a[1],request_hash=request_digest(value))
        self.assertTrue(result.payload['replayed']);self.assertEqual(result.payload['entityRevision'],1)
        other=self.store.lookup(self.b[0],OPERATION,UUID(99),access_token=self.b[1],request_hash=request_digest(value))
        self.assertEqual(other.payload['state'],'not_found')
        self.action(self.a,'send','peer',0,UUID(99))
        self.assertEqual(self.db.state['relations'][('actor','peer')][2],1)
    def test_invisible_visitors_are_not_recorded_and_hidden_guests_not_disclosed(self):
        self.action(self.a,'visit','peer',0)
        self.assertEqual([p['uid'] for p in self.page(self.b,'guests')['items']],['actor'])
        self.db.state['profiles']['actor']['legacy_raw']=source('actor',isUnVisible={'booleanValue':True})
        self.assertFalse(self.page(self.b,'guests')['items'])
        self.db.state['visits'].clear()
        self.assertFalse(self.action(self.a,'visit','peer',0).payload['result']['recorded'])
        self.assertFalse(self.db.state['visits'])
    def test_guest_cursor_pagination_is_bound_to_owner_and_kind(self):
        for i in range(5):
            uid=f'p{i}';self.db.add(uid);self.db.state['visits'][('actor',uid)]=STAMP
        first=self.page(self.a,'guests',limit=2); second=self.page(self.a,'guests',limit=2,cursor=first['nextCursor'])
        self.assertEqual([x['uid'] for x in first['items']+second['items']],['p0','p1','p2','p3'])
        for actor,kind in ((self.b,'guests'),(self.a,'friends')):
            with self.assertRaises(RuntimeInvalidRequest):self.page(actor,kind,limit=2,cursor=first['nextCursor'])
        self.assertNotIn('email',json.dumps(first));self.assertNotIn('legacy',json.dumps(first))
    def test_account_revocation_and_target_removal_gate_current_reads(self):
        self.action(self.a,'send','peer',0)
        self.db.state['accounts']['peer'][0]=1
        self.assertFalse(self.page(self.a,'outgoing')['items'])
        self.assertEqual(self.action(self.a,'cancel','peer',1).status,404)
        self.db.state['accounts']['actor'][0]=1
        with self.assertRaises(RuntimeRejected):self.page(self.a,'friends')
    def test_mounted_http_rejects_owner_injection_and_foreign_auth(self):
        conf={**ENV,'CLRS_LEGACY_READ_CURSOR_KEY_B64':base64.b64encode(bytes(range(32))).decode()}
        http=RuntimeMutationHttp(conf,service_factory=lambda _: (self.store,None,None))
        http._contacts.service=self.svc
        def get(**changes):
            return http.dispatch(env('/v1/runtime/contacts',REQUEST_METHOD='GET',HTTP_AUTHORIZATION='Bearer '+self.a[1],**changes),
                native_service=Native(self.a[0]),native_configured=True)
        self.assertEqual(get().status,'200 OK')
        self.assertEqual(get(QUERY_STRING='kind=guests&owner=peer').status,'400 Bad Request')
        self.assertEqual(get(CONTENT_LENGTH='1').status,'400 Bad Request')
    def test_migration_verifies_source_hash_uid_path_and_nanosecond_timestamp(self):
        doc={'fields':{'uid':{'stringValue':'peer'},'lastVisitTs':{'timestampValue':'2026-10-01T12:00:00.123456789Z'}},
            'createTime':'2026-10-01T12:00:00Z','updateTime':'2026-10-01T12:00:00Z'}
        digest=bytes.fromhex(payload_digest(doc));row=guest_row('users/actor/visiters/peer',doc,digest)
        self.assertEqual(row[2].microsecond,123456)
        for path,d in [('users/actor/visiters/wrong',digest),('users/actor/friends/peer',digest),('users/actor/visiters/peer',bytes(32))]:
            with self.assertRaises(ValueError):guest_row(path,doc,d)

if __name__=='__main__':unittest.main()
