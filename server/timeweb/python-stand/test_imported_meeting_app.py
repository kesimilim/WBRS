"""One actual app/dispatcher wiring case with existing synthetic current store."""
import ast
import base64
import copy
import hmac
import json
from pathlib import Path
import re
import threading
from types import SimpleNamespace
import unittest

from runtime_http import RuntimeMutationHttp
from runtime_meetings import RuntimeMeetingsService, TRUSTED_POLICY
from imported_meeting_authority import _SOURCE_FILES
from test_imported_meeting_authority import ProofDatabase, pack, capability
from test_runtime_meetings import READ_ENV
from test_runtime_meetings_http import Native
from test_runtime_mutations import store_for


class NoRoutes:
    def dispatch(self, *_args, **_kwargs): return None
    def close(self): pass


class ImportedAppTests(unittest.TestCase):
    def assembly(self, *, injected=False, authority_override=None, binding_override=None,
                 partial=None):
        db = ProofDatabase(); body = pack(db); db.add_meeting("native")
        store = store_for(db); self.addCleanup(store.close)
        authority = capability(body); native = Native(db); built = []
        preview = bytes(range(32))
        env = {**READ_ENV, "CLRS_API_DRAFT_ENABLED": "1", "CLRS_NATIVE_AUTH_ENABLED": "1",
            "CLRS_NATIVE_AUTH_WRITES_ENABLED": "1", "CLRS_PREVIEW_GUARD_ENABLED": "1",
            "CLRS_PREVIEW_ACCESS_KEY_B64": base64.b64encode(preview).decode(),
            # Environment imitations are inert, never an authority input.
            "CLRS_IMPORTED_MEETING_AUTHORITY": "true", "CLRS_IMPORTED_MEETING_FINAL": "{}"}

        def dispatcher(config, **options):
            built.append(options)
            return RuntimeMutationHttp(config, service_factory=lambda _: (store, None, None), **options)

        forbidden = lambda *_args, **_kwargs: self.fail("unrelated provider called")
        namespace = {"json": json, "re": re, "base64": base64, "hmac": hmac,
            "threading": threading, "RuntimeMutationHttp": dispatcher,
            "RuntimeMeetingsService": RuntimeMeetingsService, "TRUSTED_POLICY": TRUSTED_POLICY,
            "verify_firebase_id_token": forbidden, "read_own_profile": forbidden,
            "probe_database": forbidden, "NativeAuthService": SimpleNamespace(from_env=forbidden),
            "LegacyConversationHttp": lambda _: NoRoutes(), "LegacyPrivateMediaHttp": lambda _: NoRoutes(),
            "NativeAuthLifecycleHttp": lambda *_: NoRoutes(), "create_profile_photos_http": lambda _: None,
            "create_native_profile_photos_http": lambda _, original: original}
        tree = ast.parse(Path(__file__).with_name("app.py").read_text())
        names = {"_reply", "_native_runtime_http", "create_app"}
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
        self.assertEqual({node.name for node in functions}, names)
        # Avoid the module's global app initialization and real process env.
        exec(compile(ast.Module(body=functions, type_ignores=[]), "actual-app-wiring", "exec"), namespace)
        options = {"env": env, "native_service_factory": lambda _: native}
        if injected:
            options.update(imported_meeting_authority=authority if authority_override is None else authority_override,
                           imported_meeting_binding=body["binding"] if binding_override is None else binding_override)
        if partial == "authority": options["imported_meeting_binding"] = None
        if partial == "binding": options["imported_meeting_authority"] = None
        app = namespace["create_app"](**options); self.addCleanup(app.close)
        return app, db, store, preview, built, native

    def request(self, app, db, preview=None, *, path="/v1/runtime/meetings/m"):
        environ = {"REQUEST_METHOD": "GET", "PATH_INFO": path, "QUERY_STRING": "",
                   "HTTP_AUTHORIZATION": "Bearer " + db.access, "REMOTE_ADDR": "127.0.0.1"}
        if preview is not None: environ["HTTP_X_CLRS_PREVIEW_PROOF"] = base64.b64encode(preview).decode()
        status = []
        raw = b"".join(app(environ, lambda value, headers: status.append((value, dict(headers)))))
        self.assertEqual(status[0][1]["Cache-Control"], "no-store")
        return status[0][0], json.loads(raw)

    def test_preview_default_closed_and_exact_authority_through_real_dispatcher(self):
        self.assertTrue({"app.py", "runtime_http.py", "runtime_read_http.py"}.issubset(_SOURCE_FILES))
        app, db, store, preview, built, native = self.assembly()
        self.assertEqual(self.request(app, db)[0], "404 Not Found")
        self.assertEqual((built, native.calls, db.connections), ([], [], []))
        self.assertEqual(self.request(app, db, preview)[0], "404 Not Found")
        self.assertEqual(self.request(app, db, preview, path="/v1/runtime/meetings/native")[0], "200 OK")
        self.assertEqual(len(built), 1)
        app.close(); self.assertTrue(store._closed)

        app, db, store, preview, built, native = self.assembly(injected=True)
        self.assertEqual(self.request(app, db)[0], "404 Not Found")
        self.assertEqual((built, native.calls, db.connections), ([], [], []))
        before = copy.deepcopy(db.state)
        for path in ("/v1/runtime/meetings", "/v1/runtime/meetings/m",
                     "/v1/runtime/meetings/m/participants", "/v1/runtime/meetings/native"):
            status, payload = self.request(app, db, preview, path=path)
            self.assertEqual(status, "200 OK")
            self.assertFalse(any(word in json.dumps(payload) for word in ("legacy_raw", "payloadSha256", "source_path")))
        self.assertEqual(db.state, before)
        self.assertEqual(len(built), 1)
        app.close(); self.assertTrue(store._closed)

        for invalid in (True, {}, "signed-json"):
            app, db, store, preview, built, native = self.assembly(injected=True, authority_override=invalid)
            self.assertEqual(self.request(app, db, preview)[0], "503 Service Unavailable")
            self.assertEqual((built, native.calls, db.connections), ([], [], []))
        for partial in ("authority", "binding"):
            app, db, store, preview, built, native = self.assembly(injected=True, partial=partial)
            self.assertEqual(self.request(app, db, preview)[0], "503 Service Unavailable")
            self.assertEqual((built, native.calls, db.connections), ([], [], []))
        app, db, store, preview, built, native = self.assembly(injected=True, binding_override={})
        self.assertEqual(self.request(app, db, preview)[0], "503 Service Unavailable")
        self.assertEqual((built, native.calls, db.connections), ([], [], []))


if __name__ == "__main__":
    unittest.main()
