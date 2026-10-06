import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebTemperamentOutcome { confirmed, rejected, unknown }

/// A completed profile without an original pending test needs no recovery UI.
final class TimewebNoPendingTemperament extends StateError {
  TimewebNoPendingTemperament()
    : super('No original questionnaire operation to check.');
}

/// One native questionnaire lease. Answers are canonical brown/red/blue/white
/// blocks of twenty; the server determines the group and registration state.
final class TimewebTemperamentFlow {
  TimewebTemperamentFlow._(
    this._client,
    this._session,
    this._lease,
    this._journal,
    this._snapshot,
  );
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebTemperamentJournal _journal;
  final TimewebCurrentOwnProfile _snapshot;
  _TemperamentIntent? _intent;
  TimewebMutationReference? _reference;
  Future<TimewebTemperamentOutcome>? _active;
  TimewebTemperamentOutcome? _settled;
  List<bool> _answers = List.unmodifiable(List<bool>.filled(80, false));
  String? _confirmedGroup;
  TimewebMutationFailure? _rejectionFailure;
  bool _closed = false, _requiresReload = false;

  static Future<TimewebTemperamentFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebTemperamentJournal journal,
    required TimewebCurrentOwnProfile snapshot,
  }) async {
    lease.requireCurrent();
    snapshot.requireCurrent();
    if (!snapshot.profileExists ||
        snapshot.uid != lease.identity.uid ||
        snapshot.profileAuthority != 'canonical-current-v1') {
      throw StateError('Current questionnaire profile is unavailable.');
    }
    final flow = TimewebTemperamentFlow._(
      client,
      session,
      lease,
      journal,
      snapshot,
    );
    final intent = await journal._load(flow._origin, snapshot.uid);
    flow.requireCurrent();
    // After a lost ACK a committed profile may already be complete. Recovery
    // can only look up that original operation; it cannot post a second test.
    if (snapshot.onboarding == TimewebOnboarding.search && intent == null) {
      throw TimewebNoPendingTemperament();
    }
    if (snapshot.onboarding != TimewebOnboarding.test &&
        !(intent != null && snapshot.onboarding == TimewebOnboarding.search)) {
      throw StateError('Current profile is not ready for the questionnaire.');
    }
    if (intent != null) {
      flow._intent = intent;
      flow._answers = intent.answers;
      flow._reference = client.bindMutation(
        intent.request,
        expectedOwnerUid: snapshot.uid,
      );
    }
    return flow;
  }

  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() {
    if (_closed) throw StateError('Questionnaire is closed.');
    _lease.requireCurrent();
    _snapshot.requireCurrent();
  }

  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout =>
      _client.requestDeadline + const Duration(seconds: 2);
  List<bool> get initialAnswers {
    requireCurrent();
    return _answers;
  }

  String? get confirmedGroup {
    requireCurrent();
    return _confirmedGroup;
  }

  TimewebMutationFailure? get rejectionFailure {
    requireCurrent();
    return _rejectionFailure;
  }

  bool get needsCheck {
    requireCurrent();
    return _intent != null ||
        _active != null ||
        _settled == TimewebTemperamentOutcome.confirmed;
  }

  bool get requiresReload {
    requireCurrent();
    return _requiresReload;
  }

  Future<TimewebTemperamentOutcome> submit(List<bool> answers) {
    requireCurrent();
    if (_active != null) return _active!;
    if (_intent != null || _requiresReload || _settled != null) {
      throw StateError('Check or reload the original questionnaire operation.');
    }
    final intent = _TemperamentIntent.create(
      _origin,
      _snapshot.uid,
      _snapshot.profile!.updatedAt,
      answers,
    );
    _answers = intent.answers;
    return _track(() async {
      // Persist exact answers, UUID, owner, stamp and hash before any POST.
      await _journal._prepare(intent);
      requireCurrent();
      _intent = intent;
      _reference = _client.bindMutation(
        intent.request,
        expectedOwnerUid: _snapshot.uid,
      );
      return _finish(await _client.mutate(_reference!));
    });
  }

  Future<TimewebTemperamentOutcome> check() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_settled != null && _settled != TimewebTemperamentOutcome.unknown) {
      return Future.value(_settled);
    }
    if (_reference == null) throw StateError('No original test to look up.');
    return _track(
      () async => _finish(await _client.reconcileMutation(_reference!)),
    );
  }

  Future<TimewebTemperamentOutcome> _track(
    Future<TimewebTemperamentOutcome> Function() action,
  ) {
    final future = Future<TimewebTemperamentOutcome>.sync(action);
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

  Future<TimewebTemperamentOutcome> _finish(
    TimewebMutationResult result,
  ) async {
    requireCurrent();
    result.requireCurrent();
    final receipt = result.completedTemperament;
    if (!result.canAcknowledge ||
        (result.state == TimewebMutationState.confirmed && receipt == null)) {
      // A not_found lookup never establishes that a prior POST cannot commit.
      return _settled = TimewebTemperamentOutcome.unknown;
    }
    final confirmed = result.state == TimewebMutationState.confirmed;
    final group = confirmed ? receipt!.primaryGroup : null;
    final failure = result.failure;
    await _journal._acknowledge(_intent!, requireCurrent);
    requireCurrent();
    _client.acknowledgeMutation(_reference!);
    _intent = null;
    _reference = null;
    _confirmedGroup = group;
    _rejectionFailure = failure;
    _requiresReload = !confirmed;
    return _settled = confirmed
        ? TimewebTemperamentOutcome.confirmed
        : TimewebTemperamentOutcome.rejected;
  }

  void close() => _closed = true;
  @override
  String toString() => 'TimewebTemperamentFlow(<redacted>)';
}

/// Application-private original answers, never credentials. One runtime owns
/// serialized IO; owner replacement awaits drain before opening another owner.
final class TimewebTemperamentJournal {
  TimewebTemperamentJournal({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  static const _maximumBytes = 16384;
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _) {});
    return future;
  }

  Future<void> drain() => _tail;
  Future<File> _file(String origin, String uid) async {
    final root = await _directory();
    final folder = Directory('${root.path}/clrs_native_temperament');
    await folder.create(recursive: true);
    final key = sha256.convert(utf8.encode('$origin\u0000$uid'));
    return File('${folder.path}/$key.json');
  }

  Future<_TemperamentIntent?> _read(
    File file,
    String origin,
    String uid,
  ) async {
    if (!await file.exists()) return null;
    if (await file.length() > _maximumBytes) _invalidIntent();
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > _maximumBytes) _invalidIntent();
      bytes.addAll(chunk);
    }
    final raw = utf8.decode(bytes);
    final data = jsonDecode(raw);
    // Exact compact JSON refuses duplicate keys, extra fields and format drift.
    if (data is! Map<String, dynamic> ||
        jsonEncode(data) != raw ||
        data.length != 9 ||
        data['version'] is! int ||
        data['version'] != 1 ||
        data['origin'] != origin ||
        data['uid'] != uid ||
        data['operation'] != 'profile.complete-test.v1' ||
        data['operationId'] is! String ||
        data['expectedUpdatedAt'] is! String ||
        data['requestHash'] is! String ||
        data['answersHash'] is! String ||
        data['answers'] is! List) {
      _invalidIntent();
    }
    final answers = data['answers'] as List;
    if (answers.length != 80 || answers.any((value) => value is! bool)) {
      _invalidIntent();
    }
    try {
      final intent = _TemperamentIntent(
        origin,
        uid,
        data['operationId'],
        data['expectedUpdatedAt'],
        answers.cast<bool>(),
      );
      if (intent.request.requestHash != data['requestHash'] ||
          intent.answersHash != data['answersHash']) {
        _invalidIntent();
      }
      return intent;
    } on ArgumentError {
      _invalidIntent();
    }
  }

  Future<_TemperamentIntent?> _load(String origin, String uid) =>
      _serial(() async => _read(await _file(origin, uid), origin, uid));
  Future<void> _prepare(_TemperamentIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid);
    if (await _read(file, intent.origin, intent.uid) != null) {
      throw StateError('Original questionnaire operation is unresolved.');
    }
    final data = jsonEncode(intent.data);
    if (utf8.encode(data).length > _maximumBytes) _invalidIntent();
    final temporary = File('${file.path}.${intent.operationId}.tmp');
    try {
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<void> _acknowledge(
    _TemperamentIntent intent,
    void Function() requireCurrent,
  ) => _serial(() async {
    requireCurrent();
    final file = await _file(intent.origin, intent.uid);
    requireCurrent();
    final current = await _read(file, intent.origin, intent.uid);
    requireCurrent();
    if (current == null ||
        current.operationId != intent.operationId ||
        current.request.requestHash != intent.request.requestHash) {
      throw StateError('Original private questionnaire intent is unavailable.');
    }
    await file.delete();
  });
  @override
  String toString() => 'TimewebTemperamentJournal(<redacted>)';
}

Never _invalidIntent() =>
    throw const FormatException('Invalid private questionnaire intent.');

final class _TemperamentIntent {
  _TemperamentIntent(
    this.origin,
    this.uid,
    this.operationId,
    this.stamp,
    List<bool> answers,
  ) : answers = List.unmodifiable(answers) {
    if (answers.length != 80) throw ArgumentError('Expected eighty answers.');
    final counts = List<int>.filled(4, 0);
    for (var i = 0; i < 80; i++) {
      if (answers[i]) counts[i ~/ 20]++;
    }
    request = TimewebMutationRequest.completeOwnTemperament(
      operationId: operationId,
      expectedUpdatedAt: stamp,
      scores: TimewebTemperamentScores(
        brown: counts[0],
        red: counts[1],
        blue: counts[2],
        white: counts[3],
      ),
    );
  }
  factory _TemperamentIntent.create(
    String origin,
    String uid,
    String stamp,
    List<bool> answers,
  ) {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return _TemperamentIntent(origin, uid, id, stamp, answers);
  }
  final String origin, uid, operationId, stamp;
  final List<bool> answers;
  late final TimewebMutationRequest request;
  String get answersHash =>
      sha256.convert(utf8.encode(jsonEncode(answers))).toString();
  Map<String, Object> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'operation': request.operation,
    'operationId': operationId,
    'expectedUpdatedAt': stamp,
    'answers': answers,
    'answersHash': answersHash,
    'requestHash': request.requestHash,
  };
  @override
  String toString() => 'PrivateTemperamentIntent(<redacted>)';
}
