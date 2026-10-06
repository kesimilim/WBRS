"""Prepared sensitive-auth receipt leaf; no HTTP, connections or COMMIT.

The caller owns bounded SERIALIZABLE SQL and account -> challenge -> receipt
locking, current eligibility, challenge consumption and all effects in that SAME
transaction. Check replay BEFORE charging attempts/issuance or sending mail.
Unknown COMMIT permits only lookup of the original fingerprint: neither pending
nor absent is authority to repeat effects. No raw email/password/code is stored.
Requests ALWAYS use actor_uid=None/email-HMAC, both before and after pending
signup reservation. Completions use the UID resolved from the ORIGINAL trusted
challenge. Reconcile must preserve that scope, not resolve a new actor/epoch.
Never hold/commit a started receipt around KDF: valid-code first TX only checks
and snapshots, KDF runs outside SQL, second TX rechecks -> begin -> consumes and
changes credentials -> finish. Invalid-code attempt charging and its completed
refusal receipt belong in the same first TX. Orchestration is NOT this leaf.
"""
from __future__ import annotations

from dataclasses import dataclass
import hmac
import json
import re
import uuid

from native_credentials import unique_json, CredentialUnavailable

OPERATIONS = frozenset({"password-reset.request.v1", "password-reset.complete.v1",
    "register-email.request.v1", "register-email.complete.v1"})
MAX_PAYLOAD_BYTES = 8192
_QUERY = """SELECT context_hmac, request_hmac, state, response_status, response,
 completed_at FROM clrs_staging.native_auth_receipts
 WHERE actor_identity_hmac = %s AND operation = %s AND operation_id = %s LIMIT 1"""


class AuthReceiptInvalid(Exception):
    """Invalid local input; never includes sensitive request/configuration."""


class AuthReceiptConflict(Exception):
    """Same actor/operation/UUID was bound to different original input."""


class AuthReceiptUnavailable(Exception):
    """Malformed SQL/readback or failed leaf operation; caller must rollback."""


def _uuid(value):
    try:
        parsed = uuid.UUID(value) if isinstance(value, str) else None
        if parsed is None or str(parsed) != value or parsed.version != 4:
            raise AuthReceiptInvalid()
        return value
    except (ValueError, TypeError, AttributeError):
        raise AuthReceiptInvalid() from None


def _text(value, maximum):
    try:
        if not isinstance(value, str) or len(value.encode("utf-8")) > maximum:
            raise AuthReceiptInvalid()
        return value
    except UnicodeError:
        raise AuthReceiptInvalid() from None


def _json(value):
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True,
                          separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (UnicodeError, TypeError, ValueError, RecursionError):
        raise AuthReceiptInvalid() from None


@dataclass(frozen=True, repr=False)
class AuthReceiptFingerprint:
    operation: str
    operation_id: str
    actor_identity: bytes
    context_digest: bytes
    request_digest: bytes
    _seal: bytes


@dataclass(frozen=True, repr=False)
class AuthReceiptOutcome:
    """Only these fixed non-secret responses are persistable."""
    kind: str
    challenge_id: str | None = None

    @property
    def status(self):
        return {"accepted": 202, "completed": 200, "refused": 400}[self.kind]

    @property
    def result(self):
        value = {"status": self.kind}
        if self.kind == "accepted":
            value["challengeId"] = self.challenge_id
        return value


@dataclass(frozen=True, repr=False)
class AuthReceiptResolution:
    state: str  # completed | pending | not_found; only completed has a response.
    outcome: AuthReceiptOutcome | None = None


@dataclass(frozen=True, repr=False)
class _ReceiptLease:
    fingerprint: AuthReceiptFingerprint
    cursor: object
    execute: object
    owner: object


class SensitiveAuthReceipts:
    def __init__(self, server_key):
        if not isinstance(server_key, bytes) or len(server_key) != 32:
            raise AuthReceiptInvalid()
        root = hmac.digest(server_key, b"CLRS sensitive-auth receipts v1", "sha256")
        self._actor_key = hmac.digest(root, b"actor", "sha256")
        self._context_key = hmac.digest(root, b"context", "sha256")
        self._request_key = hmac.digest(root, b"original-request", "sha256")
        self._seal_key = hmac.digest(root, b"fingerprint-seal", "sha256")
        self._owner = object()

    def _seal(self, operation, operation_id, actor, context, request):
        return hmac.digest(self._seal_key, _json([operation, operation_id,
            actor.hex(), context.hex(), request.hex()]), "sha256")

    def bind(self, operation, operation_id, *, actor_uid, email_identity,
             purpose, challenge_id, payload):
        """Caller supplies original stable context, not a post-reset UID/epoch.

        Payload excludes operationId (bound separately) and is never retained.
        Every request uses actor_uid=None/email-HMAC as its stable actor scope;
        completion uses original challenge UID so changed bindings conflict.
        Email HMAC is from AuthChallengeCodec, not an unkeyed email hash.
        """
        _uuid(operation_id)
        if (type(operation) is not str or operation not in OPERATIONS
                or purpose != operation.rsplit(".", 2)[0] + ".v1"):
            raise AuthReceiptInvalid()
        if actor_uid is not None:
            if (not isinstance(actor_uid, str) or not 1 <= len(actor_uid) <= 191
                    or any(ord(c) < 32 or ord(c) == 127 for c in actor_uid)):
                raise AuthReceiptInvalid()
            _text(actor_uid, 764)
        if not isinstance(email_identity, bytes) or len(email_identity) != 32:
            raise AuthReceiptInvalid()
        request = operation.endswith(".request.v1")
        if request:
            if (actor_uid is not None or challenge_id is not None
                    or type(payload) is not dict or set(payload) != {"email"}):
                raise AuthReceiptInvalid()
            _text(payload["email"], 1280)
            if not 1 <= len(payload["email"]) <= 320:
                raise AuthReceiptInvalid()
        else:
            if actor_uid is None:
                raise AuthReceiptInvalid()
            _uuid(challenge_id)
            if type(payload) is not dict or set(payload) != {"challengeId", "code", "password"}:
                raise AuthReceiptInvalid()
            if payload["challengeId"] != challenge_id:
                raise AuthReceiptInvalid()
            _text(payload["password"], 4096)
            if not isinstance(payload["code"], str) or re.fullmatch(r"[0-9]{6}", payload["code"]) is None:
                raise AuthReceiptInvalid()
        raw = _json(payload)
        if len(raw) > MAX_PAYLOAD_BYTES:
            raise AuthReceiptInvalid()
        actor = hmac.digest(self._actor_key, _json(["uid", actor_uid] if actor_uid is not None
                                                 else ["email", email_identity.hex()]), "sha256")
        context = hmac.digest(self._context_key, _json([operation, actor_uid,
            email_identity.hex(), purpose, challenge_id]), "sha256")
        # Preserve original spaces/case/Unicode, never trim/normalize passwords.
        digest = hmac.digest(self._request_key, _json([operation, operation_id,
            context.hex()]) + b"\0" + raw, "sha256")
        return AuthReceiptFingerprint(operation, operation_id, actor, context, digest,
            self._seal(operation, operation_id, actor, context, digest))

    def _fingerprint(self, fingerprint):
        if (type(fingerprint) is not AuthReceiptFingerprint
                or type(fingerprint.operation) is not str or fingerprint.operation not in OPERATIONS):
            raise AuthReceiptInvalid()
        _uuid(fingerprint.operation_id)
        if any(not isinstance(x, bytes) or len(x) != 32 for x in [fingerprint.actor_identity,
                fingerprint.context_digest, fingerprint.request_digest, fingerprint._seal]):
            raise AuthReceiptInvalid()
        if not hmac.compare_digest(fingerprint._seal, self._seal(fingerprint.operation,
                fingerprint.operation_id, fingerprint.actor_identity,
                fingerprint.context_digest, fingerprint.request_digest)):
            raise AuthReceiptInvalid()

    @staticmethod
    def _outcome(operation, outcome):
        if type(outcome) is not AuthReceiptOutcome:
            raise AuthReceiptInvalid()
        if operation.endswith(".request.v1"):
            if outcome.kind != "accepted":
                raise AuthReceiptInvalid()
            _uuid(outcome.challenge_id)
        elif outcome.kind not in ("completed", "refused") or outcome.challenge_id is not None:
            raise AuthReceiptInvalid()
        return outcome

    @staticmethod
    def _params(fingerprint):
        return (fingerprint.actor_identity, fingerprint.operation, fingerprint.operation_id)

    def _read(self, cursor, execute, fingerprint, *, lock):
        execute(_QUERY + (" FOR UPDATE" if lock else ""), self._params(fingerprint))
        row = cursor.fetchone()
        if row is None:
            return AuthReceiptResolution("not_found")
        if not isinstance(row, (tuple, list)) or len(row) != 6:
            raise AuthReceiptUnavailable()
        context, request, state, status, response, completed = row
        if any(not isinstance(x, (bytes, bytearray, memoryview)) or len(x) != 32
               for x in (context, request)):
            raise AuthReceiptUnavailable()
        if (not hmac.compare_digest(bytes(context), fingerprint.context_digest)
                or not hmac.compare_digest(bytes(request), fingerprint.request_digest)):
            raise AuthReceiptConflict()
        if state == "started":
            if (status, response, completed) != (None, None, None):
                raise AuthReceiptUnavailable()
            return AuthReceiptResolution("pending")
        if state != "completed" or completed is None or type(status) is not int:
            raise AuthReceiptUnavailable()
        try:
            if isinstance(response, (str, bytes)):
                if len(response) > 256:
                    raise AuthReceiptUnavailable()
                response = unique_json(response)
            if type(response) is not dict or set(response) not in ({"status"}, {"status", "challengeId"}):
                raise AuthReceiptUnavailable()
            outcome = self._outcome(fingerprint.operation,
                AuthReceiptOutcome(response.get("status"), response.get("challengeId")))
            if response != outcome.result or status != outcome.status:
                raise AuthReceiptUnavailable()
            return AuthReceiptResolution("completed", outcome)
        except (AuthReceiptInvalid, CredentialUnavailable, TypeError, ValueError):
            raise AuthReceiptUnavailable() from None

    def begin(self, cursor, execute, fingerprint):
        """Only a returned lease permits NEW effects in this caller transaction."""
        self._fingerprint(fingerprint)
        if not callable(execute):
            raise AuthReceiptInvalid()
        retained = self._read(cursor, execute, fingerprint, lock=True)
        if retained.state != "not_found":
            return retained
        execute("""INSERT INTO clrs_staging.native_auth_receipts
          (actor_identity_hmac, operation, operation_id, context_hmac, request_hmac, state)
          VALUES (%s, %s, %s, %s, %s, 'started')""", (*self._params(fingerprint),
            fingerprint.context_digest, fingerprint.request_digest))
        if cursor.rowcount != 1 or self._read(cursor, execute, fingerprint, lock=True).state != "pending":
            raise AuthReceiptUnavailable()
        return _ReceiptLease(fingerprint, cursor, execute, self._owner)

    def finish(self, lease, outcome):
        if type(lease) is not _ReceiptLease or lease.owner is not self._owner:
            raise AuthReceiptInvalid()
        fingerprint = lease.fingerprint
        self._fingerprint(fingerprint)
        self._outcome(fingerprint.operation, outcome)
        if self._read(lease.cursor, lease.execute, fingerprint, lock=True).state != "pending":
            raise AuthReceiptUnavailable()
        lease.execute("""UPDATE clrs_staging.native_auth_receipts SET state = 'completed',
          response_status = %s, response = %s, completed_at = UTC_TIMESTAMP(6)
          WHERE actor_identity_hmac = %s AND operation = %s AND operation_id = %s
          AND context_hmac = %s AND request_hmac = %s AND state = 'started'""",
          (outcome.status, _json(outcome.result).decode(), *self._params(fingerprint),
           fingerprint.context_digest, fingerprint.request_digest))
        if lease.cursor.rowcount != 1:
            raise AuthReceiptUnavailable()
        retained = self._read(lease.cursor, lease.execute, fingerprint, lock=True)
        if retained.state != "completed" or retained.outcome != outcome:
            raise AuthReceiptUnavailable()
        return retained

    def lookup(self, cursor, execute, fingerprint):
        """Read only. not_found/pending NEVER authorizes repeat effects."""
        self._fingerprint(fingerprint)
        if not callable(execute):
            raise AuthReceiptInvalid()
        return self._read(cursor, execute, fingerprint, lock=False)
