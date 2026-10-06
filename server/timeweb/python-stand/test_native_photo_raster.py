"""Real Pillow child decoding; synthetic images only, no SQL/TCP/provider access."""
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import zlib

from PIL import Image, __version__
import native_photo_raster as raster
from private_media_s3 import PrivateMediaUnavailable
from runtime_profile_photo_uploads import PhotoUploadVerificationFailed


def original(format="JPEG", *, animated=False):
    output = io.BytesIO()
    with Image.new("RGB", (24, 16), (180, 120, 100)) as image:
        if animated:
            with Image.new("RGB", (24, 16), (100, 120, 180)) as second:
                image.save(output, format=format, save_all=True, append_images=[second], duration=100, loop=0)
        else:
            image.save(output, format=format)
    return output.getvalue()


def record(raw, mime="image/jpeg"):
    return {"key": "clrs-native-profile/" + "a" * 64, "size": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(), "content_type": mime}


def large_png_header(width, height):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\0" * 4)) + chunk(b"IEND", b"")


class RasterTests(unittest.TestCase):
    def setUp(self):
        self.port = raster.BoundedRasterVerifier(); self.cancel = threading.Event()

    def decode(self, raw, mime="image/jpeg"):
        with io.BytesIO(raw) as spool:
            return self.port.decode_verified(spool, record(raw, mime), deadline=time.monotonic() + 2, cancel=self.cancel)

    def test_actual_jpeg_png_webp_full_decode_and_same_port_record_evidence(self):
        self.assertEqual(__version__, "12.3.0")
        for format, mime in (("JPEG", "image/jpeg"), ("PNG", "image/png"), ("WEBP", "image/webp")):
            with self.subTest(format=format):
                raw = original(format); proof = self.decode(raw, mime)
                self.port.require_verified(proof, record(raw, mime))
                with self.assertRaises(PrivateMediaUnavailable):
                    raster.BoundedRasterVerifier().require_verified(proof, record(raw, mime))
                changed = record(raw, mime); changed["key"] = "clrs-native-profile/" + "b" * 64
                with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(proof, changed)
                with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(True, record(raw, mime))

    def test_truncated_nonimage_actual_mime_mismatch_and_animation_refuse(self):
        for raw, mime in ((original("JPEG")[:-4], "image/jpeg"), (original("PNG")[:-20], "image/png"),
                (original("WEBP")[:-8], "image/webp"), (b"not a raster but exact SHA and MIME header", "image/jpeg"),
                (original("PNG"), "image/jpeg"), (original("PNG", animated=True), "image/png"),
                (original("WEBP", animated=True), "image/webp")):
            with self.subTest(mime=mime, size=len(raw)):
                with self.assertRaises(PhotoUploadVerificationFailed): self.decode(raw, mime)

    def test_dimension_pixel_and_input_bounds_refuse_before_large_decode(self):
        for width, height in ((4097, 1), (1, 4097), (4001, 4000)):
            with self.subTest(width=width, height=height):
                with self.assertRaises(PhotoUploadVerificationFailed): self.decode(large_png_header(width, height), "image/png")
        raw = b"x" * (raster.MAX_BYTES + 1)
        with patch.object(raster.subprocess, "run") as run:
            with self.assertRaises(PrivateMediaUnavailable): self.decode(raw)
            run.assert_not_called()

    def test_actual_timeout_kills_reaps_child_and_releases_slot(self):
        raw = original()
        with tempfile.TemporaryDirectory(prefix="clrs-raster-test-") as directory:
            pid_path = Path(directory) / "pid"
            worker = Path(directory) / "slow.py"
            worker.write_text("import os,time\nfrom pathlib import Path\nPath(" + repr(str(pid_path))
                + ").write_text(str(os.getpid()))\ntime.sleep(20)\n")
            started = time.monotonic()
            with patch.object(raster, "_WORKER", worker):
                with io.BytesIO(raw) as spool:
                    with self.assertRaises(PrivateMediaUnavailable):
                        self.port.decode_verified(spool, record(raw), deadline=started + 0.35, cancel=self.cancel)
            self.assertLess(time.monotonic() - started, 1.2)
            self.assertTrue(pid_path.is_file(), "The real child must start before timing out")
            pid = int(pid_path.read_text())
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
        proof = self.decode(raw)  # Timed-out job released the sole slot.
        self.port.require_verified(proof, record(raw))

    def test_single_slot_bounded_stdout_cancel_and_expired_evidence(self):
        raw = original()
        self.assertTrue(raster._SLOT.acquire(blocking=False))
        try:
            with patch.object(raster.subprocess, "run") as run:
                with self.assertRaises(PrivateMediaUnavailable): self.decode(raw)
                run.assert_not_called()
        finally:
            raster._SLOT.release()
        with tempfile.TemporaryDirectory(prefix="clrs-raster-stdout-") as directory:
            worker = Path(directory) / "loud.py"
            worker.write_text("print('x'*600)\n")
            with patch.object(raster, "_WORKER", worker):
                with self.assertRaises(PrivateMediaUnavailable): self.decode(raw)
        self.cancel.set()
        with self.assertRaises(PrivateMediaUnavailable): self.decode(raw)
        self.cancel.clear(); proof = self.decode(raw)
        self.cancel.set()
        with self.assertRaises(PrivateMediaUnavailable): self.port.require_verified(proof, record(raw))
        now = 100.0; cancel = threading.Event(); port = raster.BoundedRasterVerifier(monotonic=lambda: now)
        with io.BytesIO(raw) as spool:
            proof = port.decode_verified(spool, record(raw), deadline=120, cancel=cancel)
        now = 116
        with self.assertRaises(PrivateMediaUnavailable): port.require_verified(proof, record(raw))


if __name__ == "__main__":
    unittest.main()
