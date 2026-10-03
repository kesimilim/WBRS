part of 'timeweb_auth_client.dart';

/// Page-owned native bytes; no caller URL, disk cache or legacy media fallback.
final class TimewebPostMediaBytes {
  TimewebPostMediaBytes._(
    this._reader,
    this._bytes,
    this._mime,
    this._generation,
  );
  final TimewebPostMediaReader _reader;
  final Uint8List _bytes;
  final String _mime;
  final int _generation;
  void requireCurrent() {
    _reader.requireCurrent();
    if (_reader._generation != _generation) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.staleSession,
      );
    }
  }

  Uint8List get bytes {
    requireCurrent();
    return Uint8List.fromList(_bytes);
  }

  String get contentType {
    requireCurrent();
    return _mime;
  }

  @override
  String toString() => 'TimewebPostMediaBytes(<redacted>)';
}

final class TimewebPostMediaUnavailable implements Exception {
  const TimewebPostMediaUnavailable();
}

final class TimewebPostMediaReader {
  TimewebPostMediaReader._(
    this._owner,
    this._postId,
    this._mediaId,
    this._epoch,
    this._uid,
  );
  final TimewebAuthClient _owner;
  final String _postId, _mediaId, _uid;
  final int _epoch;
  void Function()? _guard;
  final _flights = <_PeopleFlight>{}, _buffers = <Uint8List>[];
  Future<TimewebPostMediaBytes>? _active;
  bool _closed = false;
  int _generation = 0;
  void _clear() {
    _generation++;
    for (final b in _buffers) {
      b.fillRange(0, b.length, 0);
    }
    _buffers.clear();
  }

  void requireCurrent() {
    _owner._checkEpoch(_epoch, _mediaOperation);
    if (_closed || _owner._secureStoreUnsafe || _owner._session?.uid != _uid) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.staleSession,
      );
    }
    _guard?.call();
  }

  TimewebPostMediaReader bindSessionGuard(void Function() guard) {
    requireCurrent();
    _guard = guard;
    return this;
  }

  Future<TimewebPostMediaBytes> read() {
    try {
      requireCurrent();
      if (_active != null) {
        return _active!;
      }
      _clear();
      if (_owner._peopleFlights.length >= 4) {
        throw const TimewebAuthException(
          _mediaOperation,
          TimewebAuthError.unavailable,
        );
      }
      final key = 'post-media:$_epoch/${identityHashCode(this)}';
      final f = _PeopleFlight(_owner, null, null, null, _epoch, _uid, key);
      _owner._peopleFlights[key] = f;
      _flights.add(f);
      final future = f.result.future.then((v) => v as TimewebPostMediaBytes);
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
      unawaited(_execute(f));
      return future;
    } catch (error) {
      return Future.error(error);
    }
  }

  Future<void> _execute(_PeopleFlight f) async {
    try {
      requireCurrent();
      f.check();
      var session = _owner._session!;
      if (!_owner
          ._clock()
          .add(_owner.accessExpirySkew)
          .isBefore(session.accessExpiresAt)) {
        session = await _owner.refresh();
        requireCurrent();
        f.check();
      }
      var reply = await _attempt(f, session.accessToken);
      requireCurrent();
      f.check();
      if (reply.$1 == 401) {
        if (_owner._session?.accessToken == session.accessToken) {
          await _owner.refresh();
        }
        requireCurrent();
        f.check();
        session = _owner._session!;
        reply = await _attempt(f, session.accessToken);
        requireCurrent();
        f.check();
      }
      if (reply.$1 != 200) {
        if (reply.$1 == 401 &&
            _owner._session?.accessToken == session.accessToken) {
          await _owner._invalidate(_epoch);
        }
        if (reply.$1 == 404) {
          throw const TimewebPostMediaUnavailable();
        }
        throw _owner._statusError(_mediaOperation, reply.$1);
      }
      for (final bytes in _buffers) {
        bytes.fillRange(0, bytes.length, 0);
      }
      _buffers.clear();
      _buffers.add(reply.$2!);
      if (!f.result.isCompleted) {
        f.result.complete(
          TimewebPostMediaBytes._(this, reply.$2!, reply.$3!, _generation),
        );
      }
    } catch (error) {
      if (!f.result.isCompleted) {
        try {
          requireCurrent();
          f.check();
          f.result.completeError(
            error is TimewebAuthException ||
                    error is TimewebPostMediaUnavailable
                ? error
                : const TimewebAuthException(
                    _mediaOperation,
                    TimewebAuthError.invalidResponse,
                  ),
          );
        } catch (stale) {
          if (!f.result.isCompleted) {
            f.result.completeError(stale);
          }
        }
      }
    } finally {
      f.timer.cancel();
      if (identical(_owner._peopleFlights[f.key], f)) {
        _owner._peopleFlights.remove(f.key);
      }
      _flights.remove(f);
      f.settled.complete();
    }
  }

  Future<(int, Uint8List?, String?)> _attempt(
    _PeopleFlight f,
    String bearer,
  ) async {
    requireCurrent();
    f.check();
    if (_owner._inflightRequests >= 4) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.unavailable,
      );
    }
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(
            'GET',
            _owner.configuration.endpoint.replace(
              pathSegments: [
                'v1',
                'runtime',
                'posts',
                _postId,
                'media',
                _mediaId,
                'content',
              ],
            ),
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers['Accept'] = 'image/jpeg, image/png, image/webp'
          ..headers['Authorization'] = 'Bearer $bearer'
          ..headers['Cache-Control'] = 'no-store';
    StreamIterator<List<int>>? stream;
    Future<void>? cancellation;
    Future<void> cancel() =>
        stream == null ? Future.value() : cancellation ??= stream.cancel();
    f.aborts.add(abort);
    f.cancellations.add(cancel);
    _owner._inflightRequests++;
    try {
      final response = await _owner._http.send(request);
      stream = StreamIterator(response.stream);
      requireCurrent();
      f.check();
      if (response.isRedirect ||
          response.statusCode >= 300 && response.statusCode < 400 ||
          response.headers.containsKey('location')) {
        _photoInvalid();
      }
      if (response.statusCode != 200) {
        return (response.statusCode, null, null);
      }
      final mime = (response.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      final cache = (response.headers['cache-control'] ?? '')
          .toLowerCase()
          .split(',')
          .map((v) => v.trim());
      final encoding = response.headers['content-encoding']?.toLowerCase(),
          length = response.contentLength;
      if (!const {'image/jpeg', 'image/png', 'image/webp'}.contains(mime) ||
          !cache.contains('no-store') ||
          cache.contains('public') ||
          encoding != null && encoding != 'identity' ||
          response.headers.containsKey('content-range') ||
          response.headers.containsKey('accept-ranges') ||
          length == null ||
          length < 1 ||
          length > 5 * 1024 * 1024) {
        _photoInvalid();
      }
      final bytes = BytesBuilder(copy: false);
      var total = 0;
      while (await stream.moveNext()) {
        requireCurrent();
        f.check();
        final chunk = stream.current;
        if (chunk.length > length - total) {
          _photoInvalid();
        }
        total += chunk.length;
        bytes.add(chunk);
      }
      requireCurrent();
      f.check();
      if (total != length) {
        _photoInvalid();
      }
      return (200, bytes.takeBytes(), mime);
    } finally {
      try {
        if (!abort.isCompleted) {
          abort.complete();
        }
        await cancel();
      } finally {
        f.aborts.remove(abort);
        f.cancellations.remove(cancel);
        _owner._inflightRequests--;
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _active = null;
    _clear();
    final flights = _flights.toList();
    for (final f in flights) {
      f.abort(TimewebAuthError.staleSession);
    }
    await Future.wait(flights.map((v) => v.settled.future));
  }

  @override
  String toString() => 'TimewebPostMediaReader(<redacted>)';
}

extension TimewebPostMediaClient on TimewebAuthClient {
  TimewebPostMediaReader openPostMedia(String postId, String mediaId) {
    _checkEnabled(_mediaOperation);
    if (!configuration.currentReadsEnabled ||
        !configuration.runtimeWritesEnabled) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.disabled,
      );
    }
    if (!_mutationId(postId) ||
        !RegExp(r'^tw-post-media-[a-f0-9]{64}$').hasMatch(mediaId)) {
      throw ArgumentError('Invalid native post media.');
    }
    if (_session == null || _secureStoreUnsafe) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    return TimewebPostMediaReader._(
      this,
      postId,
      mediaId,
      _epoch,
      _session!.uid,
    );
  }
}
