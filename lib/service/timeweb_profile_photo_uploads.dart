part of 'timeweb_auth_client.dart';

const _uploadMaxBytes = 5242880;
const _uploadMimes = {'image/jpeg', 'image/png', 'image/webp'};
bool _uploadUuid(Object? v) =>
    v is String &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(v);
bool _uploadMid(Object? v) =>
    v is String && RegExp(r'^tw-profile-photo-[0-9a-f]{64}$').hasMatch(v);
String _uploadId(String uid, String operationId) =>
    'tw-profile-photo-${crypto.sha256.convert(utf8.encode('clrs-native-profile-photo-v1\u0000${_mutationCanonical([uid, operationId])}'))}';

final class TimewebPhotoMetadata {
  TimewebPhotoMetadata({
    required this.sha256,
    required this.byteSize,
    required this.mimeType,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        byteSize < 1 ||
        byteSize > _uploadMaxBytes ||
        !_uploadMimes.contains(mimeType)) {
      throw ArgumentError('Invalid photo metadata.');
    }
  }
  final String sha256, mimeType;
  final int byteSize;
  Map<String, dynamic> get fields => Map.unmodifiable({
    'sha256': sha256,
    'byteSize': byteSize,
    'mimeType': mimeType,
  });
  bool matches(TimewebPhotoMetadata other) =>
      sha256 == other.sha256 &&
      byteSize == other.byteSize &&
      mimeType == other.mimeType;
  @override
  String toString() => 'TimewebPhotoMetadata(<redacted>)';
}

/// Caller/source buffers remain separate from every durable JSON record.
final class TimewebProfilePhotoSource {
  TimewebProfilePhotoSource._(this.metadata, this._bytes);
  factory TimewebProfilePhotoSource.fromBytes(
    Uint8List bytes, {
    required String mimeType,
  }) {
    if (bytes.isEmpty || bytes.length > _uploadMaxBytes) {
      throw ArgumentError('Invalid photo length.');
    }
    final copy = Uint8List.fromList(bytes);
    try {
      return TimewebProfilePhotoSource._(
        TimewebPhotoMetadata(
          sha256: crypto.sha256.convert(copy).toString(),
          byteSize: copy.length,
          mimeType: mimeType,
        ),
        copy,
      );
    } catch (_) {
      copy.fillRange(0, copy.length, 0);
      rethrow;
    }
  }
  final TimewebPhotoMetadata metadata;
  final Uint8List _bytes;
  bool _closed = false;
  void requireOpen() {
    if (_closed) throw StateError('Photo source is closed.');
  }

  void close() {
    _closed = true;
    _bytes.fillRange(0, _bytes.length, 0);
  }

  @override
  String toString() => 'TimewebProfilePhotoSource(<redacted>)';
}

final class TimewebPreparedPhotoReceipt {
  TimewebPreparedPhotoReceipt._(this._data, this._reference, [this._guard]);
  final Map<String, dynamic> _data;
  final TimewebMutationReference _reference;
  final void Function()? _guard;
  void requireCurrent() {
    _reference.requireCurrent();
    _guard?.call();
  }

  TimewebPreparedPhotoReceipt bindSessionGuard(void Function() guard) =>
      TimewebPreparedPhotoReceipt._(_data, _reference, () {
        requireCurrent();
        guard();
      });
  String get mediaId {
    requireCurrent();
    return _data['mediaId'];
  }

  String get prepareOperationId {
    requireCurrent();
    return _reference._request.operationId;
  }

  TimewebPhotoMetadata get metadata {
    requireCurrent();
    return TimewebPhotoMetadata(
      sha256: _data['sha256'],
      byteSize: _data['byteSize'],
      mimeType: _data['mimeType'],
    );
  }

  String get status {
    requireCurrent();
    return 'pending';
  }

  @override
  String toString() => 'TimewebPreparedPhotoReceipt(<redacted>)';
}

final class TimewebCommittedPhotoReceipt {
  TimewebCommittedPhotoReceipt._(this._data, this._reference, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  final TimewebMutationReference _reference;
  void requireCurrent() => _check();
  String get prepareOperationId { requireCurrent(); return _reference._request._payload['prepareOperationId']; }
  String get commitOperationId { requireCurrent(); return _reference._request.operationId; }
  TimewebCommittedPhotoReceipt bindSessionGuard(void Function() guard) =>
      TimewebCommittedPhotoReceipt._(_data, _reference, () {
        requireCurrent();
        guard();
      });
  T _read<T>(String key) {
    requireCurrent();
    return _data[key] as T;
  }

  String get mediaId => _read('mediaId');
  bool get ready => _read('ready');
  int get ordinal => _read('ordinal');
  bool get isPrimary => _read('isPrimary');
  String get updatedAt => _read('updatedAt');
  @override
  String toString() => 'TimewebCommittedPhotoReceipt(<redacted>)';
}

bool _photoMutationKind(TimewebMutationKind kind) =>
    kind == TimewebMutationKind.prepareProfilePhoto ||
    kind == TimewebMutationKind.commitProfilePhoto;
TimewebMutationResult _decodePhotoMutation(
  TimewebMutationReference ref,
  int status,
  Map<String, dynamic> data,
  int? revision,
  bool replayed,
) {
  final input = ref._request._payload,
      prepare = ref._request.kind == TimewebMutationKind.prepareProfilePhoto;
  final expected = _uploadId(
    ref._uid,
    prepare ? ref._request.operationId : input['prepareOperationId'],
  );
  if (revision != null ||
      data['mediaId'] != expected ||
      data['profileAuthority'] != 'canonical-current-v1') {
    _mutationInvalidReply();
  }
  if (prepare) {
    if (status != 201 ||
        !_mutationExact(data, {
          'mediaId',
          'sha256',
          'byteSize',
          'mimeType',
          'status',
          'profileAuthority',
        }) ||
        data['status'] != 'pending' ||
        data['sha256'] != input['sha256'] ||
        data['byteSize'] is! int ||
        data['byteSize'] != input['byteSize'] ||
        data['mimeType'] != input['mimeType']) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.confirmed,
      status,
      replayed: replayed,
      preparedPhoto: TimewebPreparedPhotoReceipt._(data, ref),
      receiptConfirmed: true,
    );
  }
  if (status != 200 ||
      !_mutationExact(data, {
        'mediaId',
        'ready',
        'ordinal',
        'isPrimary',
        'updatedAt',
        'profileAuthority',
      }) ||
      input['mediaId'] != expected ||
      data['ready'] != true ||
      data['ordinal'] is! int ||
      data['ordinal'] < 0 ||
      data['ordinal'] > 19 ||
      data['isPrimary'] is! bool ||
      data['isPrimary'] != (data['ordinal'] == 0) ||
      !_mutationStamp(data['updatedAt'])) {
    _mutationInvalidReply();
  }
  return TimewebMutationResult._(
    ref,
    TimewebMutationState.confirmed,
    status,
    replayed: replayed,
    committedPhoto: TimewebCommittedPhotoReceipt._(data, ref, ref.requireCurrent),
    receiptConfirmed: true,
  );
}

final class TimewebPhotoUploadLease {
  TimewebPhotoUploadLease._(
    this._prepared,
    this._uri,
    this._headers,
    this._expiry,
  );
  final TimewebPreparedPhotoReceipt _prepared;
  final Uri _uri;
  final Map<String, String> _headers;
  final DateTime _expiry;
  bool _used = false;
  void requireCurrent() {
    _prepared.requireCurrent();
    if (!_prepared._reference._owner._clock().isBefore(_expiry)) {
      _photoExpired();
    }
  }

  DateTime get expiresAt {
    requireCurrent();
    return _expiry;
  }

  String get mediaId {
    requireCurrent();
    return _prepared.mediaId;
  }

  @override
  String toString() => 'TimewebPhotoUploadLease(<redacted>)';
}

/// Fresh current-server eligibility only; never a durable upload permission.
final class TimewebPhotoUploadAvailability {
  TimewebPhotoUploadAvailability._(this._canAppend, this._count, this._guard);
  final bool _canAppend;
  final int _count;
  final void Function() _guard;
  void requireCurrent() => _guard();
  bool get canAppend { requireCurrent(); return _canAppend; }
  int get photoCount { requireCurrent(); return _count; }
  int get photoLimit { requireCurrent(); return 20; }
  TimewebPhotoUploadAvailability bindSessionGuard(void Function() guard) =>
      TimewebPhotoUploadAvailability._(_canAppend, _count, () { requireCurrent(); guard(); });
}

enum TimewebPhotoPutOutcome { acknowledged, unknown }

extension TimewebProfilePhotoUploadsClient on TimewebAuthClient {
  Future<TimewebPhotoUploadAvailability> readPhotoUploadAvailability() {
    try {
      _checkEnabled(_photoOperation);
      if (!configuration.currentReadsEnabled || !configuration.runtimeWritesEnabled) {
        throw const TimewebAuthException(_photoOperation, TimewebAuthError.disabled);
      }
      final session = _session;
      if (session == null || _secureStoreUnsafe) {
        throw const TimewebAuthException(_photoOperation, TimewebAuthError.notAuthenticated);
      }
      final key = 'photo-upload-availability:$_epoch';
      final previous = _peopleFlights[key];
      if (previous != null) return previous.result.future.then((v) => v as TimewebPhotoUploadAvailability);
      if (_peopleFlights.length >= 4) {
        throw const TimewebAuthException(_photoOperation, TimewebAuthError.unavailable);
      }
      final flight = _PeopleFlight(this, null, null, null, _epoch, session.uid, key);
      _peopleFlights[key] = flight;
      unawaited(_executeUploadLease(flight, null));
      return flight.result.future.then((v) => v as TimewebPhotoUploadAvailability);
    } catch (error) { return Future.error(error); }
  }

  Future<void> cancelProfilePhotoUpload(TimewebProfilePhotoSource source) =>
      _cancelPhotoUploadFlights(this, source: source);
  Future<TimewebPhotoUploadLease> leaseProfilePhotoUpload(
    TimewebPreparedPhotoReceipt prepared,
  ) => _startUploadLease(this, prepared);
  Future<TimewebPhotoPutOutcome> putProfilePhoto(
    TimewebPhotoUploadLease lease,
    TimewebProfilePhotoSource source,
  ) {
    try {
      lease.requireCurrent();
      source.requireOpen();
      if (!identical(lease._prepared._reference._owner, this) ||
          lease._used ||
          !source.metadata.matches(lease._prepared.metadata)) {
        throw const TimewebAuthException(
          _photoOperation,
          TimewebAuthError.invalidRequest,
        );
      }
      if (_inflightRequests >= 4 || _profilePhotoUploadFlights.length >= 4) {
        throw const TimewebAuthException(
          _photoOperation,
          TimewebAuthError.unavailable,
        );
      }
      lease._used = true;
      final flight = _PhotoPutFlight(this, lease, source);
      _profilePhotoUploadFlights.add(flight);
      unawaited(flight.run());
      return flight.result.future;
    } catch (error) {
      return Future.error(error);
    }
  }
}

Future<TimewebPhotoUploadLease> _startUploadLease(
  TimewebAuthClient owner,
  TimewebPreparedPhotoReceipt prepared,
) {
  try {
    prepared.requireCurrent();
    owner._checkEnabled(_photoOperation);
    if (!identical(prepared._reference._owner, owner) ||
        !owner.configuration.currentReadsEnabled ||
        !owner.configuration.runtimeWritesEnabled) {
      throw const TimewebAuthException(
        _photoOperation,
        TimewebAuthError.invalidRequest,
      );
    }
    final key = 'photo-upload-lease:${owner._epoch}:${prepared.mediaId}';
    final previous = owner._peopleFlights[key];
    if (previous != null) {
      return previous.result.future.then((v) => v as TimewebPhotoUploadLease);
    }
    if (owner._peopleFlights.length >= 4) {
      throw const TimewebAuthException(
        _photoOperation,
        TimewebAuthError.unavailable,
      );
    }
    final f = _PeopleFlight(
      owner,
      null,
      null,
      null,
      owner._epoch,
      owner._session!.uid,
      key,
    );
    owner._peopleFlights[key] = f;
    unawaited(_executeUploadLease(f, prepared));
    return f.result.future.then((v) => v as TimewebPhotoUploadLease);
  } catch (error) {
    return Future.error(error);
  }
}

Future<void> _executeUploadLease(
  _PeopleFlight f,
  TimewebPreparedPhotoReceipt? prepared,
) async {
  final owner = f.owner,
      uri = f.owner.configuration.endpoint.replace(
        pathSegments: prepared == null
            ? ['v1', 'runtime', 'profile', 'photos', 'upload-availability']
            : ['v1', 'runtime', 'profile', 'photos', 'uploads', prepared.mediaId, 'lease'],
        queryParameters: prepared == null ? const {} : {'prepareOperationId': prepared.prepareOperationId},
      );
  try {
    f.check();
    var session = owner._session!;
    if (!owner
        ._clock()
        .add(owner.accessExpirySkew)
        .isBefore(session.accessExpiresAt)) {
      session = await owner.refresh();
      f.check();
    }
    var reply = await _meetingAttempt(f, uri, session.accessToken);
    f.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken) {
        await owner.refresh();
      }
      f.check();
      session = owner._session!;
      reply = await _meetingAttempt(f, uri, session.accessToken);
      f.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(f.epoch);
      }
      if (prepared == null && reply.status == 404) {
        if (reply.body == null || !_mutationExact(reply.body!, {'error'}) ||
            reply.body!['error'] != 'photo_unavailable') {
          throw const TimewebAuthException(_photoOperation, TimewebAuthError.invalidResponse);
        }
        throw const TimewebProfilePhotoUnavailable();
      }
      if (const [400, 403, 404, 409].contains(reply.status)) {
        throw const TimewebProfilePhotoUnavailable();
      }
      throw owner._statusError(_photoOperation, reply.status);
    }
    prepared?.requireCurrent();
    final lease = prepared == null
        ? _decodeUploadAvailability(f, reply.body!)
        : _decodeUploadLease(f, prepared, reply.body!);
    f.check();
    if (!f.result.isCompleted) {
      f.result.complete(lease);
    }
  } catch (error) {
    if (!f.result.isCompleted) {
      f.result.completeError(
        error is TimewebAuthException || error is TimewebProfilePhotoUnavailable
            ? error
            : const TimewebAuthException(
                _photoOperation,
                TimewebAuthError.invalidResponse,
              ),
      );
    }
  } finally {
    f.timer.cancel();
    if (identical(owner._peopleFlights[f.key], f)) {
      owner._peopleFlights.remove(f.key);
    }
    f.settled.complete();
  }
}

TimewebPhotoUploadAvailability _decodeUploadAvailability(_PeopleFlight flight, Map<String, dynamic> body) {
  if (!_mutationExact(body, {'canAppend', 'photoCount', 'photoLimit', 'profileAuthority'}) ||
      body['canAppend'] is! bool || body['photoCount'] is! int || body['photoCount'] < 3 ||
      body['photoCount'] > 20 || body['photoLimit'] != 20 || body['photoLimit'] is! int ||
      body['profileAuthority'] != 'canonical-current-v1' || body['photoCount'] == 20 && body['canAppend'] == true) {
    throw const TimewebAuthException(_photoOperation, TimewebAuthError.invalidResponse);
  }
  return TimewebPhotoUploadAvailability._(body['canAppend'], body['photoCount'], flight.checkSession);
}

TimewebPhotoUploadLease _decodeUploadLease(
  _PeopleFlight f,
  TimewebPreparedPhotoReceipt prepared,
  Map<String, dynamic> body,
) {
  if (!_mutationExact(body, {
        'mediaId',
        'method',
        'url',
        'headers',
        'expiresAt',
        'byteSize',
        'mimeType',
        'sha256',
      }) ||
      body['mediaId'] != prepared.mediaId ||
      body['method'] != 'PUT' ||
      body['byteSize'] is! int ||
      body['byteSize'] != prepared.metadata.byteSize ||
      body['mimeType'] != prepared.metadata.mimeType ||
      body['sha256'] != prepared.metadata.sha256 ||
      body['url'] is! String ||
      body['url'].length > 4096 ||
      body['headers'] is! Map<String, dynamic> ||
      !_mutationStamp(body['expiresAt'])) {
    _peopleInvalid();
  }
  final uri = Uri.tryParse(body['url']);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 's3.twcstorage.ru' ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.pathSegments.length != 3 ||
      uri.pathSegments[1] != 'clrs-native-profile' ||
      uri.pathSegments[2] !=
          prepared.mediaId.substring('tw-profile-photo-'.length) ||
      !RegExp(
        r'^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$',
      ).hasMatch(uri.pathSegments[0]) ||
      uri.pathSegments[0].contains('..') ||
      uri.path.contains('%')) {
    _peopleInvalid();
  }
  final query = uri.queryParametersAll;
  if (query.length != 6 ||
      query.values.any((v) => v.length != 1) ||
      !query.keys.toSet().containsAll({
        'X-Amz-Algorithm',
        'X-Amz-Credential',
        'X-Amz-Date',
        'X-Amz-Expires',
        'X-Amz-SignedHeaders',
        'X-Amz-Signature',
      }) ||
      query['X-Amz-Algorithm']!.single != 'AWS4-HMAC-SHA256' ||
      !RegExp(r'^\d{8}T\d{6}Z$').hasMatch(query['X-Amz-Date']!.single) ||
      !RegExp(
        r'^[A-Za-z0-9_-]{3,128}/\d{8}/[a-z0-9-]{1,40}/s3/aws4_request$',
      ).hasMatch(query['X-Amz-Credential']!.single) ||
      !RegExp(r'^[1-9][0-9]?$').hasMatch(query['X-Amz-Expires']!.single) ||
      int.parse(query['X-Amz-Expires']!.single) > 60 ||
      query['X-Amz-SignedHeaders']!.single !=
          'content-length;content-type;host;if-none-match;x-amz-checksum-sha256;x-amz-content-sha256' ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(query['X-Amz-Signature']!.single)) {
    _peopleInvalid();
  }
  final metadata = prepared.metadata,
      bytes = [
        for (var i = 0; i < 64; i += 2)
          int.parse(metadata.sha256.substring(i, i + 2), radix: 16),
      ];
  final headers = {
    'Content-Type': metadata.mimeType,
    'Content-Length': '${metadata.byteSize}',
    'If-None-Match': '*',
    'x-amz-checksum-sha256': base64Encode(bytes),
    'x-amz-content-sha256': metadata.sha256,
  };
  if (!_mutationExact(body['headers'], headers.keys.toSet()) ||
      headers.entries.any((v) => body['headers'][v.key] != v.value)) {
    _peopleInvalid();
  }
  final expiry = DateTime.parse(body['expiresAt']), now = f.owner._clock();
  if (!expiry.isAfter(now) ||
      expiry.difference(now) > const Duration(seconds: 60)) {
    _peopleInvalid();
  }
  final conservative = f.startedAt.add(const Duration(seconds: 60));
  return TimewebPhotoUploadLease._(
    prepared,
    uri,
    Map.unmodifiable(headers),
    expiry.isBefore(conservative) ? expiry : conservative,
  );
}

final class _PhotoPutFlight {
  _PhotoPutFlight(this.owner, this.lease, this.source) {
    var remaining = lease._expiry.difference(owner._clock());
    if (remaining > owner.mediaRequestDeadline) {
      remaining = owner.mediaRequestDeadline;
    }
    timer = Timer(remaining, () => abort());
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
  }
  final TimewebAuthClient owner;
  final TimewebPhotoUploadLease lease;
  final TimewebProfilePhotoSource source;
  final result = Completer<TimewebPhotoPutOutcome>(),
      settled = Completer<void>();
  final cancellation = Completer<void>();
  late final Timer timer;
  http.AbortableRequest? request;
  StreamIterator<List<int>>? reader;
  Future<void>? _cancel;
  bool aborted = false;
  Future<void> cancel() =>
      reader == null ? Future.value() : _cancel ??= reader!.cancel();
  void check() {
    lease.requireCurrent();
    if (aborted) {
      throw const TimewebAuthException(
        _photoOperation,
        TimewebAuthError.deadline,
      );
    }
  }

  void abort() {
    aborted = true;
    timer.cancel();
    if (!result.isCompleted) {
      try {
        lease._prepared.requireCurrent();
        result.complete(TimewebPhotoPutOutcome.unknown);
      } catch (stale) {
        result.completeError(stale);
      }
    }
    if (!cancellation.isCompleted) {
      cancellation.complete();
    }
    request?.bodyBytes.fillRange(0, request!.bodyBytes.length, 0);
    source.close();
    unawaited(cancel());
  }

  Future<void> run() async {
    owner._inflightRequests++;
    try {
      check();
      source.requireOpen();
      request =
          http.AbortableRequest(
              'PUT',
              lease._uri,
              abortTrigger: cancellation.future,
            )
            ..followRedirects = false
            ..bodyBytes = source._bytes
            ..headers.addAll(lease._headers);
      final response = await owner._http.send(request!);
      reader = StreamIterator(response.stream);
      check();
      var size = 0;
      while (await reader!.moveNext()) {
        check();
        size += reader!.current.length;
        if (size > 65536) {
          throw const FormatException('Upload response too large.');
        }
      }
      check();
      if (!result.isCompleted) {
        result.complete(
          const [200, 201, 204].contains(response.statusCode)
              ? TimewebPhotoPutOutcome.acknowledged
              : TimewebPhotoPutOutcome.unknown,
        );
      }
    } catch (error) {
      if (!result.isCompleted) {
        try {
          lease._prepared.requireCurrent();
          result.complete(TimewebPhotoPutOutcome.unknown);
        } catch (stale) {
          result.completeError(stale);
        }
      }
    } finally {
      abort();
      await cancel();
      owner._inflightRequests--;
      owner._profilePhotoUploadFlights.remove(this);
      settled.complete();
    }
  }
}

Future<void> _cancelPhotoUploadFlights(
  TimewebAuthClient owner, {
  TimewebProfilePhotoSource? source,
}) async {
  final flights = owner._profilePhotoUploadFlights
      .where((f) => source == null || identical(f.source, source))
      .toList();
  for (final f in flights) {
    f.abort();
  }
  await Future.wait(flights.map((f) => f.settled.future));
}
