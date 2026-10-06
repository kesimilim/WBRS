import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebPersonalChatOutcome { confirmed, rejected, unknown }

/// One original target/UUID/hash is durable before POST. Reopening this flow
/// only offers fresh receipt lookup; an absent receipt never permits resend.
final class TimewebPersonalChatFlow {
  TimewebPersonalChatFlow._(
    this._client,
    this._session,
    this._lease,
    this._journal,
    this._targetUid,
  );
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebPersonalChatJournal _journal;
  String? _targetUid;
  _PersonalChatIntent? _intent;
  TimewebMutationReference? _reference;
  Future<TimewebPersonalChatOutcome>? _active;
  TimewebPersonalChatOutcome? _settled;
  TimewebOpenedPersonalChatReceipt? _receipt;
  TimewebMutationFailure? _failure;
  bool _closed = false;

  static Future<TimewebPersonalChatFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebPersonalChatJournal journal,
    required String targetUid,
  }) async {
    lease.requireCurrent();
    // Use the exact request validator before any journal path or server call.
    TimewebMutationRequest.openPersonalChat(
      operationId: '00000000-0000-4000-8000-000000000000',
      targetUid: targetUid,
    );
    if (targetUid == lease.identity.uid) {
      throw ArgumentError('Self chat is unavailable.');
    }
    final flow = TimewebPersonalChatFlow._(
      client,
      session,
      lease,
      journal,
      targetUid,
    );
    flow._intent = await journal._load(
      flow._origin,
      lease.identity.uid,
      targetUid,
    );
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
    if (_closed) throw StateError('Personal chat action is closed.');
    _lease.requireCurrent();
  }

  Stream<AppSessionState> get sessionStates => _session.states;
  bool get needsCheck {
    requireCurrent();
    return _intent != null ||
        _active != null ||
        (_reference != null && _receipt == null);
  }

  bool get rejected {
    requireCurrent();
    return _settled == TimewebPersonalChatOutcome.rejected;
  }

  TimewebMutationFailure? get failure {
    requireCurrent();
    return _failure;
  }

  TimewebOpenedPersonalChatReceipt? get receipt {
    requireCurrent();
    return _receipt;
  }

  Future<TimewebPersonalChatOutcome> submit() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_intent != null || _settled != null) {
      throw StateError('Check the original chat action.');
    }
    return _track(() async {
      final intent = _PersonalChatIntent.create(
        _origin,
        _lease.identity.uid,
        _targetUid!,
      );
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

  Future<TimewebPersonalChatOutcome> check() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_settled == TimewebPersonalChatOutcome.rejected) {
      return Future.value(_settled);
    }
    if (_reference == null) {
      throw StateError('No original personal chat to look up.');
    }
    return _track(() async {
      // Acknowledged original references remain in RAM for reopening this pair.
      // Drop usable cache before the fresh guard, including thrown 401/503.
      _receipt = null;
      _failure = null;
      _settled = TimewebPersonalChatOutcome.unknown;
      return _finish(await _client.reconcileMutation(_reference!));
    });
  }

  Future<TimewebPersonalChatOutcome> _track(
    Future<TimewebPersonalChatOutcome> Function() action,
  ) {
    final future = Future<TimewebPersonalChatOutcome>.sync(action);
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

  Future<TimewebPersonalChatOutcome> _finish(
    TimewebMutationResult result,
  ) async {
    requireCurrent();
    result.requireCurrent();
    final receipt = result.openedPersonalChat;
    if (!result.canAcknowledge ||
        (result.state == TimewebMutationState.confirmed && receipt == null)) {
      _receipt = null;
      _failure = result.failure;
      return _settled = TimewebPersonalChatOutcome.unknown;
    }
    final confirmed = result.state == TimewebMutationState.confirmed;
    if (_intent != null) {
      await _journal._acknowledge(_intent!, requireCurrent);
      requireCurrent();
    }
    _client.acknowledgeMutation(_reference!);
    _intent = null;
    // Confirmed reference is retained only in this current owner/epoch's RAM.
    // Its journal is already acknowledged, but every reopen still uses lookup.
    if (!confirmed) {
      _reference = null;
    }
    // The opened conversation survives leaving the public profile, but retains
    // the same session lease/client epoch; the action's close is not a logout.
    _receipt = receipt?.bindSessionGuard(_lease.requireCurrent);
    _failure = result.failure;
    return _settled = confirmed
        ? TimewebPersonalChatOutcome.confirmed
        : TimewebPersonalChatOutcome.rejected;
  }

  void close() {
    _closed = true;
    _targetUid = null;
    _intent = null;
    _reference = null;
    _receipt = null;
    _failure = null;
  }

  @override
  String toString() => 'TimewebPersonalChatFlow(<redacted>)';
}

/// Bounded application-private original request. No credential or media fields.
final class TimewebPersonalChatJournal {
  TimewebPersonalChatJournal({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  static const _maximumBytes = 8192;
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _) {});
    return future;
  }

  Future<void> drain() => _tail;
  Future<File> _file(String origin, String uid, String target) async {
    final root = await _directory();
    final folder = Directory('${root.path}/clrs_native_personal_chat');
    await folder.create(recursive: true);
    final key = sha256.convert(utf8.encode('$origin\u0000$uid\u0000$target'));
    return File('${folder.path}/$key.json');
  }

  Future<_PersonalChatIntent?> _read(
    File file,
    String origin,
    String uid,
    String target,
  ) async {
    if (!await file.exists()) return null;
    if (await file.length() > _maximumBytes) _invalidPersonalChatIntent();
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > _maximumBytes) {
        _invalidPersonalChatIntent();
      }
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
        data['operation'] != 'chat.open-personal.v1' ||
        data['operationId'] is! String ||
        data['targetUid'] != target ||
        data['requestHash'] is! String) {
      _invalidPersonalChatIntent();
    }
    try {
      final intent = _PersonalChatIntent(
        origin,
        uid,
        data['operationId'],
        target,
      );
      if (intent.request.requestHash != data['requestHash']) {
        _invalidPersonalChatIntent();
      }
      return intent;
    } on ArgumentError {
      _invalidPersonalChatIntent();
    }
  }

  Future<_PersonalChatIntent?> _load(
    String origin,
    String uid,
    String target,
  ) => _serial(
    () async => _read(await _file(origin, uid, target), origin, uid, target),
  );
  Future<void> _prepare(_PersonalChatIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid, intent.targetUid);
    if (await _read(file, intent.origin, intent.uid, intent.targetUid) !=
        null) {
      throw StateError('Original personal_chat operation is unresolved.');
    }
    final data = jsonEncode(intent.data);
    if (utf8.encode(data).length > _maximumBytes) _invalidPersonalChatIntent();
    final temporary = File('${file.path}.${intent.request.operationId}.tmp');
    try {
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<void> _acknowledge(
    _PersonalChatIntent intent,
    void Function() requireCurrent,
  ) => _serial(() async {
    requireCurrent();
    final file = await _file(intent.origin, intent.uid, intent.targetUid);
    requireCurrent();
    final current = await _read(
      file,
      intent.origin,
      intent.uid,
      intent.targetUid,
    );
    requireCurrent();
    if (current == null ||
        current.request.operationId != intent.request.operationId ||
        current.request.requestHash != intent.request.requestHash) {
      throw StateError('Original private personal_chat intent is unavailable.');
    }
    await file.delete();
  });
  @override
  String toString() => 'TimewebPersonalChatJournal(<redacted>)';
}

Never _invalidPersonalChatIntent() =>
    throw const FormatException('Invalid private personal_chat intent.');

final class _PersonalChatIntent {
  _PersonalChatIntent(this.origin, this.uid, String id, this.targetUid)
    : request = TimewebMutationRequest.openPersonalChat(
        operationId: id,
        targetUid: targetUid,
      );
  factory _PersonalChatIntent.create(
    String origin,
    String uid,
    String targetUid,
  ) {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return _PersonalChatIntent(origin, uid, id, targetUid);
  }
  final String origin, uid, targetUid;
  final TimewebMutationRequest request;
  Map<String, Object> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'targetUid': targetUid,
    'operation': request.operation,
    'operationId': request.operationId,
    'requestHash': request.requestHash,
  };
}
