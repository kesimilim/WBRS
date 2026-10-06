"""Default-off native writer/own-reader factory; no app mount or automatic provider probes."""
from __future__ import annotations
import base64
import hashlib
import hmac
from pathlib import Path
import os
import tempfile
import threading

from native_credentials import decode_base64
from native_photo_upload_s3 import NativePhotoUploadS3, ENDPOINT
from native_photo_raster import BoundedRasterVerifier
from private_media_s3 import TimewebPrivateBucketState
from runtime_mutations import RuntimeMutationStore, RuntimeUnavailable, canonical_json
from runtime_profile_photo_uploads import RuntimeProfilePhotoUploadsService
from runtime_native_profile_photos import RuntimeNativeProfilePhotosService, profile_photo_branch
from runtime_profile_photos import RuntimeProfilePhotoNotFound
from runtime_profile_photos_http import RuntimeProfilePhotosHttp

GATE = 'CLRS_RUNTIME_NATIVE_PHOTO_UPLOADS_ENABLED'
_SOURCE = ('native_profile_photo_factory.py', 'runtime_native_profile_photos.py',
    'native_photo_upload_s3.py', 'runtime_profile_photo_uploads.py', 'runtime_mutations.py',
    'runtime_profile_photo_uploads_http.py', 'native_photo_raster.py',
    'native_photo_raster_worker.py', 'runtime_http.py', 'app.py')


def _binding(settings):
    directory = Path(__file__).parent
    sources = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in _SOURCE}
    source = hashlib.sha256(canonical_json(sources)).hexdigest()
    requirements = hashlib.sha256((directory / 'requirements.txt').read_bytes()).hexdigest()
    config = {name: settings.get(name) for name in ('CLRS_LEGACY_MEDIA_TARGET_BUCKET',
        'CLRS_LEGACY_MEDIA_EXPECTED_OWNER', 'CLRS_LEGACY_MEDIA_S3_REGION',
        'CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID', 'CLRS_NATIVE_PHOTO_WRITER_ACCESS_KEY')}
    secret = settings.get('CLRS_NATIVE_PHOTO_WRITER_SECRET_KEY', '')
    config['writerSecretSha256'] = hashlib.sha256(secret.encode()).hexdigest()
    return {'sourceSha256': source, 'buildSha256': hashlib.sha256(canonical_json([sources, requirements])).hexdigest(),
        'configSha256': hashlib.sha256(canonical_json(config)).hexdigest()}


def create_native_photo_writer(env):
    if env.get(GATE) != '1': return None
    try:
        settings = dict(env); mode = settings.get('CLRS_NATIVE_PHOTO_PROOF_MODE', 'release')
        def load():
            raw = decode_base64(settings.get('CLRS_NATIVE_PHOTO_PROVIDER_PROOF_B64'), max_bytes=4096)
            mac = settings.get('CLRS_NATIVE_PHOTO_PROVIDER_PROOF_HMAC_HEX')
            if mode == 'pilot': return raw, mac
            return (decode_base64(settings.get('CLRS_NATIVE_PHOTO_RELEASE_ACK_B64'), max_bytes=4096),
                settings.get('CLRS_NATIVE_PHOTO_RELEASE_HMAC_HEX'), raw, mac)
        state = TimewebPrivateBucketState(int(settings['CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID']),
            settings['CLRS_LEGACY_MEDIA_TARGET_BUCKET'], settings['CLRS_LEGACY_MEDIA_CONTROL_TOKEN'])
        port = NativePhotoUploadS3(ENDPOINT, settings['CLRS_LEGACY_MEDIA_S3_REGION'],
            settings['CLRS_LEGACY_MEDIA_TARGET_BUCKET'], settings['CLRS_LEGACY_MEDIA_EXPECTED_OWNER'],
            settings['CLRS_NATIVE_PHOTO_WRITER_ACCESS_KEY'], settings['CLRS_NATIVE_PHOTO_WRITER_SECRET_KEY'],
            bucket_state=state, provider_proof=load, proof_key=decode_base64(settings.get('CLRS_PREVIEW_ACCESS_KEY_B64'), max_bytes=64),
            image_verifier=BoundedRasterVerifier(), proof_mode=mode, release_binding=lambda: _binding(settings))
        port._proof()  # Authenticated operator witness only; local, zero HTTPS.
        return port
    except Exception:
        return None


class _Composite:
    def __init__(self, settings, legacy):
        self._env = settings; self._legacy = legacy; self._native = self._directory = None
        names = ('CLRS_RUNTIME_WRITES_ENABLED', 'CLRS_RUNTIME_MEMBERSHIP_AUTHORITY',
            'CLRS_RUNTIME_PERMISSION_MODEL', 'CLRS_RUNTIME_DB_URL', 'CLRS_RUNTIME_DB_CA_FILE', 'CLRS_NATIVE_SESSION_KEY_B64')
        self._store = RuntimeMutationStore.from_env({name: settings[name] for name in names if name in settings})
        if self._store is None: raise RuntimeUnavailable()
        self._closed = False; self._lock = threading.Lock()

    def _reader(self, identity, target_uid, access_token):
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
        branch = profile_photo_branch(self._store, identity, target_uid, access_token=access_token)
        if branch == 'legacy':
            if not self._legacy._enabled: raise RuntimeProfilePhotoNotFound()
            return self._legacy._reader()
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
            if self._native is None:
                port = create_native_photo_writer(self._env)
                if port is None: raise RuntimeUnavailable()
                cursor = decode_base64(self._env.get('CLRS_LEGACY_READ_CURSOR_KEY_B64'), max_bytes=32)
                session = decode_base64(self._env.get('CLRS_NATIVE_SESSION_KEY_B64'), max_bytes=32)
                proof = decode_base64(self._env.get('CLRS_PREVIEW_ACCESS_KEY_B64'), max_bytes=64)
                if len(cursor) != 32 or hmac.compare_digest(cursor, session) or hmac.compare_digest(cursor, proof): raise RuntimeUnavailable()
                directory = tempfile.TemporaryDirectory(prefix='clrs-own-native-photos-'); os.chmod(directory.name, 0o700)
                try:
                    self._native = RuntimeNativeProfilePhotosService(self._store, cursor,
                        uploads=RuntimeProfilePhotoUploadsService(self._store), private_s3=port, spool_directory=directory.name)
                    self._directory = directory
                except BaseException: directory.cleanup(); raise
            return self._native

    def photos(self, identity, target_uid, *, access_token, **options):
        return self._reader(identity, target_uid, access_token).photos(identity, target_uid, access_token=access_token, **options)

    def open_photo(self, identity, target_uid, *, access_token, **options):
        return self._reader(identity, target_uid, access_token).open_photo(identity, target_uid, access_token=access_token, **options)

    def close(self):
        with self._lock:
            if self._closed: return
            self._closed = True; native = self._native; directory = self._directory
        try:
            if native is not None: native.close()
        finally:
            try: self._store.close()
            finally:
                try:
                    if directory is not None: directory.cleanup()
                finally: self._legacy.close()


def create_native_profile_photos_http(env, legacy_http):
    if env.get(GATE) != '1': return legacy_http
    settings = dict(env)
    return RuntimeProfilePhotosHttp(env, service_factory=lambda: _Composite(settings, legacy_http))
