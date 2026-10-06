"""Actual S3 adapter + actual raster worker + SQL core, synthetic HTTPS only."""
from datetime import datetime, timezone
import hashlib
import io
import time
import unittest

from PIL import Image
import native_photo_upload_s3 as upload
from native_photo_raster import BoundedRasterVerifier
from private_media_s3 import TimewebPrivateBucketState
from runtime_mutations import RuntimeMutationStore
from runtime_profile_photo_uploads import RuntimeProfilePhotoUploadsService, COMMIT_OPERATION, photo_identity
from runtime_profile_photo_uploads_http import RuntimeProfilePhotoUploadsHttp
from test_native_photo_upload_s3 import HTTPSStub, KEY, BUCKET, OWNER, ACCESS, SECRET, PROOF_KEY, signed_proof
from test_runtime_profile_photo_uploads import PhotoDatabase, NEW_STAMP, SECOND
from test_runtime_http import Native, env, OP
from test_runtime_mutations import NOW, STAMP


class RealPortScope:
    """Forward real evidence checks; inject expiry/cancel only after SQL writes."""
    def __init__(self, port, delta, failure):
        self.port = port; self.delta = delta; self.failure = failure
        self.checks = 0; self.cancel = None

    def prepare_put(self, *args, **kwargs): return self.port.prepare_put(*args, **kwargs)

    def verify_ready(self, *args, **kwargs):
        self.cancel = kwargs["cancel"]
        return self.port.verify_ready(*args, **kwargs)

    def require_verified(self, evidence, record):
        self.checks += 1
        if self.checks == 2:
            if self.failure == "cancelled": self.cancel.set()
            if self.failure == "expired": self.delta[0] += 5.01
        self.port.require_verified(evidence, record)


class NativePhotoIntegrationTests(unittest.TestCase):
    def test_actual_adapter_decoder_commit_and_expired_or_cancelled_proof_rollback(self):
        spool = io.BytesIO(); Image.new("RGB", (32, 24), "orange").save(spool, format="JPEG")
        body = spool.getvalue()
        for failure in (None, "expired", "cancelled"):
            with self.subTest(failure=failure):
                db = PhotoDatabase(); delta = [0.0]; clock = lambda: time.monotonic() + delta[0]
                mid, key = photo_identity("actor", OP)
                class DerivedHTTPS(HTTPSStub):
                    def reply(self, path, api):
                        if path.startswith("/" + BUCKET + "/" + key):
                            path = path.replace(key, KEY, 1)
                        return super().reply(path, api)
                stub = DerivedHTTPS(); stub.body = body
                wall = datetime.fromtimestamp(NOW, timezone.utc)
                proof = signed_proof(checked_at=wall.strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
                state = TimewebPrivateBucketState(1, BUCKET, "synthetic-control-token",
                    connection_factory=lambda: stub.connect(True), monotonic=clock)
                image = BoundedRasterVerifier(monotonic=clock)
                port = upload.NativePhotoUploadS3(upload.ENDPOINT, "ru-1", BUCKET, OWNER, ACCESS, SECRET,
                    bucket_state=state, provider_proof=lambda: proof, proof_key=PROOF_KEY,
                    image_verifier=image, connection_factory=stub.connect, monotonic=clock, wall_clock=lambda: wall)
                writer = RealPortScope(port, delta, failure)
                store = RuntimeMutationStore(db.env, db.tokens, connect=db.connect, clock=lambda: NOW)
                self.addCleanup(store.close)
                service = RuntimeProfilePhotoUploadsService(store, writer=writer, monotonic=clock, clock=lambda: NOW)
                adapter = RuntimeProfilePhotoUploadsHttp(db.env, service=service); native = Native(); native.identity = db.identity
                def call(path, value):
                    request = env(path, value); request["HTTP_AUTHORIZATION"] = "Bearer " + db.access
                    return adapter.dispatch(request, native_service=native, native_configured=True)
                prepared = call("/v1/runtime/profile/photos/prepare", {"operationId": OP,
                    "sha256": hashlib.sha256(body).hexdigest(), "byteSize": len(body), "mimeType": "image/jpeg"})
                self.assertEqual(prepared.status, "201 Created")
                result = call("/v1/runtime/profile/photos/commit", {"operationId": SECOND, "prepareOperationId": OP, "mediaId": mid})
                self.assertEqual(writer.checks, 2)
                self.assertTrue(writer.cancel.is_set(), "Caller cancels only after the transaction settles")
                self.assertTrue(all(conn.closed for conn in stub.connections))
                self.assertTrue(all(response.closed for response in stub.replies))
                if failure is None:
                    self.assertEqual(result.status, "200 OK")
                    self.assertTrue(result.payload["result"]["ready"])
                    self.assertEqual((db.state["media"][mid][7], db.state["photos"]["actor"], db.state["profiles"]["actor"]),
                        ("ready", [[mid, 0, 1]], NEW_STAMP))
                    self.assertIn(("actor", COMMIT_OPERATION, SECOND), db.state["receipts"])
                else:
                    self.assertEqual(result.status, "503 Service Unavailable")
                    self.assertEqual(db.state["media"][mid][7], "pending")
                    self.assertFalse(db.state["photos"])
                    self.assertEqual(db.state["profiles"]["actor"], STAMP)
                    self.assertNotIn(("actor", COMMIT_OPERATION, SECOND), db.state["receipts"])


if __name__ == "__main__": unittest.main()
