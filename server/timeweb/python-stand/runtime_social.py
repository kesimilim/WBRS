"""Native feed transactions on the existing MySQL schema.

Imported documents and likes remain retained. Every mutation has the original
operation receipt, and replay checks the current visibility/role again.
"""
from __future__ import annotations

import hashlib
import time
from datetime import datetime, timezone

from legacy_conversation_payload import OpaqueReferences, LegacyInvalid
from native_credentials import decode_base64
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable
from runtime_chat import _identifier

class SocialAccessDenied(RuntimeRejected):
    pass


ORDER = "created_desc_id_desc_null_last"
OPS = frozenset({"social.publish.v1", "social.comment.v1", "social.react.v1", "social.report.v1", "social.hide-comment.v1"})
POST_COLUMNS = """p.post_id,p.author_uid,p.body,COALESCE(pm.media_id,p.media_id),p.status,
 DATE_FORMAT(p.created_at,'%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),p.like_count,p.comment_count,
 a.disabled,a.lifecycle"""
POST_FROM = (" FROM clrs_staging.posts p JOIN clrs_staging.accounts a ON a.uid=p.author_uid "
             "LEFT JOIN clrs_staging.post_media pm ON pm.post_id=p.post_id AND pm.status='ready' ")
ROLE = """SELECT role,verified_source,revoked_at FROM clrs_staging.role_grants
 WHERE uid=%s AND role IN ('admin','moderator','author') LIMIT 4 FOR SHARE"""


def ident(value):
    if not isinstance(value, str) or value in {'.','..'} or '/' in value:
        raise RuntimeInvalidRequest()
    return _identifier(value)


def body_text(value):
    if (type(value) is not str or not value.strip() or len(value)>4000
            or len(value.encode('utf8'))>16000 or '\x00' in value):
        raise RuntimeInvalidRequest()
    return value.strip()


def stamp(value):
    if value is None:
        return None
    try:
        parsed=datetime.strptime(value,'%Y-%m-%dT%H:%M:%S.%fZ')
        if parsed.strftime('%Y-%m-%dT%H:%M:%S.%fZ') != value: raise ValueError()
        return value
    except (ValueError,TypeError):
        raise RuntimeUnavailable() from None


def _roles(cursor, execute, uid):
    execute(ROLE,(uid,)); rows=cursor.fetchall()
    if len(rows)>3: raise RuntimeUnavailable()
    accepted=set()
    for row in rows:
        if (len(row)!=3 or row[0] not in {'admin','moderator','author'}
                or row[1] not in {'firebase_claim','approved_uid','admin_grant'}):
            raise RuntimeUnavailable()
        if row[2] is None: accepted.add(row[0])
    return accepted


def _post(cursor, execute, post_id, *, lock=False):
    execute("SELECT "+POST_COLUMNS+POST_FROM+"WHERE p.post_id=%s LIMIT 1"+
            (" FOR UPDATE OF p FOR SHARE OF a" if lock else " FOR SHARE OF p,a"),(post_id,))
    row=cursor.fetchone()
    if row is None: raise SocialAccessDenied()
    return _decode_post(row)


def _decode_post(row):
    if not isinstance(row,(list,tuple)) or len(row)!=10: raise RuntimeUnavailable()
    if row[4]!='published' or row[8]!=0 or row[9]!='active': raise SocialAccessDenied()
    if (row[2] is not None and (type(row[2]) is not str or len(row[2])>4000)
            or any(type(n) is not int or n<0 for n in row[6:8])): raise RuntimeUnavailable()
    return {'id':ident(row[0]),'authorUid':ident(row[1]),'text':row[2],
        'mediaId': None if row[3] is None else ident(row[3]),'createdAt':stamp(row[5]),
        'likeCount':row[6],'commentCount':row[7]}


def _comment(cursor,execute,post_id,comment_id,*,lock=False):
    execute("""SELECT author_uid,body,parent_id,media_id,
 DATE_FORMAT(created_at,'%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),deleted_at
 FROM clrs_staging.post_comments WHERE post_id=%s AND comment_id=%s LIMIT 1"""+
            (' FOR UPDATE' if lock else ' FOR SHARE'),(post_id,comment_id))
    row=cursor.fetchone()
    if row is None: raise SocialAccessDenied()
    if len(row)!=6: raise RuntimeUnavailable()
    if row[5] is not None: raise SocialAccessDenied()
    if len(row)!=6: raise RuntimeUnavailable()
    return row


class RuntimeSocialService:
    def __init__(self,store,key,*,clock=time.time):
        if store is None or type(key) is not bytes or len(key)!=32: raise RuntimeUnavailable()
        self.store=store; self.clock=clock
        self.codec=OpaqueReferences(hashlib.sha256(b'clrs-social-page-v1\0'+key).digest())
        for operation in OPS: store.register_replay_guard(operation,self._replay,response_guard=True,operation_id_guard=True)

    @classmethod
    def from_env(cls,store,env):
        if env.get('CLRS_RUNTIME_SOCIAL_ENABLED')!='1': return None
        return cls(store,decode_base64(env.get('CLRS_LEGACY_READ_CURSOR_KEY_B64'),max_bytes=32))

    @staticmethod
    def _new_id(kind,uid,operation_id):
        return ('tw-post-' if kind=='publish' else 'tw-comment-')+hashlib.sha256(
            (kind+'\0'+uid+'\0'+operation_id).encode('utf8')).hexdigest()

    @staticmethod
    def _report_target(post_id,comment_id):
        # Parent+comment may exceed VARCHAR(191). The full IDs are retained
        # separately in the report payload; the bounded target is deterministic.
        return post_id if not comment_id else 'tw-comment-target-'+hashlib.sha256(
            (post_id+'\0'+comment_id).encode('utf8')).hexdigest()

    def _replay(self,cursor,execute,uid,operation_id,request,response):
        if type(request) is not dict or type(response) is not dict: raise RuntimeUnavailable()
        kind=request.get('kind')
        shapes={'publish':({'kind','text'},{'postId'}),
            'comment':({'kind','postId','text','parentId'},{'postId','commentId'}),
            'react':({'kind','postId','commentId','active'},{'postId','commentId','active'}),
            'report':({'kind','postId','commentId'},{'postId','commentId','reported'}),
            'hide-comment':({'kind','postId','commentId'},{'postId','commentId','hidden'})}
        if kind not in shapes or (set(request),set(response))!=shapes[kind]: raise RuntimeUnavailable()
        if kind=='publish':
            if response['postId']!=self._new_id(kind,uid,operation_id): raise RuntimeUnavailable()
            if not (_roles(cursor,execute,uid)&{'admin','author'}): raise SocialAccessDenied()
            p=_post(cursor,execute,response['postId'])
            if p['authorUid']!=uid or p['text']!=body_text(request['text']): raise RuntimeUnavailable()
            return
        if response['postId']!=request['postId']: raise RuntimeUnavailable()
        _post(cursor,execute,ident(request['postId']))
        if kind=='comment':
            expected=self._new_id(kind,uid,operation_id)
            if response['commentId']!=expected: raise RuntimeUnavailable()
            row=_comment(cursor,execute,request['postId'],expected)
            if row[0]!=uid or row[1]!=body_text(request['text']) or row[2]!=request['parentId']: raise RuntimeUnavailable()
            if request['parentId'] is not None: _comment(cursor,execute,request['postId'],ident(request['parentId']))
            return
        if response['commentId']!=request['commentId']: raise RuntimeUnavailable()
        cid=request['commentId']
        if cid is not None: ident(cid)
        if kind=='hide-comment':
            if cid is None or response['hidden'] is not True: raise RuntimeUnavailable()
            if not (_roles(cursor,execute,uid)&{'admin','moderator'}): raise SocialAccessDenied()
            execute('SELECT deleted_at FROM clrs_staging.post_comments WHERE post_id=%s AND comment_id=%s LIMIT 1 FOR SHARE',(request['postId'],cid))
            row=cursor.fetchone()
            if row is None or len(row)!=1 or row[0] is None: raise RuntimeUnavailable()
        elif kind=='react':
            if type(request['active']) is not bool or response['active'] is not request['active']: raise RuntimeUnavailable()
            if cid is not None: _comment(cursor,execute,request['postId'],cid)
        elif kind=='report':
            if response['reported'] is not True: raise RuntimeUnavailable()
            report_id='tw-report-'+hashlib.sha256((uid+'\0'+request['postId']+'\0'+(cid or '')).encode()).hexdigest()
            execute('SELECT reporter_uid,entity_kind,entity_id FROM clrs_staging.moderation_reports WHERE report_id=%s LIMIT 1 FOR SHARE',(report_id,))
            row=cursor.fetchone(); expected=(uid,'comment' if cid else 'post',self._report_target(request['postId'],cid))
            if row is None or tuple(row)!=expected: raise RuntimeUnavailable()

    def feed(self,identity,*,access_token,limit=10,cursor=None,wall_uid=None):
        if type(limit) is not int or not 1<=limit<=10: raise RuntimeInvalidRequest()
        page_limit=min(limit,3)  # 3 * 16 KiB text + DTOs stays below 64 KiB.
        if wall_uid is not None: wall_uid=ident(wall_uid)
        def read(c,ex,uid):
            anchor=None
            if cursor is not None:
                try: anchor=self.codec.open('cursor',cursor)
                except LegacyInvalid: raise RuntimeInvalidRequest() from None
                if (set(anchor)!={'uid','limit','wallUid','date','id','exp'}
                        or anchor['uid']!=uid or anchor['limit']!=limit or anchor['wallUid']!=wall_uid
                        or type(anchor['exp']) is not int or not self.clock()<anchor['exp']<=self.clock()+300):
                    raise RuntimeInvalidRequest()
                ident(anchor['id']); stamp(anchor['date'])
            sql='SELECT '+POST_COLUMNS+POST_FROM+"WHERE p.status='published' AND a.disabled=0 AND a.lifecycle='active'"
            params=[]
            if wall_uid is not None:
                # Profile wall contains owned posts plus explicit retained shares.
                sql+=" AND (p.author_uid=%s OR EXISTS(SELECT 1 FROM clrs_staging.wall_entries w WHERE w.uid=%s AND w.post_id=p.post_id))"
                params += [wall_uid,wall_uid]
            if anchor:
                if anchor['date'] is None:
                    sql+=' AND p.created_at IS NULL AND p.post_id<%s'; params += [anchor['id']]
                else:
                    date=datetime.strptime(anchor['date'],'%Y-%m-%dT%H:%M:%S.%fZ')
                    sql+=' AND (p.created_at<%s OR (p.created_at=%s AND p.post_id<%s) OR p.created_at IS NULL)'
                    params += [date,date,anchor['id']]
            sql+=' ORDER BY p.created_at DESC,p.post_id DESC LIMIT %s FOR SHARE OF p,a'
            ex(sql,tuple(params+[page_limit+1])); rows=c.fetchall(); items=[_decode_post(r) for r in rows[:page_limit]]
            # Return the current actor's own reaction without permitting a fake
            # like UID supplied by the client.
            for item in items:
                item['liked']=self._liked(c,ex,uid,item['id'],'')
            next_cursor=None
            if len(rows)>page_limit:
                last=items[-1]; next_cursor=self.codec.seal('cursor',{'uid':uid,'limit':limit,
                    'wallUid':wall_uid,'date':last['createdAt'],'id':last['id'],'exp':anchor['exp'] if anchor else int(self.clock())+300})
            roles=_roles(c,ex,uid)
            return {'kind':'native-feed','ordering':ORDER,'items':items,'nextCursor':next_cursor,
                    'canPublish':bool(roles&{'admin','author'}),'canModerate':bool(roles&{'admin','moderator'})}
        return self.store.read_authenticated(identity,read,access_token=access_token)

    @staticmethod
    def _liked(c,ex,uid,post_id,comment_id):
        ex('SELECT active FROM clrs_staging.social_reaction_state WHERE post_id=%s AND comment_id=%s AND uid=%s LIMIT 1 FOR SHARE',
           (post_id,comment_id,uid)); row=c.fetchone()
        if row is not None:
            if len(row)!=1 or type(row[0]) is not int or row[0] not in (0,1): raise RuntimeUnavailable()
            return bool(row[0])
        if comment_id:
            ex('SELECT uid FROM clrs_staging.comment_likes WHERE post_id=%s AND comment_id=%s AND uid=%s LIMIT 1 FOR SHARE',(post_id,comment_id,uid))
        else:
            ex('SELECT uid FROM clrs_staging.post_likes WHERE post_id=%s AND uid=%s LIMIT 1 FOR SHARE',(post_id,uid))
        return c.fetchone() is not None

    def comments(self,identity,post_id,*,access_token,cursor=None):
        post_id=ident(post_id)
        def read(c,ex,uid):
            _post(c,ex,post_id)
            anchor=None
            if cursor is not None:
                try: anchor=self.codec.open('cursor',cursor)
                except LegacyInvalid: raise RuntimeInvalidRequest() from None
                if (set(anchor)!={'uid','postId','date','id','exp'} or anchor['uid']!=uid
                        or anchor['postId']!=post_id or type(anchor['exp']) is not int
                        or not self.clock()<anchor['exp']<=self.clock()+300): raise RuntimeInvalidRequest()
                ident(anchor['id']); stamp(anchor['date'])
            sql="""SELECT comment_id,author_uid,body,parent_id,media_id,
 DATE_FORMAT(created_at,'%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') FROM clrs_staging.post_comments
 WHERE post_id=%s AND deleted_at IS NULL"""
            params=[post_id]
            if anchor:
                if anchor['date'] is None:
                    sql+=' AND (created_at IS NOT NULL OR (created_at IS NULL AND comment_id>%s))'; params += [anchor['id']]
                else:
                    d=datetime.strptime(anchor['date'],'%Y-%m-%dT%H:%M:%S.%fZ')
                    sql+=' AND (created_at>%s OR (created_at=%s AND comment_id>%s))'; params += [d,d,anchor['id']]
            sql+=' ORDER BY created_at ASC,comment_id ASC LIMIT 4 FOR SHARE'
            ex(sql,tuple(params)); rows=c.fetchall(); items=[]
            for r in rows[:3]:
                if len(r)!=6 or r[2] is not None and (type(r[2]) is not str or len(r[2])>4000): raise RuntimeUnavailable()
                items.append({'id':ident(r[0]),'authorUid':ident(r[1]),'text':r[2],
                    'parentId': None if r[3] is None else ident(r[3]),'mediaId':None if r[4] is None else ident(r[4]),
                    'createdAt':stamp(r[5]),'liked':self._liked(c,ex,uid,post_id,r[0])})
            next_cursor=None
            if len(rows)>3:
                last=items[-1]; next_cursor=self.codec.seal('cursor',{'uid':uid,'postId':post_id,
                    'date':last['createdAt'],'id':last['id'],'exp':anchor['exp'] if anchor else int(self.clock())+300})
            return {'kind':'native-comments','postId':post_id,'ordering':'created_asc_id_asc_null_first',
                    'items':items,'nextCursor':next_cursor}
        return self.store.read_authenticated(identity,read,access_token=access_token)

    def perform(self,identity,operation_id,payload,*,access_token):
        if type(payload) is not dict: raise RuntimeInvalidRequest()
        kind=payload.get('kind'); allowed={'publish':{'kind','text'},'comment':{'kind','postId','text','parentId'},
            'react':{'kind','postId','commentId','active'},'report':{'kind','postId','commentId'},
            'hide-comment':{'kind','postId','commentId'}}
        if kind not in allowed or set(payload)!=allowed[kind]: raise RuntimeInvalidRequest()
        if kind in {'publish','comment'}: text=body_text(payload['text'])
        if kind!='publish': post_id=ident(payload['postId'])
        if kind in {'react','report','hide-comment'}:
            comment_id=payload['commentId']; comment_id='' if comment_id is None else ident(comment_id)
            if kind=='hide-comment' and not comment_id: raise RuntimeInvalidRequest()
        if kind=='react' and type(payload['active']) is not bool: raise RuntimeInvalidRequest()
        if kind=='comment': parent=payload['parentId']; parent=None if parent is None else ident(parent)
        op={'publish':'social.publish.v1','comment':'social.comment.v1','react':'social.react.v1',
            'report':'social.report.v1','hide-comment':'social.hide-comment.v1'}[kind]
        def action(c,ex,uid):
            if kind=='publish':
                if not (_roles(c,ex,uid)&{'admin','author'}): raise SocialAccessDenied()
                new_id=self._new_id(kind,uid,operation_id)
                ex("INSERT INTO clrs_staging.posts(post_id,author_uid,body,status,created_at,updated_at,legacy_raw) VALUES(%s,%s,%s,'published',UTC_TIMESTAMP(6),UTC_TIMESTAMP(6),JSON_OBJECT('nativeSocialVersion',1))",(new_id,uid,text))
                return 201,{'postId':new_id},None
            _post(c,ex,post_id,lock=True)
            if kind=='comment':
                if parent is not None: _comment(c,ex,post_id,parent)
                new_id=self._new_id(kind,uid,operation_id)
                ex("INSERT INTO clrs_staging.post_comments(post_id,comment_id,author_uid,parent_id,body,created_at,legacy_raw) VALUES(%s,%s,%s,%s,%s,UTC_TIMESTAMP(6),JSON_OBJECT('nativeSocialVersion',1))",(post_id,new_id,uid,parent,text))
                ex('UPDATE clrs_staging.posts SET comment_count=comment_count+1,updated_at=UTC_TIMESTAMP(6) WHERE post_id=%s',(post_id,))
                return 201,{'postId':post_id,'commentId':new_id},None
            if comment_id: _comment(c,ex,post_id,comment_id,lock=True)
            if kind=='react':
                previous=self._liked(c,ex,uid,post_id,comment_id); active=payload['active']
                ex("""INSERT INTO clrs_staging.social_reaction_state(post_id,comment_id,uid,active)
 VALUES(%s,%s,%s,%s) ON DUPLICATE KEY UPDATE active=VALUES(active),updated_at=UTC_TIMESTAMP(6)""",(post_id,comment_id,uid,int(active)))
                if previous!=active and not comment_id:
                    ex('UPDATE clrs_staging.posts SET like_count=GREATEST(0,like_count+%s),updated_at=UTC_TIMESTAMP(6) WHERE post_id=%s',(1 if active else -1,post_id))
                return 200,{'postId':post_id,'commentId':comment_id or None,'active':active},None
            if kind=='report':
                report_id='tw-report-'+hashlib.sha256((uid+'\0'+post_id+'\0'+comment_id).encode()).hexdigest()
                ex("""INSERT INTO clrs_staging.moderation_reports(report_id,reporter_uid,entity_kind,entity_id,status,created_at,legacy_raw)
 VALUES(%s,%s,%s,%s,'new',UTC_TIMESTAMP(6),JSON_OBJECT('postId',%s,'commentId',%s,'nativeSocialVersion',1)) ON DUPLICATE KEY UPDATE report_id=report_id""",(report_id,uid,'comment' if comment_id else 'post',self._report_target(post_id,comment_id),post_id,comment_id or None))
                return 200,{'postId':post_id,'commentId':comment_id or None,'reported':True},None
            if not (_roles(c,ex,uid)&{'admin','moderator'}): raise SocialAccessDenied()
            ex('UPDATE clrs_staging.post_comments SET deleted_at=UTC_TIMESTAMP(6) WHERE post_id=%s AND comment_id=%s AND deleted_at IS NULL',(post_id,comment_id))
            ex('UPDATE clrs_staging.posts SET comment_count=GREATEST(0,comment_count-1),updated_at=UTC_TIMESTAMP(6) WHERE post_id=%s',(post_id,))
            ex("INSERT INTO clrs_staging.admin_audit(actor_uid,action,target_kind,target_id,request_id,details) VALUES(%s,'hide-comment','comment',%s,%s,JSON_OBJECT('postId',%s))",(uid,comment_id,operation_id,post_id))
            return 200,{'postId':post_id,'commentId':comment_id,'hidden':True},None
        return self.store.mutate(identity,op,operation_id,payload,action,access_token=access_token)
