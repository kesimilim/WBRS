"""Native test completion through existing isolated transaction/store fixtures."""
import copy
import io
import json
import ssl
import unittest

from legacy_own_profile import _age, _string
from legacy_conversation_payload import LegacyInvalid
from runtime_http import RuntimeMutationHttp
from runtime_profile import RuntimeProfileService, validate_temperament, _temperament
from runtime_mutations import RuntimeInvalidRequest, request_digest
from test_runtime_full_profile import (ProfileDatabase, ProfileConnection, ProfileCursor,
                                      SQL_COLUMNS, Native, profile, request)
from test_runtime_mutations import ENV, STAMP, store_for


PATH = "/v1/runtime/me/temperament"
OP = "12345678-1234-4234-8234-123456789abc"
SECOND_OP = "12345678-1234-4234-8234-123456789abd"
NEXT = "2027-01-15T08:00:00.000002Z"
OPERATION = "profile.complete-test.v1"


def payload(values=(20, 5, 5, 5), stamp=STAMP):
    return {"expectedUpdatedAt": stamp, "scores": dict(zip(("brown", "red", "blue", "white"), values))}


def retained_details(age=None):
    return {"fields": {"fullName": {"stringValue": "  Старое имя  "},
        "age": {"integerValue": "28"} if age is None else age,
        "pol": {"stringValue": "мужской"}, "about": {"stringValue": "Коротко"},
        "hobbi": {"stringValue": "\t"}}}


def retained_details_ready(source):
    # The no-TCP SQL fixture evaluates the source predicate with the actual
    # legacy typed decoders; production returns only its SQL Boolean.
    try:
        fields = source["fields"]
        return (bool(_string(fields, "fullName", 1000).strip()) and _age(fields) is not None
                and all(_string(fields, name, maximum) not in (None, "")
                        for name, maximum in (("pol", 191), ("about", 4096), ("hobbi", 4096))))
    except (LegacyInvalid, KeyError, TypeError, AttributeError):
        return False


class TestDatabase(ProfileDatabase):
    def __init__(self):
        super().__init__()
        self.state["profiles"]["actor"]["legacy_raw"] = retained_details()
        self.bad_json_proof = False

    def connect(self, **config):
        assert config["ssl"].verify_mode == ssl.CERT_REQUIRED and config["ssl"].check_hostname
        if self.before_connect:
            self.before_connect()
        connection = TestConnection(self); self.connections.append(connection)
        return connection


class TestConnection(ProfileConnection):
    def cursor(self):
        return TestCursor(self)


class TestCursor(ProfileCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split())
        if sql.startswith("SELECT CASE WHEN (full_name") and sql.endswith("FOR UPDATE"):
            self.c.db.calls.append((sql, params))
            assert self.c.held and not self.c.readonly and params[0] == params[1]
            source = self.c.state["profiles"].get(params[0])
            self.rows = [] if source is None else [tuple(source[column] for column in SQL_COLUMNS) + (1,)]
            self.rowcount = len(self.rows)
            return self.rowcount
        if sql.startswith("SELECT COALESCE((JSON_TYPE(legacy_raw)"):
            self.c.db.calls.append((sql, params))
            assert self.c.held and not self.c.readonly and params[0] == params[1]
            assert sql.endswith("LIMIT 1 FOR SHARE")
            source = self.c.state["profiles"].get(params[0])
            self.rows = [] if source is None else [(int(retained_details_ready(source["legacy_raw"])),)]
            self.rowcount = len(self.rows)
            return self.rowcount
        if sql.startswith("UPDATE clrs_staging.profiles SET primary_group"):
            self.c.db.calls.append((sql, params))
            assert self.c.held and not self.c.readonly and params[2] == params[3]
            primary, result, uid, _, expected = params
            source = self.c.state["profiles"].get(uid)
            self.rowcount = 0
            if source and source["updated_at"][:-1].replace("T", " ") == expected:
                source["primary_group"] = primary; source["test_result"] = json.loads(result)
                source["registration_complete"] = 1; source["updated_at"] = NEXT
                self.rowcount = 1
            return self.rowcount
        if sql.startswith("SELECT JSON_TYPE(test_result)"):
            self.c.db.calls.append((sql, params))
            assert self.c.held and params[1] == params[2]
            source = self.c.state["profiles"].get(params[1])
            self.rows = [] if source is None else [("OBJECT", len(source["test_result"]),
                int(not self.c.db.bad_json_proof and source["test_result"] == json.loads(params[0])))]
            self.rowcount = len(self.rows)
            return self.rowcount
        return super().execute(statement, params)


class NativeTemperamentTests(unittest.TestCase):
    def setUp(self):
        self.db = TestDatabase(); self.store = store_for(self.db)
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

    def lookup(self, original=None, operation_id=OP, **changes):
        original = payload() if original is None else original
        environ = request(self.db.access, PATH_INFO="/v1/runtime/operations/" + OPERATION + "/" + operation_id,
            QUERY_STRING="requestHash=" + request_digest(original).hex())
        environ.update(changes)
        return self.http.dispatch(environ, native_service=self.native, native_configured=True)

    def profile_updates(self):
        return [(sql, params) for sql, params in self.db.calls if sql.startswith("UPDATE clrs_staging.profiles")]

    def test_transition_derives_group_preserves_other_data_and_full_read_becomes_search(self):
        before = copy.deepcopy(self.db.state)
        reply = self.post(); result = reply.payload["result"]
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(reply.payload["operation"], OPERATION)
        self.assertEqual(reply.payload["state"], "committed")
        self.assertEqual(result, {"uid": "actor", "primaryGroup": "коричнево-белая",
            "isRegistrationEnd": True, "onboarding": "search", "updatedAt": NEXT,
            "profileAuthority": "canonical-current-v1"})
        source = self.db.state["profiles"]["actor"]
        self.assertEqual(source["test_result"], {"scores": payload()["scores"], "primaryGroup": result["primaryGroup"]})
        self.assertEqual(source["registration_complete"], 1)
        for name, value in before["profiles"]["actor"].items():
            if name not in {"primary_group", "test_result", "registration_complete", "updated_at"}:
                self.assertEqual(source[name], value)
        for name, value in before.items():
            if name not in {"profiles", "receipts"}:
                self.assertEqual(self.db.state[name], value)
        self.assertEqual(self.db.state["profiles"]["peer"], before["profiles"]["peer"])
        self.assertEqual(self.service.read_full(self.db.identity, access_token=self.db.access)["onboarding"], "search")
        self.assertEqual(len(self.profile_updates()), 1)
        self.assertEqual(self.profile_updates()[0][1][2:4], ("actor", "actor"))
        self.assertEqual(sum(c.commits for c in self.db.connections), 1)
        self.assertNotIn("scores", result); self.assertNotIn("test_result", result)
        proofs = [(sql, params) for sql, params in self.db.calls if sql.startswith("SELECT COALESCE((JSON_TYPE(legacy_raw)")]
        self.assertEqual(len(proofs), 1)
        proof_sql, proof_uid = proofs[0]
        self.assertEqual(proof_uid, ("actor", "actor"))
        self.assertIn("JSON_LENGTH(JSON_EXTRACT(legacy_raw, '$.fields.age')) = 1", proof_sql)
        self.assertIn("JSON_TYPE(JSON_EXTRACT(legacy_raw, '$.fields.age.doubleValue')) IN ('INTEGER', 'DOUBLE') THEN CAST", proof_sql)
        self.assertIn("CHAR_LENGTH(JSON_UNQUOTE(JSON_EXTRACT(legacy_raw, '$.fields.about.stringValue'))) <= 4096", proof_sql)
        self.assertIn("WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)", proof_sql)

    def test_classifier_preserves_existing_primary_and_secondary_ties(self):
        cases = (([5, 5, 5, 5], "белая"), ([20, 20, 0, 0], "красная"),
            ([20, 0, 20, 0], "синяя"), ([20, 0, 0, 20], "белая"),
            ([20, 5, 5, 5], "коричнево-белая"), ([5, 20, 5, 5], "красно-белая"),
            ([5, 5, 20, 5], "сине-белая"), ([5, 5, 5, 20], "бело-коричневая"),
            ([20, 20, 5, 5], "красно-белая"), ([20, 20, 20, 20], "белая"))
        for values, expected in cases:
            with self.subTest(values=values):
                checked = validate_temperament(payload(values))
                self.assertEqual(_temperament(checked["scores"]), expected)
        self.assertEqual(self.db.connections, [])

    def test_exact_payload_scores_method_and_query_refuse_before_sql(self):
        invalid = (payload([19, 0, 0, 0]), payload([21, 0, 0, 0]), payload([True, 20, 0, 0]),
            payload([20.0, 0, 0, 0]), payload(["20", 0, 0, 0]), payload([-1, 20, 0, 0]),
            {**payload(), "primaryGroup": "красная"}, {**payload(), "uid": "peer"},
            {**payload(), "scores": {**payload()["scores"], "balance": 1}},
            {**payload(), "scores": {"brown": 20}}, {**payload(), "scores": [20, 0, 0, 0]},
            {**payload(), "expectedUpdatedAt": "2026-02-30T18:00:00.000000Z"})
        for body in invalid:
            with self.subTest(body=body):
                self.assertEqual(self.post({"operationId": OP, **body}).status, "400 Bad Request")
        self.assertEqual(self.post(["invalid"]).status, "400 Bad Request")
        self.assertEqual(self.post(REQUEST_METHOD="GET").status, "405 Method Not Allowed")
        self.assertEqual(self.post(QUERY_STRING="uid=peer").status, "400 Bad Request")
        self.assertEqual(self.db.connections, [])
        for disabled in ({}, {**ENV, "CLRS_RUNTIME_WRITES_ENABLED": "0"}):
            http = RuntimeMutationHttp(disabled, service_factory=lambda _: self.fail("Constructed"))
            self.assertEqual(http.dispatch(request(self.db.access, PATH_INFO=PATH, REQUEST_METHOD="POST"),
                native_service=self.native, native_configured=True).status, "404 Not Found")

    def test_missing_incomplete_and_corrupt_sources_cannot_complete(self):
        del self.db.state["profiles"]["actor"]
        missing = self.post()
        self.assertEqual((missing.status, missing.payload["result"]),
            ("404 Not Found", {"error": "profile_not_found"}))
        self.db.state["profiles"]["actor"] = profile(full_name=None, age=None, profile_details_saved=1)
        incomplete = self.post({"operationId": SECOND_OP, **payload()})
        self.assertEqual((incomplete.status, incomplete.payload["result"]),
            ("409 Conflict", {"error": "profile_incomplete"}))
        self.assertEqual(self.profile_updates(), [])
        self.db.state["profiles"]["actor"] = profile(age=True)
        corrupt = self.post({"operationId": "12345678-1234-4234-8234-123456789abe", **payload()})
        self.assertEqual((corrupt.status, corrupt.payload),
            ("503 Service Unavailable", {"error": "service_unavailable"}))
        self.assertEqual(self.profile_updates(), [])
        malformed = retained_details(); malformed["fields"]["fullName"] = {"stringValue": "\u001c\u2000\u3000"}
        cases = ((profile(legacy_raw={}), False),
            (profile(legacy_raw=malformed), False),
            (profile(legacy_raw=retained_details({"integerValue": "28", "stringValue": "28"})), False),
            (profile(legacy_raw=retained_details({"doubleValue": "NaN"})), False),
            (profile(legacy_raw=retained_details({"nullValue": None})), False),
            (profile(legacy_raw=retained_details({"stringValue": "150"})), True),
            (profile(legacy_raw=retained_details({"doubleValue": 28.5})), True),
            (profile(profile_details_saved=1, legacy_raw={}), True))
        allowed = 0
        for index, (source, eligible) in enumerate(cases):
            self.db.state["profiles"]["actor"] = source
            original = copy.deepcopy(source)
            operation = "12345678-1234-4234-8234-123456789ad" + str(index)
            with self.subTest(source_proof=index):
                if index == 0:
                    view = self.service.read_full(self.db.identity, access_token=self.db.access)
                    self.assertEqual(view["onboarding"], "test")
                    self.assertIs(view["profile"]["profileDetailsSaved"], False)
                reply = self.post({"operationId": operation, **payload()})
                if eligible:
                    allowed += 1
                    self.assertEqual(reply.status, "200 OK")
                    self.assertEqual(reply.payload["result"]["onboarding"], "search")
                    self.assertEqual(self.db.state["profiles"]["actor"]["legacy_raw"], original["legacy_raw"])
                else:
                    self.assertEqual((reply.status, reply.payload["result"]),
                        ("409 Conflict", {"error": "profile_incomplete"}))
                    self.assertEqual(self.db.state["profiles"]["actor"], original)
                self.assertEqual(len(self.profile_updates()), allowed)
        # A fresh native source cannot forge historical readiness by edit8;
        # its refusal is durable and lookup returns the same committed result.
        operation = "12345678-1234-4234-8234-123456789ad0"
        refused = self.lookup(operation_id=operation)
        self.assertEqual((refused.status, refused.payload["state"], refused.payload["result"]),
            ("409 Conflict", "committed", {"error": "profile_incomplete"}))

    def test_cas_and_already_completed_never_override_previous_or_other_device_result(self):
        reply = self.post({"operationId": OP, **payload(stamp="2027-01-15T08:00:00.000000Z")})
        self.assertEqual((reply.status, reply.payload["result"]),
            ("409 Conflict", {"error": "profile_changed", "updatedAt": STAMP}))
        self.assertEqual(self.profile_updates(), [])
        self.db.state["profiles"]["actor"] = profile(primary_group=" КРАСНАЯ ", registration_complete=0)
        existing = copy.deepcopy(self.db.state["profiles"]["actor"])
        reply = self.post({"operationId": SECOND_OP, **payload()})
        self.assertEqual(reply.payload["result"], {"error": "test_already_completed", "updatedAt": STAMP})
        self.assertEqual(self.db.state["profiles"]["actor"], existing)
        self.db.state["profiles"]["actor"] = profile(legacy_raw=retained_details())
        third = "12345678-1234-4234-8234-123456789abe"
        self.post({"operationId": third, **payload()})
        source = copy.deepcopy(self.db.state["profiles"]["actor"])
        reply = self.post({"operationId": "12345678-1234-4234-8234-123456789abf", **payload([0,20,0,0])})
        self.assertEqual(reply.payload["result"]["error"], "profile_changed")
        reply = self.post({"operationId": "12345678-1234-4234-8234-123456789ac0", **payload([0,20,0,0], NEXT)})
        self.assertEqual(reply.payload["result"]["error"], "test_already_completed")
        self.assertEqual(self.db.state["profiles"]["actor"], source)
        self.assertEqual(len(self.profile_updates()), 1)

    def test_unknown_commit_lookup_replay_and_payload_conflict_keep_one_original_mutation(self):
        self.db.commit_unknown_once = True
        unknown = self.post()
        self.assertEqual((unknown.status, unknown.payload),
            ("503 Service Unavailable", {"error": "outcome_unknown"}))
        found = self.lookup()
        self.assertEqual(found.status, "200 OK")
        self.assertTrue(found.payload["replayed"])
        self.assertEqual(found.payload["result"]["primaryGroup"], "коричнево-белая")
        replay = self.post()
        self.assertEqual(replay.payload["result"], found.payload["result"])
        self.assertTrue(replay.payload["replayed"])
        self.assertEqual(len(self.profile_updates()), 1)
        conflict = self.post({"operationId": OP, **payload([0,20,0,0])})
        self.assertEqual((conflict.status, conflict.payload),
            ("409 Conflict", {"error": "operation_conflict"}))
        missing = self.lookup(operation_id=SECOND_OP)
        self.assertEqual(missing.payload["state"], "not_found")
        self.assertEqual(len(self.profile_updates()), 1)
        self.db.state["accounts"]["actor"][0] = 1
        self.assertEqual(self.lookup().status, "401 Unauthorized")

    def test_invalid_written_json_proof_rolls_back_profile_and_receipt(self):
        before = copy.deepcopy(self.db.state); self.db.bad_json_proof = True
        reply = self.post()
        self.assertEqual((reply.status, reply.payload),
            ("503 Service Unavailable", {"error": "service_unavailable"}))
        self.assertEqual(self.db.state, before)
        self.assertEqual(sum(c.commits for c in self.db.connections), 0)
        self.assertTrue(all(c.closed for c in self.db.connections))


if __name__ == "__main__":
    unittest.main()
