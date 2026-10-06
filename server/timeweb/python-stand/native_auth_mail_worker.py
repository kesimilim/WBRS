"""Default-off, one-shot transactional auth mail; no loop/automatic retry.

Trusted specific UID/purpose/challenge only, never a caller-selected recipient or
template. Enable/configure nothing here: from_env checks the worker flag before
missing dependencies. The caller supplies one shared SMTP transport and bounded
SERIALIZABLE TLS/schema/role transaction runner with fresh connection/cursor per
phase. NativeSessionStore._transaction is the prepared default runner; its role
and lifecycle schema gates are NOT expanded here.

Claim COMMIT must return ACK; then different-connection verification COMMIT must
return ACK/release all SQL locks before SMTP. Unknown either -> NO SEND even if a
row may exist. SMTP is called once with the verified absolute <=8s deadline.
Failed/unknown SMTP parks the one attempted row; unknown finish COMMIT is never
retried and never sends again. A failed parking TX leaves attempts1/started, which
is already ineligible. Explicit read-only/operator reconciliation is separate.
No SMTP env enable, secrets, routes, grants or live connections on construction.
The default 32s budget is background-only, never synchronous HTTP work. A future
dispatcher must pass its original absolute <=8s deadline; dispatch never resets
that budget. Each SQL phase is <=8s and SMTP retains its shared actual-I/O slot.
"""
from __future__ import annotations

from dataclasses import dataclass
import math
import threading
import time

from native_sessions import NativeSessionStore
from native_auth_mail_outbox import (NativeAuthMailOutbox, AuthMailClaim,
                                    VerifiedAuthMailDelivery)
from native_auth_challenges import _uid, _identifier
from native_password_credentials import PURPOSES
from native_mail import NativeMailTransport, MailUnavailable, MailOutcomeUnknown


class AuthMailWorkerUnavailable(Exception):
    """Generic configuration/input refusal with no private values."""


@dataclass(frozen=True, repr=False)
class AuthMailWorkerResult:
    state: str
    phase: str
    smtp_attempted: bool = False
    requires_reconcile: bool = False


class NativeAuthMailWorker:
    def __init__(self, env, store, outbox, transport, *, transaction=None, monotonic=time.monotonic):
        if (not isinstance(store, NativeSessionStore) or not isinstance(outbox, NativeAuthMailOutbox)
                or not isinstance(transport, NativeMailTransport) or not callable(monotonic)
                or (transaction is not None and not callable(transaction))):
            raise AuthMailWorkerUnavailable()
        self._env = dict(env); self._store = store; self._outbox = outbox
        self._transport = transport; self._transaction = transaction; self._clock = monotonic
        self._slots = threading.BoundedSemaphore(1)

    @classmethod
    def from_env(cls, env, store=None, outbox=None, transport=None, **options):
        flag = env.get('CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED')
        if flag in (None, '0'):
            return None
        if flag != '1':
            raise AuthMailWorkerUnavailable()
        result = cls(env, store, outbox, transport, **options)
        result._enabled()
        return result

    def _enabled(self):
        if (self._env.get('CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED') != '1'
                or self._env.get('CLRS_MAIL_ENABLED') != '1'):
            raise AuthMailWorkerUnavailable()
        self._outbox.challenges._enabled()

    def _remaining(self, deadline):
        if type(deadline) not in (int, float) or not math.isfinite(deadline):
            raise AuthMailWorkerUnavailable()
        remaining = deadline - self._clock()
        if not 0 < remaining <= 32:
            raise AuthMailWorkerUnavailable()
        return remaining

    @staticmethod
    def _cancelled(cancel_event):
        if cancel_event is not None and cancel_event.is_set():
            raise AuthMailWorkerUnavailable()

    def _run(self, action, deadline, connections, cancel_event):
        self._cancelled(cancel_event)
        phase_deadline = self._clock() + min(8, self._remaining(deadline))
        def bounded(cursor, raw_execute):
            connection = getattr(cursor, 'connection', None)
            if (cursor is None or connection is None or not callable(raw_execute)
                    or any(connection is old for old in connections)):
                raise AuthMailWorkerUnavailable()
            connections.append(connection)
            count = 0
            def execute(sql, params=()):
                nonlocal count
                self._cancelled(cancel_event)
                count += 1
                if count > 32 or self._clock() >= phase_deadline:
                    raise AuthMailWorkerUnavailable()
                raw_execute(sql, params)
                self._cancelled(cancel_event)
                if self._clock() >= phase_deadline:
                    raise AuthMailWorkerUnavailable()
            result = action(cursor, execute)
            self._cancelled(cancel_event)
            if self._clock() >= phase_deadline:
                raise AuthMailWorkerUnavailable()
            return result
        if self._transaction is not None:
            result = self._transaction(bounded, deadline=phase_deadline)
        else:
            result = self._store._transaction(lambda cursor: bounded(cursor,
                lambda sql, params=(): self._store._execute(cursor, sql, params, deadline=phase_deadline)),
                deadline=phase_deadline)
        if self._clock() >= phase_deadline:
            raise AuthMailWorkerUnavailable()
        self._cancelled(cancel_event)
        self._remaining(deadline)
        return result

    def run_once(self, *, uid, purpose, challenge_id, deadline=None, cancel_event=None):
        """Invoke once only. Any uncertain result requires separate reconciliation."""
        self._enabled()
        try:
            _uid(uid); _identifier(challenge_id)
            if not isinstance(purpose, str) or purpose not in PURPOSES:
                raise AuthMailWorkerUnavailable()
            deadline = self._clock() + 32 if deadline is None else deadline
            self._remaining(deadline)
            if cancel_event is not None and not isinstance(cancel_event, threading.Event):
                raise AuthMailWorkerUnavailable()
            self._cancelled(cancel_event)
        except Exception:
            raise AuthMailWorkerUnavailable() from None
        if not self._slots.acquire(blocking=False):
            return AuthMailWorkerResult('busy', 'claim')
        try:
            # The shared transport retains a timed-out actual SMTP worker slot.
            # Avoid claiming another row while that cleanup is still active.
            with self._transport._lock:
                if self._transport._closed or self._transport._active is not None:
                    return AuthMailWorkerResult('busy', 'claim')
            connections = []
            try:
                started = self._run(lambda c, e: self._outbox.start_delivery(c, e,
                    uid=uid, purpose=purpose, challenge_id=challenge_id), deadline, connections, cancel_event)
                if started.state != 'started' or type(started.claim) is not AuthMailClaim:
                    return AuthMailWorkerResult('declined', 'retired' if started.retired else 'claim')
                claim = started.claim
            except Exception:
                return AuthMailWorkerResult('unknown', 'claim', requires_reconcile=True)
            try:
                delivery = self._run(lambda c, e: self._outbox.verify_committed_claim(c, e, claim,
                    commit_state='acknowledged'), deadline, connections, cancel_event)
                if delivery is None:
                    outcome = 'failed'; attempted = False
                else:
                    if type(delivery) is not VerifiedAuthMailDelivery:
                        raise AuthMailWorkerUnavailable()
                    delivery.remaining_seconds()
                    self._remaining(deadline)
                    self._cancelled(cancel_event)
                    outcome = None; attempted = False
            except Exception:
                # Never extract/send an intent after an uncertain verify ACK.
                return AuthMailWorkerResult('unknown', 'verify', requires_reconcile=True)
            if outcome is None:
                try:
                    delivery.remaining_seconds()
                    self._remaining(deadline)
                    # Also respect the outer one-shot deadline, without resetting
                    # the verified expiry budget or mutating transport._seconds.
                    absolute = min(delivery._deadline, deadline)
                    self._cancelled(cancel_event)
                    attempted = True
                    result = self._transport.deliver(delivery.intent, deadline=absolute)
                    if (type(result) is not dict or set(result) != {'deliveryId', 'smtpAccepted'}
                            or result['deliveryId'] != challenge_id or result['smtpAccepted'] is not True):
                        outcome = 'unknown'
                    else:
                        outcome = 'accepted'
                except MailOutcomeUnknown:
                    outcome = 'unknown'
                except MailUnavailable:
                    outcome = 'failed'
                except Exception:
                    # A foreign/malformed transport error cannot prove no DATA.
                    outcome = 'unknown' if attempted else 'failed'
            try:
                finished = self._run(lambda c, e: self._outbox.finish_delivery(c, e, claim,
                    outcome=outcome), deadline, connections, cancel_event)
                if finished.state != outcome:
                    raise AuthMailWorkerUnavailable()
            except Exception:
                return AuthMailWorkerResult('unknown', 'finish', attempted, True)
            return AuthMailWorkerResult(outcome, 'finish', attempted, outcome == 'unknown')
        finally:
            self._slots.release()
