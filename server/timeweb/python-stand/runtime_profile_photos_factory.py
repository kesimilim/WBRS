"""Native photo setup from the already reviewed completed media receipt.

Construction performs no SQL/S3 request and uses only the dedicated read key.
The authenticated acknowledgement pins the reviewed full raw import readback;
it is not evidence that the final Firebase write barrier has happened.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import re
import tempfile
import threading

from media_promotion_acknowledgement import (PINS, SOURCE,
    MAX_ACKNOWLEDGEMENT_BYTES,
    verify_media_promotion_acknowledgement)
from native_credentials import decode_base64
from private_media_s3 import (PrivateMediaS3, SigV4HTTPSReadTransport,
    TimewebPrivateBucketState)
from profile_photo_projector import COUNTS, verify_source_snapshot
from runtime_mutations import RuntimeMutationStore, RuntimeUnavailable
from runtime_profile_photos import (RuntimeProfilePhotosService, GALLERY_ORDER_POLICY,
    GALLERY_AVAILABLE_ORDER_POLICY)
from runtime_profile_photos_http import RuntimeProfilePhotosHttp


def completed_source_from_media_receipt(env, promotion):
    """Trusted setup only: reuse the exact authenticated full-readback receipt.

    verify_media_promotion_acknowledgement checked its authenticated fixed
    RAW_READBACK_PROOF_SHA256, source pins and 26 completed chunk receipts.
    No caller supplies alternative archive/completion facts or a fake cap.
    """
    verified = verify_media_promotion_acknowledgement(env)
    raw = base64.b64decode(env["CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64"], validate=True)
    if (not 1 <= len(raw) <= MAX_ACKNOWLEDGEMENT_BYTES
            or hashlib.sha256(raw).hexdigest() != verified.ciphertext_sha256
            or verified != promotion):
        raise RuntimeUnavailable()
    def verifier(supplied):
        if not hmac.compare_digest(supplied, raw): raise RuntimeUnavailable()
        # This fixed raw-readback SHA is part of the authenticated receipt
        # verified above, not a loose environment string or current SQL fact.
        return {"archiveSha256": PINS["archiveSha256"],
            "manifestSha256": PINS["inventoryManifestSha256"],
            "receiptDigest": hashlib.sha256(supplied).hexdigest(),
            "source": dict(SOURCE), "counts": dict(COUNTS), "consistent": False,
            "completion": "verified_completed_archival_import_readback"}
    return verify_source_snapshot(raw, trusted_verifier=verifier)


class _OwnedReader:
    def __init__(self, service, store, directory):
        self._service = service; self._store = store; self._directory = directory
        self._lock = threading.Lock(); self._closed = False

    def photos(self, *args, **kwargs):
        return self._service.photos(*args, **kwargs)

    def open_photo(self, *args, **kwargs):
        return self._service.open_photo(*args, **kwargs)

    def close(self):
        with self._lock:
            if self._closed: return
            self._closed = True
        # Abort leases/downloads first; the store then aborts owned SQL work.
        # TemporaryFile streams are anonymous, so cleanup never unlinks a
        # user image and active setup retains ownership of its open stream.
        try: self._service.close()
        finally:
            try: self._store.close()
            finally: self._directory.cleanup()


def create_profile_photos_service(env):
    if env.get("CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED") != "1": return None
    store = directory = service = None
    try:
        if (env.get("CLRS_RUNTIME_WRITES_ENABLED") != "1"
                or env.get("CLRS_RUNTIME_MEMBERSHIP_AUTHORITY") != "canonical-current-v1"
                or env.get("CLRS_LEGACY_MEDIA_PROMOTION_REVIEWED") != "1"
                or env.get("CLRS_LEGACY_MEDIA_PROMOTION_MODE") != "reviewed-immutable-object-alias"
                or env.get("CLRS_LEGACY_MEDIA_S3_USER_MODE") != "dedicated-read-only"
                or env.get("CLRS_RUNTIME_PROFILE_PHOTO_ORDER_POLICY") not in
                    (GALLERY_ORDER_POLICY, GALLERY_AVAILABLE_ORDER_POLICY)):
            raise RuntimeUnavailable()
        cursor_key = decode_base64(env.get("CLRS_LEGACY_READ_CURSOR_KEY_B64"), max_bytes=32)
        session_key = decode_base64(env.get("CLRS_NATIVE_SESSION_KEY_B64"), max_bytes=32)
        if len(cursor_key) != 32 or len(session_key) != 32 or hmac.compare_digest(cursor_key, session_key):
            raise RuntimeUnavailable()
        promotion = verify_media_promotion_acknowledgement(env,
            separate_from=(cursor_key, session_key))
        source = completed_source_from_media_receipt(env, promotion)
        bucket_id = env.get("CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID", "")
        if type(bucket_id) is not str or re.fullmatch(r"[1-9][0-9]{0,18}", bucket_id) is None:
            raise RuntimeUnavailable()
        bucket = env.get("CLRS_LEGACY_MEDIA_TARGET_BUCKET")
        owner = env.get("CLRS_LEGACY_MEDIA_EXPECTED_OWNER")
        transport = SigV4HTTPSReadTransport("https://s3.twcstorage.ru/",
            env.get("CLRS_LEGACY_MEDIA_S3_REGION"), env.get("CLRS_LEGACY_MEDIA_S3_ACCESS_KEY"),
            env.get("CLRS_LEGACY_MEDIA_S3_SECRET_KEY"))
        state = TimewebPrivateBucketState(int(bucket_id), bucket,
            env.get("CLRS_LEGACY_MEDIA_CONTROL_TOKEN"))
        s3 = PrivateMediaS3(bucket, owner, transport, state)
        # This store does not retain the S3/receipt credentials in its env.
        store_env = {name: env[name] for name in ("CLRS_RUNTIME_WRITES_ENABLED",
            "CLRS_RUNTIME_MEMBERSHIP_AUTHORITY", "CLRS_RUNTIME_PERMISSION_MODEL",
            "CLRS_RUNTIME_DB_URL", "CLRS_RUNTIME_DB_CA_FILE", "CLRS_NATIVE_SESSION_KEY_B64") if name in env}
        store = RuntimeMutationStore.from_env(store_env)
        if store is None: raise RuntimeUnavailable()
        directory = tempfile.TemporaryDirectory(prefix="clrs-native-profile-photos-")
        os.chmod(directory.name, 0o700)
        service = RuntimeProfilePhotosService(store, cursor_key, private_s3=s3,
            expected_bucket=bucket, expected_owner=owner, source_snapshot=source,
            media_promotion=promotion, spool_directory=directory.name,
            gallery_order_policy=env["CLRS_RUNTIME_PROFILE_PHOTO_ORDER_POLICY"])
        return _OwnedReader(service, store, directory)
    except Exception:
        if service is not None: service.close()
        if store is not None: store.close()
        if directory is not None: directory.cleanup()
        raise RuntimeUnavailable() from None


def create_profile_photos_http(env):
    # A missing/bad operator flag leaves 404 and does not authenticate, mint
    # proof, retain secrets, create a spool directory or construct a reader.
    factory = None
    if env.get("CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED") == "1":
        settings = dict(env)
        factory = lambda: create_profile_photos_service(settings)
    return RuntimeProfilePhotosHttp(env, service_factory=factory)
