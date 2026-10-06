import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebMeetingJoinOutcome { confirmed, rejected, unknown }

/// Original owner/meeting/UUID/hash is durable before POST. Restart only looks
/// up that original; absent/short replies never permit automatic resending.
final class TimewebMeetingJoinFlow {
  TimewebMeetingJoinFlow._(this._client, this._session, this._lease, this._journal, this._meetingId);
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebMeetingJoinJournal _journal;
  final String _meetingId;
  _MeetingJoinIntent? _intent;
  TimewebMutationReference? _reference;
  Future<TimewebMeetingJoinOutcome>? _active;
  TimewebMeetingJoinOutcome? _settled;
  TimewebMeetingJoinReceipt? _receipt;
  TimewebMutationFailure? _failure;
  bool _closed = false;

  static Future<TimewebMeetingJoinFlow> open({required TimewebAuthClient client,
    required AppSession session, required AppSessionLease lease,
    required TimewebMeetingJoinJournal journal, required String meetingId}) async {
    lease.requireCurrent();
    // Validates the target before opening a private journal; no network.
    TimewebMeetingJoinRequest(meetingId: meetingId);
    final flow = TimewebMeetingJoinFlow._(client, session, lease, journal, meetingId);
    flow._intent = await journal._load(flow._origin, lease.identity.uid, meetingId);
    flow.requireCurrent();
    if (flow._intent != null) flow._reference = client.bindMutation(flow._intent!.request, expectedOwnerUid: lease.identity.uid);
    return flow;
  }
  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() { if (_closed) throw StateError('Meeting join is closed.'); _lease.requireCurrent(); }
  Stream<AppSessionState> get sessionStates => _session.states;
  String get ownerUid { requireCurrent(); return _lease.identity.uid; }
  String get meetingId { requireCurrent(); return _meetingId; }
  bool get needsCheck { requireCurrent(); return _intent != null || _active != null || (_reference != null && _receipt == null); }
  bool get rejected { requireCurrent(); return _settled == TimewebMeetingJoinOutcome.rejected; }
  TimewebMutationFailure? get failure { requireCurrent(); return _failure; }
  TimewebMeetingJoinReceipt? get receipt { requireCurrent(); return _receipt; }

  Future<TimewebMeetingJoinOutcome> submit() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_intent != null || _settled != null) throw StateError('Check the original meeting join.');
    return _track(() async {
      final intent = _MeetingJoinIntent.create(_origin, ownerUid, _meetingId);
      await _journal._prepare(intent); requireCurrent();
      _intent = intent;
      _reference = _client.bindMutation(intent.request, expectedOwnerUid: ownerUid);
      return _finish(await _client.mutate(_reference!));
    });
  }
  Future<TimewebMeetingJoinOutcome> check() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_settled == TimewebMeetingJoinOutcome.rejected) return Future.value(_settled);
    if (_reference == null) throw StateError('No original meeting join to look up.');
    return _track(() async {
      _receipt = null; _failure = null; _settled = TimewebMeetingJoinOutcome.unknown;
      return _finish(await _client.reconcileMutation(_reference!));
    });
  }
  Future<TimewebMeetingJoinOutcome> _track(Future<TimewebMeetingJoinOutcome> Function() action) {
    final future = Future<TimewebMeetingJoinOutcome>.sync(action); _active = future;
    unawaited(future.then<void>((_) { if (identical(_active, future)) _active = null; },
      onError: (Object _, StackTrace __) { if (identical(_active, future)) _active = null; }));
    return future;
  }
  Future<TimewebMeetingJoinOutcome> _finish(TimewebMutationResult result) async {
    requireCurrent(); result.requireCurrent();
    final receipt = result.joinedMeeting;
    if (!result.canAcknowledge || (result.state == TimewebMutationState.confirmed && receipt == null)) {
      _receipt = null; _failure = result.failure; return _settled = TimewebMeetingJoinOutcome.unknown;
    }
    final confirmed = result.state == TimewebMutationState.confirmed;
    if (_intent != null) { await _journal._acknowledge(_intent!, requireCurrent); requireCurrent(); }
    _client.acknowledgeMutation(_reference!); _intent = null;
    if (!confirmed) _reference = null;
    _receipt = receipt?.bindSessionGuard(_lease.requireCurrent); _failure = result.failure;
    return _settled = confirmed ? TimewebMeetingJoinOutcome.confirmed : TimewebMeetingJoinOutcome.rejected;
  }
  void close() { _closed = true; _intent = null; _reference = null; _receipt = null; _failure = null; }
  @override
  String toString() => 'TimewebMeetingJoinFlow(<redacted>)';
}

/// One private original per origin + owner UID + meeting. No token, role, URL
/// chosen by a user or cursor enters the record. Exact readback precedes ACK.
final class TimewebMeetingJoinJournal {
  TimewebMeetingJoinJournal({Future<Directory> Function()? directory}) : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  static const _maximumBytes = 65536;
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action()); _tail = future.then<void>((_) {}, onError: (Object _) {}); return future;
  }
  Future<void> drain() => _tail;
  Future<File> _file(String origin, String uid, String meetingId) async {
    final root = await _directory(); final folder = Directory('${root.path}/clrs_native_meeting_join');
    await folder.create(recursive: true);
    final key = sha256.convert(utf8.encode('$origin\u0000$uid\u0000$meetingId'));
    return File('${folder.path}/$key.json');
  }
  Future<_MeetingJoinIntent?> _read(File file, String origin, String uid, String meetingId) async {
    if (!await file.exists()) return null;
    if (await file.length() > _maximumBytes) _invalidJoinIntent();
    final bytes = <int>[];
    await for (final chunk in file.openRead()) { if (bytes.length + chunk.length > _maximumBytes) _invalidJoinIntent(); bytes.addAll(chunk); }
    final raw = utf8.decode(bytes), data = jsonDecode(raw);
    if (data is! Map<String, dynamic> || jsonEncode(data) != raw || data.length != 7 ||
        data['version'] is! int || data['version'] != 1 || data['origin'] != origin || data['uid'] != uid ||
        data['operation'] != 'meeting.join.v1' || data['operationId'] is! String || data['requestHash'] is! String ||
        data['fields'] is! Map<String, dynamic>) _invalidJoinIntent();
    final fields = data['fields'] as Map<String, dynamic>;
    if (fields.length != 1 || fields['meetingId'] != meetingId) _invalidJoinIntent();
    try {
      final intent = _MeetingJoinIntent(origin, uid, meetingId, data['operationId']);
      if (intent.request.requestHash != data['requestHash']) _invalidJoinIntent(); return intent;
    } on ArgumentError { _invalidJoinIntent(); }
  }
  Future<_MeetingJoinIntent?> _load(String origin, String uid, String meetingId) =>
      _serial(() async => _read(await _file(origin, uid, meetingId), origin, uid, meetingId));
  Future<void> _prepare(_MeetingJoinIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid, intent.meetingId);
    if (await _read(file, intent.origin, intent.uid, intent.meetingId) != null) throw StateError('Original meeting join is unresolved.');
    final data = jsonEncode(intent.data); if (utf8.encode(data).length > _maximumBytes) _invalidJoinIntent();
    final temporary = File('${file.path}.${intent.request.operationId}.tmp');
    try { await temporary.writeAsString(data, flush: true); await temporary.rename(file.path); }
    finally { if (await temporary.exists()) await temporary.delete(); }
  });
  Future<void> _acknowledge(_MeetingJoinIntent intent, void Function() requireCurrent) => _serial(() async {
    requireCurrent(); final file = await _file(intent.origin, intent.uid, intent.meetingId); requireCurrent();
    final current = await _read(file, intent.origin, intent.uid, intent.meetingId); requireCurrent();
    if (current == null || current.request.operationId != intent.request.operationId || current.request.requestHash != intent.request.requestHash)
      throw StateError('Original private meeting join is unavailable.');
    await file.delete();
  });
  @override
  String toString() => 'TimewebMeetingJoinJournal(<redacted>)';
}
Never _invalidJoinIntent() => throw const FormatException('Invalid private meeting join intent.');
final class _MeetingJoinIntent {
  _MeetingJoinIntent(this.origin, this.uid, this.meetingId, String id)
    : request = TimewebMutationRequest.joinMeeting(operationId: id, meetingId: meetingId);
  factory _MeetingJoinIntent.create(String origin, String uid, String meetingId) {
    final random = Random.secure(), bytes = List.generate(16, (_) => 0);
    for (var i = 0; i < bytes.length; i++) { bytes[i] = random.nextInt(256); }
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return _MeetingJoinIntent(origin, uid, meetingId, '${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}');
  }
  final String origin, uid, meetingId;
  final TimewebMutationRequest request;
  Map<String, Object> get data => {'version': 1, 'origin': origin, 'uid': uid, 'operation': request.operation,
    'operationId': request.operationId, 'requestHash': request.requestHash, 'fields': {'meetingId': meetingId}};
}
