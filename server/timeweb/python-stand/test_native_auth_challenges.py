"""Focused transaction doubles only; no DB connection, mail, cloud or old suite."""
import copy
import json
import unittest

from native_password_credentials import AuthChallengeCodec
from native_auth_challenges import (NativeAuthChallengeStore, ChallengeUnavailable,
    ACCOUNT_QUERY, CHALLENGE_QUERY, DB_NOW_QUERY, PENDING_CREDENTIAL_QUERY,
    ConsumedChallengeCapability, validate_consumed_challenge_capability, _timestamp)

UID='Case-Ä-synthetic'; EMAIL='public@example.invalid'; CODE='012345'; NOW=1700000000
RESET='password-reset.v1'; REGISTER='register-email.v1'
ENV={name:'1' for name in ['CLRS_NATIVE_CHALLENGES_ENABLED','CLRS_NATIVE_AUTH_ENABLED',
                          'CLRS_NATIVE_AUTH_WRITES_ENABLED','CLRS_NATIVE_PASSWORD_ENABLED']}


def identifier(index):
    return '00000000-0000-4000-8000-'+str(index).zfill(12)


class FakeDatabase:
    def __init__(self):
        self.now=NOW; self.calls=[]; self.corrupt_readback=False
        self.state={'accounts':{UID:(UID,EMAIL,0,'active',0,1,_timestamp(NOW-100))},
                    'challenges':{}, 'credential_counts':{UID:(0,0,0,0)}}

    def transaction(self, action):
        # Only the trusted outer caller publishes state or rolls it back.
        working=copy.deepcopy(self.state); cursor=FakeCursor(self,working); execute=cursor.execute
        result=action(cursor,execute)
        self.state=working
        return result


class FakeCursor:
    def __init__(self,db,working):
        self.db=db; self.working=working; self.result=None; self.rowcount=0; self.wrote=False
    def fetchone(self):
        return self.result
    def _challenge_row(self,record):
        if record is None:
            return None
        row=(record['uid'],record['purpose'],record['challenge_id'],record['email_identity'],record['code_hmac'],
            record['version'],json.dumps(record['history']),_timestamp(record['issued']),_timestamp(record['expires']),
            record['attempts'],None if record['consumed'] is None else _timestamp(record['consumed']),
            record['marker'],record['pending_created'])
        return row[:-4]+(5,)+row[-3:] if self.wrote and self.db.corrupt_readback else row
    def execute(self,sql,params=()):
        self.db.calls.append((sql,params)); self.result=None; self.rowcount=0
        if sql==ACCOUNT_QUERY:
            self.result=self.working['accounts'].get(params[0])
        elif sql==CHALLENGE_QUERY:
            self.result=self._challenge_row(self.working['challenges'].get(tuple(params)))
        elif sql==DB_NOW_QUERY:
            self.result=(self.db.now,)
        elif sql==PENDING_CREDENTIAL_QUERY:
            self.result=self.working['credential_counts'].get(params[0],(0,0,0,0))
        elif sql.startswith('INSERT INTO clrs_staging.native_auth_challenges'):
            uid,purpose,challenge_id,email_identity,digest,version,history,issued,expires,marker,created=params
            assert (uid,purpose) not in self.working['challenges']
            from native_auth_challenges import _date
            self.working['challenges'][(uid,purpose)]={'uid':uid,'purpose':purpose,'challenge_id':challenge_id,
                'email_identity':email_identity,'code_hmac':digest,'version':version,'history':json.loads(history),
                'issued':_date(issued),'expires':_date(expires),'attempts':0,'consumed':None,
                'marker':marker,'pending_created':created}
            self.rowcount=1; self.wrote=True
        elif sql.startswith('UPDATE clrs_staging.native_auth_challenges SET challenge_id='):
            challenge_id,email_identity,digest,version,history,issued,expires,uid,purpose=params
            from native_auth_challenges import _date
            self.working['challenges'][(uid,purpose)].update(challenge_id=challenge_id,email_identity=email_identity,
                code_hmac=digest,version=version,history=json.loads(history),issued=_date(issued),expires=_date(expires),
                attempts=0,consumed=None)
            self.rowcount=1; self.wrote=True
        elif sql.startswith('UPDATE clrs_staging.native_auth_challenges SET attempts='):
            attempts,uid,purpose,challenge_id,previous=params
            record=self.working['challenges'][(uid,purpose)]
            assert record['challenge_id']==challenge_id and record['attempts']==previous and record['consumed'] is None
            record['attempts']=attempts; self.rowcount=1; self.wrote=True
        elif sql.startswith('UPDATE clrs_staging.native_auth_challenges SET consumed_at='):
            consumed,uid,purpose,challenge_id,version,attempts=params
            from native_auth_challenges import _date
            record=self.working['challenges'][(uid,purpose)]
            assert record['challenge_id']==challenge_id and record['version']==version and record['attempts']==attempts
            assert record['consumed'] is None
            record['consumed']=_date(consumed); self.rowcount=1; self.wrote=True
        else:
            raise AssertionError('Unexpected SQL; connections/transaction control forbidden in leaf')


class ChallengeStoreTests(unittest.TestCase):
    def setUp(self):
        self.codec=AuthChallengeCodec(bytes([9])*32)
        self.store=NativeAuthChallengeStore(ENV,self.codec); self.db=FakeDatabase()
    def issue(self,index=1,purpose=RESET,store=None,**kwargs):
        store=store or self.store
        return self.db.transaction(lambda c,e:store.issue(c,e,uid=UID,email=EMAIL,purpose=purpose,
            code=CODE,challenge_id=identifier(index),**kwargs))
    def check(self,index=1,code=CODE,purpose=RESET):
        return self.db.transaction(lambda c,e:self.store.check(c,e,uid=UID,email=EMAIL,purpose=purpose,
            code=code,challenge_id=identifier(index)))
    def seed_pending(self):
        account=(UID,EMAIL,1,'active',0,0,_timestamp(NOW-100))
        self.db.state['accounts'][UID]=account
        self.db.state['challenges'][(UID,REGISTER)]={'uid':UID,'purpose':REGISTER,'challenge_id':identifier(1),
            'email_identity':self.codec.email_identity(EMAIL),'code_hmac':self.codec.digest(uid=UID,email=EMAIL,
                purpose=REGISTER,challenge_id=identifier(1),account_token_version=0,issued_at=NOW,expires_at=NOW+600,code=CODE),
            'version':0,'history':[NOW],'issued':NOW,'expires':NOW+600,'attempts':0,'consumed':None,
            'marker':bytes([7])*32,'pending_created':account[6]}

    def test_default_off_missing_write_gate_and_no_plaintext_sql(self):
        self.assertIsNone(NativeAuthChallengeStore.from_env({}))
        self.assertIsNone(NativeAuthChallengeStore.from_env({'CLRS_NATIVE_CHALLENGES_ENABLED':'0'}))
        with self.assertRaises(ChallengeUnavailable):
            NativeAuthChallengeStore.from_env({'CLRS_NATIVE_CHALLENGES_ENABLED':'true'})
        for name in ENV:
            store=NativeAuthChallengeStore({**ENV,name:'0'},self.codec)
            with self.assertRaises(ChallengeUnavailable):
                self.issue(store=store)
        self.assertEqual(self.db.calls,[])
        self.assertEqual(self.issue().state,'issued')
        params=repr([params for _,params in self.db.calls])
        self.assertNotIn(EMAIL,params); self.assertNotIn(CODE,params)
        self.assertTrue(all(not sql.startswith(('COMMIT','ROLLBACK','BEGIN','CREATE','DELETE')) for sql,_ in self.db.calls))

    def test_new_ids_restarts_tombstones_preserve_rolling_rate(self):
        for index in range(1,6):
            self.db.now=NOW+(index-1)*60
            self.assertEqual(self.issue(index).state,'issued')
        self.db.now=NOW+300
        self.assertEqual(self.issue(6).state,'rate_limited')
        self.store=NativeAuthChallengeStore(ENV,self.codec)
        self.assertEqual(self.issue(7).state,'rate_limited')
        ticket=self.check(5).ticket
        self.assertEqual(self.db.transaction(lambda c,e:self.store.consume(c,e,ticket=ticket,code=CODE)).state,'consumed')
        self.assertEqual(len(self.db.state['challenges'][(UID,RESET)]['history']),5)
        self.db.now=NOW+3599; self.assertEqual(self.issue(8).state,'rate_limited')
        self.db.now=NOW+3600; self.assertEqual(self.issue(9).state,'issued')
        record=self.db.state['challenges'][(UID,RESET)]
        self.assertEqual(record['history'],[NOW+60,NOW+120,NOW+180,NOW+240,NOW+3600])
        self.assertEqual(self.check(5).state,'declined')

    def test_failed_attempts_declared_committed_max_five_not_rolled_back(self):
        self.issue()
        for expected in range(1,6):
            result=self.check(code='999999')
            self.assertEqual((result.state,result.attempts),('declined',expected))
            self.assertEqual(self.db.state['challenges'][(UID,RESET)]['attempts'],expected)
        self.assertEqual(self.check().state,'declined')
        self.assertEqual(self.db.state['challenges'][(UID,RESET)]['attempts'],5)

    def test_expiry_current_email_version_lifecycle_and_stale_ticket(self):
        self.issue(); original=copy.deepcopy(self.db.state); ticket=self.check().ticket
        for index,value in [(1,'changed@example.invalid'),(2,1),(3,'blocked'),(3,'deleted'),(4,1)]:
            self.db.state=copy.deepcopy(original)
            row=list(self.db.state['accounts'][UID]); row[index]=value; self.db.state['accounts'][UID]=tuple(row)
            self.assertEqual(self.check().state,'declined')
            self.assertEqual(self.db.transaction(lambda c,e:self.store.consume(c,e,ticket=ticket,code=CODE)).state,'declined')
            self.assertEqual(self.db.state['challenges'][(UID,RESET)]['attempts'],0)
        self.db.state=copy.deepcopy(original); self.db.now=NOW+600
        self.assertEqual(self.check().state,'declined')
        self.assertEqual(self.db.transaction(lambda c,e:self.store.consume(c,e,ticket=ticket,code=CODE)).state,'declined')
        self.db.now=NOW+60; self.issue(2)
        self.assertEqual(self.db.transaction(lambda c,e:self.store.consume(c,e,ticket=ticket,code=CODE)).state,'declined')

    def test_consume_same_outer_transaction_rollback_and_one_use_bound_capability(self):
        self.issue(); ticket=self.check().ticket; before=copy.deepcopy(self.db.state)
        def fail(c,e):
            result=self.store.consume(c,e,ticket=ticket,code=CODE)
            self.assertEqual(result.state,'consumed')
            row=list(c.working['accounts'][UID]); row[4]=1; c.working['accounts'][UID]=tuple(row)
            raise RuntimeError('synthetic later reset/readback failure')
        with self.assertRaises(RuntimeError):
            self.db.transaction(fail)
        self.assertEqual(self.db.state,before)
        ticket=self.check().ticket
        def finish(c,e):
            result=self.store.consume(c,e,ticket=ticket,code=CODE)
            binding=validate_consumed_challenge_capability(result.consumed,c,e)
            self.assertEqual((binding.uid,binding.email,binding.token_version),(UID,EMAIL,0))
            with self.assertRaises(ChallengeUnavailable):
                validate_consumed_challenge_capability(result.consumed,c,e)
            return result
        result=self.db.transaction(finish)
        self.assertEqual(result.state,'consumed')
        self.assertEqual(self.check().state,'declined')
        with self.assertRaises(ChallengeUnavailable):
            self.db.transaction(lambda c,e:self.store.consume(c,e,ticket=ticket,code=CODE))
        with self.assertRaises(ChallengeUnavailable):
            validate_consumed_challenge_capability(ConsumedChallengeCapability(),None,None)

    def test_cross_store_ticket_rejected_before_sql_and_readback_failure_rolls_back(self):
        self.issue(); ticket=self.check().ticket
        port=NativeAuthChallengeStore(ENV,self.codec); before=len(self.db.calls)
        with self.assertRaises(ChallengeUnavailable):
            self.db.transaction(lambda c,e:port.consume(c,e,ticket=ticket,code=CODE))
        self.assertEqual(len(self.db.calls),before)
        before=copy.deepcopy(self.db.state); self.db.now=NOW+60; self.db.corrupt_readback=True
        with self.assertRaises(ChallengeUnavailable):
            self.issue(2)
        self.assertEqual(self.db.state,before)

    def test_signup_requires_existing_trusted_marker_exact_account_and_no_credentials_profiles(self):
        row=list(self.db.state['accounts'][UID]); row[2]=1; row[5]=0; self.db.state['accounts'][UID]=tuple(row)
        self.assertEqual(self.issue(purpose=REGISTER).state,'declined')
        with self.assertRaises(ChallengeUnavailable):
            self.issue(purpose=REGISTER,pending_account=object())
        self.assertEqual(self.db.state['challenges'],{})
        self.seed_pending(); self.db.now=NOW+60
        marker=self.db.state['challenges'][(UID,REGISTER)]['marker']
        self.assertEqual(self.issue(2,purpose=REGISTER).state,'issued')
        self.assertEqual(self.db.state['challenges'][(UID,REGISTER)]['marker'],marker)
        for existing in [(1,0,0,0),(0,1,0,0),(0,0,1,0),(0,0,0,1)]:
            self.db.state['credential_counts'][UID]=existing
            self.assertEqual(self.check(2,purpose=REGISTER).state,'declined')
        self.db.state['credential_counts'][UID]=(0,0,0,0)
        self.assertEqual(self.check(2,purpose=REGISTER).state,'verified')
        self.db.state['challenges'][(UID,REGISTER)]['pending_created']=_timestamp(NOW-101)
        self.assertEqual(self.check(2,purpose=REGISTER).state,'declined')


if __name__=='__main__':
    unittest.main()
