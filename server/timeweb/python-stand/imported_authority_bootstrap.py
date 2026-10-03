"""Operator-owned encrypted final pack; absent closed, invalid never falls back.

This consumes a separately reviewed final authority. It does not acquire a
Firebase writer barrier, issue a cohort, write S3/SQL, or activate an app route.
"""
import hashlib
import hmac
import io
import re
import threading
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from native_credentials import decode_base64, unique_json
from runtime_mutations import RuntimeUnavailable, canonical_json
from imported_meeting_authority import (load_imported_authority, source_fingerprint,
                                       MAX_BYTES, POLICY)
from private_media_s3 import (PrivateMediaS3, SigV4HTTPSReadTransport,
                             TimewebPrivateBucketState)

ACK_DOMAIN = b"clrs-imported-authority-bootstrap-ack-v1\0"
TRANSPORT_DOMAIN = b"clrs-imported-authority-encrypted-pack-v1\0"
MAGIC = b"CLRSIMA1"
INPUTS = ("CLRS_IMPORTED_MEETINGS_PACK_ACK_B64",
          "CLRS_IMPORTED_MEETINGS_PACK_ACK_HMAC_HEX",
          "CLRS_IMPORTED_MEETINGS_AUTHORITY_KEY_B64")


def _shape(value, keys):
    if type(value) is not dict or set(value) != keys:
        raise RuntimeUnavailable()


def _sha(value):
    if type(value) is not str or re.fullmatch(r"[a-f0-9]{64}", value) is None:
        raise RuntimeUnavailable()
    return value


def load_reviewed_imported_authority(env):
    """Return (genuine accepted cap, independently signed reviewed binding).

    Only protected server/operator settings supply this small ACK. The complete
    encrypted pack stays in the existing private bucket, never a request/env
    body or repository file. No unsigned true assertion is treated as evidence.
    """
    if all(name not in env for name in INPUTS):
        return None, None
    cancel = threading.Event()
    try:
        key = decode_base64(env.get(INPUTS[2]), max_bytes=32)
        ack_raw = decode_base64(env.get(INPUTS[0]), max_bytes=16384)
        mac = _sha(env.get(INPUTS[1]))
        if len(key) != 32 or not 1 <= len(ack_raw) <= 16384:
            raise RuntimeUnavailable()
        for name in ("CLRS_PREVIEW_ACCESS_KEY_B64", "CLRS_NATIVE_SESSION_KEY_B64",
                     "CLRS_LEGACY_READ_CURSOR_KEY_B64"):
            if name in env and hmac.compare_digest(key, decode_base64(env[name], max_bytes=64)):
                raise RuntimeUnavailable()
        if not hmac.compare_digest(hmac.digest(key, ACK_DOMAIN + ack_raw, "sha256").hex(), mac):
            raise RuntimeUnavailable()
        ack = unique_json(ack_raw.decode("utf-8"))
        _shape(ack, {"version", "kind", "binding", "storage", "object",
                     "plaintextSha256", "packHmacHex"})
        if type(ack["version"]) is not int or ack["version"] != 1 or ack["kind"] != "reviewed-imported-authority-bootstrap":
            raise RuntimeUnavailable()
        binding = ack["binding"]
        _shape(binding, {"generation", "sourceSha256", "cohortSha256", "policy",
                         "barrierSha256", "finalDeltaSha256"})
        for name in set(binding) - {"policy"}:
            _sha(binding[name])
        if binding["policy"] != POLICY or binding["sourceSha256"] != source_fingerprint():
            raise RuntimeUnavailable()
        _sha(ack["plaintextSha256"]); pack_mac = bytes.fromhex(_sha(ack["packHmacHex"]))
        storage = ack["storage"]
        _shape(storage, {"endpoint", "bucket", "owner", "region", "controlBucketId"})
        bucket_id = env.get("CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID")
        if (type(bucket_id) is not str or re.fullmatch(r"[1-9][0-9]{0,18}", bucket_id) is None
                or type(storage["controlBucketId"]) is not int
                or storage != {"endpoint": "https://s3.twcstorage.ru/",
                    "bucket": env.get("CLRS_LEGACY_MEDIA_TARGET_BUCKET"),
                    "owner": env.get("CLRS_LEGACY_MEDIA_EXPECTED_OWNER"),
                    "region": env.get("CLRS_LEGACY_MEDIA_S3_REGION"),
                    "controlBucketId": int(bucket_id)}
                or env.get("CLRS_LEGACY_MEDIA_S3_USER_MODE") != "dedicated-read-only"):
            raise RuntimeUnavailable()
        record = ack["object"]
        _shape(record, {"key", "size", "sha256", "content_type"})
        if (type(record["key"]) is not str or re.fullmatch(r"clrs-import-quarantine/[a-f0-9]{64}", record["key"]) is None
                or type(record["size"]) is not int or not len(MAGIC) + 28 < record["size"] <= MAX_BYTES
                or record["content_type"] != "application/octet-stream"):
            raise RuntimeUnavailable()
        _sha(record["sha256"])
        transport = SigV4HTTPSReadTransport(storage["endpoint"], storage["region"],
            env.get("CLRS_LEGACY_MEDIA_S3_ACCESS_KEY"), env.get("CLRS_LEGACY_MEDIA_S3_SECRET_KEY"))
        state = TimewebPrivateBucketState(storage["controlBucketId"], storage["bucket"],
            env.get("CLRS_LEGACY_MEDIA_CONTROL_TOKEN"))
        private = PrivateMediaS3(storage["bucket"], storage["owner"], transport, state)
        with io.BytesIO() as sink:
            private.get_verified_to_file(record, sink, time.monotonic() + 30, cancel)
            ciphertext = sink.read(MAX_BYTES + 1)
        if (len(ciphertext) != record["size"] or not ciphertext.startswith(MAGIC)
                or hashlib.sha256(ciphertext).hexdigest() != record["sha256"]):
            raise RuntimeUnavailable()
        aad = TRANSPORT_DOMAIN + canonical_json({"generation": binding["generation"],
            "sourceSha256": binding["sourceSha256"], "plaintextSha256": ack["plaintextSha256"]})
        encryption_key = hmac.digest(key, TRANSPORT_DOMAIN + b"encryption-key", "sha256")
        nonce_at = len(MAGIC)
        raw = AESGCM(encryption_key).decrypt(ciphertext[nonce_at:nonce_at + 12], ciphertext[nonce_at + 12:], aad)
        if not 1 <= len(raw) <= MAX_BYTES or hashlib.sha256(raw).hexdigest() != ack["plaintextSha256"]:
            raise RuntimeUnavailable()
        cap = load_imported_authority(raw, pack_mac, key, reviewed_binding=binding)
        cap.require(binding)
        return cap, dict(binding)
    except Exception:
        raise RuntimeUnavailable() from None
    finally:
        cancel.set()
