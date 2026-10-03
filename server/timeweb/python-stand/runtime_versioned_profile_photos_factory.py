"""Optional genuine captured-version port. No env flag manufactures its capability."""
import os
import tempfile
import threading
from native_credentials import decode_base64
from media_promotion_acknowledgement import verify_media_promotion_acknowledgement
from private_media_s3 import PrivateMediaS3, SigV4HTTPSReadTransport, TimewebPrivateBucketState
from runtime_mutations import RuntimeMutationStore, RuntimeUnavailable
from runtime_profile_photos_http import RuntimeProfilePhotosHttp
from runtime_native_profile_photos import RuntimeNativeProfilePhotosService
from runtime_versioned_profile_photos import RuntimeVersionedProfilePhotosService, _CAPS


class _Hybrid:
    def __init__(self, versioned, legacy_http, store, directory):
        self.versioned=versioned; self.legacy=legacy_http; self.store=store; self.directory=directory
        self.lock=threading.Lock(); self.closed=False

    def _select(self, identity, target_uid, access_token):
        with self.lock:
            if self.closed: raise RuntimeUnavailable()
        # Any invalid/stale cohort member refuses. Never fall back to the old avatar.
        if self.versioned.contains(identity,target_uid,access_token=access_token): return self.versioned
        reader=self.legacy._reader()
        if target_uid in _CAPS[self.versioned._snapshot]['profiles']:
            # A real native replacement must pass the ordinary current branch and
            # committed prepare/commit provenance reader; no imported fallback.
            reader=reader._reader(identity,target_uid,access_token)
            if not isinstance(reader,RuntimeNativeProfilePhotosService): raise RuntimeUnavailable()
        return reader

    def photos(self, identity, target_uid, *, access_token, **kwargs):
        return self._select(identity,target_uid,access_token).photos(identity,target_uid,access_token=access_token,**kwargs)

    def open_photo(self, identity, target_uid, reference, *, access_token, **kwargs):
        return self._select(identity,target_uid,access_token).open_photo(identity,target_uid,reference=reference,access_token=access_token,**kwargs)

    def close(self):
        with self.lock:
            if self.closed: return
            self.closed=True
        try: self.versioned.close()
        finally:
            try: self.store.close()
            finally:
                try: self.directory.cleanup()
                finally: self.legacy.close()


class _OwnedHttp(RuntimeProfilePhotosHttp):
    def __init__(self, env, legacy, factory):
        super().__init__(env,service_factory=factory); self._legacy=legacy

    def close(self):
        try: super().close()
        finally: self._legacy.close()


def create_versioned_profile_photos_http(env, legacy_http, *, snapshot=None):
    if snapshot is None: return legacy_http  # Exact identity/default behaviour.
    if snapshot not in _CAPS: raise RuntimeUnavailable()
    if env.get('CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED') != '1': return legacy_http
    settings=dict(env)
    def create():
        store=directory=service=None
        try:
            names=('CLRS_RUNTIME_WRITES_ENABLED','CLRS_RUNTIME_MEMBERSHIP_AUTHORITY',
                'CLRS_RUNTIME_PERMISSION_MODEL','CLRS_RUNTIME_DB_URL','CLRS_RUNTIME_DB_CA_FILE','CLRS_NATIVE_SESSION_KEY_B64')
            store=RuntimeMutationStore.from_env({name:settings[name] for name in names if name in settings})
            if store is None: raise RuntimeUnavailable()
            key=decode_base64(settings['CLRS_LEGACY_READ_CURSOR_KEY_B64'])
            if len(key)!=32 or key==decode_base64(settings['CLRS_NATIVE_SESSION_KEY_B64']): raise RuntimeUnavailable()
            bucket=settings['CLRS_LEGACY_MEDIA_TARGET_BUCKET']; owner=settings['CLRS_LEGACY_MEDIA_EXPECTED_OWNER']
            s3=PrivateMediaS3(bucket,owner,SigV4HTTPSReadTransport('https://s3.twcstorage.ru/',
                settings['CLRS_LEGACY_MEDIA_S3_REGION'],settings['CLRS_LEGACY_MEDIA_S3_ACCESS_KEY'],
                settings['CLRS_LEGACY_MEDIA_S3_SECRET_KEY']),TimewebPrivateBucketState(
                    int(settings['CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID']),bucket,settings['CLRS_LEGACY_MEDIA_CONTROL_TOKEN']))
            directory=tempfile.TemporaryDirectory(prefix='clrs-versioned-profile-photos-'); os.chmod(directory.name,0o700)
            promotion=verify_media_promotion_acknowledgement(settings,separate_from=(key,decode_base64(settings['CLRS_NATIVE_SESSION_KEY_B64'])))
            service=RuntimeVersionedProfilePhotosService(store,key,private_s3=s3,snapshot=snapshot,spool_directory=directory.name,media_promotion=promotion)
            return _Hybrid(service,legacy_http,store,directory)
        except Exception:
            if service is not None: service.close()
            if store is not None: store.close()
            if directory is not None: directory.cleanup()
            raise RuntimeUnavailable() from None
    return _OwnedHttp(settings,legacy_http,create)
