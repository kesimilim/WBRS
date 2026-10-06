"""Preview data remains closed before auth, body reads and dependency setup."""
import base64
import io
import unittest
from types import SimpleNamespace

from app import create_app


class PreviewGuardTest(unittest.TestCase):
    def test_preview_guard_precedes_all_data_routes(self):
        proof = base64.b64encode(bytes(range(32))).decode()
        calls = []
        def factory(name):
            def construct(env):
                calls.append(name)
                return SimpleNamespace(dispatch=lambda *a, **k: None,
                                       close=lambda: calls.append(name + "-closed"))
            return construct
        def verify(*a, **k):
            calls.append("auth")
            return "synthetic-user"
        def profile(*a, **k):
            calls.append("sql")
            return {"uid": "synthetic-user"}
        def probe(**k):
            calls.append("probe")
            return True
        env = {"CLRS_API_DRAFT_ENABLED": "1", "CLRS_PREVIEW_GUARD_ENABLED": "1",
               "CLRS_PREVIEW_ACCESS_KEY_B64": proof, "CLRS_NATIVE_AUTH_ENABLED": "1",
               "CLRS_NATIVE_AUTH_WRITES_ENABLED": "1", "FIREBASE_PROJECT_ID": "synthetic",
               "FIREBASE_WEB_API_KEY": "public-test-key"}
        def app(settings):
            return create_app(env=settings, verify_token=verify, profile_reader=profile,
                              database_probe=probe, native_service_factory=factory("native"),
                              legacy_http_factory=factory("legacy"), media_http_factory=factory("media"))
        def request(application, path, supplied=None, query=""):
            state = {}
            class UnreadBody(io.BytesIO):
                def read(self, *a):
                    raise AssertionError("preview rejection read body")
            environ = {"PATH_INFO": path, "REQUEST_METHOD": "GET", "QUERY_STRING": query,
                       "HTTP_AUTHORIZATION": "Bearer synthetic-token", "wsgi.input": UnreadBody()}
            if supplied is not None:
                environ["HTTP_X_CLRS_PREVIEW_PROOF"] = supplied
            body = application(environ, lambda status, headers: state.update(status=status))
            list(body)
            if callable(getattr(body, "close", None)):
                body.close()
            return state["status"]
        preview = app(env)
        self.assertEqual(calls, [])
        for route in ("/v1/auth/login", "/v1/auth/refresh", "/v1/auth/logout",
                      "/v1/me/profile", "/v1/chats", "/v1/meetings", "/v1/media/synthetic"):
            for supplied in (None, "invalid", base64.b64encode(b"x" * 32).decode()):
                self.assertEqual(request(preview, route, supplied, "proof=" + proof), "404 Not Found")
        for route in ("/", "/health", "/healthz"):
            self.assertEqual(request(preview, route), "200 OK")
        self.assertEqual(request(preview, "/readyz"), "503 Service Unavailable")
        self.assertEqual(calls, [])
        for invalid in (None, "", "invalid", base64.b64encode(b"x" * 31).decode()):
            invalid_env = {**env, "CLRS_PREVIEW_ACCESS_KEY_B64": invalid}
            self.assertEqual(request(app(invalid_env), "/v1/me/profile", proof), "503 Service Unavailable")
        self.assertEqual(request(app({**env, "CLRS_PREVIEW_GUARD_ENABLED": "true"}),
                                 "/v1/me/profile", proof), "503 Service Unavailable")
        self.assertEqual(calls, [])
        self.assertEqual(request(preview, "/v1/me/profile", proof), "200 OK")
        self.assertEqual(calls, ["legacy", "media", "native", "auth", "sql"])
        self.assertEqual(request(preview, "/v1/me/profile", proof.rstrip("=")), "200 OK")
        self.assertEqual(calls.count("native"), 1)
        preview.close()
        self.assertEqual(calls[-2:], ["media-closed", "native-closed"])
        calls.clear()
        app({k: v for k, v in env.items() if not k.startswith("CLRS_PREVIEW_")})
        self.assertEqual(calls, ["legacy", "media", "native"])


if __name__ == "__main__":
    unittest.main()
