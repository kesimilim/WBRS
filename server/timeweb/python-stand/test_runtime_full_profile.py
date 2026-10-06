"""Current own full-profile HTTP through the real bounded native read store.

The connector is MySQL-shaped and isolated: no TCP, deployment or real users.
"""
import copy
from dataclasses import replace
import json
import ssl
import unittest
from unittest.mock import patch

from native_sessions import NativeIdentity
from runtime_http import RuntimeMutationHttp
from runtime_profile import RuntimeProfileService
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, canonical_json
from test_runtime_mutations import (FakeDatabase, FakeConnection, FakeCursor,
                                   ENV, STAMP, NOW, store_for)


PATH = "/v1/runtime/me/full-profile"
PROFILE_KEYS = {"fullName", "age", "rost", "about", "hobbi", "deti", "pol",
    "relationStatus", "country", "countryCode", "region", "city", "languageCode",
    "primaryGroup", "secondaryGroup", "profileDetailsSaved", "isRegistrationEnd",
    "updatedAt"}
ENVELOPE_KEYS = {"uid", "profileExists", "profile", "onboarding", "profileAuthority", "mediaReady"}
GROUPS = ("коричнево-красная", "коричнево-синяя", "коричневая", "коричнево-белая",
    "бело-коричневая", "бело-красная", "бело-синяя", "белая", "сине-белая",
    "красно-синяя", "красно-белая", "красная", "красно-коричневая", "синяя",
    "сине-коричневая", "сине-красная")
SQL_COLUMNS = ("full_name", "age", "height_cm", "about_text", "interests_text",
    "has_children", "gender", "relationship_status", "country", "country_code",
    "region", "city", "language_code", "primary_group", "secondary_group",
    "profile_details_saved", "registration_complete", "updated_at")


def profile(**changes):
    return {"full_name": "  Имя  ", "age": 28, "height_cm": 180,
        "about_text": " Коротко ", "interests_text": "Хобби\n", "has_children": 0,
        "gender": "мужской", "relationship_status": "не женат",
        "country": " Россия ", "country_code": "RU", "region": "Москва",
        "city": "Москва", "language_code": "ru", "primary_group": None,
        "secondary_group": None, "profile_details_saved": 0,
        "registration_complete": 0, "updated_at": STAMP,
        "legacy_raw": {"email": "private@example.invalid", "balance": 123,
                       "profilePic": "https://example.invalid/?token=private"},
        "test_result": {"privateAnswers": [1, 2]}, **changes}


class ProfileDatabase(FakeDatabase):
    def __init__(self):
        super().__init__()
        self.state["profiles"] = {"actor": profile(), "peer": profile(full_name="Собеседник")}
        self.after_profile_read = None
        self.oversize_valid_bit = None

    def connect(self, **config):
        assert config["ssl"].verify_mode == ssl.CERT_REQUIRED and config["ssl"].check_hostname
        if self.before_connect:
            self.before_connect()
        connection = ProfileConnection(self); self.connections.append(connection)
        return connection


class ProfileConnection(FakeConnection):
    def cursor(self):
        return ProfileCursor(self)


class ProfileCursor(FakeCursor):
    def execute(self, statement, params=()):
        sql = " ".join(statement.split())
        if sql.startswith("SELECT CASE WHEN (full_name") and "FROM clrs_staging.profiles" in sql:
            self.c.db.calls.append((sql, params))
            assert sql.endswith("LIMIT 1 FOR SHARE") and self.c.readonly and self.c.held
            source = self.c.state["profiles"].get(params[0])
            self.rows = []
            if source is not None:
                values = [source[column] for column in SQL_COLUMNS]
                valid = 1
                for index, column in enumerate(SQL_COLUMNS):
                    if column in {"age", "height_cm", "has_children", "profile_details_saved",
                                  "registration_complete", "updated_at"}:
                        continue
                    value = source[column]
                    maximum = 1000 if column == "full_name" else (
                        4096 if column in {"about_text", "interests_text"} else 191)
                    # Model SQL CHAR_LENGTH/OCTET_LENGTH without accepting a
                    # masked oversized value as a real NULL.
                    if isinstance(value, str) and (len(value) > maximum
                            or len(value.encode("utf-8", errors="surrogatepass")) > maximum * 4):
                        values[index] = None; valid = 0
                if self.c.db.oversize_valid_bit is not None:
                    valid = self.c.db.oversize_valid_bit
                self.rows = [tuple(values) + (valid,)]
            self.rowcount = len(self.rows)
            if self.c.db.after_profile_read:
                self.c.db.after_profile_read()
            return self.rowcount
        return super().execute(statement, params)


class Native:
    def __init__(self, db):
        self.identity = db.identity; self.calls = []

    def authorize(self, token, *, peer):
        self.calls.append((token, peer))
        return self.identity


class ForbiddenInput:
    def read(self, _):
        raise AssertionError("Full-profile GET must never read input")


def request(token, **changes):
    return {"REQUEST_METHOD": "GET", "PATH_INFO": PATH, "QUERY_STRING": "",
        "CONTENT_LENGTH": "0", "HTTP_AUTHORIZATION": "Bearer " + token,
        "REMOTE_ADDR": "socket-peer", "wsgi.input": ForbiddenInput(), **changes}


class CurrentOwnFullProfileTests(unittest.TestCase):
    def setUp(self):
        self.db = ProfileDatabase(); self.store = store_for(self.db)
        self.service = RuntimeProfileService(self.store)
        self.native = Native(self.db)
        self.http = RuntimeMutationHttp(ENV, service_factory=lambda _: (self.store, None, self.service))
        self.addCleanup(self.http.close)

    def read(self, **changes):
        return self.http.dispatch(request(self.db.access, **changes),
            native_service=self.native, native_configured=True)

    def profile_queries(self):
        return [(sql, params) for sql, params in self.db.calls if "FROM clrs_staging.profiles" in sql]

    def test_exact_current_envelope_short_source_and_private_fields_are_not_exposed(self):
        before = copy.deepcopy(self.db.state)
        reply = self.read(); view = reply.payload
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(set(view), ENVELOPE_KEYS)
        self.assertEqual(set(view["profile"]), PROFILE_KEYS)
        self.assertEqual((view["uid"], view["profileExists"], view["onboarding"]), ("actor", True, "test"))
        self.assertEqual(view["profileAuthority"], "canonical-current-v1")
        self.assertIs(view["mediaReady"], False)
        self.assertEqual(view["profile"]["fullName"], "  Имя  ")
        self.assertEqual(view["profile"]["about"], " Коротко ")
        self.assertEqual(view["profile"]["hobbi"], "Хобби\n")
        self.assertEqual(view["profile"]["country"], " Россия ")
        self.assertEqual(view["profile"]["updatedAt"], STAMP)
        self.assertIs(view["profile"]["deti"], False)
        for secret in ("private", "legacy_raw", "test_result", "balance", "email", "profilePic", "role"):
            self.assertNotIn(secret, json.dumps(view))
        self.assertEqual(self.db.state, before)
        self.assertEqual(sum(c.commits for c in self.db.connections), 0)
        self.assertTrue(all(c.closed and c.readonly for c in self.db.connections))
        sql, params = self.profile_queries()[0]
        self.assertEqual(params, ("actor", "actor"))
        self.assertIn("WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY) LIMIT 1 FOR SHARE", sql)
        self.assertIn("OCTET_LENGTH(about_text) <= 16384", sql)
        self.assertIn("CHAR_LENGTH(full_name) <= 1000", sql)
        self.assertNotIn("legacy_raw", sql); self.assertNotIn("test_result", sql)
        proofs = [sql for sql, _ in self.db.calls if "FROM clrs_staging.device_sessions AS s" in sql]
        self.assertEqual(len(proofs), 2)

    def test_absent_nullable_and_real_partial_profiles_remain_truthful(self):
        del self.db.state["profiles"]["actor"]
        reply = self.read()
        self.assertEqual(reply.payload, {"uid": "actor", "profileExists": False,
            "profile": None, "onboarding": "registration",
            "profileAuthority": "canonical-current-v1", "mediaReady": False})
        nullable = profile(**{key: None for key in SQL_COLUMNS if key != "updated_at"})
        self.db.state["profiles"]["actor"] = nullable
        view = self.read().payload
        self.assertTrue(view["profileExists"])
        self.assertEqual(view["onboarding"], "registration")
        self.assertTrue(all(value is None for key, value in view["profile"].items() if key != "updatedAt"))
        self.db.state["profiles"]["actor"] = profile(interests_text="", primary_group="unknown",
            secondary_group="красная")
        self.assertEqual(self.read().payload["onboarding"], "registration")

    def test_existing_completion_exact_groups_and_saved_details_gate(self):
        for group in GROUPS:
            self.db.state["profiles"]["actor"] = profile(full_name=None, age=None,
                about_text=None, primary_group="  " + group.upper() + "  ")
            with self.subTest(group=group):
                view = self.read().payload
                self.assertEqual(view["onboarding"], "search")
                self.assertEqual(view["profile"]["primaryGroup"], "  " + group.upper() + "  ")
        self.db.state["profiles"]["actor"] = profile(full_name=None, age=None,
            registration_complete=1, primary_group="unknown")
        self.assertEqual(self.read().payload["onboarding"], "search")
        self.db.state["profiles"]["actor"] = profile(full_name=None, age=None,
            about_text=None, profile_details_saved=1)
        self.assertEqual(self.read().payload["onboarding"], "test")
        self.db.state["profiles"]["actor"] = profile(full_name=" \t", profile_details_saved=0)
        self.assertEqual(self.read().payload["onboarding"], "registration")
        self.db.state["profiles"]["actor"] = profile(gender=" ", about_text="\n", interests_text="\t")
        self.assertEqual(self.read().payload["onboarding"], "test")

    def test_corrupt_present_fields_never_fabricate_null_false_or_registration(self):
        malformed = {"age": (True, -1, 131, "28", 28.0),
            "height_cm": (False, -1, 301, "180"),
            "has_children": (True, 2, "0"), "profile_details_saved": (False, 2, "1"),
            "registration_complete": (True, 2, "false"), "full_name": (123, "bad\x00name", "\ud800"),
            "about_text": ({"value": "x"}, "bad\x7f"), "primary_group": (123, ["красная"]),
            "secondary_group": ({},), "language_code": (False,),
            "updated_at": (None, "2026-02-30T18:00:00.000000Z", "2026-10-01T18:00:00Z")}
        for column, values in malformed.items():
            for value in values:
                self.db.state["profiles"]["actor"] = profile(**{column: value})
                with self.subTest(column=column, value=repr(value)):
                    reply = self.read()
                    self.assertEqual((reply.status, reply.payload),
                        ("503 Service Unavailable", {"error": "service_unavailable"}))
        self.db.state["profiles"]["actor"] = profile()
        for marker in (False, 0, 2, "1"):
            self.db.oversize_valid_bit = marker
            self.assertEqual(self.read().status, "503 Service Unavailable")

    def test_utf8_and_character_bounds_preserve_whole_source_values(self):
        maximum = profile(full_name="😀" * 1000, about_text="😀" * 4096,
            interests_text="😀" * 4096)
        for column in ("gender", "relationship_status", "country", "country_code", "region",
                       "city", "language_code", "primary_group", "secondary_group"):
            maximum[column] = "😀" * 191
        self.db.state["profiles"]["actor"] = maximum
        view = self.read().payload
        self.assertEqual(view["profile"]["about"], "😀" * 4096)
        self.assertLessEqual(len(canonical_json(view)), 65536)
        # Match app.py's actual wire encoding, including JSON escape growth.
        # Escaped CR/LF/TAB/quote/backslash use two bytes per scalar, whereas
        # non-ASCII astral scalars use four with ensure_ascii=False throughout.
        for fill in ("\r", "\n", "\t", '"', "\\", "Ж", "😀"):
            escaped = profile(full_name=fill * 1000, about_text=fill * 4096,
                interests_text=fill * 4096)
            for column in ("gender", "relationship_status", "country", "country_code", "region",
                           "city", "language_code", "primary_group", "secondary_group"):
                escaped[column] = fill * 191
            self.db.state["profiles"]["actor"] = escaped
            with self.subTest(fill=repr(fill)):
                result = self.read()
                self.assertEqual(result.status, "200 OK")
                wire = json.dumps(result.payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                self.assertEqual(len(wire), len(canonical_json(result.payload)))
                self.assertLessEqual(len(wire), 65536)
                self.assertEqual(result.payload["profile"]["about"], fill * 4096)
        for column, value in (("full_name", "😀" * 1001), ("about_text", "a" * 4097),
                              ("country_code", "😀" * 192)):
            self.db.state["profiles"]["actor"] = profile(**{column: value})
            with self.subTest(column=column):
                self.assertEqual(self.read().status, "503 Service Unavailable")

    def test_query_body_post_and_target_path_rejected_before_authorization(self):
        for changes in ({"QUERY_STRING": "uid=peer"}, {"QUERY_STRING": "&"},
                        {"QUERY_STRING": "limit=1"}, {"QUERY_STRING": None},
                        {"CONTENT_LENGTH": "1"}, {"HTTP_TRANSFER_ENCODING": "chunked"}):
            with self.subTest(changes=changes):
                self.assertEqual(self.read(**changes).status, "400 Bad Request")
        self.assertEqual(self.read(REQUEST_METHOD="POST").status, "405 Method Not Allowed")
        self.assertIsNone(self.read(PATH_INFO=PATH + "/peer"))
        self.assertEqual(self.native.calls, [])
        self.assertEqual(self.db.connections, [])

    def test_default_off_no_firebase_fallback_and_unavailable_service(self):
        for config in ({}, {**ENV, "CLRS_RUNTIME_WRITES_ENABLED": "0"},
                       {**ENV, "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY": "immutable-reviewed-snapshot"}):
            http = RuntimeMutationHttp(config, service_factory=lambda _: self.fail("Constructed"))
            self.assertEqual(http.dispatch(request(self.db.access), native_service=self.native,
                native_configured=True).status, "404 Not Found")
        for header in ("Bearer firebase.jwt", "Bearer nr1.refresh", "Bearer na1. bad"):
            self.assertEqual(self.read(HTTP_AUTHORIZATION=header).status, "401 Unauthorized")
        self.assertEqual(self.native.calls, [])
        self.assertEqual(self.db.connections, [])
        http = RuntimeMutationHttp(ENV, service_factory=lambda _: (_ for _ in ()).throw(RuntimeUnavailable()))
        self.assertEqual(http.dispatch(request(self.db.access), native_service=self.native,
            native_configured=True).status, "503 Service Unavailable")

    def test_store_serialization_budget_failure_is_server_unavailable(self):
        with patch("runtime_mutations.canonical_json", side_effect=RuntimeInvalidRequest()):
            reply = self.read()
        self.assertEqual((reply.status, reply.payload),
            ("503 Service Unavailable", {"error": "service_unavailable"}))
        self.assertEqual(len(self.profile_queries()), 1)
        self.assertEqual(sum(c.commits for c in self.db.connections), 0)

    def test_native_proof_disabled_revoked_wrong_uid_and_access_expiry(self):
        before = copy.deepcopy(self.db.state)
        for kind in ("disabled", "blocked", "revoked", "version", "wrong_uid"):
            self.db.state = copy.deepcopy(before); self.db.calls.clear()
            self.native.identity = self.db.identity
            if kind == "disabled": self.db.state["accounts"]["actor"][0] = 1
            if kind == "blocked": self.db.state["accounts"]["actor"][1] = "blocked"
            if kind == "version": self.db.state["accounts"]["actor"][2] += 1
            if kind == "revoked": self.db.state["sessions"][self.db.identity.session_id]["revoked_at"] = STAMP
            if kind == "wrong_uid": self.native.identity = replace(self.db.identity, uid="peer")
            with self.subTest(kind=kind):
                reply = self.read()
                self.assertEqual(reply.status, "401 Unauthorized")
                self.assertTrue(reply.authenticate)
                self.assertEqual(self.profile_queries(), [])
        self.db.state = before; self.native.identity = self.db.identity
        clock = [NOW]; self.store._clock = lambda: clock[0]
        self.db.after_profile_read = lambda: clock.__setitem__(0, NOW + 901)
        self.assertEqual(self.read().status, "401 Unauthorized")
        self.assertEqual(sum(c.commits for c in self.db.connections), 0)

    def test_second_native_owner_reads_only_its_own_profile(self):
        session, tokens = self.db.tokens.mint("peer", "other-device", 0, NOW)
        self.db.state["sessions"][session["session_id"]] = session
        self.native.identity = NativeIdentity("peer", True, session["session_id"], NOW, NOW + 900)
        reply = self.http.dispatch(request(tokens["accessToken"]), native_service=self.native,
            native_configured=True)
        self.assertEqual(reply.status, "200 OK")
        self.assertEqual(reply.payload["uid"], "peer")
        self.assertEqual(reply.payload["profile"]["fullName"], "Собеседник")
        self.assertEqual(self.profile_queries()[0][1], ("peer", "peer"))


if __name__ == "__main__":
    unittest.main()
