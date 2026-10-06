import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebMeetingCreateOutcome { confirmed, rejected, unknown }

/// One exact owner/request/UUID is durable before POST. Restart only checks
/// that original receipt; not_found never authorizes an automatic resend.
final class TimewebMeetingCreateFlow {
  TimewebMeetingCreateFlow._(this._client, this._session, this._lease, this._journal);
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebMeetingCreateJournal _journal;
  _MeetingCreateIntent? _intent;
  TimewebMutationReference? _reference;
  Future<TimewebMeetingCreateOutcome>? _active;
  TimewebMeetingCreateOutcome? _settled;
  TimewebMeetingCreateReceipt? _receipt;
  TimewebMutationFailure? _failure;
  bool _closed = false;

  static Future<TimewebMeetingCreateFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebMeetingCreateJournal journal,
  }) async {
    lease.requireCurrent();
    final flow = TimewebMeetingCreateFlow._(client, session, lease, journal);
    flow._intent = await journal._load(flow._origin, lease.identity.uid);
    flow.requireCurrent();
    if (flow._intent != null) {
      flow._reference = client.bindMutation(
        flow._intent!.request,
        expectedOwnerUid: lease.identity.uid,
      );
    }
    return flow;
  }

  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() {
    if (_closed) throw StateError('Meeting creation is closed.');
    _lease.requireCurrent();
  }

  Stream<AppSessionState> get sessionStates => _session.states;
  String get ownerUid {
    requireCurrent();
    return _lease.identity.uid;
  }

  bool get needsCheck {
    requireCurrent();
    return _intent != null || _active != null || (_reference != null && _receipt == null);
  }

  bool get rejected {
    requireCurrent();
    return _settled == TimewebMeetingCreateOutcome.rejected;
  }

  TimewebMutationFailure? get failure {
    requireCurrent();
    return _failure;
  }

  TimewebMeetingCreateRequest? get pendingRequest {
    requireCurrent();
    return _intent?.fields;
  }

  TimewebMeetingCreateReceipt? get receipt {
    requireCurrent();
    return _receipt;
  }

  Future<TimewebMeetingCreateOutcome> submit(TimewebMeetingCreateRequest request) {
    requireCurrent();
    if (_active != null) return _active!;
    if (_intent != null || _settled != null) {
      throw StateError('Check the original meeting creation.');
    }
    if (request.fields['invitedUid'] == ownerUid)
      throw ArgumentError('Self invitation is unavailable.');
    return _track(() async {
      final intent = _MeetingCreateIntent.create(_origin, ownerUid, request);
      await _journal._prepare(intent);
      requireCurrent();
      _intent = intent;
      _reference = _client.bindMutation(intent.request, expectedOwnerUid: ownerUid);
      return _finish(await _client.mutate(_reference!));
    });
  }

  Future<TimewebMeetingCreateOutcome> check() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_settled == TimewebMeetingCreateOutcome.rejected) return Future.value(_settled);
    if (_reference == null) throw StateError('No original meeting to look up.');
    return _track(() async {
      _receipt = null;
      _failure = null;
      _settled = TimewebMeetingCreateOutcome.unknown;
      return _finish(await _client.reconcileMutation(_reference!));
    });
  }

  Future<TimewebMeetingCreateOutcome> _track(
    Future<TimewebMeetingCreateOutcome> Function() action,
  ) {
    final future = Future<TimewebMeetingCreateOutcome>.sync(action);
    _active = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_active, future)) _active = null;
        },
        onError: (Object _, StackTrace __) {
          if (identical(_active, future)) _active = null;
        },
      ),
    );
    return future;
  }

  Future<TimewebMeetingCreateOutcome> _finish(TimewebMutationResult result) async {
    requireCurrent();
    result.requireCurrent();
    final receipt = result.createdMeeting;
    if (!result.canAcknowledge ||
        (result.state == TimewebMutationState.confirmed && receipt == null)) {
      _receipt = null;
      _failure = result.failure;
      return _settled = TimewebMeetingCreateOutcome.unknown;
    }
    final confirmed = result.state == TimewebMutationState.confirmed;
    if (_intent != null) {
      await _journal._acknowledge(_intent!, requireCurrent);
      requireCurrent();
    }
    _client.acknowledgeMutation(_reference!);
    _intent = null;
    if (!confirmed) _reference = null;
    // Route close clears the flow, but this receipt keeps the same native lease.
    _receipt = receipt?.bindSessionGuard(_lease.requireCurrent);
    _failure = result.failure;
    return _settled = confirmed
        ? TimewebMeetingCreateOutcome.confirmed
        : TimewebMeetingCreateOutcome.rejected;
  }

  void close() {
    _closed = true;
    _intent = null;
    _reference = null;
    _receipt = null;
    _failure = null;
  }

  @override
  String toString() => 'TimewebMeetingCreateFlow(<redacted>)';
}

/// Application-private original fields only; no bearer, password or cursor.
final class TimewebMeetingCreateJournal {
  TimewebMeetingCreateJournal({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  static const _maximumBytes = 65536;
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _) {});
    return future;
  }

  Future<void> drain() => _tail;
  Future<File> _file(String origin, String uid) async {
    final root = await _directory();
    final folder = Directory('${root.path}/clrs_native_meeting_create');
    await folder.create(recursive: true);
    final key = sha256.convert(utf8.encode('$origin\u0000$uid'));
    return File('${folder.path}/$key.json');
  }

  Future<_MeetingCreateIntent?> _read(File file, String origin, String uid) async {
    if (!await file.exists()) return null;
    if (await file.length() > _maximumBytes) _invalidMeetingIntent();
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > _maximumBytes) _invalidMeetingIntent();
      bytes.addAll(chunk);
    }
    final raw = utf8.decode(bytes);
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        jsonEncode(data) != raw ||
        data.length != 7 ||
        data['version'] is! int ||
        data['version'] != 1 ||
        data['origin'] != origin ||
        data['uid'] != uid ||
        data['operation'] != 'meeting.create.v1' ||
        data['operationId'] is! String ||
        data['requestHash'] is! String ||
        data['fields'] is! Map<String, dynamic>) {
      _invalidMeetingIntent();
    }
    final fields = data['fields'] as Map<String, dynamic>;
    if (fields.values.any((value) => value is! String) || fields['invitedUid'] == uid)
      _invalidMeetingIntent();
    try {
      final request = await TimewebMeetingCreateRequest.fromCatalog(
        name: fields['name'],
        description: fields['description'],
        countryCode: fields['countryCode'],
        region: fields['region'],
        datetime: fields['datetime'],
        type: fields['type'],
        invitedUid: fields['invitedUid'],
      );
      final intent = _MeetingCreateIntent(origin, uid, data['operationId'], request);
      if (request.fields.length != fields.length ||
          request.fields.entries.any((entry) => fields[entry.key] != entry.value) ||
          intent.request.requestHash != data['requestHash'])
        _invalidMeetingIntent();
      return intent;
    } on ArgumentError {
      _invalidMeetingIntent();
    } on TypeError {
      _invalidMeetingIntent();
    }
  }

  Future<_MeetingCreateIntent?> _load(String origin, String uid) =>
      _serial(() async => _read(await _file(origin, uid), origin, uid));
  Future<void> _prepare(_MeetingCreateIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid);
    if (await _read(file, intent.origin, intent.uid) != null) {
      throw StateError('Original meeting creation is unresolved.');
    }
    final data = jsonEncode(intent.data);
    if (utf8.encode(data).length > _maximumBytes) _invalidMeetingIntent();
    final temporary = File('${file.path}.${intent.request.operationId}.tmp');
    try {
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<void> _acknowledge(_MeetingCreateIntent intent, void Function() requireCurrent) =>
      _serial(() async {
        requireCurrent();
        final file = await _file(intent.origin, intent.uid);
        requireCurrent();
        final current = await _read(file, intent.origin, intent.uid);
        requireCurrent();
        if (current == null ||
            current.request.operationId != intent.request.operationId ||
            current.request.requestHash != intent.request.requestHash) {
          throw StateError('Original private meeting intent is unavailable.');
        }
        await file.delete();
      });
  @override
  String toString() => 'TimewebMeetingCreateJournal(<redacted>)';
}

Never _invalidMeetingIntent() => throw const FormatException('Invalid private meeting intent.');

final class _MeetingCreateIntent {
  _MeetingCreateIntent(this.origin, this.uid, String id, this.fields)
    : request = TimewebMutationRequest.createMeeting(operationId: id, request: fields);
  factory _MeetingCreateIntent.create(
    String origin,
    String uid,
    TimewebMeetingCreateRequest fields,
  ) {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
    return _MeetingCreateIntent(origin, uid, id, fields);
  }
  final String origin, uid;
  final TimewebMeetingCreateRequest fields;
  final TimewebMutationRequest request;
  Map<String, Object> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'operation': request.operation,
    'operationId': request.operationId,
    'requestHash': request.requestHash,
    'fields': fields.fields,
  };
}
