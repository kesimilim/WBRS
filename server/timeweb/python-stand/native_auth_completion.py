"""Prepared two-phase auth completion; no HTTP/factory/flag/mail integration.

UID/email and deadline are resolved by the trusted caller, not request authority.
The transaction seam must provide fresh exclusive cursor/execute in bounded
SERIALIZABLE SQL with reviewed TLS/schema/role and atomic COMMIT/rollback. The
default wraps NativeSessionStore's existing transaction; its role/schema gates
are NOT expanded here. A lifecycle schema/role and HTTP/global-abuse/mail seam
remain prerequisites. No exception proves rollback: unavailable requires an
explicit lookup of the returned original digest fingerprint, never auto retry.
"""
from __future__ import annotations

from dataclasses import dataclass
import math
import time

from native_sessions import NativeSessionStore
from native_password_credentials import PasswordWorkPool
from native_auth_challenges import (NativeAuthChallengeStore, ChallengeTicket,
    validate_consumed_challenge_capability)
from native_auth_receipts import (SensitiveAuthReceipts, AuthReceiptFingerprint,
    AuthReceiptOutcome, AuthReceiptResolution)
from native_password_transition import apply_prepared_reset
from native_pending_account import complete_pending_registration


class AuthCompletionUnavailable(Exception):
    """Generic invalid configuration/input; no request/config in errors."""


@dataclass(frozen=True, repr=False)
class AuthCompletionResult:
    state: str
    fingerprint: AuthReceiptFingerprint
    outcome: AuthReceiptOutcome | None = None
    requires_lookup: bool = False


@dataclass(frozen=True, repr=False)
class _Candidate:
    ticket: ChallengeTicket
    password_version: int


class NativeAuthCompletion:
    def __init__(self, store, pool, challenges, receipts, *, transaction=None,
                 monotonic=time.monotonic):
        if (not isinstance(store, NativeSessionStore) or not isinstance(pool, PasswordWorkPool)
                or store._password_selector is not pool
                or not isinstance(challenges, NativeAuthChallengeStore)
                or not isinstance(receipts, SensitiveAuthReceipts)
                or not callable(monotonic) or (transaction is not None and not callable(transaction))):
            raise AuthCompletionUnavailable()
        self._store = store; self._pool = pool; self._challenges = challenges
        self._receipts = receipts; self._transaction = transaction; self._clock = monotonic

    def _remaining(self, deadline):
        if type(deadline) not in (int, float) or not math.isfinite(deadline):
            raise AuthCompletionUnavailable()
        remaining = deadline - self._clock()
        if not 0 < remaining <= 8:
            raise AuthCompletionUnavailable()
        return remaining

    def _run(self, action, deadline, cursors):
        self._remaining(deadline)
        def bounded(cursor, raw_execute):
            if cursor is None or not callable(raw_execute) or any(cursor is old for old in cursors):
                raise AuthCompletionUnavailable()
            cursors.append(cursor)
            count = 0
            def execute(sql, params=()):
                nonlocal count
                self._remaining(deadline)
                count += 1
                if count > 64:
                    raise AuthCompletionUnavailable()
                raw_execute(sql, params)
                self._remaining(deadline)
            result = action(cursor, execute)
            self._remaining(deadline)
            return result
        if self._transaction is not None:
            result = self._transaction(bounded, deadline=deadline)
        else:
            result = self._store._transaction(
                lambda cursor: bounded(cursor, lambda sql, params=(): self._store._execute(
                    cursor, sql, params, deadline=deadline)), deadline=deadline)
        self._remaining(deadline)
        return result

    @staticmethod
    def _result(fingerprint, resolution):
        return AuthCompletionResult(resolution.state, fingerprint, resolution.outcome,
                                    resolution.state != 'completed')

    def complete(self, *, uid, email, purpose, operation_id, challenge_id, code, password, deadline):
        """One attempt. Only encrypted prepared material crosses the KDF phases.

        A completed result may be an exact replay (including a prior refusal).
        Pending/unavailable is never application authority. Fingerprint context
        stays original across reset/email/version changes and contains no raw
        UID/email/password/code. Never call this as an automatic error retry.
        """
        try:
            self._remaining(deadline)
            if purpose not in ('register-email.v1', 'password-reset.v1'):
                raise AuthCompletionUnavailable()
            operation = purpose[:-3] + '.complete.v1'
            fingerprint = self._receipts.bind(operation, operation_id, actor_uid=uid,
                email_identity=self._challenges.codec.email_identity(email), purpose=purpose,
                challenge_id=challenge_id,
                payload={'challengeId': challenge_id, 'code': code, 'password': password})
        except Exception:
            raise AuthCompletionUnavailable() from None
        cursors = []
        try:
            def first(cursor, execute):
                self._challenges.lock_for_receipt(cursor, execute, uid=uid, purpose=purpose)
                replay = self._receipts.lookup(cursor, execute, fingerprint)
                if replay.state != 'not_found':
                    return replay
                checked = self._challenges.check(cursor, execute, uid=uid, email=email,
                    purpose=purpose, code=code, challenge_id=challenge_id)
                if checked.state != 'verified':
                    lease = self._receipts.begin(cursor, execute, fingerprint)
                    if type(lease) is AuthReceiptResolution:
                        return lease
                    return self._receipts.finish(lease, AuthReceiptOutcome('refused'))
                ticket = checked.ticket
                if type(ticket) is not ChallengeTicket:
                    raise AuthCompletionUnavailable()
                version = 0 if purpose == 'register-email.v1' else ticket.account_token_version + 1
                return _Candidate(ticket, version)
            first_result = self._run(first, deadline, cursors)
            if type(first_result) is AuthReceiptResolution:
                return self._result(fingerprint, first_result)
            if type(first_result) is not _Candidate:
                raise AuthCompletionUnavailable()
            prepared = self._pool.prepare(uid, first_result.password_version, password,
                timeout=min(1.5, self._remaining(deadline)))
            self._remaining(deadline)
            def second(cursor, execute):
                self._challenges.lock_for_receipt(cursor, execute, uid=uid, purpose=purpose)
                lease = self._receipts.begin(cursor, execute, fingerprint)
                if type(lease) is AuthReceiptResolution:
                    return lease
                consumed = self._challenges.consume(cursor, execute, ticket=first_result.ticket, code=code)
                if consumed.state != 'consumed':
                    return self._receipts.finish(lease, AuthReceiptOutcome('refused'))
                if purpose == 'register-email.v1':
                    # This leaf itself validates/consumes the authentic same-TX
                    # signup capability before any credential/profile write.
                    complete_pending_registration(cursor, execute, self._pool.native_codec,
                        consumed_challenge=consumed.consumed, prepared_row=prepared)
                else:
                    binding = validate_consumed_challenge_capability(consumed.consumed, cursor, execute)
                    if (binding.uid != uid or binding.email != email or binding.purpose != purpose
                            or binding.challenge_id != challenge_id
                            or binding.token_version != first_result.ticket.account_token_version):
                        raise AuthCompletionUnavailable()
                    apply_prepared_reset(cursor, execute, self._pool.native_codec, uid=uid, email=email,
                        expected_token_version=binding.token_version, prepared_row=prepared)
                return self._receipts.finish(lease, AuthReceiptOutcome('completed'))
            return self._result(fingerprint, self._run(second, deadline, cursors))
        except Exception:
            # Includes conflict, timeout, KDF failure and unknown COMMIT. Do not
            # infer which transaction committed or issue a new apply lease.
            return AuthCompletionResult('unavailable', fingerprint, requires_lookup=True)

    def lookup(self, fingerprint, *, deadline):
        """Original digest-only reconciliation. Never checks a code or applies."""
        try:
            self._remaining(deadline)
            return self._result(fingerprint, self._run(
                lambda cursor, execute: self._receipts.lookup(cursor, execute, fingerprint), deadline, []))
        except Exception:
            if type(fingerprint) is not AuthReceiptFingerprint:
                raise AuthCompletionUnavailable() from None
            return AuthCompletionResult('unavailable', fingerprint, requires_lookup=True)
