"""Own geography CAS against the pinned asset and existing no-TCP store fixture."""
import copy
import hashlib
import io
import json
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest.mock import patch

from runtime_geography import CATALOG_SHA256, _catalog, _decode_catalog, resolve_geography
from runtime_http import RuntimeMutationHttp
from runtime_profile import RuntimeProfileService, ProfileEditInvalid, validate_profile_edit
from runtime_mutations import RuntimeUnavailable, request_digest
from test_runtime_full_profile import Native, profile, request
from test_runtime_temperament import TestDatabase, TestConnection, TestCursor, OP, SECOND_OP, NEXT
from test_runtime_mutations import ENV, STAMP, store_for


PATH = "/v1/runtime/me/geography"
OPERATION = "profile.edit-geography.v1"
CHANGES = {"countryCode": "AU", "region": "New South Wales"}


def payload(changes=None, stamp=STAMP):
    return {"expectedUpdatedAt": stamp, "changes": dict(CHANGES if changes is None else changes)}


class GeographyDatabase(TestDatabase):
    def __init__(self):
        super().__init__()
        self.state["profiles"]["actor"]["profile_details_saved"] = 1
        self.change_non_geo = False

    def connect(self, **config):
        assert config["ssl"].verify_mode == ssl.CERT_REQUIRED and config["ssl"].check_hostname
        if self.before_connect:
            self.before_connect()
        connection = GeographyConnection(self); self.connections.append(connection)
        return connection


class GeographyConnection(TestConnection):
    def cursor(self):
        return GeographyCursor(self)


class GeographyCursor(TestCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split())
        if sql.startswith("UPDATE clrs_staging.profiles SET country"):
            self.c.db.calls.append((sql, params))
            assert self.c.held and not self.c.readonly and params[3] == params[4]
            country, code, region, uid, _, expected = params
            source = self.c.state["profiles"].get(uid)
            self.rowcount = 0
            if source and source["updated_at"][:-1].replace("T", " ") == expected:
                source["country"] = country; source["country_code"] = code
                source["region"] = region; source["updated_at"] = NEXT
                if self.c.db.change_non_geo:
                    source["city"] = "unexpected source change"
                self.rowcount = 1
            return self.rowcount
        return super().execute(statement, params)


class NativeGeographyTests(unittest.TestCase):
    def setUp(self):
        self.db = GeographyDatabase(); self.store = store_for(self.db)
        self.service = RuntimeProfileService(self.store); self.native = Native(self.db)
        self.http = RuntimeMutationHttp(ENV, service_factory=lambda _: (self.store, None, self.service))
        self.addCleanup(self.http.close)

    def post(self, body=None, **changes):
        body = {"operationId": OP, **payload()} if body is None else body
        raw = json.dumps(body).encode()
        environ = request(self.db.access, PATH_INFO=PATH, REQUEST_METHOD="POST",
            CONTENT_TYPE="application/json", CONTENT_LENGTH=str(len(raw)), **{"wsgi.input": io.BytesIO(raw)})
        environ.update(changes)
        return self.http.dispatch(environ, native_service=self.native, native_configured=True)

    def lookup(self, original=None, operation_id=OP):
        original = payload() if original is None else original
        return self.http.dispatch(request(self.db.access,
            PATH_INFO="/v1/runtime/operations/" + OPERATION + "/" + operation_id,
            QUERY_STRING="requestHash=" + request_digest(original).hex()),
            native_service=self.native, native_configured=True)

    def profile_updates(self):
        return [(sql, params) for sql, params in self.db.calls if sql.startswith("UPDATE clrs_staging.profiles")]

    def test_bundle_matches_exact_approved_asset_and_supported_country_region(self):
        stand = Path(__file__).resolve().parent
        approved = stand.parents[2] / "assets" / "geo_catalog.json"
        bundled = (stand / "geo_catalog.json").read_bytes()
        self.assertEqual(bundled, approved.read_bytes())
        self.assertEqual(hashlib.sha256(bundled).hexdigest(), CATALOG_SHA256)
        self.assertEqual(len(_decode_catalog(bundled)), 56)
        self.assertEqual(resolve_geography(CHANGES), {"country": "Австралия", **CHANGES})
        self.assertEqual(resolve_geography({"countryCode": "RU", "region": "Республика Дагестан"}),
            {"country": "Россия", "countryCode": "RU", "region": "Республика Дагестан"})
        self.assertEqual(self.db.connections, [])

    def test_geo_save_derives_country_preserves_all_other_source_data_and_destination(self):
        before = copy.deepcopy(self.db.state)
        prior_destination = self.service.read_full(self.db.identity, access_token=self.db.access)["onboarding"]
        reply = self.post()
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(reply.payload["operation"], OPERATION)
        self.assertEqual(reply.payload["result"], {"uid": "actor", "country": "Австралия", **CHANGES,
            "updatedAt": NEXT, "profileAuthority": "canonical-current-v1"})
        source = self.db.state["profiles"]["actor"]
        self.assertEqual((source["country"], source["country_code"], source["region"]),
            ("Австралия", "AU", "New South Wales"))
        for name, value in before["profiles"]["actor"].items():
            if name not in {"country", "country_code", "region", "updated_at"}:
                self.assertEqual(source[name], value)
        for name, value in before.items():
            if name not in {"profiles", "receipts"}:
                self.assertEqual(self.db.state[name], value)
        self.assertEqual(self.db.state["profiles"]["peer"], before["profiles"]["peer"])
        self.assertEqual(self.service.read_full(self.db.identity, access_token=self.db.access)["onboarding"], prior_destination)
        sql, params = self.profile_updates()[0]
        self.assertEqual(params[3:5], ("actor", "actor"))
        self.assertIn("AND updated_at = CAST(%s AS DATETIME(6))", sql)
        self.assertNotIn("legacy_raw", sql); self.assertNotIn("test_result", sql)
        self.assertNotIn("city", sql); self.assertNotIn("language_code", sql)
        self.assertEqual(sum(c.commits for c in self.db.connections), 1)

    def test_ready_legacy_completion_is_accepted_but_blank_fallback_and_false_saved_proof_are_not(self):
        states = (profile(registration_complete=1, full_name=None, age=None),
            profile(primary_group=" КРАСНАЯ ", registration_complete=0, full_name=None, age=None))
        for index, source in enumerate(states):
            self.db.state["profiles"]["actor"] = source
            with self.subTest(index=index):
                reply = self.post({"operationId": OP if index == 0 else SECOND_OP, **payload()})
                self.assertEqual(reply.status, "200 OK")
                self.assertEqual(self.service.read_full(self.db.identity, access_token=self.db.access)["onboarding"], "search")
        self.assertEqual(len(self.profile_updates()), 2)
        for index, source in enumerate((profile(), profile(full_name=None, age=None),
                                       profile(full_name=None, age=None, profile_details_saved=1))):
            self.db.state["profiles"]["actor"] = source
            operation = "12345678-1234-4234-8234-123456789ac" + str(index)
            with self.subTest(unready=index):
                reply = self.post({"operationId": operation, **payload()})
                self.assertEqual((reply.status, reply.payload["result"]),
                    ("409 Conflict", {"error": "profile_not_ready"}))
                self.assertEqual(self.db.state["profiles"]["actor"], source)
        self.assertEqual(len(self.profile_updates()), 2)

    def test_missing_cas_and_noop_keep_truthful_receipts_without_profile_write(self):
        self.db.state["profiles"]["actor"] = profile(profile_details_saved=1,
            country="Австралия", country_code="AU", region="New South Wales")
        noop = self.post()
        self.assertEqual(noop.payload["result"]["updatedAt"], STAMP)
        self.assertEqual(self.profile_updates(), [])
        stale = self.post({"operationId": SECOND_OP, **payload(stamp="2027-01-15T08:00:00.000000Z")})
        self.assertEqual((stale.status, stale.payload["result"]),
            ("409 Conflict", {"error": "profile_changed", "updatedAt": STAMP}))
        del self.db.state["profiles"]["actor"]
        missing = self.post({"operationId": "12345678-1234-4234-8234-123456789abe", **payload()})
        self.assertEqual((missing.status, missing.payload["result"]),
            ("404 Not Found", {"error": "profile_not_found"}))
        self.assertEqual(self.profile_updates(), [])
        self.assertNotIn("actor", self.db.state["profiles"])

    def test_exact_pair_catalog_membership_and_no_foreign_or_old_editor_fields(self):
        invalid = ({"countryCode": "AU"}, {"region": "New South Wales"},
            {"countryCode": "au", "region": "New South Wales"},
            {"countryCode": "ZZ", "region": "New South Wales"},
            {"countryCode": "US", "region": "Москва"}, {**CHANGES, "country": "forged"},
            {**CHANGES, "city": "Sydney"}, {**CHANGES, "languageCode": "en"},
            {**CHANGES, "uid": "peer"}, {**CHANGES, "profileDetailsSaved": True},
            {**CHANGES, "region": " New South Wales "}, {**CHANGES, "region": True},
            {**CHANGES, "region": "\ud800"}, {**CHANGES, "region": "x" * 192})
        for changes in invalid:
            with self.subTest(changes=repr(changes)):
                self.assertEqual(self.post({"operationId": OP, **payload(changes)}).status, "400 Bad Request")
        self.assertEqual(self.post(REQUEST_METHOD="GET").status, "405 Method Not Allowed")
        self.assertEqual(self.post(QUERY_STRING="uid=peer").status, "400 Bad Request")
        self.assertEqual(self.db.connections, [])
        with self.assertRaises(ProfileEditInvalid):
            validate_profile_edit(payload())
        disabled = RuntimeMutationHttp({}, service_factory=lambda _: self.fail("Constructed"))
        self.assertEqual(disabled.dispatch(request(self.db.access, PATH_INFO=PATH, REQUEST_METHOD="POST"),
            native_service=self.native, native_configured=True).status, "404 Not Found")

    def test_missing_or_changed_catalog_fails_closed_before_sql(self):
        with self.assertRaises(RuntimeUnavailable):
            _decode_catalog(b'{"version":2,"countries":[]}')
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing.json"
            changed = Path(directory) / "changed.json"
            changed.write_bytes(Path(__file__).with_name("geo_catalog.json").read_bytes() + b" ")
            try:
                for path in (missing, changed):
                    _catalog.cache_clear()
                    with patch("runtime_geography._CATALOG", path):
                        reply = self.post()
                        self.assertEqual((reply.status, reply.payload),
                            ("503 Service Unavailable", {"error": "service_unavailable"}))
            finally:
                _catalog.cache_clear()
        self.assertEqual(self.db.connections, [])

    def test_unknown_commit_original_hash_lookup_replay_and_disabled_native_owner(self):
        self.db.commit_unknown_once = True
        unknown = self.post()
        self.assertEqual((unknown.status, unknown.payload),
            ("503 Service Unavailable", {"error": "outcome_unknown"}))
        found = self.lookup()
        self.assertEqual(found.status, "200 OK")
        self.assertEqual(found.payload["result"]["country"], "Австралия")
        self.assertTrue(found.payload["replayed"])
        replay = self.post()
        self.assertEqual(replay.payload["result"], found.payload["result"])
        self.assertEqual(len(self.profile_updates()), 1)
        conflict = self.post({"operationId": OP, **payload({"countryCode": "AU", "region": "Victoria"})})
        self.assertEqual((conflict.status, conflict.payload),
            ("409 Conflict", {"error": "operation_conflict"}))
        self.assertEqual(self.lookup(operation_id=SECOND_OP).payload["state"], "not_found")
        self.db.state["accounts"]["actor"][0] = 1
        self.assertEqual(self.lookup().status, "401 Unauthorized")
        self.assertEqual(self.post({"operationId": SECOND_OP, **payload(stamp=NEXT)}).status, "401 Unauthorized")
        self.assertEqual(len(self.profile_updates()), 1)

    def test_corrupt_source_and_non_geo_post_write_change_roll_back(self):
        self.db.state["profiles"]["actor"]["age"] = True
        before = copy.deepcopy(self.db.state)
        reply = self.post()
        self.assertEqual((reply.status, reply.payload),
            ("503 Service Unavailable", {"error": "service_unavailable"}))
        self.assertEqual(self.db.state, before)
        self.assertEqual(self.profile_updates(), [])
        self.db.state["profiles"]["actor"] = profile(profile_details_saved=1)
        before = copy.deepcopy(self.db.state); self.db.change_non_geo = True
        reply = self.post()
        self.assertEqual(reply.status, "503 Service Unavailable")
        self.assertEqual(self.db.state, before)
        self.assertEqual(sum(c.commits for c in self.db.connections), 0)
        self.assertTrue(all(c.closed for c in self.db.connections))


if __name__ == "__main__":
    unittest.main()
