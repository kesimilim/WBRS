"""Default-off native-only HTTP routes for current-authority reads/mutations.

Mounted after the existing operator preview guard. No Firebase-token fallback,
arbitrary paths/SQL or automatic retry of a transaction with unknown commit.
"""
from __future__ import annotations

import re
from typing import NamedTuple

from native_auth import NativeRejected, NativeUnavailable, NativeRateLimited
from native_credentials import unique_json, CredentialUnavailable
from native_sessions import NativeIdentity
from runtime_mutations import (RuntimeMutationStore, RuntimeInvalidRequest,
    RuntimeRejected, RuntimeConflict, RuntimeUnavailable, RuntimeCommitUnknown)
from runtime_chat import RuntimeChatService
from runtime_personal_chat import RuntimePersonalChatService, PersonalChatAccessRejected
from runtime_profile import RuntimeProfileService, ProfileEditInvalid
from runtime_meeting_create import RuntimeMeetingCreateService, MeetingAccessRejected
from runtime_meeting_join import RuntimeMeetingJoinService
from runtime_meeting_membership import RuntimeMeetingMembershipService
from runtime_meeting_chat import RuntimeMeetingChatService
from runtime_read_http import RuntimeReadHttp
from runtime_initial_profile import RuntimeInitialProfileService, InitialProfileAccessRejected
from runtime_profile_photo_uploads import RuntimeProfilePhotoUploadsService


_OPERATIONS = frozenset({"profile.finish-registration.v1", "chat.send-text.v1", "chat.mark-read.v1", "chat.open-personal.v1", "meeting.create.v1", "meeting.join.v1", "meeting.leave.v1", "meeting.kick.v1", "meeting.send-text.v1", "profile.edit.v1", "profile.complete-test.v1", "profile.edit-geography.v1"})
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
_MAX_BODY = 65536


class RuntimeHttpReply(NamedTuple):
    status: str
    payload: dict
    authenticate: bool = False
    retry: bool = False


def _route(path):
    if not isinstance(path, str) or len(path) > 1000:
        return None
    try:
        path = path.encode("latin-1").decode("utf-8")
    except UnicodeError:
        return None
    if path == "/v1/runtime/me/registration":
        return "profile.finish-registration.v1", None, None
    if path == "/v1/runtime/me/profile":
        return "profile.edit.v1", None, None
    if path == "/v1/runtime/me/full-profile":
        return "profile.full-read.v1", None, None
    if path == "/v1/runtime/me/temperament":
        return "profile.complete-test.v1", None, None
    if path == "/v1/runtime/me/geography":
        return "profile.edit-geography.v1", None, None
    if path == "/v1/runtime/meetings/leave":
        return "meeting.leave.v1", None, None
    if path == "/v1/runtime/meetings/kick":
        return "meeting.kick.v1", None, None
    if path == "/v1/runtime/meetings/join":
        return "meeting.join.v1", None, None
    if path == "/v1/runtime/meetings":
        return "meeting.create.v1", None, None
    if path == "/v1/runtime/personal-chats":
        return "chat.open-personal.v1", None, None
    match = re.fullmatch(r"/v1/runtime/meetings/([^/]{1,191})/messages", path)
    if match:
        resource = match[1]
        if any(ord(c) < 32 or ord(c) == 127 for c in resource):
            return None
        return "meeting.send-text.v1", resource, None
    match = re.fullmatch(r"/v1/runtime/chats/([^/]{1,191})/(messages|read)", path)
    if match:
        resource, suffix = match.groups()
        if any(ord(c) < 32 or ord(c) == 127 for c in resource):
            return None
        return ("chat.send-text.v1" if suffix == "messages" else "chat.mark-read.v1"), resource, None
    match = re.fullmatch(r"/v1/runtime/operations/([^/]+)/([^/]+)", path)
    if match and match[1] in _OPERATIONS and _UUID.fullmatch(match[2]):
        return "reconcile", match[1], match[2]
    return None


def _body(environ):
    length = environ.get("CONTENT_LENGTH", "")
    if (environ.get("HTTP_TRANSFER_ENCODING") or not isinstance(length, str)
            or re.fullmatch(r"[1-9][0-9]{0,4}", length) is None
            or not 1 <= int(length) <= _MAX_BODY
            or environ.get("CONTENT_TYPE", "").lower() not in {
                "application/json", "application/json; charset=utf-8"}):
        raise RuntimeInvalidRequest()
    try:
        raw = environ["wsgi.input"].read(int(length))
        if not isinstance(raw, bytes) or len(raw) != int(length):
            raise RuntimeInvalidRequest()
        return unique_json(raw.decode("utf-8"))
    except (KeyError, OSError, UnicodeError, CredentialUnavailable):
        raise RuntimeInvalidRequest() from None


def _create(env):
    store = RuntimeMutationStore.from_env(env)
    from native_profile_photo_factory import create_native_photo_writer
    from runtime_profile_photo_uploads_http import RuntimeProfilePhotoUploadsHttp
    # The initial-profile and upload routes share this exact store/photo core.
    initial = photos = writer = None
    if env.get("CLRS_RUNTIME_PERMISSION_MODEL") == "provider-database-v1":
        writer = create_native_photo_writer(env)
        photos = RuntimeProfilePhotoUploadsService(store, writer=writer)
        initial = RuntimeInitialProfileService(store, photos=photos)
    uploads = (RuntimeProfilePhotoUploadsHttp(env, service=photos if writer is not None else None)
               if env.get("CLRS_RUNTIME_NATIVE_PHOTO_UPLOADS_ENABLED") == "1" else None)
    return store, RuntimeChatService(store), RuntimeProfileService(store), RuntimePersonalChatService(store), RuntimeMeetingCreateService(store), RuntimeMeetingJoinService(store), RuntimeMeetingChatService(store), RuntimeMeetingMembershipService(store), initial, uploads


class RuntimeMutationHttp:
    def __init__(self, env, *, service_factory=_create, read_factory=None, meetings_factory=None):
        self._enabled = (env.get("CLRS_RUNTIME_WRITES_ENABLED") == "1"
            and env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") == "canonical-current-v1")
        self._services = None
        if self._enabled:
            try:
                self._services = service_factory(env)
            except Exception:
                pass
        self._reads = RuntimeReadHttp(env, self._services[0] if self._services else None,
                                      read_factory=read_factory, meetings_factory=meetings_factory)

    def close(self):
        self._reads.close()
        if self._services is not None:
            cleanup = getattr(self._services[0], "close", None)
            if callable(cleanup):
                cleanup()
            self._services = None

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        if self._services is not None and len(self._services) > 9 and self._services[9] is not None:
            upload_reply = self._services[9].dispatch(
                environ, native_service=native_service, native_configured=native_configured)
            if upload_reply is not None:
                return upload_reply
        meeting_mutation = (environ.get("PATH_INFO") in {"/v1/runtime/meetings/join", "/v1/runtime/meetings/leave", "/v1/runtime/meetings/kick"}
            or (environ.get("PATH_INFO") == "/v1/runtime/meetings"
                and environ.get("REQUEST_METHOD") == "POST")
            or (environ.get("REQUEST_METHOD") == "POST"
                and re.fullmatch(r"/v1/runtime/meetings/[^/]{1,191}/messages", environ.get("PATH_INFO", "")) is not None))
        read_reply = None if meeting_mutation else self._reads.dispatch(
            environ, native_service=native_service, native_configured=native_configured)
        if read_reply is not None:
            return read_reply
        route = _route(environ.get("PATH_INFO", ""))
        if route is None:
            return None
        if not self._enabled:
            return RuntimeHttpReply("404 Not Found", {"error": "not_found"})
        operation, resource, operation_id = route
        profile_read = operation == "profile.edit.v1" and environ.get("REQUEST_METHOD") == "GET"
        full_profile_read = operation == "profile.full-read.v1"
        method = "GET" if operation == "reconcile" or profile_read or full_profile_read else "POST"
        if environ.get("REQUEST_METHOD") != method:
            return RuntimeHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        try:
            query = environ.get("QUERY_STRING", "")
            if operation == "reconcile":
                if not isinstance(query, str) or re.fullmatch(r"requestHash=[0-9a-f]{64}", query) is None:
                    raise RuntimeInvalidRequest()
                if environ.get("HTTP_TRANSFER_ENCODING") or environ.get("CONTENT_LENGTH", "") not in ("", "0"):
                    raise RuntimeInvalidRequest()
            elif query or (full_profile_read and not isinstance(query, str)):
                raise RuntimeInvalidRequest()
            if (profile_read or full_profile_read) and (environ.get("HTTP_TRANSFER_ENCODING")
                    or environ.get("CONTENT_LENGTH", "") not in ("", "0")):
                raise RuntimeInvalidRequest()
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (not isinstance(header, str) or not header.startswith("Bearer na1.")
                    or len(header) > 135 or any(c.isspace() for c in header[7:])):
                raise NativeRejected()
            if not native_configured:
                raise NativeRejected()
            if native_service is None or self._services is None:
                raise NativeUnavailable()
            token = header[7:]
            identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
            if type(identity) is not NativeIdentity:
                raise NativeUnavailable()
            store, chat, profile = self._services[:3]
            if full_profile_read:
                result = profile.read_full(identity, access_token=token)
                if type(result) is not dict:
                    raise RuntimeUnavailable()
                return RuntimeHttpReply("200 OK", result)
            if profile_read:
                return RuntimeHttpReply("200 OK", profile.read_for_edit(identity, access_token=token))
            if operation == "reconcile":
                outcome = store.lookup(identity, resource, operation_id,
                    access_token=token, request_hash=bytes.fromhex(query[12:]))
            else:
                body = _body(environ)
                if type(body) is not dict:
                    raise RuntimeInvalidRequest()
                operation_id = body.get("operationId")
                if not isinstance(operation_id, str) or _UUID.fullmatch(operation_id) is None:
                    raise RuntimeInvalidRequest()
                if operation == "chat.open-personal.v1":
                    if set(body) != {"operationId", "targetUid"}:
                        raise RuntimeInvalidRequest()
                    if len(self._services) < 4:
                        raise RuntimeUnavailable()
                    outcome = self._services[3].open_personal(identity, body["targetUid"],
                        operation_id, access_token=token)
                elif operation == "meeting.send-text.v1":
                    if set(body) != {"operationId", "text"}:
                        raise RuntimeInvalidRequest()
                    if len(self._services) < 7:
                        raise RuntimeUnavailable()
                    outcome = self._services[6].send_text(identity, resource, operation_id,
                        body["text"], access_token=token)
                elif operation in {"meeting.leave.v1", "meeting.kick.v1"}:
                    expected = {"operationId", "meetingId"} | ({"targetUid"} if operation == "meeting.kick.v1" else set())
                    if set(body) != expected:
                        raise RuntimeInvalidRequest()
                    if len(self._services) < 8:
                        raise RuntimeUnavailable()
                    method = self._services[7].kick if operation == "meeting.kick.v1" else self._services[7].leave
                    outcome = method(identity, operation_id,
                        {key: value for key, value in body.items() if key != "operationId"}, access_token=token)
                elif operation == "meeting.join.v1":
                    if set(body) != {"operationId", "meetingId"}:
                        raise RuntimeInvalidRequest()
                    if len(self._services) < 6:
                        raise RuntimeUnavailable()
                    outcome = self._services[5].join(identity, operation_id,
                        {"meetingId": body["meetingId"]}, access_token=token)
                elif operation == "meeting.create.v1":
                    if len(self._services) < 5:
                        raise RuntimeUnavailable()
                    outcome = self._services[4].create(identity, operation_id,
                        {key: value for key, value in body.items() if key != "operationId"},
                        access_token=token)
                elif operation == "chat.send-text.v1":
                    if set(body) != {"operationId", "text", "quoteMessageId"}:
                        raise RuntimeInvalidRequest()
                    outcome = chat.send_text(identity, resource, operation_id, body["text"],
                        quote_message_id=body["quoteMessageId"], access_token=token)
                elif operation == "chat.mark-read.v1":
                    if set(body) != {"operationId", "throughSequence"}:
                        raise RuntimeInvalidRequest()
                    outcome = chat.mark_read(identity, resource, operation_id,
                        body["throughSequence"], access_token=token)
                elif operation == "profile.finish-registration.v1":
                    if len(self._services) < 9 or self._services[8] is None:
                        raise RuntimeUnavailable()
                    outcome = self._services[8].finish(identity, operation_id,
                        {key: value for key, value in body.items() if key != "operationId"}, access_token=token)
                elif operation == "profile.complete-test.v1":
                    if set(body) != {"operationId", "expectedUpdatedAt", "scores"}:
                        raise RuntimeInvalidRequest()
                    outcome = profile.complete_test(identity, operation_id,
                        {"expectedUpdatedAt": body["expectedUpdatedAt"], "scores": body["scores"]},
                        access_token=token)
                elif operation == "profile.edit-geography.v1":
                    if set(body) != {"operationId", "expectedUpdatedAt", "changes"}:
                        raise RuntimeInvalidRequest()
                    outcome = profile.edit_geography(identity, operation_id,
                        {"expectedUpdatedAt": body["expectedUpdatedAt"], "changes": body["changes"]},
                        access_token=token)
                else:
                    if set(body) != {"operationId", "expectedUpdatedAt", "changes"}:
                        raise RuntimeInvalidRequest()
                    outcome = profile.edit(identity, operation_id,
                        {"expectedUpdatedAt": body["expectedUpdatedAt"], "changes": body["changes"]},
                        access_token=token)
            status = {200: "200 OK", 201: "201 Created", 400: "400 Bad Request",
                      404: "404 Not Found", 409: "409 Conflict"}.get(outcome.status)
            if status is None or type(outcome.payload) is not dict:
                raise RuntimeUnavailable()
            return RuntimeHttpReply(status, outcome.payload)
        except (RuntimeInvalidRequest, ProfileEditInvalid):
            return RuntimeHttpReply("400 Bad Request", {"error": "invalid_request"})
        except InitialProfileAccessRejected:
            return RuntimeHttpReply("404 Not Found", {"error": "registration_unavailable"})
        except MeetingAccessRejected:
            return RuntimeHttpReply("404 Not Found", {"error": "meeting_unavailable"})
        except PersonalChatAccessRejected:
            return RuntimeHttpReply("404 Not Found", {"error": "person_unavailable"})
        except (NativeRejected, RuntimeRejected):
            return RuntimeHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
        except RuntimeConflict:
            return RuntimeHttpReply("409 Conflict", {"error": "operation_conflict"})
        except RuntimeCommitUnknown:
            return RuntimeHttpReply("503 Service Unavailable", {"error": "outcome_unknown"})
        except NativeRateLimited:
            return RuntimeHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except Exception:
            return RuntimeHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
