import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebGeographyOutcome { confirmed, rejected, unknown }

/// Current owner/canonical revision only. Leaving the page keeps an unresolved
/// original request durable, with restart recovery restricted to receipt lookup.
final class TimewebGeographyFlow {
  TimewebGeographyFlow._(
    this._client,
    this._session,
    this._lease,
    this._journal,
    this._snapshot,
  );
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebGeographyJournal _journal;
  final TimewebCurrentOwnProfile _snapshot;
  _GeographyIntent? _intent;
  TimewebMutationReference? _reference;
  Future<TimewebGeographyOutcome>? _active;
  TimewebGeographyOutcome? _settled;
  TimewebGeographyReceipt? _receipt;
  bool _closed = false, _requiresReload = false;

  static Future<TimewebGeographyFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebGeographyJournal journal,
    required TimewebCurrentOwnProfile snapshot,
  }) async {
    lease.requireCurrent();
    snapshot.requireCurrent();
    if (!snapshot.profileExists ||
        snapshot.uid != lease.identity.uid ||
        snapshot.profileAuthority != 'canonical-current-v1') {
      throw StateError('Current geography profile is unavailable.');
    }
    final flow = TimewebGeographyFlow._(
      client,
      session,
      lease,
      journal,
      snapshot,
    );
    flow._intent = await journal._load(flow._origin, snapshot.uid);
    flow.requireCurrent();
    // A pending operation stays reachable even if the fresh row is no longer
    // eligible. It still cannot submit; the server settles its original receipt.
    if (flow._intent == null && !flow._eligible) {
      throw StateError('Current profile is not ready for geography editing.');
    }
    if (flow._intent != null) {
      flow._reference = client.bindMutation(
        flow._intent!.request,
        expectedOwnerUid: snapshot.uid,
      );
    }
    return flow;
  }

  bool get _eligible {
    final p = _snapshot.profile!;
    return _snapshot.onboarding == TimewebOnboarding.search ||
        (p.profileDetailsSaved == true &&
            p.fullName?.trim().isNotEmpty == true &&
            p.age != null &&
            p.pol?.isNotEmpty == true &&
            p.about?.isNotEmpty == true &&
            p.hobbi?.isNotEmpty == true);
  }

  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() {
    if (_closed) throw StateError('Geography editor is closed.');
    _lease.requireCurrent();
    _snapshot.requireCurrent();
  }

  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout =>
      _client.requestDeadline + const Duration(seconds: 2);
  String? get countryCode {
    requireCurrent();
    return _intent?.changes.countryCode ?? _snapshot.profile!.countryCode;
  }

  String? get region {
    requireCurrent();
    return _intent?.changes.region ?? _snapshot.profile!.region;
  }

  TimewebGeographyReceipt? get receipt {
    requireCurrent();
    return _receipt;
  }

  bool get needsCheck {
    requireCurrent();
    return _intent != null ||
        _active != null ||
        _settled == TimewebGeographyOutcome.confirmed;
  }

  bool get requiresReload {
    requireCurrent();
    return _requiresReload;
  }

  bool hasChanges({required String countryCode, required String region}) {
    requireCurrent();
    return countryCode != _snapshot.profile!.countryCode ||
        region != _snapshot.profile!.region;
  }

  Future<TimewebGeographyOutcome> save({
    required String countryCode,
    required String region,
  }) {
    requireCurrent();
    if (_active != null) return _active!;
    if (_intent != null || _requiresReload || _settled != null || !_eligible) {
      throw StateError('Check or reload the original geography operation.');
    }
    return _track(() async {
      final changes = await TimewebGeographyChanges.fromCatalog(
        countryCode: countryCode,
        region: region,
      );
      requireCurrent();
      final intent = _GeographyIntent.create(
        _origin,
        _snapshot.uid,
        _snapshot.profile!.updatedAt,
        changes,
      );
      // Exact pair, owner, CAS, UUID and hash are durable before the first POST.
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

  Future<TimewebGeographyOutcome> check() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_settled != null && _settled != TimewebGeographyOutcome.unknown) {
      return Future.value(_settled);
    }
    if (_reference == null) {
      throw StateError('No original geography to look up.');
    }
    return _track(
      () async => _finish(await _client.reconcileMutation(_reference!)),
    );
  }

  Future<TimewebGeographyOutcome> _track(
    Future<TimewebGeographyOutcome> Function() action,
  ) {
    final future = Future<TimewebGeographyOutcome>.sync(action);
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

  Future<TimewebGeographyOutcome> _finish(TimewebMutationResult result) async {
    requireCurrent();
    result.requireCurrent();
    final receipt = result.editedGeography;
    if (!result.canAcknowledge ||
        (result.state == TimewebMutationState.confirmed && receipt == null)) {
      // An absent lookup receipt never proves that a previous POST cannot commit.
      return _settled = TimewebGeographyOutcome.unknown;
    }
    final confirmed = result.state == TimewebMutationState.confirmed;
    await _journal._acknowledge(_intent!, requireCurrent);
    requireCurrent();
    _client.acknowledgeMutation(_reference!);
    _intent = null;
    _reference = null;
    _receipt = receipt?.bindSessionGuard(requireCurrent);
    _requiresReload = !confirmed;
    return _settled = confirmed
        ? TimewebGeographyOutcome.confirmed
        : TimewebGeographyOutcome.rejected;
  }

  void close() => _closed = true;
  @override
  String toString() => 'TimewebGeographyFlow(<redacted>)';
}

/// Bounded application-private original request. No credential or media fields.
final class TimewebGeographyJournal {
  TimewebGeographyJournal({Future<Directory> Function()? directory})
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
  Future<File> _file(String origin, String uid) async {
    final root = await _directory();
    final folder = Directory('${root.path}/clrs_native_geography');
    await folder.create(recursive: true);
    final key = sha256.convert(utf8.encode('$origin\u0000$uid'));
    return File('${folder.path}/$key.json');
  }

  Future<_GeographyIntent?> _read(File file, String origin, String uid) async {
    if (!await file.exists()) return null;
    if (await file.length() > _maximumBytes) _invalidGeographyIntent();
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > _maximumBytes) {
        _invalidGeographyIntent();
      }
      bytes.addAll(chunk);
    }
    final raw = utf8.decode(bytes);
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        jsonEncode(data) != raw ||
        data.length != 8 ||
        data['version'] is! int ||
        data['version'] != 1 ||
        data['origin'] != origin ||
        data['uid'] != uid ||
        data['operation'] != 'profile.edit-geography.v1' ||
        data['operationId'] is! String ||
        data['expectedUpdatedAt'] is! String ||
        data['requestHash'] is! String ||
        data['changes'] is! Map<String, dynamic>) {
      _invalidGeographyIntent();
    }
    final pair = data['changes'] as Map<String, dynamic>;
    if (pair.length != 2 ||
        pair['countryCode'] is! String ||
        pair['region'] is! String) {
      _invalidGeographyIntent();
    }
    try {
      final changes = await TimewebGeographyChanges.fromCatalog(
        countryCode: pair['countryCode'],
        region: pair['region'],
      );
      final intent = _GeographyIntent(
        origin,
        uid,
        data['operationId'],
        data['expectedUpdatedAt'],
        changes,
      );
      if (intent.request.requestHash != data['requestHash']) {
        _invalidGeographyIntent();
      }
      return intent;
    } on ArgumentError {
      _invalidGeographyIntent();
    }
  }

  Future<_GeographyIntent?> _load(String origin, String uid) =>
      _serial(() async => _read(await _file(origin, uid), origin, uid));
  Future<void> _prepare(_GeographyIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid);
    if (await _read(file, intent.origin, intent.uid) != null) {
      throw StateError('Original geography operation is unresolved.');
    }
    final data = jsonEncode(intent.data);
    if (utf8.encode(data).length > _maximumBytes) _invalidGeographyIntent();
    final temporary = File('${file.path}.${intent.request.operationId}.tmp');
    try {
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<void> _acknowledge(
    _GeographyIntent intent,
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
      throw StateError('Original private geography intent is unavailable.');
    }
    await file.delete();
  });
  @override
  String toString() => 'TimewebGeographyJournal(<redacted>)';
}

Never _invalidGeographyIntent() =>
    throw const FormatException('Invalid private geography intent.');

final class _GeographyIntent {
  _GeographyIntent(this.origin, this.uid, String id, this.stamp, this.changes)
    : request = TimewebMutationRequest.editOwnGeography(
        operationId: id,
        expectedUpdatedAt: stamp,
        changes: changes,
      );
  factory _GeographyIntent.create(
    String origin,
    String uid,
    String stamp,
    TimewebGeographyChanges changes,
  ) {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return _GeographyIntent(origin, uid, id, stamp, changes);
  }
  final String origin, uid, stamp;
  final TimewebGeographyChanges changes;
  final TimewebMutationRequest request;
  Map<String, Object> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'operation': request.operation,
    'operationId': request.operationId,
    'expectedUpdatedAt': stamp,
    'changes': {'countryCode': changes.countryCode, 'region': changes.region},
    'requestHash': request.requestHash,
  };
}
