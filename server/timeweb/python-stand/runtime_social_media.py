"""Author-owned post images, using the existing private conditional S3 writer.

The key prefix is the writer's existing grant; a distinct domain and SQL
purpose keep post uploads separate from every profile gallery and receipt.
"""
import hashlib
import re
import threading
import time

from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, canonical_json
from runtime_profile_photo_uploads import validate_prepare, _uuid, _MEDIA, PhotoUploadVerificationFailed
from private_media_s3 import PrivateMediaUnavailable

MID = re.compile(r'tw-post-media-[a-f0-9]{64}\Z')
PREFIX = 'clrs-native-profile/'


def media_identity(uid, operation):
    digest = hashlib.sha256(b'clrs-native-post-photo-v1\0' + canonical_json([uid, _uuid(operation)])).hexdigest()
    return 'tw-post-media-' + digest, PREFIX + digest


def media_ids(value):
    if (type(value) is not list or len(value) > 10
            or any(type(v) is not str for v in value) or len(set(value)) != len(value)):
        raise RuntimeInvalidRequest()
    from runtime_social import ident
    return [ident(v) for v in value]


class RuntimeSocialMedia:
    def __init__(self, store, writer, roles):
        self.store = store; self.writer = writer; self.roles = roles
        self.slots = threading.BoundedSemaphore(2)

    def authorize(self, c, ex, uid):
        from runtime_social import SocialAccessDenied
        if not self.roles(c, ex, uid) & {'author', 'admin', 'moderator'}:
            raise SocialAccessDenied()

    def record(self, c, ex, uid, media_id, *, lock=False):
        from runtime_social import SocialAccessDenied
        if type(media_id) is not str or MID.fullmatch(media_id) is None: raise RuntimeInvalidRequest()
        ex(_MEDIA.replace('FOR SHARE', 'FOR UPDATE') if lock else _MEDIA, (media_id, media_id))
        row = c.fetchone()
        if (row is None or len(row) != 11 or tuple(row[:4]) !=
                (media_id, uid, 'post', PREFIX + media_id[len('tw-post-media-'):])
                or row[7] not in ('pending', 'ready') or any(v != 1 for v in row[8:])):
            raise SocialAccessDenied()
        metadata = validate_prepare({'mimeType': row[4], 'byteSize': row[5], 'sha256': row[6]})
        return row[7], {'key': row[3], 'size': metadata['byteSize'],
                       'sha256': metadata['sha256'], 'content_type': metadata['mimeType']}

    def prepare(self, identity, operation, payload, *, access_token):
        fields = validate_prepare({k: v for k, v in payload.items() if k != 'kind'})
        if self.writer is None: raise RuntimeUnavailable()
        def action(c, ex, uid):
            self.authorize(c, ex, uid)
            ex("SELECT media_id FROM clrs_staging.media_objects WHERE owner_uid=%s AND purpose='post' "
               "AND status='pending' AND created_at>UTC_TIMESTAMP()-INTERVAL 1 DAY LIMIT 100 FOR SHARE", (uid,))
            pending = c.fetchall()
            if len(pending) >= 100: raise RuntimeUnavailable()
            mid, key = media_identity(uid, operation)
            ex("INSERT INTO clrs_staging.media_objects(media_id,owner_uid,purpose,object_key,mime_type,byte_size,sha256,status) "
               "VALUES(%s,%s,'post',%s,%s,%s,%s,'pending')",
               (mid, uid, key, fields['mimeType'], fields['byteSize'], bytes.fromhex(fields['sha256'])))
            if c.rowcount != 1: raise RuntimeUnavailable()
            return 201, {'mediaId': mid, 'status': 'pending', **fields}, None
        return self.store.mutate(identity, 'social.prepare-media.v1', operation, payload, action, access_token=access_token)

    def context(self, identity, media_id, operation, token):
        def read(c, ex, uid):
            self.authorize(c, ex, uid)
            if media_identity(uid, operation)[0] != media_id: raise RuntimeInvalidRequest()
            status, record = self.record(c, ex, uid, media_id)
            return {'status': status, 'record': record}
        value = self.store.read_authenticated(identity, read, access_token=token)
        return value['status'], value['record']

    def lease(self, identity, media_id, operation, *, access_token):
        status, record = self.context(identity, media_id, operation, access_token)
        if status != 'pending' or self.writer is None: raise RuntimeUnavailable()
        if not self.slots.acquire(blocking=False): raise RuntimeUnavailable()
        cancel = threading.Event()
        try:
            lease = self.writer.prepare_put(record, deadline=time.monotonic()+5, cancel=cancel)
            if self.context(identity, media_id, operation, access_token) != (status, record): raise RuntimeUnavailable()
            return {'mediaId': media_id, 'method': 'PUT', **lease, 'byteSize': record['size'],
                    'mimeType': record['content_type'], 'sha256': record['sha256']}
        finally:
            cancel.set(); self.slots.release()

    def commit(self, identity, operation, payload, *, access_token):
        _uuid(payload['prepareOperationId'])
        if not isinstance(payload['mediaId'], str) or not MID.fullmatch(payload['mediaId']): raise RuntimeInvalidRequest()
        original = self.store.lookup(identity, 'social.commit-media.v1', operation, payload=payload, access_token=access_token)
        if original.payload['state'] != 'not_found': return original
        status, record = self.context(identity, payload['mediaId'], payload['prepareOperationId'], access_token)
        if self.writer is None or not self.slots.acquire(blocking=False): raise RuntimeUnavailable()
        cancel = threading.Event()
        try:
            evidence = None
            try: evidence = self.writer.verify_ready(record, deadline=time.monotonic()+12, cancel=cancel)
            except (PrivateMediaUnavailable, PhotoUploadVerificationFailed): pass
            def action(c, ex, uid):
                self.authorize(c, ex, uid)
                if media_identity(uid, payload['prepareOperationId'])[0] != payload['mediaId']: raise RuntimeInvalidRequest()
                current, actual = self.record(c, ex, uid, payload['mediaId'], lock=True)
                if actual != record: raise RuntimeUnavailable()
                if evidence is None: return 409,{'error':'media_not_verified'},None
                self.writer.require_verified(evidence, actual)
                if current == 'pending':
                    ex("UPDATE clrs_staging.media_objects SET status='ready',updated_at=UTC_TIMESTAMP(6) "
                       "WHERE media_id=%s AND owner_uid=%s AND purpose='post' AND status='pending'", (payload['mediaId'], uid))
                    if c.rowcount != 1: raise RuntimeUnavailable()
                return 200, {'mediaId': payload['mediaId'], 'ready': True}, None
            return self.store.mutate(identity, 'social.commit-media.v1', operation, payload, action, access_token=access_token)
        finally:
            cancel.set(); self.slots.release()

    def replay(self, c, ex, uid, operation, request, response):
        self.authorize(c, ex, uid)
        if request['kind'] == 'prepare-media':
            fields = validate_prepare({k: v for k, v in request.items() if k != 'kind'})
            mid, _ = media_identity(uid, operation)
            if response != {'mediaId': mid, 'status': 'pending', **fields}: raise RuntimeUnavailable()
            _, record = self.record(c, ex, uid, mid)
            if (record['size'], record['sha256'], record['content_type']) != (fields['byteSize'], fields['sha256'], fields['mimeType']):
                raise RuntimeUnavailable()
        else:
            if (response != {'mediaId': request['mediaId'], 'ready': True}
                    or media_identity(uid, request['prepareOperationId'])[0] != request['mediaId']
                    or self.record(c, ex, uid, request['mediaId'])[0] != 'ready'):
                raise RuntimeUnavailable()
