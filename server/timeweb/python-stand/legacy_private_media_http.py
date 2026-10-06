"""Default-off authenticated private bytes; no URL signing or cloud mutation."""
import math
import os
import re
import threading
import tempfile
import time

from auth_bridge import (AuthenticatedIdentity, AuthRejected, AuthUnavailable,
    AuthenticationError, verify_firebase_identity)
from native_auth import NativeRejected, NativeRateLimited, NativeUnavailable
from native_sessions import NativeIdentity
from legacy_conversation_http import LegacyHttpReply
from legacy_conversation_read import (LegacyReadRejected, LegacyReadUnavailable,
    LegacyReadRateLimited)
from legacy_private_media import (LegacyPrivateMediaService, VerifiedMediaLease,
    REQUEST_SECONDS)
from private_media_s3 import (PrivateMediaS3, SigV4HTTPSReadTransport,
    TimewebPrivateBucketState)


def create_private_media_service(env):
    # Construction is pure. Only the dedicated read credentials are accepted;
    # there is deliberately no fallback to an import/migration credential.
    if env.get("CLRS_LEGACY_MEDIA_ENABLED") != "1":
        return None
    service = None; directory = None
    try:
        raw_id = env.get("CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID", "")
        if not isinstance(raw_id, str) or not re.fullmatch(r"[1-9][0-9]{0,18}", raw_id):
            raise LegacyReadUnavailable()
        bucket = env.get("CLRS_LEGACY_MEDIA_TARGET_BUCKET")
        owner = env.get("CLRS_LEGACY_MEDIA_EXPECTED_OWNER")
        transport = SigV4HTTPSReadTransport("https://s3.twcstorage.ru/",
            env.get("CLRS_LEGACY_MEDIA_S3_REGION"),
            env.get("CLRS_LEGACY_MEDIA_S3_ACCESS_KEY"),
            env.get("CLRS_LEGACY_MEDIA_S3_SECRET_KEY"))
        state = TimewebPrivateBucketState(int(raw_id), bucket,
            env.get("CLRS_LEGACY_MEDIA_CONTROL_TOKEN"))
        service = LegacyPrivateMediaService.from_env(env,
            private_s3=PrivateMediaS3(bucket, owner, transport, state))
        # Receipt and strict DB/TLS configuration are verified before creating
        # any directory. An explicitly supplied empty/bad path never defaults.
        if "CLRS_LEGACY_MEDIA_SPOOL_DIR" not in env:
            directory = tempfile.TemporaryDirectory(prefix="clrs-private-media-")
            os.chmod(directory.name, 0o700)
            service._env["CLRS_LEGACY_MEDIA_SPOOL_DIR"] = directory.name
            service._http_spool_directory = directory
        with service._spool():
            pass
        for name in ("CLRS_LEGACY_MEDIA_S3_ACCESS_KEY", "CLRS_LEGACY_MEDIA_S3_SECRET_KEY",
                "CLRS_LEGACY_MEDIA_CONTROL_TOKEN"):
            service._env.pop(name, None)
        return service
    except Exception:
        if service is not None:
            try:
                service.close()
            except Exception:
                pass
        if directory is not None:
            try:
                directory.cleanup()
            except Exception:
                pass
        raise LegacyReadUnavailable() from None


class MediaHttpBody:
    """Own the already-verified spool even if WSGI closes before iteration."""
    def __init__(self, lease):
        self._lease = lease
        self._iterator = lease.iter_bytes()
        self._closed = False

    def __iter__(self):
        return self

    def __next__(self):
        if self._closed:
            raise StopIteration
        try:
            return next(self._iterator)
        except BaseException:
            self.close()
            raise

    def close(self):
        if self._closed:
            return
        self._closed = True
        try:
            self._iterator.close()
        finally:
            self._lease.close()


class MediaHttpReply:
    def __init__(self, lease):
        self._lease = lease

    def respond(self, start_response):
        body = None
        try:
            # Recheck expiry/cancellation BEFORE sending even the headers.
            self._lease.__enter__()
            body = MediaHttpBody(self._lease)
            headers = list(self._lease.headers.items())
            headers.append(("Referrer-Policy", "no-referrer"))
            start_response("200 OK", headers)
            return body
        except BaseException:
            if body is not None:
                body.close()
            else:
                self._lease.close()
            raise


class LegacyPrivateMediaHttp:
    def __init__(self, env, *, service_factory=create_private_media_service,
            identity_verifier=verify_firebase_identity, monotonic=time.monotonic):
        self._enabled = env.get("CLRS_LEGACY_MEDIA_ENABLED") == "1"
        self._env = {key: env.get(key) for key in ("FIREBASE_PROJECT_ID", "FIREBASE_WEB_API_KEY")}
        self._verify = identity_verifier; self._monotonic = monotonic
        self._service = None
        if self._enabled:
            try:
                self._service = service_factory(env)
            except Exception:
                pass

    def close(self):
        service = self._service; self._service = None
        if service is not None:
            service.close()

    def dispatch(self, environ, *, native_service=None, native_configured=False):
        path = environ.get("PATH_INFO", "")
        if not isinstance(path, str) or not path.startswith("/v1/media/"):
            return None
        if not self._enabled:
            return LegacyHttpReply("404 Not Found", {"error": "not_found"})
        if environ.get("REQUEST_METHOD") != "GET":
            return LegacyHttpReply("405 Method Not Allowed", {"error": "method_not_allowed"})
        reference = path[len("/v1/media/"):]
        if (not 1 <= len(reference) <= 4096 or not re.fullmatch(r"[A-Za-z0-9_-]+", reference)
                or environ.get("QUERY_STRING") or environ.get("HTTP_RANGE")
                or environ.get("HTTP_TRANSFER_ENCODING")
                or environ.get("CONTENT_LENGTH", "") not in ("", "0")):
            return LegacyHttpReply("400 Bad Request", {"error": "invalid_request"})
        try:
            header = environ.get("HTTP_AUTHORIZATION", "")
            if (not isinstance(header, str) or not header.startswith("Bearer ")
                    or not header[7:] or len(header) > 8192 or any(c.isspace() for c in header[7:])):
                raise NativeRejected()
            token = header[7:]
            if token.startswith(("na1.", "nr1.")):
                if not native_configured:
                    raise NativeRejected()
                if native_service is None:
                    raise NativeUnavailable()
                identity = native_service.authorize(token, peer=environ.get("REMOTE_ADDR", ""))
                if type(identity) is not NativeIdentity:
                    raise NativeUnavailable()
            else:
                if not self._env.get("FIREBASE_PROJECT_ID") or not self._env.get("FIREBASE_WEB_API_KEY"):
                    raise AuthUnavailable()
                identity = self._verify(token, project_id=self._env["FIREBASE_PROJECT_ID"],
                    web_api_key=self._env["FIREBASE_WEB_API_KEY"])
                if type(identity) is not AuthenticatedIdentity:
                    raise AuthUnavailable()
            if self._service is None:
                raise LegacyReadUnavailable()
            # Only an authenticated request may extend the initial 10s budget.
            begin = environ.get("clrs.media_request_budget")
            if not callable(begin):
                raise LegacyReadUnavailable()
            deadline, cancel = begin()
            now = self._monotonic()
            if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                    or not now < deadline <= now + REQUEST_SECONDS
                    or not isinstance(cancel, threading.Event) or cancel.is_set()):
                raise LegacyReadUnavailable()
            lease = self._service.open_media(identity, reference,
                request_cancel=cancel, request_deadline=deadline)
            if type(lease) is not VerifiedMediaLease:
                if callable(getattr(lease, "close", None)):
                    lease.close()
                raise LegacyReadUnavailable()
            return MediaHttpReply(lease)
        except (NativeRejected, AuthRejected):
            return LegacyHttpReply("401 Unauthorized", {"error": "unauthorized"}, authenticate=True)
        except LegacyReadRejected:
            return LegacyHttpReply("404 Not Found", {"error": "not_found"})
        except (NativeRateLimited, LegacyReadRateLimited):
            return LegacyHttpReply("429 Too Many Requests", {"error": "rate_limited"}, retry=True)
        except (NativeUnavailable, AuthenticationError, LegacyReadUnavailable):
            return LegacyHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
        except Exception:
            return LegacyHttpReply("503 Service Unavailable", {"error": "service_unavailable"})
