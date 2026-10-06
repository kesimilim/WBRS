"""Prepared registration/reset request transaction; no HTTP, SMTP or flags.

Caller owns verified TLS/schema/role and bounded fresh SERIALIZABLE transactions.
Signup requires a trusted current/final source-account authority callback: a
stale legacy snapshot's absence is NOT authority. No legacy JSON is scanned by
this leaf. Production factory must keep signup off until that separate gate and
full Auth/canonical import proof exist. Optional issue_budget is a trusted SQL
budget seam; peer/global abuse policy, valid SMTP and delivery are separate.
All accepted replies have the same202/opaque UUID shape, including ineligible,
blocked/unknown accounts and budget/issuance refusal. Only encrypted mail intent
is enqueued; this change cannot claim successful delivery.
"""
from __future__ import annotations

from dataclasses import dataclass
import math
import secrets
import time
import uuid

from native_sessions import NativeSessionStore
from native_auth_challenges import NativeAuthChallengeStore
from native_auth_receipts import (SensitiveAuthReceipts, AuthReceiptFingerprint,
    AuthReceiptOutcome, AuthReceiptResolution)
from native_auth_mail_outbox import NativeAuthMailOutbox
from native_mail import NativeMailIntent
from native_pending_account import create_pending_account


_LOOKUP = """SELECT uid FROM clrs_staging.accounts
 WHERE email_normalized = %s LIMIT 2 FOR UPDATE"""


class AuthRequestUnavailable(Exception):
    """Generic invalid configuration/input; never exposes private context."""


@dataclass(frozen=True, repr=False)
class AuthRequestResult:
    state: str
    fingerprint: AuthReceiptFingerprint
    outcome: AuthReceiptOutcome | None = None
    requires_lookup: bool = False


class NativeAuthRequest:
    def __init__(self, store, challenges, receipts, outbox, *, transaction=None,
                 source_account_exists=None, issue_budget=None, monotonic=time.monotonic):
        if (not isinstance(store, NativeSessionStore)
                or not isinstance(challenges, NativeAuthChallengeStore)
                or not isinstance(receipts, SensitiveAuthReceipts)
                or not isinstance(outbox, NativeAuthMailOutbox) or outbox.challenges is not challenges
                or not callable(monotonic) or any(value is not None and not callable(value)
                    for value in (transaction, source_account_exists, issue_budget))):
            raise AuthRequestUnavailable()
        self._store = store; self._challenges = challenges; self._receipts = receipts
        self._outbox = outbox; self._transaction = transaction
        self._source_account_exists = source_account_exists; self._issue_budget = issue_budget
        self._clock = monotonic

    def _remaining(self, deadline):
        if type(deadline) not in (int, float) or not math.isfinite(deadline):
            raise AuthRequestUnavailable()
        remaining = deadline - self._clock()
        if not 0 < remaining <= 8:
            raise AuthRequestUnavailable()
        return remaining

    def _run(self, action, deadline):
        self._remaining(deadline)
        def bounded(cursor, raw_execute):
            if cursor is None or not callable(raw_execute):
                raise AuthRequestUnavailable()
            count = 0
            def execute(sql, params=()):
                nonlocal count
                self._remaining(deadline); count += 1
                if count > 64:
                    raise AuthRequestUnavailable()
                raw_execute(sql, params)
                self._remaining(deadline)
            result = action(cursor, execute)
            self._remaining(deadline)
            return result
        if self._transaction is None:
            result = self._store._transaction(lambda cursor: bounded(cursor,
                lambda sql, params=(): self._store._execute(cursor, sql, params, deadline=deadline)),
                deadline=deadline)
        else:
            result = self._transaction(bounded, deadline=deadline)
        self._remaining(deadline)
        return result

    @staticmethod
    def _result(fingerprint, resolution):
        return AuthRequestResult(resolution.state, fingerprint, resolution.outcome,
                                 resolution.state != 'completed')

    def request(self, *, email, purpose, operation_id, deadline):
        """Bind original email bytes, resolve canonical account only in SQL.

        Email/operation are request data; caller supplies purpose/deadline. No
        UID/challenge/code input or plaintext password is accepted. Replay uses
        the stable email actor even after account activation/email changes.
        """
        try:
            self._remaining(deadline)
            if purpose not in ('register-email.v1', 'password-reset.v1') or not isinstance(email, str):
                raise AuthRequestUnavailable()
            canonical = email.strip().lower()
            fingerprint = self._receipts.bind(purpose[:-3] + '.request.v1', operation_id,
                actor_uid=None, email_identity=self._challenges.codec.email_identity(canonical),
                purpose=purpose, challenge_id=None, payload={'email': email})
            challenge_id = str(uuid.uuid4())
            candidate_uid = str(uuid.uuid4())
            code = str(secrets.randbelow(1_000_000)).zfill(6)
        except Exception:
            raise AuthRequestUnavailable() from None
        try:
            def action(cursor, execute):
                execute(_LOOKUP, (canonical,))
                rows = cursor.fetchall()
                if (not isinstance(rows, (tuple, list)) or len(rows) > 1
                        or any(not isinstance(row, (tuple, list)) or len(row) != 1 for row in rows)):
                    raise AuthRequestUnavailable()
                native_uid = None if not rows else rows[0][0]
                uid = candidate_uid if native_uid is None else native_uid
                # Lock account/challenge before receipt, including UID/gap locks
                # for the prospective account. This does not create authority.
                self._challenges.lock_for_receipt(cursor, execute, uid=uid, purpose=purpose)
                lease = self._receipts.begin(cursor, execute, fingerprint)
                if type(lease) is AuthReceiptResolution:
                    return lease
                accepted = AuthReceiptOutcome('accepted', challenge_id)
                if self._issue_budget is not None:
                    allowed = self._issue_budget(cursor, execute)
                    if type(allowed) is not bool:
                        raise AuthRequestUnavailable()
                    if not allowed:
                        return self._receipts.finish(lease, accepted)
                pending = None
                if purpose == 'register-email.v1':
                    if self._source_account_exists is None:
                        raise AuthRequestUnavailable()
                    if native_uid is None:
                        source_exists = self._source_account_exists(cursor, execute, canonical)
                        if type(source_exists) is not bool:
                            raise AuthRequestUnavailable()
                        if source_exists:
                            return self._receipts.finish(lease, accepted)
                        pending = create_pending_account(cursor, execute, uid=uid, email=canonical)
                if native_uid is None and pending is None:
                    return self._receipts.finish(lease, accepted)
                issued = self._challenges.issue(cursor, execute, uid=uid, email=canonical,
                    purpose=purpose, code=code, challenge_id=challenge_id, pending_account=pending)
                if issued.state == 'issued':
                    intent = NativeMailIntent(canonical,
                        'verify-email' if purpose == 'register-email.v1' else 'reset-password', code, challenge_id)
                    queued = self._outbox.enqueue(cursor, execute, issued=issued.challenge, intent=intent)
                    if queued.state not in ('queued', 'already_queued'):
                        raise AuthRequestUnavailable()
                elif pending is not None or issued.state not in ('declined', 'rate_limited'):
                    # A new reservation must never commit without its initial
                    # pending marker/challenge and encrypted mail intent.
                    raise AuthRequestUnavailable()
                return self._receipts.finish(lease, accepted)
            return self._result(fingerprint, self._run(action, deadline))
        except Exception:
            # No exception proves rollback; only original digest lookup may
            # reconcile. Never retry reserve/issue/enqueue automatically.
            return AuthRequestResult('unavailable', fingerprint, requires_lookup=True)

    def lookup(self, fingerprint, *, deadline):
        """Digest-only reconciliation; absence/pending never authorize issue."""
        try:
            self._remaining(deadline)
            return self._result(fingerprint, self._run(
                lambda cursor, execute: self._receipts.lookup(cursor, execute, fingerprint), deadline))
        except Exception:
            if type(fingerprint) is not AuthReceiptFingerprint:
                raise AuthRequestUnavailable() from None
            return AuthRequestResult('unavailable', fingerprint, requires_lookup=True)
