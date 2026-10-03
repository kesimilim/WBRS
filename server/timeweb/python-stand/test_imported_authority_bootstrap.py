"""Synthetic encrypted transport through the real private port/final validator.

No network, SQL, production key/config, existing cohort or live barrier is read.
"""
import base64
import copy
from datetime import datetime, timezone
import hashlib
import hmac
import time
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import imported_authority_bootstrap as bootstrap
from imported_meeting_authority import DOMAIN, MAX_BYTES
from runtime_mutations import RuntimeUnavailable, canonical_json
from test_imported_meeting_authority import pack, ProofDatabase
from test_private_media_s3 import Port, Reply, BUCKET, OWNER, acl

KEY = b"q" * 32  # Deliberately synthetic and exactly the dedicated-key size.


def encoded(raw):
    return base64.b64encode(raw).decode()


class PackPort(Port):
    def open(self, operation, bucket, key, deadline, cancel):
        if operation == "GetObject":
            self.calls.append((operation, bucket, key))
            reply = Reply(self.body, content_type="application/octet-stream")
            self.replies.append(reply)
            return reply
        return super().open(operation, bucket, key, deadline, cancel)


def fixture(body=None):
    body = copy.deepcopy(body) if body is not None else pack(ProofDatabase())
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    body["barrier"]["verifiedAt"] = stamp
    body["finalDelta"]["completedAt"] = stamp
    body["issuedAt"] = stamp
    raw = canonical_json(body, max_bytes=MAX_BYTES)
    plain_sha = hashlib.sha256(raw).hexdigest()
    aad = bootstrap.TRANSPORT_DOMAIN + canonical_json({
        "generation": body["binding"]["generation"],
        "sourceSha256": body["binding"]["sourceSha256"], "plaintextSha256": plain_sha})
    nonce = b"test-nonce12"
    cipher = bootstrap.MAGIC + nonce + AESGCM(hmac.digest(KEY,
        bootstrap.TRANSPORT_DOMAIN + b"encryption-key", "sha256")).encrypt(nonce, raw, aad)
    ack = {"version": 1, "kind": "reviewed-imported-authority-bootstrap",
        "binding": body["binding"], "storage": {"endpoint": "https://s3.twcstorage.ru/",
            "bucket": BUCKET, "owner": OWNER, "region": "synthetic-region", "controlBucketId": 7},
        "object": {"key": "clrs-import-quarantine/" + "a" * 64, "size": len(cipher),
            "sha256": hashlib.sha256(cipher).hexdigest(), "content_type": "application/octet-stream"},
        "plaintextSha256": plain_sha, "packHmacHex": hmac.digest(KEY, DOMAIN + raw, "sha256").hex()}
    env = {"CLRS_IMPORTED_MEETINGS_AUTHORITY_KEY_B64": encoded(KEY),
        "CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID": "7", "CLRS_LEGACY_MEDIA_TARGET_BUCKET": BUCKET,
        "CLRS_LEGACY_MEDIA_EXPECTED_OWNER": OWNER, "CLRS_LEGACY_MEDIA_S3_REGION": "synthetic-region",
        "CLRS_LEGACY_MEDIA_S3_USER_MODE": "dedicated-read-only",
        "CLRS_LEGACY_MEDIA_S3_ACCESS_KEY": "synthetic_read", "CLRS_LEGACY_MEDIA_S3_SECRET_KEY": "synthetic-secret",
        "CLRS_LEGACY_MEDIA_CONTROL_TOKEN": "synthetic-control"}
    sign_ack(env, ack)
    return env, ack, PackPort(cipher), body


def sign_ack(env, ack):
    raw = canonical_json(ack)
    env["CLRS_IMPORTED_MEETINGS_PACK_ACK_B64"] = encoded(raw)
    env["CLRS_IMPORTED_MEETINGS_PACK_ACK_HMAC_HEX"] = hmac.digest(KEY, bootstrap.ACK_DOMAIN + raw, "sha256").hex()


class BootstrapTests(unittest.TestCase):
    def load(self, env, port, *, private=True):
        def state(bucket, deadline, cancel):
            return {"bucket": bucket, "type": "private" if private else "public", "checked_at": time.monotonic()}
        with patch.object(bootstrap, "SigV4HTTPSReadTransport", return_value=port) as transport, \
                patch.object(bootstrap, "TimewebPrivateBucketState", return_value=state):
            try:
                return bootstrap.load_reviewed_imported_authority(env)
            finally:
                self.assertEqual(transport.call_count, 1)

    def test_default_absent_partial_and_ack_binding_refuse_before_transport(self):
        with patch.object(bootstrap, "SigV4HTTPSReadTransport") as transport:
            self.assertEqual(bootstrap.load_reviewed_imported_authority({}), (None, None))
            for env in [{bootstrap.INPUTS[0]: ""}, {bootstrap.INPUTS[2]: encoded(KEY)}]:
                with self.assertRaises(RuntimeUnavailable): bootstrap.load_reviewed_imported_authority(env)
            for change in ["signature", "source", "policy", "bucket", "prefix", "oversize", "shared-key"]:
                env, ack, _, _ = fixture()
                if change == "signature": env[bootstrap.INPUTS[1]] = "0" * 64
                else:
                    if change == "source": ack["binding"]["sourceSha256"] = "0" * 64
                    if change == "policy": ack["binding"]["policy"] = "unreviewed"
                    if change == "bucket": ack["storage"]["bucket"] = "other-bucket"
                    if change == "prefix": ack["object"]["key"] = "clrs-native-profile/" + "a" * 64
                    if change == "oversize": ack["object"]["size"] = MAX_BYTES + 1
                    if change == "shared-key": env["CLRS_NATIVE_SESSION_KEY_B64"] = encoded(KEY)
                    sign_ack(env, ack)
                with self.subTest(change=change), self.assertRaises(RuntimeUnavailable):
                    bootstrap.load_reviewed_imported_authority(env)
            transport.assert_not_called()

    def test_real_full_private_port_decrypt_and_final_authority_return(self):
        env, ack, port, body = fixture()
        cap, binding = self.load(env, port)
        cap.require(binding)
        self.assertEqual(binding, body["binding"])
        self.assertEqual(cap.entry("m")["payloadSha256"], body["meetings"][0]["payloadSha256"])
        self.assertEqual([call[0] for call in port.calls], ["GetBucketAcl", "GetBucketPolicy", "GetObjectAcl",
            "GetObject", "GetBucketAcl", "GetBucketPolicy", "GetObjectAcl"])
        self.assertTrue(all(reply.closed for reply in port.replies))
        self.assertEqual(port.calls[3][2], ack["object"]["key"])

    def test_cipher_private_and_signed_false_final_evidence_never_issue_capability(self):
        for change in ["cipher", "aead", "privacy", "acl", "barrier", "delta", "tombstones", "pack-mac"]:
            env, ack, port, body = fixture()
            if change in {"barrier", "delta", "tombstones"}:
                if change == "barrier": body["barrier"]["allWritersStopped"] = False
                if change == "delta": body["finalDelta"]["final"] = False
                if change == "tombstones": body["finalDelta"]["tombstonesSha256"] = "0" * 64
                env, ack, port, _ = fixture(body)
            if change in {"cipher", "aead"}:
                port.body = port.body[:-1] + bytes([port.body[-1] ^ 1])
                if change == "aead":
                    ack["object"]["sha256"] = hashlib.sha256(port.body).hexdigest(); sign_ack(env, ack)
            if change == "acl": port.override = lambda op: Reply(acl("foreign-owner")) if op == "GetObjectAcl" else None
            if change == "pack-mac": ack["packHmacHex"] = "0" * 64; sign_ack(env, ack)
            with self.subTest(change=change), self.assertRaises(RuntimeUnavailable):
                self.load(env, port, private=change != "privacy")
            self.assertTrue(all(reply.closed for reply in port.replies))


if __name__ == "__main__":
    unittest.main()
