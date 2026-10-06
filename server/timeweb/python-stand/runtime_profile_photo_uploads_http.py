"""Unmounted upload HTTP adapter. Same native bearer/store; writer default closed."""
import re

from native_auth import NativeRejected, NativeUnavailable, NativeRateLimited
from native_sessions import NativeIdentity
from runtime_http import RuntimeHttpReply, _body, _UUID
from runtime_mutations import (RuntimeInvalidRequest, RuntimeRejected, RuntimeConflict,
    RuntimeCommitUnknown, RuntimeUnavailable)
from runtime_profile_photo_uploads import (PREPARE_OPERATION, COMMIT_OPERATION,
    PhotoUploadTargetRejected)


class RuntimeProfilePhotoUploadsHttp:
    def __init__(self, env, *, service=None):
        self._enabled = (env.get("CLRS_RUNTIME_WRITES_ENABLED") == "1"
            and env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") == "canonical-current-v1")
        self._service = service  # No factory, credential lookup or activation.

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        path = environ.get("PATH_INFO", ""); query = environ.get("QUERY_STRING", "")
        if not isinstance(path, str) or len(path) > 1000: return None
        operation = {"/v1/runtime/profile/photos/prepare": PREPARE_OPERATION,
            "/v1/runtime/profile/photos/commit": COMMIT_OPERATION}.get(path)
        lease = re.fullmatch(r"/v1/runtime/profile/photos/uploads/(tw-profile-photo-[0-9a-f]{64})/lease", path)
        lookup = re.fullmatch(r"/v1/runtime/operations/(profile\.photo\.(?:prepare|commit)\.v1)/([^/]{36})", path)
        availability = path == "/v1/runtime/profile/photos/upload-availability"
        if operation is None and not lease and not lookup and not availability: return None
        if not self._enabled: return RuntimeHttpReply("404 Not Found", {"error": "not_found"})
        method = "GET" if lease or lookup or availability else "POST"
        if environ.get("REQUEST_METHOD") != method: return RuntimeHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        try:
            if (not isinstance(query, str) or len(query) > 200 or method == "GET" and
                    (environ.get("HTTP_TRANSFER_ENCODING") or environ.get("CONTENT_LENGTH", "") not in ("", "0"))):
                raise RuntimeInvalidRequest()
            if lookup:
                if _UUID.fullmatch(lookup[2]) is None or re.fullmatch(r"requestHash=[0-9a-f]{64}", query) is None: raise RuntimeInvalidRequest()
            elif lease:
                if not query.startswith("prepareOperationId=") or _UUID.fullmatch(query[19:]) is None: raise RuntimeInvalidRequest()
            elif query: raise RuntimeInvalidRequest()
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (not native_configured or not isinstance(header, str) or not header.startswith("Bearer na1.")
                    or len(header) > 135 or any(c.isspace() for c in header[7:])): raise NativeRejected()
            if native_service is None or self._service is None: raise NativeUnavailable()
            token = header[7:]; identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
            if type(identity) is not NativeIdentity: raise NativeUnavailable()
            if availability:
                return RuntimeHttpReply("200 OK", self._service.upload_availability(identity, access_token=token))
            if lease:
                result = self._service.upload_lease(identity, lease[1], query[19:], access_token=token)
                return RuntimeHttpReply("200 OK", result)
            if lookup:
                outcome = self._service._store.lookup(identity, lookup[1], lookup[2], access_token=token, request_hash=bytes.fromhex(query[12:]))
            else:
                body = _body(environ)
                if (type(body) is not dict or not isinstance(body.get("operationId"), str)
                        or _UUID.fullmatch(body["operationId"]) is None): raise RuntimeInvalidRequest()
                payload = {key: value for key, value in body.items() if key != "operationId"}
                call = self._service.prepare if operation == PREPARE_OPERATION else self._service.commit
                outcome = call(identity, body["operationId"], payload, access_token=token)
            status = {200: "200 OK", 201: "201 Created", 404: "404 Not Found", 409: "409 Conflict"}.get(outcome.status)
            if status is None: raise RuntimeUnavailable()
            return RuntimeHttpReply(status, outcome.payload)
        except RuntimeInvalidRequest: return RuntimeHttpReply("400 Bad Request", {"error": "invalid_request"})
        except PhotoUploadTargetRejected: return RuntimeHttpReply("404 Not Found", {"error": "photo_unavailable"})
        except (NativeRejected, RuntimeRejected): return RuntimeHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
        except RuntimeConflict: return RuntimeHttpReply("409 Conflict", {"error": "operation_conflict"})
        except RuntimeCommitUnknown: return RuntimeHttpReply("503 Service Unavailable", {"error": "outcome_unknown"})
        except NativeRateLimited: return RuntimeHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except Exception: return RuntimeHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
