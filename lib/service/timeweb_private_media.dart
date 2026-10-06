part of 'timeweb_auth_client.dart';

const _privateMediaMaximumBytes = 32000000;
const _privateMediaMaximumPending = 32;
const _privateMediaMaximumActive = 2;
const _privateMediaTypes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
};
const _mediaOperation = TimewebAuthOperation.media;

/// Server-issued opaque capability only; no URL, owner, path or bearer input.
final class TimewebPrivateMediaRequest {
  TimewebPrivateMediaRequest(String reference) : _reference = reference {
    if (reference.isEmpty ||
        reference.length > 4096 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(reference)) {
      throw ArgumentError('Invalid private media reference.');
    }
  }
  final String _reference;
  @override
  String toString() => 'TimewebPrivateMediaRequest(<redacted>)';
}

/// In-memory bytes only. Recheck after awaits; a retained A/ABA/logout result
/// cannot yield bytes in a later logical session. The bytes getter returns a copy.
final class TimewebPrivateMediaBytes {
  TimewebPrivateMediaBytes._(this._bytes, this._contentType, this._check);
  final Uint8List _bytes;
  final String _contentType;
  final void Function() _check;
  void requireCurrent() => _check();
  Uint8List get bytes {
    _check();
    return Uint8List.fromList(_bytes);
  }

  String get contentType {
    _check();
    return _contentType;
  }

  int get length {
    _check();
    return _bytes.length;
  }

  @override
  String toString() => 'TimewebPrivateMediaBytes(<redacted>)';
}

final class _PrivateMediaReply {
  _PrivateMediaReply(this.status, [this.bytes, this.contentType]);
  final int status;
  final Uint8List? bytes;
  final String? contentType;
}

final class _PrivateMediaFlight {
  _PrivateMediaFlight(
    this.owner,
    this.epoch,
    this.uid,
    this.key,
    this.reference,
  ) {
    // Keep a drain attached even when a caller drops a cancelled GET Future.
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    timer = Timer(
      owner.mediaRequestDeadline,
      () => abort(TimewebAuthError.deadline),
    );
  }
  final TimewebAuthClient owner;
  final int epoch;
  final String uid, key, reference;
  final result = Completer<TimewebPrivateMediaBytes>();
  final stopwatch = Stopwatch()..start();
  final aborts = <Completer<void>>{};
  final cancellations = <Future<void> Function()>{};
  late final Timer timer;
  bool started = false;
  TimewebAuthError? reason;

  void checkSession() {
    owner._checkEpoch(epoch, _mediaOperation);
    if (owner._secureStoreUnsafe || owner._session?.uid != uid) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.staleSession,
      );
    }
  }

  void check() {
    checkSession();
    if (reason == null && stopwatch.elapsed >= owner.mediaRequestDeadline) {
      abort(TimewebAuthError.deadline);
    }
    if (reason != null) throw TimewebAuthException(_mediaOperation, reason!);
  }

  void abort(TimewebAuthError error) {
    reason ??= error;
    timer.cancel();
    if (!started && identical(owner._mediaFlights[key], this)) {
      owner._mediaFlights.remove(key);
    }
    for (final trigger in aborts.toList()) {
      if (!trigger.isCompleted) trigger.complete();
    }
    for (final cancel in cancellations.toList()) {
      unawaited(cancel().catchError((Object _) {}));
    }
    if (!result.isCompleted) {
      result.completeError(TimewebAuthException(_mediaOperation, reason!));
    }
  }
}

void _cancelPrivateMedia(TimewebAuthClient owner) {
  for (final flight in owner._mediaFlights.values.toList()) {
    flight.abort(TimewebAuthError.staleSession);
  }
}

void _pumpPrivateMedia(TimewebAuthClient owner) {
  if (owner._mediaPumping) return;
  owner._mediaPumping = true;
  try {
    // Dart's insertion-ordered map is the bounded FIFO. Expired/cancelled
    // waiting jobs are removed before they can acquire an HTTP slot.
    while (owner._mediaFlights.values.where((f) => f.started).length <
        _privateMediaMaximumActive) {
      _PrivateMediaFlight? next;
      for (final flight in owner._mediaFlights.values) {
        if (!flight.started) {
          next = flight;
          break;
        }
      }
      if (next == null) return;
      next.started = true;
      unawaited(_executePrivateMedia(next));
    }
  } finally {
    owner._mediaPumping = false;
  }
}

Future<TimewebPrivateMediaBytes> _readPrivateMedia(
  TimewebAuthClient owner,
  TimewebPrivateMediaRequest request,
) {
  try {
    owner._checkEnabled(_mediaOperation);
    if (!owner.configuration.privateMediaEnabled) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.disabled,
      );
    }
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    final key =
        '${owner._epoch}\u0000${session.uid}\u0000${request._reference}';
    final previous = owner._mediaFlights[key];
    if (previous != null) return previous.result.future;
    if (owner._mediaFlights.length >= _privateMediaMaximumPending) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.unavailable,
      );
    }
    final flight = _PrivateMediaFlight(
      owner,
      owner._epoch,
      session.uid,
      key,
      request._reference,
    );
    owner._mediaFlights[key] = flight;
    _pumpPrivateMedia(owner);
    return flight.result.future;
  } on TimewebAuthException catch (error) {
    return Future.error(error);
  }
}

Future<void> _executePrivateMedia(_PrivateMediaFlight flight) async {
  final owner = flight.owner;
  try {
    flight.check();
    var session = owner._session!;
    if (!owner
        ._clock()
        .add(owner.accessExpirySkew)
        .isBefore(session.accessExpiresAt)) {
      session = await owner.refresh();
      flight.check();
    }
    var reply = await _privateMediaAttempt(flight, session.accessToken);
    flight.check();
    if (reply.status == 401) {
      // A late 401 for an already rotated token must not repeat a refresh POST.
      if (owner._session?.accessToken == session.accessToken)
        await owner.refresh();
      flight.check();
      session = owner._session!;
      reply = await _privateMediaAttempt(flight, session.accessToken);
      flight.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(flight.epoch);
      }
      throw owner._statusError(_mediaOperation, reply.status);
    }
    final result = TimewebPrivateMediaBytes._(
      reply.bytes!,
      reply.contentType!,
      flight.checkSession,
    );
    flight.check();
    if (!flight.result.isCompleted) flight.result.complete(result);
  } catch (error) {
    if (!flight.result.isCompleted) {
      try {
        flight.check();
        flight.result.completeError(
          error is TimewebAuthException
              ? error
              : const TimewebAuthException(
                  _mediaOperation,
                  TimewebAuthError.network,
                ),
        );
      } on TimewebAuthException catch (stale) {
        if (!flight.result.isCompleted) flight.result.completeError(stale);
      }
    }
  } finally {
    flight.timer.cancel();
    // Timeout does not pretend an injected hanging send/cancel has settled.
    // This flight slot is held until the actual operation above finishes.
    if (identical(owner._mediaFlights[flight.key], flight))
      owner._mediaFlights.remove(flight.key);
    _pumpPrivateMedia(owner);
  }
}

Future<_PrivateMediaReply> _privateMediaAttempt(
  _PrivateMediaFlight flight,
  String bearer,
) async {
  final owner = flight.owner;
  flight.check();
  if (owner._inflightRequests >= 4) {
    throw const TimewebAuthException(
      _mediaOperation,
      TimewebAuthError.unavailable,
    );
  }
  final trigger = Completer<void>();
  final request =
      http.AbortableRequest(
          'GET',
          owner.configuration.endpoint.replace(
            pathSegments: ['v1', 'media', flight.reference],
          ),
          abortTrigger: trigger.future,
        )
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $bearer'
        ..headers['Accept'] = _privateMediaTypes.join(', ')
        ..headers['Cache-Control'] = 'no-store';
  StreamIterator<List<int>>? reader;
  Future<void>? cancellation;
  Future<void> cancelReader() {
    if (reader == null) return Future<void>.value();
    return cancellation ??= reader.cancel();
  }

  flight.aborts.add(trigger);
  flight.cancellations.add(cancelReader);
  owner._inflightRequests++;
  try {
    final response = await owner._http.send(request);
    reader = StreamIterator(response.stream);
    // StreamIterator is lazy: begin its subscription before any header/stale
    // refusal, so cancellation also closes a never-consumed late response.
    var moving = reader.moveNext();
    unawaited(moving.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    flight.check();
    if (response.statusCode >= 300 && response.statusCode < 400 ||
        response.isRedirect) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.invalidResponse,
      );
    }
    if (response.statusCode != 200)
      return _PrivateMediaReply(response.statusCode);
    final lengthHeader = response.headers['content-length'] ?? '';
    final length = int.tryParse(lengthHeader);
    final mime = response.headers['content-type']?.toLowerCase() ?? '';
    final cache = (response.headers['cache-control'] ?? '')
        .toLowerCase()
        .split(',')
        .map((v) => v.trim())
        .toSet();
    final encoding = response.headers['content-encoding']?.toLowerCase();
    if (!RegExp(r'^[1-9][0-9]{0,7}$').hasMatch(lengthHeader) ||
        length == null ||
        length > _privateMediaMaximumBytes ||
        (response.contentLength != null && response.contentLength != length) ||
        !_privateMediaTypes.contains(mime) ||
        !cache.contains('private') ||
        !cache.contains('no-store') ||
        cache.contains('public') ||
        response.headers['x-content-type-options']?.toLowerCase() !=
            'nosniff' ||
        (encoding != null && encoding != 'identity')) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.invalidResponse,
      );
    }
    final bytes = Uint8List(length);
    var offset = 0;
    while (await moving) {
      flight.check();
      final chunk = reader.current;
      if (chunk.length > length - offset) {
        throw const TimewebAuthException(
          _mediaOperation,
          TimewebAuthError.invalidResponse,
        );
      }
      bytes.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
      moving = reader.moveNext();
    }
    flight.check();
    if (offset != length) {
      throw const TimewebAuthException(
        _mediaOperation,
        TimewebAuthError.invalidResponse,
      );
    }
    return _PrivateMediaReply(200, bytes, mime);
  } finally {
    try {
      if (!trigger.isCompleted) trigger.complete();
      await cancelReader();
    } finally {
      flight.aborts.remove(trigger);
      flight.cancellations.remove(cancelReader);
      owner._inflightRequests--;
    }
  }
}
