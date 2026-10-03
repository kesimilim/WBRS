"""Native-authorized token routes; no Firebase principal or token response."""
import re
from native_auth import NativeRejected,NativeUnavailable,NativeRateLimited
from native_sessions import NativeIdentity
from runtime_http import RuntimeHttpReply,_body,_UUID
from runtime_mutations import RuntimeInvalidRequest,RuntimeRejected,RuntimeConflict,RuntimeUnavailable,RuntimeCommitUnknown
from runtime_push import RuntimePushService,create_push_codec,REGISTER,REVOKE

class RuntimePushHttp:
    def __init__(self,env,*,service=None):
        self.env=dict(env);self.service=service
    def handle(self,environ,*,native_service,native_configured):
        path=environ.get('PATH_INFO','');lookup=re.fullmatch(r'/v1/runtime/operations/(push\.(?:register|revoke)\.v1)/([^/]+)',path)
        operation={'/v1/runtime/me/push-token/register':REGISTER,'/v1/runtime/me/push-token/revoke':REVOKE}.get(path)
        if operation is None and lookup is None:return None
        if self.env.get('CLRS_RUNTIME_WRITES_ENABLED')!='1' or self.env.get('CLRS_RUNTIME_MEMBERSHIP_AUTHORITY')!='canonical-current-v1':return RuntimeHttpReply('404 Not Found',{'error':'not_found'})
        try:
            if environ.get('REQUEST_METHOD')!=('GET' if lookup else 'POST'):raise RuntimeInvalidRequest()
            query=environ.get('QUERY_STRING','')
            if lookup:
                if _UUID.fullmatch(lookup[2]) is None or re.fullmatch(r'requestHash=[a-f0-9]{64}',query) is None or environ.get('CONTENT_LENGTH','') not in ('','0') or environ.get('HTTP_TRANSFER_ENCODING'):raise RuntimeInvalidRequest()
            elif query:raise RuntimeInvalidRequest()
            header=environ.get('HTTP_AUTHORIZATION','')
            if not native_configured or type(header) is not str or not header.startswith('Bearer na1.') or len(header)>135 or any(c.isspace() for c in header[7:]):raise NativeRejected()
            if native_service is None or self.service is None:raise NativeUnavailable()
            access=header[7:];identity=native_service.authorize(access,peer=environ.get('REMOTE_ADDR',''))
            if type(identity) is not NativeIdentity:raise NativeUnavailable()
            if lookup:outcome=self.service.store.lookup(identity,lookup[1],lookup[2],access_token=access,request_hash=bytes.fromhex(query[12:]))
            else:
                body=_body(environ)
                if set(body)!=( {'operationId','token'} if operation==REGISTER else {'operationId'}) or type(body['operationId']) is not str or _UUID.fullmatch(body['operationId']) is None:raise RuntimeInvalidRequest()
                outcome=(self.service.register(identity,body['operationId'],body['token'],access_token=access) if operation==REGISTER else self.service.revoke(identity,body['operationId'],access_token=access))
            status={200:'200 OK',409:'409 Conflict'}.get(outcome.status)
            if status is None:raise RuntimeUnavailable()
            return RuntimeHttpReply(status,outcome.payload)
        except RuntimeInvalidRequest:return RuntimeHttpReply('400 Bad Request',{'error':'invalid_request'})
        except (NativeRejected,RuntimeRejected):return RuntimeHttpReply('401 Unauthorized',{'error':'unauthorized'},authenticate=True)
        except RuntimeConflict:return RuntimeHttpReply('409 Conflict',{'error':'operation_conflict'})
        except RuntimeCommitUnknown:return RuntimeHttpReply('503 Service Unavailable',{'error':'outcome_unknown'})
        except NativeRateLimited:return RuntimeHttpReply('429 Too Many Requests',{'error':'rate_limited'},retry=True)
        except Exception:return RuntimeHttpReply('503 Service Unavailable',{'error':'service_unavailable'})

def create_runtime_push_http(env,store):
    codec=create_push_codec(env)
    if codec is None or store is None:return RuntimePushHttp(env)
    return RuntimePushHttp(env,service=RuntimePushService(store,codec))
