"""Scoped native meeting messages; shared real store, synthetic SQL, no TCP."""
import copy
import json
import unittest
from runtime_http import RuntimeMutationHttp
from runtime_meetings import RuntimeMeetingsService, TRUSTED_POLICY
from runtime_meeting_create import MeetingAccessRejected
from runtime_meeting_chat import (RuntimeMeetingChatService, SEND_OPERATION, MESSAGE_ORIGIN,
    _INDEX_PARTS, _message_id, validate_page)
from runtime_mutations import (RuntimeMutationStore, RuntimeUnavailable, RuntimeCommitUnknown,
    RuntimeInvalidRequest, RuntimeRejected, request_digest, canonical_json)
from runtime_reads import RuntimeReadRejected
from test_runtime_meeting_join import JoinCursor, JoinDatabase, MID
from test_runtime_http import Native, env, OP, ENV as HTTP_ENV
from test_runtime_mutations import NOW, STAMP

SECOND = "12345678-1234-4234-8234-123456789abd"
KEY = bytes(range(32))
TEXT = "  Точный текст\n\t"


class MessageCursor(JoinCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); state = self.c.state; db = self.c.db
        selected = ("meeting_messages" in sql or sql.startswith("SELECT revision FROM clrs_staging.meetings")
                    or sql.startswith("UPDATE clrs_staging.meetings SET revision"))
        if not selected: return super().execute(statement, params)
        assert self.c.held
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if db.fail_contains and db.fail_contains in sql: raise OSError("synthetic SQL denial")
        if "information_schema.STATISTICS" in sql:
            self.rows = db.message_indexes
        elif sql.startswith("SELECT revision FROM"):
            assert params == (MID,MID); self.rows = [(state["meetings"][MID]["revision"],)]
        elif sql.startswith("INSERT INTO"):
            assert not self.c.readonly
            meeting, mid, sequence, sender, text, created, raw = params
            assert meeting == MID and (meeting,mid) not in state["meeting_messages"]
            assert (meeting,sender) in state["meeting_members"]
            assert not any(row["sequence"] == sequence for row in state["meeting_messages"].values())
            assert created == STAMP[:-1].replace("T"," ")
            state["meeting_messages"][(meeting,mid)] = {"meetingId":meeting,"messageId":mid,
                "sequence":sequence,"senderUid":sender,"text":text,"createdAt":STAMP,
                "media_id":None,"legacy_raw":json.loads(raw)}; self.rowcount=1
        elif sql.startswith("UPDATE"):
            assert not self.c.readonly
            revision, created, meeting, exact, old = params
            assert meeting == exact == MID and revision == old+1
            row=state["meetings"][MID]; assert row["revision"]==old
            row.update(revision=revision,updatedAt=STAMP); self.rowcount=1
        else:
            assert sql.endswith("FOR SHARE OF mm") and params[:2] == (MID,MID)
            rows=list(state["meeting_messages"].values())
            if "mm.message_id = %s" in sql:
                assert params[2]==params[3]; rows=[row for row in rows if row["messageId"]==params[2]]
            else:
                assert "FORCE INDEX (meeting_messages_page_idx)" in sql
                rows.sort(key=lambda row:row["sequence"],reverse=True)
                if "mm.sequence <= %s" in sql:
                    rows=[row for row in rows if row["sequence"]<=params[2]]
                    if "mm.sequence < %s" in sql: rows=[row for row in rows if row["sequence"]<params[3]]
                    rows=rows[:params[-1]]
                else: rows=rows[:1]
            self.rows=[(row["meetingId"],row["messageId"],row["sequence"],row["senderUid"],
                row["text"],row["createdAt"],int(row["media_id"] is None),
                int(row["legacy_raw"]=={"origin":MESSAGE_ORIGIN})) for row in rows]
        return self.rowcount or len(self.rows)


class MessageDatabase(JoinDatabase):
    def __init__(self, **options):
        super().__init__(**options); self.state["meeting_members"][(MID,"peer")]=self.member("peer")
        self.state["meeting_messages"]={}
        self.message_indexes=[(*part,None,None if part[3]=="sequence" else "utf8mb4_0900_bin") for part in sorted(_INDEX_PARTS)]
    def connect(self, **config):
        connection=super().connect(**config); connection.cursor=lambda:MessageCursor(connection); return connection
    def services(self, clock=lambda:NOW):
        store=RuntimeMutationStore(self.env,self.tokens,connect=self.connect,clock=lambda:NOW)
        return store,RuntimeMeetingChatService(store,clock=clock),RuntimeMeetingsService(store,KEY,trusted_policy=TRUSTED_POLICY,clock=clock)


class MeetingChatTests(unittest.TestCase):
    def setup_chat(self, **options):
        db=MessageDatabase(**options); peer,token=db.peer_identity(); store,chat,reads=db.services()
        self.addCleanup(store.close); return db,store,chat,reads,peer,token
    @staticmethod
    def inserts(db): return sum(sql.startswith("INSERT INTO clrs_staging.meeting_messages") for sql,_ in db.calls)
    def http(self,store,chat,reads,identity,token):
        native=Native();native.identity=identity
        adapter=RuntimeMutationHttp(HTTP_ENV,service_factory=lambda _:(store,None,None,None,None,None,chat),meetings_factory=lambda shared,_:reads if shared is store else self.fail("Different store"))
        def call(request):
            request["HTTP_AUTHORIZATION"]="Bearer "+token
            return adapter.dispatch(request,native_service=native,native_configured=True)
        return call

    def test_http_exact_text_atomic_revision_and_original_uuid_receipt_remains_provable(self):
        db,store,chat,reads,peer,token=self.setup_chat(); db.state["meetings"][MID]["revision"]=7
        call=self.http(store,chat,reads,peer,token)
        post=lambda op:call(env(f"/v1/runtime/meetings/{MID}/messages",{"operationId":op,"text":TEXT}))
        first=post(OP); result=first.payload["result"]
        self.assertEqual((first.status,first.payload["entityRevision"]),("201 Created",8))
        self.assertEqual(result,{"meetingId":MID,"messageId":_message_id(MID,"peer",OP),"sequence":1,
            "senderUid":"peer","text":TEXT,"createdAt":STAMP,"chatRevision":8})
        second=post(SECOND); self.assertEqual((second.payload["result"]["sequence"],second.payload["result"]["chatRevision"]),(2,9))
        self.assertEqual(post(OP).payload["result"],result); self.assertEqual(self.inserts(db),2)
        lookup=lambda:call(env(f"/v1/runtime/operations/{SEND_OPERATION}/{OP}",REQUEST_METHOD="GET",QUERY_STRING="requestHash="+request_digest({"meetingId":MID,"text":TEXT}).hex()))
        found=lookup(); self.assertEqual(found.status,"201 Created");self.assertTrue(found.payload["replayed"])
        self.assertEqual(found.payload["result"],result)
        receipt=db.state["receipts"][("peer",SEND_OPERATION,OP)]; original=receipt[3]
        wrapper=json.loads(original);wrapper["response"]=second.payload["result"];receipt[3]=json.dumps(wrapper)
        self.assertEqual(lookup().status,"503 Service Unavailable");receipt[3]=original
        db.state["meeting_messages"][(MID,result["messageId"])]["text"]="changed"
        self.assertEqual(lookup().payload,{"error":"meeting_unavailable"})
        self.assertFalse(any("user_events" in sql or "outbox" in sql or "chat_messages" in sql for sql,_ in db.calls))
        for extra in ("quoteMessageId","media","senderUid"):
            self.assertEqual(call(env(f"/v1/runtime/meetings/{MID}/messages",{"operationId":OP,"text":TEXT,extra:"x"})).status,"400 Bad Request")

    def test_unknown_commit_restart_lookup_only_and_atomic_rollback_fail_closed(self):
        for committed in (False,True):
            with self.subTest(committed=committed):
                db,store,chat,_,peer,token=self.setup_chat()
                if committed:db.commit_unknown_once=True
                else:db.before_commit=lambda:(_ for _ in ()).throw(OSError("before commit"))
                with self.assertRaises(RuntimeCommitUnknown):chat.send_text(peer,MID,OP,TEXT,access_token=token)
                store.close();db.before_commit=None; restarted,_,_=db.services();self.addCleanup(restarted.close)
                original={"meetingId":MID,"text":TEXT}
                found=restarted.lookup(peer,SEND_OPERATION,OP,request_hash=request_digest(original),access_token=token)
                self.assertEqual(found.payload["state"],"committed" if committed else "not_found")
                self.assertEqual(len(db.state["meeting_messages"]),int(committed));self.assertEqual(self.inserts(db),1)
                self.assertEqual(restarted.lookup(db.identity,SEND_OPERATION,OP,payload=original,access_token=db.access).payload["state"],"not_found")
        for failure in ("UPDATE clrs_staging.meetings SET revision","index","grants"):
            with self.subTest(failure=failure):
                db,_,chat,_,peer,token=self.setup_chat(provider=failure!="grants")
                if failure=="index":db.message_indexes=db.message_indexes[:-1]
                else:db.fail_contains=failure
                before=copy.deepcopy(db.state)
                with self.assertRaises(RuntimeUnavailable):chat.send_text(peer,MID,OP,TEXT,access_token=token)
                self.assertEqual(db.state,before)

    def test_bounded_cursor_whole_text_64k_original_window_expiry_and_native_rows(self):
        db,store,chat,reads,peer,token=self.setup_chat(); now=[NOW];reads._clock=lambda:now[0]
        text="😀"*4096
        for i in range(6):chat.send_text(peer,MID,f"12345678-1234-4234-8234-{i:012d}",text,access_token=token)
        first=reads.messages(peer,MID,access_token=token)
        self.assertEqual([row["sequence"] for row in first["items"]],[6,5,4]);self.assertLessEqual(len(canonical_json(first)),65536)
        cursor=first["nextCursor"];claim=reads._codec.open("cursor",cursor)
        self.assertEqual((claim["capSequence"],claim["initialRevision"],claim["exp"]),(6,6,NOW+300))
        chat.send_text(peer,MID,SECOND,"new",access_token=token)
        second=reads.messages(peer,MID,cursor=cursor,access_token=token)
        self.assertEqual([row["sequence"] for row in second["items"]],[3,2,1]);self.assertIsNone(second["nextCursor"])
        self.assertEqual(second["chatRevision"],7)
        for options in ({"limit":29},{"cursor":reads._codec.seal("cursor",{**claim,"meetingId":"foreign"})}):
            with self.assertRaises(RuntimeInvalidRequest):reads.messages(peer,MID,cursor=options.get("cursor",cursor),limit=options.get("limit",30),access_token=token)
        with self.assertRaises(RuntimeInvalidRequest):reads.messages(db.identity,MID,cursor=cursor,access_token=db.access)
        now[0]=NOW+300
        with self.assertRaises(RuntimeInvalidRequest):reads.messages(peer,MID,cursor=cursor,access_token=token)
        now[0]=NOW
        db.state["meeting_messages"][(MID,_message_id(MID,"peer",SECOND))]["legacy_raw"]={}
        with self.assertRaises(RuntimeUnavailable):reads.messages(peer,MID,access_token=token)
        for invalid in (" ","x\x00","x\x7f","\ud800","a"*4097):
            with self.assertRaises(RuntimeInvalidRequest):chat.send_text(peer,MID,OP,invalid,access_token=token)
        with self.assertRaises(RuntimeUnavailable):validate_page({**first,"items":[],"nextCursor":cursor},MID,30)

    def test_member_only_actor_revocation_kick_and_four_original_refusals(self):
        db,store,chat,reads,peer,token=self.setup_chat(individual=True)
        db.state["meeting_members"].pop((MID,"peer"))
        call=self.http(store,chat,reads,peer,token)
        read=lambda:call(env(f"/v1/runtime/meetings/{MID}/messages",REQUEST_METHOD="GET"))
        denied=read();self.assertEqual((denied.status,denied.payload,denied.authenticate),("404 Not Found",{"error":"meeting_unavailable"},False))
        db.state["meeting_members"][(MID,"peer")]=db.member("peer")
        self.assertEqual(read().payload["items"],[])
        chat.send_text(peer,MID,OP,TEXT,access_token=token)
        db.state["meeting_members"][(MID,"peer")].update(leftAt=STAMP,kickedAt=STAMP)
        with self.assertRaises(MeetingAccessRejected):store.lookup(peer,SEND_OPERATION,OP,payload={"meetingId":MID,"text":TEXT},access_token=token)
        self.assertEqual(read().status,"404 Not Found")
        db.state["accounts"]["peer"][0]=1
        self.assertEqual((read().status,read().authenticate),("401 Unauthorized",True))
        changes=[(404,"meeting_not_found",lambda db:db.state["meetings"].clear()),
            (409,"meeting_unavailable",lambda db:db.state["meeting_members"].pop((MID,"peer"))),
            (404,"profile_not_found",lambda db:db.state["profiles"].pop("peer")),
            (409,"profile_not_ready",lambda db:db.state["profiles"]["peer"].update(isRegistrationEnd=0,primaryGroup=None))]
        for status,error,change in changes:
            db,store,chat,_,peer,token=self.setup_chat();change(db)
            reply=chat.send_text(peer,MID,OP,TEXT,access_token=token)
            self.assertEqual((reply.status,reply.payload["result"]),(status,{"error":error}))
            self.assertEqual(store.lookup(peer,SEND_OPERATION,OP,payload={"meetingId":MID,"text":TEXT},access_token=token).payload["result"],{"error":error})
            self.assertEqual(db.state["meeting_messages"],{})


if __name__=="__main__":unittest.main()
