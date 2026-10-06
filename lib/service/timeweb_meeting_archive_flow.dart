import 'dart:async';
import 'app_session.dart';
import 'timeweb_auth_client.dart';

/// Read-only owner archive. It never opens current member chat, resolves a
/// protected roster, sends a message or modifies a durable mutation original.
final class TimewebMeetingArchiveFlow {
  TimewebMeetingArchiveFlow._(this._client, this._session, this._lease, this._meetingId);
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final String _meetingId;
  List<TimewebMeetingMessage> _messages = [];
  TimewebMeetingArchiveWindow? _window;
  TimewebMeetingArchiveCursor? _older;
  void Function()? _readAuthority;
  Future<void>? _readFlight;
  bool _closed = false, _available = true;
  static const _limit = 30, _maximumMessages = 300;
  static Future<TimewebMeetingArchiveFlow> open({required TimewebAuthClient client,
    required AppSession session, required AppSessionLease lease, required String meetingId}) async {
    lease.requireCurrent(); TimewebMeetingLeaveRequest(meetingId: meetingId);
    final flow = TimewebMeetingArchiveFlow._(client, session, lease, meetingId);
    await flow._load(initial: true); flow.requireCurrent(); return flow;
  }
  void requireCurrent() {
    if (_closed) throw StateError('Meeting archive is closed.');
    _lease.requireCurrent(); if (!_available) throw const TimewebMeetingArchiveUnavailable();
    _readAuthority?.call();
  }
  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout => _client.requestDeadline + const Duration(seconds: 2);
  String get ownerUid { requireCurrent(); return _lease.identity.uid; }
  String get meetingId { requireCurrent(); return _meetingId; }
  TimewebMeetingArchiveWindow get window { requireCurrent(); return _window!; }
  List<TimewebMeetingMessage> get messages { requireCurrent(); return List.unmodifiable(_messages); }
  bool get hasOlder { requireCurrent(); return _older != null; }
  bool get targetAvailable {
    _lease.requireCurrent(); if (_closed || !_available) return false;
    try { requireCurrent(); return true; } on TimewebMeetingNotFound { return false; }
  }
  Future<void> loadOlder() => _load();
  Future<void> _load({bool initial = false}) {
    requireCurrent(); if (_readFlight != null) return _readFlight!;
    if (!initial && _older == null) return Future.value();
    final future = (() async {
      try {
        final page = await _client.readMeetingArchive(_meetingId, limit: _limit, cursor: initial ? null : _older);
        requireCurrent(); page.requireCurrent();
        _readAuthority = page.requireCurrent;
        _window ??= page.window.bindSessionGuard(requireCurrent);
        final rows = <String, TimewebMeetingMessage>{}, sequences = <int>{};
        for (final item in [..._messages, ...page.items]) {
          if (rows.containsKey(item.messageId) || !sequences.add(item.sequence)) {
            throw const TimewebAuthException(TimewebAuthOperation.currentRead, TimewebAuthError.invalidResponse);
          }
          rows[item.messageId] = item.bindSessionGuard(requireCurrent);
        }
        final ordered = rows.values.toList()..sort((a, b) => b.sequence.compareTo(a.sequence));
        if (ordered.length > _maximumMessages) { ordered.removeRange(0, ordered.length - _maximumMessages); }
        _messages = ordered; _older = page.nextCursor;
      } on TimewebMeetingArchiveUnavailable { _deny(); rethrow; }
      on TimewebMeetingNotFound { _deny(); rethrow; }
      on TimewebAuthException catch (error) {
        if (const {TimewebAuthError.invalidRequest, TimewebAuthError.invalidResponse}.contains(error.error)) { _deny(); }
        rethrow;
      }
    })();
    _readFlight = future;
    unawaited(future.then<void>((_) { if (identical(_readFlight, future)) _readFlight = null; },
      onError: (Object _, StackTrace __) { if (identical(_readFlight, future)) _readFlight = null; })); return future;
  }
  void _deny() { _available = false; _messages = []; _older = null; _window = null; }
  void close() { _closed = true; _messages = []; _older = null; _window = null; }
  @override
  String toString() => 'TimewebMeetingArchiveFlow(<redacted>)';
}
