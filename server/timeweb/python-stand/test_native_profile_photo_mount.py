"""One scoped mount contract; all credentials/ports are synthetic, no TCP/SQL."""
import base64
import io
import json
import os
import unittest
from unittest.mock import Mock, patch

with patch.dict(os.environ, {}, clear=True):
    import app
import native_profile_photo_factory as factory
import runtime_http
from native_sessions import NativeIdentity
from runtime_mutations import MutationOutcome
from runtime_profile_photo_uploads import RuntimeProfilePhotoUploadsService
from runtime_initial_profile import RuntimeInitialProfileService

OP_ID = "a0000000-0000-4000-8000-000000000001"
IDENTITY = NativeIdentity("synthetic-owner", True, "synthetic-session", 1, 9999999999)
ENV = {"CLRS_RUNTIME_WRITES_ENABLED": "1",
       "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "canonical-current-v1",
       "CLRS_RUNTIME_PERMISSION_MODEL": "provider-database-v1"}


class Store:
    def __init__(self, env):
        self._env = env
        self.guards = {}
        self.lookups = []
        self.closed = 0

    def register_replay_guard(self, operation, guard, **options):
        if operation in self.guards:
            raise AssertionError("duplicate shared-store replay guard")
        self.guards[operation] = (guard, options)

    def lookup(self, identity, operation, operation_id, **options):
        self.lookups.append((identity, operation, operation_id, options))
        return MutationOutcome(200, {"state": "not_found"})

    def close(self):
        self.closed += 1


class Port:
    def __init__(self):
        self.closed = 0
        self.dispatches = []

    def dispatch(self, environ, **options):
        self.dispatches.append((environ["PATH_INFO"], options))
        return None

    def close(self):
        self.closed += 1


class Composite(Port):
    def __init__(self, legacy):
        super().__init__()
        self.legacy = legacy

    def close(self):
        if self.closed:
            return
        super().close()
        self.legacy.close()


def request(path, *, body=None, query="", proof=None, bearer=True):
    raw = b"" if body is None else json.dumps(body).encode()
    env = {"PATH_INFO": path, "REQUEST_METHOD": "GET" if body is None else "POST",
           "QUERY_STRING": query, "CONTENT_LENGTH": str(len(raw)),
           "CONTENT_TYPE": "application/json", "wsgi.input": io.BytesIO(raw),
           "REMOTE_ADDR": "127.0.0.1"}
    if bearer:
        env["HTTP_AUTHORIZATION"] = "Bearer na1.synthetic"
    if proof is not None:
        env["HTTP_X_CLRS_PREVIEW_PROOF"] = proof
    return env


class NativeProfilePhotoMountTest(unittest.TestCase):
    def test_mount_gate_shared_core_native_auth_preview_and_close(self):
        native = Mock()
        native.authorize.return_value = IDENTITY
        for gate, expected in ((None, None), ("0", None), ("1", "503 Service Unavailable")):
            with self.subTest(gate=gate):
                env = dict(ENV)
                if gate is not None:
                    env["CLRS_RUNTIME_NATIVE_PHOTO_UPLOADS_ENABLED"] = gate
                legacy = Port()
                if gate != "1":
                    self.assertIs(factory.create_native_profile_photos_http(env, legacy), legacy)
                # Real factory rejects absent writer+signed attestation, never loads secrets.
                self.assertIsNone(factory.create_native_photo_writer(env))
                store = Store(env)
                with patch.object(runtime_http.RuntimeMutationStore, "from_env", return_value=store):
                    services = runtime_http._create(env)
                self.assertEqual(len(services), 10)
                self.assertIs(services[0], store)
                self.assertEqual([type(service).__name__ for service in services[1:9]], [
                    "RuntimeChatService", "RuntimeProfileService", "RuntimePersonalChatService",
                    "RuntimeMeetingCreateService", "RuntimeMeetingJoinService", "RuntimeMeetingChatService",
                    "RuntimeMeetingMembershipService", "RuntimeInitialProfileService"])
                self.assertIsInstance(services[8], RuntimeInitialProfileService)
                self.assertIs(services[8]._photos._store, store)
                self.assertIsNone(services[8]._photos._writer)
                with patch.object(runtime_http, "RuntimeReadHttp", return_value=Port()):
                    http = runtime_http.RuntimeMutationHttp(env, service_factory=lambda _: services)
                reply = http.dispatch(request("/v1/runtime/profile/photos/prepare", body={"operationId": OP_ID}),
                                      native_service=native, native_configured=True)
                self.assertEqual(None if reply is None else reply.status, expected)
                # Old initial receipt lookup still takes the original generic store route.
                lookup = http.dispatch(request("/v1/runtime/operations/profile.finish-registration.v1/" + OP_ID,
                    query="requestHash=" + "a" * 64), native_service=native, native_configured=True)
                self.assertEqual(lookup.status, "200 OK")
                self.assertEqual(store.lookups[-1][1:3], ("profile.finish-registration.v1", OP_ID))
                http.close(); http.close()
                self.assertEqual(store.closed, 1)

        env = {**ENV, "CLRS_RUNTIME_NATIVE_PHOTO_UPLOADS_ENABLED": "1"}
        store = Store(env)
        writer = Mock(spec=["prepare_put", "verify_ready", "require_verified"])
        with patch.object(runtime_http.RuntimeMutationStore, "from_env", return_value=store), \
                patch.object(factory, "create_native_photo_writer", return_value=writer):
            services = runtime_http._create(env)
        uploads = services[9]
        self.assertIsInstance(uploads._service, RuntimeProfilePhotoUploadsService)
        self.assertIs(uploads._service, services[8]._photos)
        self.assertIs(uploads._service._writer, writer)
        self.assertEqual(set(store.guards) & {"profile.photo.prepare.v1", "profile.photo.commit.v1"},
                         {"profile.photo.prepare.v1", "profile.photo.commit.v1"})
        uploads._service.prepare = Mock(return_value=MutationOutcome(201, {"fixture": "prepare-delegated"}))
        services[8].finish = Mock(return_value=MutationOutcome(200, {"fixture": "initial-delegated"}))
        with patch.object(runtime_http, "RuntimeReadHttp", return_value=Port()):
            runtime = runtime_http.RuntimeMutationHttp(env, service_factory=lambda _: services)
        missing_auth = runtime.dispatch(request("/v1/runtime/profile/photos/prepare", body={"operationId": OP_ID},
            bearer=False), native_service=native, native_configured=True)
        self.assertEqual(missing_auth.status, "401 Unauthorized")
        self.assertTrue(missing_auth.authenticate)
        uploads._service.prepare.assert_not_called()

        proof = base64.b64encode(b"p" * 32).decode()
        app_env = {**env, "CLRS_API_DRAFT_ENABLED": "1", "CLRS_PREVIEW_GUARD_ENABLED": "1",
                   "CLRS_PREVIEW_ACCESS_KEY_B64": proof, "CLRS_NATIVE_AUTH_ENABLED": "1",
                   "CLRS_NATIVE_AUTH_WRITES_ENABLED": "1"}
        legacy, composite = Port(), None
        def wrap(current_env, previous):
            nonlocal composite
            self.assertIs(current_env, app_env)
            self.assertIs(previous, legacy)
            composite = Composite(previous)
            return composite
        with patch.object(app, "create_native_profile_photos_http", side_effect=wrap) as wrapped:
            application = app.create_app(env=app_env, profile_photos_http=legacy,
                runtime_http_factory=lambda _: runtime, native_service_factory=lambda _: native,
                legacy_http_factory=lambda _: Port(), media_http_factory=lambda _: Port(),
                lifecycle_http_factory=lambda *_: Port())
            self.assertIsNone(composite)
            def call(environ):
                status = []
                body = b"".join(application(environ, lambda code, headers: status.append(code)))
                return status[0], json.loads(body)
            status, _ = call(request("/v1/runtime/profile/photos/prepare", body={"operationId": OP_ID}))
            self.assertEqual(status, "404 Not Found")
            wrapped.assert_not_called()
            uploads._service.prepare.assert_not_called()
            status, payload = call(request("/v1/runtime/profile/photos/prepare", proof=proof,
                body={"operationId": OP_ID, "sha256": "b" * 64, "byteSize": 17, "mimeType": "image/png"}))
            self.assertEqual((status, payload), ("201 Created", {"fixture": "prepare-delegated"}))
            wrapped.assert_called_once()
            uploads._service.prepare.assert_called_once_with(IDENTITY, OP_ID,
                {"sha256": "b" * 64, "byteSize": 17, "mimeType": "image/png"}, access_token="na1.synthetic")
            status, _ = call(request("/v1/runtime/me/registration", proof=proof,
                                    body={"operationId": OP_ID, "fixture": "initial"}))
            self.assertEqual(status, "200 OK")
            services[8].finish.assert_called_once_with(IDENTITY, OP_ID, {"fixture": "initial"},
                                                      access_token="na1.synthetic")
            application.close(); application.close()
            self.assertEqual(composite.closed, 1)
            self.assertEqual(legacy.closed, 1)
            self.assertEqual(store.closed, 1)
            self.assertTrue(all(options["native_service"] is native and options["native_configured"]
                                for _, options in composite.dispatches))


if __name__ == "__main__":
    unittest.main()
