"""Exact old importer projection; private exclusions never grant resource access."""
import hashlib
from imported_meeting_review import _ROOT_FIELDS, _uids, _string, _schedule, _opaque_fields, SOURCE_CONTRACT
from legacy_conversation_payload import document, payload_digest, string_field, identifier
from runtime_mutations import RuntimeUnavailable
from runtime_meetings import MEETING_FIELDS
from runtime_people import _uid


def require(value):
    if not value:
        raise RuntimeUnavailable()


def source_members(fields):
    # Validate the unique active source list, but preserve its original indexes.
    _uids(fields, "users", required=True)
    users = [item["stringValue"] for item in fields["users"]["arrayValue"].get("values", [])]
    value = fields.get("kicked")
    if value is None and "kicked" not in fields:
        return users, None
    require(type(value) is dict and set(value) == {"arrayValue"}
        and type(value["arrayValue"]) is dict and not set(value["arrayValue"]) - {"values"})
    entries = value["arrayValue"].get("values", [])
    require(type(entries) is list and len(entries) <= 1000)
    kicked = []
    for item in entries:
        require(type(item) is dict and set(item) == {"stringValue"})
        kicked.append(_uid(item["stringValue"]))
    # The original literal array stays in the root hash. Only denial is a set.
    return users, sorted(set(kicked), key=lambda uid: uid.encode())


def source_geography(fields):
    _string(fields, "country")  # Private source cache, no inferred catalog code.
    code, region, city = (_string(fields, name) for name in ("countryCode", "region", "city"))
    return code, city if region is None else region


def source_sender(payload):
    fields = payload["fields"]
    first, second = string_field(fields, "sendByID"), string_field(fields, "sender")
    require(not (first and second and first != second))
    return identifier(second if second is not None else first, uid=True)


def project_entries(inputs):
    """Pure literal validation AFTER genuine whole-core readback; no signing."""
    from imported_meeting_authority import digest, reviewed_message
    capture, readback = inputs["sourceCapture"], inputs["canonicalReadback"]
    accounts = readback["currentAccountUids"]
    require(type(accounts) is list and len(accounts) <= 20000
        and accounts == sorted(set(accounts), key=lambda uid: uid.encode()))
    for uid in accounts:
        _uid(uid)
    account_set, entries, flat_messages, flat_exclusions = set(accounts), [], [], []
    for mid in inputs["reviewedRoots"]:
        payload = document(capture["roots"][mid]); fields = payload["fields"]
        require(not set(fields) - _ROOT_FIELDS); _opaque_fields(fields)
        original_users, kicked = source_members(fields)
        missing = mid in inputs.get("missingKickedReviewed", [])
        require(kicked is not None or (missing and "kicked" not in fields))
        kicked = kicked or []; require(not set(original_users) & set(kicked))
        users = sorted(original_users, key=lambda uid: uid.encode())
        row = readback["roots"][mid]
        expected = {key: row[key] for key in (*MEETING_FIELDS[:12], "localDatetime")}
        require(_schedule(fields)[:2] == (row["localDatetime"], row["startsAt"])
            and source_geography(fields) == (row["countryCode"], row["region"])
            and row["organizerUid"] == _string(fields, "admin", required=True)
            and row["kind"] == {"групповая": "group", "индивидуальная": "individual"}[_string(fields, "type", required=True)]
            and row["invitedUid"] == _string(fields, "invitedUid")
            and row["title"] == _string(fields, "name", 1000, controls=True)
            and row["description"] == _string(fields, "description", 4096, controls=True)
            and payload_digest(document(row["legacy_raw"])) == payload_digest(payload))
        hashed = payload_digest(payload); members = readback["members"][mid]
        normalized = {uid for uid in original_users if uid in account_set and uid not in kicked}
        require(set(members) == normalized)
        excluded_members = []
        for index, uid in enumerate(original_users):
            if uid not in account_set:
                excluded_members.append({"uid": uid, "sourceIndex": index, "reason": "meeting_member_account_missing"})
                continue
            member = members[uid]
            require(member["uid"] == uid and member["joinedAt"] is None
                and member["leftAt"] is None and member["kickedAt"] is None
                and member["membershipRevision"] == 0
                and member["legacy_raw"] == {"source_path": "meets/" + mid, "source_index": index,
                    "source_field": "users", "source_payload_hash": hashed})
        children = capture["messages"].get(mid, {}); messages = readback["messages"].get(mid, [])
        require(type(children) is dict and len(children) <= 65536)
        excluded_children, expected_ids = [], set()
        for message_id, raw in sorted(children.items(), key=lambda item: item[0].encode()):
            child = document(raw); sender = source_sender(child)
            reason = ("message_sender_account_missing" if sender not in account_set else
                "message_sender_not_explicit_member" if sender not in normalized else
                "message_invalid" if child["fields"].get("message") == {"stringValue": ""}
                    and not set(child["fields"]) & {"image", "giftNoticeId", "giftNoticeName", "sharedContent"} else None)
            if reason:
                excluded_children.append({"messageId": message_id, "firebasePath": "meets/" + mid + "/messages/" + message_id,
                    "payloadSha256": payload_digest(child), "senderUid": sender, "reason": reason})
            else:
                expected_ids.add(message_id)
        require({msg["messageId"] for msg in messages} == expected_ids and len(messages) == len(expected_ids))
        pins = []
        for sequence, msg in enumerate(sorted(messages, key=lambda value: value["sequence"]), 1):
            pin = reviewed_message(mid, msg["messageId"], children[msg["messageId"]], sequence)
            require(msg["sequence"] == sequence and msg["senderUid"] in normalized and msg["mediaId"] is None
                and all(msg[key] == pin[key] for key in ("messageId", "senderUid", "createdAt"))
                and hashlib.sha256(msg["text"].encode()).hexdigest() == pin["textSha256"]
                and payload_digest(document(msg["legacy_raw"])) == pin["payloadSha256"])
            pins.append(pin); flat_messages.append([mid, pin])
        exclusions = {"memberExclusions": excluded_members, "childExclusions": excluded_children}
        entries.append({"meetingId": mid, "firebasePath": "meets/" + mid, "payloadSha256": hashed,
            "metadataReviewSha256": digest({"source": hashed, "canonical": expected, "members": members,
                "currentAccountUidsSha256": digest(accounts), **exclusions}),
            "sourceContract": SOURCE_CONTRACT, "canonical": expected,
            "users": users, "sourceUserOrder": original_users, "kicked": kicked,
            "missingKickedReviewed": missing, "messages": pins, **exclusions})
        flat_exclusions.append([mid, exclusions])
    return entries, flat_messages, flat_exclusions, digest(accounts)
