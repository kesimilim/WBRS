"""One mounted social scenario with the real receipt/session store, no TCP."""
import base64
import json
import unittest

from native_auth import NativeRejected
from native_sessions import NativeIdentity
from runtime_http import RuntimeMutationHttp
from runtime_mutations import RuntimeMutationStore, request_digest
from test_runtime_http import env
from test_runtime_mutations import FakeDatabase, FakeCursor, ENV, NOW, STAMP

KEY = bytes(range(32))
UUID = lambda n: f"12345678-1234-4234-8234-{n:012d}"


class SocialCursor(FakeCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); state = self.c.state; db = self.c.db
        tables = ("role_grants", "posts", "post_comments", "social_reaction_state", "post_likes", "comment_likes", "moderation_reports", "admin_audit")
        if not any("clrs_staging." + table in sql for table in tables):
            return super().execute(statement, params)
        assert self.c.held; db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if sql.startswith("SELECT"):
            assert self.c.readonly or "FOR SHARE" in sql or "FOR UPDATE" in sql
        else: assert not self.c.readonly
        if "FROM clrs_staging.role_grants" in sql:
            rows = state["roles"].get(params[0], [])
            self.rows = [tuple(row) if "granted_by" in sql.split(" FROM ")[0] else tuple(row[:3]) for row in rows]
        elif sql.startswith("SELECT p.post_id"):
            posts = list(state["posts"].values())
            if "WHERE p.post_id=" in sql: posts = [row for row in posts if row["id"] == params[0]]
            else:
                posts = [row for row in posts if row["status"] == "published" and state["accounts"][row["uid"]][:2] == [0, "active"]]
                if "p.created_at<%s" in sql:
                    date = params[-4].strftime("%Y-%m-%dT%H:%M:%S.%fZ"); ident = params[-2]
                    posts = [row for row in posts if row["stamp"] is None or (row["stamp"], row["id"].encode()) < (date, ident.encode())]
                elif "p.created_at IS NULL AND p.post_id<%s" in sql:
                    posts = [row for row in posts if row["stamp"] is None and row["id"].encode() < params[-2].encode()]
                posts.sort(key=lambda row: (row["stamp"] is not None, row["stamp"] or "", row["id"].encode()), reverse=True)
                posts = posts[:params[-1]]
            self.rows = [(row["id"], row["uid"], row["text"], None, row["status"], row["stamp"], row["likes"], row["comments"],
                *state["accounts"][row["uid"]][:2]) for row in posts]
        elif sql.startswith("SELECT active"):
            row = state["reactions"].get(tuple(params[:3])); self.rows = [] if row is None else [(row,)]
        elif "FROM clrs_staging.post_likes" in sql:
            if tuple(params[:2]) in state["legacy_likes"]: self.rows = [(params[1],)]
        elif "FROM clrs_staging.comment_likes" in sql:
            if tuple(params[:3]) in state["legacy_comment_likes"]: self.rows = [(params[2],)]
        elif sql.startswith("SELECT author_uid"):
            row = state["comments"].get(tuple(params[:2]))
            if row: self.rows = [(row["uid"], row["text"], row["parent"], None, row["stamp"], row["deleted"])]
        elif sql.startswith("SELECT deleted_at"):
            row = state["comments"].get(tuple(params[:2])); self.rows = [] if row is None else [(row["deleted"],)]
        elif sql.startswith("SELECT reporter_uid"):
            row = state["reports"].get(params[0]); self.rows = [] if row is None else [row]
        elif sql.startswith("SELECT comment_id"):
            rows = [row for key, row in state["comments"].items() if key[0] == params[0] and row["deleted"] is None]
            if "created_at>%s" in sql:
                stamp = params[-3].strftime("%Y-%m-%dT%H:%M:%S.%fZ"); ident = params[-1]
                rows = [row for row in rows if row["stamp"] is not None and (row["stamp"], row["id"].encode()) > (stamp, ident.encode())]
            elif "created_at IS NULL AND comment_id>%s" in sql:
                rows = [row for row in rows if row["stamp"] is not None or row["id"].encode() > params[-1].encode()]
            rows.sort(key=lambda row: (row["stamp"] is not None, row["stamp"] or "", row["id"].encode()))
            self.rows = [(row["id"], row["uid"], row["text"], row["parent"], None, row["stamp"]) for row in rows[:4]]
        elif sql.startswith("INSERT INTO clrs_staging.posts"):
            ident, uid, text = params[:3]; assert ident not in state["posts"]
            state["posts"][ident] = {"id": ident, "uid": uid, "text": text, "stamp": STAMP, "status": "published", "likes": 0, "comments": 0}; self.rowcount = 1
        elif sql.startswith("INSERT INTO clrs_staging.post_comments"):
            post, ident, uid, parent, text = params[:5]; assert (post, ident) not in state["comments"]
            state["comments"][(post, ident)] = {"id": ident, "uid": uid, "parent": parent, "text": text, "stamp": STAMP, "deleted": None}; self.rowcount = 1
        elif sql.startswith("INSERT INTO clrs_staging.social_reaction_state"):
            post, comment, uid, active = params[:4]; assert active in (0, 1)
            state["reactions"][(post, comment, uid)] = active; self.rowcount = 1
        elif sql.startswith("INSERT INTO clrs_staging.moderation_reports"):
            ident, uid, kind, target, post_id, comment_id = params
            assert target == post_id if comment_id is None else target.startswith("tw-comment-target-")
            if ident not in state["reports"]: state["reports"][ident] = (uid, kind, target); self.rowcount = 1
        elif sql.startswith("INSERT INTO clrs_staging.admin_audit"):
            state["audit"].append(tuple(params)); self.rowcount = 1
        elif sql.startswith("UPDATE clrs_staging.posts"):
            row = state["posts"][params[-1]]
            if "like_count" in sql: row["likes"] = max(0, row["likes"] + params[0])
            elif "comment_count=comment_count+1" in sql: row["comments"] += 1
            else: row["comments"] = max(0, row["comments"] - 1)
            self.rowcount = 1
        elif sql.startswith("UPDATE clrs_staging.post_comments"):
            row = state["comments"].get(tuple(params[:2]))
            if row and row["deleted"] is None: row["deleted"] = STAMP; self.rowcount = 1
        else: raise AssertionError("unexpected social SQL shape")
        return self.rowcount or len(self.rows)


class SocialDatabase(FakeDatabase):
    def __init__(self):
        super().__init__()
        self.state.update(posts={}, comments={}, reactions={}, legacy_likes=set(), legacy_comment_likes=set(), reports={}, audit=[],
            roles={"actor": [["author", "approved_uid", None, None], ["admin", "approved_uid", None, None]]})
        self.grant_rows = [("GRANT USAGE ON *.* TO 'fixture'@'%' REQUIRE SSL",),
            ("GRANT SELECT, INSERT, UPDATE ON `clrs_staging`.* TO 'fixture'@'%'",)]
        session, access = self.tokens.mint("peer", "device-peer", 0, NOW)
        self.peer_token = access["accessToken"]; self.state["sessions"][session["session_id"]] = session
        self.peer = NativeIdentity("peer", True, session["session_id"], NOW, NOW + 900)

    def connect(self, **configuration):
        connection = super().connect(**configuration); connection.cursor = lambda: SocialCursor(connection); return connection


class Native:
    """Keep the production mandatory peer keyword; verify actual fixture tokens."""
    def __init__(self, db): self.db = db
    def authorize(self, token, *, peer):
        if peer != "socket-peer": raise NativeRejected()
        if token == self.db.access: return self.db.identity
        if token == self.db.peer_token: return self.db.peer
        raise NativeRejected()


class SocialTests(unittest.TestCase):
    def test_mounted_shared_store_original_social_receipts_and_current_acl(self):
        db = SocialDatabase(); native = Native(db); now = [NOW]
        configuration = {**ENV, "CLRS_RUNTIME_PERMISSION_MODEL": "provider-database-v1", "CLRS_RUNTIME_SOCIAL_ENABLED": "1",
            "CLRS_LEGACY_READ_CURSOR_KEY_B64": base64.b64encode(KEY).decode()}
        def mount():
            store = RuntimeMutationStore(configuration, db.tokens, connect=db.connect, clock=lambda: NOW)
            http = RuntimeMutationHttp(configuration, service_factory=lambda _: (store,))
            self.addCleanup(http.close); return store, http
        store, http = mount()
        def call(path, *, token=None, body=None, query=""):
            return http.dispatch(env(path, body, REQUEST_METHOD="POST" if body is not None else "GET", QUERY_STRING=query,
                HTTP_AUTHORIZATION="Bearer " + (token or db.access)), native_service=native, native_configured=True)
        def action(operation, payload, token=None):
            return call("/v1/runtime/social/actions", token=token, body={"operationId": operation, "payload": payload})
        def lookup(kind, operation, payload, token=None, generic=False):
            return call(("/v1/runtime/operations/" if generic else "/v1/runtime/social/operations/") + kind + "/" + operation,
                token=token, query="requestHash=" + request_digest(payload).hex())
        published = action(UUID(1), {"kind": "publish", "text": "Авторская публикация"})
        self.assertEqual(published.status.split()[0], "201", published.payload)
        http._social.service.clock = lambda: now[0]
        post = published.payload["result"]["postId"]
        reaction = {"kind": "react", "postId": post, "commentId": None, "active": True}
        self.assertEqual(action(UUID(2), reaction, db.peer_token).status.split()[0], "200")
        self.assertEqual(action(UUID(2), reaction, db.peer_token).payload["result"]["active"], True)
        self.assertEqual(db.state["posts"][post]["likes"], 1)
        reaction["active"] = False; action(UUID(3), reaction, db.peer_token)
        self.assertEqual((db.state["posts"][post]["likes"], db.state["reactions"][(post, "", "peer")]), (0, 0))
        comment = {"kind": "comment", "postId": post, "text": "Сохранённый комментарий", "parentId": None}
        db.commit_unknown_once = True
        self.assertEqual(action(UUID(4), comment, db.peer_token).payload, {"error": "outcome_unknown"})
        http.close(); store, http = mount()
        # The explicit social original lookup is the first request after restart.
        # The generic operations route deliberately has no social authority.
        self.assertIsNone(lookup("social.comment.v1", UUID(4), comment, db.peer_token, generic=True))
        original = lookup("social.comment.v1", UUID(4), comment, db.peer_token)
        self.assertEqual(original.status.split()[0], "201", original.payload)
        comment_id = original.payload["result"]["commentId"]
        self.assertEqual(lookup("social.comment.v1", UUID(4), comment).payload["state"], "not_found")
        http._social.service.clock = lambda: now[0]
        self.assertEqual(db.state["posts"][post]["comments"], 1)
        self.assertEqual(sum(sql.startswith("INSERT INTO clrs_staging.post_comments") for sql, _ in db.calls), 1)
        receipt = db.state["receipts"][("peer", "social.comment.v1", UUID(4))]; retained = receipt[3]
        changed = json.loads(retained); changed["response"]["commentId"] = "other-visible-comment"
        db.state["comments"][(post, "other-visible-comment")] = {"id": "other-visible-comment", "uid": "actor", "parent": None, "text": "Чужой", "stamp": STAMP, "deleted": None}
        receipt[3] = json.dumps(changed)
        self.assertEqual(lookup("social.comment.v1", UUID(4), comment, db.peer_token).status.split()[0], "503")
        receipt[3] = retained; db.state["comments"].pop((post, "other-visible-comment"))
        report = {"kind": "report", "postId": post, "commentId": comment_id}
        self.assertEqual(action(UUID(5), report, db.peer_token).payload["result"]["reported"], True)
        hide = {"kind": "hide-comment", "postId": post, "commentId": comment_id}
        self.assertEqual(action(UUID(6), hide).payload["result"]["hidden"], True)
        self.assertEqual((db.state["posts"][post]["comments"], len(db.state["reports"]), len(db.state["audit"])), (0, 1, 1))
        self.assertEqual(lookup("social.hide-comment.v1", UUID(6), hide).payload["result"]["hidden"], True)
        db.state["roles"]["actor"] = [["author", "approved_uid", STAMP, None], ["admin", "approved_uid", STAMP, None]]
        denied = lookup("social.hide-comment.v1", UUID(6), hide)
        self.assertEqual((denied.status.split()[0], denied.authenticate), ("403", False))
        self.assertEqual(action(UUID(7), {"kind": "publish", "text": "Нет роли"}).status.split()[0], "403")
        # Two pages after the first are needed to prove TTL cannot slide.
        for n in range(8):
            ident = f"retained-{n}"
            db.state["posts"][ident] = {"id": ident, "uid": "actor", "text": "Сохранённое", "stamp": STAMP, "status": "published", "likes": 0, "comments": 0}
        page = call("/v1/runtime/social/feed", token=db.peer_token)
        cursor = page.payload["nextCursor"]; self.assertIsNotNone(cursor)
        exp = http._social.service.codec.open("cursor", cursor)["exp"]
        wrong_owner = call("/v1/runtime/social/feed", query="cursor=" + cursor)
        self.assertEqual((wrong_owner.status.split()[0], wrong_owner.authenticate), ("400", False))
        now[0] += 250
        next_page = call("/v1/runtime/social/feed", token=db.peer_token, query="cursor=" + cursor)
        next_cursor = next_page.payload["nextCursor"]; self.assertIsNotNone(next_cursor)
        self.assertEqual(http._social.service.codec.open("cursor", next_cursor)["exp"], exp)
        now[0] = exp
        self.assertEqual(call("/v1/runtime/social/feed", token=db.peer_token, query="cursor=" + next_cursor).status.split()[0], "400")
        db.state["accounts"]["peer"][0] = 1
        denied = call("/v1/runtime/social/feed", token=db.peer_token)
        self.assertEqual((denied.status.split()[0], denied.authenticate), ("401", True))


if __name__ == "__main__": unittest.main()
