"""Reviewed captured-delta photo versions; retained imports and native reader untouched.

A captured staging cohort is not a Firebase write barrier or public cutover.
An authenticated operator readback receipt is mandatory; an env flag cannot issue it.
"""
from __future__ import annotations
import hashlib
import hmac
import threading
import time
import weakref
import re
from urllib.parse import urlsplit, parse_qsl
from datetime import datetime, timezone

from legacy_conversation_payload import OpaqueReferences, document, payload_digest
from native_credentials import unique_json
from private_media_s3 import PrivateMediaS3
from profile_photo_review import (_typed_string, _storage_path, _identifier, _sha,
    SourcePhotoDocument, ReadyPhotoEvidence, _ready, _copied)
from media_promotion_acknowledgement import VerifiedMediaPromotion
from legacy_private_media import target_key, _metadata
from runtime_mutations import RuntimeUnavailable, canonical_json
from runtime_profile_photo_uploads import NATIVE_GALLERY_SQL, native_gallery
from runtime_profile_photos import (RuntimeProfilePhotosService, RuntimeProfilePhotoNotFound,
    ACTOR_SQL, _account, _rows, _target, _associations, _digest, _hash,
    media_sql, storage_sql, _MEDIA_COLUMNS, _STORAGE_COLUMNS, MAX_IMAGE_BYTES)

POLICY = 'captured-current-originals-binary-gallery-v1'
SOURCE = {'project': 'chatapp-4e347', 'database': '(default)', 'bucket': 'chatapp-4e347.appspot.com'}
PINS = {'generation': '1dac81d1f6255324bddb0b4ab6fa5e31b264ad54c77b84f9b6c9ed6a856c678b',
    'firestore': '70f4612227259ffb1ced42d96002447f4e7aceb0666ef259664025e388ed36cb',
    'storageMetadata':'8b6e1f538fe115934e7af1ebbf6e3731e94a2dee972a5dabc29aff270b6ec76f',
    'storageCopy': '7865b5261b7560b5ad35eeb006ed442bf0dbe60183bbb7418bb1a674da6bfe78'}
_CAPS = weakref.WeakKeyDictionary()
_ALLOWED_CHANGES = {'profilePic', 'profilePicThumb', 'lastOnlineTS', 'online', 'chats', 'chatWithId'}
PROFILE_SQL = """SELECT encoded_payload, payload_sha256 FROM clrs_staging.clrs_final_profile_photo_versions
 WHERE generation_id=%s AND uid=%s AND CAST(uid AS BINARY)=CAST(%s AS BINARY) LIMIT 1 FOR SHARE"""
VERSION_SQL = """SELECT source_path, encoded_payload, payload_sha256 FROM clrs_staging.clrs_final_media_versions
 WHERE generation_id=%s AND source_path_sha256=%s AND CAST(source_path AS BINARY)=CAST(%s AS BINARY) LIMIT 1 FOR SHARE"""
GENERATION_SQL = "SELECT state,expected_records,expected_batches FROM clrs_staging.clrs_final_generations WHERE generation_id=%s LIMIT 1 FOR SHARE"


def _decode(value, maximum=262144):
    if type(value) is bytes: value = value.decode('utf-8', 'strict')
    if type(value) is str: value = unique_json(value)
    if type(value) is not dict: raise RuntimeProfilePhotoNotFound()
    canonical_json(value, max_bytes=maximum)
    return value


def _same_current_original(left, right):
    def identity(value):
        url=urlsplit(value)
        if url.scheme!='https' or url.netloc!='firebasestorage.googleapis.com': raise RuntimeProfilePhotoNotFound()
        prefix='/v0/b/'+SOURCE['bucket']+'/o/'
        if not url.path.startswith(prefix): raise RuntimeProfilePhotoNotFound()
        pairs=parse_qsl(url.query,keep_blank_values=True,strict_parsing=True)
        query=dict(pairs)
        if len(pairs)!=2 or set(query)!={'alt','token'} or query['alt']!='media' or re.fullmatch(r'[A-Za-z0-9_-]{1,1024}',query['token']) is None: raise RuntimeProfilePhotoNotFound()
        return url.scheme,url.netloc,url.path
    return identity(left)==identity(right)


def source_slots(uid, root, gallery):
    """Same literal original/available/order policy, without forging old media IDs."""
    _identifier(uid); root = document(root)
    if _typed_string(root['fields'], 'uid') not in (None, uid): raise RuntimeProfilePhotoNotFound()
    if type(gallery) is not list or len(gallery) > 50: raise RuntimeProfilePhotoNotFound()
    original = _typed_string(root['fields'], 'profilePic')
    slots = [] if original in (None, '') else [[_storage_path(original), None]]
    ids = []; paths = set()
    for row in gallery:
        if type(row) is not dict or set(row) != {'id', 'payload', 'sha256'}: raise RuntimeProfilePhotoNotFound()
        ident = _identifier(row['id']); payload = document(row['payload'])
        if ident in ids or payload_digest(payload) != _sha(row['sha256']): raise RuntimeProfilePhotoNotFound()
        ids.append(ident); url = _typed_string(payload['fields'], 'url')
        if url in (None, ''): continue
        path = _storage_path(url)
        if path in paths: raise RuntimeProfilePhotoNotFound()
        paths.add(path)
        if original in (None, ''): raise RuntimeProfilePhotoNotFound()
        if path == slots[0][0]:
            if url != original and not _same_current_original(url,original): raise RuntimeProfilePhotoNotFound()
            slots[0][1] = ident
        else: slots.append([path, ident])
    if ids != sorted(ids, key=lambda x: x.encode()) or len(slots) > 20: raise RuntimeProfilePhotoNotFound()
    return slots


class VerifiedPhotoVersions:
    pass


def source_fingerprint():
    from pathlib import Path
    base = Path(__file__).parent
    names = ('runtime_versioned_profile_photos.py', 'runtime_profile_photos.py',
        'profile_photo_review.py', 'private_media_s3.py', 'runtime_mutations.py', 'profile_visibility.py',
        'runtime_versioned_profile_photos_factory.py', 'runtime_native_profile_photos.py',
        'runtime_profile_photo_uploads.py', 'native_profile_photo_factory.py')
    return hashlib.sha256(canonical_json({name: hashlib.sha256((base/name).read_bytes()).hexdigest()
        for name in names})).hexdigest()


def verify_photo_versions(raw, key):
    """Only an authenticated actual sidecar fresh-readback acknowledgement issues a cap."""
    try:
        if type(raw) is not bytes or not 1 <= len(raw) <= 16384 or type(key) is not bytes or len(key) < 32: raise ValueError()
        envelope = unique_json(raw.decode('utf-8', 'strict'))
        if set(envelope) != {'body', 'hmacSha256'}: raise ValueError()
        body = envelope['body']
        signature = hmac.digest(key, b'clrs-captured-photo-versions-readback-v1\0' + canonical_json(body), 'sha256').hex()
        if not hmac.compare_digest(signature, _sha(envelope['hmacSha256'])): raise ValueError()
        if (set(body) != {'kind','pins','policy','sourceFingerprint','profiles','media','freshReadbackVerified',
                'shadowGenerationVerified','objectCopiesVerified','sourceBarrierVerified','canonicalWrites',
                'legacyPromotionCipherSha256','targetBucket','expectedOwner'}
                or body['kind'] != 'clrs-captured-photo-versions-readback-v1' or body['pins'] != PINS
                or body['policy'] != POLICY or body['sourceFingerprint'] != source_fingerprint()
                or body['freshReadbackVerified'] is not True or body['shadowGenerationVerified'] is not True
                or body['objectCopiesVerified'] is not True or body['sourceBarrierVerified'] is not False
                or type(body['canonicalWrites']) is not int or body['canonicalWrites'] != 0
                or type(body['profiles']) is not dict or len(body['profiles']) != 7
                or type(body['media']) is not dict or len(body['media']) != 14): raise ValueError()
        _sha(body['legacyPromotionCipherSha256'])
        if type(body['targetBucket']) is not str or type(body['expectedOwner']) is not str: raise ValueError()
        for uid, digest in body['profiles'].items(): _identifier(uid); _sha(digest)
        for path, digest in body['media'].items(): _sha(path); _sha(digest)
        result = VerifiedPhotoVersions(); _CAPS[result] = body
        return result
    except Exception: raise RuntimeUnavailable() from None


class RuntimeVersionedProfilePhotosService(RuntimeProfilePhotosService):
    def __init__(self, store, cursor_key, *, private_s3, snapshot, spool_directory,
            media_promotion, clock=time.time, monotonic=time.monotonic):
        if (snapshot not in _CAPS or type(private_s3) is not PrivateMediaS3
                or type(media_promotion) is not VerifiedMediaPromotion
                or media_promotion.ciphertext_sha256 != _CAPS[snapshot]['legacyPromotionCipherSha256']
                or private_s3._bucket != _CAPS[snapshot]['targetBucket'] or private_s3._owner != _CAPS[snapshot]['expectedOwner']
                or type(cursor_key) is not bytes or len(cursor_key) != 32
                or not callable(getattr(store, 'read_authenticated', None))): raise RuntimeUnavailable()
        self._store=store; self._s3=private_s3; self._snapshot=snapshot; self._directory=spool_directory
        self._clock=clock; self._monotonic=monotonic; self._promotion=media_promotion
        self._codec=OpaqueReferences(hmac.digest(cursor_key, b'clrs-versioned-profile-photos-v1\0', 'sha256'))
        self._slots=threading.BoundedSemaphore(2); self._lock=threading.Lock()
        self._inflight=set(); self._leases=set(); self._closed=False

    def _check(self):
        with self._lock:
            if self._closed: raise RuntimeUnavailable()
        self._promotion.require_current(self._clock())
        if self._snapshot not in _CAPS or _CAPS[self._snapshot]['sourceFingerprint'] != source_fingerprint(): raise RuntimeUnavailable()

    def contains(self, identity, uid, *, access_token):
        # Even branch selection requires the current actor and current target.
        if uid not in _CAPS[self._snapshot]['profiles']: return False
        def select(cursor, execute, actor_uid):
            actor = _account(_rows(cursor,execute,ACTOR_SQL,(actor_uid,actor_uid)),actor_uid)
            _,_,before = _target(cursor,execute,uid,actor,datetime.fromtimestamp(self._clock(),timezone.utc))
            self._bundle(cursor,execute,uid,before)
            rows = _rows(cursor,execute,NATIVE_GALLERY_SQL.replace('LIMIT 21','LIMIT 51'),(uid,uid))
            native = bool(rows) and any(type(row[0]) is str and row[0].startswith('tw-profile-photo-') for row in rows)
            if native:
                try: native_gallery(rows,uid)
                except Exception: raise RuntimeProfilePhotoNotFound() from None
            _,_,after = _target(cursor,execute,uid,actor,datetime.fromtimestamp(self._clock(),timezone.utc))
            if after != before: raise RuntimeProfilePhotoNotFound()
            return {'native':native}
        if self._store.read_authenticated(identity,select,access_token=access_token)['native']: return False
        self._proof(identity, access_token, uid)
        return True

    def _bundle(self, cursor, execute, target_uid, current_guard):
        self._check(); expected = _CAPS[self._snapshot]['profiles'].get(target_uid)
        if expected is None: raise RuntimeProfilePhotoNotFound()
        gen = bytes.fromhex(PINS['generation'])
        if _rows(cursor,execute,GENERATION_SQL,(gen,)) != [('verified',86990,870)]: raise RuntimeProfilePhotoNotFound()
        stored = _rows(cursor,execute,PROFILE_SQL,(gen,target_uid,target_uid))
        if len(stored) != 1 or _sha(stored[0][1]) != expected: raise RuntimeProfilePhotoNotFound()
        bundle = _decode(stored[0][0]); digest = hashlib.sha256(canonical_json(bundle)).hexdigest()
        if (digest != expected or set(bundle) != {'uid','policy','root','rootSha256','gallery','canonicalGuard',
                'originalAssociations','referenceCohort','photos'} or bundle['uid'] != target_uid or bundle['policy'] != POLICY
                or type(bundle['canonicalGuard']) is not list or len(bundle['canonicalGuard']) != 9
                or any(bundle['canonicalGuard'][i] != current_guard[i] for i in (0,3,7))): raise RuntimeProfilePhotoNotFound()
        return bundle

    def _context(self, cursor, execute, actor_uid, target_uid):
        self._check(); cap = _CAPS[self._snapshot]; gen = bytes.fromhex(PINS['generation'])
        actor = _account(_rows(cursor, execute, ACTOR_SQL, (actor_uid,actor_uid)), actor_uid)
        _, raw, before = _target(cursor, execute, target_uid, actor, datetime.fromtimestamp(self._clock(),timezone.utc))
        bundle = self._bundle(cursor,execute,target_uid,before)
        digest = hashlib.sha256(canonical_json(bundle)).hexdigest()
        current = document(bundle['root']); baseline = document(raw)
        if payload_digest(current) != bundle['rootSha256']: raise RuntimeProfilePhotoNotFound()
        strip = lambda fields: {k:v for k,v in fields.items() if k not in _ALLOWED_CHANGES}
        if strip(current['fields']) != strip(baseline['fields']) or current['createTime'] != baseline['createTime']: raise RuntimeProfilePhotoNotFound()
        old = [list(vars(row).values()) for row in _associations(cursor,execute,target_uid)]
        if old != bundle['originalAssociations']: raise RuntimeProfilePhotoNotFound()
        slots = source_slots(target_uid,current,bundle['gallery']); photos = bundle['photos']
        if type(bundle['referenceCohort']) is not list or len(bundle['referenceCohort'])>1000: raise RuntimeProfilePhotoNotFound()
        for path,_ in slots:
            if not any(type(ref) is dict and ref.get('name')==path and ref.get('owner')==target_uid
                    and ref.get('purpose')=='profile' and ref.get('validContext') is True
                    and ref.get('documentPath') in ['users/'+target_uid,*('users/'+target_uid+'/images/'+row['id'] for row in bundle['gallery'])]
                    for ref in bundle['referenceCohort']): raise RuntimeProfilePhotoNotFound()
        if type(photos) is not list or len(photos) != len(slots): raise RuntimeProfilePhotoNotFound()
        records=[]; rows=[]; provenance=[]
        for ordinal,(slot,item) in enumerate(zip(slots,photos)):
            if type(item) is not dict or set(item) != {'path','imageId','mediaId','record','versionSha256','storageProof','currentMetadata'} or [item['path'],item['imageId']] != slot: raise RuntimeProfilePhotoNotFound()
            record=item['record']; _identifier(item['mediaId'])
            if (type(record) is not dict or set(record) != {'key','size','sha256','content_type'}
                    or type(record['size']) is not int or not 0 < record['size'] <= MAX_IMAGE_BYTES
                    or record['content_type'] not in {'image/jpeg','image/png','image/webp','image/gif'}): raise RuntimeProfilePhotoNotFound()
            _sha(record['sha256'])
            if item['versionSha256'] is not None:
                pin = cap['media'].get(_digest(item['path']))
                version = _rows(cursor,execute,VERSION_SQL,(gen,_hash(item['path']),item['path']))
                if pin != item['versionSha256'] or len(version) != 1 or version[0][0] != item['path'] or _sha(version[0][2]) != pin: raise RuntimeProfilePhotoNotFound()
                value = _decode(version[0][1],65536)
                if (hashlib.sha256(canonical_json(value)).hexdigest() != pin or value['source']['name'] != item['path']
                        or value['copyProofSha256'] != PINS['storageCopy'] or value['target'] != {'targetKey':record['key'],
                            'size':record['size'],'sha256':record['sha256'],'contentType':record['content_type']}
                        or int(value['source']['metadata']['size']) != record['size']
                        or value['source']['metadata']['contentType'] != record['content_type']
                        or value['source']['metadata'].get('bucket',SOURCE['bucket']) != SOURCE['bucket']
                        or re.fullmatch(r'[1-9][0-9]{0,30}',value['source']['metadata']['generation']) is None
                        or record['key'] != 'clrs-import-quarantine/'+hashlib.sha256(canonical_json(
                            ['clrs-final-storage-delta-v1',SOURCE['project'],SOURCE['bucket'],item['path'],
                             value['source']['metadata']['generation'],record['sha256']])).hexdigest()
                        or item['mediaId'] != 'version-media-'+record['key'].rsplit('/',1)[-1]): raise RuntimeProfilePhotoNotFound()
                provenance.append(pin)
            else:
                sr = _rows(cursor,execute,storage_sql(1),(SOURCE['bucket'],_hash(item['path'])))
                if len(sr)!=1: raise RuntimeProfilePhotoNotFound()
                stored=dict(zip(_STORAGE_COLUMNS,sr[0])); _copied(stored['copied_at'])
                stored['source_metadata']=_metadata(stored['source_metadata'])
                stored['source_sha256']=_sha(stored['source_sha256']);stored['target_sha256']=_sha(stored['target_sha256'])
                if type(stored['copied_at']) is datetime: stored['copied_at']=stored['copied_at'].strftime('%Y-%m-%d %H:%M:%S.%f')
                metadata=item['currentMetadata']
                if (stored!=item['storageProof'] or stored['source_bucket']!=SOURCE['bucket'] or stored['source_path']!=item['path']
                        or record['key']!=target_key(SOURCE['project'],SOURCE['bucket'],item['path'])
                        or stored['target_key']!=record['key'] or stored['source_size']!=record['size']
                        or stored['source_sha256']!=record['sha256'] or stored['target_sha256']!=record['sha256']
                        or type(metadata) is not dict or metadata.get('contentType')!=record['content_type']
                        or any(metadata.get(field)!=stored['source_metadata'].get(field)
                            for field in ('generation','size','contentType','md5Hash','crc32c'))): raise RuntimeProfilePhotoNotFound()
                provenance.append(hashlib.sha256(canonical_json(stored)).hexdigest())
            records.append(record); rows.append([item['mediaId'],ordinal,int(ordinal==0)])
        _,_,after = _target(cursor,execute,target_uid,actor,datetime.fromtimestamp(self._clock(),timezone.utc))
        if after != before or [list(vars(row).values()) for row in _associations(cursor,execute,target_uid)] != old: raise RuntimeProfilePhotoNotFound()
        self._check()
        return {'actorHash':_digest(actor_uid),'targetHash':_digest(target_uid),
            'contextHash':hashlib.sha256(canonical_json([digest,before,old,provenance])).hexdigest(),'rows':rows,'records':records}

    def open_photo(self, identity, target_uid, reference, **kwargs):
        lease=super().open_photo(identity,target_uid,reference,**kwargs)
        try:
            resource=self._resource(identity,kwargs['access_token'],target_uid,reference)
            original=lease._before_first_byte
            def before():
                from private_media_s3 import PRIVACY_MAX_AGE
                original()
                checked=self._s3._object_privacy(resource['record']['key'],lease._deadline,lease._cancel)
                if self._monotonic()-checked>PRIVACY_MAX_AGE: raise RuntimeUnavailable()
                original()  # Actor/target may be revoked during the final private lookup.
            lease._before_first_byte=before
            return lease
        except BaseException:
            lease.close();raise
