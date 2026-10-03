"""Operator-reviewed incremental source originals. Never a global/final generation."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import hmac
import re
import threading
import time
import weakref

from native_credentials import unique_json
from legacy_conversation_payload import OpaqueReferences, document, payload_digest
from media_promotion_acknowledgement import VerifiedMediaPromotion
from private_media_s3 import PrivateMediaS3
from profile_photo_review import _identifier, _sha
from runtime_mutations import RuntimeUnavailable, canonical_json
from runtime_profile_photo_uploads import NATIVE_GALLERY_SQL, native_gallery
from runtime_profile_photos import (ACTOR_SQL, SOURCE_SQL, ROOT_SQL, GALLERY_SQL,
    RuntimeProfilePhotoNotFound, _account, _rows, _target, _associations,
    _source_document, _digest, _hash, MAX_IMAGE_BYTES)
from runtime_versioned_profile_photos import (RuntimeVersionedProfilePhotosService, SOURCE, POLICY,
    source_slots, source_fingerprint as captured_guard_fingerprint)

DOMAIN = b'clrs-source-profile-photo-delta-readback-v1\0'
MAX_PACK_BYTES = 65536
_CAPS = weakref.WeakKeyDictionary()
_FIELDS = {'kind', 'source', 'policy', 'sourceFingerprint', 'evidence', 'profiles',
    'targetBucket', 'expectedOwner', 'legacyPromotionCipherSha256',
    'freshSqlReadbackVerified', 'fullPrivateObjectReadbackVerified',
    'sourceBarrierVerified', 'globallyConsistentFinalCapture', 'finalAuthority'}


class VerifiedProfilePhotoDelta:
    pass


def source_fingerprint():
    local = Path(__file__).parent
    paths = [local/'runtime_profile_photo_delta.py', local/'runtime_profile_photo_delta_factory.py']
    return hashlib.sha256(canonical_json({'deltaSources': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in paths}, 'capturedGuardFingerprint': captured_guard_fingerprint()})).hexdigest()


def _bundle(uid, value):
    _identifier(uid)
    if (type(value) is not dict or set(value) != {'root', 'rootSha256', 'gallery', 'photos'}
            or type(value['gallery']) is not list or type(value['photos']) is not list): raise ValueError()
    root = document(value['root'])
    if payload_digest(root) != _sha(value['rootSha256']): raise ValueError()
    slots = source_slots(uid, root, value['gallery'])
    if not 1 <= len(slots) <= 20 or len(slots) != len(value['photos']): raise ValueError()
    records = []
    for slot, photo in zip(slots, value['photos']):
        if (type(photo) is not dict or set(photo) != {'path', 'imageId', 'record', 'sourceMetadata'}
                or [photo['path'], photo['imageId']] != slot): raise ValueError()
        metadata = photo['sourceMetadata']; record = photo['record']
        if (type(metadata) is not dict or metadata.get('bucket') != SOURCE['bucket']
                or metadata.get('name') != photo['path']
                or type(metadata.get('generation')) is not str
                or re.fullmatch(r'[1-9][0-9]{0,30}', metadata['generation']) is None
                or type(record) is not dict or set(record) != {'key', 'size', 'sha256', 'content_type'}
                or type(record['size']) is not int or not 0 < record['size'] <= MAX_IMAGE_BYTES
                or type(metadata.get('size')) is not str or metadata['size'] != str(record['size'])
                or record['content_type'] not in {'image/jpeg', 'image/png', 'image/webp', 'image/gif'}
                or metadata.get('contentType') != record['content_type']): raise ValueError()
        _sha(record['sha256'])
        expected = 'clrs-import-quarantine/' + hashlib.sha256(canonical_json(
            ['clrs-final-storage-delta-v1', SOURCE['project'], SOURCE['bucket'],
             photo['path'], metadata['generation'], record['sha256']])).hexdigest()
        if record['key'] != expected: raise ValueError()
        records.append(record)
    return root, slots, records


def verify_profile_photo_delta(raw, key, *, separate_from):
    """HMAC authenticates actual reviewed readback; no env bool issues a capability."""
    try:
        if (type(raw) is not bytes or not 1 <= len(raw) <= MAX_PACK_BYTES
                or type(key) is not bytes or len(key) != 32
                or type(separate_from) is not tuple or len(separate_from) < 3
                or any(type(other) is not bytes or len(other) < 32 or hmac.compare_digest(key, other)
                    for other in separate_from)): raise ValueError()
        envelope = unique_json(raw.decode('utf-8', 'strict'))
        if type(envelope) is not dict or set(envelope) != {'body', 'hmacSha256'}: raise ValueError()
        body = envelope['body']
        if type(body) is not dict or set(body) != _FIELDS: raise ValueError()
        if not hmac.compare_digest(_sha(envelope['hmacSha256']),
                hmac.digest(key, DOMAIN + canonical_json(body, max_bytes=MAX_PACK_BYTES), 'sha256').hex()): raise ValueError()
        if (body['kind'] != 'clrs-source-profile-photo-delta-readback-v1'
                or body['source'] != SOURCE or body['policy'] != POLICY
                or body['sourceFingerprint'] != source_fingerprint()
                or body['freshSqlReadbackVerified'] is not True
                or body['fullPrivateObjectReadbackVerified'] is not True
                or body['sourceBarrierVerified'] is not False
                or body['globallyConsistentFinalCapture'] is not False or body['finalAuthority'] is not False
                or type(body['profiles']) is not dict or not 1 <= len(body['profiles']) <= 20
                or type(body['evidence']) is not dict or set(body['evidence']) !=
                    {'sourceCaptureCipherSha256', 'targetPlanSha256', 'sqlReadbackCipherSha256', 'objectReadbackCipherSha256'}
                or type(body['targetBucket']) is not str or not body['targetBucket']
                or type(body['expectedOwner']) is not str or not body['expectedOwner']): raise ValueError()
        for digest in body['evidence'].values(): _sha(digest)
        _sha(body['legacyPromotionCipherSha256'])
        for uid, bundle in body['profiles'].items(): _bundle(uid, bundle)
        result = VerifiedProfilePhotoDelta()
        _CAPS[result] = (body, hashlib.sha256(key).digest())
        return result
    except Exception: raise RuntimeUnavailable() from None


def require_separate_keys(snapshot, *keys):
    if snapshot not in _CAPS: raise RuntimeUnavailable()
    if any(type(key) is not bytes or len(key) < 32
            or hmac.compare_digest(_CAPS[snapshot][1], hashlib.sha256(key).digest()) for key in keys):
        raise RuntimeUnavailable()


class RuntimeProfilePhotoDeltaService(RuntimeVersionedProfilePhotosService):
    def __init__(self, store, cursor_key, *, private_s3, snapshot, spool_directory,
            media_promotion, clock=time.time, monotonic=time.monotonic):
        if snapshot not in _CAPS: raise RuntimeUnavailable()
        body = _CAPS[snapshot][0]; require_separate_keys(snapshot, cursor_key)
        if (not callable(getattr(store, 'read_authenticated', None)) or type(cursor_key) is not bytes or len(cursor_key) != 32
                or type(private_s3) is not PrivateMediaS3 or private_s3._bucket != body['targetBucket']
                or private_s3._owner != body['expectedOwner'] or type(media_promotion) is not VerifiedMediaPromotion
                or media_promotion.ciphertext_sha256 != body['legacyPromotionCipherSha256']): raise RuntimeUnavailable()
        self._store=store; self._s3=private_s3; self._snapshot=snapshot; self._directory=spool_directory
        self._clock=clock; self._monotonic=monotonic; self._promotion=media_promotion
        self._codec=OpaqueReferences(hmac.digest(cursor_key,b'clrs-source-profile-photo-delta-reference-v1\0','sha256'))
        self._slots=threading.BoundedSemaphore(2); self._lock=threading.Lock()
        self._inflight=set(); self._leases=set(); self._closed=False

    def _check(self):
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
        self._promotion.require_current(self._clock())
        if self._snapshot not in _CAPS or _CAPS[self._snapshot][0]['sourceFingerprint'] != source_fingerprint():
            raise RuntimeUnavailable()

    def has_target(self, uid):
        self._check()
        return uid in _CAPS[self._snapshot][0]['profiles']

    def contains(self, identity, uid, *, access_token):
        if not self.has_target(uid): return False
        def select(cursor, execute, actor_uid):
            actor = _account(_rows(cursor,execute,ACTOR_SQL,(actor_uid,actor_uid)),actor_uid)
            _,raw,before = _target(cursor,execute,uid,actor,datetime.fromtimestamp(self._clock(),timezone.utc))
            self._captured(cursor,execute,uid,raw,_CAPS[self._snapshot][0]['profiles'][uid])
            rows = _rows(cursor,execute,NATIVE_GALLERY_SQL,(uid,uid))
            if rows:
                try: native_gallery(rows,uid)
                except Exception: raise RuntimeProfilePhotoNotFound() from None
            _,_,after = _target(cursor,execute,uid,actor,datetime.fromtimestamp(self._clock(),timezone.utc))
            if before != after: raise RuntimeProfilePhotoNotFound()
            return {'native':bool(rows)}
        if self._store.read_authenticated(identity,select,access_token=access_token)['native']: return False
        self._proof(identity,access_token,uid)
        return True

    def _captured(self, cursor, execute, target_uid, raw, bundle):
        root,slots,records = _bundle(target_uid,bundle)
        if document(raw) != root: raise RuntimeProfilePhotoNotFound()
        if _rows(cursor,execute,SOURCE_SQL) != [(SOURCE['project'],SOURCE['database'],SOURCE['bucket'])]: raise RuntimeProfilePhotoNotFound()
        path='users/'+target_uid
        roots=_rows(cursor,execute,ROOT_SQL,(_hash(path),path))
        if len(roots)!=1: raise RuntimeProfilePhotoNotFound()
        stored=_source_document(roots[0],'users')
        if stored.encoded_payload != root or stored.payload_sha256 != bundle['rootSha256']: raise RuntimeProfilePhotoNotFound()
        path+='/images'; gallery=_rows(cursor,execute,GALLERY_SQL,(_hash(path),path))
        actual=[]
        for row in gallery:
            doc=_source_document(row,path)
            actual.append({'id':doc.firebase_path.rsplit('/',1)[-1],'payload':doc.encoded_payload,'sha256':doc.payload_sha256})
        if actual != bundle['gallery']: raise RuntimeProfilePhotoNotFound()
        return records

    def _context(self, cursor, execute, actor_uid, target_uid):
        self._check(); bundle = _CAPS[self._snapshot][0]['profiles'].get(target_uid)
        if bundle is None: raise RuntimeProfilePhotoNotFound()
        actor = _account(_rows(cursor,execute,ACTOR_SQL,(actor_uid,actor_uid)),actor_uid)
        _,raw,before = _target(cursor,execute,target_uid,actor,datetime.fromtimestamp(self._clock(),timezone.utc))
        records = self._captured(cursor,execute,target_uid,raw,bundle)
        if _associations(cursor,execute,target_uid): raise RuntimeProfilePhotoNotFound()
        _,_,after=_target(cursor,execute,target_uid,actor,datetime.fromtimestamp(self._clock(),timezone.utc))
        if after!=before or _associations(cursor,execute,target_uid): raise RuntimeProfilePhotoNotFound()
        self._check()
        rows=[['delta-media-'+record['key'].rsplit('/',1)[-1],ordinal,int(ordinal==0)]
            for ordinal,record in enumerate(records)]
        return {'actorHash':_digest(actor_uid),'targetHash':_digest(target_uid),
            'contextHash':hashlib.sha256(canonical_json([bundle,before])).hexdigest(),'rows':rows,'records':records}
