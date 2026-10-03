"""Fixed native social routes, behind the existing guard and native session."""
import re
import threading
from typing import NamedTuple
from urllib.parse import parse_qsl

from native_auth import NativeRejected, NativeRateLimited
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, RuntimeConflict, RuntimeCommitUnknown
from runtime_social import RuntimeSocialService, SocialAccessDenied, OPS, ident


class SocialReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


class RuntimeSocialHttp:
    def __init__(self,env,store):
        self.enabled=env.get('CLRS_RUNTIME_SOCIAL_ENABLED')=='1'
        self.env=dict(env); self.store=store; self.service=None
        self._lock=threading.Lock()

    def dispatch(self,environ,*,native_service=None,native_configured=False):
        path=environ.get('PATH_INFO','')
        if not path.startswith('/v1/runtime/social/'): return None
        if not self.enabled: return SocialReply('404 Not Found',{'error':'not_found'})
        try:
            with self._lock:
                if self.service is None:
                    self.service=RuntimeSocialService.from_env(self.store,self.env)
            if self.service is None: raise RuntimeUnavailable()
            match=re.fullmatch(r'/v1/runtime/social/posts/([^/]+)/comments',path)
            lookup=re.fullmatch(r'/v1/runtime/social/operations/([^/]+)/([0-9a-f-]{36})',path)
            feed=path=='/v1/runtime/social/feed'; action=path=='/v1/runtime/social/actions'
            if not (feed or action or match or lookup and lookup[1] in OPS):
                return SocialReply('404 Not Found',{'error':'not_found'})
            expected='POST' if action else 'GET'
            if environ.get('REQUEST_METHOD')!=expected:
                return SocialReply('405 Method Not Allowed',{'error':'method_not_allowed'})
            raw=environ.get('QUERY_STRING','')
            if type(raw) is not str or len(raw)>8192 or re.search(r'%(?![0-9a-fA-F]{2})',raw): raise RuntimeInvalidRequest()
            try: pairs=parse_qsl(raw,keep_blank_values=True,strict_parsing=True,encoding='utf8',errors='strict',max_num_fields=3)
            except (ValueError,UnicodeError): raise RuntimeInvalidRequest() from None
            options=dict(pairs)
            if len(options)!=len(pairs): raise RuntimeInvalidRequest()
            if action and options: raise RuntimeInvalidRequest()
            if not action and (environ.get('HTTP_TRANSFER_ENCODING') or environ.get('CONTENT_LENGTH','') not in ('','0')): raise RuntimeInvalidRequest()
            header=environ.get('HTTP_AUTHORIZATION','')
            if type(header) is not str or not header.startswith('Bearer na1.') or len(header)>135 or any(c.isspace() for c in header[7:]): raise NativeRejected()
            if not native_configured or native_service is None: raise RuntimeUnavailable()
            token=header[7:]; identity=native_service.authorize(token, peer=environ.get('REMOTE_ADDR',''))
            if feed:
                if set(options)-{'limit','cursor','wallUid'}: raise RuntimeInvalidRequest()
                limit=options.get('limit','10')
                if not re.fullmatch(r'[1-9]|10',limit): raise RuntimeInvalidRequest()
                result=self.service.feed(identity,access_token=token,limit=int(limit),cursor=options.get('cursor'),wall_uid=options.get('wallUid'))
            elif match:
                if set(options)-{'cursor'}: raise RuntimeInvalidRequest()
                resource=match[1].encode('latin1').decode('utf8'); ident(resource)
                result=self.service.comments(identity,resource,access_token=token,cursor=options.get('cursor'))
            elif lookup:
                from runtime_http import _UUID
                if not _UUID.fullmatch(lookup[2]) or set(options)!={'requestHash'} or not re.fullmatch(r'[0-9a-f]{64}',options['requestHash']): raise RuntimeInvalidRequest()
                outcome=self.store.lookup(identity,lookup[1],lookup[2],access_token=token,request_hash=bytes.fromhex(options['requestHash']))
                return SocialReply(f'{outcome.status} OK',outcome.payload)
            else:
                from runtime_http import _body, _UUID
                value=_body(environ)
                if type(value) is not dict or set(value)!={'operationId','payload'} or not isinstance(value['operationId'],str) or not _UUID.fullmatch(value['operationId']): raise RuntimeInvalidRequest()
                outcome=self.service.perform(identity,value['operationId'],value['payload'],access_token=token)
                return SocialReply('201 Created' if outcome.status==201 else '200 OK',outcome.payload)
            return SocialReply('200 OK',result)
        except SocialAccessDenied: return SocialReply('403 Forbidden',{'error':'social_access_denied'})
        except (NativeRejected,RuntimeRejected): return SocialReply('401 Unauthorized',{'error':'unauthorized'},authenticate=True)
        except (RuntimeInvalidRequest,UnicodeError): return SocialReply('400 Bad Request',{'error':'invalid_request'})
        except RuntimeConflict: return SocialReply('409 Conflict',{'error':'operation_conflict'})
        except RuntimeCommitUnknown: return SocialReply('503 Service Unavailable',{'error':'outcome_unknown'})
        except NativeRateLimited: return SocialReply('429 Too Many Requests',{'error':'rate_limited'},retry=True)
        except Exception: return SocialReply('503 Service Unavailable',{'error':'service_unavailable'})
