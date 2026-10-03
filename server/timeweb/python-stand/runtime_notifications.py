"""Bounded own current notifications; source records grant no live access."""
import hmac
import re
import time
from datetime import datetime, timezone
from urllib.parse import parse_qsl
from native_credentials import decode_base64, unique_json
from native_auth import NativeRejected, NativeRateLimited
from native_sessions import NativeIdentity
from legacy_conversation_payload import OpaqueReferences, LegacyInvalid
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json, MAX_INTEGER
from runtime_chat import _identifier, _pair, _ChatFailure

STAMP = "DATE_FORMAT(created_at,'%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')"
EVENT = f"SELECT event_id,event_kind,CASE WHEN OCTET_LENGTH(CAST(payload AS CHAR))<=8192 THEN payload ELSE NULL END,{STAMP} FROM clrs_staging.user_events FORCE INDEX(user_events_audience_idx) WHERE audience_uid=%s AND CAST(audience_uid AS BINARY)=CAST(%s AS BINARY)"
NOTICE = f"SELECT notification_id,kind,entity_id,{STAMP},DATE_FORMAT(read_at,'%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),CASE WHEN OCTET_LENGTH(CAST(legacy_raw AS CHAR))<=131072 THEN legacy_raw ELSE NULL END FROM clrs_staging.notifications FORCE INDEX(notifications_page_idx) WHERE uid=%s AND CAST(uid AS BINARY)=CAST(%s AS BINARY)"
MESSAGE_KINDS = {'chat.message.created.v1':'chat', 'meeting.message.created.v1':'meeting'}
HISTORICAL = {'gift':'chat','meeting':'meeting','post_comment':'post','comment_reply':'post','comment_like':'post','post_like':'post','post':'post'}

class NotificationUnavailable(Exception): pass

def _id(value):
    if type(value) is not str or value in ('.','..') or '/' in value or any(ord(c)<32 or ord(c)==127 or 0xD800<=ord(c)<=0xDFFF for c in value):raise RuntimeUnavailable()
    try:return _identifier(value)
    except RuntimeInvalidRequest:raise RuntimeUnavailable() from None

def _utc(value):
    if value is None:return None
    try:
        if re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z',value) is None:raise ValueError()
        parsed=datetime.strptime(value,'%Y-%m-%dT%H:%M:%S.%fZ')
        if parsed.year<1000:raise ValueError()
        return value
    except (TypeError,ValueError):raise RuntimeUnavailable() from None

def _key(value):
    if type(value) is not str or len(value)>193:raise RuntimeInvalidRequest()
    if value.startswith('e:') and re.fullmatch(r'[1-9][0-9]{0,18}',value[2:]) and int(value[2:])<=MAX_INTEGER:return 'event',int(value[2:])
    if value.startswith('n:'):
        try:return 'notice',_id(value[2:])
        except RuntimeUnavailable:pass
    raise RuntimeInvalidRequest()

class RuntimeNotificationsService:
    def __init__(self,store,key,*,meeting_authority=None,clock=time.time,target=None):
        if store is None or type(key) is not bytes or len(key)!=32:raise RuntimeUnavailable()
        self.store=store;self.clock=clock;self.authority=meeting_authority
        self.codec=OpaqueReferences(hmac.digest(key,b'clrs-native-notifications-cursor-v1\0','sha256'))
        self.target=target or self._target
    def _target(self,c,ex,uid,kind,resource):
        try:
            if kind=='chat':_pair(c,ex,uid,resource,readonly=True);return True
            if kind=='meeting':
                from runtime_meeting_chat import _state
                _state(self.store,c,ex,uid,resource,datetime.fromtimestamp(self.clock(),timezone.utc),readonly=True,authority=self.authority)
                return True
            if kind=='post':
                from runtime_social import _post
                _post(c,ex,resource);return True
            return False
        except (_ChatFailure,RuntimeRejected):return False
        except Exception as error:
            from runtime_meeting_join import _JoinFailure
            from runtime_social import SocialAccessDenied
            if isinstance(error,(_JoinFailure,SocialAccessDenied)):return False
            raise
    def _row(self,c,ex,uid,source,row,*,strict=False):
        if not isinstance(row,(tuple,list)) or len(row)!=(4 if source=='event' else 6):raise RuntimeUnavailable()
        kind=_id(row[1]);created=_utc(row[3]);target_kind=None;resource=None
        if source=='event':
            if type(row[0]) is not int or not 1<=row[0]<=MAX_INTEGER:raise RuntimeUnavailable()
            if kind not in MESSAGE_KINDS:return None
            raw=row[2]
            if type(raw) in (str,bytes):
                if len(raw)>8192:raise RuntimeUnavailable()
                raw=unique_json(raw.decode() if type(raw) is bytes else raw)
            target_kind=MESSAGE_KINDS[kind];key='chatId' if target_kind=='chat' else 'meetingId'
            if (type(raw) is not dict or set(raw)!={key,'messageId','sequence','senderUid','chatRevision','createdAt'}
                or type(raw['sequence']) is not int or not 1<=raw['sequence']<=MAX_INTEGER
                or created is None or raw['createdAt'] is None
                or type(raw['chatRevision']) is not int or not 0<=raw['chatRevision']<=MAX_INTEGER
                or target_kind=='chat' and raw['chatRevision']<raw['sequence']):raise RuntimeUnavailable()
            _id(raw['messageId']);_utc(raw['createdAt']);resource=_id(raw[key]);sender=_id(raw['senderUid'])
            if sender==uid:return None
            notice_id='e:'+str(row[0]);read=None
        else:
            notice_id='n:'+_id(row[0]);resource=None if row[2] is None else _id(row[2]);read=True if row[4] is not None else None
            _utc(row[4]);target_kind=HISTORICAL.get(kind)
            if read is None and row[5] is not None:
                raw=row[5]
                if type(raw) in (str,bytes):raw=unique_json(raw.decode() if type(raw) is bytes else raw)
                if type(raw) is not dict or type(raw.get('fields',{})) is not dict:raise RuntimeUnavailable()
                value=raw.get('fields',{}).get('read')
                if value is not None:
                    if type(value) is not dict or set(value)!={'booleanValue'} or type(value['booleanValue']) is not bool:raise RuntimeUnavailable()
                    read=value['booleanValue']
        if target_kind and resource and not self.target(c,ex,uid,target_kind,resource):target_kind=None;resource=None
        if not target_kind:resource=None
        if strict and target_kind is None:raise NotificationUnavailable()
        return {'id':notice_id,'type':kind,'targetKind':target_kind,'targetId':resource,'createdAt':created,'read':read}
    def _cursor(self,value,uid,limit):
        try:
            v=self.codec.open('cursor',value)
            if (set(v)!={'v','uid','purpose','limit','phase','before','cap','noticeCap','exp'} or v['v']!=1 or type(v['v']) is not int
                or v['uid']!=uid or v['purpose']!='native-notifications' or v['limit']!=limit or type(v['limit']) is not int
                or v['phase'] not in ('event','notice') or type(v['cap']) is not int or not 0<=v['cap']<=MAX_INTEGER
                or type(v['exp']) is not int or not int(self.clock())<v['exp']<=int(self.clock())+300):raise ValueError()
            for field in ('noticeCap','before'):
                if v['phase']=='event' and field=='before':
                    if type(v[field]) is not int or not 0<=v[field]<=v['cap']+1:raise ValueError()
                elif v[field] is not None:
                    if type(v[field]) is not list or len(v[field])!=2:raise ValueError()
                    _utc(v[field][0]);_id(v[field][1])
            return v
        except (ValueError,TypeError,LegacyInvalid,RuntimeUnavailable):raise RuntimeInvalidRequest() from None
    def page(self,identity,*,access_token,limit=30,cursor=None):
        if type(limit) is not int or not 1<=limit<=30:raise RuntimeInvalidRequest()
        def action(c,ex,uid):
            if cursor is not None:v=self._cursor(cursor,uid,limit)
            else:
                ex(EVENT+' ORDER BY event_id DESC LIMIT 1 FOR SHARE',(uid,uid));events=c.fetchall()
                if len(events)>1:raise RuntimeUnavailable()
                cap=events[0][0] if events else 0
                if type(cap) is not int or not 0<=cap<MAX_INTEGER:raise RuntimeUnavailable()
                ex(NOTICE+' ORDER BY created_at DESC,notification_id ASC LIMIT 1 FOR SHARE',(uid,uid));notices=c.fetchall()
                if len(notices)>1:raise RuntimeUnavailable()
                notice_cap=[_utc(notices[0][3]),_id(notices[0][0])] if notices else None
                v={'v':1,'uid':uid,'purpose':'native-notifications','limit':limit,'phase':'event','before':cap+1,'cap':cap,'noticeCap':notice_cap,'exp':int(self.clock())+300}
            count=min(limit,3);source=v['phase'];params=[uid,uid]
            if source=='event':
                ex(EVENT+' AND event_id<=%s AND event_id<%s ORDER BY event_id DESC LIMIT %s FOR SHARE',(*params,v['cap'],v['before'],count+1));rows=c.fetchall()
            else:
                sql=NOTICE
                for anchor,inclusive in ((v['noticeCap'],True),(v['before'],False)):
                    if anchor is None:continue
                    stamp,nid=anchor;op='>=' if inclusive else '>'
                    if stamp is None:sql+=' AND created_at IS NULL AND BINARY notification_id'+op+'BINARY %s';params.append(nid)
                    else:
                        sql+=' AND (created_at<%s OR (created_at=%s AND BINARY notification_id'+op+'BINARY %s) OR created_at IS NULL)'
                        params.extend((stamp[:-1].replace('T',' '),stamp[:-1].replace('T',' '),nid))
                ex(sql+' ORDER BY created_at DESC,notification_id ASC LIMIT %s FOR SHARE',(*params,count+1));rows=c.fetchall()
            if len(rows)>count+1:raise RuntimeUnavailable()
            result={'kind':'native-notifications','items':[],'nextCursor':None}
            emitted=[]
            for row in rows[:count]:
                item=self._row(c,ex,uid,source,row)
                if item is not None:emitted.append(item)
            if rows:
                v['before']=rows[min(len(rows),count)-1][0] if source=='event' else [rows[min(len(rows),count)-1][3],rows[min(len(rows),count)-1][0]]
            more=len(rows)>count
            if not more and source=='event' and v['noticeCap'] is not None:v['phase']='notice';v['before']=None;more=True
            if more:result['nextCursor']=self.codec.seal('cursor',v)
            result['items']=emitted
            if len(canonical_json(result))>65536:raise RuntimeUnavailable()
            return result
        return self.store.read_authenticated(identity,action,access_token=access_token)
    def one(self,identity,notice_id,*,access_token):
        source,value=_key(notice_id)
        def action(c,ex,uid):
            ex((EVENT+' AND event_id=%s LIMIT 1 FOR SHARE') if source=='event' else (NOTICE+' AND notification_id=%s AND CAST(notification_id AS BINARY)=CAST(%s AS BINARY) LIMIT 1 FOR SHARE'),(uid,uid,value) if source=='event' else (uid,uid,value,value))
            rows=c.fetchall()
            if len(rows)>1:raise RuntimeUnavailable()
            if not rows:raise NotificationUnavailable()
            item=self._row(c,ex,uid,source,rows[0],strict=True)
            if item is None:raise NotificationUnavailable()
            return item
        return self.store.read_authenticated(identity,action,access_token=access_token)

class RuntimeNotificationsHttp:
    def __init__(self,env,store,*,meeting_authority=None):
        self.enabled=env.get('CLRS_RUNTIME_WRITES_ENABLED')=='1' and env.get('CLRS_RUNTIME_MEMBERSHIP_AUTHORITY')=='canonical-current-v1'
        self.service=None
        try:self.service=RuntimeNotificationsService(store,decode_base64(env.get('CLRS_LEGACY_READ_CURSOR_KEY_B64'),max_bytes=32),meeting_authority=meeting_authority)
        except Exception:pass
    def dispatch(self,environ,*,native_service=None,native_configured=False):
        from runtime_http import RuntimeHttpReply
        path=environ.get('PATH_INFO','');prefix='/v1/runtime/me/notifications'
        if path!=prefix and not path.startswith(prefix+'/'):return None
        try:
            if not self.enabled:return RuntimeHttpReply('404 Not Found',{'error':'not_found'})
            if environ.get('REQUEST_METHOD')!='GET':return RuntimeHttpReply('405 Method Not Allowed',{'error':'method_not_allowed'})
            if environ.get('HTTP_TRANSFER_ENCODING') or environ.get('CONTENT_LENGTH','') not in ('','0'):raise RuntimeInvalidRequest()
            raw=environ.get('QUERY_STRING','')
            if type(raw) is not str or len(raw)>4096 or not raw.isascii() or re.search(r'%(?![a-fA-F0-9]{2})',raw):raise RuntimeInvalidRequest()
            try:pairs=parse_qsl(raw,keep_blank_values=True,strict_parsing=True,max_num_fields=2)
            except ValueError:raise RuntimeInvalidRequest() from None
            query=dict(pairs)
            if len(query)!=len(pairs) or set(query)-{'limit','cursor'} or path!=prefix and query:raise RuntimeInvalidRequest()
            token=environ.get('HTTP_AUTHORIZATION','')
            if type(token) is not str or not token.startswith('Bearer na1.') or len(token)>135 or any(c.isspace() for c in token[7:]):raise NativeRejected()
            if not native_configured or native_service is None or self.service is None:raise RuntimeUnavailable()
            access=token[7:];identity=native_service.authorize(access,peer=environ.get('REMOTE_ADDR',''))
            if type(identity) is not NativeIdentity:raise RuntimeUnavailable()
            if path!=prefix:return RuntimeHttpReply('200 OK',self.service.one(identity,path[len(prefix)+1:],access_token=access))
            limit=query.get('limit','30')
            if not re.fullmatch(r'[1-9][0-9]?',limit) or 'cursor' in query and not query['cursor']:raise RuntimeInvalidRequest()
            return RuntimeHttpReply('200 OK',self.service.page(identity,access_token=access,limit=int(limit),cursor=query.get('cursor')))
        except RuntimeInvalidRequest:return RuntimeHttpReply('400 Bad Request',{'error':'invalid_request'})
        except NotificationUnavailable:return RuntimeHttpReply('404 Not Found',{'error':'notification_unavailable'})
        except (NativeRejected,RuntimeRejected):return RuntimeHttpReply('401 Unauthorized',{'error':'unauthorized'},authenticate=True)
        except NativeRateLimited:return RuntimeHttpReply('429 Too Many Requests',{'error':'rate_limited'},retry=True)
        except Exception:return RuntimeHttpReply('503 Service Unavailable',{'error':'service_unavailable'})

def create_runtime_notifications_http(env,store,*,meeting_authority=None):
    return RuntimeNotificationsHttp(env,store,meeting_authority=meeting_authority)
