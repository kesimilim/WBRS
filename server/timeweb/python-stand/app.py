"""Isolated CLRS API draft for an existing free Timeweb App Platform stand.

The deployed smoke branch remains separate. This draft has no SQL editor,
admin route, arbitrary media access, or cross-account profile read.
"""

import json
import os
import re
import base64
import hmac
import threading

from auth_bridge import AuthRejected, AuthUnavailable, AuthenticationError, verify_firebase_id_token
from profile_store import AccountUnavailable, DatabaseUnavailable, probe_database, read_own_profile
from native_auth import (MAX_BODY_BYTES, NativeAuthService, NativeRateLimited,
                         NativeRejected, NativeUnavailable, parse_login_body)
from native_credentials import unique_json, CredentialUnavailable
from legacy_conversation_http import LegacyConversationHttp
from legacy_private_media_http import LegacyPrivateMediaHttp, MediaHttpReply
from runtime_http import RuntimeMutationHttp
from runtime_meetings import RuntimeMeetingsService, TRUSTED_POLICY
from native_auth_lifecycle_http import NativeAuthLifecycleHttp
from runtime_profile_photos_http import RuntimeProfilePhotoMediaReply, RuntimeProfilePhotosHttpReply
from runtime_profile_photos_factory import create_profile_photos_http
from native_profile_photo_factory import create_native_profile_photos_http


def _reply(start_response, status, payload, *, head=False, authenticate=False, retry=False):
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    headers = [
        ("Content-Type", "application/json; charset=utf-8"),
        ("Content-Length", str(len(body))),
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
    ]
    if authenticate:
        headers.append(("WWW-Authenticate", "Bearer"))
    if retry:
        headers.append(("Retry-After", "60"))
    start_response(status, headers)
    return [b"" if head else body]


class InvalidBody(Exception):
    pass


def _body(environ):
    # Bound the read itself, not only the decoded JSON. Socket deadlines are
    # enforced by the server; chunked/unknown-length input is never accepted.
    if environ.get("HTTP_TRANSFER_ENCODING"):
        raise InvalidBody()
    length = environ.get("CONTENT_LENGTH", "")
    if not isinstance(length, str) or re.fullmatch(r"[0-9]{1,5}", length) is None:
        raise InvalidBody()
    length = int(length)
    if not 1 <= length <= MAX_BODY_BYTES:
        raise InvalidBody()
    content_type = environ.get("CONTENT_TYPE", "").lower()
    if content_type not in ("application/json", "application/json; charset=utf-8"):
        raise InvalidBody()
    try:
        raw = environ["wsgi.input"].read(length)
    except Exception:
        raise InvalidBody() from None
    if not isinstance(raw, bytes) or len(raw) != length:
        raise InvalidBody()
    return raw


def _json_body(environ, keys):
    try:
        result = unique_json(_body(environ).decode("utf-8"))
    except (CredentialUnavailable, UnicodeError):
        raise InvalidBody() from None
    if set(result) != keys:
        raise InvalidBody()
    return result


def _bearer(environ):
    header = environ.get("HTTP_AUTHORIZATION", "")
    if (not isinstance(header, str) or not header.startswith("Bearer ")
            or len(header) > 8192 or not header[7:]
            or any(char.isspace() for char in header[7:])):
        raise NativeRejected()
    return header[7:]


def _peer(environ):
    # The hosting proxy's socket identity is used conservatively. Do not trust
    # caller-controlled X-Forwarded-For to bypass the process rate limit.
    return environ.get("REMOTE_ADDR", "")


def _native_runtime_http(env, *, imported_authority=None, reviewed_binding=None):
    # Only an external reviewed assembler may supply the opaque final authority.
    if imported_authority is not None or reviewed_binding is not None:
        from runtime_imported_meetings import imported_meetings_factory
        from runtime_mutations import RuntimeUnavailable
        if imported_authority is None or reviewed_binding is None:
            raise RuntimeUnavailable()
        meetings_factory = imported_meetings_factory(imported_authority,
                                                     reviewed_binding=reviewed_binding)
    else:
        meetings_factory = lambda store, current_env: RuntimeMeetingsService.from_env(
            store, current_env, trusted_policy=TRUSTED_POLICY)
    return RuntimeMutationHttp(env, meetings_factory=meetings_factory)


def create_app(*, env=None, verify_token=verify_firebase_id_token,
               profile_reader=read_own_profile, database_probe=probe_database,
               native_service_factory=NativeAuthService.from_env,
               legacy_http_factory=LegacyConversationHttp,
               media_http_factory=LegacyPrivateMediaHttp,
               runtime_http_factory=_native_runtime_http,
               lifecycle_http_factory=NativeAuthLifecycleHttp,
               profile_photos_http=None,
               profile_photos_http_factory=create_profile_photos_http,
               imported_meeting_authority=None, imported_meeting_binding=None):
    """Construct WSGI app with injectable dependencies for offline tests."""
    if env is None:
        env = os.environ
    native_service = legacy_http = media_http = runtime_http = lifecycle_http = None
    initialized = False
    init_lock = threading.Lock()
    preview_flag = env.get("CLRS_PREVIEW_GUARD_ENABLED")
    preview = preview_flag not in (None, "0")
    preview_key = None
    if preview:
        try:
            if preview_flag != "1":
                raise ValueError()
            encoded = env["CLRS_PREVIEW_ACCESS_KEY_B64"]
            if not isinstance(encoded, str) or re.fullmatch(r"[A-Za-z0-9+/]{43}=?", encoded) is None:
                raise ValueError()
            preview_key = base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True)
            if len(preview_key) != 32 or base64.b64encode(preview_key).decode().rstrip("=") != encoded.rstrip("="):
                raise ValueError()
        except Exception:
            preview_key = None
    native_configured = (env.get("CLRS_NATIVE_AUTH_ENABLED") == "1"
                         and env.get("CLRS_NATIVE_AUTH_WRITES_ENABLED") == "1")
    def initialize():
        nonlocal native_service, legacy_http, media_http, runtime_http, lifecycle_http, profile_photos_http, initialized
        with init_lock:
            if initialized:
                return
            legacy_http = legacy_http_factory(env)
            media_http = media_http_factory(env)
            if imported_meeting_authority is not None or imported_meeting_binding is not None:
                runtime_http = runtime_http_factory(env, imported_authority=imported_meeting_authority,
                                                   reviewed_binding=imported_meeting_binding)
            else:
                runtime_http = runtime_http_factory(env)
            if profile_photos_http is None:
                profile_photos_http = profile_photos_http_factory(env)
            profile_photos_http = create_native_profile_photos_http(env, profile_photos_http)
            if native_configured:
                try:
                    native_service = native_service_factory(env)
                except Exception:
                    # Invalid secret/configuration closes routes without exposing it.
                    native_service = None
            lifecycle_http = lifecycle_http_factory(env, native_service)
            initialized = True
    if not preview:
        initialize()

    def application(environ, start_response):
        method = environ.get("REQUEST_METHOD", "")
        path = environ.get("PATH_INFO", "")
        smoke = env.get("CLRS_STAGING_SMOKE_ENABLED") == "1"
        api = env.get("CLRS_API_DRAFT_ENABLED") == "1"
        if smoke and api:
            if path in ("/", "/health", "/healthz", "/readyz") and method in ("GET", "HEAD"):
                return _reply(start_response, "503 Service Unavailable",
                              {"state": "conflicting_modes"}, head=method == "HEAD")
            return _reply(start_response, "404 Not Found", {"error": "not_found"})

        if path in ("/", "/health", "/healthz") and method in ("GET", "HEAD"):
            state = "api_draft" if api else "smoke_only"
            return _reply(start_response, "200 OK",
                          {"service": "clrs-timeweb-stand", "state": state},
                          head=method == "HEAD")
        if path == "/readyz" and method in ("GET", "HEAD"):
            # Data staging is not application cutover. A preview must also
            # avoid unauthenticated DB work from readiness probes.
            connected = False
            if api and not preview:
                try:
                    connected = database_probe(env=env) is True
                except Exception:
                    connected = False
            return _reply(start_response, "503 Service Unavailable",
                          {"state": "migration_incomplete" if api else "api_not_configured",
                           "database_connected": connected},
                          head=method == "HEAD")

        if preview:
            if preview_key is None:
                return _reply(start_response, "503 Service Unavailable", {"error": "service_unavailable"})
            supplied = environ.get("HTTP_X_CLRS_PREVIEW_PROOF", "")
            try:
                if not isinstance(supplied, str) or re.fullmatch(r"[A-Za-z0-9+/]{43}=?", supplied) is None:
                    raise ValueError()
                proof = base64.b64decode(supplied + "=" * (-len(supplied) % 4), validate=True)
                canonical = base64.b64encode(proof).decode().rstrip("=") == supplied.rstrip("=")
                allowed = canonical and len(proof) == 32 and hmac.compare_digest(proof, preview_key)
            except Exception:
                allowed = False
            if not allowed:
                return _reply(start_response, "404 Not Found", {"error": "not_found"})
            try:
                initialize()
            except Exception:
                return _reply(start_response, "503 Service Unavailable", {"error": "service_unavailable"})

        if api and path in ("/v1/auth/login", "/v1/auth/refresh", "/v1/auth/logout"):
            if not native_configured:
                return _reply(start_response, "404 Not Found", {"error": "not_found"})
            if method != "POST":
                return _reply(start_response, "405 Method Not Allowed", {"error": "method_not_allowed"})
            if native_service is None:
                return _reply(start_response, "503 Service Unavailable", {"error": "service_unavailable"})
            if environ.get("QUERY_STRING"):
                return _reply(start_response, "400 Bad Request", {"error": "invalid_request"})
            try:
                if path == "/v1/auth/login":
                    try:
                        body = parse_login_body(_body(environ))
                    except NativeRejected:
                        raise InvalidBody() from None
                    payload = native_service.login(body, peer=_peer(environ))
                elif path == "/v1/auth/refresh":
                    body = _json_body(environ, {"refreshToken"})
                    payload = native_service.refresh(body["refreshToken"], peer=_peer(environ))
                else:
                    body = _json_body(environ, {"allSessions"})
                    if type(body["allSessions"]) is not bool:
                        raise InvalidBody()
                    payload = native_service.logout(_bearer(environ), peer=_peer(environ),
                                                    all_sessions=body["allSessions"])
            except InvalidBody:
                return _reply(start_response, "400 Bad Request", {"error": "invalid_request"})
            except NativeRejected:
                return _reply(start_response, "401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
            except NativeRateLimited:
                return _reply(start_response, "429 Too Many Requests", {"error": "rate_limited"}, retry=True)
            except Exception:
                return _reply(start_response, "503 Service Unavailable", {"error": "service_unavailable"})
            return _reply(start_response, "200 OK", payload)

        if api:
            if profile_photos_http is not None:
                photo_reply = profile_photos_http.dispatch(environ, native_service=native_service,
                                                          native_configured=native_configured)
                if isinstance(photo_reply, RuntimeProfilePhotoMediaReply):
                    photo_reply = photo_reply.respond(start_response)
                    if not isinstance(photo_reply, RuntimeProfilePhotosHttpReply):
                        return photo_reply
                if photo_reply is not None:
                    return _reply(start_response, photo_reply.status, photo_reply.payload,
                                  authenticate=photo_reply.authenticate, retry=photo_reply.retry)
            lifecycle_reply = lifecycle_http.dispatch(environ)
            if lifecycle_reply is not None:
                return _reply(start_response, lifecycle_reply.status, lifecycle_reply.payload,
                              retry=lifecycle_reply.retry)
            runtime_reply = runtime_http.dispatch(environ, native_service=native_service,
                                                 native_configured=native_configured)
            if runtime_reply is not None:
                return _reply(start_response, runtime_reply.status, runtime_reply.payload,
                              authenticate=runtime_reply.authenticate, retry=runtime_reply.retry)
            media_reply = media_http.dispatch(environ, native_service=native_service,
                                             native_configured=native_configured)
            if isinstance(media_reply, MediaHttpReply):
                try:
                    return media_reply.respond(start_response)
                except Exception:
                    return _reply(start_response, "503 Service Unavailable", {"error": "service_unavailable"})
            if media_reply is not None:
                return _reply(start_response, media_reply.status, media_reply.payload,
                              authenticate=media_reply.authenticate, retry=media_reply.retry)
            legacy_reply = legacy_http.dispatch(environ, native_service=native_service,
                                              native_configured=native_configured)
            if legacy_reply is not None:
                return _reply(start_response, legacy_reply.status, legacy_reply.payload,
                              authenticate=legacy_reply.authenticate, retry=legacy_reply.retry)

        if not api or path != "/v1/me/profile" or method != "GET":
            return _reply(start_response, "404 Not Found", {"error": "not_found"})

        if environ.get("QUERY_STRING"):
            return _reply(start_response, "400 Bad Request", {"error": "invalid_request"})
        try:
            token = _bearer(environ)
        except NativeRejected:
            return _reply(start_response, "401 Unauthorized",
                          {"error": "unauthorized"}, authenticate=True)
        try:
            if token.startswith(("na1.", "nr1.")):
                if not native_configured:
                    raise NativeRejected()
                if native_service is None:
                    raise NativeUnavailable()
                uid = native_service.authorize(token, peer=_peer(environ)).uid
            else:
                if not env.get("FIREBASE_PROJECT_ID") or not env.get("FIREBASE_WEB_API_KEY"):
                    raise AuthUnavailable()
                uid = verify_token(token,
                                   project_id=env["FIREBASE_PROJECT_ID"],
                                   web_api_key=env["FIREBASE_WEB_API_KEY"])
        except (AuthRejected, NativeRejected):
            return _reply(start_response, "401 Unauthorized",
                          {"error": "unauthorized"}, authenticate=True)
        except NativeRateLimited:
            return _reply(start_response, "429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except (AuthUnavailable, AuthenticationError, NativeUnavailable):
            return _reply(start_response, "503 Service Unavailable",
                          {"error": "service_unavailable"})
        except Exception:
            return _reply(start_response, "503 Service Unavailable",
                          {"error": "service_unavailable"})
        try:
            profile = profile_reader(uid, env=env)
        except AccountUnavailable:
            return _reply(start_response, "404 Not Found", {"error": "not_found"})
        except DatabaseUnavailable:
            return _reply(start_response, "503 Service Unavailable",
                          {"error": "service_unavailable"})
        except Exception:
            return _reply(start_response, "503 Service Unavailable",
                          {"error": "service_unavailable"})
        return _reply(start_response, "200 OK", {"profile": profile})

    def close():
        with init_lock:
            for service in (profile_photos_http, lifecycle_http, media_http, native_service, runtime_http):
                cleanup = getattr(service, "close", None)
                if callable(cleanup):
                    try:
                        cleanup()
                    except Exception:
                        # Finish independent cleanup even if one port fails.
                        pass
    application.close = close
    return application


app = create_app()


if __name__ == "__main__":
    smoke_enabled = os.environ.get("CLRS_STAGING_SMOKE_ENABLED") == "1"
    api_enabled = os.environ.get("CLRS_API_DRAFT_ENABLED") == "1"
    if smoke_enabled == api_enabled:
        raise SystemExit("Select exactly one isolated CLRS stand mode")
    try:
        port = int(os.environ.get("PORT", "5005"))
    except ValueError as exc:
        raise SystemExit("Invalid stand port") from exc
    if not 1 <= port <= 65535:
        raise SystemExit("Invalid stand port")
    from http_runtime import make_bounded_server
    with make_bounded_server("0.0.0.0", port, app) as server:
        server.serve_forever()
