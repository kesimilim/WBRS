"""Isolated native upload port; production stays closed without a current signed probe.

The operator-owned proof loader/key attest an authorized controlled provider probe,
not configuration assertions. No probe runner, factory, credentials or activation
is supplied here. Imported/quarantine reader source and permissions are unchanged.
"""
from __future__ import annotations
import base64
import datetime as dt
import hashlib
import hmac
import io
import json
import math
import re
import threading
import time
import urllib.parse
import weakref

from private_media_s3 import (PrivateMediaS3, PrivateMediaUnavailable, SigV4HTTPSReadTransport,
    CHUNK_BYTES, _bucket, _headers, _https_get, _json_pairs, _length, _owner_acl, _signed_headers)
from runtime_profile_photo_uploads import PhotoUploadVerificationFailed as NativePhotoObjectMismatch

ENDPOINT = "https://s3.twcstorage.ru/"
HOST = "s3.twcstorage.ru"
PREFIX = "clrs-native-profile/"
MAX_BYTES = 5 * 1024 * 1024
MIMES = frozenset({"image/jpeg", "image/png", "image/webp"})
PROOF_DOMAIN = b"clrs-native-upload-provider-proof-v1\0"
PROOF_V2_DOMAIN = b"clrs-native-upload-provider-proof-v2\0"
RELEASE_DOMAIN = b"clrs-native-upload-release-v1\0"


def _record(value):
    if (not isinstance(value, dict) or set(value) != {"key", "size", "sha256", "content_type"}
            or not isinstance(value["key"], str) or not re.fullmatch(PREFIX + r"[a-f0-9]{64}", value["key"])
            or type(value["size"]) is not int or not 1 <= value["size"] <= MAX_BYTES
            or not isinstance(value["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", value["sha256"])
            or not isinstance(value["content_type"], str) or value["content_type"] not in MIMES):
        raise PrivateMediaUnavailable()
    return tuple(value[name] for name in ("key", "size", "sha256", "content_type"))


def _utc(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z", value):
        raise PrivateMediaUnavailable()
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=dt.timezone.utc)


class _NativeReadTransport(SigV4HTTPSReadTransport):
    def open(self, operation, bucket, key, deadline, cancel):
        _bucket(bucket)
        if operation in {"GetObject", "GetObjectAcl"}:
            if not isinstance(key, str) or not re.fullmatch(PREFIX + r"[a-f0-9]{64}", key):
                raise PrivateMediaUnavailable()
            path = "/" + bucket + "/" + key; query = "acl=" if operation == "GetObjectAcl" else ""
        elif operation in {"GetBucketAcl", "GetBucketPolicy"} and key is None:
            path = "/" + bucket; query = "acl=" if operation == "GetBucketAcl" else "policy="
        else:
            raise PrivateMediaUnavailable()
        stamp = self._wall().astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        headers = _signed_headers("GET", HOST, path, query, self._region, "s3", self._access, self._secret, stamp, self._token)
        headers.update({"connection": "close", "accept-encoding": "identity"})
        return _https_get(self._factory, path + ("?" + query if query else ""), headers, deadline, cancel, self._clock)


class _Verified:
    __slots__ = ("__weakref__",)


class NativePhotoUploadS3:
    """Writer-only credentials. Proof loader returns (authenticated JSON bytes, HMAC hex).

    The proof uses its versioned PROOF_DOMAIN/PROOF_V2_DOMAIN + raw bytes and a
    separate >=32-byte operator key.
    It binds this endpoint/bucket/region/owner/writer to observed conditional PUT,
    original readback and owner-only ACL/private policy. V1 proves bad-checksum
    rejection; separately signed v2 records whether the provider enforces it.
    Provider checksum validation never replaces full server byte/raster checks.
    Absence/expiry/alteration denies both operations before any HTTPS call.
    Ready additionally needs a trusted full-raster decoder port: decode_verified
    (private <=5MiB seekable spool, record, deadline/cancel) + require_verified.
    It must prove actual MIME, dimensions/pixel bounds and full decoding; no
    header/magic-only boolean. None remains closed; this module supplies no decoder.
    """
    def __init__(self, endpoint, region, bucket, expected_owner, writer_access_key, writer_secret_key,
            *, bucket_state, provider_proof=None, proof_key=None, image_verifier=None, connection_factory=None,
            monotonic=time.monotonic, wall_clock=None, proof_mode="pilot", release_binding=None):
        self._wall = wall_clock or (lambda: dt.datetime.now(dt.timezone.utc)); self._clock = monotonic
        self._transport = _NativeReadTransport(endpoint, region, writer_access_key, writer_secret_key,
            connection_factory=connection_factory, monotonic=monotonic, wall_clock=self._wall)
        self._private = PrivateMediaS3(bucket, expected_owner, self._transport, bucket_state, monotonic=monotonic)
        if proof_mode not in ("pilot", "release"): raise PrivateMediaUnavailable()
        self._mode = proof_mode; self._binding = release_binding
        self._proof_loader = provider_proof; self._proof_key = proof_key
        self._writer_hash = hashlib.sha256(writer_access_key.encode()).hexdigest()
        self._image = image_verifier
        self._evidence = weakref.WeakKeyDictionary(); self._lock = threading.Lock()

    def _proof(self):
        try:
            if (not callable(self._proof_loader) or type(self._proof_key) is not bytes or len(self._proof_key) < 32
                    or hmac.compare_digest(self._proof_key, self._transport._secret.encode())):
                raise PrivateMediaUnavailable()
            loaded = self._proof_loader(); release_digest = None
            if self._mode == "release":
                if not callable(self._binding) or type(loaded) is not tuple or len(loaded) != 4:
                    raise PrivateMediaUnavailable()
                release, release_mac, raw, mac = loaded
                if (type(release) is not bytes or not 1 <= len(release) <= 4096 or type(release_mac) is not str
                        or not re.fullmatch(r"[a-f0-9]{64}", release_mac)
                        or not hmac.compare_digest(hmac.digest(self._proof_key, RELEASE_DOMAIN + release, "sha256").hex(), release_mac)):
                    raise PrivateMediaUnavailable()
                witness = json.loads(release, object_pairs_hook=_json_pairs); binding = self._binding()
                if (type(binding) is not dict or set(binding) != {"buildSha256", "sourceSha256", "configSha256"}
                        or any(type(v) is not str or re.fullmatch(r"[a-f0-9]{64}", v) is None for v in binding.values())
                        or type(witness) is not dict or set(witness) != {"version", "kind", "binding", "providerProofSha256", "issuedAt"}
                        or type(witness["version"]) is not int or witness["version"] != 1
                        or witness["kind"] != "native-photo-upload-release" or witness["binding"] != binding
                        or witness["providerProofSha256"] != hashlib.sha256(raw).hexdigest()
                        or _utc(witness["issuedAt"]) > self._wall().astimezone(dt.timezone.utc)):
                    raise PrivateMediaUnavailable()
                release_digest = hashlib.sha256(release + raw).hexdigest()
            else:
                raw, mac = loaded
            if (type(raw) is not bytes or not 1 <= len(raw) <= 4096 or not isinstance(mac, str)
                    or not re.fullmatch(r"[a-f0-9]{64}", mac)):
                raise PrivateMediaUnavailable()
            value = json.loads(raw, object_pairs_hook=_json_pairs)
            version = value.get("version") if type(value) is dict else None
            if type(version) is not int or version not in (1, 2): raise PrivateMediaUnavailable()
            domain = PROOF_DOMAIN if version == 1 else PROOF_V2_DOMAIN
            if not hmac.compare_digest(hmac.digest(self._proof_key, domain + raw, "sha256").hex(), mac):
                raise PrivateMediaUnavailable()
            names = {"version", "endpoint", "bucket", "region", "owner", "writer_sha256", "checked_at", "probe_key",
                "original_sha256", "readback_sha256", "put_status", "duplicate_status", "duplicate_error",
                "checksum_status", "checksum_error", "object_acl", "bucket_acl", "bucket_type", "bucket_policy"}
            if version == 2: names |= {"checksum_validation", "checksum_observation",
                "checksum_body_sha256", "checksum_sent_sha256", "checksum_readback_sha256"}
            if set(value) != names: raise PrivateMediaUnavailable()
            checksum = value["checksum_status"] == 400 and value["checksum_error"] == "BadDigest"
            if version == 2:
                capability = value["checksum_validation"]
                checksum = (type(capability) is bool and type(value["checksum_status"]) is int and
                    value["checksum_body_sha256"] == value["original_sha256"] and
                    isinstance(value["checksum_sent_sha256"], str) and
                    re.fullmatch(r"[a-f0-9]{64}", value["checksum_sent_sha256"]) is not None and
                    value["checksum_sent_sha256"] != value["checksum_body_sha256"] and
                    ((capability and checksum and value["checksum_readback_sha256"] is None
                      and value["checksum_observation"] == "bad_digest_rejected") or
                     (not capability and value["checksum_status"] == 200 and value["checksum_error"] is None
                      and value["checksum_readback_sha256"] == value["checksum_body_sha256"]
                      and value["checksum_observation"] == "checksum_not_enforced")))
            if (value["endpoint"] != ENDPOINT
                    or value["bucket"] != self._private._bucket or value["region"] != self._transport._region
                    or value["owner"] != self._private._owner or value["writer_sha256"] != self._writer_hash
                    or not isinstance(value["probe_key"], str) or not re.fullmatch(PREFIX + r"[a-f0-9]{64}", value["probe_key"])
                    or not isinstance(value["original_sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", value["original_sha256"])
                    or value["original_sha256"] != value["readback_sha256"] or value["put_status"] != 200
                    or value["duplicate_status"] != 412 or value["duplicate_error"] != "PreconditionFailed"
                    or not checksum
                    or value["bucket_type"] != "private"
                    or value["bucket_policy"] not in (None, {"Version": "2012-10-17", "Statement": []})):
                raise PrivateMediaUnavailable()
            for name in ("object_acl", "bucket_acl"):
                _owner_acl(base64.b64decode(value[name], validate=True), self._private._owner)
            now = self._wall().astimezone(dt.timezone.utc); checked = _utc(value["checked_at"])
            if checked > now or self._mode == "pilot" and (now - checked).total_seconds() >= 300:
                raise PrivateMediaUnavailable()
            return (release_digest, None) if self._mode == "release" else (hashlib.sha256(raw).hexdigest(), checked + dt.timedelta(seconds=300))
        except Exception:
            raise PrivateMediaUnavailable() from None

    def _request(self, deadline, cancel):
        if (type(deadline) not in {int, float} or not math.isfinite(deadline)
                or not callable(getattr(cancel, "is_set", None))):
            raise PrivateMediaUnavailable()
        self._private._check(deadline, cancel)

    def prepare_put(self, record, *, deadline, cancel):
        key, size, sha, mime = _record(record); self._request(deadline, cancel)
        proof, proof_end = self._proof()
        checked = self._private._privacy(deadline, cancel)
        now = self._wall().astimezone(dt.timezone.utc); signed = now.replace(microsecond=0)
        expires = 60 if proof_end is None else min(60, math.floor((proof_end - now).total_seconds()))
        if expires < 1:
            raise PrivateMediaUnavailable()
        stamp = signed.strftime("%Y%m%dT%H%M%SZ"); scope = stamp[:8] + "/" + self._transport._region + "/s3/aws4_request"
        headers = {"Content-Type": mime, "Content-Length": str(size), "If-None-Match": "*",
            "x-amz-checksum-sha256": base64.b64encode(bytes.fromhex(sha)).decode(), "x-amz-content-sha256": sha}
        lower = {name.lower(): value for name, value in headers.items()}; lower["host"] = HOST
        names = ";".join(sorted(lower)); path = "/" + self._private._bucket + "/" + key
        query = {"X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": self._transport._access + "/" + scope,
            "X-Amz-Date": stamp, "X-Amz-Expires": str(expires), "X-Amz-SignedHeaders": names}
        quote = lambda value: urllib.parse.quote(value, safe="-_.~")
        encoded = "&".join(quote(name) + "=" + quote(query[name]) for name in sorted(query))
        canonical = "\n".join(["PUT", path, encoded, "".join(name + ":" + lower[name] + "\n" for name in sorted(lower)), names, sha])
        to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        signing_key = ("AWS4" + self._transport._secret).encode()
        for part in [stamp[:8], self._transport._region, "s3", "aws4_request"]:
            signing_key = hmac.digest(signing_key, part.encode(), "sha256")
        signature = hmac.digest(signing_key, to_sign.encode(), "sha256").hex()
        self._request(deadline, cancel)
        if self._clock() - checked > 5 or self._proof()[0] != proof:
            raise PrivateMediaUnavailable()
        return {"url": ENDPOINT[:-1] + path + "?" + encoded + "&X-Amz-Signature=" + signature, "headers": headers,
            "expiresAt": (signed + dt.timedelta(seconds=expires)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")}

    def verify_ready(self, record, *, deadline, cancel):
        with io.BytesIO() as spool:
            return self._verify_to_spool(record, spool, deadline=deadline, cancel=cancel)

    def require_private(self, record, *, deadline, cancel):
        key, *_ = _record(record); self._request(deadline, cancel); proof, _ = self._proof()
        checked = self._private._privacy(deadline, cancel)
        _owner_acl(self._private._control("GetObjectAcl", key, deadline, cancel), self._private._owner)
        self._request(deadline, cancel)
        if self._clock() - checked > 5 or self._proof()[0] != proof: raise PrivateMediaUnavailable()

    def get_verified_to_file(self, record, sink, *, deadline, cancel):
        if sink.tell() != 0: raise PrivateMediaUnavailable()
        evidence = self._verify_to_spool(record, sink, deadline=deadline, cancel=cancel)
        self.require_verified(evidence, record); sink.seek(0)
        return evidence

    def _verify_to_spool(self, record, spool, *, deadline, cancel):
        bound = _record(record); key, size, sha, mime = bound; self._request(deadline, cancel)
        if not all(callable(getattr(self._image, name, None)) for name in ("decode_verified", "require_verified")):
            raise PrivateMediaUnavailable()
        deadline = min(deadline, self._clock() + 60)
        proof, _ = self._proof(); response = None
        try:
            checked = self._private._privacy(deadline, cancel)
            _owner_acl(self._private._control("GetObjectAcl", key, deadline, cancel), self._private._owner)
            if self._clock() - checked > 5:
                raise PrivateMediaUnavailable()
            response = self._transport.open("GetObject", self._private._bucket, key, deadline, cancel)
            headers = _headers(response)
            if response.status != 200:
                raise PrivateMediaUnavailable()
            if _length(headers, MAX_BYTES) != size or headers.get("content-type") != mime:
                raise NativePhotoObjectMismatch()
            digest = hashlib.sha256(); total = 0
            while True:
                self._request(deadline, cancel); amount = min(CHUNK_BYTES, size - total + 1); chunk = response.read(amount)
                if not isinstance(chunk, bytes):
                    raise PrivateMediaUnavailable()
                if len(chunk) > amount or total + len(chunk) > size:
                    raise PrivateMediaUnavailable()
                if not chunk:
                    break
                digest.update(chunk); total += len(chunk); spool.write(chunk)
            if total != size:  # Early EOF can be transport loss, never a definitive rejected upload.
                raise PrivateMediaUnavailable()
            if not hmac.compare_digest(digest.hexdigest(), sha):
                raise NativePhotoObjectMismatch()
            response.close(); response = None
            spool.seek(0)
            image_proof = self._image.decode_verified(spool, dict(record), deadline=deadline, cancel=cancel)
            if image_proof is None or isinstance(image_proof, (bool, int, float, str, bytes, dict, list, tuple)):
                raise PrivateMediaUnavailable()
            self._image.require_verified(image_proof, dict(record))
            checked = self._private._privacy(deadline, cancel)
            _owner_acl(self._private._control("GetObjectAcl", key, deadline, cancel), self._private._owner)
            self._request(deadline, cancel)
            if self._clock() - checked > 5 or self._proof()[0] != proof:
                raise PrivateMediaUnavailable()
            evidence = _Verified()
            with self._lock:
                self._evidence[evidence] = (bound, proof, self._clock(), checked, deadline, cancel, image_proof)
            return evidence
        except NativePhotoObjectMismatch:
            raise NativePhotoObjectMismatch() from None
        except Exception:
            raise PrivateMediaUnavailable() from None
        finally:
            if response is not None:
                response.close()

    def require_verified(self, evidence, record):
        bound = _record(record)
        with self._lock:
            value = self._evidence.get(evidence) if type(evidence) is _Verified else None
        if value is None:
            raise PrivateMediaUnavailable()
        expected, proof, issued, checked, deadline, cancel, image_proof = value
        self._request(deadline, cancel)
        if (bound != expected or not 0 <= self._clock() - issued <= 15 or not 0 <= self._clock() - checked <= 5
                or self._proof()[0] != proof):
            raise PrivateMediaUnavailable()
        self._image.require_verified(image_proof, dict(record))
        self._request(deadline, cancel)
        if self._clock() - checked > 5 or self._proof()[0] != proof:
            raise PrivateMediaUnavailable()
