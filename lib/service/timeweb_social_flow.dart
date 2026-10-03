import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebSocialOutcome { confirmed, unknown }

/// One unresolved original action per API origin/current UID. Reopening offers
/// only receipt lookup, even when the server has not found that UUID yet.
final class TimewebSocialFlow {
  TimewebSocialFlow._(this._client, this._session, this._lease, this._journal);
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebSocialJournal _journal;
  _SocialIntent? _intent;
  TimewebMutationReference? _reference;
  Future<TimewebSocialOutcome>? _active;
  TimewebSocialReceipt? _receipt;
  TimewebMutationFailure? _failure;
  bool _closed = false;

  static Future<TimewebSocialFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebSocialJournal journal,
  }) async {
    lease.requireCurrent();
    final flow = TimewebSocialFlow._(client, session, lease, journal);
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
    if (_closed) throw StateError('Social action is closed.');
    _lease.requireCurrent();
  }

  String get ownerUid {
    requireCurrent();
    return _lease.identity.uid;
  }

  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout => _session.waitTimeout;
  bool get needsCheck {
    requireCurrent();
    return _intent != null || _active != null;
  }

  TimewebSocialAction? get pendingAction {
    requireCurrent();
    return _intent?.action;
  }

  TimewebSocialReceipt? get receipt {
    requireCurrent();
    return _receipt;
  }

  TimewebMutationFailure? get failure {
    requireCurrent();
    return _failure;
  }

  Future<TimewebSocialOutcome> submit(TimewebSocialAction action) {
    requireCurrent();
    if (_active != null) return _active!;
    if (_intent != null) throw StateError('Check the original social action.');
    return _track(() async {
      _receipt = null;
      _failure = null;
      final intent = _SocialIntent.create(_origin, _lease.identity.uid, action);
      await _journal._prepare(intent);
      requireCurrent();
      _intent = intent;
      _reference = _client.bindMutation(
        intent.request,
        expectedOwnerUid: _lease.identity.uid,
      );
      return _finish(await _client.mutate(_reference!));
    });
  }

  Future<TimewebSocialOutcome> check() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_reference == null || _intent == null) {
      throw StateError('No original social action.');
    }
    return _track(() async {
      _receipt = null;
      _failure = null;
      return _finish(await _client.reconcileMutation(_reference!));
    });
  }

  Future<TimewebSocialOutcome> _track(
    Future<TimewebSocialOutcome> Function() action,
  ) {
    final future = Future<TimewebSocialOutcome>.sync(action);
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

  Future<TimewebSocialOutcome> _finish(TimewebMutationResult result) async {
    requireCurrent();
    result.requireCurrent();
    _failure = result.failure;
    final receipt = result.socialReceipt;
    if (!result.canAcknowledge ||
        result.state != TimewebMutationState.confirmed ||
        receipt == null) {
      _receipt = null;
      return TimewebSocialOutcome.unknown;
    }
    await _journal._acknowledge(_intent!, requireCurrent);
    requireCurrent();
    _client.acknowledgeMutation(_reference!);
    _intent = null;
    _reference = null;
    _receipt = receipt.bindSessionGuard(_lease.requireCurrent);
    return TimewebSocialOutcome.confirmed;
  }

  void close() {
    _closed = true;
    _intent = null;
    _reference = null;
    _receipt = null;
    _failure = null;
  }

  @override
  String toString() => 'TimewebSocialFlow(<redacted>)';
}

/// No token, cursor, URL, binary or local media path is written here.
final class TimewebSocialJournal {
  TimewebSocialJournal({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  static const _maximumBytes = 32768;
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _) {});
    return future;
  }

  Future<void> drain() => _tail;
  Future<File> _file(String origin, String uid) async {
    final root = await _directory();
    final folder = Directory('${root.path}/clrs_native_social');
    await folder.create(recursive: true);
    final key = sha256.convert(utf8.encode('$origin\u0000$uid'));
    return File('${folder.path}/$key.json');
  }

  Future<_SocialIntent?> _read(File file, String origin, String uid) async {
    if (!await file.exists()) return null;
    if (await file.length() > _maximumBytes) _invalidIntent();
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > _maximumBytes) _invalidIntent();
      bytes.addAll(chunk);
    }
    final raw = utf8.decode(bytes), data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> ||
        jsonEncode(data) != raw ||
        data.length != 7 ||
        data['version'] is! int ||
        data['version'] != 1 ||
        data['origin'] != origin ||
        data['uid'] != uid ||
        data['operationId'] is! String ||
        data['payload'] is! Map<String, dynamic> ||
        data['requestHash'] is! String) {
      _invalidIntent();
    }
    try {
      final intent = _SocialIntent(
        origin,
        uid,
        data['operationId'],
        TimewebSocialAction.fromPayload(data['payload']),
      );
      if (intent.request.operation != data['operation'] ||
          intent.request.requestHash != data['requestHash']) {
        _invalidIntent();
      }
      return intent;
    } on ArgumentError {
      _invalidIntent();
    }
  }

  Future<_SocialIntent?> _load(String origin, String uid) =>
      _serial(() async => _read(await _file(origin, uid), origin, uid));
  Future<void> _prepare(_SocialIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid);
    if (await _read(file, intent.origin, intent.uid) != null) {
      throw StateError('Original social action is unresolved.');
    }
    final data = jsonEncode(intent.data);
    if (utf8.encode(data).length > _maximumBytes) _invalidIntent();
    final temporary = File('${file.path}.${intent.request.operationId}.tmp');
    try {
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<void> _acknowledge(
    _SocialIntent intent,
    void Function() requireCurrent,
  ) => _serial(() async {
    requireCurrent();
    final file = await _file(intent.origin, intent.uid);
    requireCurrent();
    final current = await _read(file, intent.origin, intent.uid);
    requireCurrent();
    if (current == null ||
        current.request.operationId != intent.request.operationId ||
        current.request.requestHash != intent.request.requestHash) {
      throw StateError('Original social intent is unavailable.');
    }
    await file.delete();
  });
  @override
  String toString() => 'TimewebSocialJournal(<redacted>)';
}

Never _invalidIntent() =>
    throw const FormatException('Invalid private social intent.');

final class _SocialIntent {
  _SocialIntent(this.origin, this.uid, String id, this.action)
    : request = TimewebMutationRequest.socialAction(
        operationId: id,
        action: action,
      );
  factory _SocialIntent.create(
    String origin,
    String uid,
    TimewebSocialAction action,
  ) {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    // A separate reference prevents any journal operation from deriving identity.
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return _SocialIntent(
      origin,
      uid,
      '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}',
      action,
    );
  }
  final String origin, uid;
  final TimewebSocialAction action;
  final TimewebMutationRequest request;
  Map<String, Object> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'operation': request.operation,
    'operationId': request.operationId,
    'payload': action.payload,
    'requestHash': request.requestHash,
  };
}
