"""Native inventory/purchase/gifting routes with original-only receipt lookup."""
import re
import threading
from typing import NamedTuple
from urllib.parse import parse_qsl
from native_auth import NativeRejected, NativeRateLimited
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, RuntimeConflict, RuntimeCommitUnknown
from runtime_gifts import RuntimeGiftService, GiftAccessDenied, OPS

class GiftReply(NamedTuple):
    status:str
    payload:dict
    authenticate:bool=False
    retry:bool=False

class RuntimeGiftsHttp:
    def __init__(self,env,store):
        self.enabled=env.get('CLRS_RUNTIME_GIFTS_ENABLED')=='1';self.store=store
        self.service=None;self.lock=threading.Lock()

    def dispatch(self,environ,*,native_service=None,native_configured=False):
        path=environ.get('PATH_INFO','')
        if not path.startswith('/v1/runtime/gifts/'):return None
        if not self.enabled:return GiftReply('404 Not Found',{'error':'not_found'})
        try:
            with self.lock:
                if self.service is None:self.service=RuntimeGiftService(self.store)
            mine=path=='/v1/runtime/gifts/mine';action=path=='/v1/runtime/gifts/actions'
            lookup=re.fullmatch(r'/v1/runtime/gifts/operations/(gift\.(?:buy|send)\.v1)/([0-9a-f-]{36})',path)
            if not(mine or action or lookup):return GiftReply('404 Not Found',{'error':'not_found'})
            if environ.get('REQUEST_METHOD')!=('POST' if action else 'GET'):return GiftReply('405 Method Not Allowed',{'error':'method_not_allowed'})
            raw=environ.get('QUERY_STRING','')
            if type(raw) is not str or len(raw)>256 or re.search(r'%(?![0-9a-fA-F]{2})',raw):raise RuntimeInvalidRequest()
            try:pairs=parse_qsl(raw,keep_blank_values=True,strict_parsing=True,max_num_fields=1)
            except ValueError:raise RuntimeInvalidRequest() from None
            query=dict(pairs)
            if len(pairs)!=len(query) or not lookup and query:raise RuntimeInvalidRequest()
            if not action and (environ.get('HTTP_TRANSFER_ENCODING') or environ.get('CONTENT_LENGTH','') not in ('','0')):raise RuntimeInvalidRequest()
            header=environ.get('HTTP_AUTHORIZATION','')
            if type(header) is not str or not header.startswith('Bearer na1.') or len(header)>135 or any(c.isspace() for c in header[7:]):raise NativeRejected()
            if not native_configured or native_service is None:raise RuntimeUnavailable()
            token=header[7:];identity=native_service.authorize(token,peer=environ.get('REMOTE_ADDR',''))
            if mine:return GiftReply('200 OK',self.service.mine(identity,access_token=token))
            from runtime_http import _body,_UUID
            if lookup:
                if not _UUID.fullmatch(lookup[2]) or set(query)!={'requestHash'} or not re.fullmatch(r'[0-9a-f]{64}',query['requestHash']):raise RuntimeInvalidRequest()
                result=self.store.lookup(identity,lookup[1],lookup[2],access_token=token,request_hash=bytes.fromhex(query['requestHash']))
            else:
                body=_body(environ)
                if type(body) is not dict or set(body)!={'operationId','payload'} or type(body['operationId']) is not str or not _UUID.fullmatch(body['operationId']):raise RuntimeInvalidRequest()
                result=self.service.perform(identity,body['operationId'],body['payload'],access_token=token)
            status={200:'200 OK',201:'201 Created',409:'409 Conflict'}.get(result.status)
            if status is None:raise RuntimeUnavailable()
            return GiftReply(status,result.payload)
        except GiftAccessDenied:return GiftReply('403 Forbidden',{'error':'gift_access_denied'})
        except (NativeRejected,RuntimeRejected):return GiftReply('401 Unauthorized',{'error':'unauthorized'},authenticate=True)
        except RuntimeInvalidRequest:return GiftReply('400 Bad Request',{'error':'invalid_request'})
        except RuntimeConflict:return GiftReply('409 Conflict',{'error':'operation_conflict'})
        except RuntimeCommitUnknown:return GiftReply('503 Service Unavailable',{'error':'outcome_unknown'})
        except NativeRateLimited:return GiftReply('429 Too Many Requests',{'error':'rate_limited'},retry=True)
        except Exception:return GiftReply('503 Service Unavailable',{'error':'service_unavailable'})
