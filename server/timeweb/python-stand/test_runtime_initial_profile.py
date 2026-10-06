"""New finish scenarios only: real mutation/photo SQL core, synthetic storage."""
import copy
from datetime import datetime, timedelta
import json
from unittest.mock import patch
from types import SimpleNamespace
import unittest

from native_sessions import NativeIdentity
from runtime_mutations import RuntimeMutationStore, request_digest
from runtime_initial_profile import RuntimeInitialProfileService, OPERATION
from runtime_profile import RuntimeProfileService, _FULL_FIELDS, _FIELDS, _LEGACY_DETAILS_PROOF
from runtime_profile_photo_uploads import RuntimeProfilePhotoUploadsService, COMMIT_OPERATION
from runtime_http import RuntimeMutationHttp, _create
from test_runtime_profile_photo_uploads import PhotoDatabase, PhotoCursor, FakeWriter, DATA, PAYLOAD
from test_runtime_mutations import NOW, STAMP
from test_runtime_http import Native, env

OP = "12345678-1234-4234-8234-123456789abc"
CHANGE = {"fullName": "  Новый участник  ", "age": 30, "rost": 170,
    "about": "Подробный рассказ о себе для анкеты", "hobbi": "Увлечения и интересы нового участника",
    "deti": False, "pol": "мужской", "relationStatus": "не женат"}
GEO = {"countryCode": "RU", "region": "Московская область"}


def advance(value):
    return (datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ") + timedelta(microseconds=1)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def blank():
    return {name: (0 if name in {"profileDetailsSaved", "isRegistrationEnd"} else None) for name in _FULL_FIELDS}


class InitialCursor(PhotoCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); db = self.c.db; state = self.c.state
        initial = sql.startswith("UPDATE clrs_staging.profiles SET about_text")
        full = sql.startswith("SELECT CASE WHEN") and "FROM clrs_staging.profiles" in sql
        if not initial and not full:
            result = super().execute(statement, params)
            if sql.startswith("UPDATE clrs_staging.profiles SET updated_at") and self.rowcount:
                state["profiles"][params[0]] = advance(db.state["profiles"][params[0]])
            return result
        assert self.c.held
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if db.fail_contains and db.fail_contains in sql: raise OSError("synthetic finish failure")
        if full:
            assert params[0] == params[1]
            value = state["initial_profiles"].get(params[0])
            if value is not None:
                self.rows = [tuple(value[name] for name in _FULL_FIELDS) + (state["profiles"][params[0]], 1)]
        else:
            assert not self.c.readonly and "legacy_raw" not in sql
            uid, exact_uid, expected = params[-3:]; assert uid == exact_uid
            value = state["initial_profiles"].get(uid)
            if (value is not None and value["profileDetailsSaved"] == 0 and value["isRegistrationEnd"] == 0
                    and state["profiles"][uid] == expected.replace(" ", "T") + "Z"):
                assignments = sql.split(" SET ", 1)[1].split(", profile_details_saved", 1)[0]
                reverse = {column: name for name, column in {**_FIELDS, "country": "country", "countryCode": "country_code", "region": "region"}.items()}
                for assignment, content in zip(assignments.split(", "), params[:-3]):
                    value[reverse[assignment.split(" = ")[0]]] = int(content) if type(content) is bool else content
                value["profileDetailsSaved"] = 1; state["profiles"][uid] = advance(state["profiles"][uid]); self.rowcount = 1
                if db.revoke_at_finish: state["sessions"][db.identity.session_id]["revoked_at"] = STAMP
                if db.break_photo_at_finish: state["media"][state["photos"][uid][-1][0]][7] = "pending"
        return self.rowcount


class InitialDatabase(PhotoDatabase):
    def __init__(self):
        super().__init__(); self.state["initial_profiles"] = {"actor": blank(), "peer": blank()}
        self.revoke_at_finish = False; self.break_photo_at_finish = False

    def connect(self, **config):
        connection = super().connect(**config); connection.cursor = lambda: InitialCursor(connection)
        return connection


class InitialProfileTests(unittest.TestCase):
    def setup_service(self):
        db = InitialDatabase(); store = RuntimeMutationStore(db.env, db.tokens, connect=db.connect, clock=lambda: NOW)
        self.addCleanup(store.close)
        writer = FakeWriter(); photos = RuntimeProfilePhotoUploadsService(store, writer=writer, clock=lambda: NOW)
        initial = RuntimeInitialProfileService(store, photos=photos); profile = RuntimeProfileService(store)
        native = Native(); native.identity = db.identity
        adapter = RuntimeMutationHttp(db.env, service_factory=lambda _: (store, None, profile, None, None, None, None, None, initial))
        pointers = []
        for index in range(3):
            prepare = f"12345678-1234-4234-8234-{100 + index:012d}"
            commit = f"12345678-1234-4234-8234-{200 + index:012d}"
            ready = photos.prepare(db.identity, prepare, PAYLOAD, access_token=db.access)
            mid = ready.payload["result"]["mediaId"]; writer.objects[db.state["media"][mid][3]] = (DATA, "image/png")
            result = photos.commit(db.identity, commit, {"prepareOperationId": prepare, "mediaId": mid}, access_token=db.access)
            self.assertEqual(result.status, 200)
            pointers.append({"prepareOperationId": prepare, "commitOperationId": commit, "mediaId": mid})
        payload = {"expectedUpdatedAt": db.state["profiles"]["actor"], "changes": copy.deepcopy(CHANGE), "geography": GEO, "photos": pointers}
        def call(body=payload, operation_id=OP):
            request = env("/v1/runtime/me/registration", {"operationId": operation_id, **body})
            request["HTTP_AUTHORIZATION"] = "Bearer " + db.access
            return adapter.dispatch(request, native_service=native, native_configured=True)
        def lookup(owner=native, access=None, operation_id=OP, body=payload):
            request = env(f"/v1/runtime/operations/{OPERATION}/{operation_id}", REQUEST_METHOD="GET", QUERY_STRING="requestHash=" + request_digest(body).hex())
            request["HTTP_AUTHORIZATION"] = "Bearer " + (access or db.access)
            return adapter.dispatch(request, native_service=owner, native_configured=True)
        return db, store, initial, call, lookup, payload

    def test_native_blank_one_cas_three_sql_receipts_and_historical_lookup(self):
        db, store, initial, call, lookup, payload = self.setup_service()
        before = copy.deepcopy(db.state); verifies = sum(sql.startswith("UPDATE clrs_staging.media_objects") for sql, _ in db.calls)
        start = len(db.calls); result = call()
        self.assertEqual((result.status, result.payload["entityRevision"]), ("200 OK", None))
        self.assertEqual(result.payload["requestHash"], request_digest(payload).hex())
        self.assertEqual(result.payload["result"], {"uid": "actor", "profileDetailsSaved": True, "onboarding": "test",
            "updatedAt": db.state["profiles"]["actor"], "profileAuthority": "canonical-current-v1"})
        self.assertEqual(db.state["initial_profiles"]["actor"]["fullName"], CHANGE["fullName"].strip())
        self.assertEqual(db.state["initial_profiles"]["actor"]["isRegistrationEnd"], 0)
        self.assertEqual(db.state["initial_profiles"]["actor"]["country"], "Россия")
        self.assertEqual(db.state["initial_profiles"]["peer"], before["initial_profiles"]["peer"])
        for name in ("legacy", "photos", "media"): self.assertEqual(db.state[name], before[name])
        self.assertEqual(sum(sql.startswith("UPDATE clrs_staging.profiles") for sql, _ in db.calls[start:]), 1)
        self.assertLessEqual(len(db.calls[start:]), 64)
        self.assertEqual(lookup().payload["result"], result.payload["result"])
        # Historical ACK remains valid after a legitimate later edit/test. It
        # neither resets completion nor grants any source/media capability.
        db.state["profiles"]["actor"] = advance(db.state["profiles"]["actor"])
        db.state["initial_profiles"]["actor"].update(fullName="Позже изменено", isRegistrationEnd=1, primaryGroup="белая")
        self.assertEqual(lookup().payload["result"], result.payload["result"])
        self.assertEqual(sum(sql.startswith("UPDATE clrs_staging.media_objects") for sql, _ in db.calls), verifies)
        fresh = {**payload, "expectedUpdatedAt": db.state["profiles"]["actor"]}
        self.assertEqual(call(fresh, OP[:-1] + "d").payload["result"]["error"], "registration_already_completed")

    def test_unknown_commit_restart_original_lookup_never_second_update(self):
        db, store, initial, call, lookup, payload = self.setup_service(); start = len(db.calls)
        db.commit_unknown_once = True; result = call()
        self.assertEqual(result.payload, {"error": "outcome_unknown"})
        self.assertEqual(lookup().payload["result"]["onboarding"], "test")
        self.assertEqual(sum(sql.startswith("UPDATE clrs_staging.profiles") for sql, _ in db.calls[start:]), 1)
        self.assertEqual(lookup(operation_id=OP[:-1] + "e").payload["state"], "not_found")
        # Same UUID with changed immutable content cannot become a new intent.
        changed = {**payload, "changes": {**CHANGE, "age": 31}}
        self.assertEqual(lookup(body=changed).payload, {"error": "operation_conflict"})

    def test_current_owner_stamp_exact_flags_and_real_photo_proof_refusals(self):
        for defect in ("stamp", "pending", "missing-commit", "fake-receipt", "missing-row", "nonowner", "index", "saved", "nullflags"):
            with self.subTest(defect=defect):
                db, store, initial, call, lookup, payload = self.setup_service(); start = len(db.calls)
                pointer = payload["photos"][-1]
                if defect == "stamp": payload["expectedUpdatedAt"] = STAMP
                if defect == "pending": db.state["media"][pointer["mediaId"]][7] = "pending"
                if defect == "missing-commit": del db.state["receipts"][("actor", COMMIT_OPERATION, pointer["commitOperationId"])]
                if defect == "fake-receipt":
                    row = db.state["receipts"][("actor", COMMIT_OPERATION, pointer["commitOperationId"])]
                    wrapper = json.loads(row[3]); wrapper["response"]["ordinal"] = 0; row[3] = json.dumps(wrapper)
                if defect == "missing-row": del db.state["media"][pointer["mediaId"]]
                if defect == "nonowner": db.state["media"][pointer["mediaId"]][1] = "peer"
                if defect == "index": db.indexes_ok = False
                if defect == "saved": db.state["initial_profiles"]["actor"]["profileDetailsSaved"] = 1
                if defect == "nullflags": db.state["initial_profiles"]["actor"]["profileDetailsSaved"] = None
                result = call()
                self.assertIn(result.status, ("404 Not Found", "409 Conflict", "503 Service Unavailable"))
                self.assertFalse(any(sql.startswith("UPDATE clrs_staging.profiles") for sql, _ in db.calls[start:]))
                if defect in {"stamp", "pending", "missing-commit", "fake-receipt", "missing-row", "nonowner", "saved"}:
                    self.assertEqual(result.payload["state"], "committed")
                    self.assertEqual(lookup().payload["result"], result.payload["result"])
        db, store, initial, call, lookup, payload = self.setup_service(); self.assertEqual(call().status, "200 OK")
        session, token = db.tokens.mint("peer", "device-b", 0, NOW); db.state["sessions"][session["session_id"]] = session
        native_b = Native(); native_b.identity = NativeIdentity("peer", True, session["session_id"], NOW, NOW + 900)
        self.assertEqual(lookup(owner=native_b, access=token["accessToken"]).payload["state"], "not_found")
        db.state["sessions"][db.identity.session_id]["revoked_at"] = STAMP
        self.assertEqual(lookup().status, "401 Unauthorized")

    def test_rollback_after_update_revocation_postproof_or_receipt_failure(self):
        for defect in ("session", "photo", "receipt"):
            with self.subTest(defect=defect):
                db, store, initial, call, lookup, payload = self.setup_service(); before = copy.deepcopy(db.state)
                db.revoke_at_finish = defect == "session"; db.break_photo_at_finish = defect == "photo"
                if defect == "receipt": db.fail_contains = "UPDATE clrs_staging.idempotency_receipts"
                result = call(); self.assertIn(result.status, ("401 Unauthorized", "503 Service Unavailable"))
                self.assertEqual(db.state, before)
                self.assertEqual(lookup().payload["state"], "not_found")

    def test_wire_validation_closed_factory_and_shared_instance(self):
        db, store, initial, call, lookup, payload = self.setup_service()
        for invalid in ({**payload, "photos": payload["photos"][:2]},
                {**payload, "photos": [payload["photos"][0]] * 3},
                {**payload, "changes": {**CHANGE, "ownerUid": "peer"}},
                {**payload, "geography": {"countryCode": "RU", "region": "Нет такого региона"}},
                {**payload, "changes": {**CHANGE, "age": True}}):
            self.assertEqual(call(invalid).status, "400 Bad Request")
        fresh_db = InitialDatabase()
        fresh_store = RuntimeMutationStore(fresh_db.env, fresh_db.tokens, connect=fresh_db.connect, clock=lambda: NOW)
        self.addCleanup(fresh_store.close)
        with patch("runtime_http.RuntimeMutationStore.from_env", return_value=fresh_store):
            services = _create(fresh_db.env)
            self.assertIs(services[8]._store, fresh_store)
            self.assertIs(services[8]._photos._store, fresh_store)
            self.assertIsNone(services[8]._photos._writer)
            self.assertEqual(set(fresh_store._replay_guards).intersection({COMMIT_OPERATION}), {COMMIT_OPERATION})
        disabled = RuntimeMutationHttp({}, service_factory=lambda _: self.fail("default-off construction"))
        self.assertEqual(disabled.dispatch(env("/v1/runtime/me/registration", {})).status, "404 Not Found")


if __name__ == "__main__": unittest.main()
