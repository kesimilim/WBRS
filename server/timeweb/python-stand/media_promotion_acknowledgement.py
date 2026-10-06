"""Bounded server-only completed media promotion acknowledgement consumer.

No file, network, SQL, promotion or logging. The two CLRSX2 JSON frames and
their EOF are authenticated before any completed receipt can be accepted.
"""
from __future__ import annotations

import base64
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
import json
import math
import re
import struct
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


MAX_ACKNOWLEDGEMENT_BYTES = 16_384
FUTURE_CLOCK_SKEW_SECONDS = 60
MAGIC = b"CLRSX2\0\0"
PINS = {
    "archiveSha256": "b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e",
    "inventoryManifestSha256": "82352a0bb8a172fc33034204be2a3a752bcac69cc971f0feeb9a177ebcb3a341",
    "planSha256": "c9b8279bada1f8442dd9d8f97792f45d7f0eb56e9bba2f71968c052e8fe46f0b",
}
SOURCE = {"project": "chatapp-4e347", "database": "(default)",
    "bucket": "chatapp-4e347.appspot.com"}
AUDIT_FILE_SHA256 = "cd708b917797837073b75f9549809a6f80d6e90cd6592f2925db58180e7197fb"
FULL_ROWS_SHA256 = "c30890b3a247fd927ff7274ddc64475b393a91c513dc6edc685c411014d57bd6"
RAW_READBACK_PROOF_SHA256 = "09f1fb45427b0f1e460fea482d5dad9fd5e682263c40051d5dfb49d0214a76fd"
RECEIPT_FIELDS = {"kind", "version", "state", "pins", "source", "auditFileSha256",
    "targetRowsSha256", "receiptDigests", "rawReadbackProofSha256", "targetBucket",
    "expectedOwner", "candidates", "retainedQuarantine", "startedAt", "verifiedAt",
    "atomicCrossServiceSnapshot", "httpEnabled", "receiptHmacSha256"}
_DIGEST = re.compile(r"[a-f0-9]{64}\Z")
_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")


class MediaPromotionUnavailable(Exception):
    def __init__(self):
        super().__init__("Media promotion acknowledgement unavailable")


def _base64(value, maximum):
    if (not isinstance(value, str) or not value
            or len(value) > ((maximum + 2) // 3) * 4):
        raise MediaPromotionUnavailable()
    decoded = base64.b64decode(value, validate=True)
    if not decoded or len(decoded) > maximum or base64.b64encode(decoded).decode() != value:
        raise MediaPromotionUnavailable()
    return decoded


def _json(raw):
    def pairs(items):
        result = {}
        for name, item in items:
            if name in result:
                raise MediaPromotionUnavailable()
            result[name] = item
        return result
    def integer(value):
        if len(value) > 16:
            raise MediaPromotionUnavailable()
        return int(value)
    def invalid(_):
        raise MediaPromotionUnavailable()
    parsed = json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=pairs,
        parse_int=integer, parse_float=invalid, parse_constant=invalid)
    if not isinstance(parsed, dict):
        raise MediaPromotionUnavailable()
    return parsed


def _frames(ciphertext, key):
    if len(ciphertext) < 16 or ciphertext[:8] != MAGIC:
        raise MediaPromotionUnavailable()
    header = ciphertext[:16]; position = 16; records = []
    for index in range(2):
        if position + 4 > len(ciphertext):
            raise MediaPromotionUnavailable()
        length_buffer = ciphertext[position:position + 4]
        length = struct.unpack(">I", length_buffer)[0]; position += 4
        if not 1 <= length <= MAX_ACKNOWLEDGEMENT_BYTES or position + length + 16 > len(ciphertext):
            raise MediaPromotionUnavailable()
        counter = struct.pack(">I", index)
        plain = AESGCM(key).decrypt(header[8:] + counter,
            ciphertext[position:position + length + 16], header + counter + length_buffer)
        position += length + 16
        if plain[:1] != b"\x01":
            raise MediaPromotionUnavailable()
        records.append(_json(plain[1:]))
    end = records[1]
    if (position != len(ciphertext) or set(end) != {"kind", "summary"}
            or end["kind"] != "end" or not isinstance(end["summary"], dict)
            or set(end["summary"]) != {"receiptRecords"}
            or type(end["summary"]["receiptRecords"]) is not int
            or end["summary"]["receiptRecords"] != 1):
        raise MediaPromotionUnavailable()
    return records[0]


def _date(value):
    if not isinstance(value, str) or not _DATE.fullmatch(value):
        raise MediaPromotionUnavailable()
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


@dataclass(frozen=True, repr=False)
class VerifiedMediaPromotion:
    ciphertext_sha256: str
    verified_epoch: float
    started_epoch: float

    def require_current(self, now):
        # A completed migration is durable, not a current privacy/membership
        # proof. Runtime authorization and fresh S3 checks remain separate.
        if (type(now) not in {int, float} or not math.isfinite(now)
                or self.verified_epoch > now + FUTURE_CLOCK_SKEW_SECONDS
                or self.started_epoch > self.verified_epoch):
            raise MediaPromotionUnavailable()
        return now


def verify_media_promotion_acknowledgement(env, *, clock=time.time, separate_from=()):
    """Verify exact current review pins; no operator-controlled alternative pins."""
    try:
        key = _base64(env.get("CLRS_LEGACY_MEDIA_PROMOTION_RECEIPT_KEY_B64"), 32)
        if len(key) != 32 or any(hmac.compare_digest(key, other) for other in separate_from):
            raise MediaPromotionUnavailable()
        ciphertext = _base64(env.get("CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64"), MAX_ACKNOWLEDGEMENT_BYTES)
        expected_sha = env.get("CLRS_LEGACY_MEDIA_PROMOTION_ACK_SHA256")
        digest = hashlib.sha256(ciphertext).hexdigest()
        if (not isinstance(expected_sha, str) or not _DIGEST.fullmatch(expected_sha)
                or not hmac.compare_digest(digest, expected_sha)):
            raise MediaPromotionUnavailable()
        receipt = _frames(ciphertext, key)
        if set(receipt) != RECEIPT_FIELDS:
            raise MediaPromotionUnavailable()
        if (receipt["kind"] != "clrs-media-promotion-complete-acknowledgement"
                or type(receipt["version"]) is not int or receipt["version"] != 1
                or receipt["state"] != "sequential_privacy_chunks_and_final_sql_verified"
                or not isinstance(receipt["pins"], dict) or receipt["pins"] != PINS
                or not isinstance(receipt["source"], dict) or receipt["source"] != SOURCE
                or receipt["auditFileSha256"] != AUDIT_FILE_SHA256
                or receipt["targetRowsSha256"] != FULL_ROWS_SHA256
                or receipt["rawReadbackProofSha256"] != RAW_READBACK_PROOF_SHA256
                or type(receipt["candidates"]) is not int or receipt["candidates"] != 5191
                or type(receipt["retainedQuarantine"]) is not int or receipt["retainedQuarantine"] != 1287
                or receipt["atomicCrossServiceSnapshot"] is not False
                or receipt["httpEnabled"] is not False):
            raise MediaPromotionUnavailable()
        receipts = receipt["receiptDigests"]
        if (not isinstance(receipts, list) or len(receipts) != 26
                or any(not isinstance(value, str) or not _DIGEST.fullmatch(value) for value in receipts)
                or len(set(receipts)) != 26):
            raise MediaPromotionUnavailable()
        bucket = env.get("CLRS_LEGACY_MEDIA_TARGET_BUCKET")
        owner = env.get("CLRS_LEGACY_MEDIA_EXPECTED_OWNER")
        if (not isinstance(bucket, str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket)
                or not isinstance(owner, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,191}", owner)
                or receipt["targetBucket"] != bucket or receipt["expectedOwner"] != owner
                or env.get("CLRS_LEGACY_READ_SOURCE_SHA256") != PINS["archiveSha256"]
                or any(env.get("CLRS_LEGACY_READ_SOURCE_" + name.upper()) != value
                    for name, value in SOURCE.items())):
            raise MediaPromotionUnavailable()
        supplied = receipt["receiptHmacSha256"]
        if not isinstance(supplied, str) or not _DIGEST.fullmatch(supplied):
            raise MediaPromotionUnavailable()
        body = {name: value for name, value in receipt.items() if name != "receiptHmacSha256"}
        canonical = json.dumps(body, sort_keys=True, ensure_ascii=False,
            separators=(",", ":"), allow_nan=False).encode("utf-8")
        body_hash = hashlib.sha256(canonical).hexdigest().encode("ascii")
        expected_mac = hmac.digest(key, b"clrs-media-promotion-receipt-v1\0" + body_hash, "sha256").hex()
        if not hmac.compare_digest(expected_mac, supplied):
            raise MediaPromotionUnavailable()
        verified = VerifiedMediaPromotion(digest, _date(receipt["verifiedAt"]), _date(receipt["startedAt"]))
        verified.require_current(clock())
        return verified
    except Exception:
        raise MediaPromotionUnavailable() from None
