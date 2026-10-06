"""Default-off single background auth-mail dispatcher; explicit start only.

HTTP may call wake(), never run the 32s delivery synchronously. One daemon polls
every five seconds and selects ONE original queued current eligible challenge;
worker rechecks account/challenge/AEAD/HMAC under its own transaction locks.
Selection never yields recipient/code/template or any arbitrary mail input.

Unknown SQL/SMTP/finish or an unretired declined row parks/halt: no automatic
retry, no self-healing claim. The worker can retire an obsolete exact immutable
AEAD row without SEND; only ACK of that retirement permits draining the next.
Operator read-only reconciliation and deliberate restart are separate. Declared
failed delivery is attempted1 and skipped; replaced/expired/consumed rows are
filtered before LIMIT so an obsolete first row does not block the queue.

Shutdown owner MUST close the shared NativeMailTransport before close()/join:
that aborts actual I/O, wipes its credential and closes the cancel-check->deliver
race. Dispatcher sets worker cancellation, rejects later wakes/starts and joins
boundedly; it never owns/recreates SMTP credentials or an SMTP worker pool.
No start/send/schema/flags/live connection happens in construction.
"""
from __future__ import annotations

import threading
import time

from native_auth_mail_worker import NativeAuthMailWorker, AuthMailWorkerResult
from native_auth_challenges import _uid, _identifier
from native_password_credentials import PURPOSES, MAX_VERSION


_NEXT = """SELECT c.uid, c.purpose, c.challenge_id
 FROM clrs_staging.outbox AS o
 JOIN clrs_staging.native_auth_challenges AS c
   ON c.uid = o.audience_uid
  AND o.outbox_id = CONCAT('auth-mail:', c.challenge_id)
  AND o.source_event_id = o.outbox_id
 JOIN clrs_staging.accounts AS a ON a.uid = c.uid
 WHERE o.channel = 'email' AND o.event_kind = 'auth.challenge.mail.v1'
   AND o.attempts = 0 AND o.delivered_at IS NULL AND o.last_error_code IS NULL
   AND o.available_at <= UTC_TIMESTAMP(6)
   AND c.account_token_version = a.token_version AND a.lifecycle = 'active'
   AND c.attempts < 5 AND c.consumed_at IS NULL
   AND c.issued_at <= UTC_TIMESTAMP(6)
   AND c.expires_at > UTC_TIMESTAMP(6) + INTERVAL 8 SECOND
   AND ((c.purpose = 'password-reset.v1' AND a.disabled = 0 AND a.token_version < %s)
    OR (c.purpose = 'register-email.v1' AND a.disabled = 1 AND a.email_verified = 0
        AND a.token_version = 0 AND c.account_token_version = 0
        AND OCTET_LENGTH(c.pending_signup_marker) = 32
        AND c.pending_account_created_at = a.created_at
        AND NOT EXISTS (SELECT 1 FROM clrs_staging.auth_credentials AS ac WHERE ac.uid = a.uid)
        AND NOT EXISTS (SELECT 1 FROM clrs_staging.native_password_credentials AS nc WHERE nc.uid = a.uid)
        AND NOT EXISTS (SELECT 1 FROM clrs_staging.auth_identities AS ai WHERE ai.uid = a.uid)
        AND NOT EXISTS (SELECT 1 FROM clrs_staging.profiles AS p WHERE p.uid = a.uid)))
 ORDER BY o.available_at ASC, o.outbox_id ASC LIMIT 1"""


class AuthMailDispatcherUnavailable(Exception):
    """Generic configuration/selection refusal, no private SQL or mail values."""


class NativeAuthMailDispatcher:
    def __init__(self, env, worker, *, transaction=None, monotonic=time.monotonic):
        if (not isinstance(worker, NativeAuthMailWorker) or not callable(monotonic)
                or transaction is not None and not callable(transaction)):
            raise AuthMailDispatcherUnavailable()
        self._env = dict(env); self._worker = worker
        self._transaction = transaction; self._clock = monotonic
        self._closed = threading.Event(); self._wake = threading.Event()
        self._lock = threading.Lock(); self._pump_slot = threading.BoundedSemaphore(1)
        self._thread = None; self._started = False; self._halted = False

    @classmethod
    def from_env(cls, env, worker=None, **options):
        flag = env.get('CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED')
        if flag in (None, '0'):
            return None
        if flag != '1':
            raise AuthMailDispatcherUnavailable()
        result = cls(env, worker, **options); result._enabled()
        return result

    def _enabled(self):
        if self._env.get('CLRS_NATIVE_AUTH_MAIL_WORKER_ENABLED') != '1':
            raise AuthMailDispatcherUnavailable()
        self._worker._enabled()

    @property
    def halted(self):
        with self._lock:
            return self._halted

    def start(self):
        """Explicit lifecycle start; never create a second daemon."""
        self._enabled()
        with self._lock:
            if self._closed.is_set() or self._halted:
                raise AuthMailDispatcherUnavailable()
            if self._started:
                return False
            self._started = True
            self._thread = threading.Thread(target=self._loop, daemon=True, name='clrs-auth-mail-dispatch')
            try:
                self._thread.start()
            except Exception:
                self._halted = True
                raise AuthMailDispatcherUnavailable() from None
            self._wake.set()  # Read queued intents already present at startup.
            return True

    def wake(self):
        """Nonblocking HTTP seam, no SQL or SMTP on this calling thread."""
        with self._lock:
            if self._closed.is_set() or self._halted or not self._started:
                return False
            self._wake.set(); return True

    def close(self):
        """Bounded join; owner closes shared transport BEFORE calling this."""
        self._closed.set(); self._wake.set()
        with self._lock:
            thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=1)
        return thread is None or not thread.is_alive()

    def _select(self):
        deadline = self._clock() + 8
        def action(cursor, execute):
            if self._closed.is_set() or self._clock() >= deadline or not callable(execute):
                raise AuthMailDispatcherUnavailable()
            execute(_NEXT, (MAX_VERSION,))
            if self._closed.is_set() or self._clock() >= deadline:
                raise AuthMailDispatcherUnavailable()
            rows = cursor.fetchall()
            if (not isinstance(rows, (tuple, list)) or len(rows) > 1
                    or rows and (not isinstance(rows[0], (tuple, list)) or len(rows[0]) != 3)):
                raise AuthMailDispatcherUnavailable()
            if not rows:
                return None
            uid, purpose, challenge_id = rows[0]
            _uid(uid); _identifier(challenge_id)
            if not isinstance(purpose, str) or purpose not in PURPOSES:
                raise AuthMailDispatcherUnavailable()
            return uid, purpose, challenge_id
        if self._transaction is None:
            store = self._worker._store
            result = store._transaction(lambda c: action(c,
                lambda sql, params=(): store._execute(c, sql, params, deadline=deadline)), deadline=deadline)
        else:
            result = self._transaction(action, deadline=deadline)
        if self._closed.is_set() or self._clock() >= deadline:
            raise AuthMailDispatcherUnavailable()
        return result

    def _pump_once(self):
        if self._closed.is_set() or self.halted or not self._pump_slot.acquire(blocking=False):
            return 'stopped'
        try:
            selected = self._select()
            if selected is None:
                return 'empty'
            if self._closed.is_set():
                return 'stopped'
            uid, purpose, challenge_id = selected
            result = self._worker.run_once(uid=uid, purpose=purpose, challenge_id=challenge_id,
                                          deadline=self._clock()+32, cancel_event=self._closed)
            if (type(result) is not AuthMailWorkerResult or result.state == 'unknown'
                    or result.requires_reconcile):
                raise AuthMailDispatcherUnavailable()
            if result.state == 'declined' and result.phase == 'retired':
                return 'retired'
            if result.state not in ('accepted', 'failed', 'busy'):
                raise AuthMailDispatcherUnavailable()
            return result.state
        except Exception:
            if not self._closed.is_set():
                with self._lock:
                    self._halted = True
            return 'stopped' if self._closed.is_set() else 'halted'
        finally:
            self._pump_slot.release()

    def _loop(self):
        while not self._closed.is_set():
            self._wake.wait(5); self._wake.clear()
            if self._closed.is_set() or self.halted:
                return
            state = self._pump_once()
            if state in ('halted', 'stopped'):
                return
            if state in ('accepted', 'failed', 'retired') and not self._closed.is_set():
                self._wake.set()  # Drain different queued intents, never retry a claimed one.
