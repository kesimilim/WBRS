"""Operator-signed all-15 final acceptance; never a meeting-only readiness claim.

No issuer, I/O, SQL or provider call. Only a separately reviewed final assembler
may derive this metadata from genuine post-barrier capture and fresh readback.
The immutable archival/media baseline remains independent.
"""
from __future__ import annotations

import hashlib
import hmac
import re
import weakref
from datetime import datetime, timezone
from pathlib import Path

from imported_meeting_authority import ImportedMeetingAuthority
from native_credentials import decode_base64, unique_json
from runtime_mutations import RuntimeUnavailable, canonical_json

DOMAIN = b"clrs-final-runtime-readiness-v1\0"
INPUTS = ("CLRS_FINAL_RUNTIME_ACK_B64", "CLRS_FINAL_RUNTIME_MANIFEST_SHA256")
TABLES = frozenset({"accounts", "profiles", "auth_credentials", "auth_identities",
    "meetings", "meeting_members", "meeting_messages", "gift_catalog", "posts",
    "post_comments", "post_likes", "comment_likes", "wall_entries", "wallets",
    "gift_inventory"})
_BINDING = {"generation", "sourceSha256", "cohortSha256", "policy",
    "barrierSha256", "finalDeltaSha256"}
_DIGESTS = {"manifestSha256", "generation", "sourceCaptureSha256",
    "canonicalReadbackCipherSha256", "canonicalReadbackRowsSha256",
    "consumerSourceSha256"}
_FIELDS = _DIGESTS | {"kind", "version", "tableCounts", "importedBinding", "acceptedAt"}
_CAPS = weakref.WeakKeyDictionary()
_SHA = re.compile(r"[a-f0-9]{64}\Z")
_STAMP = re.compile(r"[1-9][0-9]{3}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\Z")


def consumer_source_fingerprint():
    root = Path(__file__).parent
    return hashlib.sha256(canonical_json({name:
        hashlib.sha256((root / name).read_bytes()).hexdigest()
        for name in ("app.py", "final_runtime_readiness.py")})).hexdigest()


class FinalRuntimeAcceptance:
    def require(self, authority, binding, env):
        body = _CAPS.get(self)
        if (body is None or type(authority) is not ImportedMeetingAuthority
                or type(binding) is not dict
                or body["importedBinding"] != binding
                or body["manifestSha256"] != env.get(INPUTS[1])
                or body["consumerSourceSha256"] != consumer_source_fingerprint()):
            raise RuntimeUnavailable()
        # The imported capability independently checked its signed real writer
        # barrier, complete final delta, cohort and current server source pins.
        authority.require(binding)


def load_final_runtime_acceptance(env, *, authority, binding, clock=None):
    if all(name not in env for name in INPUTS):
        return None
    try:
        if type(authority) is not ImportedMeetingAuthority or type(binding) is not dict:
            raise RuntimeUnavailable()
        authority.require(binding)
        expected = env.get(INPUTS[1])
        if type(expected) is not str or _SHA.fullmatch(expected) is None:
            raise RuntimeUnavailable()
        key = decode_base64(env.get("CLRS_IMPORTED_MEETINGS_AUTHORITY_KEY_B64"), max_bytes=32)
        raw = decode_base64(env.get(INPUTS[0]), max_bytes=16384)
        if len(key) != 32 or not 1 <= len(raw) <= 16384:
            raise RuntimeUnavailable()
        envelope = unique_json(raw.decode("utf-8"))
        if type(envelope) is not dict or set(envelope) != {"body", "hmacSha256"}:
            raise RuntimeUnavailable()
        body, signature = envelope["body"], envelope["hmacSha256"]
        if (type(body) is not dict or set(body) != _FIELDS
                or type(signature) is not str or _SHA.fullmatch(signature) is None
                or not hmac.compare_digest(signature,
                    hmac.digest(key, DOMAIN + canonical_json(body), "sha256").hex())):
            raise RuntimeUnavailable()
        if (type(body["version"]) is not int or body["version"] != 1
                or body["kind"] != "clrs-final-runtime-readiness-v1"
                or any(type(body[name]) is not str or _SHA.fullmatch(body[name]) is None
                    for name in _DIGESTS)
                or body["manifestSha256"] != expected
                or type(body["importedBinding"]) is not dict
                or set(body["importedBinding"]) != _BINDING
                or body["importedBinding"] != binding
                or body["generation"] != binding["generation"]
                or body["consumerSourceSha256"] != consumer_source_fingerprint()):
            raise RuntimeUnavailable()
        counts = body["tableCounts"]
        if (type(counts) is not dict or set(counts) != TABLES
                or any(type(value) is not int or not 0 <= value <= 2**63 - 1
                    for value in counts.values())):
            raise RuntimeUnavailable()
        stamp = body["acceptedAt"]
        if type(stamp) is not str or _STAMP.fullmatch(stamp) is None:
            raise RuntimeUnavailable()
        accepted = datetime.fromisoformat(stamp[:-1] + "+00:00")
        now = datetime.now(timezone.utc) if clock is None else clock()
        if now.tzinfo is None or accepted > now:
            raise RuntimeUnavailable()
        cap = FinalRuntimeAcceptance()
        _CAPS[cap] = unique_json(canonical_json(body).decode("utf-8"))
        cap.require(authority, binding, env)
        return cap
    except Exception:
        raise RuntimeUnavailable() from None
