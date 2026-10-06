"""Focused synthetic HTTPS-port checks. No credentials, SQL or external requests."""
import base64
import datetime as dt
import hashlib
import hmac
import io
import json
import threading
import unittest
from urllib.parse import parse_qsl, quote, urlsplit

import native_photo_upload_s3 as upload
from private_media_s3 import PrivateMediaUnavailable, TimewebPrivateBucketState
from runtime_profile_photo_uploads import PhotoUploadVerificationFailed

BUCKET = "synthetic-private-bucket"
OWNER = "synthetic-owner"
ACCESS = "SYNTHETIC_WRITER_KEY"
SECRET = "synthetic-writer-secret"
PROOF_KEY = b"synthetic-operator-proof-key-32bytes"
KEY = upload.PREFIX + "a" * 64
BODY = b"synthetic-image-original\xff" * 3000
WALL = dt.datetime(2026, 10, 3, 12, 0, 0, 250000, tzinfo=dt.timezone.utc)


def acl(owner=OWNER, *, public=False):
    grantee = ('<Grantee><Type>Group</Type><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee>'
        if public else f'<Grantee><Type>CanonicalUser</Type><ID>{owner}</ID></Grantee>')
    return (f'<AccessControlPolicy><Owner><ID>{owner}</ID></Owner><AccessControlList>'
        f'<Grant>{grantee}<Permission>FULL_CONTROL</Permission></Grant></AccessControlList></AccessControlPolicy>').encode()


def record(body=BODY):
    return {"key": KEY, "size": len(body), "sha256": hashlib.sha256(body).hexdigest(), "content_type": "image/jpeg"}


def signed_proof(**changes):
    value = {"version": 1, "endpoint": upload.ENDPOINT, "bucket": BUCKET, "region": "ru-1", "owner": OWNER,
        "writer_sha256": hashlib.sha256(ACCESS.encode()).hexdigest(), "checked_at": WALL.strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "probe_key": upload.PREFIX + "b" * 64, "original_sha256": hashlib.sha256(b"synthetic-probe").hexdigest(),
        "readback_sha256": hashlib.sha256(b"synthetic-probe").hexdigest(), "put_status": 200,
        "duplicate_status": 412, "duplicate_error": "PreconditionFailed", "checksum_status": 400,
        "checksum_error": "BadDigest", "object_acl": base64.b64encode(acl()).decode(),
        "bucket_acl": base64.b64encode(acl()).decode(), "bucket_type": "private", "bucket_policy": None}
    value.update(changes)
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return raw, hmac.digest(PROOF_KEY, upload.PROOF_DOMAIN + raw, "sha256").hex()


def signed_proof_v2(**changes):
    value = json.loads(signed_proof()[0])
    value.update(version=2, checksum_validation=False, checksum_observation="checksum_not_enforced",
        checksum_status=200, checksum_error=None, checksum_body_sha256=value["original_sha256"],
        checksum_sent_sha256="0" * 64, checksum_readback_sha256=value["original_sha256"])
    value.update(changes)
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return raw, hmac.digest(PROOF_KEY, upload.PROOF_V2_DOMAIN + raw, "sha256").hex()


class Response:
    def __init__(self, body, *, status=200, mime="application/xml", headers=None):
        self.status = status; self.body = io.BytesIO(body); self.closed = False; self.amounts = []
        self.headers = headers or [("Content-Length", str(len(body))), ("Content-Type", mime)]

    def getheaders(self):
        return self.headers

    def read(self, amount):
        self.amounts.append(amount)
        return self.body.read(amount)

    def close(self):
        self.closed = True


class Socket:
    def settimeout(self, value):
        assert 0 < value <= 2

    def shutdown(self, how):
        pass


class Connection:
    def __init__(self, owner, api=False):
        self.owner = owner; self.api = api; self.sock = Socket(); self.closed = False

    def connect(self):
        pass

    def request(self, method, path, *, headers):
        self.owner.calls.append((method, path, dict(headers), self.api)); self.path = path
        assert method == "GET", "Verifier must never PUT/HEAD/redirect/retry"

    def getresponse(self):
        reply = self.owner.reply(self.path, self.api)
        self.owner.replies.append(reply)
        return reply

    def close(self):
        self.closed = True


class HTTPSStub:
    def __init__(self):
        self.calls = []; self.replies = []; self.connections = []; self.override = None; self.body = BODY
        self.object_acl_count = 0; self.public_after_get = False; self.bucket_type = "private"

    def connect(self, api=False):
        conn = Connection(self, api); self.connections.append(conn)
        return conn

    def reply(self, path, api):
        if api:
            assert path == "/api/v1/storages/buckets/1"
            value = {"bucket": {"id": 1, "name": BUCKET, "type": self.bucket_type, "website_config": None}}
            return Response(json.dumps(value).encode(), mime="application/json")
        if self.override:
            answer = self.override(path)
            if answer is not None:
                return answer
        if path == "/" + BUCKET + "/" + KEY:
            return Response(self.body, mime="image/jpeg")
        if path == "/" + BUCKET + "/" + KEY + "?acl=":
            self.object_acl_count += 1
            return Response(acl(public=self.public_after_get and self.object_acl_count > 1))
        if path == "/" + BUCKET + "?acl=":
            return Response(acl())
        if path == "/" + BUCKET + "?policy=":
            return Response(b'{"Version":"2012-10-17","Statement":[]}', mime="application/json")
        raise AssertionError("Arbitrary path denied")


class SyntheticImageVerifier:
    """Trusted test seam only; does NOT prove real raster decoding or production readiness."""
    def __init__(self):
        self.calls = []; self.tokens = {}; self.raise_error = None; self.literal = False

    def decode_verified(self, spool, record, *, deadline, cancel):
        self.calls.append((spool, dict(record), deadline, cancel))
        if self.raise_error:
            raise self.raise_error()
        raw = spool.read()
        assert len(raw) <= upload.MAX_BYTES and hashlib.sha256(raw).hexdigest() == record["sha256"]
        if self.literal:
            return True
        token = object(); self.tokens[token] = upload._record(record)
        return token

    def require_verified(self, token, record):
        if self.tokens.get(token) != upload._record(record):
            raise PrivateMediaUnavailable()


def verify_signature(descriptor, headers=None):
    parsed = urlsplit(descriptor["url"]); args = dict(parse_qsl(parsed.query)); signature = args.pop("X-Amz-Signature")
    exact = descriptor["headers"] if headers is None else headers
    lower = {name.lower(): value for name, value in exact.items()}; lower["host"] = parsed.netloc
    names = args["X-Amz-SignedHeaders"]
    canonical_query = "&".join(quote(name, safe="-_.~") + "=" + quote(args[name], safe="-_.~") for name in sorted(args))
    canonical = "\n".join(["PUT", parsed.path, canonical_query,
        "".join(name + ":" + lower[name] + "\n" for name in names.split(";")), names, lower["x-amz-content-sha256"]])
    scope = args["X-Amz-Credential"].split("/", 1)[1]
    value = "\n".join([args["X-Amz-Algorithm"], args["X-Amz-Date"], scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = ("AWS4" + SECRET).encode()
    for part in scope.split("/"):
        key = hmac.digest(key, part.encode(), "sha256")
    return hmac.compare_digest(signature, hmac.digest(key, value.encode(), "sha256").hex())


class NativeUploadPortTests(unittest.TestCase):
    def setUp(self):
        self.stub = HTTPSStub(); self.now = 100.0; self.wall = WALL; self.cancel = threading.Event()
        self.proof = signed_proof(); self.image = SyntheticImageVerifier()
        self.port = self.make_port()

    def make_port(self, **changes):
        state = TimewebPrivateBucketState(1, BUCKET, "synthetic-control-token", connection_factory=lambda: self.stub.connect(True),
            monotonic=lambda: self.now)
        kwargs = {"bucket_state": state, "provider_proof": lambda: self.proof, "proof_key": PROOF_KEY,
            "image_verifier": self.image, "connection_factory": self.stub.connect,
            "monotonic": lambda: self.now, "wall_clock": lambda: self.wall}
        kwargs.update(changes)
        return upload.NativePhotoUploadS3(upload.ENDPOINT, "ru-1", BUCKET, OWNER, ACCESS, SECRET, **kwargs)

    def tearDown(self):
        self.assertTrue(all(conn.closed for conn in self.stub.connections))
        self.assertTrue(all(reply.closed for reply in self.stub.replies))
        self.assertTrue(all(spool.closed for spool, *_ in self.image.calls))

    def test_v2_observed_checksum_capability_never_replaces_actual_byte_verification(self):
        for changes in ({}, {"checksum_validation": True, "checksum_observation": "bad_digest_rejected",
                "checksum_status": 400, "checksum_error": "BadDigest", "checksum_readback_sha256": None}):
            with self.subTest(capability=changes.get("checksum_validation", False)):
                self.proof = signed_proof_v2(**changes)
                lease = self.port.prepare_put(record(), deadline=105, cancel=self.cancel)
                self.assertTrue(verify_signature(lease))
                self.assertEqual(lease["headers"]["If-None-Match"], "*")
                self.assertEqual(base64.b64decode(lease["headers"]["x-amz-checksum-sha256"]), hashlib.sha256(BODY).digest())
                evidence = self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
                self.port.require_verified(evidence, record())
                with self.assertRaises(PrivateMediaUnavailable):
                    self.port.require_verified(object(), record())
                self.stub.body = b"x" * len(BODY)  # Same MIME/size, different actual bytes.
                with self.assertRaises(PhotoUploadVerificationFailed):
                    self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
                self.stub.body = BODY
        calls = len(self.stub.calls)
        bad_pairs = ({"checksum_status": 400, "checksum_error": "BadDigest"},
            {"checksum_error": "BadDigest"}, {"checksum_validation": True},
            {"checksum_validation": 0}, {"checksum_observation": "unknown"},
            {"checksum_body_sha256": "1" * 64}, {"checksum_sent_sha256": hashlib.sha256(b"synthetic-probe").hexdigest()},
            {"checksum_readback_sha256": None}, {"checksum_readback_sha256": "f" * 64},
            {"checksum_validation": True, "checksum_observation": "bad_digest_rejected",
                "checksum_status": 400, "checksum_error": "BadDigest"})
        for changes in bad_pairs:
            self.proof = signed_proof_v2(**changes)
            with self.subTest(changes=changes), self.assertRaises(PrivateMediaUnavailable): self.port._proof()
        raw, mac = signed_proof_v2()
        for bad in ((raw, "0" * 64),
                (raw, hmac.digest(PROOF_KEY, upload.PROOF_DOMAIN + raw, "sha256").hex())):
            self.proof = bad
            with self.assertRaises(PrivateMediaUnavailable): self.port._proof()
        self.proof = signed_proof_v2(); self.wall += dt.timedelta(seconds=300)
        with self.assertRaises(PrivateMediaUnavailable): self.port._proof()
        self.wall = WALL; self.proof = signed_proof()  # Existing exact v1 shape/domain remains supported.
        self.port._proof()
        self.proof = signed_proof(checksum_status=200, checksum_error=None)
        with self.assertRaises(PrivateMediaUnavailable): self.port._proof()
        self.assertEqual(len(self.stub.calls), calls)

    def test_closed_missing_tampered_expired_foreign_or_false_provider_proof(self):
        for port in (self.make_port(provider_proof=None), self.make_port(provider_proof=True), self.make_port(proof_key=None)):
            for method in (port.prepare_put, port.verify_ready):
                with self.assertRaises(PrivateMediaUnavailable): method(record(), deadline=160, cancel=self.cancel)
        original = self.proof
        cases = [(original[0], "0" * 64), signed_proof(bucket="foreign-private-bucket"), signed_proof(duplicate_status=200),
            signed_proof(checksum_status=200), signed_proof(readback_sha256="f" * 64),
            signed_proof(writer_sha256="a" * 64), signed_proof(object_acl=base64.b64encode(acl(public=True)).decode()),
            signed_proof(checked_at="2026-10-03T11:55:00.250000Z"), signed_proof(checked_at="2026-10-03T12:00:01.250000Z")]
        for proof in cases:
            self.proof = proof
            with self.assertRaises(PrivateMediaUnavailable): self.port.prepare_put(record(), deadline=160, cancel=self.cancel)
        self.assertEqual(self.stub.calls, [])

    def test_presign_exact_conditional_headers_length_checksum_expiry_and_fixed_native_path(self):
        result = self.port.prepare_put(record(), deadline=105, cancel=self.cancel)
        self.assertEqual(set(result), {"url", "headers", "expiresAt"})
        self.assertEqual(set(result["headers"]), {"Content-Type", "Content-Length", "If-None-Match", "x-amz-checksum-sha256", "x-amz-content-sha256"})
        self.assertEqual(result["headers"]["If-None-Match"], "*")
        self.assertEqual(result["headers"]["Content-Length"], str(len(BODY)))
        self.assertEqual(base64.b64decode(result["headers"]["x-amz-checksum-sha256"]), hashlib.sha256(BODY).digest())
        parts = urlsplit(result["url"])
        self.assertEqual((parts.scheme, parts.netloc, parts.path), ("https", upload.HOST, "/" + BUCKET + "/" + KEY))
        self.assertEqual(dict(parse_qsl(parts.query))["X-Amz-Expires"], "60")
        self.assertEqual(result["expiresAt"], "2026-10-03T12:01:00.000000Z")
        self.assertTrue(verify_signature(result))
        for name in result["headers"]:
            changed = dict(result["headers"]); changed[name] += "changed"
            self.assertFalse(verify_signature(result, changed))
        self.assertEqual(len(self.stub.calls), 3)  # Fresh API, bucket ACL and policy before issuing lease.
        self.assertTrue(all(method == "GET" for method, *_ in self.stub.calls))

    def test_full_byte_get_and_private_prepost_checks_opaque_same_port_same_record_evidence(self):
        evidence = self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
        self.port.require_verified(evidence, record())
        self.assertEqual(self.stub.object_acl_count, 2)
        self.assertEqual(len(self.image.calls), 1)
        self.assertEqual(self.image.calls[0][1:], (record(), 160, self.cancel))
        body_response = next(reply for reply in self.stub.replies if reply.headers[-1][1] == "image/jpeg")
        self.assertEqual(body_response.body.tell(), len(BODY))
        self.assertTrue(all(1 <= amount <= 65536 for amount in body_response.amounts))
        self.assertEqual(sum(path.endswith("/" + KEY) for _, path, _, _ in self.stub.calls), 1)
        self.assertTrue(all(not headers.get("authorization", "").startswith("AWS4") or ACCESS in headers["authorization"]
            for _, _, headers, _ in self.stub.calls))
        for alien in (True, {}, object()):
            with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(alien, record())
        with self.assertRaises(PrivateMediaUnavailable): self.make_port().require_verified(evidence, record())
        changed = record(); changed["key"] = upload.PREFIX + "c" * 64
        with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(evidence, changed)
        self.now += 5.01
        with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(evidence, record())

    def test_proved_object_mismatch_is_specific_but_redirect_io_privacy_and_cancel_are_unknown(self):
        self.assertIs(upload.NativePhotoObjectMismatch, PhotoUploadVerificationFailed)
        for body, mime, length in ((BODY[:-1], "image/jpeg", len(BODY) - 1), (BODY, "image/png", len(BODY)),
                (b"x" * len(BODY), "image/jpeg", len(BODY))):
            self.stub.override = lambda path, body=body, mime=mime, length=length: Response(body,
                headers=[("Content-Length", str(length)), ("Content-Type", mime)]) if path.endswith("/" + KEY) else None
            with self.assertRaises(PhotoUploadVerificationFailed): self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
        self.stub.override = lambda path: Response(BODY[:-1], headers=[("Content-Length", str(len(BODY))),
            ("Content-Type", "image/jpeg")]) if path.endswith("/" + KEY) else None
        with self.assertRaises(PrivateMediaUnavailable): self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
        self.stub.override = lambda path: Response(b"", status=302) if path.endswith("/" + KEY) else None
        with self.assertRaises(PrivateMediaUnavailable): self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
        self.stub.override = None; self.stub.public_after_get = True; self.stub.object_acl_count = 0
        with self.assertRaises(PrivateMediaUnavailable): self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
        self.stub.public_after_get = False; self.stub.bucket_type = "public"
        with self.assertRaises(PrivateMediaUnavailable): self.port.prepare_put(record(), deadline=160, cancel=self.cancel)
        self.cancel.set()
        with self.assertRaises(PrivateMediaUnavailable): self.port.prepare_put(record(), deadline=160, cancel=self.cancel)

    def test_native_prefix_size_mime_bounds_and_no_arbitrary_endpoint_or_operation(self):
        for change in ({"key": "clrs-import-quarantine/" + "a" * 64}, {"key": KEY + "/../other"}, {"size": 0},
                {"size": upload.MAX_BYTES + 1}, {"size": True}, {"content_type": "image/gif"}, {"sha256": "A" * 64}):
            value = record(); value.update(change)
            with self.assertRaises(PrivateMediaUnavailable): self.port.prepare_put(value, deadline=160, cancel=self.cancel)
        self.assertEqual(self.stub.calls, [])
        with self.assertRaises(PrivateMediaUnavailable):
            upload.NativePhotoUploadS3("http://s3.twcstorage.ru/", "ru-1", BUCKET, OWNER, ACCESS, SECRET, bucket_state=lambda *_: None)
        for operation, key in (("HeadObject", KEY), ("PutObject", KEY), ("DeleteObject", KEY), ("GetObject", "foreign-prefix/" + "a" * 64)):
            with self.assertRaises(PrivateMediaUnavailable): self.port._transport.open(operation, BUCKET, key, 160, self.cancel)
        exact = record(b"x" * upload.MAX_BYTES)
        self.assertEqual(upload._record(exact)[1], upload.MAX_BYTES)

    def test_evidence_invalidates_on_current_proof_change_expiry_and_deadline(self):
        evidence = self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
        self.proof = signed_proof(probe_key=upload.PREFIX + "c" * 64)
        with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(evidence, record())
        self.proof = signed_proof(); self.wall += dt.timedelta(seconds=301)
        with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(evidence, record())
        self.wall = WALL; self.now = 160
        with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(evidence, record())

    def test_ready_closed_without_actual_decoder_or_with_literal_cap_and_decoder_failure_distinction(self):
        for value in (None, True, lambda *_: True):
            with self.assertRaises(PrivateMediaUnavailable):
                self.make_port(image_verifier=value).verify_ready(record(), deadline=160, cancel=self.cancel)
        self.assertEqual(self.stub.calls, [])
        self.image.literal = True
        with self.assertRaises(PrivateMediaUnavailable): self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
        self.image.literal = False; self.image.raise_error = PhotoUploadVerificationFailed
        with self.assertRaises(PhotoUploadVerificationFailed): self.port.verify_ready(record(), deadline=160, cancel=self.cancel)
        self.image.raise_error = OSError
        with self.assertRaises(PrivateMediaUnavailable): self.port.verify_ready(record(), deadline=160, cancel=self.cancel)


if __name__ == "__main__":
    unittest.main()
