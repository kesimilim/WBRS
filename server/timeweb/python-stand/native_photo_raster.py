"""One-slot, <=2s child decoder port. No network, user paths or credential loading."""
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import weakref

from private_media_s3 import PrivateMediaUnavailable, _json_pairs
from runtime_profile_photo_uploads import PhotoUploadVerificationFailed

MAX_BYTES = 5 * 1024 * 1024
_SLOT = threading.BoundedSemaphore(1)
_WORKER = Path(__file__).with_name("native_photo_raster_worker.py")


class _ImageEvidence:
    __slots__ = ("__weakref__",)


def _bound(record):
    # Share the frozen upload adapter's exact record and native-key validator.
    from native_photo_upload_s3 import _record
    return _record(record)


class BoundedRasterVerifier:
    def __init__(self, *, monotonic=time.monotonic):
        self._clock = monotonic; self._evidence = weakref.WeakKeyDictionary(); self._lock = threading.Lock()

    def _check(self, deadline, cancel):
        if (type(deadline) not in {int, float} or not math.isfinite(deadline)
                or not callable(getattr(cancel, "is_set", None)) or cancel.is_set() or self._clock() >= deadline):
            raise PrivateMediaUnavailable()

    def decode_verified(self, spool, record, *, deadline, cancel):
        bound = _bound(record); _, size, sha, mime = bound; self._check(deadline, cancel)
        if not _SLOT.acquire(blocking=False):
            raise PrivateMediaUnavailable()
        try:
            if not callable(getattr(spool, "read", None)) or spool.tell() != 0:
                raise PrivateMediaUnavailable()
            raw = spool.read(size + 1)
            if type(raw) is not bytes or len(raw) != size:
                raise PhotoUploadVerificationFailed()
            self._check(deadline, cancel)
            timeout = min(2, deadline - self._clock())
            env = {"PATH": os.defpath}
            if sys.platform == "win32" and "SystemRoot" in os.environ:
                env["SystemRoot"] = os.environ["SystemRoot"]
            with tempfile.TemporaryFile(mode="w+b") as output:
                # run() kills and reaps its child on TimeoutExpired; no thread/Future timeout.
                result = subprocess.run([sys.executable, "-I", "-B", str(_WORKER), mime, str(size), sha],
                    input=raw, stdout=output, stderr=subprocess.DEVNULL, timeout=timeout, check=False, env=env)
                output.seek(0); encoded = output.read(513)
            self._check(deadline, cancel)
            if result.returncode != 0 or not 1 <= len(encoded) <= 512:
                raise PrivateMediaUnavailable()
            value = json.loads(encoded, object_pairs_hook=_json_pairs)
            if value == {"status": "invalid"}:
                raise PhotoUploadVerificationFailed()
            if (not isinstance(value, dict) or set(value) != {"status", "mime", "size", "sha256", "width", "height"}
                    or value["status"] != "ok" or value["mime"] != mime or value["size"] != size or value["sha256"] != sha
                    or type(value["width"]) is not int or type(value["height"]) is not int
                    or not 1 <= value["width"] <= 4096 or not 1 <= value["height"] <= 4096
                    or value["width"] * value["height"] > 16_000_000):
                raise PrivateMediaUnavailable()
            evidence = _ImageEvidence()
            with self._lock:
                self._evidence[evidence] = (bound, self._clock(), deadline, cancel)
            return evidence
        except PhotoUploadVerificationFailed:
            raise PhotoUploadVerificationFailed() from None
        except Exception:
            raise PrivateMediaUnavailable() from None
        finally:
            _SLOT.release()

    def require_verified(self, evidence, record):
        bound = _bound(record)
        with self._lock:
            value = self._evidence.get(evidence) if type(evidence) is _ImageEvidence else None
        if value is None:
            raise PrivateMediaUnavailable()
        expected, issued, deadline, cancel = value
        self._check(deadline, cancel)
        if bound != expected or not 0 <= self._clock() - issued <= 15:
            raise PrivateMediaUnavailable()
