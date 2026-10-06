"""SQL-shaped caller-owned transactions. No TCP, database, grant or S3 calls."""
import copy
from dataclasses import replace
import hashlib
import unittest

from media_promotion_acknowledgement import PINS, SOURCE, VerifiedMediaPromotion
from profile_photo_projector import (ProfilePhotoProjector, PhotoProjectionRefused,
    PhotoCommitUnknown, VerifiedSourceSnapshot, verify_source_snapshot,
    verify_photo_recovery, COUNTS, READ_TABLES, MAX_STATEMENTS,
    PROVIDER_MODEL, MIGRATE_PERMISSIONS)
from test_profile_photo_review import source, evidence, url, UID, PATH, STAMP


KEY = bytes(range(32))
PROOF = b"synthetic completed authenticated import/readback evidence"
HOST = "db.example.invalid"
OWNER_PERMISSIONS = ("CREATE", "DELETE", "INSERT", "REFERENCES", "SELECT", "UPDATE")


def source_verifier(receipt):
    return {"archiveSha256": PINS["archiveSha256"], "manifestSha256": PINS["inventoryManifestSha256"],
        "receiptDigest": hashlib.sha256(receipt).hexdigest(), "source": dict(SOURCE),
        "counts": dict(COUNTS), "consistent": False,
        "completion": "verified_completed_archival_import_readback"}


def connection_verifier(connection):
    recovery = connection.role == "recovery"
    return {"host": HOST, "database": "clrs_staging", "mysql": "8.4", "verifiedTLS": connection.db.tls,
        "verifiedHostname": True, "strict": True, "socketTimeoutSeconds": 2,
        "fresh_grants_verified": True, "grants_sha256": "1"*64,
        "underlying_permissions_scope": "strict-table-role",
        "underlying_permissions": {"readTables": sorted(READ_TABLES),
            "insertTables": [] if recovery else ["profile_photos"],
            "updateTables": [] if recovery else connection.db.update_tables,
            "deleteTables": connection.db.delete_tables if recovery else [], "otherWriteTables": []},
        "executed_sql_scope": "profile-photo-projector-v1",
        "execution_mode": "recovery" if recovery else "apply", "runner_allowlist_enforced": True}


def provider_verifier(connection):
    facts = connection_verifier(connection)
    facts["underlying_permissions_scope"] = "existing-approved-provider-database"
    facts["underlying_permissions"] = {"database": "clrs_staging",
        "privileges": list(OWNER_PERMISSIONS if connection.role == "recovery" else MIGRATE_PERMISSIONS),
        "globalPrivileges": [], "grantOption": False}
    return facts


def doc_row(record, collection):
    return (record.firebase_path, collection, record.firebase_path.rsplit("/", 1)[1],
        record.encoded_payload, bytes.fromhex(record.payload_sha256))


class Database:
    def __init__(self):
        root = source("users/" + UID, uid={"stringValue": UID}, status={"stringValue": "active"},
            profilePic={"stringValue": url(PATH)})
        image = source("users/" + UID + "/images/photo-a", url={"stringValue": url(PATH)})
        proof = evidence()
        self.state = {"source": (SOURCE["project"], SOURCE["database"], SOURCE["bucket"]),
            "owner": (UID, 0, "active", UID, root.encoded_payload, STAMP),
            "root": doc_row(root, "users"), "gallery": [doc_row(image, "users/" + UID + "/images")],
            "storage": [tuple(proof.storage.values())], "media": [tuple(proof.media.values())], "photos": []}
        self.connections = []; self.calls = []; self.receipts = []
        self.tls = True; self.delete_tables = ["profile_photos"]; self.update_tables = ["profile_photos"]
        self.commit_error = None; self.corrupt_insert = False; self.after_photo_select = None
        self.deny_recovery_lock = False

    def connect(self):
        connection = Connection(self, "apply"); self.connections.append(connection)
        return connection

    def recovery_connect(self):
        connection = Connection(self, "recovery"); self.connections.append(connection)
        return connection

    def persist(self, encrypted):
        self.receipts.append(encrypted)
        return hashlib.sha256(encrypted).hexdigest()

    def projector(self, **changes):
        options = {"connect": self.connect, "trusted_connection_verifier": connection_verifier,
            "pinned_host": HOST,
            "source_snapshot": verify_source_snapshot(PROOF, trusted_verifier=source_verifier),
            "media_promotion": VerifiedMediaPromotion("0" * 64, 100, 80),
            "recovery": verify_photo_recovery(connect=self.recovery_connect,
                trusted_connection_verifier=connection_verifier, pinned_host=HOST),
            "receipt_key": KEY, "load_pending_receipt": lambda uid: self.receipts[-1] if self.receipts else None,
            "clock": lambda: 100}
        return ProfilePhotoProjector(**{**options, **changes})


class Connection:
    def __init__(self, db, role):
        self.db = db; self.state = copy.deepcopy(db.state)
        self.role = role; self.statements = 0
        self.commits = 0; self.rollbacks = 0; self.closed = False; self.readonly = False
        self.photo_selects = 0

    def cursor(self): return Cursor(self)
    def rollback(self): self.rollbacks += 1
    def close(self): self.closed = True
    def commit(self):
        assert not self.readonly
        self.commits += 1
        if self.db.commit_error != "not-committed": self.db.state = copy.deepcopy(self.state)
        if self.db.commit_error: raise OSError("synthetic transport failure")


class Cursor:
    def __init__(self, connection):
        self.c = connection; self.rows = []; self.rowcount = 0

    def fetchall(self): return list(self.rows)

    def execute(self, statement, params=()):
        sql = " ".join(statement.split()); db = self.c.db; state = self.c.state
        self.c.statements += 1
        db.calls.append((sql, params)); self.rows = []; self.rowcount = 0
        if sql.startswith("SET "): return 0
        if sql.startswith("START TRANSACTION"):
            self.c.readonly = "READ ONLY" in sql; return 0
        if sql.startswith("SELECT "):
            if "FROM clrs_staging.profile_photos" in sql:
                assert sql.endswith("FOR SHARE" if self.c.readonly else "FOR UPDATE")
            else:
                assert sql.endswith("FOR SHARE") or sql.endswith("FOR SHARE OF a, p")
            if self.c.readonly: assert "FOR UPDATE" not in sql
            if "FROM clrs_staging.legacy_source" in sql: self.rows = [state["source"]]
            elif "FROM clrs_staging.accounts AS a" in sql:
                assert "p.uid = a.uid AND CAST(p.uid AS BINARY) = CAST(a.uid AS BINARY)" in sql
                assert params[0] == params[1]
                self.rows = [state["owner"]] if state["owner"][0] == params[0] else []
            elif "FROM clrs_staging.legacy_documents" in sql:
                if "firebase_path_sha256" in sql:
                    self.rows = [state["root"]] if state["root"][0] == params[1] else []
                else:
                    assert "LIMIT 51" in sql and "ORDER BY CAST(document_id AS BINARY)" in sql
                    self.rows = sorted([x for x in state["gallery"] if x[1] == params[1]], key=lambda x: x[2].encode())[:51]
                assert hashlib.sha256(params[1].encode()).digest() == params[0]
            elif "FROM clrs_staging.legacy_storage_objects" in sql:
                assert "LIMIT 51" in sql and params[0] == SOURCE["bucket"]
                self.rows = [x for x in state["storage"] if x[0] == params[0] and hashlib.sha256(x[1].encode()).digest() in params[1:]][:51]
            elif "FROM clrs_staging.media_objects" in sql:
                assert "LIMIT 51" in sql
                self.rows = [x for x in state["media"] if hashlib.sha256(x[3].encode()).digest() in params][:51]
            elif "FROM clrs_staging.profile_photos" in sql:
                assert "LIMIT 51" in sql and params[0] == params[1]
                if self.c.role == "recovery" and not self.c.readonly and db.deny_recovery_lock:
                    raise PermissionError("synthetic actual lock refusal")
                self.rows = sorted([x for x in state["photos"] if x[0] == params[0]], key=lambda x: x[2])[:51]
                self.c.photo_selects += 1
                if db.after_photo_select: db.after_photo_select(self.c)
            else: raise AssertionError(sql)
            self.rowcount = len(self.rows); return self.rowcount
        assert not self.c.readonly
        if sql.startswith("INSERT INTO clrs_staging.profile_photos"):
            assert self.c.role == "apply"
            assert "ON DUPLICATE" not in sql and "REPLACE" not in sql
            rows = [tuple(params[i:i+5]) for i in range(0, len(params), 5)]
            state["photos"].extend(rows); self.rowcount = len(rows)
            if db.corrupt_insert: state["photos"][0] = (*state["photos"][0][:2], 2, *state["photos"][0][3:])
            return self.rowcount
        if sql.startswith("DELETE FROM clrs_staging.profile_photos"):
            assert self.c.role == "recovery"
            assert "CAST(uid AS BINARY)" in sql and "CAST(media_id AS BINARY)" in sql
            assert "firebase_image_id <=> %s" in sql and "LIMIT %s" in sql
            uid, exact = params[:2]; assert uid == exact
            records = [params[i:i+5] for i in range(2, len(params)-1, 5)]
            removed = [x for x in state["photos"] if x[0] == uid and any((x[1], x[1], x[2], x[3], x[4]) == tuple(r) for r in records)]
            assert len(removed) <= params[-1]
            state["photos"] = [x for x in state["photos"] if x not in removed]
            self.rowcount = len(removed); return self.rowcount
        raise AssertionError(sql)


class ProfilePhotoProjectorTests(unittest.TestCase):
    def setUp(self): self.db = Database(); self.projector = self.db.projector()
    def prepare(self): return self.projector.prepare(UID, reviewed_source_id_order=["photo-a"])

    def test_mysql_tuple_result_preserves_source_checks_and_exact_apply(self):
        from unittest.mock import patch
        with patch.object(Cursor, "fetchall", lambda cursor: tuple(cursor.rows)):
            prepared = self.prepare()
            result = self.projector.apply(prepared, persist_receipt=self.db.persist)
            self.assertEqual("applied", result["state"])
            self.assertEqual("present_verified", self.projector.reconcile(self.db.receipts[-1])["state"])
            self.assertEqual(1, len(self.db.state["photos"]))
            self.assertEqual(1, sum(conn.commits for conn in self.db.connections))
            wrong = Database(); wrong.state["source"] = ("wrong-project", SOURCE["database"], SOURCE["bucket"])
            with self.assertRaises(PhotoProjectionRefused) as error:
                wrong.projector().prepare(UID, reviewed_source_id_order=["photo-a"])
            self.assertEqual("source_identity_mismatch", error.exception.reason)
            self.assertFalse(any(conn.commits for conn in wrong.connections))

    def test_source_and_recovery_capabilities_are_mandatory_not_user_flags(self):
        for verifier in (None, lambda _: {}):
            with self.assertRaises(PhotoProjectionRefused): verify_source_snapshot(PROOF, trusted_verifier=verifier)
        for key, value in (("consistent", True), ("counts", {**COUNTS, "authUsers": 8207}),
                ("archiveSha256", "0"*64), ("completion", "failed_partial_export"),
                ("completion", "verified_local_full_export")):
            with self.assertRaises(PhotoProjectionRefused):
                verify_source_snapshot(PROOF, trusted_verifier=lambda b: {**source_verifier(b), key: value})
        forged = VerifiedSourceSnapshot(PINS["archiveSha256"], PINS["inventoryManifestSha256"], "0"*64, tuple(COUNTS.items()), False)
        for changes in ({"source_snapshot": None}, {"source_snapshot": forged}, {"recovery": True},
                {"load_pending_receipt": None}, {"trusted_connection_verifier": None}):
            with self.assertRaises(PhotoProjectionRefused): self.db.projector(**changes)
        self.assertEqual(self.db.calls, [])
        for tls, tables in ((False, ["profile_photos"]), (True, []), (True, ["profile_photos", "media_objects"])):
            self.db.tls = tls; self.db.delete_tables = tables
            with self.assertRaises(PhotoProjectionRefused):
                self.projector.apply(self.prepare(), persist_receipt=self.db.persist)
        self.assertFalse(any(sql.startswith("INSERT") for sql, _ in self.db.calls))
        self.assertFalse(any(x.commits for x in self.db.connections))

    def test_prepare_apply_readback_receipt_and_reconcile_emit_no_identity(self):
        prepared = self.prepare()
        self.assertEqual(prepared.summary()["candidateRows"], 1)
        with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=None)
        result = self.projector.apply(prepared, persist_receipt=self.db.persist)
        self.assertEqual(result, {"state": "applied", "reason": "exact_rows_verified", "rows": 1})
        self.assertEqual(len(self.db.state["photos"]), 1)
        self.assertEqual(len(self.db.receipts), 1)
        self.assertNotIn(UID.encode(), self.db.receipts[0])
        record, before, after = self.projector._open(self.db.receipts[0])
        self.assertIs(record["consistent"], False); self.assertEqual(before, ()); self.assertEqual(len(after), 1)
        verified = self.db.projector().reconcile(self.db.receipts[0])
        self.assertEqual(verified["state"], "present_verified")
        for public in (result, verified, prepared.summary()):
            self.assertNotIn(UID, str(public)); self.assertNotIn("quarantine", str(public))
        self.assertTrue(all(x.closed for x in self.db.connections))
        self.assertTrue(all(x.statements <= MAX_STATEMENTS for x in self.db.connections))

    def test_provider_grants_are_broad_declared_and_recovery_is_separate(self):
        recovery = verify_photo_recovery(connect=self.db.recovery_connect,
            trusted_connection_verifier=provider_verifier, pinned_host=HOST,
            permission_model=PROVIDER_MODEL, underlying_provider_permissions=OWNER_PERMISSIONS)
        projector = self.db.projector(permission_model=PROVIDER_MODEL,
            trusted_connection_verifier=provider_verifier, recovery=recovery)
        prepared = projector.prepare(UID, reviewed_source_id_order=["photo-a"])
        self.assertEqual(projector.apply(prepared, persist_receipt=self.db.persist)["state"], "applied")
        apply_connection = next(c for c in self.db.connections if c.commits)
        self.assertEqual(apply_connection.role, "apply")
        declared = provider_verifier(apply_connection)
        self.assertEqual(declared["underlying_permissions_scope"], "existing-approved-provider-database")
        self.assertEqual(declared["underlying_permissions"]["privileges"], list(MIGRATE_PERMISSIONS))
        self.assertNotIn("DELETE", declared["underlying_permissions"]["privileges"])
        self.assertEqual(len([c for c in self.db.connections if c.role == "recovery"]), 2)
        self.assertTrue(all(c.rollbacks == 1 and c.commits == 0 for c in self.db.connections if c.role == "recovery"))
        self.assertEqual(projector.rollback(self.db.receipts[0], persist_receipt=self.db.persist)["state"], "rolled_back")
        self.assertEqual(self.db.connections[-1].role, "recovery")
        for key, value in (("underlying_permissions_scope", "strict-table-role"),
                ("runner_allowlist_enforced", False), ("fresh_grants_verified", False),
                ("grants_sha256", None), ("host", "other.example.invalid")):
            failed = self.db.projector(permission_model=PROVIDER_MODEL,
                trusted_connection_verifier=lambda c: {**provider_verifier(c), key: value}, recovery=recovery)
            count = len(self.db.calls)
            with self.assertRaises(PhotoProjectionRefused): failed.prepare(UID, reviewed_source_id_order=["photo-a"])
            self.assertFalse(any(sql.startswith(("INSERT", "DELETE")) for sql, _ in self.db.calls[count:]))

    def test_runner_sql_scope_and_recovery_revocation_refuse_before_commit(self):
        for readonly, recovery, sql in ((False, False, "UPDATE clrs_staging.profiles SET full_name = %s"),
                (False, False, "DELETE FROM clrs_staging.profile_photos"),
                (False, True, "INSERT INTO clrs_staging.profile_photos VALUES (%s)"),
                (True, False, "SELECT * FROM clrs_staging.accounts")):
            count = len(self.db.calls)
            with self.assertRaises(PhotoProjectionRefused) as caught:
                self.projector._transaction(lambda cursor, execute: (execute(sql), None),
                    readonly=readonly, recovery=recovery)
            self.assertEqual(caught.exception.reason, "sql_scope_refused")
            self.assertNotIn(sql, [statement for statement, _ in self.db.calls[count:]])
        prepared = self.prepare()
        def revoke_after_readback(connection):
            if connection.photo_selects == 3: self.db.delete_tables = []
        self.db.after_photo_select = revoke_after_readback
        with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=self.db.persist)
        self.assertEqual(self.db.state["photos"], [])
        self.assertEqual(self.db.receipts, [])
        self.assertFalse(any(c.commits for c in self.db.connections))

    def test_mixed_model_requires_apply_lock_right_and_probe_never_relocks_before_commit(self):
        self.db.update_tables = []
        with self.assertRaises(PhotoProjectionRefused) as caught: self.prepare()
        self.assertEqual(caught.exception.reason, "connection_or_recovery_role_unverified")
        self.assertFalse(any(sql.startswith("INSERT") for sql, _ in self.db.calls))
        self.db.update_tables = ["profile_photos"]
        recovery = verify_photo_recovery(connect=self.db.recovery_connect,
            trusted_connection_verifier=connection_verifier, pinned_host=HOST)
        projector = self.db.projector(permission_model=PROVIDER_MODEL,
            trusted_connection_verifier=provider_verifier, recovery=recovery)
        prepared = projector.prepare(UID, reviewed_source_id_order=["photo-a"])
        self.db.deny_recovery_lock = True
        with self.assertRaises(PhotoProjectionRefused): projector.apply(prepared, persist_receipt=self.db.persist)
        self.assertFalse(any(sql.startswith("INSERT") for sql, _ in self.db.calls))
        self.assertFalse(any(c.commits for c in self.db.connections))
        self.db.deny_recovery_lock = False
        projector.apply(prepared, persist_receipt=self.db.persist)
        probes = [c for c in self.db.connections if c.role == "recovery"][-2:]
        self.assertFalse(probes[0].readonly)
        self.assertEqual(probes[0].photo_selects, 1)
        self.assertEqual(probes[0].rollbacks, 1)
        self.assertEqual(probes[0].commits, 0)
        self.assertTrue(probes[1].readonly)
        self.assertEqual(probes[1].photo_selects, 0)
        self.assertEqual(probes[1].rollbacks, 1)
        self.assertEqual(probes[1].commits, 0)

    def test_source_owner_gallery_completeness_and_reviewed_query_order_refuse(self):
        original = copy.deepcopy(self.db.state)
        changes = [lambda s: s.update(source=("wrong", SOURCE["database"], SOURCE["bucket"])),
            lambda s: s.update(owner=(UID, 1, "active", *s["owner"][3:])),
            lambda s: s.update(owner=(UID, 0, "deleted", *s["owner"][3:])),
            lambda s: s.update(owner=(UID, 0, "active", "other", *s["owner"][4:])),
            lambda s: s.update(root=(*s["root"][:4], b"0"*32)),
            lambda s: s.update(gallery=s["gallery"]*51),
            lambda s: s.update(media=[]), lambda s: s.update(storage=[])]
        for change in changes:
            self.db.state = copy.deepcopy(original); change(self.db.state)
            with self.assertRaises(PhotoProjectionRefused): self.prepare()
        self.db.state = original
        with self.assertRaises(PhotoProjectionRefused): self.projector.prepare(UID, reviewed_source_id_order=["different"])
        self.assertFalse(any(sql.startswith(("INSERT", "DELETE")) for sql, _ in self.db.calls))

    def test_cas_preinsert_full_readback_and_precommit_guard_roll_back(self):
        prepared = self.prepare(); original = copy.deepcopy(self.db.state)
        self.db.state["owner"] = (*self.db.state["owner"][:5], "2026-09-02T00:00:00.000000Z")
        with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=self.db.persist)
        self.db.state = copy.deepcopy(original)
        self.db.after_photo_select = lambda c: c.state.update(owner=(*c.state["owner"][:5], "2026-09-03T00:00:00.000000Z")) if c.photo_selects == 1 else None
        with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=self.db.persist)
        self.db.after_photo_select = None; self.db.corrupt_insert = True
        with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=self.db.persist)
        self.db.corrupt_insert = False
        def persist(encrypted):
            active = next(c for c in reversed(self.db.connections) if not c.closed and c.role == "apply")
            active.state["owner"] = (*active.state["owner"][:5], "2026-09-04T00:00:00.000000Z")
            return self.db.persist(encrypted)
        with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=persist)
        self.assertEqual(self.db.state, original)
        self.assertFalse(any(c.commits for c in self.db.connections))

    def test_failed_durable_receipt_prevents_commit_and_requires_fresh_readback(self):
        prepared = self.prepare(); before = copy.deepcopy(self.db.state)
        with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=lambda _: None)
        self.assertEqual(self.db.state, before)
        self.assertFalse(any(c.commits for c in self.db.connections))
        with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=self.db.persist)

    def test_unknown_commit_present_and_absent_are_reconcile_only_after_restart(self):
        for policy, expected in (("committed", "present_verified"), ("not-committed", "not_committed_verified")):
            with self.subTest(policy=policy):
                self.db = Database(); self.projector = self.db.projector(); prepared = self.prepare()
                self.db.commit_error = policy
                with self.assertRaises(PhotoCommitUnknown): self.projector.apply(prepared, persist_receipt=self.db.persist)
                count = sum(sql.startswith("INSERT") for sql, _ in self.db.calls)
                with self.assertRaises(PhotoProjectionRefused): self.projector.apply(prepared, persist_receipt=self.db.persist)
                restarted = self.db.projector()
                self.assertEqual(restarted.reconcile(self.db.receipts[0])["state"], expected)
                self.assertEqual(sum(sql.startswith("INSERT") for sql, _ in self.db.calls), count)
                with self.assertRaises(PhotoProjectionRefused): restarted.apply(restarted.prepare(UID, reviewed_source_id_order=["photo-a"]), persist_receipt=self.db.persist)
                self.assertEqual(sum(sql.startswith("INSERT") for sql, _ in self.db.calls), count)

    def test_receipt_tamper_and_context_change_refuse_reconcile_without_writes(self):
        self.projector.apply(self.prepare(), persist_receipt=self.db.persist)
        encrypted = self.db.receipts[0]
        with self.assertRaises(PhotoProjectionRefused): self.db.projector().reconcile(encrypted[:-1] + bytes([encrypted[-1]^1]))
        record, _, _ = self.projector._open(encrypted)
        record["after"][0][1] = "unrelated-media"
        with self.assertRaises(PhotoProjectionRefused): self.db.projector().reconcile(self.projector._seal(record))
        self.db.state["owner"] = (*self.db.state["owner"][:5], "2026-09-05T00:00:00.000000Z")
        count = len(self.db.calls)
        with self.assertRaises(PhotoProjectionRefused): self.db.projector().reconcile(encrypted)
        self.assertFalse(any(sql.startswith(("INSERT", "DELETE")) for sql, _ in self.db.calls[count:]))

    def test_guarded_rollback_exact_after_preserves_other_owners_and_reconciles(self):
        self.projector.apply(self.prepare(), persist_receipt=self.db.persist)
        apply_receipt = self.db.receipts[0]
        other = ("other", "other-media", 0, 1, None); self.db.state["photos"].append(other)
        result = self.db.projector().rollback(apply_receipt, persist_receipt=self.db.persist)
        self.assertEqual(result["state"], "rolled_back")
        self.assertEqual(self.db.state["photos"], [other])
        self.assertEqual(self.db.projector().reconcile(self.db.receipts[-1])["state"], "present_verified")
        with self.assertRaises(PhotoProjectionRefused): self.db.projector().rollback(apply_receipt, persist_receipt=self.db.persist)

    def test_rollback_later_rows_conflict_no_delete_and_unknown_commit_reconcile(self):
        self.projector.apply(self.prepare(), persist_receipt=self.db.persist)
        apply_receipt = self.db.receipts[0]; original = copy.deepcopy(self.db.state)
        self.db.state["photos"][0] = (*self.db.state["photos"][0][:2], 1, *self.db.state["photos"][0][3:])
        count = len(self.db.calls)
        with self.assertRaises(PhotoProjectionRefused): self.db.projector().rollback(apply_receipt, persist_receipt=self.db.persist)
        self.assertFalse(any(sql.startswith("DELETE") for sql, _ in self.db.calls[count:]))
        self.db.state = original; self.db.commit_error = "committed"
        with self.assertRaises(PhotoCommitUnknown): self.db.projector().rollback(apply_receipt, persist_receipt=self.db.persist)
        self.assertEqual(self.db.projector().reconcile(self.db.receipts[-1])["state"], "present_verified")
        count = len(self.db.calls)
        with self.assertRaises(PhotoProjectionRefused): self.db.projector().rollback(apply_receipt, persist_receipt=self.db.persist)
        self.assertFalse(any(sql.startswith("DELETE") for sql, _ in self.db.calls[count:]))


if __name__ == "__main__": unittest.main()
