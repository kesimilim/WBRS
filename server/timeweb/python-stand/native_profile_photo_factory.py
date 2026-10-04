"""Default-off native writer/own-reader factory; no app mount or automatic provider probes."""
from __future__ import annotations
import base64
import hashlib
import hmac
from pathlib import Path
import os
import tempfile
import threading
import time

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


class _ListCursor:
    """Normalize only the collection shape; every SQL field remains exact."""
    def __init__(self, cursor): self._cursor = cursor
    def fetchall(self): return list(self._cursor.fetchall())
    def __getattr__(self, name): return getattr(self._cursor, name)


class ImportedPhotoAppendContext:
    """Private factory hook. No HTTP argument can supply source authority."""
    def __init__(self, original_http): self._original = original_http

    def source(self, uid):
        from runtime_profile_photos_factory import _OwnedReader
        from runtime_profile_photos import RuntimeProfilePhotosService
        from runtime_versioned_profile_photos_factory import _Hybrid
        from runtime_profile_photo_delta_factory import _DeltaHybrid
        from runtime_versioned_profile_photos import _CAPS as versions, RuntimeVersionedProfilePhotosService
        from runtime_profile_photo_delta import RuntimeProfilePhotoDeltaService
        reader = self._original._reader()
        for _ in range(6):
            if type(reader) is _DeltaHybrid:
                if uid is not None and reader.versioned.has_target(uid): return reader.versioned
                reader = reader.legacy._reader()
            elif type(reader) is _Hybrid:
                if uid is not None and uid in versions[reader.versioned._snapshot]['profiles']: return reader.versioned
                reader = reader.legacy._reader()
            elif type(reader) is _Composite: reader = reader._legacy._reader()
            elif type(reader) is _OwnedReader: reader = reader._service
            elif type(reader) in (RuntimeProfilePhotosService, RuntimeVersionedProfilePhotosService, RuntimeProfilePhotoDeltaService): return reader
            else: raise RuntimeUnavailable()
        raise RuntimeUnavailable()

    def layout(self, cursor, execute, actor_uid, uid, *, write=False):
        from runtime_profile_photos import PHOTOS_SQL, RuntimeProfilePhotoNotFound
        from runtime_profile_photo_uploads import NATIVE_GALLERY_SQL, native_gallery, MAX_PHOTOS, _MID
        sql = PHOTOS_SQL.replace('FOR SHARE', 'FOR UPDATE') if write else PHOTOS_SQL
        execute(sql, (uid, uid)); associations = list(cursor.fetchall())
        if len(associations) > MAX_PHOTOS: raise RuntimeProfilePhotoNotFound()
        sql = NATIVE_GALLERY_SQL.replace('FOR SHARE OF p, m', 'FOR UPDATE OF p, m') if write else NATIVE_GALLERY_SQL
        execute(sql, (uid, uid)); joined = list(cursor.fetchall())
        if (len(joined) != len(associations) or any(len(a) != 5 or a[0] != uid or len(r) != 15
                or list(a[1:]) != list(r[:4]) for a, r in zip(associations, joined))): raise RuntimeProfilePhotoNotFound()
        native = []; old = []
        for row in joined:
            if type(row[0]) is not str: raise RuntimeProfilePhotoNotFound()
            if row[0].startswith('tw-profile-photo-'):
                if _MID.fullmatch(row[0]) is None: raise RuntimeProfilePhotoNotFound()
                native.append(row)
            else: old.append(row)
        # Execute the old reader's exact SQL with a fixed source-only association
        # projection. Its root/gallery/media/storage/HMAC proofs are unmodified.
        legacy_sql = PHOTOS_SQL.replace(' ORDER BY',
            " AND LEFT(CAST(media_id AS BINARY), 17) <> CAST('tw-profile-photo-' AS BINARY) ORDER BY")
        def source_execute(statement, params=()):
            return execute(legacy_sql if statement == PHOTOS_SQL else statement, params)
        proof = self.source(uid)._context(_ListCursor(cursor), source_execute, actor_uid, uid)
        if (not isinstance(proof.get('rows'), list) or not isinstance(proof.get('records'), list)
                or not 1 <= len(proof['rows']) <= MAX_PHOTOS or len(proof['rows']) != len(proof['records'])
                or any(len(row) != 3 or type(row[1]) is not int or row[1] != n or type(row[2]) is not int
                    or row[2] != int(n == 0) for n, row in enumerate(proof['rows']))): raise RuntimeProfilePhotoNotFound()
        # Original canonical associations may differ from a verified virtual
        # current version. The source reader proved that entire original set.
        if any(type(row[1]) is not int or row[1] >= len(proof['rows']) for row in old): raise RuntimeProfilePhotoNotFound()
        try: native = native_gallery(native, uid, ordinal_offset=len(proof['rows']))
        except Exception: raise RuntimeProfilePhotoNotFound() from None
        rows = proof['rows'] + [row[:3] for row in native]
        if len({row[0] for row in rows}) != len(rows): raise RuntimeProfilePhotoNotFound()
        return proof, native, rows, [list(row) for row in associations]

    def __call__(self, cursor, execute, uid, *, write=False):
        from runtime_profile_photo_uploads import PhotoUploadTargetRejected
        try: return self.layout(cursor, execute, uid, uid, write=write)[2]
        except RuntimeUnavailable: raise
        except Exception: raise PhotoUploadTargetRejected() from None


def _native_append_records(store, cursor, execute, uid, stamp, rows):
    # Same original prepare/commit proof as the native reader; actual ordinals
    # remain global (after the old prefix), never renumbered receipt fields.
    from native_credentials import unique_json
    from runtime_mutations import RECEIPT_QUERY, request_digest
    from runtime_native_profile_photos import COMMITS_SQL
    from runtime_profile_photo_uploads import (COMMIT_OPERATION, PREPARE_OPERATION,
        validate_commit, validate_commit_response, photo_record, _prepared, _uuid)
    if not rows: return [], []
    execute(COMMITS_SQL, (uid, uid, COMMIT_OPERATION)); commits = cursor.fetchall()
    if len(commits) > 20: raise RuntimeProfilePhotoNotFound()
    receipts = {}
    for row in commits:
        if len(row) != 7: raise RuntimeUnavailable()
        _uuid(row[0]); wrapper = row[4]
        if isinstance(wrapper, bytes): wrapper = wrapper.decode('utf-8', 'strict')
        if isinstance(wrapper, str): wrapper = unique_json(wrapper)
        if type(wrapper) is not dict or set(wrapper) != {'request', 'response'}: raise RuntimeUnavailable()
        request = validate_commit(wrapper['request'])
        status, checked, revision = store._receipt(row[1:], request_digest(request))
        if status != 200 or revision is not None or request['mediaId'] in receipts: raise RuntimeProfilePhotoNotFound()
        receipts[request['mediaId']] = (row[0], request, checked['response'])
    records = []; provenance = []
    for row in rows:
        operation_id, request, response = receipts.get(row[0], (None, None, None))
        if request is None: raise RuntimeProfilePhotoNotFound()
        fields, record = photo_record(uid, request, row[4:])
        execute(RECEIPT_QUERY + ' FOR SHARE', (uid, PREPARE_OPERATION, request['prepareOperationId']))
        original = cursor.fetchone()
        if original is None: raise RuntimeProfilePhotoNotFound()
        status, wrapper, revision = store._receipt(original, request_digest(fields))
        if status != 201 or revision is not None or wrapper != {'request': fields, 'response': _prepared(row[0], fields)}:
            raise RuntimeProfilePhotoNotFound()
        validate_commit_response(request, response, {'updatedAt': stamp}, row[:3])
        records.append(record); provenance.append([operation_id, request, response, wrapper])
    return records, provenance


class _AppendPrivateS3:
    def __init__(self, imported, native): self._imported = imported; self._native = native
    def get_verified_to_file(self, record, sink, **options):
        from runtime_profile_photo_uploads import PREFIX
        port = self._native if record['key'].startswith(PREFIX) else self._imported
        return port.get_verified_to_file(record, sink, **options)
    def require_private(self, record, *, deadline, cancel):
        from runtime_profile_photo_uploads import PREFIX
        if record['key'].startswith(PREFIX): return self._native.require_private(record, deadline=deadline, cancel=cancel)
        from private_media_s3 import _owner_acl
        self._imported._privacy(deadline, cancel)
        _owner_acl(self._imported._control('GetObjectAcl', record['key'], deadline, cancel), self._imported._owner)


class _AppendReader(RuntimeNativeProfilePhotosService):
    def __init__(self, store, cursor_key, *, source_context, uploads, private_s3, imported_s3, spool_directory,
            clock=time.time, monotonic=time.monotonic):
        super().__init__(store, cursor_key, uploads=uploads, private_s3=private_s3,
            spool_directory=spool_directory, clock=clock, monotonic=monotonic)
        self._source_context = source_context; self._native_port = private_s3
        self._s3 = _AppendPrivateS3(imported_s3, private_s3)

    def _check(self):
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
        try: self._native_port._proof()
        except Exception: raise RuntimeUnavailable() from None

    def _context(self, cursor, execute, actor_uid, target_uid):
        from datetime import datetime, timezone
        from runtime_profile_photos import _account, _rows, _target, ACTOR_SQL, _digest
        self._check()
        actor = _account(_rows(cursor, execute, ACTOR_SQL, (actor_uid, actor_uid)), actor_uid)
        _, raw, before = _target(cursor, execute, target_uid, actor, datetime.fromtimestamp(self._clock(), timezone.utc))
        if raw == {}:
            # Native-only proof implementation remains unchanged.
            return super()._context(cursor, execute, actor_uid, target_uid)
        proof, native, rows, associations = self._source_context.layout(cursor, execute, actor_uid, target_uid)
        stamp = self._uploads._profile(cursor, execute, target_uid)
        records, provenance = _native_append_records(self._store, cursor, execute, target_uid, stamp, native)
        _, _, after = _target(cursor, execute, target_uid, actor, datetime.fromtimestamp(self._clock(), timezone.utc))
        if before != after: raise RuntimeProfilePhotoNotFound()
        return {'actorHash': _digest(actor_uid), 'targetHash': _digest(target_uid),
            'contextHash': hashlib.sha256(canonical_json([proof['contextHash'], before, associations, native, provenance])).hexdigest(),
            'rows': rows, 'records': proof['records'] + records}


class _AppendOwned:
    def __init__(self, settings, original, source_context):
        self.original = original; self.context = source_context; self._settings = settings
        self._closed = False; self._lock = threading.Lock(); self._mixed = self._directory = None
        names = ('CLRS_RUNTIME_WRITES_ENABLED', 'CLRS_RUNTIME_MEMBERSHIP_AUTHORITY', 'CLRS_RUNTIME_PERMISSION_MODEL',
            'CLRS_RUNTIME_DB_URL', 'CLRS_RUNTIME_DB_CA_FILE', 'CLRS_NATIVE_SESSION_KEY_B64')
        self._store = RuntimeMutationStore.from_env({name: settings[name] for name in names if name in settings})
        if self._store is None: raise RuntimeUnavailable()

    def _select(self, identity, uid, access_token):
        from datetime import datetime, timezone
        from runtime_profile_photos import _account, _rows, _target, ACTOR_SQL, PHOTOS_SQL
        def select(cursor, execute, actor_uid):
            actor = _account(_rows(cursor, execute, ACTOR_SQL, (actor_uid, actor_uid)), actor_uid)
            _, raw, before = _target(cursor, execute, uid, actor, datetime.fromtimestamp(time.time(), timezone.utc))
            associations = _rows(cursor, execute, PHOTOS_SQL, (uid, uid))
            mixed = raw != {} and any(type(row[1]) is str and row[1].startswith('tw-profile-photo-') for row in associations)
            _, _, after = _target(cursor, execute, uid, actor, datetime.fromtimestamp(time.time(), timezone.utc))
            if before != after: raise RuntimeProfilePhotoNotFound()
            return {'mixed': mixed}
        if not self._store.read_authenticated(identity, select, access_token=access_token)['mixed']:
            return self.original._reader()  # Exact old behaviour, including >20 old photos and a closed writer.
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
            if self._mixed is None:
                port = create_native_photo_writer(self._settings)
                if port is None: raise RuntimeUnavailable()
                key = decode_base64(self._settings['CLRS_LEGACY_READ_CURSOR_KEY_B64'], max_bytes=32)
                session = decode_base64(self._settings['CLRS_NATIVE_SESSION_KEY_B64'], max_bytes=32)
                preview = decode_base64(self._settings['CLRS_PREVIEW_ACCESS_KEY_B64'], max_bytes=64)
                if len(key) != 32 or key == session or key == preview: raise RuntimeUnavailable()
                directory = tempfile.TemporaryDirectory(prefix='clrs-imported-append-photos-'); os.chmod(directory.name, 0o700)
                try:
                    uploads = RuntimeProfilePhotoUploadsService(self._store, imported_context=self.context)
                    self._mixed = _AppendReader(self._store, key, source_context=self.context, uploads=uploads, private_s3=port,
                        imported_s3=self.context.source(None)._s3, spool_directory=directory.name)
                    self._directory = directory
                except BaseException: directory.cleanup(); raise
            return self._mixed

    def photos(self, identity, uid, *, access_token, **options):
        return self._select(identity, uid, access_token).photos(identity, uid, access_token=access_token, **options)
    def open_photo(self, identity, uid, reference, *, access_token, **options):
        return self._select(identity, uid, access_token).open_photo(identity, uid, reference, access_token=access_token, **options)
    def close(self):
        with self._lock:
            if self._closed: return
            self._closed = True; mixed = self._mixed; directory = self._directory
        try:
            if mixed is not None: mixed.close()
        finally:
            try: self._store.close()
            finally:
                if directory is not None: directory.cleanup()
                self.original.close()


def create_append_profile_photos_http(env, original):
    if env.get(GATE) != '1' or env.get('CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED') != '1': return original
    from runtime_versioned_profile_photos_factory import _OwnedHttp
    context = ImportedPhotoAppendContext(original); settings = dict(env)
    http = _OwnedHttp(settings, original, lambda: _AppendOwned(settings, original, context))
    http.imported_append_context = context
    return http
