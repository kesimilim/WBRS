"""Strict default-off HTTP mount for native email registration/reset.

Called only after the existing operator preview guard. Original operation tokens
are POST body data, never query parameters/path/access logs. No credential body
is echoed or logged; no implicit retries or Firebase-token fallback.
"""
from __future__ import annotations

import re
from typing import NamedTuple

from native_auth import NativeRateLimited
from native_credentials import unique_json
from native_auth_lifecycle import (NativeAuthLifecycle, LifecycleInvalid, LifecycleRefused)


class LifecycleHttpReply(NamedTuple):
    status: str
    payload: dict
    retry: bool = False


_ROUTES = {'/v1/auth/password-reset/request': ('password-reset.v1', 'request'),
           '/v1/auth/password-reset/complete': ('password-reset.v1', 'complete'),
           '/v1/auth/register-email/request': ('register-email.v1', 'request'),
           '/v1/auth/register-email/complete': ('register-email.v1', 'complete'),
           '/v1/auth/operations/lookup': (None, 'lookup')}


def _body(environ):
    length = environ.get('CONTENT_LENGTH', '')
    if (environ.get('QUERY_STRING') or environ.get('HTTP_TRANSFER_ENCODING')
            or not isinstance(length, str) or re.fullmatch('[1-9][0-9]{0,3}', length) is None
            or not 1 <= int(length) <= 8192
            or environ.get('CONTENT_TYPE', '').lower() not in
                ('application/json', 'application/json; charset=utf-8')):
        raise LifecycleInvalid()
    try:
        raw = environ['wsgi.input'].read(int(length))
        if not isinstance(raw, bytes) or len(raw) != int(length):
            raise LifecycleInvalid()
        value = unique_json(raw.decode('utf-8'))
        if type(value) is not dict:
            raise LifecycleInvalid()
        return value
    except Exception:
        raise LifecycleInvalid() from None


class NativeAuthLifecycleHttp:
    def __init__(self, env, native_service, *, service_factory=NativeAuthLifecycle.from_env):
        self._enabled = env.get('CLRS_NATIVE_AUTH_LIFECYCLE_ENABLED') == '1'
        self._registration = env.get('CLRS_NATIVE_REGISTRATION_ENABLED') == '1'
        self._service = None
        if self._enabled:
            try:
                self._service = service_factory(env, native_service)
            except Exception:
                pass

    def close(self):
        if self._service is not None:
            self._service.close()
            self._service = None

    def dispatch(self, environ):
        route = _ROUTES.get(environ.get('PATH_INFO', ''))
        if route is None:
            return None
        purpose, operation = route
        if not self._enabled or (purpose == 'register-email.v1' and not self._registration):
            return LifecycleHttpReply('404 Not Found', {'error': 'not_found'})
        if environ.get('REQUEST_METHOD') != 'POST':
            return LifecycleHttpReply('405 Method Not Allowed', {'error': 'method_not_allowed'})
        try:
            body = _body(environ)
            if self._service is None:
                return LifecycleHttpReply('503 Service Unavailable', {'error': 'service_unavailable'})
            peer = environ.get('REMOTE_ADDR', '')
            result = (self._service.lookup(body, peer=peer) if operation == 'lookup'
                      else getattr(self._service, operation)(purpose, body, peer=peer))
            token = self._service.operation_token(result.fingerprint)
            if result.state == 'completed' and result.outcome is not None:
                status = {200: '200 OK', 202: '202 Accepted', 400: '400 Bad Request'}[result.outcome.status]
                return LifecycleHttpReply(status, {**result.outcome.result, 'operationToken': token})
            # Absence/pending is not retry authority, even after a timeout.
            return LifecycleHttpReply('503 Service Unavailable',
                {'error': 'outcome_unknown', 'operationToken': token})
        except LifecycleInvalid:
            return LifecycleHttpReply('400 Bad Request', {'error': 'invalid_request'})
        except LifecycleRefused:
            return LifecycleHttpReply('400 Bad Request', {'status': 'refused'})
        except NativeRateLimited:
            return LifecycleHttpReply('429 Too Many Requests', {'error': 'rate_limited'}, retry=True)
        except Exception:
            return LifecycleHttpReply('503 Service Unavailable', {'error': 'service_unavailable'})
