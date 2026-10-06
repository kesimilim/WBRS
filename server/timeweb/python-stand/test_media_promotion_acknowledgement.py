"""Synthetic server-only acknowledgement tests; no source, secrets or network."""
import base64
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import struct
import subprocess
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import media_promotion_acknowledgement as ack
from legacy_private_media import LegacyPrivateMediaService
from legacy_conversation_read import LegacyReadUnavailable


KEY = bytes([7]) * 32
CURSOR_KEY = bytes([9]) * 32
NOW = 1_790_876_800
BUCKET = "synthetic-media-bucket"
OWNER = "synthetic_owner"
REPOSITORY = Path(__file__).resolve().parents[3]


def date(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def body():
    return {"kind": "clrs-media-promotion-complete-acknowledgement", "version": 1,
        "state": "sequential_privacy_chunks_and_final_sql_verified",
        "pins": dict(ack.PINS), "source": dict(ack.SOURCE),
        "auditFileSha256": ack.AUDIT_FILE_SHA256,
        "targetRowsSha256": ack.FULL_ROWS_SHA256,
        "rawReadbackProofSha256": ack.RAW_READBACK_PROOF_SHA256,
        "receiptDigests": [hashlib.sha256(f"synthetic-chunk-{i}".encode()).hexdigest() for i in range(26)],
        "targetBucket": BUCKET, "expectedOwner": OWNER,
        "candidates": 5191, "retainedQuarantine": 1287,
        "startedAt": date(NOW - 100), "verifiedAt": date(NOW),
        "atomicCrossServiceSnapshot": False, "httpEnabled": False}


def compact(value, *, sort=False):
    return json.dumps(value, ensure_ascii=False, sort_keys=sort,
        separators=(",", ":"), allow_nan=False).encode()


def sign(value, key=KEY):
    digest = hashlib.sha256(compact(value, sort=True)).hexdigest().encode("ascii")
    return {**value, "receiptHmacSha256": hmac.digest(key,
        b"clrs-media-promotion-receipt-v1\0" + digest, "sha256").hex()}


def encrypted(records, key=KEY):
    # Deliberate deterministic SYNTHETIC-only nonce; never production material.
    header = ack.MAGIC + b"syntheti"
    result = bytearray(header)
    for index, plain in enumerate(records):
        counter = struct.pack(">I", index); length = struct.pack(">I", len(plain))
        result.extend(length)
        result.extend(AESGCM(key).encrypt(header[8:] + counter, plain,
            header + counter + length))
    return bytes(result)


def env_for_ciphertext(ciphertext, key=KEY):
    return {"CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64": base64.b64encode(ciphertext).decode(),
        "CLRS_LEGACY_MEDIA_PROMOTION_ACK_SHA256": hashlib.sha256(ciphertext).hexdigest(),
        "CLRS_LEGACY_MEDIA_PROMOTION_RECEIPT_KEY_B64": base64.b64encode(key).decode(),
        "CLRS_LEGACY_MEDIA_TARGET_BUCKET": BUCKET,
        "CLRS_LEGACY_MEDIA_EXPECTED_OWNER": OWNER,
        "CLRS_LEGACY_READ_SOURCE_SHA256": ack.PINS["archiveSha256"],
        **{"CLRS_LEGACY_READ_SOURCE_" + name.upper(): value for name, value in ack.SOURCE.items()}}


def fixture(value=None, *, key=KEY, first_raw=None, end_raw=None, end=None):
    first_raw = compact(sign(body() if value is None else value, key)) if first_raw is None else first_raw
    end_raw = compact({"kind": "end", "summary": {"receiptRecords": 1}} if end is None else end) if end_raw is None else end_raw
    return env_for_ciphertext(encrypted([b"\x01" + first_raw, b"\x01" + end_raw], key), key)


class PrivatePort:
    _bucket = BUCKET
    _owner = OWNER

    def get_verified_to_file(self, *_args, **_kwargs):
        raise AssertionError("No S3 operation is allowed in acknowledgement tests")


class AcknowledgementTests(unittest.TestCase):
    def verify(self, env, now=NOW):
        return ack.verify_media_promotion_acknowledgement(env,
            clock=lambda: now, separate_from=(CURSOR_KEY,))

    def assert_unavailable(self, env, now=NOW):
        with self.assertRaises(ack.MediaPromotionUnavailable) as raised:
            self.verify(env, now)
        self.assertEqual("Media promotion acknowledgement unavailable", str(raised.exception))

    def test_valid_completed_proof_is_durable_not_runtime_privacy(self):
        env = fixture()
        proof = self.verify(env)
        self.assertEqual(env["CLRS_LEGACY_MEDIA_PROMOTION_ACK_SHA256"], proof.ciphertext_sha256)
        self.assertEqual(NOW, proof.verified_epoch)
        self.assertEqual(NOW + 60 * 86_400, proof.require_current(NOW + 60 * 86_400))
        self.assertEqual(NOW, self.verify(env, NOW + 60 * 86_400).verified_epoch)

    def test_actual_node_signer_and_clrsx2_writer_interoperate(self):
        code = """
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { signMediaPromotionReceipt } from './server/timeweb/media-promotion-core.mjs';
import { EncryptedArchiveWriter } from './server/timeweb/encrypted-archive.mjs';
let input = ''; for await (const chunk of process.stdin) input += chunk;
const { body, keyB64 } = JSON.parse(input), key = Buffer.from(keyB64, 'base64');
const directory = await mkdtemp(join(tmpdir(), 'clrs-synthetic-ack-'));
try {
  const file = join(directory, 'synthetic.clrsenc');
  const writer = await EncryptedArchiveWriter.create(file, key);
  await writer.writeJson(signMediaPromotionReceipt(body, key));
  await writer.finish({ receiptRecords: 1 });
  const bytes = await readFile(file);
  process.stdout.write(JSON.stringify({ base64: bytes.toString('base64'),
    sha256: createHash('sha256').update(bytes).digest('hex') }));
} finally { key.fill(0); await rm(directory, { recursive: true, force: true }); }
"""
        result = subprocess.run([os.environ.get("CLRS_TEST_NODE_BIN", "node"),
            "--input-type=module", "--eval", code], cwd=REPOSITORY, text=True,
            input=json.dumps({"body": body(), "keyB64": base64.b64encode(KEY).decode()}),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=True)
        self.assertLess(len(result.stdout), 24_000)
        emitted = json.loads(result.stdout)
        env = fixture(); env["CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64"] = emitted["base64"]
        env["CLRS_LEGACY_MEDIA_PROMOTION_ACK_SHA256"] = emitted["sha256"]
        self.assertEqual(NOW, self.verify(env).verified_epoch)

    def test_ciphertext_pin_aead_key_and_hmac_are_independent_gates(self):
        env = fixture(); env["CLRS_LEGACY_MEDIA_PROMOTION_ACK_SHA256"] = "0" * 64
        self.assert_unavailable(env)
        ciphertext = bytearray(base64.b64decode(fixture()["CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64"]))
        ciphertext[-1] ^= 1
        self.assert_unavailable(env_for_ciphertext(bytes(ciphertext)))
        env = fixture(); env["CLRS_LEGACY_MEDIA_PROMOTION_RECEIPT_KEY_B64"] = base64.b64encode(bytes([8]) * 32).decode()
        self.assert_unavailable(env)
        receipt = sign(body()); receipt["receiptHmacSha256"] = "0" * 64
        self.assert_unavailable(fixture(first_raw=compact(receipt)))

    def test_authenticated_end_eof_and_exact_two_json_frames_required(self):
        good = base64.b64decode(fixture()["CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64"])
        first = b"\x01" + compact(sign(body()))
        end = b"\x01" + compact({"kind": "end", "summary": {"receiptRecords": 1}})
        for candidate in [good[:-1], good + b"tail", encrypted([first]),
                encrypted([first, end, end]), encrypted([end, first]),
                encrypted([b"\x02" + first[1:], end])]:
            with self.subTest(length=len(candidate)):
                self.assert_unavailable(env_for_ciphertext(candidate))
        for summary in [{"receiptRecords": 0}, {"receiptRecords": True},
                {"receiptRecords": 1, "extra": 0}]:
            self.assert_unavailable(fixture(end={"kind": "end", "summary": summary}))

    def test_duplicate_and_unknown_keys_never_become_valid_proof(self):
        receipt = compact(sign(body()))
        self.assert_unavailable(fixture(first_raw=receipt[:-1] + b',"version":1}'))
        self.assert_unavailable(fixture(first_raw=receipt.replace(
            b'"pins":{', b'"pins":{"archiveSha256":"duplicate",', 1)))
        self.assert_unavailable(fixture(end_raw=b'{"kind":"end","summary":{"receiptRecords":1,"receiptRecords":1}}'))
        for field in ["unknown", "pins", "source"]:
            value = body()
            if field == "unknown":
                value[field] = 1
            else:
                value[field]["unknown"] = "synthetic"
            self.assert_unavailable(fixture(value))
        self.assert_unavailable(fixture(end={"kind": "end", "summary": {"receiptRecords": 1}, "extra": 1}))

    def test_partial_or_nonfinal_promotion_and_duplicate_chunk_digests_refused(self):
        cases = [("kind", "clrs-media-promotion-receipt"), ("version", True),
            ("state", "prepared"), ("candidates", 200), ("retainedQuarantine", 0),
            ("atomicCrossServiceSnapshot", True), ("httpEnabled", True)]
        for name, changed in cases:
            value = body(); value[name] = changed
            with self.subTest(field=name):
                self.assert_unavailable(fixture(value))
        for digests in [body()["receiptDigests"][:-1], ["a" * 64] * 26,
                body()["receiptDigests"][:-1] + ["not-a-digest"]]:
            value = body(); value["receiptDigests"] = digests
            self.assert_unavailable(fixture(value))

    def test_stale_pins_foreign_source_or_target_fail_with_valid_signature(self):
        for field in ["auditFileSha256", "targetRowsSha256", "rawReadbackProofSha256"]:
            value = body(); value[field] = "0" * 64
            self.assert_unavailable(fixture(value))
        for field in ack.PINS:
            value = body(); value["pins"][field] = "0" * 64
            self.assert_unavailable(fixture(value))
        for field in ack.SOURCE:
            value = body(); value["source"][field] = "foreign"
            self.assert_unavailable(fixture(value))
        for field in ["targetBucket", "expectedOwner"]:
            value = body(); value[field] = "foreign-target"
            self.assert_unavailable(fixture(value))
        env = fixture(); env["CLRS_LEGACY_READ_SOURCE_SHA256"] = "0" * 64
        self.assert_unavailable(env)

    def test_timestamp_shape_order_and_future_skew_without_age_expiry(self):
        self.verify(fixture(), NOW - ack.FUTURE_CLOCK_SKEW_SECONDS)
        self.assert_unavailable(fixture(), NOW - ack.FUTURE_CLOCK_SKEW_SECONDS - 1)
        value = body(); value["startedAt"] = date(NOW + 1)
        self.assert_unavailable(fixture(value))
        for changed in ["2026-10-01T12:00:00Z", "2026-13-01T12:00:00.000Z", None]:
            value = body(); value["verifiedAt"] = changed
            self.assert_unavailable(fixture(value))
        for invalid_clock in [float("nan"), float("inf"), True]:
            self.assert_unavailable(fixture(), invalid_clock)

    def test_bounded_canonical_base64_and_separate_key(self):
        for name in ["CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64", "CLRS_LEGACY_MEDIA_PROMOTION_RECEIPT_KEY_B64"]:
            for changed in ["A" * 24_000, "!invalid!", "", "YWJjZA", None]:
                env = fixture(); env[name] = changed
                self.assert_unavailable(env)
        self.assert_unavailable(fixture(key=CURSOR_KEY))
        ciphertext = ack.MAGIC + b"syntheti" + struct.pack(">I", 0xffffffff) + b"bounded"
        self.assert_unavailable(env_for_ciphertext(ciphertext))


class FactoryTests(unittest.TestCase):
    def test_defaultoff_ignores_missing_or_broken_material_without_connect(self):
        with patch("media_promotion_acknowledgement.verify_media_promotion_acknowledgement") as verify:
            self.assertIsNone(LegacyPrivateMediaService.from_env({}))
            self.assertIsNone(LegacyPrivateMediaService.from_env({"CLRS_LEGACY_MEDIA_ENABLED": "0"}))
            verify.assert_not_called()

    def test_invalid_acknowledgement_refuses_before_configuration_or_sql(self):
        env = fixture(); env["CLRS_LEGACY_MEDIA_ENABLED"] = "1"
        env["CLRS_LEGACY_MEDIA_PROMOTION_ACK_SHA256"] = "0" * 64
        with patch.object(LegacyPrivateMediaService, "_configuration") as configure:
            with self.assertRaises(LegacyReadUnavailable):
                LegacyPrivateMediaService.from_env(env, private_s3=PrivatePort(), cursor_key=CURSOR_KEY,
                    connect=lambda **_: self.fail("No SQL before proof"), clock=lambda: NOW)
            configure.assert_not_called()

    def test_valid_factory_drops_receipt_secret_and_keeps_durable_clock_binding(self):
        env = fixture(); env["CLRS_LEGACY_MEDIA_ENABLED"] = "1"
        env["CLRS_LEGACY_CURSOR_KEY_B64"] = base64.b64encode(CURSOR_KEY).decode()
        now = [NOW]
        with patch.object(LegacyPrivateMediaService, "_configuration") as configure:
            service = LegacyPrivateMediaService.from_env(env, private_s3=PrivatePort(),
                connect=lambda **_: self.fail("Factory must not open SQL"), clock=lambda: now[0])
            configure.assert_called_once_with()
        self.assertNotIn("CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64", service._env)
        self.assertNotIn("CLRS_LEGACY_MEDIA_PROMOTION_RECEIPT_KEY_B64", service._env)
        self.assertIn("CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64", env)
        now[0] += 60 * 86_400
        self.assertEqual(now[0], service._clock())
        now[0] = NOW - ack.FUTURE_CLOCK_SKEW_SECONDS - 1
        with self.assertRaises(LegacyReadUnavailable):
            service._clock()

    def test_foreign_adapter_and_cursor_key_reuse_refused_before_configuration(self):
        env = fixture(); env["CLRS_LEGACY_MEDIA_ENABLED"] = "1"
        port = PrivatePort(); port._owner = "foreign_owner"
        with patch.object(LegacyPrivateMediaService, "_configuration") as configure:
            with self.assertRaises(LegacyReadUnavailable):
                LegacyPrivateMediaService.from_env(env, private_s3=port,
                    cursor_key=CURSOR_KEY, clock=lambda: NOW)
            reused = fixture(key=CURSOR_KEY); reused["CLRS_LEGACY_MEDIA_ENABLED"] = "1"
            with self.assertRaises(LegacyReadUnavailable):
                LegacyPrivateMediaService.from_env(reused, private_s3=PrivatePort(),
                    cursor_key=CURSOR_KEY, clock=lambda: NOW)
            configure.assert_not_called()


if __name__ == "__main__":
    unittest.main()
