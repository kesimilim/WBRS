"""Independent incremental-source wrapper; original seven-profile port is unchanged."""
import os
import tempfile
from native_credentials import decode_base64
from media_promotion_acknowledgement import verify_media_promotion_acknowledgement
from private_media_s3 import PrivateMediaS3, SigV4HTTPSReadTransport, TimewebPrivateBucketState
from runtime_mutations import RuntimeMutationStore, RuntimeUnavailable
from runtime_native_profile_photos import RuntimeNativeProfilePhotosService
from runtime_versioned_profile_photos_factory import _Hybrid, _OwnedHttp
from runtime_profile_photo_delta import RuntimeProfilePhotoDeltaService, _CAPS, require_separate_keys


class _DeltaHybrid(_Hybrid):
    def _select(self, identity, target_uid, access_token):
        with self.lock:
            if self.closed: raise RuntimeUnavailable()
        if self.versioned.contains(identity,target_uid,access_token=access_token): return self.versioned
        reader=self.legacy._reader()
        if self.versioned.has_target(target_uid):
            # Resolve the existing old-version/native composite. No fallback to
            # imported media if a replacement lacks committed native provenance.
            for _ in range(3):
                if type(reader) is RuntimeNativeProfilePhotosService: return reader
                if callable(getattr(reader,'_select',None)): reader=reader._select(identity,target_uid,access_token)
                elif callable(getattr(reader,'_reader',None)): reader=reader._reader(identity,target_uid,access_token)
                else: raise RuntimeUnavailable()
            if type(reader) is not RuntimeNativeProfilePhotosService: raise RuntimeUnavailable()
        return reader


def create_delta_profile_photos_http(env, legacy_http, *, snapshot=None):
    if snapshot is None: return legacy_http
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
            session=decode_base64(settings['CLRS_NATIVE_SESSION_KEY_B64'])
            review=decode_base64(settings['CLRS_PREVIEW_ACCESS_KEY_B64'])
            require_separate_keys(snapshot,key,session,review)
            if len(key)!=32 or key==session or key==review: raise RuntimeUnavailable()
            bucket=settings['CLRS_LEGACY_MEDIA_TARGET_BUCKET']; owner=settings['CLRS_LEGACY_MEDIA_EXPECTED_OWNER']
            s3=PrivateMediaS3(bucket,owner,SigV4HTTPSReadTransport('https://s3.twcstorage.ru/',
                settings['CLRS_LEGACY_MEDIA_S3_REGION'],settings['CLRS_LEGACY_MEDIA_S3_ACCESS_KEY'],
                settings['CLRS_LEGACY_MEDIA_S3_SECRET_KEY']),TimewebPrivateBucketState(
                    int(settings['CLRS_LEGACY_MEDIA_CONTROL_BUCKET_ID']),bucket,settings['CLRS_LEGACY_MEDIA_CONTROL_TOKEN']))
            directory=tempfile.TemporaryDirectory(prefix='clrs-source-photo-delta-'); os.chmod(directory.name,0o700)
            promotion=verify_media_promotion_acknowledgement(settings,separate_from=(key,session))
            service=RuntimeProfilePhotoDeltaService(store,key,private_s3=s3,snapshot=snapshot,
                spool_directory=directory.name,media_promotion=promotion)
            return _DeltaHybrid(service,legacy_http,store,directory)
        except Exception:
            if service is not None: service.close()
            if store is not None: store.close()
            if directory is not None: directory.cleanup()
            raise RuntimeUnavailable() from None
    return _OwnedHttp(settings,legacy_http,create)
