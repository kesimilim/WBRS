import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebMeetingMembershipOutcome { confirmed, rejected, unknown }

/// Restore requires only the current owner lease. A committed own leave may
/// already deny messages; it must still be possible to look up its original.
final class TimewebMeetingMembershipFlow {
  TimewebMeetingMembershipFlow._(this._client, this._session, this._lease, this._journal, this._meetingId, this._kick);
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebMeetingMembershipJournal _journal;
  final String _meetingId;
  final bool _kick;
  _MembershipIntent? _intent;
  TimewebMutationReference? _reference;
  Future<TimewebMeetingMembershipOutcome>? _active;
  TimewebMeetingMembershipOutcome? _settled;
  TimewebMeetingLeaveReceipt? _leaveReceipt;
  TimewebMeetingKickReceipt? _kickReceipt;
  TimewebMutationFailure? _failure;
  String? _targetUid;
  bool _closed = false;
  static Future<TimewebMeetingMembershipFlow> open({required TimewebAuthClient client,
    required AppSession session, required AppSessionLease lease, required TimewebMeetingMembershipJournal journal,
    required String meetingId, required bool kick}) async {
    lease.requireCurrent(); TimewebMeetingLeaveRequest(meetingId: meetingId);
    final flow = TimewebMeetingMembershipFlow._(client, session, lease, journal, meetingId, kick);
    flow._intent = await journal._load(flow._origin, lease.identity.uid, meetingId, kick);
    flow.requireCurrent(); flow._targetUid = flow._intent?.targetUid;
    if (flow._intent != null) flow._reference = client.bindMutation(flow._intent!.request, expectedOwnerUid: lease.identity.uid);
    return flow;
  }
  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() { if (_closed) throw StateError('Meeting membership action is closed.'); _lease.requireCurrent(); }
  Stream<AppSessionState> get sessionStates => _session.states;
  String get ownerUid { requireCurrent(); return _lease.identity.uid; }
  String get meetingId { requireCurrent(); return _meetingId; }
  String? get targetUid { requireCurrent(); return _targetUid; }
  bool get needsCheck { requireCurrent(); return _intent != null || _active != null || (_reference != null && _settled != TimewebMeetingMembershipOutcome.confirmed); }
  bool get rejected { requireCurrent(); return _settled == TimewebMeetingMembershipOutcome.rejected; }
  TimewebMutationFailure? get failure { requireCurrent(); return _failure; }
  TimewebMeetingLeaveReceipt? get leaveReceipt { requireCurrent(); return _leaveReceipt; }
  TimewebMeetingKickReceipt? get kickReceipt { requireCurrent(); return _kickReceipt; }
  Future<TimewebMeetingMembershipOutcome> submit({String? targetUid}) {
    requireCurrent();
    if (_active != null) {
      if (targetUid != _targetUid) throw StateError('Original membership target is already bound.');
      return _active!;
    }
    if (_intent != null || _settled != null) throw StateError('Check the original membership action.');
    if (_kick ? targetUid == null : targetUid != null) throw ArgumentError('Invalid membership action target.');
    final intent = _MembershipIntent.create(_origin, ownerUid, _meetingId, _kick, targetUid);
    _targetUid = targetUid;
    return _track(() async {
      await _journal._prepare(intent); requireCurrent(); _intent = intent; _targetUid = targetUid;
      _reference = _client.bindMutation(intent.request, expectedOwnerUid: ownerUid);
      return _finish(await _client.mutate(_reference!));
    });
  }
  Future<TimewebMeetingMembershipOutcome> check() {
    requireCurrent(); if (_active != null) return _active!;
    if (_settled == TimewebMeetingMembershipOutcome.rejected) return Future.value(_settled);
    if (_reference == null) throw StateError('No original membership action to look up.');
    return _track(() async {
      _leaveReceipt = null; _kickReceipt = null; _failure = null; _settled = TimewebMeetingMembershipOutcome.unknown;
      return _finish(await _client.reconcileMutation(_reference!));
    });
  }
  Future<TimewebMeetingMembershipOutcome> _track(Future<TimewebMeetingMembershipOutcome> Function() action) {
    final future = Future<TimewebMeetingMembershipOutcome>.sync(action); _active = future;
    unawaited(future.then<void>((_) { if (identical(_active, future)) _active = null; },
      onError: (Object _, StackTrace __) { if (identical(_active, future)) _active = null; })); return future;
  }
  Future<TimewebMeetingMembershipOutcome> _finish(TimewebMutationResult result) async {
    requireCurrent(); result.requireCurrent();
    final leave = result.leftMeeting, kick = result.kickedParticipant;
    if (!result.canAcknowledge || (result.state == TimewebMutationState.confirmed && (_kick ? kick == null : leave == null))) {
      _leaveReceipt = null; _kickReceipt = null; _failure = result.failure;
      return _settled = TimewebMeetingMembershipOutcome.unknown;
    }
    final confirmed = result.state == TimewebMutationState.confirmed;
    if (_intent != null) { await _journal._acknowledge(_intent!, requireCurrent); requireCurrent(); }
    // Disk readback/ACK precedes local read-authority retirement and UI success.
    _client.acknowledgeMutation(_reference!); _intent = null;
    if (!confirmed) _reference = null;
    _leaveReceipt = leave?.bindSessionGuard(_lease.requireCurrent);
    _kickReceipt = kick?.bindSessionGuard(_lease.requireCurrent); _failure = result.failure;
    return _settled = confirmed ? TimewebMeetingMembershipOutcome.confirmed : TimewebMeetingMembershipOutcome.rejected;
  }
  void close() { _closed = true; _intent = null; _reference = null; _leaveReceipt = null; _kickReceipt = null; _failure = null; _targetUid = null; }
  @override
  String toString() => 'TimewebMeetingMembershipFlow(<redacted>)';
}

/// One original per origin/owner/meeting/action; kick target stays inside the
/// exact original rather than selecting a different pending target on restart.
final class TimewebMeetingMembershipJournal {
  TimewebMeetingMembershipJournal({Future<Directory> Function()? directory}) : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action()); _tail = future.then<void>((_) {}, onError: (Object _) {}); return future;
  }
  Future<void> drain() => _tail;
  Future<File> _file(String origin, String uid, String meetingId, bool kick) async {
    final root = await _directory(), key = sha256.convert(utf8.encode('$origin\u0000$uid\u0000$meetingId\u0000${kick ? 'kick' : 'leave'}'));
    final folder = Directory('${root.path}/clrs_native_meeting_membership'); await folder.create(recursive: true);
    return File('${folder.path}/$key.json');
  }
  Future<_MembershipIntent?> _read(File file, String origin, String uid, String meetingId, bool kick) async {
    if (!await file.exists()) return null;
    if (await file.length() > 65536) _invalidMembershipIntent();
    final bytes = <int>[];
    await for (final chunk in file.openRead()) { if (bytes.length + chunk.length > 65536) { _invalidMembershipIntent(); } bytes.addAll(chunk); }
    final raw = utf8.decode(bytes), data = jsonDecode(raw);
    if (data is! Map<String, dynamic> || jsonEncode(data) != raw || data.length != 7 || data['version'] is! int || data['version'] != 1 ||
        data['origin'] != origin || data['uid'] != uid || data['operation'] != (kick ? 'meeting.kick.v1' : 'meeting.leave.v1') ||
        data['operationId'] is! String || data['requestHash'] is! String || data['fields'] is! Map<String, dynamic>) { _invalidMembershipIntent(); }
    final fields = data['fields'] as Map<String, dynamic>;
    if (fields.length != (kick ? 2 : 1) || fields['meetingId'] != meetingId || kick && fields['targetUid'] is! String) _invalidMembershipIntent();
    try {
      final intent = _MembershipIntent(origin, uid, meetingId, kick, fields['targetUid'], data['operationId']);
      if (intent.request.requestHash != data['requestHash']) _invalidMembershipIntent(); return intent;
    } on ArgumentError { _invalidMembershipIntent(); }
  }
  Future<_MembershipIntent?> _load(String origin, String uid, String meetingId, bool kick) =>
      _serial(() async => _read(await _file(origin, uid, meetingId, kick), origin, uid, meetingId, kick));
  Future<void> _prepare(_MembershipIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid, intent.meetingId, intent.kick);
    if (await _read(file, intent.origin, intent.uid, intent.meetingId, intent.kick) != null) throw StateError('Original membership action is unresolved.');
    final data = jsonEncode(intent.data); if (utf8.encode(data).length > 65536) _invalidMembershipIntent();
    final temporary = File('${file.path}.${intent.request.operationId}.tmp');
    try { await temporary.writeAsString(data, flush: true); await temporary.rename(file.path); }
    finally { if (await temporary.exists()) await temporary.delete(); }
  });
  Future<void> _acknowledge(_MembershipIntent intent, void Function() requireCurrent) => _serial(() async {
    requireCurrent(); final file = await _file(intent.origin, intent.uid, intent.meetingId, intent.kick); requireCurrent();
    final current = await _read(file, intent.origin, intent.uid, intent.meetingId, intent.kick); requireCurrent();
    if (current == null || current.request.operationId != intent.request.operationId || current.request.requestHash != intent.request.requestHash)
      { throw StateError('Original private membership action is unavailable.'); } await file.delete();
  });
  @override
  String toString() => 'TimewebMeetingMembershipJournal(<redacted>)';
}
Never _invalidMembershipIntent() => throw const FormatException('Invalid private meeting membership intent.');
final class _MembershipIntent {
  _MembershipIntent(this.origin, this.uid, this.meetingId, this.kick, this.targetUid, String id)
    : request = kick ? TimewebMutationRequest.kickMeetingParticipant(operationId: id, meetingId: meetingId, targetUid: targetUid!) :
        TimewebMutationRequest.leaveMeeting(operationId: id, meetingId: meetingId);
  factory _MembershipIntent.create(String origin, String uid, String meetingId, bool kick, String? targetUid) {
    final random = Random.secure(), bytes = List.generate(16, (_) => 0);
    for (var i = 0; i < bytes.length; i++) { bytes[i] = random.nextInt(256); }
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return _MembershipIntent(origin, uid, meetingId, kick, targetUid, '${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}');
  }
  final String origin, uid, meetingId;
  final bool kick;
  final String? targetUid;
  final TimewebMutationRequest request;
  Map<String, Object> get data => {'version': 1, 'origin': origin, 'uid': uid, 'operation': request.operation,
    'operationId': request.operationId, 'requestHash': request.requestHash,
    'fields': {'meetingId': meetingId, if (kick) 'targetUid': targetUid!}};
}
