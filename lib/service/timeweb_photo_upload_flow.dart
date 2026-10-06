import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebPhotoUploadOutcome { prepared, ready, rejected, unknown }

final class TimewebPhotoUploadFlow {
  TimewebPhotoUploadFlow._(
    this._client,
    this._session,
    this._lease,
    this._journal,
    this._onReady,
  );
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebPhotoUploadJournal _journal;
  final Future<void> Function(TimewebCommittedPhotoReceipt)? _onReady;
  _PhotoIntent? _intent;
  TimewebMutationReference? _prepareRef, _commitRef;
  TimewebPreparedPhotoReceipt? _prepared;
  TimewebCommittedPhotoReceipt? _ready;
  TimewebProfilePhotoSource? _source;
  TimewebMutationFailure? _failure;
  Future<TimewebPhotoUploadOutcome>? _active;
  TimewebPhotoUploadOutcome? _settled;
  Future<void> _drain = Future.value();
  StreamSubscription<AppSessionState>? _subscription;
  bool _closed = false;
  static Future<TimewebPhotoUploadFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebPhotoUploadJournal journal,
    Future<void> Function(TimewebCommittedPhotoReceipt)? onReady,
  }) async {
    lease.requireCurrent();
    final flow = TimewebPhotoUploadFlow._(client, session, lease, journal, onReady);
    flow._intent = await journal._load(flow._origin, lease.identity.uid);
    flow.requireCurrent();
    if (flow._intent != null) {
      flow._prepareRef = client.bindMutation(
        flow._intent!.prepare,
        expectedOwnerUid: lease.identity.uid,
      );
      if (flow._intent!.commit != null) {
        flow._commitRef = client.bindMutation(
          flow._intent!.commit!,
          expectedOwnerUid: lease.identity.uid,
        );
      }
    }
    flow._subscription = session.states.listen((state) {
      if (!state.authenticated || state.epoch != lease.epoch) {
        flow._purge();
        flow._prepared = null;
        flow._ready = null;
      }
    });
    return flow;
  }

  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() {
    if (_closed) {
      throw StateError('Photo upload is closed.');
    }
    _lease.requireCurrent();
  }

  String get ownerUid {
    requireCurrent();
    return _lease.identity.uid;
  }

  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout =>
      _client.mediaRequestDeadline +
      _client.requestDeadline * 2 +
      const Duration(seconds: 2);
  bool get needsCheck {
    requireCurrent();
    return _active != null ||
        _intent != null && (_prepared == null || _intent!.commit != null);
  }

  bool get sourceAttached {
    requireCurrent();
    return _source != null;
  }

  TimewebPhotoMetadata? get metadata {
    requireCurrent();
    return _intent?.metadata;
  }

  TimewebPreparedPhotoReceipt? get prepared {
    requireCurrent();
    return _prepared;
  }

  TimewebCommittedPhotoReceipt? get readyReceipt {
    requireCurrent();
    return _ready;
  }

  TimewebMutationFailure? get failure {
    requireCurrent();
    return _failure;
  }

  bool get rejected {
    requireCurrent();
    return _settled == TimewebPhotoUploadOutcome.rejected;
  }

  void reattach(TimewebProfilePhotoSource source) {
    requireCurrent();
    source.requireOpen();
    if (_active != null ||
        _intent == null ||
        _intent!.commit != null ||
        !source.metadata.matches(_intent!.metadata)) {
      throw StateError('Original photo source does not match.');
    }
    if (identical(_source, source)) {
      return;
    }
    _purge();
    _source = source;
  }

  Future<void> reattachFile(File file) async {
    requireCurrent();
    if (_intent == null || _intent!.commit != null || _active != null) {
      throw StateError('Original photo cannot be reattached.');
    }
    final expected = _intent!.metadata,
        buffer = Uint8List(expected.byteSize + 1);
    var length = 0;
    try {
      await for (final chunk in file.openRead(0, buffer.length)) {
        requireCurrent();
        if (length + chunk.length > buffer.length) {
          throw const FormatException('Photo length changed.');
        }
        buffer.setRange(length, length + chunk.length, chunk);
        length += chunk.length;
        if (chunk is Uint8List) {
          chunk.fillRange(0, chunk.length, 0);
        }
      }
      requireCurrent();
      if (length != expected.byteSize) {
        throw const FormatException('Photo length changed.');
      }
      final source = TimewebProfilePhotoSource.fromBytes(
        Uint8List.sublistView(buffer, 0, length),
        mimeType: expected.mimeType,
      );
      try {
        reattach(source);
      } catch (_) {
        source.close();
        rethrow;
      }
    } finally {
      buffer.fillRange(0, buffer.length, 0);
    }
  }

  Future<TimewebPhotoUploadOutcome> prepare(TimewebProfilePhotoSource source) {
    requireCurrent();
    if (_active != null) {
      return _active!;
    }
    source.requireOpen();
    if (_intent != null || _settled != null) {
      throw StateError('Check the original photo.');
    }
    _source = source;
    return _track(() async {
      final intent = _PhotoIntent(
        _origin,
        ownerUid,
        source.metadata,
        _photoUuid(),
      );
      await _journal._save(null, intent, requireCurrent);
      requireCurrent();
      _intent = intent;
      _prepareRef = _client.bindMutation(
        intent.prepare,
        expectedOwnerUid: ownerUid,
      );
      return _finish(await _client.mutate(_prepareRef!), false);
    });
  }

  Future<TimewebPhotoUploadOutcome> uploadAndCommit() {
    requireCurrent();
    if (_active != null) {
      return _active!;
    }
    if (_intent == null ||
        _prepared == null ||
        _intent!.commit != null ||
        _source == null ||
        _settled == TimewebPhotoUploadOutcome.rejected) {
      throw StateError('Original photo needs checking or reattachment.');
    }
    return _track(() async {
      final lease = await _client.leaseProfilePhotoUpload(_prepared!);
      requireCurrent();
      final next = _intent!.withCommit(_photoUuid());
      await _journal._save(_intent, next, requireCurrent);
      requireCurrent();
      _intent = next;
      _commitRef = _client.bindMutation(
        next.commit!,
        expectedOwnerUid: ownerUid,
      );
      try {
        await _client.putProfilePhoto(lease, _source!);
        requireCurrent();
        return _finish(await _client.mutate(_commitRef!), true);
      } finally {
        _purge();
      }
    });
  }

  Future<TimewebPhotoUploadOutcome> check() {
    requireCurrent();
    if (_active != null) {
      return _active!;
    }
    final commit = _commitRef != null, ref = _commitRef ?? _prepareRef;
    if (ref == null) {
      throw StateError('No original photo to look up.');
    }
    _ready = null;
    _failure = null;
    return _track(
      () async => _finish(await _client.reconcileMutation(ref), commit),
    );
  }

  Future<TimewebPhotoUploadOutcome> _track(
    Future<TimewebPhotoUploadOutcome> Function() action,
  ) {
    final future = Future<TimewebPhotoUploadOutcome>.sync(action);
    _active = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_active, future)) {
            _active = null;
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_active, future)) {
            _active = null;
          }
        },
      ),
    );
    return future;
  }

  Future<TimewebPhotoUploadOutcome> _finish(
    TimewebMutationResult result,
    bool commit,
  ) async {
    requireCurrent();
    result.requireCurrent();
    _failure = result.failure;
    if (!result.canAcknowledge) {
      _ready = null;
      if (!commit) {
        _prepared = null;
      }
      return _settled = TimewebPhotoUploadOutcome.unknown;
    }
    final confirmed = result.state == TimewebMutationState.confirmed;
    if (confirmed && !commit) {
      final receipt = result.preparedPhoto!;
      final next = _intent!.withMedia(receipt.mediaId);
      await _journal._save(_intent, next, requireCurrent);
      requireCurrent();
      _intent = next;
      _client.acknowledgeMutation(_prepareRef!);
      _prepared = receipt.bindSessionGuard(requireCurrent);
      return _settled = TimewebPhotoUploadOutcome.prepared;
    }
    if (confirmed && commit && _onReady != null) {
      await _onReady(result.committedPhoto!.bindSessionGuard(requireCurrent));
      requireCurrent();
      result.requireCurrent();
    }
    if (_intent != null) {
      await _journal._acknowledge(_intent!, requireCurrent);
      requireCurrent();
    }
    _client.acknowledgeMutation(commit ? _commitRef! : _prepareRef!);
    _intent = null;
    _purge();
    _ready = confirmed
        ? result.committedPhoto!.bindSessionGuard(requireCurrent)
        : null;
    return _settled = confirmed
        ? TimewebPhotoUploadOutcome.ready
        : TimewebPhotoUploadOutcome.rejected;
  }

  void _purge() {
    final source = _source;
    _source = null;
    if (source != null) {
      source.close();
      _drain = Future.wait([
        _drain,
        _client.cancelProfilePhotoUpload(source),
      ]).then((_) {});
      unawaited(_drain);
    }
  }

  Future<void> close() async {
    _closed = true;
    _purge();
    _prepared = null;
    _ready = null;
    await _subscription?.cancel();
    await _drain;
  }

  @override
  String toString() => 'TimewebPhotoUploadFlow(<redacted>)';
}

final class TimewebPhotoUploadJournal {
  TimewebPhotoUploadJournal({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final f = _tail.then((_) => action());
    _tail = f.then<void>((_) {}, onError: (Object _) {});
    return f;
  }

  Future<void> drain() => _tail;
  Future<File> _file(String origin, String uid) async {
    final folder = Directory(
      '${(await _directory()).path}/clrs_native_photo_upload',
    );
    await folder.create(recursive: true);
    return File(
      '${folder.path}/${sha256.convert(utf8.encode('$origin\u0000$uid'))}.json',
    );
  }

  Future<_PhotoIntent?> _read(File file, String origin, String uid) async {
    if (!await file.exists()) {
      return null;
    }
    if (await file.length() > 65536) {
      _badPhotoIntent();
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > 65536) {
        _badPhotoIntent();
      }
      bytes.addAll(chunk);
    }
    final raw = utf8.decode(bytes), data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        jsonEncode(data) != raw ||
        data.length != 9 ||
        data['version'] is! int ||
        data['version'] != 1 ||
        data['origin'] != origin ||
        data['uid'] != uid ||
        data['metadata'] is! Map<String, dynamic> ||
        data['prepareOperationId'] is! String ||
        data['prepareRequestHash'] is! String ||
        data['mediaId'] != null && data['mediaId'] is! String ||
        data['commitOperationId'] != null &&
            data['commitOperationId'] is! String ||
        (data['commitOperationId'] == null) !=
            (data['commitRequestHash'] == null)) {
      _badPhotoIntent();
    }
    final meta = data['metadata'] as Map<String, dynamic>;
    if (meta.length != 3 ||
        meta['sha256'] is! String ||
        meta['byteSize'] is! int ||
        meta['mimeType'] is! String) {
      _badPhotoIntent();
    }
    try {
      final intent = _PhotoIntent(
        origin,
        uid,
        TimewebPhotoMetadata(
          sha256: meta['sha256'],
          byteSize: meta['byteSize'],
          mimeType: meta['mimeType'],
        ),
        data['prepareOperationId'],
        mediaId: data['mediaId'],
        commitId: data['commitOperationId'],
      );
      if (intent.prepare.requestHash != data['prepareRequestHash'] ||
          intent.commit?.requestHash != data['commitRequestHash']) {
        _badPhotoIntent();
      }
      return intent;
    } on ArgumentError {
      _badPhotoIntent();
    }
  }

  Future<_PhotoIntent?> _load(String origin, String uid) =>
      _serial(() async => _read(await _file(origin, uid), origin, uid));
  Future<void> _save(
    _PhotoIntent? expected,
    _PhotoIntent next,
    void Function() guard,
  ) => _serial(() async {
    guard();
    final file = await _file(next.origin, next.uid),
        current = await _read(
          await _file(next.origin, next.uid),
          next.origin,
          next.uid,
        );
    guard();
    if (jsonEncode(current?.data) != jsonEncode(expected?.data)) {
      throw StateError('Original photo journal changed.');
    }
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(next.data), flush: true);
      guard();
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  });
  Future<void> _acknowledge(_PhotoIntent intent, void Function() guard) =>
      _serial(() async {
        guard();
        final file = await _file(intent.origin, intent.uid),
            current = await _read(
              await _file(intent.origin, intent.uid),
              intent.origin,
              intent.uid,
            );
        guard();
        if (jsonEncode(current?.data) != jsonEncode(intent.data)) {
          throw StateError('Original photo journal changed.');
        }
        await file.delete();
      });
  @override
  String toString() => 'TimewebPhotoUploadJournal(<redacted>)';
}

Never _badPhotoIntent() =>
    throw const FormatException('Invalid private photo intent.');
String _photoUuid() {
  final random = Random.secure(),
      bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

final class _PhotoIntent {
  _PhotoIntent(
    this.origin,
    this.uid,
    this.metadata,
    this.prepareId, {
    this.mediaId,
    this.commitId,
  }) {
    if (mediaId != null &&
            mediaId !=
                'tw-profile-photo-${sha256.convert(utf8.encode('clrs-native-profile-photo-v1\u0000${jsonEncode([uid, prepareId])}'))}' ||
        commitId != null && mediaId == null) {
      throw ArgumentError('Invalid original photo.');
    }
    prepare = TimewebMutationRequest.prepareProfilePhoto(
      operationId: prepareId,
      metadata: metadata,
    );
    if (commitId != null) {
      commit = TimewebMutationRequest.commitProfilePhoto(
        operationId: commitId!,
        prepareOperationId: prepareId,
        mediaId: mediaId!,
      );
    }
  }
  final String origin, uid, prepareId;
  final TimewebPhotoMetadata metadata;
  final String? mediaId, commitId;
  late final TimewebMutationRequest prepare;
  TimewebMutationRequest? commit;
  _PhotoIntent withMedia(String id) => _PhotoIntent(
    origin,
    uid,
    metadata,
    prepareId,
    mediaId: id,
    commitId: commitId,
  );
  _PhotoIntent withCommit(String id) => _PhotoIntent(
    origin,
    uid,
    metadata,
    prepareId,
    mediaId: mediaId,
    commitId: id,
  );
  Map<String, Object?> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'metadata': metadata.fields,
    'prepareOperationId': prepareId,
    'prepareRequestHash': prepare.requestHash,
    'mediaId': mediaId,
    'commitOperationId': commitId,
    'commitRequestHash': commit?.requestHash,
  };
}
