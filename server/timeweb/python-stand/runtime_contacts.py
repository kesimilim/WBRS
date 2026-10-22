"""Native friends and guests. Current sessions, private owner lists, CAS writes.

Lists join profiles in one bounded batch. Archived profile payloads never leave
the server. Visits do not disclose invisible visitors or modify paid periods.
"""
from datetime import datetime, timezone
import hmac
import time

from legacy_conversation_payload import OpaqueReferences
from native_credentials import decode_base64
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, RuntimeRejected, MAX_INTEGER
from runtime_people import RuntimePeopleService, _uid, _row, _decode_person, _SELECT

OPERATION = 'contacts.change.v1'
KINDS = frozenset({'friends', 'incoming', 'outgoing', 'guests'})
ACTIONS = frozenset({'send', 'accept', 'decline', 'cancel', 'remove', 'visit'})
RELATION = ('SELECT state,requester_uid,revision FROM clrs_staging.contact_relationships '
            'WHERE uid_low=%s AND uid_high=%s LIMIT 1')


class ContactUnavailable(RuntimeInvalidRequest):
    pass


def validate_action(value):
    if (type(value) is not dict or set(value) != {'kind', 'targetUid', 'expectedRevision'}
            or type(value['kind']) is not str or value['kind'] not in ACTIONS
            or type(value['expectedRevision']) is not int
            or not 0 <= value['expectedRevision'] < MAX_INTEGER):
        raise RuntimeInvalidRequest()
    _uid(value['targetUid'])
    if value['kind'] == 'visit' and value['expectedRevision'] != 0:
        raise RuntimeInvalidRequest()
    return value


def relation_result(actor, target, row):
    if row is None:
        return {'kind': 'native-relationship', 'targetUid': target, 'status': 'none', 'revision': 0}
    if (len(row) != 3 or row[0] not in {'none', 'pending', 'friends'}
            or type(row[2]) is not int or not 1 <= row[2] <= MAX_INTEGER
            or (row[0] == 'pending' and row[1] not in {actor, target})
            or (row[0] != 'pending' and row[1] is not None)):
        raise RuntimeUnavailable()
    status = ('outgoing' if row[1] == actor else 'incoming') if row[0] == 'pending' else row[0]
    return {'kind': 'native-relationship', 'targetUid': target, 'status': status, 'revision': row[2]}


def transition(action, status):
    allowed = {'send': ('none', 'outgoing'), 'accept': ('incoming', 'friends'),
               'decline': ('incoming', 'none'), 'cancel': ('outgoing', 'none'),
               'remove': ('friends', 'none')}
    before, after = allowed[action]
    return after if status == before else None


class RuntimeContactsService:
    def __init__(self, store, key, *, clock=time.time):
        if store is None or type(key) is not bytes or len(key) != 32:
            raise RuntimeUnavailable()
        self.store = store; self.clock = clock
        self.codec = OpaqueReferences(hmac.digest(key, b'clrs-native-contacts-v1\0', 'sha256'))
        store.register_replay_guard(OPERATION, self._replay, response_guard=True)

    @classmethod
    def from_env(cls, store, env):
        return cls(store, decode_base64(env.get('CLRS_LEGACY_READ_CURSOR_KEY_B64'), max_bytes=32))

    def _people(self, cursor, execute, actor, uids):
        if not uids: return {}
        marks = ','.join(['%s']*len(uids))
        execute(_SELECT+' AND p.uid IN ('+marks+') LIMIT 31 FOR SHARE OF p,a', tuple(uids))
        result = {}
        for raw in cursor.fetchall():
            row = _row(raw)
            if row['uid'] not in uids or row['uid'] in result: raise RuntimeUnavailable()
            person = _decode_person(row, actor, datetime.fromtimestamp(self.clock(), timezone.utc))
            if person is not None:
                result[row['uid']] = {'uid': person['uid'], 'fullName': person['fullName'],
                    'primaryGroup': person['primaryGroup'], 'city': person['city'], 'age': person['age']}
        return result

    def _target(self, cursor, execute, actor, target):
        if target == actor.uid: raise ContactUnavailable()
        people = self._people(cursor, execute, actor, [target])
        if target not in people: raise ContactUnavailable()

    def relationship(self, identity, target, *, access_token):
        target = _uid(target)
        def read(c, ex, uid):
            actor = RuntimePeopleService._actor(c, ex, uid)
            self._target(c, ex, actor, target)
            ex(RELATION+' FOR SHARE', tuple(sorted([uid, target])))
            return relation_result(uid, target, c.fetchone())
        return self.store.read_authenticated(identity, read, access_token=access_token)

    def _anchor(self, token, uid, kind, limit):
        if token is None: return None
        try:
            if type(token) is not str or len(token) > 2048: raise ValueError()
            value = self.codec.open('cursor', token)
            if (set(value) != {'uid', 'kind', 'limit', 'after', 'exp'}
                    or value['uid'] != uid or value['kind'] != kind
                    or type(value['limit']) is not int or value['limit'] != limit
                    or type(value['exp']) is not int or not self.clock() < value['exp'] <= self.clock()+300
                    or type(value['after']) is not list or len(value['after']) != 2):
                raise ValueError()
            from runtime_reads import _timestamp
            _timestamp(value['after'][0], nullable=True); _uid(value['after'][1])
            return value['after']
        except Exception:
            raise RuntimeInvalidRequest() from None

    def list(self, identity, kind, *, access_token, limit=20, cursor=None):
        if type(kind) is not str or kind not in KINDS or type(limit) is not int or not 1 <= limit <= 30:
            raise RuntimeInvalidRequest()
        def read(c, ex, uid):
            actor = RuntimePeopleService._actor(c, ex, uid)
            anchor = self._anchor(cursor, uid, kind, limit)
            if kind == 'guests':
                source = ('SELECT visitor_uid AS peer,last_visit_at AS stamp,NULL AS state,NULL AS requester,0 AS revision '
                          'FROM clrs_staging.profile_visits WHERE owner_uid=%s')
                params = [uid]
            else:
                state = 'friends' if kind == 'friends' else 'pending'
                direction = '' if kind == 'friends' else (' AND requester_uid=%s' if kind == 'outgoing' else ' AND requester_uid<>%s')
                source = ('SELECT uid_high AS peer,updated_at AS stamp,state,requester_uid AS requester,revision '
                          'FROM clrs_staging.contact_relationships WHERE uid_low=%s AND state=%s'+direction+
                          ' UNION ALL SELECT uid_low AS peer,updated_at AS stamp,state,requester_uid AS requester,revision '
                          'FROM clrs_staging.contact_relationships WHERE uid_high=%s AND state=%s'+direction)
                part = [uid, state] + ([] if kind == 'friends' else [uid]); params = part+part
            where = ''
            if anchor is not None:
                if anchor[0] is None:
                    where = ' WHERE stamp IS NULL AND peer>%s'; params.append(anchor[1])
                else:
                    date = anchor[0][:-1].replace('T', ' ')
                    where = ' WHERE (stamp<%s OR (stamp=%s AND peer>%s) OR stamp IS NULL)'
                    params.extend([date, date, anchor[1]])
            sql = ("SELECT peer,DATE_FORMAT(stamp,'%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ'),state,requester,revision FROM ("+
                   source+') AS contacts'+where+' ORDER BY stamp DESC,peer ASC LIMIT %s')
            ex(sql, (*params, limit+1)); rows = c.fetchall()
            if len(rows) > limit+1: raise RuntimeUnavailable()
            selected = rows[:limit]; peers = [_uid(r[0]) for r in selected]
            if len(peers) != len(set(peers)): raise RuntimeUnavailable()
            people = self._people(c, ex, actor, peers)
            items = []
            for row in selected:
                if row[0] not in people: continue
                status = 'guest' if kind == 'guests' else relation_result(uid, row[0], row[2:])['status']
                items.append({**people[row[0]], 'status': status, 'revision': row[4], 'updatedAt': row[1]})
            next_cursor = None
            if len(rows) > limit:
                last = selected[-1]
                next_cursor = self.codec.seal('cursor', {'uid':uid,'kind':kind,'limit':limit,
                    'after':[last[1],last[0]],'exp':int(self.clock())+300})
            return {'kind':'native-contacts','list':kind,'items':items,'nextCursor':next_cursor}
        return self.store.read_authenticated(identity, read, access_token=access_token)

    def _replay(self, c, ex, uid, request, response):
        validate_action(request)
        actor = RuntimePeopleService._actor(c, ex, uid)
        # The receipt contains only this actor's original action result, no
        # target profile. Keep it available after hiding/deletion so a committed
        # action can be acknowledged without issuing another POST.
        if type(response) is not dict: raise RuntimeUnavailable()
        if response in ({'error':'contact_unavailable'}, {'error':'relationship_changed'}): return
        if request['kind'] == 'visit':
            if (set(response) != {'kind','targetUid','recorded'} or response['kind'] != 'native-visit'
                    or response['targetUid'] != request['targetUid'] or type(response['recorded']) is not bool):
                raise RuntimeUnavailable()
        else:
            expected = transition(request['kind'], {'send':'none','accept':'incoming',
                'decline':'incoming','cancel':'outgoing','remove':'friends'}[request['kind']])
            if (set(response) != {'kind','targetUid','status','revision'} or response['kind'] != 'native-relationship'
                    or response['targetUid'] != request['targetUid'] or response['status'] != expected
                    or type(response['revision']) is not int or response['revision'] != request['expectedRevision']+1):
                raise RuntimeUnavailable()

    def perform(self, identity, operation_id, value, *, access_token):
        request = validate_action(value)
        def action(c, ex, uid):
            actor = RuntimePeopleService._actor(c, ex, uid); target = request['targetUid']
            try: self._target(c, ex, actor, target)
            except ContactUnavailable: return 404, {'error':'contact_unavailable'}, None
            if request['kind'] == 'visit':
                # The target sees this visitor only if the visitor is currently
                # visible to the target as well. Never record invisible visits.
                target_actor = RuntimePeopleService._actor(c, ex, target)
                visible = uid in self._people(c, ex, target_actor, [uid])
                if visible:
                    ex('INSERT INTO clrs_staging.profile_visits(owner_uid,visitor_uid,last_visit_at) '
                       'VALUES(%s,%s,UTC_TIMESTAMP(6)) ON DUPLICATE KEY UPDATE last_visit_at=UTC_TIMESTAMP(6)', (target,uid))
                return 200, {'kind':'native-visit','targetUid':target,'recorded':visible}, None
            pair = tuple(sorted([uid,target]))
            # A persistent none row lets cancel/remove use UPDATE only and stops
            # stale actions or duplicate retries from resurrecting a friendship.
            ex("INSERT INTO clrs_staging.contact_relationships(uid_low,uid_high,state,requester_uid,revision,updated_at) "
               "VALUES(%s,%s,'none',NULL,1,UTC_TIMESTAMP(6)) ON DUPLICATE KEY UPDATE uid_low=uid_low", pair)
            inserted = c.rowcount == 1
            ex(RELATION+' FOR UPDATE', pair); before = relation_result(uid,target,c.fetchone())
            revision = 0 if inserted else before['revision']
            if revision != request['expectedRevision']:
                return 409, {'error':'relationship_changed'}, before['revision']
            after = transition(request['kind'], before['status'])
            if after is None: return 409, {'error':'relationship_changed'}, before['revision']
            state = 'pending' if after == 'outgoing' else after
            requester = uid if state == 'pending' else None
            revision += 1
            ex('UPDATE clrs_staging.contact_relationships SET state=%s,requester_uid=%s,revision=%s,updated_at=UTC_TIMESTAMP(6) '
               'WHERE uid_low=%s AND uid_high=%s', (state,requester,revision,*pair))
            return 200, {'kind':'native-relationship','targetUid':target,'status':after,'revision':revision}, revision
        return self.store.mutate(identity,OPERATION,operation_id,request,action,access_token=access_token)
