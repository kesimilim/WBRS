part of 'timeweb_auth_client.dart';

const _photoOperation = TimewebAuthOperation.currentRead;
const _photoMaxBytes = 8 * 1024 * 1024;
const _photoTypes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'};

/// A current target/storage refusal leaves a healthy native identity signed in.
final class TimewebProfilePhotoUnavailable implements Exception {
  const TimewebProfilePhotoUnavailable();
  @override
  String toString() => 'TimewebProfilePhotoUnavailable';
}

/// Tokens never become URLs or persisted application state. Each belongs to
/// one reader, actor, target, epoch and conservative sixty-second deadline.
final class TimewebProfilePhotoReference {
  TimewebProfilePhotoReference._(
    this._reader,
    this._value,
    this._expiresAt,
    this._ordinal,
    this._primary,
    this._mime,
    this._length,
  );
  final TimewebProfilePhotoReader _reader;
  final String _value;
  final DateTime _expiresAt;
  final int _ordinal, _length;
  final bool _primary;
  final String _mime;
  void requireCurrent() {
    _reader.requireCurrent();
    if (!_reader._client._clock().isBefore(_expiresAt)) _photoExpired();
  }

  int get ordinal {
    _reader.requireCurrent();
    return _ordinal;
  }

  bool get isPrimary {
    _reader.requireCurrent();
    return _primary;
  }

  String get contentType {
    _reader.requireCurrent();
    return _mime;
  }

  int get byteSize {
    _reader.requireCurrent();
    return _length;
  }

  @override
  String toString() => 'TimewebProfilePhotoReference(<redacted>)';
}

final class TimewebProfilePhotosCursor {
  TimewebProfilePhotosCursor._(
    this._reader,
    this._value,
    this._expiresAt,
    this._limit,
    this._last,
  );
  final TimewebProfilePhotoReader _reader;
  final String _value;
  final DateTime _expiresAt;
  final int _limit, _last;
  void requireCurrent() {
    _reader.requireCurrent();
    if (!_reader._client._clock().isBefore(_expiresAt)) _photoExpired();
  }

  @override
  String toString() => 'TimewebProfilePhotosCursor(<redacted>)';
}

final class TimewebProfilePhotosPage {
  TimewebProfilePhotosPage._(this._reader, this._items, this._cursor);
  final TimewebProfilePhotoReader _reader;
  final List<TimewebProfilePhotoReference> _items;
  final TimewebProfilePhotosCursor? _cursor;
  void requireCurrent() => _reader.requireCurrent();
  List<TimewebProfilePhotoReference> get items {
    requireCurrent();
    return _items;
  }

  TimewebProfilePhotosCursor? get nextCursor {
    requireCurrent();
    return _cursor;
  }

  @override
  String toString() => 'TimewebProfilePhotosPage(<redacted>)';
}

final class TimewebProfilePhotoBytes {
  TimewebProfilePhotoBytes._(this._reader, this._bytes, this._mime);
  final TimewebProfilePhotoReader _reader;
  final Uint8List _bytes;
  final String _mime;
  void requireCurrent() => _reader.requireCurrent();
  String get contentType {
    requireCurrent();
    return _mime;
  }

  Uint8List get bytes {
    requireCurrent();
    return Uint8List.fromList(_bytes);
  }

  @override
  String toString() => 'TimewebProfilePhotoBytes(<redacted>)';
}

/// A page owns its transfers. Closing it synchronously revokes all results;
/// the returned future waits for actual transport/stream cancellation. Slots
/// remain occupied until that cancellation settles, including late send().
final class TimewebProfilePhotoReader {
  TimewebProfilePhotoReader._(
    this._client,
    this._target,
    this._epoch,
    this._actor,
    this._id,
  );
  final TimewebAuthClient _client;
  final String _target, _actor;
  final int _epoch, _id;
  void Function()? _sessionGuard;
  bool _closed = false;
  Future<void>? _drain;
  void requireCurrent() {
    _client._checkEpoch(_epoch, _photoOperation);
    if (_closed ||
        _client._secureStoreUnsafe ||
        _client._session?.uid != _actor) {
      throw const TimewebAuthException(
        _photoOperation,
        TimewebAuthError.staleSession,
      );
    }
    _sessionGuard?.call();
  }

  TimewebProfilePhotoReader bindSessionGuard(void Function() guard) {
    requireCurrent();
    final previous = _sessionGuard;
    _sessionGuard = () {
      previous?.call();
      guard();
    };
    requireCurrent();
    return this;
  }

  Future<TimewebProfilePhotosPage> photos({
    int limit = 30,
    TimewebProfilePhotosCursor? cursor,
  }) => _startPhotoRead(
    this,
    limit,
    cursor,
    null,
  ).then((v) => v as TimewebProfilePhotosPage);
  Future<TimewebProfilePhotoBytes> readOriginal(
    TimewebProfilePhotoReference reference,
  ) => _startPhotoRead(
    this,
    0,
    null,
    reference,
  ).then((v) => v as TimewebProfilePhotoBytes);
  Future<void> close() {
    _closed = true;
    return _drain ??= _cancelPhotoFlights(_client, reader: this);
  }

  @override
  String toString() => 'TimewebProfilePhotoReader(<redacted>)';
}

TimewebProfilePhotoReader _openProfilePhotos(
  TimewebAuthClient client,
  String target,
) {
  client._checkEnabled(_photoOperation);
  if (!client.configuration.currentReadsEnabled ||
      !client.configuration.runtimeWritesEnabled) {
    throw const TimewebAuthException(
      _photoOperation,
      TimewebAuthError.disabled,
    );
  }
  if (!_currentIdentifier(target) ||
      target.contains('/') ||
      target.contains('%') ||
      target.contains('\\') ||
      const ['.', '..'].contains(target)) {
    _photoExpired();
  }
  final session = client._session;
  if (session == null || client._secureStoreUnsafe) {
    throw const TimewebAuthException(
      _photoOperation,
      TimewebAuthError.notAuthenticated,
    );
  }
  return TimewebProfilePhotoReader._(
    client,
    target,
    client._epoch,
    session.uid,
    client._profilePhotoReaderSequence++,
  );
}

final class _ProfilePhotoFlight {
  _ProfilePhotoFlight(
    this.reader,
    this.limit,
    this.cursor,
    this.reference,
    this.key,
  ) {
    startedAt = owner._clock();
    var deadline = reference == null
        ? owner.requestDeadline
        : owner.mediaRequestDeadline;
    if (reference != null) {
      final remaining = reference!._expiresAt.difference(startedAt);
      if (remaining < deadline) deadline = remaining;
    }
    budget = deadline;
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    timer = Timer(budget, () => abort(TimewebAuthError.deadline));
  }
  final TimewebProfilePhotoReader reader;
  final int limit;
  final TimewebProfilePhotosCursor? cursor;
  final TimewebProfilePhotoReference? reference;
  final String key;
  TimewebAuthClient get owner => reader._client;
  final result = Completer<Object>();
  final settled = Completer<void>();
  final elapsed = Stopwatch()..start();
  final aborts = <Completer<void>>{};
  final cancellations = <Future<void> Function()>{};
  late final Timer timer;
  late final DateTime startedAt;
  late final Duration budget;
  TimewebAuthError? reason;
  void check() {
    reader.requireCurrent();
    reference?.requireCurrent();
    cursor?.requireCurrent();
    if (reason == null && elapsed.elapsed >= budget) {
      abort(TimewebAuthError.deadline);
    }
    if (reason != null) throw TimewebAuthException(_photoOperation, reason!);
  }

  void abort(TimewebAuthError error) {
    reason ??= error;
    timer.cancel();
    for (final a in aborts.toList()) {
      if (!a.isCompleted) a.complete();
    }
    for (final cancel in cancellations.toList()) {
      unawaited(cancel().catchError((Object _) {}));
    }
    if (!result.isCompleted) {
      result.completeError(TimewebAuthException(_photoOperation, reason!));
    }
  }
}

Future<void> _cancelPhotoFlights(
  TimewebAuthClient client, {
  TimewebProfilePhotoReader? reader,
}) async {
  final flights = client._profilePhotoFlights.values
      .where((f) => reader == null || identical(f.reader, reader))
      .toList();
  for (final f in flights) {
    f.abort(TimewebAuthError.staleSession);
  }
  await Future.wait(flights.map((f) => f.settled.future));
}

Future<Object> _startPhotoRead(
  TimewebProfilePhotoReader reader,
  int limit,
  TimewebProfilePhotosCursor? cursor,
  TimewebProfilePhotoReference? reference,
) {
  try {
    reader.requireCurrent();
    if (reference != null) {
      if (!identical(reference._reader, reader)) _photoExpired();
      reference.requireCurrent();
    } else {
      if (limit < 1 || limit > 30) _photoExpired();
      if (cursor != null) {
        if (!identical(cursor._reader, reader) || cursor._limit != limit) {
          _photoExpired();
        }
        cursor.requireCurrent();
      }
    }
    final client = reader._client;
    final key =
        '${reader._id}\u0000$limit\u0000${cursor?._value ?? ''}\u0000${reference?._value ?? ''}';
    final existing = client._profilePhotoFlights[key];
    if (existing != null) return existing.result.future;
    if (client._profilePhotoFlights.length >= 4) {
      throw const TimewebAuthException(
        _photoOperation,
        TimewebAuthError.unavailable,
      );
    }
    final flight = _ProfilePhotoFlight(reader, limit, cursor, reference, key);
    client._profilePhotoFlights[key] = flight;
    unawaited(_executePhotoRead(flight));
    return flight.result.future;
  } catch (e) {
    return Future.error(e);
  }
}

Future<void> _executePhotoRead(_ProfilePhotoFlight f) async {
  final owner = f.owner;
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
    var reply = await _photoAttempt(f, session.accessToken);
    f.check();
    if (reply.$1 == 401) {
      if (owner._session?.accessToken == session.accessToken) {
        await owner.refresh();
      }
      f.check();
      session = owner._session!;
      reply = await _photoAttempt(f, session.accessToken);
      f.check();
    }
    if (reply.$1 != 200) {
      if (reply.$1 == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(f.reader._epoch);
      }
      if (reply.$1 == 404) throw const TimewebProfilePhotoUnavailable();
      throw owner._statusError(_photoOperation, reply.$1);
    }
    final bytes = reply.$2!;
    final Object value;
    if (f.reference != null) {
      value = TimewebProfilePhotoBytes._(f.reader, bytes, f.reference!._mime);
    } else {
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic>) _photoInvalid();
      value = _decodePhotoPage(f, body);
    }
    f.check();
    if (!f.result.isCompleted) f.result.complete(value);
  } catch (error) {
    if (!f.result.isCompleted) {
      try {
        f.check();
        f.result.completeError(
          error is TimewebAuthException ||
                  error is TimewebProfilePhotoUnavailable
              ? error
              : error is FormatException
              ? const TimewebAuthException(
                  _photoOperation,
                  TimewebAuthError.invalidResponse,
                )
              : const TimewebAuthException(
                  _photoOperation,
                  TimewebAuthError.network,
                ),
        );
      } catch (stale) {
        if (!f.result.isCompleted) f.result.completeError(stale);
      }
    }
  } finally {
    f.timer.cancel();
    if (identical(owner._profilePhotoFlights[f.key], f)) {
      owner._profilePhotoFlights.remove(f.key);
    }
    f.settled.complete();
  }
}

Future<(int, Uint8List?)> _photoAttempt(
  _ProfilePhotoFlight f,
  String bearer,
) async {
  final owner = f.owner;
  f.check();
  if (owner._inflightRequests >= 4) {
    throw const TimewebAuthException(
      _photoOperation,
      TimewebAuthError.unavailable,
    );
  }
  final abort = Completer<void>();
  final binary = f.reference != null;
  final request =
      http.AbortableRequest(
          'GET',
          owner.configuration.endpoint.replace(
            path:
                '/v1/runtime/people/${f.reader._target}/photos${binary ? '/content' : ''}',
            queryParameters: binary
                ? {'reference': f.reference!._value}
                : {
                    'limit': '${f.limit}',
                    if (f.cursor != null) 'cursor': f.cursor!._value,
                  },
          ),
          abortTrigger: abort.future,
        )
        ..followRedirects = false
        ..headers['Accept'] = binary ? f.reference!._mime : 'application/json'
        ..headers['Authorization'] = 'Bearer $bearer'
        ..headers['Cache-Control'] = 'no-store';
  StreamIterator<List<int>>? stream;
  Future<void>? cancellation;
  Future<void> cancel() {
    if (stream == null) return Future.value();
    return cancellation ??= stream.cancel();
  }

  f.aborts.add(abort);
  f.cancellations.add(cancel);
  owner._inflightRequests++;
  try {
    final response = await owner._http.send(request);
    stream = StreamIterator(response.stream);
    f.check();
    if (response.isRedirect ||
        response.statusCode >= 300 && response.statusCode < 400 ||
        response.headers.containsKey('location')) {
      _photoInvalid();
    }
    // Error bodies are deliberately never decoded; a closed 404 cannot cause
    // a parser error, refresh, cached identity change, or healthy image result.
    if (response.statusCode != 200) return (response.statusCode, null);
    final mime = (response.headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();
    final cache = (response.headers['cache-control'] ?? '')
        .toLowerCase()
        .split(',')
        .map((v) => v.trim());
    final encoding = response.headers['content-encoding']?.toLowerCase();
    final length = response.contentLength;
    final max = binary ? f.reference!._length : 65536;
    if (mime != (binary ? f.reference!._mime : 'application/json') ||
        !cache.contains('no-store') ||
        cache.contains('public') ||
        encoding != null && encoding != 'identity' ||
        response.headers.containsKey('content-range') ||
        response.headers.containsKey('accept-ranges') ||
        length != null && (length < 1 || length > max) ||
        binary && (length == null || length != max || max > _photoMaxBytes)) {
      _photoInvalid();
    }
    final collected = BytesBuilder(copy: false);
    var total = 0;
    while (await stream.moveNext()) {
      f.check();
      final chunk = stream.current;
      if (chunk.length > max - total ||
          length != null && chunk.length > length - total) {
        _photoInvalid();
      }
      total += chunk.length;
      collected.add(chunk);
    }
    f.check();
    if (total < 1 ||
        length != null && total != length ||
        binary && total != max) {
      _photoInvalid();
    }
    return (200, collected.takeBytes());
  } finally {
    try {
      if (!abort.isCompleted) abort.complete();
      await cancel();
    } finally {
      f.aborts.remove(abort);
      f.cancellations.remove(cancel);
      owner._inflightRequests--;
    }
  }
}

TimewebProfilePhotosPage _decodePhotoPage(
  _ProfilePhotoFlight f,
  Map<String, dynamic> body,
) {
  if (!_mutationExact(body, {
        'kind',
        'targetUid',
        'ordering',
        'items',
        'nextCursor',
      }) ||
      body['kind'] != 'canonical-profile-photos' ||
      body['targetUid'] != f.reader._target ||
      body['ordering'] != 'ordinal_asc' ||
      body['items'] is! List ||
      (body['items'] as List).length > f.limit) {
    _photoInvalid();
  }
  final expiry = f.startedAt.add(const Duration(seconds: 60));
  final items = <TimewebProfilePhotoReference>[];
  final tokens = <String>{};
  var ordinal = (f.cursor?._last ?? -1) + 1;
  for (final row in body['items'] as List) {
    if (row is! Map<String, dynamic> ||
        !_mutationExact(row, {
          'ordinal',
          'isPrimary',
          'contentType',
          'byteSize',
          'reference',
        }) ||
        row['ordinal'] is! int ||
        row['ordinal'] != ordinal ||
        ordinal >= 50 ||
        row['isPrimary'] is! bool ||
        row['isPrimary'] != (ordinal == 0) ||
        !_photoTypes.contains(row['contentType']) ||
        row['byteSize'] is! int ||
        row['byteSize'] < 1 ||
        row['byteSize'] > _photoMaxBytes ||
        row['reference'] is! String ||
        !_validReadCursor(row['reference']) ||
        !tokens.add(row['reference'])) {
      _photoInvalid();
    }
    items.add(
      TimewebProfilePhotoReference._(
        f.reader,
        row['reference'],
        expiry,
        ordinal,
        row['isPrimary'],
        row['contentType'],
        row['byteSize'],
      ),
    );
    ordinal++;
  }
  final next = body['nextCursor'];
  if (next != null &&
      (next is! String ||
          !_validReadCursor(next) ||
          next == f.cursor?._value ||
          items.isEmpty ||
          ordinal >= 50)) {
    _photoInvalid();
  }
  return TimewebProfilePhotosPage._(
    f.reader,
    List.unmodifiable(items),
    next == null
        ? null
        : TimewebProfilePhotosCursor._(
            f.reader,
            next,
            expiry,
            f.limit,
            ordinal - 1,
          ),
  );
}

Never _photoExpired() => throw const TimewebAuthException(
  _photoOperation,
  TimewebAuthError.invalidRequest,
);
Never _photoInvalid() => throw const TimewebAuthException(
  _photoOperation,
  TimewebAuthError.invalidResponse,
);
