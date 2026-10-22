"""Current native sessions only; neither list owner nor visitor comes from input."""
import re
import threading
from typing import NamedTuple
from urllib.parse import parse_qsl

from native_auth import NativeRejected, NativeRateLimited
from runtime_contacts import RuntimeContactsService, ContactUnavailable, OPERATION
from runtime_mutations import (RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable,
                              RuntimeConflict, RuntimeCommitUnknown)


class ContactReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


class RuntimeContactsHttp:
    def __init__(self, env, store):
        self.enabled = (env.get('CLRS_RUNTIME_WRITES_ENABLED') == '1'
                        and env.get('CLRS_RUNTIME_MEMBERSHIP_AUTHORITY') == 'canonical-current-v1')
        self.env = dict(env); self.store = store; self.service = None
        self.lock = threading.Lock()

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        path = environ.get('PATH_INFO', '')
        base = '/v1/runtime/contacts'
        if path != base and not path.startswith(base+'/'): return None
        if not self.enabled: return ContactReply('404 Not Found', {'error':'not_found'})
        try:
            from runtime_http import _body, _UUID
            action = path == base+'/actions'
            lookup = re.fullmatch(base+r'/operations/contacts\.change\.v1/([0-9a-f-]{36})', path)
            person = re.fullmatch(base+'/people/([^/]{1,191})', path)
            if path != base and not action and not person and not lookup:
                return ContactReply('404 Not Found', {'error':'not_found'})
            if environ.get('REQUEST_METHOD') != ('POST' if action else 'GET'):
                return ContactReply('405 Method Not Allowed', {'error':'method_not_allowed'})
            query = environ.get('QUERY_STRING', '')
            if type(query) is not str or len(query)>4096 or re.search(r'%(?![0-9a-fA-F]{2})',query): raise RuntimeInvalidRequest()
            pairs = parse_qsl(query, keep_blank_values=True, strict_parsing=True, errors='strict', max_num_fields=3)
            options = dict(pairs)
            if len(options) != len(pairs): raise RuntimeInvalidRequest()
            if not action and (environ.get('HTTP_TRANSFER_ENCODING') or environ.get('CONTENT_LENGTH','') not in ('','0')):
                raise RuntimeInvalidRequest()
            header = environ.get('HTTP_AUTHORIZATION','')
            if type(header) is not str or not header.startswith('Bearer na1.') or len(header)>135 or any(c.isspace() for c in header[7:]):
                raise NativeRejected()
            if not native_configured or native_service is None: raise RuntimeUnavailable()
            token = header[7:]; identity = native_service.authorize(token, peer=environ.get('REMOTE_ADDR',''))
            with self.lock:
                if self.service is None: self.service = RuntimeContactsService.from_env(self.store,self.env)
            if action:
                if options: raise RuntimeInvalidRequest()
                body = _body(environ)
                if (type(body) is not dict or set(body) != {'operationId','payload'}
                        or type(body['operationId']) is not str or not _UUID.fullmatch(body['operationId'])):
                    raise RuntimeInvalidRequest()
                result = self.service.perform(identity,body['operationId'],body['payload'],access_token=token)
                return ContactReply({200:'200 OK',404:'404 Not Found',409:'409 Conflict'}[result.status],result.payload)
            if lookup:
                if (not _UUID.fullmatch(lookup[1]) or set(options) != {'requestHash'}
                        or not re.fullmatch(r'[0-9a-f]{64}',options['requestHash'])): raise RuntimeInvalidRequest()
                result = self.store.lookup(identity,OPERATION,lookup[1],access_token=token,
                                           request_hash=bytes.fromhex(options['requestHash']))
                return ContactReply({200:'200 OK',404:'404 Not Found',409:'409 Conflict'}[result.status],result.payload)
            if person:
                if options: raise RuntimeInvalidRequest()
                target = person[1].encode('latin1').decode('utf8')
                result = self.service.relationship(identity,target,access_token=token)
            else:
                if set(options)-{'kind','cursor','limit'}: raise RuntimeInvalidRequest()
                limit = options.get('limit','20')
                if not re.fullmatch(r'[1-9]|[12][0-9]|30',limit): raise RuntimeInvalidRequest()
                result = self.service.list(identity,options.get('kind','friends'),limit=int(limit),
                    cursor=options.get('cursor'),access_token=token)
            return ContactReply('200 OK',result)
        except ContactUnavailable: return ContactReply('404 Not Found',{'error':'not_found'})
        except (RuntimeInvalidRequest,ValueError,UnicodeError): return ContactReply('400 Bad Request',{'error':'invalid_request'})
        except (NativeRejected,RuntimeRejected): return ContactReply('401 Unauthorized',{'error':'unauthorized'},True)
        except NativeRateLimited: return ContactReply('429 Too Many Requests',{'error':'rate_limited'},retry=True)
        except RuntimeConflict: return ContactReply('409 Conflict',{'error':'operation_conflict'})
        except RuntimeCommitUnknown: return ContactReply('503 Service Unavailable',{'error':'outcome_unknown'})
        except Exception: return ContactReply('503 Service Unavailable',{'error':'service_unavailable'})
