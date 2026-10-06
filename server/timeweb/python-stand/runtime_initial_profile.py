"""Initial own profile finish; existing blank row + three proved native photos.

No new profile/media rows or retained-source changes. The photo SQL service is
shared with uploads; no writer/lease is invoked by this operation.
"""
from __future__ import annotations

import json

from runtime_mutations import (RuntimeInvalidRequest, RuntimeRejected,
    RuntimeUnavailable, RECEIPT_QUERY, canonical_json, request_digest)
from runtime_profile import (_FIELDS, _FULL_SELECT, _full_profile, _full_onboarding,
    _stamp, validate_profile_edit)
from runtime_geography import resolve_geography
from runtime_profile_photo_uploads import (RuntimeProfilePhotoUploadsService,
    PhotoUploadTargetRejected, COMMIT_OPERATION, AUTHORITY, _uuid, validate_commit,
    photo_identity)


OPERATION = "profile.finish-registration.v1"
_ERRORS = {"profile_not_found": 404, "photo_not_found": 404, "photo_not_ready": 409}
_STAMP_ERRORS = frozenset({"profile_changed", "registration_already_saved", "registration_already_completed"})
_SELECT = _FULL_SELECT.replace("FOR SHARE", "FOR UPDATE")


class InitialProfileAccessRejected(RuntimeRejected):
    """Healthy actor has lost current target/proof; original intent stays unknown."""


def validate_finish(payload):
    if (type(payload) is not dict or set(payload) != {"expectedUpdatedAt", "changes", "geography", "photos"}
            or type(payload["changes"]) is not dict or set(payload["changes"]) != set(_FIELDS)
            or type(payload["photos"]) is not list or len(payload["photos"]) != 3):
        raise RuntimeInvalidRequest()
    checked = validate_profile_edit({"expectedUpdatedAt": payload["expectedUpdatedAt"], "changes": payload["changes"]})
    checked["geography"] = resolve_geography(payload["geography"])
    for photo in payload["photos"]:
        if type(photo) is not dict or set(photo) != {"mediaId", "prepareOperationId", "commitOperationId"}:
            raise RuntimeInvalidRequest()
        validate_commit({name: photo[name] for name in ("mediaId", "prepareOperationId")})
        _uuid(photo["commitOperationId"])
    if any(len({photo[name] for photo in payload["photos"]}) != 3
           for name in ("mediaId", "prepareOperationId", "commitOperationId")):
        raise RuntimeInvalidRequest()
    # Immutable original bytes, including whitespace, are the receipt hash.
    return checked, json.loads(canonical_json(payload))


class RuntimeInitialProfileService:
    def __init__(self, store, *, photos):
        if (not isinstance(photos, RuntimeProfilePhotoUploadsService) or photos._store is not store):
            raise RuntimeUnavailable()
        self._store = store; self._photos = photos
        store.register_replay_guard(OPERATION, self._guard, response_guard=True, operation_id_guard=True)

    def _photo_proofs(self, cursor, execute, uid, photos):
        for proof in photos:
            request = {name: proof[name] for name in ("mediaId", "prepareOperationId")}
            if request["mediaId"] != photo_identity(uid, request["prepareOperationId"])[0]:
                return "photo_not_found"
            context = self._photos._context(cursor, execute, uid, request)
            if "error" in context: return context["error"]
            if context["status"] != "ready": return "photo_not_ready"
            execute(RECEIPT_QUERY + " FOR SHARE", (uid, COMMIT_OPERATION, proof["commitOperationId"]))
            row = cursor.fetchone()
            if row is None: return "photo_not_ready"
            status, wrapper, revision = self._store._receipt(row, request_digest(request))
            photo = next((item for item in context["photos"] if item[0] == request["mediaId"]), None)
            response = wrapper["response"]
            if (status != 200 or revision is not None or wrapper["request"] != request or photo is None
                    or set(response) != {"mediaId", "ready", "ordinal", "isPrimary", "updatedAt", "profileAuthority"}
                    or response["mediaId"] != request["mediaId"] or response["ready"] is not True
                    or type(response["ordinal"]) is not int or response["ordinal"] != photo[1]
                    or type(response["isPrimary"]) is not bool or response["isPrimary"] != bool(photo[2])
                    or response["profileAuthority"] != AUTHORITY or _stamp(response["updatedAt"]) > context["updatedAt"]):
                return "photo_not_ready"
        return None

    def _guard(self, cursor, execute, uid, op, request, response):
        validate_finish(request); _uuid(op)
        error = response.get("error")
        if set(response) == {"error"} and error in _ERRORS: return
        if set(response) == {"error", "updatedAt"} and error in _STAMP_ERRORS:
            _stamp(response["updatedAt"]); return
        execute(_FULL_SELECT, (uid, uid)); row = cursor.fetchone()
        if row is None: raise InitialProfileAccessRejected()
        current = _full_profile(row)
        if (set(response) != {"uid", "profileDetailsSaved", "onboarding", "updatedAt", "profileAuthority"}
                or response["uid"] != uid or response["profileDetailsSaved"] is not True
                or response["onboarding"] != "test" or response["profileAuthority"] != AUTHORITY
                or current["profileDetailsSaved"] is not True
                or _stamp(response["updatedAt"]) <= request["expectedUpdatedAt"]
                or response["updatedAt"] > current["updatedAt"]):
            raise InitialProfileAccessRejected()
        try: error = self._photo_proofs(cursor, execute, uid, request["photos"])
        except PhotoUploadTargetRejected: raise InitialProfileAccessRejected() from None
        if error: raise InitialProfileAccessRejected()
        execute(RECEIPT_QUERY + " FOR SHARE", (uid, OPERATION, op))
        status, wrapper, revision = self._store._receipt(cursor.fetchone(), request_digest(request))
        if status != 200 or revision is not None or wrapper != {"request": request, "response": response}:
            raise InitialProfileAccessRejected()

    def finish(self, identity, operation_id, payload, *, access_token):
        _uuid(operation_id); checked, request = validate_finish(payload)
        def action(cursor, execute, uid):
            execute(_SELECT, (uid, uid)); row = cursor.fetchone()
            if row is None: return 404, {"error": "profile_not_found"}, None
            before = _full_profile(row)
            if before["updatedAt"] != checked["expectedUpdatedAt"]:
                return 409, {"error": "profile_changed", "updatedAt": before["updatedAt"]}, None
            if _full_onboarding(before) == "search":
                return 409, {"error": "registration_already_completed", "updatedAt": before["updatedAt"]}, None
            if before["profileDetailsSaved"] is True:
                return 409, {"error": "registration_already_saved", "updatedAt": before["updatedAt"]}, None
            # Nullable/legacy flags are not a proved native blank profile.
            if before["profileDetailsSaved"] is not False or before["isRegistrationEnd"] is not False:
                raise InitialProfileAccessRejected()
            try: error = self._photo_proofs(cursor, execute, uid, request["photos"])
            except PhotoUploadTargetRejected: error = "photo_not_ready"
            if error: return _ERRORS[error], {"error": error}, None
            fields = {**checked["changes"], **checked["geography"]}
            columns = {**_FIELDS, "country": "country", "countryCode": "country_code", "region": "region"}
            names = list(fields)
            execute("UPDATE clrs_staging.profiles SET " + ", ".join(columns[name] + " = %s" for name in names)
                + ", profile_details_saved = 1, updated_at = GREATEST(UTC_TIMESTAMP(6), updated_at + INTERVAL 1 MICROSECOND)"
                " WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)"
                " AND updated_at = CAST(%s AS DATETIME(6)) AND profile_details_saved = 0 AND registration_complete = 0",
                tuple(fields[name] for name in names) + (uid, uid, before["updatedAt"][:-1].replace("T", " ")))
            if cursor.rowcount != 1: raise RuntimeUnavailable()
            execute(_SELECT, (uid, uid)); after = _full_profile(cursor.fetchone())
            if (any(after[name] != value for name, value in fields.items()) or after["profileDetailsSaved"] is not True
                    or after["updatedAt"] <= before["updatedAt"] or _full_onboarding(after) != "test"
                    or any(after[name] != value for name, value in before.items()
                           if name not in set(fields) | {"profileDetailsSaved", "updatedAt"})):
                raise RuntimeUnavailable()
            if self._photo_proofs(cursor, execute, uid, request["photos"]): raise RuntimeUnavailable()
            return 200, {"uid": uid, "profileDetailsSaved": True, "onboarding": "test",
                "updatedAt": after["updatedAt"], "profileAuthority": AUTHORITY}, None
        return self._store.mutate(identity, OPERATION, operation_id, request, action, access_token=access_token)
