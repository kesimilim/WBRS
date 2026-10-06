"""Fixed isolated child: bounded full raster decode, JSON metadata only on stdout."""
import hashlib
import io
import json
import sys
import warnings

MAX_BYTES = 5 * 1024 * 1024
MAX_DIMENSION = 4096
MAX_PIXELS = 16_000_000
FORMATS = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}


def decode():
    if sys.platform.startswith("linux"):
        import resource
        resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024, 256 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
        resource.setrlimit(resource.RLIMIT_FSIZE, (512, 512))
        resource.setrlimit(resource.RLIMIT_NOFILE, (32, 32))
    from PIL import Image, ImageFile, __version__
    if __version__ != "12.3.0":
        return {"status": "unavailable"}
    if len(sys.argv) != 4:
        return {"status": "unavailable"}
    mime, expected_size, expected_sha = sys.argv[1:]
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if not 1 <= len(raw) <= MAX_BYTES or len(raw) != int(expected_size) or hashlib.sha256(raw).hexdigest() != expected_sha:
        return {"status": "invalid"}
    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    ImageFile.LOAD_TRUNCATED_IMAGES = False
    warnings.simplefilter("error", Image.DecompressionBombWarning)
    try:
        with Image.open(io.BytesIO(raw), formats=tuple(FORMATS)) as image:
            width, height = image.size
            if (image.format not in FORMATS or FORMATS[image.format] != mime
                    or not 1 <= width <= MAX_DIMENSION or not 1 <= height <= MAX_DIMENSION
                    or width * height > MAX_PIXELS or getattr(image, "is_animated", False)
                    or getattr(image, "n_frames", 1) != 1):
                return {"status": "invalid"}
            image.verify()
        with Image.open(io.BytesIO(raw), formats=tuple(FORMATS)) as image:
            if image.size != (width, height) or FORMATS.get(image.format) != mime:
                return {"status": "invalid"}
            image.load()  # Force complete pixel decoding; MIME/header sniffing never yields ready.
        return {"status": "ok", "mime": mime, "size": len(raw), "sha256": expected_sha,
            "width": width, "height": height}
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError, Image.DecompressionBombWarning):
        return {"status": "invalid"}


if __name__ == "__main__":
    try:
        result = decode()
    except Exception:
        result = {"status": "unavailable"}
    output = json.dumps(result, separators=(",", ":")).encode("ascii")
    sys.stdout.buffer.write(output if len(output) <= 512 else b'{"status":"unavailable"}')
