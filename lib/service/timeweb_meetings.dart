part of 'timeweb_auth_client.dart';

final class TimewebMeetingCreateRequest {
  TimewebMeetingCreateRequest._(this._fields);
  final Map<String, dynamic> _fields;
  static Future<TimewebMeetingCreateRequest> fromCatalog({required String name,
    required String description, required String countryCode, required String region,
    required String datetime, required String type, String? invitedUid}) async {
    if (!_currentNullableText(name, 1000) || name.trim().isEmpty ||
        !_currentNullableText(description, 4096) || !_meetingLocalDatetime(datetime) ||
        !const ['групповая', 'индивидуальная'].contains(type) ||
        (type == 'индивидуальная' ? !_currentIdentifier(invitedUid) : invitedUid != null)) {
      throw ArgumentError('Invalid native meeting request.');
    }
    await TimewebGeographyChanges.fromCatalog(countryCode: countryCode, region: region);
    return TimewebMeetingCreateRequest._(Map.unmodifiable({'name': name, 'description': description,
      'countryCode': countryCode, 'region': region, 'datetime': datetime, 'type': type,
      if (invitedUid != null) 'invitedUid': invitedUid}));
  }
  Map<String, dynamic> get fields => _fields;
  @override
  String toString() => 'TimewebMeetingCreateRequest(<redacted>)';
}

bool _meetingLocalDatetime(Object? value) {
  if (value is! String || !RegExp(r'^[0-9]{2}\.[0-9]{2}\.[0-9]{4} [0-9]{2}:[0-9]{2}$').hasMatch(value)) return false;
  final day = int.parse(value.substring(0, 2)), month = int.parse(value.substring(3, 5));
  final year = int.parse(value.substring(6, 10)), hour = int.parse(value.substring(11, 13)), minute = int.parse(value.substring(14));
  final date = DateTime.utc(year, month, day, hour, minute);
  return year >= 1 && year <= 9999 && date.year == year && date.month == month && date.day == day && date.hour == hour && date.minute == minute;
}

// Imported read schedules keep the original local literal or one canonical SQL UTC stamp.
bool _meetingReadSchedule(Object? local, Object? utc) {
  if (local == null) {
    return utc is String && utc.endsWith('Z') && _mutationStamp(utc) && int.parse(utc.substring(0, 4)) >= 1000;
  }
  if (utc != null || local is! String) { return false; }
  final match = RegExp(r'^([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4}) ([0-9]{1,2}):([0-9]{2})$').firstMatch(local);
  if (match == null || match.end != local.length) { return false; }
  final day = int.parse(match[1]!), month = int.parse(match[2]!), year = int.parse(match[3]!);
  final hour = int.parse(match[4]!), minute = int.parse(match[5]!);
  final date = DateTime.utc(year, month, day, hour, minute);
  return year >= 1 && year <= 9999 && date.year == year && date.month == month && date.day == day && date.hour == hour && date.minute == minute;
}

int _meetingCompareSchedule(String? leftTime, String leftId, String? rightTime, String rightId) {
  if (leftTime != rightTime) {
    if (leftTime == null) { return -1; }
    if (rightTime == null) { return 1; }
    return leftTime.compareTo(rightTime);
  }
  return _currentCompareIds(leftId, rightId);
}

final class TimewebMeetingCreateReceipt {
  TimewebMeetingCreateReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingCreateReceipt bindSessionGuard(void Function() guard) =>
      TimewebMeetingCreateReceipt._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  bool get created => _read('created');
  int get meetingRevision => _read('meetingRevision');
  String get localDatetime => _read('localDatetime');
  @override
  String toString() => 'TimewebMeetingCreateReceipt(<redacted>)';
}

final class TimewebMeetingJoinRequest {
  TimewebMeetingJoinRequest({required this.meetingId}) {
    if (!_meetingIdentifier(meetingId)) throw ArgumentError('Invalid native meeting.');
  }
  final String meetingId;
  @override
  String toString() => 'TimewebMeetingJoinRequest(<redacted>)';
}

final class TimewebMeetingJoinReceipt {
  TimewebMeetingJoinReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingJoinReceipt bindSessionGuard(void Function() guard) =>
      TimewebMeetingJoinReceipt._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  bool get joined => _read('joined');
  bool get alreadyMember => _read('alreadyMember');
  int get membershipRevision => _read('membershipRevision');
  @override
  String toString() => 'TimewebMeetingJoinReceipt(<redacted>)';
}

final class TimewebMeetingLeaveRequest {
  TimewebMeetingLeaveRequest({required this.meetingId}) {
    if (!_meetingIdentifier(meetingId)) throw ArgumentError('Invalid native meeting.');
  }
  final String meetingId;
  @override
  String toString() => 'TimewebMeetingLeaveRequest(<redacted>)';
}
final class TimewebMeetingKickRequest {
  TimewebMeetingKickRequest({required this.meetingId, required this.targetUid}) {
    TimewebMeetingLeaveRequest(meetingId: meetingId);
    if (!_currentIdentifier(targetUid)) throw ArgumentError('Invalid native participant.');
  }
  final String meetingId, targetUid;
  @override
  String toString() => 'TimewebMeetingKickRequest(<redacted>)';
}
final class TimewebMeetingLeaveReceipt {
  TimewebMeetingLeaveReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingLeaveReceipt bindSessionGuard(void Function() guard) =>
      TimewebMeetingLeaveReceipt._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  bool get left => _read('left');
  bool get alreadyLeft => _read('alreadyLeft');
  int? get membershipRevision => _read('membershipRevision');
  String? get leftAt => _read('leftAt');
  @override
  String toString() => 'TimewebMeetingLeaveReceipt(<redacted>)';
}
final class TimewebMeetingKickReceipt {
  TimewebMeetingKickReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingKickReceipt bindSessionGuard(void Function() guard) =>
      TimewebMeetingKickReceipt._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  String get targetUid => _read('targetUid');
  bool get kicked => _read('kicked');
  bool get alreadyKicked => _read('alreadyKicked');
  int get membershipRevision => _read('membershipRevision');
  String get kickedAt => _read('kickedAt');
  String get leftAt => _read('leftAt');
  @override
  String toString() => 'TimewebMeetingKickReceipt(<redacted>)';
}

// One bounded generation per client, separate from auth/receipt ownership. An
// ACK retires held meeting reads, including empty pages and late responses.
final _meetingGenerations = Expando<int>();
final _meetingFlightChecks = Expando<void Function()>();
void _invalidateMeetingReads(TimewebAuthClient owner) => _meetingGenerations[owner] = (_meetingGenerations[owner] ?? 0) + 1;
void Function() _meetingReadCheck(_PeopleFlight f) => _meetingFlightChecks[f]!;
bool _meetingMembershipKind(TimewebMutationKind kind) =>
    kind == TimewebMutationKind.leaveMeeting || kind == TimewebMutationKind.kickMeetingParticipant;

TimewebMutationResult _decodeMeetingMembership(TimewebMutationReference ref, int status, Map<String, dynamic> value, int? revision, bool replayed) {
  final leave = ref._request.kind == TimewebMutationKind.leaveMeeting;
  if (status != 200 || value['meetingId'] != ref._request._payload['meetingId']) { _mutationInvalidReply(); }
  if (leave) {
    if (!_mutationExact(value, {'meetingId','left','alreadyLeft','membershipRevision','leftAt'}) ||
        value['left'] != true || value['alreadyLeft'] is! bool || revision != value['membershipRevision'] ||
        !(value['membershipRevision'] == null ? value['leftAt'] == null && value['alreadyLeft'] == true :
          _mutationInteger(value['membershipRevision']) && _mutationStamp(value['leftAt']))) { _mutationInvalidReply(); }
    return TimewebMutationResult._(ref, TimewebMutationState.confirmed, status, revision: revision, replayed: replayed,
      leftMeeting: TimewebMeetingLeaveReceipt._(value, ref.requireCurrent), receiptConfirmed: true);
  }
  if (!_mutationExact(value, {'meetingId','targetUid','kicked','alreadyKicked','membershipRevision','kickedAt','leftAt'}) ||
      value['targetUid'] != ref._request._payload['targetUid'] || value['kicked'] != true || value['alreadyKicked'] is! bool ||
      !_mutationInteger(value['membershipRevision']) || revision != value['membershipRevision'] ||
      !_mutationStamp(value['kickedAt']) || !_mutationStamp(value['leftAt'])) { _mutationInvalidReply(); }
  return TimewebMutationResult._(ref, TimewebMutationState.confirmed, status, revision: revision, replayed: replayed,
    kickedParticipant: TimewebMeetingKickReceipt._(value, ref.requireCurrent), receiptConfirmed: true);
}

final class TimewebMeetingFilters {
  TimewebMeetingFilters._(this._query);
  final Map<String, String> _query;
  static Future<TimewebMeetingFilters> fromCatalog({String scope = 'group', int limit = 30,
    String? countryCode, String? region}) async {
    if (!const ['group', 'individual'].contains(scope)) throw ArgumentError('Invalid meeting scope.');
    await TimewebPeopleFilters.fromCatalog(limit: limit, countryCode: countryCode, region: region);
    return TimewebMeetingFilters._(Map.unmodifiable({'scope': scope, 'limit': '$limit',
      if (countryCode != null) 'countryCode': countryCode, if (region != null) 'region': region}));
  }
  String get scope => _query['scope']!;
  int get limit => int.parse(_query['limit']!);
  String? get countryCode => _query['countryCode'];
  String? get region => _query['region'];
  @override
  String toString() => 'TimewebMeetingFilters(<redacted>)';
}

final class TimewebMeetingCursor {
  TimewebMeetingCursor._(this._value, this._owner, this._scope, this._check, this._expiry,
    {int? capSequence, int? beforeSequence, int? revision, String? previousMeetingId, String? previousStartsAt})
      : _capSequence = capSequence, _beforeSequence = beforeSequence, _revision = revision,
        _previousMeetingId = previousMeetingId, _previousStartsAt = previousStartsAt;
  final String _value, _scope;
  final TimewebAuthClient _owner;
  final void Function() _check;
  final DateTime _expiry;
  final int? _capSequence, _beforeSequence, _revision;
  final String? _previousMeetingId, _previousStartsAt;
  void requireCurrent() { _check(); if (!_owner._clock().isBefore(_expiry)) throw const TimewebAuthException(TimewebAuthOperation.currentRead, TimewebAuthError.invalidRequest); }
  @override
  String toString() => 'TimewebMeetingCursor(<redacted>)';
}

final class TimewebMeetingPage<T> {
  TimewebMeetingPage._(this._items, this._cursor, this._check);
  final List<T> _items;
  final TimewebMeetingCursor? _cursor;
  final void Function() _check;
  void requireCurrent() => _check();
  List<T> get items { _check(); return _items; }
  TimewebMeetingCursor? get nextCursor { _check(); return _cursor; }
  bool get mediaReady { _check(); return false; }
  TimewebMeetingPage<T> bindSessionGuard(void Function() guard) {
    void check() { requireCurrent(); guard(); }
    final cursor = _cursor;
    return TimewebMeetingPage<T>._(List.unmodifiable(_items.map((item) =>
      (item is TimewebMeeting ? item.bindSessionGuard(guard) : (item as TimewebMeetingParticipant).bindSessionGuard(guard)) as T)),
      cursor == null ? null : TimewebMeetingCursor._(cursor._value, cursor._owner, cursor._scope,
        () { cursor.requireCurrent(); guard(); }, cursor._expiry,
        capSequence: cursor._capSequence, beforeSequence: cursor._beforeSequence, revision: cursor._revision,
        previousMeetingId: cursor._previousMeetingId, previousStartsAt: cursor._previousStartsAt), check);
  }
  @override
  String toString() => 'TimewebMeetingPage(<redacted>)';
}

final class TimewebMeeting {
  TimewebMeeting._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeeting bindSessionGuard(void Function() guard) => TimewebMeeting._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  String get organizerUid => _read('organizerUid');
  String? get invitedUid => _read('invitedUid');
  String get kind => _read('kind');
  String get title => _read('title');
  String get description => _read('description');
  String get countryCode => _read('countryCode');
  String get region => _read('region');
  String? get startsAt => _read('startsAt');
  String? get createdAt => _read('createdAt');
  String? get updatedAt => _read('updatedAt');
  int get revision => _read('revision');
  String? get localDatetime => _read('localDatetime');
  String get scheduleLabel {
    _check();
    final local = _data['localDatetime'] as String?;
    if (local != null) { return local; }
    final utc = _data['startsAt'] as String;
    return '${utc.substring(8, 10)}.${utc.substring(5, 7)}.${utc.substring(0, 4)} ${utc.substring(11, 16)} UTC';
  }
  Null get media { _check(); return null; }
  bool get mediaReady { _check(); return false; }
  @override
  String toString() => 'TimewebMeeting(<redacted>)';
}

final class TimewebMeetingParticipant {
  TimewebMeetingParticipant._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingParticipant bindSessionGuard(void Function() guard) => TimewebMeetingParticipant._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get uid => _read('uid');
  String? get fullName => _read('fullName');
  String? get primaryGroup => _read('primaryGroup');
  String? get joinedAt => _read('joinedAt');
  int get membershipRevision => _read('membershipRevision');
  Null get avatar { _check(); return null; }
  bool get mediaReady { _check(); return false; }
  @override
  String toString() => 'TimewebMeetingParticipant(<redacted>)';
}

final class TimewebMeetingTextRequest {
  TimewebMeetingTextRequest({required this.meetingId, required this.text}) {
    if (!_meetingIdentifier(meetingId) || !_mutationText(text)) throw ArgumentError('Invalid meeting text.');
  }
  final String meetingId, text;
  @override
  String toString() => 'TimewebMeetingTextRequest(<redacted>)';
}
final class TimewebMeetingMessage {
  TimewebMeetingMessage._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingMessage bindSessionGuard(void Function() guard) => TimewebMeetingMessage._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  String get messageId => _read('messageId');
  int get sequence => _read('sequence');
  String get senderUid => _read('senderUid');
  String get text => _read('text');
  String get createdAt => _read('createdAt');
  @override
  String toString() => 'TimewebMeetingMessage(<redacted>)';
}
final class TimewebSentMeetingMessageReceipt extends TimewebMeetingMessage {
  TimewebSentMeetingMessageReceipt._(Map<String, dynamic> data, void Function() check) : super._(data, check);
  int get chatRevision => _read('chatRevision');
  @override
  TimewebSentMeetingMessageReceipt bindSessionGuard(void Function() guard) => TimewebSentMeetingMessageReceipt._(_data, () { requireCurrent(); guard(); });
  @override
  String toString() => 'TimewebSentMeetingMessageReceipt(<redacted>)';
}
final class TimewebMeetingMessagePage {
  TimewebMeetingMessagePage._(this._items, this._cursor, this._meetingId, this._revision, this._check);
  final List<TimewebMeetingMessage> _items;
  final TimewebMeetingCursor? _cursor;
  final int _revision;
  final String _meetingId;
  final void Function() _check;
  void requireCurrent() => _check();
  List<TimewebMeetingMessage> get items { _check(); return _items; }
  TimewebMeetingCursor? get nextCursor { _check(); return _cursor; }
  int get chatRevision { _check(); return _revision; }
  String get meetingId { _check(); return _meetingId; }
  bool get mediaReady { _check(); return false; }
  TimewebMeetingMessagePage bindSessionGuard(void Function() guard) {
    void check() { requireCurrent(); guard(); }
    final cursor = _cursor;
    return TimewebMeetingMessagePage._(List.unmodifiable(_items.map((v) => v.bindSessionGuard(guard))),
      cursor == null ? null : TimewebMeetingCursor._(cursor._value, cursor._owner, cursor._scope,
        () { cursor.requireCurrent(); guard(); }, cursor._expiry, capSequence: cursor._capSequence,
        beforeSequence: cursor._beforeSequence, revision: cursor._revision), _meetingId, _revision, check);
  }
  @override
  String toString() => 'TimewebMeetingMessagePage(<redacted>)';
}

/// This owner archive window proves no live membership or chat capability.
final class TimewebMeetingArchiveWindow {
  TimewebMeetingArchiveWindow._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingArchiveWindow bindSessionGuard(void Function() guard) =>
      TimewebMeetingArchiveWindow._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  int get throughSequence => _read('throughSequence');
  String get capturedAt => _read('capturedAt');
  String get operationId => _read('operationId');
  int get membershipRevision => _read('membershipRevision');
  @override
  String toString() => 'TimewebMeetingArchiveWindow(<redacted>)';
}
final class TimewebMeetingArchiveCursor {
  TimewebMeetingArchiveCursor._(this._cursor, this._window);
  final TimewebMeetingCursor _cursor;
  final Map<String, dynamic> _window;
  void requireCurrent() => _cursor.requireCurrent();
  @override
  String toString() => 'TimewebMeetingArchiveCursor(<redacted>)';
}
final class TimewebMeetingArchivePage {
  TimewebMeetingArchivePage._(this._items, this._cursor, this._meetingId, this._window, this._check);
  final List<TimewebMeetingMessage> _items;
  final TimewebMeetingArchiveCursor? _cursor;
  final String _meetingId;
  final TimewebMeetingArchiveWindow _window;
  final void Function() _check;
  void requireCurrent() => _check();
  List<TimewebMeetingMessage> get items { _check(); return _items; }
  TimewebMeetingArchiveCursor? get nextCursor { _check(); return _cursor; }
  String get meetingId { _check(); return _meetingId; }
  TimewebMeetingArchiveWindow get window { _check(); return _window; }
  bool get mediaReady { _check(); return false; }
  TimewebMeetingArchivePage bindSessionGuard(void Function() guard) {
    void check() { requireCurrent(); guard(); }
    final cursor = _cursor?._cursor;
    return TimewebMeetingArchivePage._(List.unmodifiable(_items.map((v) => v.bindSessionGuard(guard))),
      cursor == null ? null : TimewebMeetingArchiveCursor._(TimewebMeetingCursor._(cursor._value, cursor._owner, cursor._scope,
        () { cursor.requireCurrent(); guard(); }, cursor._expiry, capSequence: cursor._capSequence,
        beforeSequence: cursor._beforeSequence), _cursor!._window), _meetingId, _window.bindSessionGuard(guard), check);
  }
  @override
  String toString() => 'TimewebMeetingArchivePage(<redacted>)';
}
final class TimewebMeetingArchiveUnavailable implements Exception {
  const TimewebMeetingArchiveUnavailable();
  @override
  String toString() => 'TimewebMeetingArchiveUnavailable';
}
TimewebMeetingArchivePage _decodeMeetingArchive(_PeopleFlight f, Map<String, dynamic> body, String id,
    Map<String, String> query, String scope, TimewebMeetingArchiveCursor? cursor) {
  if (!_mutationExact(body, {'kind','meetingId','archiveWindow','ordering','items','nextCursor','mediaReady'}) ||
      body['kind'] != 'canonical-current' || body['meetingId'] != id || body['ordering'] != 'sequence_desc' ||
      body['mediaReady'] != false || body['archiveWindow'] is! Map<String, dynamic> || body['items'] is! List ||
      (body['items'] as List).length > int.parse(query['limit']!)) { _peopleInvalid(); }
  final window = body['archiveWindow'] as Map<String, dynamic>;
  if (!_mutationExact(window, {'throughSequence','capturedAt','operationId','membershipRevision'}) ||
      !_mutationInteger(window['throughSequence']) || !_mutationInteger(window['membershipRevision'], positive: true) ||
      !_mutationStamp(window['capturedAt']) || window['operationId'] is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(window['operationId']) ||
      cursor != null && window.entries.any((v) => cursor._window[v.key] != v.value)) { _peopleInvalid(); }
  final next = body['nextCursor'], raw = body['items'] as List;
  if (next != null && (!_validReadCursor(next is String ? next : '') || next == cursor?._cursor._value || raw.isEmpty)) { _peopleInvalid(); }
  final rows = <TimewebMeetingMessage>[], ids = <String>{}; int? previous = cursor?._cursor._beforeSequence;
  for (final value in raw) {
    if (value is! Map<String, dynamic> || !_mutationExact(value, {'meetingId','messageId','sequence','senderUid','text','createdAt'}) ||
        !_meetingMessageFields(value, id) || value['sequence'] > window['throughSequence'] ||
        previous != null && value['sequence'] >= previous || !ids.add(value['messageId'])) { _peopleInvalid(); }
    previous = value['sequence']; rows.add(TimewebMeetingMessage._(Map.unmodifiable(value), _meetingReadCheck(f)));
  }
  final frozen = Map<String, dynamic>.unmodifiable(window);
  final continuation = next == null ? null : TimewebMeetingArchiveCursor._(TimewebMeetingCursor._(next, f.owner, scope, _meetingReadCheck(f),
    cursor?._cursor._expiry ?? f.startedAt.add(const Duration(seconds: 300)), capSequence: window['throughSequence'], beforeSequence: rows.last.sequence), frozen);
  return TimewebMeetingArchivePage._(List.unmodifiable(rows), continuation, id,
    TimewebMeetingArchiveWindow._(frozen, _meetingReadCheck(f)), _meetingReadCheck(f));
}

bool _meetingMessageFields(Map<String, dynamic> value, String id) => value['meetingId'] == id &&
  value['messageId'] is String && RegExp(r'^tw-meet-msg-[a-f0-9]{64}$').hasMatch(value['messageId']) &&
  _mutationInteger(value['sequence'], positive: true) && _currentIdentifier(value['senderUid']) &&
  _mutationText(value['text']) && _mutationStamp(value['createdAt']);

TimewebMeetingMessagePage _decodeMeetingMessages(_PeopleFlight f, Map<String, dynamic> body, Map<String, String> query,
  String id, TimewebMeetingCursor? cursor, String scope) {
  if (!_mutationExact(body, {'kind','meetingId','chatRevision','ordering','items','nextCursor','mediaReady'}) ||
      body['kind'] != 'canonical-current' || body['meetingId'] != id || body['ordering'] != 'sequence_desc' ||
      body['mediaReady'] != false || !_mutationInteger(body['chatRevision']) || body['items'] is! List ||
      (body['items'] as List).length > int.parse(query['limit']!) || cursor != null && body['chatRevision'] < cursor._revision!) _peopleInvalid();
  final next = body['nextCursor'], raw = body['items'] as List;
  if (next != null && (!_validReadCursor(next is String ? next : '') || next == cursor?._value || raw.isEmpty)) _peopleInvalid();
  final rows = <TimewebMeetingMessage>[], ids = <String>{}; int? previous = cursor?._beforeSequence;
  for (final value in raw) {
    if (value is! Map<String, dynamic> || !_mutationExact(value, {'meetingId','messageId','sequence','senderUid','text','createdAt'}) ||
        !_meetingMessageFields(value, id) || value['sequence'] > body['chatRevision'] ||
        cursor != null && value['sequence'] > cursor._capSequence! || previous != null && value['sequence'] >= previous || !ids.add(value['messageId'])) _peopleInvalid();
    previous = value['sequence']; rows.add(TimewebMeetingMessage._(Map.unmodifiable(value), _meetingReadCheck(f)));
  }
  final continuation = next == null ? null : TimewebMeetingCursor._(next, f.owner, scope, _meetingReadCheck(f),
    cursor?._expiry ?? f.startedAt.add(const Duration(seconds: 300)), capSequence: cursor?._capSequence ?? rows.first.sequence,
    beforeSequence: rows.last.sequence, revision: cursor?._revision ?? body['chatRevision']);
  return TimewebMeetingMessagePage._(List.unmodifiable(rows), continuation, id, body['chatRevision'], _meetingReadCheck(f));
}

TimewebMutationResult _decodeSentMeetingMessage(TimewebMutationReference ref, int status, Map<String, dynamic> result, int? revision, bool replayed) {
  final input = ref._request._payload;
  final expected = 'tw-meet-msg-${crypto.sha256.convert(utf8.encode('clrs-native-meeting-message-v1\u0000${_mutationCanonical([input['meetingId'], ref._uid, ref._request.operationId])}'))}';
  if (status != 201 || !_mutationExact(result, {'meetingId','messageId','sequence','senderUid','text','createdAt','chatRevision'}) ||
      !_meetingMessageFields(result, input['meetingId']) || result['messageId'] != expected || result['senderUid'] != ref._uid ||
      result['text'] != input['text'] || !_mutationInteger(result['chatRevision']) || revision != result['chatRevision'] || revision! < result['sequence']) _mutationInvalidReply();
  return TimewebMutationResult._(ref, TimewebMutationState.confirmed, status, replayed: replayed, revision: revision,
    meetingMessage: TimewebSentMeetingMessageReceipt._(result, ref.requireCurrent), receiptConfirmed: true);
}

final class TimewebMeetingNotFound implements Exception {
  const TimewebMeetingNotFound();
  @override
  String toString() => 'TimewebMeetingNotFound';
}

extension TimewebMeetingsClient on TimewebAuthClient {
  Future<TimewebMeetingArchivePage> readMeetingArchive(String meetingId, {int limit = 30, TimewebMeetingArchiveCursor? cursor}) {
    if (limit < 1 || limit > 30) return Future.error(ArgumentError('Invalid meeting archive limit.'));
    return _meetingRead(this, {'limit': '$limit'}, meetingId, cursor?._cursor, messages: true, archive: true, archiveCursor: cursor)
      .then((v) => v as TimewebMeetingArchivePage);
  }
  Future<TimewebMeetingMessagePage> readMeetingMessages(String meetingId, {int limit = 30, TimewebMeetingCursor? cursor}) {
    if (limit < 1 || limit > 30) return Future.error(ArgumentError('Invalid meeting message limit.'));
    return _meetingRead(this, {'limit': '$limit'}, meetingId, cursor, messages: true).then((v) => v as TimewebMeetingMessagePage);
  }
  Future<TimewebMeetingPage<TimewebMeeting>> readMeetings(TimewebMeetingFilters filters, {TimewebMeetingCursor? cursor}) =>
      _meetingRead(this, filters._query, null, cursor).then((v) => v as TimewebMeetingPage<TimewebMeeting>);
  Future<TimewebMeeting> readMeeting(String meetingId) => _meetingRead(this, const {}, meetingId, null).then((v) => v as TimewebMeeting);
  Future<TimewebMeetingPage<TimewebMeetingParticipant>> readMeetingParticipants(String meetingId, {int limit = 30, TimewebMeetingCursor? cursor}) {
    if (limit < 1 || limit > 30) return Future.error(ArgumentError('Invalid participant limit.'));
    return _meetingRead(this, {'limit': '$limit'}, meetingId, cursor).then((v) => v as TimewebMeetingPage<TimewebMeetingParticipant>);
  }
}

Future<Object> _meetingRead(TimewebAuthClient owner, Map<String, String> query, String? id, TimewebMeetingCursor? cursor, {bool messages = false, bool archive = false, TimewebMeetingArchiveCursor? archiveCursor}) {
  try {
    owner._checkEnabled(_peopleOperation);
    if (!owner.configuration.currentReadsEnabled || !owner.configuration.runtimeWritesEnabled) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.disabled);
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.notAuthenticated);
    if (id != null && !_meetingIdentifier(id)) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.invalidRequest);
    final scope = '${archive ? 'meeting-archive' : messages ? 'meeting-messages' : 'meetings'}:$id:${jsonEncode(query)}';
    if (cursor != null) {
      if (!identical(cursor._owner, owner) || cursor._scope != scope) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.invalidRequest);
      cursor.requireCurrent();
    }
    final generation = _meetingGenerations[owner] ?? 0;
    final key = '${owner._epoch}\u0000$generation\u0000$scope\u0000${cursor?._value ?? ''}';
    final existing = owner._peopleFlights[key];
    if (existing != null) return existing.result.future;
    if (owner._peopleFlights.length >= 4) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.unavailable);
    final flight = _PeopleFlight(owner, null, null, null, owner._epoch, session.uid, key);
    _meetingFlightChecks[flight] = () {
      flight.checkSession();
      if ((_meetingGenerations[owner] ?? 0) != generation) throw const TimewebMeetingNotFound();
    };
    owner._peopleFlights[key] = flight;
    unawaited(_executeMeetingRead(flight, query, id, cursor, scope, messages, archive, archiveCursor));
    return flight.result.future;
  } catch (error) { return Future.error(error); }
}

Future<void> _executeMeetingRead(_PeopleFlight f, Map<String, String> query, String? id, TimewebMeetingCursor? cursor, String scope, bool messages, bool archive, TimewebMeetingArchiveCursor? archiveCursor) async {
  final owner = f.owner;
  final uri = owner.configuration.endpoint.replace(pathSegments: ['v1', 'runtime', 'meetings',
    if (id != null) id, if (id != null && query.isNotEmpty) archive ? 'archived-messages' : messages ? 'messages' : 'participants'],
    queryParameters: query.isEmpty ? null : {...query, if (cursor != null) 'cursor': cursor._value});
  try {
    f.check(); var session = owner._session!;
    if (!owner._clock().add(owner.accessExpirySkew).isBefore(session.accessExpiresAt)) { session = await owner.refresh(); f.check(); }
    var reply = await _meetingAttempt(f, uri, session.accessToken); f.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken) await owner.refresh();
      f.check(); session = owner._session!; reply = await _meetingAttempt(f, uri, session.accessToken); f.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 && owner._session?.accessToken == session.accessToken) await owner._invalidate(f.epoch);
      if (archive && const [400,403,404].contains(reply.status)) throw const TimewebMeetingArchiveUnavailable();
      if (reply.status == 404 && id != null) throw const TimewebMeetingNotFound();
      throw owner._statusError(_peopleOperation, reply.status);
    }
    final catalog = messages ? const <String, dynamic>{} : await _pinnedGeographyCatalog(); f.check();
    final value = archive ? _decodeMeetingArchive(f, reply.body!, id!, query, scope, archiveCursor)
      : messages ? _decodeMeetingMessages(f, reply.body!, query, id!, cursor, scope)
      : _decodeMeetingRead(f, reply.body!, query, id, cursor, scope, catalog); f.check();
    _meetingReadCheck(f)();
    if (!f.result.isCompleted) f.result.complete(value);
  } catch (error) {
    if (!f.result.isCompleted) {
      try { f.check(); f.result.completeError(error is TimewebAuthException || error is TimewebMeetingNotFound || error is TimewebMeetingArchiveUnavailable ? error : const TimewebAuthException(_peopleOperation, TimewebAuthError.network)); }
      on TimewebAuthException catch (stale) { if (!f.result.isCompleted) f.result.completeError(stale); }
    }
  } finally {
    f.timer.cancel(); if (identical(owner._peopleFlights[f.key], f)) owner._peopleFlights.remove(f.key); f.settled.complete();
  }
}

Future<_Reply> _meetingAttempt(_PeopleFlight f, Uri uri, String bearer) async {
  f.check(); final owner = f.owner;
  if (owner._inflightRequests >= 4) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.unavailable);
  final abort = Completer<void>();
  final request = http.AbortableRequest('GET', uri, abortTrigger: abort.future)..followRedirects = false
    ..headers['Accept'] = 'application/json'..headers['Authorization'] = 'Bearer $bearer'..headers['Cache-Control'] = 'no-store';
  StreamIterator<List<int>>? reader; Future<void>? cancellation;
  Future<void> cancel() => reader == null ? Future.value() : cancellation ??= reader.cancel();
  f.aborts.add(abort); f.cancellations.add(cancel); owner._inflightRequests++;
  try {
    final response = await owner._http.send(request); reader = StreamIterator(response.stream);
    var moving = reader.moveNext(); unawaited(moving.then<void>((_) {}, onError: (Object _, StackTrace __) {})); f.check();
    if (response.isRedirect || response.statusCode >= 300 && response.statusCode < 400) _peopleInvalid();
    if (response.statusCode != 200) return _Reply(response.statusCode, null);
    final mime = response.headers['content-type']?.toLowerCase() ?? '';
    final cache = (response.headers['cache-control'] ?? '').toLowerCase().split(',').map((v) => v.trim());
    final encoding = response.headers['content-encoding']?.toLowerCase();
    if (mime.split(';').first.trim() != 'application/json' || !cache.contains('no-store') || cache.contains('public') ||
        encoding != null && encoding != 'identity' || response.contentLength != null && response.contentLength! > 65536) _peopleInvalid();
    final bytes = <int>[];
    while (await moving) { f.check(); if (bytes.length + reader.current.length > 65536) _peopleInvalid(); bytes.addAll(reader.current); moving = reader.moveNext(); }
    f.check(); if (response.contentLength != null && response.contentLength != bytes.length) _peopleInvalid();
    final decoded = jsonDecode(utf8.decode(bytes)); if (decoded is! Map<String, dynamic>) _peopleInvalid();
    return _Reply(200, decoded);
  } on FormatException { _peopleInvalid(); }
  finally { try { if (!abort.isCompleted) abort.complete(); await cancel(); }
    finally { f.aborts.remove(abort); f.cancellations.remove(cancel); owner._inflightRequests--; } }
}

bool _meetingIdentifier(Object? value) => _currentIdentifier(value) && !(value as String).contains(RegExp(r'[/\\%?#]'));

TimewebMeeting _decodeMeeting(_PeopleFlight f, Object? value, Map<String, dynamic> catalog) {
  if (value is! Map<String, dynamic> || !_mutationExact(value, {'meetingId','organizerUid','invitedUid','kind','title','description','countryCode','region',
      'startsAt','localDatetime','createdAt','updatedAt','revision','media','mediaReady'}) ||
      !_meetingIdentifier(value['meetingId']) || !_currentIdentifier(value['organizerUid']) ||
      !((value['kind'] == 'group' && value['invitedUid'] == null) || (value['kind'] == 'individual' && _currentIdentifier(value['invitedUid']) && value['invitedUid'] != value['organizerUid'] && [value['organizerUid'], value['invitedUid']].contains(f.uid))) ||
      !_meetingReadSchedule(value['localDatetime'], value['startsAt']) || value['media'] != null || value['mediaReady'] != false ||
      !_mutationInteger(value['revision']) || !_currentNullableStamp(value['createdAt']) || !_currentNullableStamp(value['updatedAt'])) _peopleInvalid();
  if (value['title'] is! String || (value['title'] as String).trim().isEmpty || value['description'] is! String ||
      !_currentNullableText(value['title'], 1000) || !_currentNullableText(value['description'], 4096) ||
      !(catalog['countries'] as List).any((row) => row['code'] == value['countryCode'] && (row['regions'] as List).contains(value['region']))) _peopleInvalid();
  return TimewebMeeting._(Map.unmodifiable(value), _meetingReadCheck(f));
}

Object _decodeMeetingRead(_PeopleFlight f, Map<String, dynamic> body, Map<String, String> query, String? id, TimewebMeetingCursor? cursor, String scope, Map<String, dynamic> catalog) {
  if (body['kind'] != 'canonical-current' || body['mediaReady'] != false) _peopleInvalid();
  if (id != null && query.isEmpty) {
    if (!_mutationExact(body, {'kind','meeting','mediaReady'})) _peopleInvalid();
    final item = _decodeMeeting(f, body['meeting'], catalog); if (item.meetingId != id) _peopleInvalid(); return item;
  }
  final participants = id != null, limit = int.parse(query['limit']!);
  if (!_mutationExact(body, {'kind','ordering','items','nextCursor','mediaReady',participants ? 'meetingId' : 'scope'}) ||
      body['ordering'] != (participants ? 'uid_binary_asc' : 'starts_at_asc_meeting_id_asc_null_first') ||
      (participants ? body['meetingId'] != id : body['scope'] != query['scope']) || body['items'] is! List || (body['items'] as List).length > limit) _peopleInvalid();
  final next = body['nextCursor'];
  if (next != null && (!_validReadCursor(next is String ? next : '') || next == cursor?._value)) _peopleInvalid();
  TimewebMeetingCursor? continuation({String? meetingId, String? startsAt}) => next == null ? null :
      TimewebMeetingCursor._(next, f.owner, scope, _meetingReadCheck(f), cursor?._expiry ?? f.startedAt.add(const Duration(seconds: 300)),
        previousMeetingId: meetingId, previousStartsAt: startsAt);
  String? previous;
  if (participants) {
    final items = <TimewebMeetingParticipant>[];
    for (final value in body['items'] as List) {
      if (value is! Map<String, dynamic> || !_mutationExact(value, {'uid','fullName','primaryGroup','joinedAt','membershipRevision','avatar','mediaReady'}) ||
          !_currentIdentifier(value['uid']) || !_currentNullableText(value['fullName'], 1000) || !_currentNullableText(value['primaryGroup'], 191) ||
          !_currentNullableStamp(value['joinedAt']) || !_mutationInteger(value['membershipRevision']) || value['avatar'] != null || value['mediaReady'] != false ||
          previous != null && _currentCompareIds(previous, value['uid']) >= 0) _peopleInvalid();
      previous = value['uid']; items.add(TimewebMeetingParticipant._(Map.unmodifiable(value), _meetingReadCheck(f)));
    }
    return TimewebMeetingPage<TimewebMeetingParticipant>._(List.unmodifiable(items), continuation(), _meetingReadCheck(f));
  }
  final items = <TimewebMeeting>[], ids = <String>{};
  var previousId = cursor?._previousMeetingId, previousTime = cursor?._previousStartsAt;
  for (final value in body['items'] as List) {
    final item = _decodeMeeting(f, value, catalog);
    if (item.kind != query['scope'] || query['countryCode'] != null && item.countryCode != query['countryCode'] ||
        query['region'] != null && item.region != query['region'] || !ids.add(item.meetingId) ||
        previousId != null && _meetingCompareSchedule(previousTime, previousId, item.startsAt, item.meetingId) >= 0 ||
        item.kind == 'individual' && ![item.organizerUid, item.invitedUid].contains(f.uid)) _peopleInvalid();
    previousId = item.meetingId; previousTime = item.startsAt; items.add(item);
  }
  return TimewebMeetingPage<TimewebMeeting>._(List.unmodifiable(items), continuation(meetingId: previousId, startsAt: previousTime), _meetingReadCheck(f));
}

TimewebMutationResult _decodeCreatedMeeting(TimewebMutationReference ref, int status, Map<String, dynamic> result, int? revision, bool replayed) {
  final expected = 'tw-meeting-${crypto.sha256.convert([...utf8.encode('clrs-native-meeting-v1\u0000'), ...utf8.encode(_mutationCanonical([ref._uid, ref._request.operationId]))])}';
  if (!_mutationExact(result, {'meetingId','created','meetingRevision','localDatetime'}) || result['meetingId'] != expected ||
      result['created'] != true || result['meetingRevision'] is! int || result['meetingRevision'] != 0 || revision != 0 || result['localDatetime'] != ref._request._payload['datetime']) _mutationInvalidReply();
  return TimewebMutationResult._(ref, TimewebMutationState.confirmed, status, replayed: replayed, revision: revision,
    meeting: TimewebMeetingCreateReceipt._(result, ref.requireCurrent), receiptConfirmed: true);
}

TimewebMutationResult _decodeJoinedMeeting(TimewebMutationReference ref, int status, Map<String, dynamic> result, int? revision, bool replayed) {
  if (status != 200 || !_mutationExact(result, {'meetingId','joined','alreadyMember','membershipRevision'}) ||
      result['meetingId'] != ref._request._payload['meetingId'] || result['joined'] != true ||
      result['alreadyMember'] is! bool || !_mutationInteger(result['membershipRevision']) || revision != result['membershipRevision']) _mutationInvalidReply();
  return TimewebMutationResult._(ref, TimewebMutationState.confirmed, status, replayed: replayed, revision: revision,
    joinedMeeting: TimewebMeetingJoinReceipt._(result, ref.requireCurrent), receiptConfirmed: true);
}
