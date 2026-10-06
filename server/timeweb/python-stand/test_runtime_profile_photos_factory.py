"""Addressed native-photo setup/cleanup tests; no TCP, secrets or cloud."""
import base64
import copy
from pathlib import Path
import unittest
from unittest.mock import patch

import runtime_profile_photos_factory as factory
from media_promotion_acknowledgement import verify_media_promotion_acknowledgement
from profile_photo_projector import _SOURCE_CAPS
from runtime_profile_photos import GALLERY_ORDER_POLICY
from runtime_mutations import RuntimeUnavailable
from test_media_promotion_acknowledgement import fixture, KEY, CURSOR_KEY, NOW
from test_runtime_mutations import ENV


class NativePhotoFactoryTests(unittest.TestCase):
    def env(self):
        return {**ENV, **fixture(), "CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED": "1",
            "CLRS_NATIVE_SESSION_KEY_B64": base64.b64encode(bytes(range(32))).decode(),
            "CLRS_RUNTIME_PROFILE_PHOTO_ORDER_POLICY": GALLERY_ORDER_POLICY,
            "CLRS_LEGACY_READ_CURSOR_KEY_B64": base64.b64encode(CURSOR_KEY).decode(),
            "CLRS_LEGACY_MEDIA_PROMOTION_REVIEWED": "1",
            "CLRS_LEGACY_MEDIA_PROMOTION_MODE": "reviewed-immutable-object-alias",
            "CLRS_LEGACY_MEDIA_S3_USER_MODE": "dedicated-read-only",
            "CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID": "466459",
            "CLRS_LEGACY_MEDIA_S3_REGION": "ru-1",
            "CLRS_LEGACY_MEDIA_S3_ACCESS_KEY": "syntheticaccesskey",
            "CLRS_LEGACY_MEDIA_S3_SECRET_KEY": "syntheticSecretKeyNotActual123456",
            "CLRS_LEGACY_MEDIA_CONTROL_TOKEN": "synthetic_control_token"}

    def test_disabled_never_constructs_and_http_is_closed(self):
        with patch.object(factory, "RuntimeMutationStore") as store:
            self.assertIsNone(factory.create_profile_photos_service({}))
            reply = factory.create_profile_photos_http({**ENV,
                "CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED": "0"}).dispatch({
                    "PATH_INFO": "/v1/runtime/people/peer/photos", "REQUEST_METHOD": "GET"})
            self.assertEqual("404 Not Found", reply.status)
            store.from_env.assert_not_called()

    def test_source_cap_is_from_authentic_complete_ack_and_rejects_changed_ciphertext(self):
        env = self.env()
        promotion = verify_media_promotion_acknowledgement(env, clock=lambda: NOW)
        cap = factory.completed_source_from_media_receipt(env, promotion)
        self.assertIn(cap, _SOURCE_CAPS)
        self.assertEqual(promotion.ciphertext_sha256, cap.receipt_digest)
        self.assertFalse(cap.consistent)
        corrupted = copy.deepcopy(env)
        raw = bytearray(base64.b64decode(env["CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64"]))
        raw[-1] ^= 1
        corrupted["CLRS_LEGACY_MEDIA_PROMOTION_ACK_B64"] = base64.b64encode(raw).decode()
        with self.assertRaises(Exception):
            factory.completed_source_from_media_receipt(corrupted, promotion)

    def test_invalid_policy_or_key_separation_refuses_before_store_or_spool(self):
        for change in ({"CLRS_RUNTIME_PROFILE_PHOTO_ORDER_POLICY": "guessed_chronology"},
                {"CLRS_LEGACY_MEDIA_S3_USER_MODE": "migration"},
                {"CLRS_NATIVE_SESSION_KEY_B64": base64.b64encode(CURSOR_KEY).decode()},
                {"CLRS_NATIVE_SESSION_KEY_B64": base64.b64encode(KEY).decode()}):
            with self.subTest(change=tuple(change)), patch.object(factory, "RuntimeMutationStore") as store, \
                    patch.object(factory.tempfile, "TemporaryDirectory") as directory:
                with self.assertRaises(RuntimeUnavailable):
                    factory.create_profile_photos_service({**self.env(), **change})
                store.from_env.assert_not_called(); directory.assert_not_called()

    def test_setup_has_no_network_and_close_removes_spool_and_aborts_owner(self):
        with patch.object(factory.RuntimeMutationStore, "from_env") as make_store, \
                patch.object(factory, "SigV4HTTPSReadTransport") as transport, \
                patch.object(factory, "TimewebPrivateBucketState") as state:
            owned = factory.create_profile_photos_service(self.env())
            path = Path(owned._directory.name)
            self.assertEqual(0o700, path.stat().st_mode & 0o777)
            transport.return_value.open.assert_not_called(); state.return_value.assert_not_called()
            self.assertNotIn("CLRS_LEGACY_MEDIA_S3_SECRET_KEY", make_store.call_args.args[0])
            owned.close(); owned.close()
            make_store.return_value.close.assert_called_once(); self.assertFalse(path.exists())

    def test_late_service_setup_failure_closes_store_and_directory(self):
        with patch.object(factory.RuntimeMutationStore, "from_env") as make_store, \
                patch.object(factory, "RuntimeProfilePhotosService", side_effect=RuntimeUnavailable), \
                patch.object(factory.tempfile, "TemporaryDirectory") as make_directory, \
                patch.object(factory.os, "chmod"):
            with self.assertRaises(RuntimeUnavailable):
                factory.create_profile_photos_service(self.env())
            make_store.return_value.close.assert_called_once()
            make_directory.return_value.cleanup.assert_called_once()

    def test_explicit_available_factory_and_runtime_read_old_complete_rows(self):
        import runtime_profile_photos as photos
        from profile_photo_review import AVAILABLE_GALLERY_POLICY
        from test_runtime_profile_photos import CurrentProfilePhotoTests, doc_row, KEY as PROFILE_KEY
        from test_profile_photo_review import source, url
        env = {**self.env(), "CLRS_RUNTIME_PROFILE_PHOTO_ORDER_POLICY": photos.GALLERY_AVAILABLE_ORDER_POLICY}
        with patch.object(factory.RuntimeMutationStore, "from_env") as make_store, \
                patch.object(factory, "SigV4HTTPSReadTransport") as transport, \
                patch.object(factory, "TimewebPrivateBucketState") as state:
            owned = factory.create_profile_photos_service(env)
            try:
                self.assertEqual(owned._service._gallery_original_policy, AVAILABLE_GALLERY_POLICY)
                transport.return_value.open.assert_not_called(); state.return_value.assert_not_called()
            finally: owned.close()
            make_store.return_value.close.assert_called_once()
        fixture = CurrentProfilePhotoTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.db.add_profile("actor", count=2)
        collection = "users/actor/images"
        blank = source(collection + "/blank", thumbnailUrl={"stringValue": url("thumb-only.jpg")})
        row = doc_row(blank, collection); fixture.db.state["galleries"]["actor"].append(row)
        with self.assertRaises(photos.RuntimeProfilePhotoNotFound):
            fixture.service.photos(fixture.db.identity, "actor", access_token=fixture.db.access)
        service = photos.RuntimeProfilePhotosService(fixture.store, PROFILE_KEY,
            **{**fixture.options, "gallery_order_policy": photos.GALLERY_AVAILABLE_ORDER_POLICY})
        self.addCleanup(service.close)
        page = service.photos(fixture.db.identity, "actor", access_token=fixture.db.access)
        self.assertEqual([(x["ordinal"], x["isPrimary"]) for x in page["items"]], [(0, True), (1, False)])
        reference = page["items"][0]["reference"]
        fixture.db.state["galleries"]["actor"].remove(row)
        self.assertEqual(len(service.photos(fixture.db.identity, "actor", access_token=fixture.db.access)["items"]), 2)
        with self.assertRaises(photos.RuntimeInvalidRequest):
            service._resource(fixture.db.identity, fixture.db.access, "actor", reference)
        self.assertFalse(any(sql.startswith(("INSERT", "UPDATE", "DELETE")) for sql, _ in fixture.db.calls))
        self.assertTrue(all(connection.commits == 0 for connection in fixture.db.connections))


if __name__ == "__main__": unittest.main()
