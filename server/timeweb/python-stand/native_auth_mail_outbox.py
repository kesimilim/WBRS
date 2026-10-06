"""Prepared auth-email SQL leaves, no worker/SEND/connection/COMMIT/retry.

Caller owns bounded SERIALIZABLE TX and verified TLS/schema/role. Frozen
challenge._locked/_eligible/_now are the explicitly reviewed internal interface:
account -> challenge -> outbox, WITHOUT _verify_locked/code-attempt charging.
Enqueue belongs in challenge/receipt TX. start_delivery returns NO mail intent.
Only an ACKNOWLEDGED claim COMMIT followed by verify_committed_claim on a
DIFFERENT actual cursor.connection can expose an intent. Unknown claim COMMIT
NEVER permits SEND, even if a later row says started. Claim verification is not
a transaction runner and cannot observe the caller's COMMIT acknowledgement.

The future SMTP caller must commit/release verification locks, immediately
check delivery.remaining_seconds(), and construct/pass that <=8s deadline to
the transport; skip near expiry or delay. No automatic SMTP/claim retry, including
failure/unknown. Atomic SQL + SMTP delivery is not claimed. The prepared worker
passes the verified absolute deadline to the shared SMTP transport; no worker
is enabled by these leaves.

Historical receipt reconciliation after challenge replacement must use the
immutable resolve_context seam; do not bind a new receipt to a rotated row.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import hmac
import json
import threading
import time
import weakref

from native_auth_challenges import (NativeAuthChallengeStore, IssuedChallenge,
                                   _uid, _identifier, _date, _timestamp)
from native_credentials import unique_json
from native_mail import NativeMailIntent
from native_mail_envelope import NativeMailEnvelope
from native_password_credentials import PURPOSES

EVENT_KIND = "auth.challenge.mail.v1"
STARTED = "auth.mail.started"
_ERRORS = {"failed": "auth.mail.failed", "unknown": "auth.mail.unknown"}
_QUERY = """SELECT outbox_id, source_event_id, audience_uid, channel, event_kind, payload,
 DATE_FORMAT(available_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'), attempts,
 DATE_FORMAT(delivered_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'), last_error_code,
 DATE_FORMAT(created_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f')
 FROM clrs_staging.outbox WHERE outbox_id = %s LIMIT 1 FOR UPDATE"""
_CONTEXT_QUERY = _QUERY.removesuffix(" FOR UPDATE")


class AuthMailUnavailable(Exception):
    """Generic refusal/failure, never private rows, recipient/code or SQL text."""


@dataclass(frozen=True, repr=False, eq=False)
class AuthMailClaim:
    """Opaque registry capability; contains NO publicly extractable intent."""


@dataclass(frozen=True, repr=False)
class AuthMailDecision:
    state: str
    claim: AuthMailClaim | None = None
    retired: bool = False  # ACK belongs to the outer transaction runner only.


@dataclass(frozen=True, repr=False)
class OriginalAuthMailContext:
    """Historical receipt context only; never an auth/delivery capability."""
    uid: str
    email: str
    purpose: str
    challenge_id: str
    email_identity: bytes


@dataclass(frozen=True, repr=False)
class VerifiedAuthMailDelivery:
    intent: NativeMailIntent
    _deadline: float
    _clock: object

    def remaining_seconds(self):
        # Future transport must receive this budget, never reset it to eight.
        remaining = self._deadline - self._clock()
        if not 0 < remaining <= 8:
            raise AuthMailUnavailable()
        return remaining


def _json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"), allow_nan=False)


def _ids(uid, purpose, challenge_id):
    _uid(uid); _identifier(challenge_id)
    if not isinstance(purpose, str) or purpose not in PURPOSES:
        raise AuthMailUnavailable()
    identifier = "auth-mail:" + challenge_id
    return identifier, identifier


def _connection(cursor):
    connection = getattr(cursor, "connection", None)
    if connection is None:
        raise AuthMailUnavailable()
    return connection


class NativeAuthMailOutbox:
    def __init__(self, challenges, envelopes, *, monotonic=time.monotonic):
        if (not isinstance(challenges, NativeAuthChallengeStore)
                or not isinstance(envelopes, NativeMailEnvelope) or not callable(monotonic)):
            raise AuthMailUnavailable()
        self.challenges = challenges; self.envelopes = envelopes; self._clock = monotonic
        self._claims = weakref.WeakKeyDictionary(); self._lock = threading.Lock()

    def _current(self, cursor, execute, uid, purpose, challenge_id):
        self.challenges._enabled(); _ids(uid, purpose, challenge_id)
        account, record = self.challenges._locked(cursor, execute, uid, purpose)
        now = self.challenges._now(cursor, execute)
        if (account is None or record is None or record['challenge_id'] != challenge_id
                or record['version'] != account[4] or record['attempts'] >= 5
                or record['consumed'] is not None or not record['issued'] <= now < record['expires']
                or not self.challenges._eligible(cursor, execute, account, record, account[1], purpose)
                or not hmac.compare_digest(record['email_identity'],
                                           self.challenges.codec.email_identity(account[1]))):
            return None
        return account, record, now

    def _intent(self, account, record, payload, now):
        if (payload.get('issuedAt') != record['issued'] or payload.get('expiresAt') != record['expires']):
            raise AuthMailUnavailable()
        intent = self.envelopes.open(payload, uid=record['uid'], purpose=record['purpose'],
            delivery_id=record['challenge_id'], now=now)
        if (intent.recipient != account[1]
                or not hmac.compare_digest(record['email_identity'],
                                           self.challenges.codec.email_identity(intent.recipient))
                or not hmac.compare_digest(record['code_hmac'], self.challenges.codec.digest(
                    uid=record['uid'], email=intent.recipient, purpose=record['purpose'],
                    challenge_id=record['challenge_id'], account_token_version=record['version'],
                    issued_at=record['issued'], expires_at=record['expires'], code=intent.code))):
            raise AuthMailUnavailable()
        return intent

    @staticmethod
    def _row(cursor, execute, uid, purpose, challenge_id):
        identifier, source = _ids(uid, purpose, challenge_id)
        execute(_QUERY, (identifier,)); values = cursor.fetchone()
        return NativeAuthMailOutbox._parse_row(values, uid, purpose, challenge_id)

    @staticmethod
    def _parse_row(values, uid, purpose, challenge_id):
        identifier, source = _ids(uid, purpose, challenge_id)
        if values is None:
            return None
        if (not isinstance(values, (tuple, list)) or len(values) != 11
                or tuple(values[:5]) != (identifier, source, uid, 'email', EVENT_KIND)
                or type(values[7]) is not int or values[7] not in (0, 1)):
            raise AuthMailUnavailable()
        payload = values[5]
        if isinstance(payload, (str, bytes)):
            if len(payload) > 8192:
                raise AuthMailUnavailable()
            payload = unique_json(payload)
        if type(payload) is not dict or len(_json(payload).encode()) > 8192:
            raise AuthMailUnavailable()
        _date(values[6]); _date(values[10])
        if values[8] is not None:
            _date(values[8])
        if values[7] == 0:
            if values[8] is not None or values[9] is not None:
                raise AuthMailUnavailable()
        elif values[8] is None:
            if values[9] not in (STARTED, *_ERRORS.values()):
                raise AuthMailUnavailable()
        elif values[9] is not None:
            raise AuthMailUnavailable()
        return {'id': identifier, 'source': source, 'uid': uid, 'purpose': purpose,
                'challenge_id': challenge_id, 'payload': payload, 'available': values[6],
                'attempts': values[7], 'delivered': values[8], 'error': values[9], 'created': values[10]}

    def resolve_context(self, cursor, execute, *, challenge_id):
        """SELECT-only immutable context, including expired/replaced challenges.

        Finish this resolver's separate read TX BEFORE account/challenge write
        locks. HTTP must compare resolved purpose to its fixed route. Opening
        at immutable issuedAt is ONLY AEAD context recovery, never current-time
        eligibility. No code/intent is returned. Original independent email-HMAC
        is not stored in this envelope: this recomputes the canonical email HMAC;
        original sensitive receipt context/request digests are checked separately.
        Absent fake IDs give None/generic outward refusal, never a guessed UID.
        """
        try:
            self.challenges._enabled(); _identifier(challenge_id)
            if not callable(execute):
                raise AuthMailUnavailable()
            execute(_CONTEXT_QUERY, ('auth-mail:' + challenge_id,))
            values = cursor.fetchone()
            if values is None:
                return None
            if not isinstance(values, (tuple, list)) or len(values) != 11:
                raise AuthMailUnavailable()
            payload = values[5]
            if isinstance(payload, (str, bytes)):
                if len(payload) > 8192:
                    raise AuthMailUnavailable()
                payload = unique_json(payload)
            if type(payload) is not dict:
                raise AuthMailUnavailable()
            uid, purpose = values[2], payload.get('purpose')
            row = self._parse_row(values, uid, purpose, challenge_id)
            intent = self.envelopes.open(row['payload'], uid=uid, purpose=purpose,
                delivery_id=challenge_id, now=row['payload'].get('issuedAt'))
            return OriginalAuthMailContext(uid, intent.recipient, purpose, challenge_id,
                                          self.challenges.codec.email_identity(intent.recipient))
        except AuthMailUnavailable:
            raise
        except Exception:
            raise AuthMailUnavailable() from None

    @staticmethod
    def _identity(row):
        # Delivery outcome changes are separate; all routing/ciphertext remains immutable.
        return hashlib.sha256(_json({k: v for k, v in row.items()
            if k not in ('attempts', 'delivered', 'error')}).encode()).digest()

    def enqueue(self, cursor, execute, *, issued, intent):
        try:
            if type(issued) is not IssuedChallenge or type(intent) is not NativeMailIntent:
                raise AuthMailUnavailable()
            current = self._current(cursor, execute, issued.uid, issued.purpose, issued.challenge_id)
            if current is None:
                return AuthMailDecision('declined')
            account, record, now = current
            if (issued.account_token_version != record['version'] or issued.issued_at != record['issued']
                    or issued.expires_at != record['expires'] or intent.delivery_id != issued.challenge_id):
                raise AuthMailUnavailable()
            payload = self.envelopes.seal(uid=issued.uid, purpose=issued.purpose, intent=intent,
                issued_at=record['issued'], expires_at=record['expires'])
            self._intent(account, record, payload, now)
            existing = self._row(cursor, execute, issued.uid, issued.purpose, issued.challenge_id)
            if existing is not None:
                self._intent(account, record, existing['payload'], now)
                return AuthMailDecision('already_queued')
            identifier, source = _ids(issued.uid, issued.purpose, issued.challenge_id)
            available = _timestamp(now)
            execute("""INSERT INTO clrs_staging.outbox
              (outbox_id, source_event_id, audience_uid, channel, event_kind, payload, available_at)
              VALUES (%s, %s, %s, 'email', %s, %s, %s)""",
              (identifier, source, issued.uid, EVENT_KIND, _json(payload), available))
            if cursor.rowcount != 1:
                raise AuthMailUnavailable()
            retained = self._row(cursor, execute, issued.uid, issued.purpose, issued.challenge_id)
            if (retained is None or retained['payload'] != payload or retained['available'] != available
                    or retained['attempts'] != 0 or retained['delivered'] is not None or retained['error'] is not None):
                raise AuthMailUnavailable()
            return AuthMailDecision('queued')
        except AuthMailUnavailable:
            raise
        except Exception:
            raise AuthMailUnavailable() from None

    def start_delivery(self, cursor, execute, *, uid, purpose, challenge_id):
        try:
            connection = _connection(cursor)
            current = self._current(cursor, execute, uid, purpose, challenge_id)
            if current is None:
                # A dispatcher may have selected this row before current email,
                # account/version or challenge changed. Retire ONLY this exact
                # immutable AEAD route under account->challenge->outbox locks;
                # historical decrypt is context recovery, never SEND authority.
                row = self._row(cursor, execute, uid, purpose, challenge_id)
                if row is None or row['attempts'] != 0:
                    return AuthMailDecision('declined')
                self.envelopes.open(row['payload'], uid=uid, purpose=purpose,
                    delivery_id=challenge_id, now=row['payload'].get('issuedAt'))
                identity = self._identity(row)
                execute("""UPDATE clrs_staging.outbox SET attempts = 1, last_error_code = %s
                  WHERE outbox_id = %s AND attempts = 0 AND delivered_at IS NULL AND last_error_code IS NULL""",
                  (_ERRORS['failed'], row['id']))
                if cursor.rowcount != 1:
                    raise AuthMailUnavailable()
                retained = self._row(cursor, execute, uid, purpose, challenge_id)
                if (retained is None or not hmac.compare_digest(identity, self._identity(retained))
                        or retained['attempts'] != 1 or retained['delivered'] is not None
                        or retained['error'] != _ERRORS['failed']):
                    raise AuthMailUnavailable()
                return AuthMailDecision('declined', retired=True)
            account, record, now = current
            row = self._row(cursor, execute, uid, purpose, challenge_id)
            if (row is None or row['attempts'] != 0 or _date(row['available']) > now
                    or _date(row['created']) > now or record['expires'] - now <= 8):
                return AuthMailDecision('declined')
            self._intent(account, record, row['payload'], now)
            identity = self._identity(row)
            execute("""UPDATE clrs_staging.outbox SET attempts = 1, last_error_code = %s
              WHERE outbox_id = %s AND attempts = 0 AND delivered_at IS NULL AND last_error_code IS NULL""",
              (STARTED, row['id']))
            if cursor.rowcount != 1:
                raise AuthMailUnavailable()
            retained = self._row(cursor, execute, uid, purpose, challenge_id)
            if (retained is None or not hmac.compare_digest(identity, self._identity(retained))
                    or retained['attempts'] != 1 or retained['delivered'] is not None or retained['error'] != STARTED):
                raise AuthMailUnavailable()
            claim = AuthMailClaim()
            with self._lock:
                self._claims[claim] = {'uid': uid, 'purpose': purpose, 'challenge_id': challenge_id,
                    'connection': connection, 'identity': identity, 'verification': 'unverified'}
            return AuthMailDecision('started', claim)
        except AuthMailUnavailable:
            raise
        except Exception:
            raise AuthMailUnavailable() from None

    def verify_committed_claim(self, cursor, execute, claim, *, commit_state):
        """Caller-acknowledged COMMIT AND fresh different-connection SQL proof.

        Unknown COMMIT parks local authority forever, with no SEND/retry. A bool,
        new cursor on the same connection or row state alone is insufficient.
        The caller owns releasing this verification TX before bounded SMTP I/O.
        """
        try:
            with self._lock:
                binding = self._claims.get(claim) if type(claim) is AuthMailClaim else None
                if binding is None or binding['verification'] != 'unverified':
                    raise AuthMailUnavailable()
                # Consume extraction authority even on refusal/error/unknown.
                binding['verification'] = 'refused'
            if commit_state == 'unknown':
                return None
            if commit_state != 'acknowledged' or _connection(cursor) is binding['connection']:
                raise AuthMailUnavailable()
            current = self._current(cursor, execute, binding['uid'], binding['purpose'], binding['challenge_id'])
            if current is None:
                return None
            account, record, now = current
            row = self._row(cursor, execute, binding['uid'], binding['purpose'], binding['challenge_id'])
            if (row is None or row['attempts'] != 1 or row['error'] != STARTED or row['delivered'] is not None
                    or not hmac.compare_digest(binding['identity'], self._identity(row))):
                raise AuthMailUnavailable()
            intent = self._intent(account, record, row['payload'], now)
            now = self.challenges._now(cursor, execute)
            if record['expires'] - now <= 8:
                return None
            with self._lock:
                binding['verification'] = 'verified'
            return VerifiedAuthMailDelivery(intent, self._clock() + 8, self._clock)
        except AuthMailUnavailable:
            raise
        except Exception:
            raise AuthMailUnavailable() from None

    def finish_delivery(self, cursor, execute, claim, *, outcome):
        """Record one SMTP outcome; never makes an attempted row eligible again.

        Completion does not require a still-current challenge: SMTP may have
        finished as it was replaced/consumed. It updates ONLY this exact claimed
        immutable outbox row, without reopening delivery authority.
        """
        try:
            with self._lock:
                binding = self._claims.get(claim) if type(claim) is AuthMailClaim else None
            if binding is None or outcome not in ('accepted', 'failed', 'unknown'):
                raise AuthMailUnavailable()
            if outcome == 'accepted' and binding['verification'] != 'verified':
                raise AuthMailUnavailable()
            self.challenges._enabled()
            self.challenges._locked(cursor, execute, binding['uid'], binding['purpose'])
            self.challenges._now(cursor, execute)
            row = self._row(cursor, execute, binding['uid'], binding['purpose'], binding['challenge_id'])
            if (row is None or row['attempts'] != 1 or row['error'] != STARTED or row['delivered'] is not None
                    or not hmac.compare_digest(binding['identity'], self._identity(row))):
                raise AuthMailUnavailable()
            error = None if outcome == 'accepted' else _ERRORS[outcome]
            execute("""UPDATE clrs_staging.outbox SET delivered_at =
              CASE WHEN %s = 'accepted' THEN UTC_TIMESTAMP(6) ELSE NULL END, last_error_code = %s
              WHERE outbox_id = %s AND attempts = 1 AND delivered_at IS NULL AND last_error_code = %s""",
              (outcome, error, row['id'], STARTED))
            if cursor.rowcount != 1:
                raise AuthMailUnavailable()
            retained = self._row(cursor, execute, binding['uid'], binding['purpose'], binding['challenge_id'])
            if (retained is None or not hmac.compare_digest(binding['identity'], self._identity(retained))
                    or retained['attempts'] != 1 or retained['error'] != error
                    or (retained['delivered'] is not None) != (outcome == 'accepted')):
                raise AuthMailUnavailable()
            with self._lock:
                binding['verification'] = 'finished'
            return AuthMailDecision(outcome)
        except AuthMailUnavailable:
            raise
        except Exception:
            raise AuthMailUnavailable() from None
