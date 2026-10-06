import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'app_session.dart';
import 'timeweb_auth_client.dart';
import 'timeweb_chat_flow.dart' show TimewebChatWriteOutcome;

/// Native text only. Current target denial removes RAM display authority while
/// unresolved private originals remain available for a later receipt lookup.
final class TimewebMeetingChatFlow {
  TimewebMeetingChatFlow._(this._client, this._session, this._lease, this._journal, this._meetingId);
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebMeetingChatJournal _journal;
  final String _meetingId;
  List<TimewebMeetingMessage> _messages = [];
  TimewebMeetingCursor? _older;
  Future<void>? _readFlight;
  Future<TimewebChatWriteOutcome>? _writeFlight;
  _MeetingTextIntent? _intent;
  TimewebMutationReference? _reference;
  TimewebChatWriteOutcome? _completed;
  TimewebMutationFailure? _failure;
  int _minimumRevision = 0;
  bool _closed = false, _available = true;
  void Function()? _readAuthority;
  static const _limit = 30, _maximumMessages = 300;

  static Future<TimewebMeetingChatFlow> open({required TimewebAuthClient client,
    required AppSession session, required AppSessionLease lease,
    required TimewebMeetingChatJournal journal, required String meetingId}) async {
    lease.requireCurrent(); TimewebMeetingJoinRequest(meetingId: meetingId);
    final flow = TimewebMeetingChatFlow._(client, session, lease, journal, meetingId);
    await flow.loadLatest(); // fresh current membership/access, including empty
    flow._intent = await journal._load(flow._origin, lease.identity.uid, meetingId);
    flow.requireCurrent();
    if (flow._intent != null) flow._reference = client.bindMutation(flow._intent!.request, expectedOwnerUid: lease.identity.uid);
    return flow;
  }
  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() {
    if (_closed) throw StateError('Meeting conversation is closed.');
    _lease.requireCurrent(); if (!_available) throw const TimewebMeetingNotFound();
    _readAuthority?.call();
  }
  bool get targetAvailable {
    _lease.requireCurrent(); if (_closed || !_available) return false;
    try { requireCurrent(); return true; } on TimewebMeetingNotFound { return false; }
  }
  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout => _client.requestDeadline + const Duration(seconds: 2);
  String get ownerUid { requireCurrent(); return _lease.identity.uid; }
  String get meetingId { requireCurrent(); return _meetingId; }
  List<TimewebMeetingMessage> get messages { requireCurrent(); for (final v in _messages) { v.requireCurrent(); } return List.unmodifiable(_messages); }
  bool get hasOlder { requireCurrent(); return _older != null; }
  bool get sendNeedsCheck { requireCurrent(); return _intent != null || _writeFlight != null || _completed != null || _reference != null; }
  String? get pendingText { requireCurrent(); return _intent?.text; }
  TimewebMutationFailure? get failure { _lease.requireCurrent(); return _failure; }
  void _denyTarget() { _available = false; _messages = []; _older = null; _completed = null; }
  Future<void> loadLatest() => _load(false);
  Future<void> loadOlder() => _load(true);
  Future<void> loadUpdates() => _load(false, updates: true);
  Future<void> _load(bool older, {bool updates = false}) {
    requireCurrent(); if (_readFlight != null) return _readFlight!;
    if (older && _older == null) return Future.value();
    final future = (() async {
      try {
        final page = await _client.readMeetingMessages(_meetingId, limit: _limit, cursor: older ? _older : null);
        requireCurrent(); page.requireCurrent(); _readAuthority = page.requireCurrent;
        if (page.chatRevision < _minimumRevision) throw const TimewebAuthException(TimewebAuthOperation.currentRead, TimewebAuthError.invalidResponse);
        final rows = <String, TimewebMeetingMessage>{}; final sequences = <int, String>{};
        for (final item in [...(older || updates ? _messages : <TimewebMeetingMessage>[]), ...page.items]) {
          final previous = rows[item.messageId];
          if (previous != null && (previous.sequence != item.sequence || previous.text != item.text || previous.senderUid != item.senderUid || previous.createdAt != item.createdAt) ||
              sequences.containsKey(item.sequence) && sequences[item.sequence] != item.messageId) {
            throw const TimewebAuthException(TimewebAuthOperation.currentRead, TimewebAuthError.invalidResponse);
          }
          sequences[item.sequence] = item.messageId; rows[item.messageId] = item.bindSessionGuard(requireCurrent);
        }
        final ordered = rows.values.toList()..sort((a,b) => b.sequence.compareTo(a.sequence));
        final capped = ordered.length > _maximumMessages;
        if (capped) { if (updates) { ordered.removeRange(_maximumMessages, ordered.length); }
          else { ordered.removeRange(0, ordered.length - _maximumMessages); } }
        _messages = ordered; _minimumRevision = page.chatRevision;
        if (!updates || capped || _older == null) _older = page.nextCursor;
      } on TimewebMeetingNotFound { _lease.requireCurrent(); _denyTarget(); rethrow; }
    })();
    _readFlight = future;
    unawaited(future.then<void>((_) { if (identical(_readFlight, future)) _readFlight = null; },
      onError: (Object _, StackTrace __) { if (identical(_readFlight, future)) _readFlight = null; }));
    return future;
  }
  Future<TimewebChatWriteOutcome> send(String originalText) {
    requireCurrent(); if (_writeFlight != null) return _writeFlight!;
    if (sendNeedsCheck) throw StateError('Check the original meeting text first.');
    final intent = _MeetingTextIntent.create(_origin, ownerUid, _meetingId, originalText);
    return _track(() async {
      await _journal._prepare(intent); requireCurrent(); _intent = intent;
      _reference = _client.bindMutation(intent.request, expectedOwnerUid: ownerUid);
      return _finish(await _client.mutate(_reference!));
    });
  }
  Future<TimewebChatWriteOutcome> checkSend() {
    requireCurrent(); if (_writeFlight != null) return _writeFlight!;
    if (_reference == null) throw StateError('No original meeting text to look up.');
    return _track(() async => _finish(await _client.reconcileMutation(_reference!)));
  }
  Future<TimewebChatWriteOutcome> _track(Future<TimewebChatWriteOutcome> Function() action) {
    final future = Future<TimewebChatWriteOutcome>.sync(action); _writeFlight = future;
    unawaited(future.then<void>((_) { if (identical(_writeFlight, future)) _writeFlight = null; },
      onError: (Object _, StackTrace __) { if (identical(_writeFlight, future)) _writeFlight = null; })); return future;
  }
  Future<TimewebChatWriteOutcome> _finish(TimewebMutationResult result) async {
    requireCurrent(); result.requireCurrent(); _failure = result.failure;
    if (!result.canAcknowledge) {
      _completed = null;
      if (result.failure == TimewebMutationFailure.meetingUnavailable || result.failure == TimewebMutationFailure.meetingNotFound) _denyTarget();
      return TimewebChatWriteOutcome.unknown;
    }
    final receipt = result.sentMeetingMessage;
    final confirmed = result.state == TimewebMutationState.confirmed && receipt != null;
    if (_intent != null) { await _journal._acknowledge(_intent!, requireCurrent); requireCurrent(); }
    _client.acknowledgeMutation(_reference!); _intent = null;
    if (confirmed) { if (receipt.chatRevision > _minimumRevision) _minimumRevision = receipt.chatRevision; }
    else if (const {TimewebMutationFailure.meetingUnavailable, TimewebMutationFailure.meetingNotFound,
      TimewebMutationFailure.notFound, TimewebMutationFailure.profileNotReady}.contains(result.failure)) _denyTarget();
    // No optimistic insertion. UI performs a current GET after this disk ACK.
    return _completed = confirmed ? TimewebChatWriteOutcome.confirmed : TimewebChatWriteOutcome.declined;
  }
  void acceptDisplayedSendResult() {
    requireCurrent(); if (_completed == null) throw StateError('Meeting text is unresolved.');
    _completed = null; _reference = null; _failure = null;
  }
  void close() { _closed = true; _messages = []; _older = null; _intent = null; _reference = null; _completed = null; }
  @override
  String toString() => 'TimewebMeetingChatFlow(<redacted>)';
}

final class TimewebMeetingChatJournal {
  TimewebMeetingChatJournal({Future<Directory> Function()? directory}) : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action()); _tail = future.then<void>((_) {}, onError: (Object _) {}); return future;
  }
  Future<void> drain() => _tail;
  Future<File> _file(String origin, String uid, String meetingId) async {
    final root = await _directory(), key = sha256.convert(utf8.encode('$origin\u0000$uid\u0000$meetingId'));
    final folder = Directory('${root.path}/clrs_native_meeting_text'); await folder.create(recursive: true);
    return File('${folder.path}/$key.json');
  }
  Future<_MeetingTextIntent?> _read(File file, String origin, String uid, String meetingId) async {
    if (!await file.exists()) return null;
    if (await file.length() > 65536) _invalidTextIntent();
    final bytes = <int>[];
    await for (final chunk in file.openRead()) { if (bytes.length + chunk.length > 65536) _invalidTextIntent(); bytes.addAll(chunk); }
    final raw = utf8.decode(bytes), data = jsonDecode(raw);
    if (data is! Map<String, dynamic> || jsonEncode(data) != raw || data.length != 7 || data['version'] is! int || data['version'] != 1 ||
        data['origin'] != origin || data['uid'] != uid || data['operation'] != 'meeting.send-text.v1' ||
        data['operationId'] is! String || data['requestHash'] is! String || data['fields'] is! Map<String, dynamic>) _invalidTextIntent();
    final fields = data['fields'] as Map<String, dynamic>;
    if (fields.length != 2 || fields['meetingId'] != meetingId || fields['text'] is! String) _invalidTextIntent();
    try {
      final intent = _MeetingTextIntent(origin, uid, meetingId, fields['text'], data['operationId']);
      if (intent.request.requestHash != data['requestHash']) _invalidTextIntent(); return intent;
    } on ArgumentError { _invalidTextIntent(); }
  }
  Future<_MeetingTextIntent?> _load(String origin, String uid, String meetingId) => _serial(() async => _read(await _file(origin,uid,meetingId),origin,uid,meetingId));
  Future<void> _prepare(_MeetingTextIntent intent) => _serial(() async {
    final file = await _file(intent.origin,intent.uid,intent.meetingId);
    if (await _read(file,intent.origin,intent.uid,intent.meetingId) != null) throw StateError('Original meeting text is unresolved.');
    final data = jsonEncode(intent.data); if (utf8.encode(data).length > 65536) _invalidTextIntent();
    final temporary = File('${file.path}.${intent.request.operationId}.tmp');
    try { await temporary.writeAsString(data,flush:true); await temporary.rename(file.path); }
    finally { if (await temporary.exists()) await temporary.delete(); }
  });
  Future<void> _acknowledge(_MeetingTextIntent intent, void Function() requireCurrent) => _serial(() async {
    requireCurrent(); final file = await _file(intent.origin,intent.uid,intent.meetingId); requireCurrent();
    final current = await _read(file,intent.origin,intent.uid,intent.meetingId); requireCurrent();
    if (current == null || current.request.operationId != intent.request.operationId || current.request.requestHash != intent.request.requestHash)
      throw StateError('Original private meeting text is unavailable.'); await file.delete();
  });
  @override
  String toString() => 'TimewebMeetingChatJournal(<redacted>)';
}
Never _invalidTextIntent() => throw const FormatException('Invalid private meeting text intent.');
final class _MeetingTextIntent {
  _MeetingTextIntent(this.origin,this.uid,this.meetingId,this.text,String id)
    : request = TimewebMutationRequest.sendMeetingText(operationId:id,meetingId:meetingId,text:text);
  factory _MeetingTextIntent.create(String origin,String uid,String meetingId,String text) {
    final random = Random.secure(), bytes = List.generate(16, (_) => 0);
    for (var i=0;i<bytes.length;i++) { bytes[i]=random.nextInt(256); }
    bytes[6]=(bytes[6]&15)|64; bytes[8]=(bytes[8]&63)|128;
    final hex = bytes.map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
    return _MeetingTextIntent(origin,uid,meetingId,text,'${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}');
  }
  final String origin,uid,meetingId,text;
  final TimewebMutationRequest request;
  Map<String,Object> get data => {'version':1,'origin':origin,'uid':uid,'operation':request.operation,
    'operationId':request.operationId,'requestHash':request.requestHash,'fields':{'meetingId':meetingId,'text':text}};
}
