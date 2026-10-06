import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebInitialProfileOutcome { confirmed, rejected, unknown }

final class TimewebInitialPhotosUnavailable implements Exception {
  const TimewebInitialPhotosUnavailable();
  @override
  String toString() => 'TimewebInitialPhotosUnavailable';
}

/// Keeps photo pointers before photo ACK; initial finish is a separate original.
final class TimewebInitialProfileFlow {
  TimewebInitialProfileFlow._(
    this._client,
    this._session,
    this._lease,
    this._journal,
  );
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebInitialProfileJournal _journal;
  StreamSubscription<AppSessionState>? _subscription;
  _InitialDraft? _draft;
  List<TimewebInitialPhotoProof> _photos = [];
  TimewebInitialProfileRequest? _pending;
  TimewebMutationReference? _reference;
  TimewebInitialProfileReceipt? _receipt;
  TimewebMutationFailure? _failure;
  Future<TimewebInitialProfileOutcome>? _active;
  Future<void>? _photoChecks;
  bool _verified = false, _closed = false;
  TimewebInitialProfileOutcome? _settled;
  static Future<TimewebInitialProfileFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebInitialProfileJournal journal,
  }) async {
    lease.requireCurrent();
    final f = TimewebInitialProfileFlow._(client, session, lease, journal);
    f._draft = await journal._load(f._origin, lease.identity.uid);
    f.requireCurrent();
    if (f._draft != null) {
      f._photos = f._draft!.photos
          .map(
            (p) => TimewebInitialPhotoProof.restore(
              client: client,
              ownerUid: lease.identity.uid,
              fields: p,
            ),
          )
          .toList();
      if (f._draft!.operationId != null) {
        f._pending = TimewebInitialProfileRequest.restore(
          f._draft!.request!,
          f._photos,
        );
        f._reference = client.bindMutation(
          TimewebMutationRequest.finishInitialProfile(
            operationId: f._draft!.operationId!,
            request: f._pending!,
          ),
          expectedOwnerUid: lease.identity.uid,
        );
      }
    }
    f._subscription = session.states.listen((state) {
      if (!state.authenticated || state.epoch != lease.epoch) {
        f._clearRam();
      }
    });
    return f;
  }

  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() {
    if (_closed) throw StateError('Initial profile is closed.');
    _lease.requireCurrent();
  }

  String get ownerUid {
    requireCurrent();
    return _lease.identity.uid;
  }

  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout =>
      _client.requestDeadline * 4 + const Duration(seconds: 2);
  List<TimewebInitialPhotoProof> get readyPhotos {
    requireCurrent();
    return List.unmodifiable(_photos);
  }

  bool get photosVerified {
    requireCurrent();
    return _verified;
  }

  bool get needsCheck {
    requireCurrent();
    return _draft?.operationId != null || _active != null;
  }

  TimewebInitialProfileRequest? get pendingRequest {
    requireCurrent();
    return _pending;
  }

  TimewebInitialProfileReceipt? get receipt {
    requireCurrent();
    return _receipt;
  }

  TimewebMutationFailure? get failure {
    requireCurrent();
    return _failure;
  }

  bool get rejected {
    requireCurrent();
    return _settled == TimewebInitialProfileOutcome.rejected;
  }

  Future<void> addReadyPhoto(TimewebCommittedPhotoReceipt receipt) async {
    requireCurrent();
    receipt.requireCurrent();
    final proof = TimewebInitialPhotoProof.fromReady(receipt);
    proof.requireOwner(_client, ownerUid);
    if (_draft?.operationId != null ||
        _active != null ||
        _photoChecks != null ||
        _settled != null) {
      throw StateError('Check the original initial profile.');
    }
    final photos = readyPhotos;
    final duplicate = photos.where((p) => p.mediaId == proof.mediaId).toList();
    if (duplicate.isNotEmpty &&
        jsonEncode(duplicate.single.fields) != jsonEncode(proof.fields)) {
      throw StateError('Original photo pointer changed.');
    }
    if (duplicate.isEmpty && photos.length >= 3) {
      throw StateError('Exactly three photos are retained.');
    }
    final next = _InitialDraft(_origin, ownerUid, [
      ...photos.map((p) => p.fields),
      if (duplicate.isEmpty) proof.fields,
    ]);
    // Idempotent callbacks still reprove the exact fsynced record, never RAM only.
    await _journal._save(_draft, next, requireCurrent);
    requireCurrent();
    proof.requireCurrent();
    _draft = next;
    if (duplicate.isEmpty) _photos = [...photos, proof];
    _verified = false;
  }

  Future<void> checkPhotos() {
    requireCurrent();
    if (_draft?.operationId != null) {
      throw StateError('Check the original finish only.');
    }
    if (_photoChecks != null) return _photoChecks!;
    late Future<void> future;
    future = _verifyPhotos().whenComplete(() {
      if (identical(_photoChecks, future)) _photoChecks = null;
    });
    return _photoChecks = future;
  }

  Future<void> _verifyPhotos() async {
    requireCurrent();
    _verified = false;
    if (_photos.length != 3) throw const TimewebInitialPhotosUnavailable();
    for (final proof in readyPhotos) {
      proof.requireOwner(_client, ownerUid);
      final request = TimewebMutationRequest.commitProfilePhoto(
        operationId: proof.commitOperationId,
        prepareOperationId: proof.prepareOperationId,
        mediaId: proof.mediaId,
      );
      final ref = _client.bindMutation(request, expectedOwnerUid: ownerUid),
          result = await _client.reconcileMutation(ref);
      requireCurrent();
      result.requireCurrent();
      if (result.state != TimewebMutationState.confirmed ||
          !result.hasReceipt ||
          result.committedPhoto?.mediaId != proof.mediaId ||
          result.committedPhoto?.ready != true) {
        throw const TimewebInitialPhotosUnavailable();
      }
      // Retention is durable already; discard only this freshly proved RAM reference.
      _client.acknowledgeMutation(ref);
    }
    requireCurrent();
    _verified = true;
  }

  Future<TimewebInitialProfileOutcome> submit(
    TimewebInitialProfileRequest request,
  ) {
    requireCurrent();
    if (_active != null) return _active!;
    if (_draft?.operationId != null || _settled != null || request.lookupOnly) {
      throw StateError('Check the original initial profile.');
    }
    request.requireOwner(_client, ownerUid);
    if (jsonEncode(request.photos.map((p) => p.fields).toList()) !=
        jsonEncode(_photos.map((p) => p.fields).toList())) {
      throw StateError('Retained original photos changed.');
    }
    return _track(() async {
      await checkPhotos();
      requireCurrent();
      request.requireOwner(_client, ownerUid);
      final next = _InitialDraft(
        _origin,
        ownerUid,
        _photos.map((p) => p.fields).toList(),
        operationId: _initialUuid(),
        request: request.fields,
      );
      await _journal._save(_draft, next, requireCurrent);
      requireCurrent();
      _draft = next;
      _pending = request;
      _reference = _client.bindMutation(
        TimewebMutationRequest.finishInitialProfile(
          operationId: next.operationId!,
          request: request,
        ),
        expectedOwnerUid: ownerUid,
      );
      return _finish(await _client.mutate(_reference!));
    });
  }

  Future<TimewebInitialProfileOutcome> check() {
    requireCurrent();
    if (_active != null) return _active!;
    if (_reference == null) {
      throw StateError('No original initial profile to check.');
    }
    _receipt = null;
    _failure = null;
    return _track(
      () async => _finish(await _client.reconcileMutation(_reference!)),
    );
  }

  Future<TimewebInitialProfileOutcome> _track(
    Future<TimewebInitialProfileOutcome> Function() action,
  ) {
    final f = Future<TimewebInitialProfileOutcome>.sync(action);
    _active = f;
    unawaited(
      f.then<void>(
        (_) {
          if (identical(_active, f)) _active = null;
        },
        onError: (Object _, StackTrace __) {
          if (identical(_active, f)) _active = null;
        },
      ),
    );
    return f;
  }

  Future<TimewebInitialProfileOutcome> _finish(
    TimewebMutationResult result,
  ) async {
    requireCurrent();
    result.requireCurrent();
    _failure = result.failure;
    if (!result.canAcknowledge) {
      _receipt = null;
      return _settled = TimewebInitialProfileOutcome.unknown;
    }
    final confirmed = result.state == TimewebMutationState.confirmed;
    if (_draft?.operationId != null) {
      if (confirmed) {
        await _journal._clear(_draft!, requireCurrent);
        _draft = null;
        _photos = [];
        _verified = false;
      } else {
        final next = _InitialDraft(_origin, ownerUid, _draft!.photos);
        await _journal._save(_draft, next, requireCurrent);
        _draft = next;
      }
    }
    requireCurrent();
    _client.acknowledgeMutation(_reference!);
    _pending = null;
    _receipt = confirmed
        ? result.initialProfile!.bindSessionGuard(requireCurrent)
        : null;
    return _settled = confirmed
        ? TimewebInitialProfileOutcome.confirmed
        : TimewebInitialProfileOutcome.rejected;
  }

  void _clearRam() {
    _photos = [];
    _pending = null;
    _receipt = null;
    _draft = null;
    _reference = null;
    _verified = false;
    _failure = null;
  }

  void close() {
    _closed = true;
    _clearRam();
    unawaited(_subscription?.cancel());
  }

  @override
  String toString() => 'TimewebInitialProfileFlow(<redacted>)';
}

final class TimewebInitialProfileJournal {
  TimewebInitialProfileJournal({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  Future<void> drain() => _tail;
  Future<T> _serial<T>(Future<T> Function() action) {
    final f = _tail.then((_) => action());
    _tail = f.then<void>((_) {}, onError: (Object _) {});
    return f;
  }

  Future<File> _file(String origin, String uid) async {
    final d = Directory(
      '${(await _directory()).path}/clrs_native_initial_profile',
    );
    await d.create(recursive: true);
    return File(
      '${d.path}/${sha256.convert(utf8.encode('$origin\u0000$uid'))}.json',
    );
  }

  Future<_InitialDraft?> _read(File file, String origin, String uid) async {
    if (!await file.exists()) return null;
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > 65536) {
        throw const FormatException('Initial journal exceeds its bound.');
      }
      bytes.addAll(chunk);
    }
    final raw = utf8.decode(bytes), v = jsonDecode(raw);
    if (v is! Map<String, dynamic> ||
        jsonEncode(v) != raw ||
        v.length != 7 ||
        v['version'] is! int ||
        v['version'] != 1 ||
        v['origin'] != origin ||
        v['uid'] != uid ||
        v['photos'] is! List ||
        v['photos'].length > 3 ||
        (v['operationId'] == null) != (v['request'] == null) ||
        (v['operationId'] == null) != (v['requestHash'] == null)) {
      throw const FormatException('Invalid private initial draft.');
    }
    try {
      final photos = <Map<String, dynamic>>[];
      for (final p in v['photos']) {
        if (p is! Map<String, dynamic> ||
            p.length != 3 ||
            p.keys.toSet().difference({
              'mediaId',
              'prepareOperationId',
              'commitOperationId',
            }).isNotEmpty) {
          throw const FormatException('Invalid photo pointer.');
        }
        photos.add(p);
      }
      final draft = _InitialDraft(
        origin,
        uid,
        photos,
        operationId: v['operationId'],
        request: v['request'],
      );
      if (draft.requestHash != v['requestHash']) {
        throw const FormatException('Initial hash changed.');
      }
      return draft;
    } catch (_) {
      throw const FormatException('Invalid private initial draft.');
    }
  }

  Future<_InitialDraft?> _load(String origin, String uid) =>
      _serial(() async => _read(await _file(origin, uid), origin, uid));
  Future<void> _save(
    _InitialDraft? expected,
    _InitialDraft next,
    void Function() guard,
  ) => _serial(() async {
    guard();
    final file = await _file(next.origin, next.uid),
        before = await _read(
          await _file(next.origin, next.uid),
          next.origin,
          next.uid,
        );
    guard();
    if (jsonEncode(before?.data) != jsonEncode(expected?.data)) {
      throw StateError('Original initial draft changed.');
    }
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(next.data), flush: true);
      guard();
      await temporary.rename(file.path);
      final after = await _read(file, next.origin, next.uid);
      guard();
      if (jsonEncode(after?.data) != jsonEncode(next.data)) {
        throw StateError('Initial draft readback failed.');
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<void> _clear(_InitialDraft expected, void Function() guard) =>
      _serial(() async {
        guard();
        final file = await _file(expected.origin, expected.uid),
            before = await _read(
              await _file(expected.origin, expected.uid),
              expected.origin,
              expected.uid,
            );
        guard();
        if (jsonEncode(before?.data) != jsonEncode(expected.data)) {
          throw StateError('Original initial draft changed.');
        }
        await file.delete();
        if (await file.exists()) {
          throw StateError('Initial acknowledgement failed.');
        }
        guard();
      });
}

String _canonicalInitial(Object? v) {
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalInitial(v[k])}').join(',')}}';
  }
  if (v is List) return '[${v.map(_canonicalInitial).join(',')}]';
  return jsonEncode(v);
}

final class _InitialDraft {
  _InitialDraft(
    this.origin,
    this.uid,
    List<Map<String, dynamic>> photos, {
    this.operationId,
    Map<String, dynamic>? request,
  }) : photos = List.unmodifiable(
         photos.map((p) => Map<String, dynamic>.unmodifiable(p)),
       ),
       request = request == null ? null : Map.unmodifiable(request) {
    if (photos.length > 3) {
      throw const FormatException('Too many original photos.');
    }
    for (final field in [
      'mediaId',
      'prepareOperationId',
      'commitOperationId',
    ]) {
      if (photos.any((p) => p[field] is! String) ||
          photos.map((p) => p[field]).toSet().length != photos.length) {
        throw const FormatException('Invalid distinct photos.');
      }
    }
    if (operationId != null) {
      if (!RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
          ).hasMatch(operationId!) ||
          photos.length != 3 ||
          request == null ||
          jsonEncode(request['photos']) != jsonEncode(this.photos)) {
        throw const FormatException('Invalid original finish.');
      }
      requestHash = sha256
          .convert(utf8.encode(_canonicalInitial(request)))
          .toString();
    }
  }
  final String origin, uid;
  final List<Map<String, dynamic>> photos;
  final String? operationId;
  final Map<String, dynamic>? request;
  String? requestHash;
  Map<String, Object?> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'photos': photos,
    'operationId': operationId,
    'requestHash': requestHash,
    'request': request,
  };
}

String _initialUuid() {
  final r = Random.secure(), b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
