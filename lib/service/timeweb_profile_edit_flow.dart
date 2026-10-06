import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebProfileEditOutcome { confirmed, rejected, unknown }

/// One screen's current canonical profile. No Firebase/global profile hydration,
/// onboarding completion or alternate transport. Leaving the screen revokes its
/// lease; a possibly committed request stays in the private journal for lookup.
final class TimewebProfileEditFlow {
  TimewebProfileEditFlow._(
    this._client,
    this._session,
    this._lease,
    this._journal,
    this._view,
  );
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebProfileEditJournal _journal;
  final TimewebProfileEditorSnapshot _view;
  _EditIntent? _intent;
  TimewebMutationReference? _reference;
  Future<TimewebProfileEditOutcome>? _active;
  TimewebProfileEditOutcome? _settled;
  bool _closed = false;
  bool _requiresReload = false;

  static Future<TimewebProfileEditFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebProfileEditJournal journal,
  }) async {
    lease.requireCurrent();
    final view = await client.readProfileForEdit(
      const TimewebProfileEditorRequest.own(),
    );
    lease.requireCurrent();
    view.requireCurrent();
    if (!view.profileExists ||
        view.uid != lease.identity.uid ||
        view.profileAuthority != 'canonical-current-v1') {
      throw StateError('Current profile is unavailable.');
    }
    final flow = TimewebProfileEditFlow._(
      client,
      session,
      lease,
      journal,
      view,
    );
    final intent = await journal._load(flow._origin, view.uid);
    flow.requireCurrent();
    if (intent != null) {
      flow._intent = intent;
      flow._reference = client.bindMutation(
        intent.request,
        expectedOwnerUid: view.uid,
      );
      // A restored operation is lookup-only, even if its original ACK vanished.
      // An absent receipt does not establish that the old POST cannot commit.
    }
    return flow;
  }

  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() {
    if (_closed) throw StateError('Profile editor is closed.');
    _lease.requireCurrent();
    _view.requireCurrent();
  }

  // Cancel on screen disposal instead of retaining its controllers until this
  // long-running session eventually changes.
  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout =>
      _client.requestDeadline + const Duration(seconds: 2);
  bool get needsCheck {
    requireCurrent();
    return _intent != null ||
        _active != null ||
        _settled == TimewebProfileEditOutcome.confirmed;
  }

  bool get requiresReload {
    requireCurrent();
    return _requiresReload;
  }

  String get fullName => _text('fullName', _view.profile!.fullName);
  String get about => _text('about', _view.profile!.about);
  String get hobbi => _text('hobbi', _view.profile!.hobbi);
  int? get age => _value<int>('age', _view.profile!.age);
  int? get rost => _value<int>('rost', _view.profile!.rost);
  bool? get deti => _value<bool>('deti', _view.profile!.deti);
  String? get pol => _value<String>('pol', _view.profile!.pol);
  bool get canSetGender {
    requireCurrent();
    return _view.profile!.pol == null;
  }

  String? get relationStatus =>
      _value<String>('relationStatus', _view.profile!.relationStatus);
  String _text(String key, String? source) => _value<String>(key, source) ?? '';
  T? _value<T>(String key, T? source) {
    requireCurrent();
    final value = _intent?.changes[key];
    return value == null ? source : value as T;
  }

  bool hasChanges({
    required String fullName,
    required String about,
    required String hobbi,
    int? age,
    int? rost,
    bool? deti,
    String? pol,
    String? relationStatus,
  }) {
    requireCurrent();
    return fieldChanged('fullName', fullName) ||
        fieldChanged('about', about) ||
        fieldChanged('hobbi', hobbi) ||
        fieldChanged('age', age) ||
        fieldChanged('rost', rost) ||
        fieldChanged('deti', deti) ||
        fieldChanged('pol', pol) ||
        fieldChanged('relationStatus', relationStatus);
  }

  bool fieldChanged(String field, Object? value) {
    requireCurrent();
    final profile = _view.profile!;
    final Object? old = switch (field) {
      'fullName' => profile.fullName,
      'about' => profile.about,
      'hobbi' => profile.hobbi,
      'age' => profile.age,
      'rost' => profile.rost,
      'deti' => profile.deti,
      'pol' => profile.pol,
      'relationStatus' => profile.relationStatus,
      _ => throw ArgumentError('Unsupported editor field.'),
    };
    if (const {'fullName', 'about', 'hobbi'}.contains(field)) {
      return value != (old ?? '');
    }
    // The mutation contract cannot clear a field to null. Omitted optional
    // arguments preserve old/null values and retain the original 3-field API.
    return value != null && value != old;
  }

  Future<TimewebProfileEditOutcome> save({
    required String fullName,
    required String about,
    required String hobbi,
    int? age,
    int? rost,
    bool? deti,
    String? pol,
    String? relationStatus,
  }) {
    requireCurrent();
    if (_active != null) return _active!;
    if (_intent != null || _requiresReload || _settled != null) {
      throw StateError('Reconcile or reload the original profile operation.');
    }
    final changes = <String, Object>{
      if (fieldChanged('fullName', fullName)) 'fullName': fullName,
      if (fieldChanged('about', about)) 'about': about,
      if (fieldChanged('hobbi', hobbi)) 'hobbi': hobbi,
      if (fieldChanged('age', age)) 'age': age!,
      if (fieldChanged('rost', rost)) 'rost': rost!,
      if (fieldChanged('deti', deti)) 'deti': deti!,
      if (fieldChanged('pol', pol)) 'pol': pol!,
      if (fieldChanged('relationStatus', relationStatus))
        'relationStatus': relationStatus!,
    };
    final intent = _EditIntent.create(
      _origin,
      _view.uid,
      _view.profile!.updatedAt,
      changes,
    );
    return _track(() async {
      // Exact input, owner, CAS and hash are durable before the first POST.
      await _journal._prepare(intent);
      requireCurrent();
      _intent = intent;
      _reference = _client.bindMutation(
        intent.request,
        expectedOwnerUid: _view.uid,
      );
      return _finish(await _client.mutate(_reference!));
    });
  }

  Future<TimewebProfileEditOutcome> check() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_settled != null && _settled != TimewebProfileEditOutcome.unknown) {
      return Future.value(_settled);
    }
    if (_reference == null) {
      throw StateError('No original operation to lookup.');
    }
    return _track(
      () async => _finish(await _client.reconcileMutation(_reference!)),
    );
  }

  Future<TimewebProfileEditOutcome> _track(
    Future<TimewebProfileEditOutcome> Function() action,
  ) {
    final future = Future<TimewebProfileEditOutcome>.sync(action);
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

  Future<TimewebProfileEditOutcome> _finish(
    TimewebMutationResult result,
  ) async {
    requireCurrent();
    result.requireCurrent();
    if (!result.canAcknowledge) {
      return _settled = TimewebProfileEditOutcome.unknown;
    }
    final confirmed =
        result.state == TimewebMutationState.confirmed &&
        result.editedProfile != null;
    // A storage error retains the original reference; checking again retires
    // exactly that UUID, never starts a replacement mutation.
    await _journal._acknowledge(_intent!);
    requireCurrent();
    _client.acknowledgeMutation(_reference!);
    _intent = null;
    _reference = null;
    _requiresReload = !confirmed;
    return _settled = confirmed
        ? TimewebProfileEditOutcome.confirmed
        : TimewebProfileEditOutcome.rejected;
  }

  void close() => _closed = true;
  @override
  String toString() => 'TimewebProfileEditFlow(<redacted>)';
}

/// Application-private profile intent, not credentials. Only the eight reviewed
/// editable fields are persisted. One runtime owns this journal; IO is serialized
/// across its screens. Unresolved entries are immutable and never overwritten.
final class TimewebProfileEditJournal {
  TimewebProfileEditJournal({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  static const _maximumBytes = 65536;
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _) {});
    return future;
  }

  /// Owner replacement waits actual local IO too. A late A/ABA file write must
  /// settle before a new runtime can load/create a journal for that same UID.
  Future<void> drain() => _tail;

  Future<File> _file(String origin, String uid) async {
    final root = await _directory();
    final folder = Directory('${root.path}/clrs_native_profile_edits');
    await folder.create(recursive: true);
    final key = sha256.convert(utf8.encode('$origin\u0000$uid'));
    return File('${folder.path}/$key.json');
  }

  Future<_EditIntent?> _read(File file, String origin, String uid) async {
    if (!await file.exists()) return null;
    if (await file.length() > _maximumBytes) {
      throw const FormatException('Invalid private profile intent.');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      bytes.addAll(chunk);
      if (bytes.length > _maximumBytes) {
        throw const FormatException('Invalid private profile intent.');
      }
    }
    final raw = utf8.decode(bytes);
    final data = jsonDecode(raw);
    // We only load our exact compact encoding. Duplicate keys/extra fields,
    // malformed hashes and changed owner/origin fail closed before HTTP.
    if (data is! Map<String, dynamic> ||
        jsonEncode(data) != raw ||
        data.length != 8 ||
        data['version'] is! int ||
        data['version'] != 1 ||
        data['origin'] != origin ||
        data['uid'] != uid ||
        data['operationId'] is! String ||
        data['expectedUpdatedAt'] is! String ||
        data['requestHash'] is! String ||
        data['changes'] is! Map ||
        data['operation'] != 'profile.edit.v1') {
      throw const FormatException('Invalid private profile intent.');
    }
    final changes = data['changes'] as Map;
    if (changes.isEmpty ||
        changes.length > 8 ||
        changes.entries.any(
          (e) => !switch (e.key) {
            'fullName' ||
            'about' ||
            'hobbi' ||
            'pol' ||
            'relationStatus' => e.value is String,
            'age' || 'rost' => e.value is int,
            'deti' => e.value is bool,
            _ => false,
          },
        )) {
      throw const FormatException('Invalid private profile intent.');
    }
    final _EditIntent intent;
    try {
      intent = _EditIntent(
        origin,
        uid,
        data['operationId'],
        data['expectedUpdatedAt'],
        Map<String, Object>.from(changes),
      );
    } on ArgumentError {
      throw const FormatException('Invalid private profile intent.');
    }
    if (intent.request.requestHash != data['requestHash']) {
      throw const FormatException('Invalid private profile intent.');
    }
    return intent;
  }

  Future<_EditIntent?> _load(String origin, String uid) =>
      _serial(() async => _read(await _file(origin, uid), origin, uid));
  Future<void> _prepare(_EditIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid);
    if (await _read(file, intent.origin, intent.uid) != null) {
      throw StateError('Original profile operation is unresolved.');
    }
    final data = jsonEncode(intent.data);
    if (utf8.encode(data).length > _maximumBytes) {
      throw const FormatException('Private profile intent exceeds its bound.');
    }
    final temporary = File('${file.path}.${intent.operationId}.tmp');
    try {
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<void> _acknowledge(_EditIntent intent) => _serial(() async {
    final file = await _file(intent.origin, intent.uid);
    final current = await _read(file, intent.origin, intent.uid);
    if (current == null ||
        current.operationId != intent.operationId ||
        current.request.requestHash != intent.request.requestHash) {
      throw StateError('Original private profile intent is unavailable.');
    }
    await file.delete();
  });
  @override
  String toString() => 'TimewebProfileEditJournal(<redacted>)';
}

final class _EditIntent {
  _EditIntent(
    this.origin,
    this.uid,
    this.operationId,
    this.stamp,
    Map<String, Object> changes,
  ) : changes = Map.unmodifiable(changes) {
    request = TimewebMutationRequest.editOwnProfile(
      operationId: operationId,
      expectedUpdatedAt: stamp,
      changes: TimewebProfileChanges(
        fullName: changes['fullName'] as String?,
        age: changes['age'] as int?,
        rost: changes['rost'] as int?,
        about: changes['about'] as String?,
        hobbi: changes['hobbi'] as String?,
        deti: changes['deti'] as bool?,
        pol: changes['pol'] as String?,
        relationStatus: changes['relationStatus'] as String?,
      ),
    );
  }
  factory _EditIntent.create(
    String origin,
    String uid,
    String stamp,
    Map<String, Object> changes,
  ) {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return _EditIntent(origin, uid, id, stamp, changes);
  }
  final String origin, uid, operationId, stamp;
  final Map<String, Object> changes;
  late final TimewebMutationRequest request;
  Map<String, Object> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'operation': 'profile.edit.v1',
    'operationId': operationId,
    'expectedUpdatedAt': stamp,
    'changes': changes,
    'requestHash': request.requestHash,
  };
  @override
  String toString() => 'PrivateProfileIntent(<redacted>)';
}
