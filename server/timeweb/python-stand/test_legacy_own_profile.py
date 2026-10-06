"""Five targeted synthetic tests; no real archive/SQL/HTTP/Firebase IO."""
import hashlib
import json
import unittest
from legacy_own_profile import LegacyOwnProfileService, GROUPS
from legacy_conversation_read import LegacyReadRejected, LegacyReadUnavailable, DOCUMENT_QUERY
from test_legacy_conversation_read import (FakeDatabase, KEY, NOW, PIN, SOURCE,
    UID_A, UID_B, enabled, identity, s)


def b(value): return {"booleanValue": value}
def full_fields():
    return {"uid": s(UID_A), "fullName": s("Synthetic own name"), "age": {"integerValue": "32"},
        "pol": s("male"), "about": s("Synthetic description"), "hobbi": s("Synthetic interests"),
        "rost": s("178"), "country": s("Synthetic country"), "countryCode": s("ZZ"),
        "region": s("Synthetic region"), "city": s("Synthetic city"), "deti": b(True), "status": s("active")}
def service(db, env=None):
    return LegacyOwnProfileService(env or enabled(), KEY, connect=db.connect, clock=lambda: NOW)


class OwnProfileTests(unittest.TestCase):
    def test_existing_saved_or_legacy_user_keeps_gate_destination(self):
        cases = [({"isRegistrationEnd": b(True)}, "search"), ({"profileDetailsSaved": b(True)}, "test"), ({}, "test")]
        cases += [({"группа": s("  "+group.upper()+"  "), "isRegistrationEnd": b(False),
            "profileDetailsSaved": b(False)}, "search") for group in sorted(GROUPS)]
        cases += [({"группа": s("unknown-source-group")}, "test")]
        for extra, expected in cases:
            with self.subTest(extra=extra, expected=expected):
                db=FakeDatabase(); fields=full_fields(); fields.update(extra); db.add("users/"+UID_A,fields)
                reply=service(db).own_profile(identity())
                self.assertEqual(expected,reply["onboarding"])
                self.assertEqual(UID_A,reply["profile"]["uid"]); self.assertEqual(32,reply["profile"]["age"])
                self.assertEqual("Synthetic interests",reply["profile"]["hobbi"])
                self.assertEqual(PIN,reply["sourceSnapshot"])
                self.assertEqual(bytes(db.documents["users/"+UID_A][4]).hex(),reply["profileDocumentHash"])
                self.assertTrue(db.connections[-1].rolled_back); self.assertTrue(db.connections[-1].closed)
        for age in [{"stringValue":"32"},{"doubleValue":32.0},{"doubleValue":32.5}]:
            db=FakeDatabase(); fields=full_fields(); fields["age"]=age; db.add("users/"+UID_A,fields)
            self.assertEqual("test",service(db).own_profile(identity())["onboarding"])
        db=FakeDatabase(); fields=full_fields(); fields["age"]=s("malformed-age"); db.add("users/"+UID_A,fields)
        with self.assertRaises(LegacyReadUnavailable): service(db).own_profile(identity())

    def test_absent_or_partial_profile_truthful_onboarding_no_mutation(self):
        db=FakeDatabase(); reply=service(db).own_profile(identity())
        self.assertEqual("registration",reply["onboarding"]); self.assertFalse(reply["profileExists"])
        self.assertIsNone(reply["profile"]); self.assertIsNone(reply["profileDocumentHash"])
        self.assertTrue(reply["readOnly"]); self.assertFalse(reply["mediaReady"])
        db.add("users/"+UID_A,{"uid":s(UID_A),"fullName":s("Synthetic partial")})
        reply=service(db).own_profile(identity()); self.assertTrue(reply["profileExists"])
        self.assertEqual("registration",reply["onboarding"])
        for name in ["isRegistrationEnd","profileDetailsSaved","age"]: self.assertIsNone(reply["profile"][name])
        self.assertEqual([],reply["unavailableFields"])
        self.assertEqual((hashlib.sha256(("users/"+UID_A).encode()).digest(),),
            [params for sql,params in db.calls if sql==DOCUMENT_QUERY][-1])
        self.assertFalse(any(sql.startswith(("INSERT","UPDATE","DELETE","CREATE","COMMIT")) for sql,_ in db.calls))

    def test_only_verified_own_uid_and_active_noncontradictory_account(self):
        db=FakeDatabase(); db.add("users/"+UID_B,full_fields())
        for forged in [UID_A,{"uid":UID_A},identity(expires=NOW),identity(uid="bad/uid")]:
            with self.assertRaises(LegacyReadRejected): service(db).own_profile(forged)
        self.assertEqual([],db.configs)
        with self.assertRaises(TypeError): service(db).own_profile(identity(),UID_B)
        for account in [(UID_B,0,"active"),(UID_A,1,"active"),(UID_A,0,"deleted")]:
            db=FakeDatabase(); db.accounts[UID_A]=account
            with self.assertRaises(LegacyReadRejected): service(db).own_profile(identity())
        for extra in [{"uid":s(UID_B)},{"status":s("blocked")},{"deleted":b(True)},{"registrationStatus":s("deleted")}]:
            db=FakeDatabase(); fields=full_fields(); fields.update(extra); db.add("users/"+UID_A,fields)
            with self.assertRaises(LegacyReadRejected): service(db).own_profile(identity())

    def test_private_urls_tokens_roles_and_financial_fields_absent(self):
        db=FakeDatabase(); fields=full_fields()
        url="https://firebasestorage.googleapis.com/v0/b/"+SOURCE[2]+"/o/users%2Fsynthetic%2Favatar.jpg?alt=media&token=synthetic-private-download-token"
        fields.update({"profilePic":s(url),"profilePicThumb":s("https://external.example.invalid/private"),
            "email":s("synthetic-private-email@example.invalid"),"password":s("synthetic-secret-password"),
            "admin":b(True),"balance":{"integerValue":"100"},"token":s("synthetic-private-token"),
            "presentedGifts":{"mapValue":{"fields":{"secret":s(url)}}}})
        db.add("users/"+UID_A,fields); api=service(db); reply=api.own_profile(identity()); text=json.dumps(reply)
        for secret in [url,"firebasestorage.googleapis.com","synthetic-private-download-token","synthetic-private-token",
            "synthetic-private-email","synthetic-secret-password","users/synthetic/avatar.jpg"]: self.assertNotIn(secret,text)
        for name in ["email","password","admin","balance","token","presentedGifts"]: self.assertNotIn(name,reply["profile"])
        avatar=reply["profile"]["profilePic"]; self.assertEqual("quarantined",avatar["status"])
        reference=api._codec.open("media",avatar["reference"])
        self.assertEqual(UID_A,reference["uid"]); self.assertEqual(reply["profileDocumentHash"],reference["parent"])
        self.assertEqual("profilePic",reference["field"]); self.assertNotIn("token",reference)
        self.assertEqual("unavailable",reply["profile"]["profilePicThumb"]["kind"])
        self.assertFalse(reply["mediaReady"])

    def test_default_off_source_hash_tls_and_exact_readonly_role(self):
        db=FakeDatabase()
        with self.assertRaises(LegacyReadUnavailable): service(db,{"unused":"1"}).own_profile(identity())
        self.assertEqual([],db.configs)
        for change in ["source","tls","grant","database","digest","marker"]:
            with self.subTest(change=change):
                db=FakeDatabase(); db.add("users/"+UID_A,full_fields())
                if change=="source": db.source=("wrong-project",SOURCE[1],SOURCE[2])
                if change=="tls": db.tls=False
                if change=="grant": db.extra_grant=True
                if change=="database": db.target="production"
                if change=="digest":
                    row=db.documents["users/"+UID_A]; db.documents["users/"+UID_A]=(*row[:4],b"x"*32)
                if change=="marker":
                    fields=full_fields(); fields["isRegistrationEnd"]=s("true"); db.add("users/"+UID_A,fields)
                with self.assertRaises(LegacyReadUnavailable): service(db).own_profile(identity())
        for name, bad in [("isRegistrationEnd",{"booleanValue":None}),("profileDetailsSaved",{"booleanValue":None}),
                          ("status",{"stringValue":None}),("группа",{"stringValue":None})]:
            db=FakeDatabase(); fields=full_fields(); fields[name]=bad; db.add("users/"+UID_A,fields)
            with self.assertRaises(LegacyReadUnavailable): service(db).own_profile(identity())
        env=enabled(); env["CLRS_LEGACY_READ_PERMISSION_MODEL"]="provider-database-v1"; api=service(FakeDatabase(),env)
        api._grants([("GRANT USAGE ON *.* TO `synthetic`@`%` REQUIRE SSL",),("GRANT SELECT ON `clrs_staging`.* TO `synthetic`@`%`",)])
        with self.assertRaises(LegacyReadUnavailable):
            api._grants([("GRANT USAGE ON *.* TO `synthetic`@`%`",),("GRANT SELECT, UPDATE ON `clrs_staging`.* TO `synthetic`@`%`",)])


if __name__=="__main__": unittest.main()
