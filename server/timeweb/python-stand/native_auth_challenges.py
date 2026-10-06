"""Default-off SQL leaf for email challenges; no connection/commit/mail/retry.

TRUSTED CALLER CONTRACT: cursor/execute belong to ONE bounded SERIALIZABLE
transaction with verified TLS/schema/role. UID/email are resolved by the caller,
not accepted as client-selected authority. Lock account -> challenge -> keyed
sensitive receipt -> credential/session/outbox. The caller owns receipt replay,
COMMIT/rollback and unknown-outcome lookup; never store a code/password/original
sensitive request in receipts. Declined check results MUST be committed with
their keyed receipt to preserve failed attempts, not raised/rolled back.

This leaf cannot create signup authority. Initial signup requires the separate
new-account leaf's authentic same-cursor/execute capability after exact INSERT
readback; without it, initial signup is refused. An existing trusted pending
challenge can be reissued/checked/consumed without assigning a new marker.
No marker supplied by an HTTP/client/caller argument makes disabled eligible.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import hmac
import json
import os
import re
import threading
import uuid
import weakref

from native_credentials import CredentialUnavailable, decode_base64
from native_password_credentials import AuthChallengeCodec, advance_issuance_history, MAX_VERSION, PURPOSES

ACCOUNT_QUERY = """SELECT uid, email_normalized, disabled, lifecycle, token_version, email_verified,
 DATE_FORMAT(created_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f')
 FROM clrs_staging.accounts WHERE uid = %s LIMIT 1 FOR UPDATE"""
CHALLENGE_QUERY = """SELECT uid, purpose, challenge_id, email_identity_hmac, code_hmac,
 account_token_version, issue_history,
 DATE_FORMAT(issued_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'),
 DATE_FORMAT(expires_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'), attempts,
 DATE_FORMAT(consumed_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f'), pending_signup_marker,
 DATE_FORMAT(pending_account_created_at, '%%Y-%%m-%%d %%H:%%i:%%s.%%f')
 FROM clrs_staging.native_auth_challenges WHERE uid = %s AND purpose = %s LIMIT 1 FOR UPDATE"""
DB_NOW_QUERY = "SELECT FLOOR(UNIX_TIMESTAMP(UTC_TIMESTAMP(6)))"
PENDING_CREDENTIAL_QUERY = """SELECT
 EXISTS(SELECT 1 FROM clrs_staging.auth_credentials WHERE uid = %s),
 EXISTS(SELECT 1 FROM clrs_staging.native_password_credentials WHERE uid = %s),
 EXISTS(SELECT 1 FROM clrs_staging.auth_identities WHERE uid = %s),
 EXISTS(SELECT 1 FROM clrs_staging.profiles WHERE uid = %s)"""
_CONSUMED = weakref.WeakKeyDictionary()
_CONSUMED_LOCK = threading.Lock()


class ChallengeUnavailable(Exception):
    """Configuration/storage/input failure; no private data in errors."""


@dataclass(frozen=True, repr=False)
class IssuedChallenge:
    uid: str
    purpose: str
    challenge_id: str
    account_token_version: int
    issued_at: int
    expires_at: int


@dataclass(frozen=True, repr=False, eq=False)
class ChallengeTicket:
    uid: str
    purpose: str
    challenge_id: str
    account_token_version: int
    email_identity: bytes
    row_identity: bytes


@dataclass(frozen=True, repr=False, eq=False)
class ConsumedChallengeCapability:
    """Opaque, authentic only when present in this module's private registry."""


@dataclass(frozen=True, repr=False)
class ConsumedChallengeBinding:
    uid: str
    email: str
    token_version: int
    purpose: str
    challenge_id: str
    marker: bytes | None
    account_created_at: str | None
    consumed_at: int


@dataclass(frozen=True, repr=False)
class ChallengeDecision:
    state: str
    challenge: IssuedChallenge | None = None
    ticket: ChallengeTicket | None = None
    attempts: int | None = None
    consumed: ConsumedChallengeCapability | None = None


def _uid(value):
    try:
        if (not isinstance(value, str) or not 1 <= len(value) <= 191
                or len(value.encode('utf-8')) > 764 or any(ord(c) < 32 or ord(c) == 127 for c in value)):
            raise ChallengeUnavailable()
    except UnicodeError:
        raise ChallengeUnavailable() from None


def _identifier(value):
    try:
        identifier = uuid.UUID(value)
        if str(identifier) != value or identifier.version != 4:
            raise ChallengeUnavailable()
    except (TypeError, ValueError, AttributeError):
        raise ChallengeUnavailable() from None


def _timestamp(seconds):
    try:
        return datetime.fromtimestamp(seconds, timezone.utc).strftime('%Y-%m-%d %H:%M:%S.000000')
    except (ValueError, OverflowError, OSError):
        raise ChallengeUnavailable() from None


def _date(value, *, whole=False):
    if (not isinstance(value, str) or re.fullmatch(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}', value) is None
            or (whole and not value.endswith('.000000'))):
        raise ChallengeUnavailable()
    try:
        return int(datetime.strptime(value, '%Y-%m-%d %H:%M:%S.%f').replace(tzinfo=timezone.utc).timestamp())
    except (ValueError, OverflowError):
        raise ChallengeUnavailable() from None


def _blob(value):
    if not isinstance(value, (bytes, bytearray, memoryview)) or len(value) != 32:
        raise ChallengeUnavailable()
    return bytes(value)


def _history(value, issued):
    try:
        if isinstance(value, (str, bytes)):
            if len(value) > 256:
                raise ChallengeUnavailable()
            value = json.loads(value, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if (type(value) is not list or not 1 <= len(value) <= 5
                or any(type(x) is not int or not 0 <= x <= issued for x in value)
                or value[-1] != issued
                or any(value[i+1] - value[i] < 60 for i in range(len(value)-1))):
            raise ChallengeUnavailable()
        return value
    except (ValueError, TypeError, UnicodeError):
        raise ChallengeUnavailable() from None


def _record(row, uid, purpose):
    if row is None:
        return None
    if not isinstance(row, (tuple, list)) or len(row) != 13 or row[0:2] not in ((uid, purpose), [uid, purpose]):
        raise ChallengeUnavailable()
    _identifier(row[2])
    if (type(row[5]) is not int or not 0 <= row[5] <= MAX_VERSION
            or type(row[9]) is not int or not 0 <= row[9] <= 5):
        raise ChallengeUnavailable()
    issued, expires = _date(row[7], whole=True), _date(row[8], whole=True)
    if not 0 <= issued <= 2**53-601 or expires != issued + 600:
        raise ChallengeUnavailable()
    history = _history(row[6], issued)
    consumed = None if row[10] is None else _date(row[10])
    if consumed is not None and consumed < issued:
        raise ChallengeUnavailable()
    marker = None if row[11] is None else _blob(row[11])
    pending_created = row[12]
    if purpose == 'register-email.v1':
        if marker is None or pending_created is None:
            raise ChallengeUnavailable()
        _date(pending_created)
    elif marker is not None or pending_created is not None:
        raise ChallengeUnavailable()
    return {'uid': uid, 'purpose': purpose, 'challenge_id': row[2], 'email_identity': _blob(row[3]),
        'code_hmac': _blob(row[4]), 'version': row[5], 'history': history, 'issued': issued,
        'expires': expires, 'attempts': row[9], 'consumed': consumed, 'marker': marker,
        'pending_created': pending_created}


def _identity(record):
    value = {key: (item.hex() if isinstance(item, bytes) else item) for key, item in record.items()}
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                   separators=(',', ':'), allow_nan=False).encode()).digest()


class NativeAuthChallengeStore:
    def __init__(self, env, codec):
        if not isinstance(codec, AuthChallengeCodec):
            raise ChallengeUnavailable()
        self._env = dict(env); self.codec = codec
        self._tickets = weakref.WeakSet()

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        flag = env.get('CLRS_NATIVE_CHALLENGES_ENABLED')
        if flag in (None, '0'):
            return None
        if flag != '1':
            raise ChallengeUnavailable()
        try:
            result = cls(env, AuthChallengeCodec(decode_base64(env.get('CLRS_NATIVE_SESSION_KEY_B64'), max_bytes=32)))
            result._enabled()
            return result
        except Exception:
            raise ChallengeUnavailable() from None

    def _enabled(self):
        if any(self._env.get(name) != '1' for name in ['CLRS_NATIVE_CHALLENGES_ENABLED',
                'CLRS_NATIVE_AUTH_ENABLED', 'CLRS_NATIVE_AUTH_WRITES_ENABLED', 'CLRS_NATIVE_PASSWORD_ENABLED']):
            raise ChallengeUnavailable()

    def _fields(self, uid, email, purpose, challenge_id, code):
        self._enabled(); _uid(uid); _identifier(challenge_id)
        if (not isinstance(purpose, str) or purpose not in PURPOSES
                or not isinstance(code, str) or re.fullmatch(r'[0-9]{6}', code) is None):
            raise ChallengeUnavailable()
        try:
            return self.codec.email_identity(email)
        except CredentialUnavailable:
            raise ChallengeUnavailable() from None

    @staticmethod
    def _now(cursor, execute):
        execute(DB_NOW_QUERY)
        row = cursor.fetchone()
        if row is None or len(row) != 1:
            raise ChallengeUnavailable()
        value = row[0]
        if isinstance(value, Decimal) and value.is_finite() and value == value.to_integral_value():
            value = int(value)
        if type(value) is not int or not 0 <= value <= 2**53-601:
            raise ChallengeUnavailable()
        return value

    @staticmethod
    def _locked(cursor, execute, uid, purpose):
        if not callable(execute):
            raise ChallengeUnavailable()
        execute(ACCOUNT_QUERY, (uid,)); account = cursor.fetchone()
        if account is not None:
            if (len(account) != 7 or account[0] != uid or type(account[2]) is not int or account[2] not in (0,1)
                    or account[3] not in ('active','blocked','deleted') or type(account[4]) is not int
                    or not 0 <= account[4] <= MAX_VERSION or type(account[5]) is not int or account[5] not in (0,1)):
                raise ChallengeUnavailable()
            _date(account[6])
        execute(CHALLENGE_QUERY, (uid, purpose))
        return account, _record(cursor.fetchone(), uid, purpose)

    @staticmethod
    def _eligible(cursor, execute, account, record, email, purpose):
        if account is None or account[1] != email or account[3] != 'active':
            return False
        if purpose == 'password-reset.v1':
            return account[2] == 0 and account[4] < MAX_VERSION
        if (record is None or record['marker'] is None or record['pending_created'] != account[6]
                or account[2] != 1 or account[4] != 0 or account[5] != 0 or record['version'] != 0):
            return False
        execute(PENDING_CREDENTIAL_QUERY, (account[0],) * 4)
        existing = cursor.fetchone()
        if existing is None or len(existing) != 4 or any(type(x) is not int or x not in (0,1) for x in existing):
            raise ChallengeUnavailable()
        return existing == (0,0,0,0) or existing == [0,0,0,0]

    def lock_for_receipt(self, cursor, execute, *, uid, purpose):
        """Trusted outer phase: lock account/challenge BEFORE receipt begin.

        No code eligibility/attempt/rate charge and no returned private rows.
        Receipt replay/conflict is resolved before issue/check; those repeat
        these same locks on the same cursor, not a new transaction.
        """
        self._enabled(); _uid(uid)
        if not isinstance(purpose, str) or purpose not in PURPOSES:
            raise ChallengeUnavailable()
        self._locked(cursor,execute,uid,purpose)

    def issue(self, cursor, execute, *, uid, email, purpose, code, challenge_id, pending_account=None):
        email_identity = self._fields(uid, email, purpose, challenge_id, code)
        if pending_account is not None and purpose != 'register-email.v1':
            raise ChallengeUnavailable()
        account, old = self._locked(cursor, execute, uid, purpose)
        pending = old
        if pending_account is not None:
            if old is not None:
                raise ChallengeUnavailable()
            try:
                from native_pending_account import validate_pending_account_capability
                binding = validate_pending_account_capability(pending_account,cursor,execute)
                if (binding.uid != uid or binding.email != email or binding.token_version != 0
                        or account is None or binding.account_created_at != account[6]):
                    raise ChallengeUnavailable()
                pending = {'marker':_blob(binding.marker), 'pending_created':binding.account_created_at, 'version':0}
            except Exception:
                raise ChallengeUnavailable() from None
        if not self._eligible(cursor, execute, account, pending, email, purpose):
            return ChallengeDecision('declined')
        now = self._now(cursor, execute)
        if old is not None and (old['issued'] > now or old['challenge_id'] == challenge_id):
            # Operation replay must be resolved through the caller's receipt;
            # a repeated challengeID never rotates or sends a second message.
            return ChallengeDecision('declined')
        try:
            history = advance_issuance_history(old['history'] if old else [], now)
        except CredentialUnavailable:
            return ChallengeDecision('rate_limited')
        digest = self.codec.digest(uid=uid, email=email, purpose=purpose, challenge_id=challenge_id,
            account_token_version=account[4], issued_at=now, expires_at=now+600, code=code)
        params = (challenge_id, email_identity, digest, account[4], json.dumps(history, separators=(',',':')),
                  _timestamp(now), _timestamp(now+600))
        if old is None:
            # Initial signup needs the authentic pending-account capability
            # checked above; an absent row alone supplies no signup authority.
            execute("""INSERT INTO clrs_staging.native_auth_challenges
 (uid,purpose,challenge_id,email_identity_hmac,code_hmac,account_token_version,issue_history,issued_at,expires_at,
 pending_signup_marker,pending_account_created_at)
 VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (uid,purpose,*params,pending['marker'] if pending else None,pending['pending_created'] if pending else None))
        else:
            execute("""UPDATE clrs_staging.native_auth_challenges SET challenge_id=%s,
 email_identity_hmac=%s, code_hmac=%s, account_token_version=%s, issue_history=%s,
 issued_at=%s, expires_at=%s, attempts=0, consumed_at=NULL, updated_at=UTC_TIMESTAMP(6)
 WHERE uid=%s AND purpose=%s""", (*params,uid,purpose))
        if cursor.rowcount != 1:
            raise ChallengeUnavailable()
        execute(CHALLENGE_QUERY,(uid,purpose)); retained=_record(cursor.fetchone(),uid,purpose)
        expected={'uid':uid,'purpose':purpose,'challenge_id':challenge_id,'email_identity':email_identity,
            'code_hmac':digest,'version':account[4],'history':history,'issued':now,'expires':now+600,
            'attempts':0,'consumed':None,'marker':pending['marker'] if pending else None,
            'pending_created':pending['pending_created'] if pending else None}
        if retained != expected:
            raise ChallengeUnavailable()
        return ChallengeDecision('issued',IssuedChallenge(uid,purpose,challenge_id,account[4],now,now+600))

    def _verify_locked(self, cursor, execute, account, record, *, email, purpose, challenge_id, code):
        now=self._now(cursor,execute)
        if (not self._eligible(cursor,execute,account,record,email,purpose) or record is None
                or record['challenge_id'] != challenge_id or record['version'] != account[4]
                or not hmac.compare_digest(record['email_identity'],self.codec.email_identity(email))
                or record['consumed'] is not None or record['attempts'] >= 5
                or not record['issued'] <= now < record['expires']):
            return ChallengeDecision('declined')
        valid=self.codec.verify(record['code_hmac'],now=now,attempts=record['attempts'],consumed=False,
            uid=record['uid'],email=email,purpose=purpose,challenge_id=challenge_id,
            account_token_version=record['version'],issued_at=record['issued'],expires_at=record['expires'],code=code)
        if valid:
            ticket=ChallengeTicket(record['uid'],purpose,challenge_id,record['version'],
                                   record['email_identity'],_identity(record))
            self._tickets.add(ticket)
            return ChallengeDecision('verified',ticket=ticket,attempts=record['attempts'])
        attempts=record['attempts']+1
        execute("""UPDATE clrs_staging.native_auth_challenges SET attempts=%s, updated_at=UTC_TIMESTAMP(6)
 WHERE uid=%s AND purpose=%s AND challenge_id=%s AND attempts=%s AND consumed_at IS NULL""",
                (attempts,record['uid'],purpose,challenge_id,record['attempts']))
        if cursor.rowcount != 1:
            raise ChallengeUnavailable()
        execute(CHALLENGE_QUERY,(record['uid'],purpose)); retained=_record(cursor.fetchone(),record['uid'],purpose)
        if retained != {**record,'attempts':attempts}:
            raise ChallengeUnavailable()
        # Declared refusal, not exception: caller commits this failed attempt
        # WITH its sensitive keyed receipt. This leaf never COMMITs on its own.
        return ChallengeDecision('declined',attempts=attempts)

    def check(self, cursor, execute, *, uid, email, purpose, code, challenge_id):
        self._fields(uid,email,purpose,challenge_id,code)
        account,record=self._locked(cursor,execute,uid,purpose)
        return self._verify_locked(cursor,execute,account,record,email=email,purpose=purpose,
                                   challenge_id=challenge_id,code=code)

    def consume(self, cursor, execute, *, ticket, code):
        self._enabled()
        if type(ticket) is not ChallengeTicket or ticket not in self._tickets:
            raise ChallengeUnavailable()
        account,record=self._locked(cursor,execute,ticket.uid,ticket.purpose)
        if (account is None or record is None or account[4] != ticket.account_token_version
                or not hmac.compare_digest(_identity(record),ticket.row_identity)
                or not hmac.compare_digest(record['email_identity'],ticket.email_identity)):
            return ChallengeDecision('declined')
        self._fields(ticket.uid,account[1],ticket.purpose,ticket.challenge_id,code)
        decision=self._verify_locked(cursor,execute,account,record,email=account[1],purpose=ticket.purpose,
                                    challenge_id=ticket.challenge_id,code=code)
        if decision.state != 'verified':
            return decision
        now=self._now(cursor,execute)
        if now >= record['expires']:
            return ChallengeDecision('declined')
        execute("""UPDATE clrs_staging.native_auth_challenges SET consumed_at=%s, updated_at=UTC_TIMESTAMP(6)
 WHERE uid=%s AND purpose=%s AND challenge_id=%s AND account_token_version=%s
 AND attempts=%s AND consumed_at IS NULL""",
            (_timestamp(now),ticket.uid,ticket.purpose,ticket.challenge_id,ticket.account_token_version,record['attempts']))
        if cursor.rowcount != 1:
            raise ChallengeUnavailable()
        execute(CHALLENGE_QUERY,(ticket.uid,ticket.purpose)); retained=_record(cursor.fetchone(),ticket.uid,ticket.purpose)
        if retained != {**record,'consumed':now}:
            raise ChallengeUnavailable()
        self._tickets.discard(ticket)
        capability=ConsumedChallengeCapability()
        binding=ConsumedChallengeBinding(ticket.uid,account[1],ticket.account_token_version,ticket.purpose,
            ticket.challenge_id,record['marker'],record['pending_created'],now)
        with _CONSUMED_LOCK:
            _CONSUMED[capability]=(weakref.ref(self),cursor,execute,binding,_identity(retained))
        return ChallengeDecision('consumed',attempts=record['attempts'],consumed=capability)


def validate_consumed_challenge_capability(capability, cursor, execute):
    """One-use trusted completion authority, before activation/reset writes.

    Caller must use a NEW cursor and captured execute callable for each outer
    transaction; never reuse those identities across COMMIT/rollback. This leaf
    has no transaction lifecycle observer. Consumed proof is not a durable
    receipt and must never be serialized, stored, sent to clients or replayed.
    """
    if type(capability) is not ConsumedChallengeCapability:
        raise ChallengeUnavailable()
    with _CONSUMED_LOCK:
        registered=_CONSUMED.pop(capability,None)
    if registered is None:
        raise ChallengeUnavailable()
    owner_ref, original_cursor, original_execute, binding, identity=registered
    owner=owner_ref()
    if owner is None or cursor is not original_cursor or execute is not original_execute:
        raise ChallengeUnavailable()
    owner._enabled()
    account,record=owner._locked(cursor,execute,binding.uid,binding.purpose)
    if (account is None or record is None or account[4] != binding.token_version
            or account[1] != binding.email or record['consumed'] != binding.consumed_at
            or not hmac.compare_digest(_identity(record),identity)
            or not owner._eligible(cursor,execute,account,record,binding.email,binding.purpose)):
        raise ChallengeUnavailable()
    return binding
