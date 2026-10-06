part of 'timeweb_auth_client.dart';

const _adminUsersOperation = TimewebAuthOperation.currentRead;

/// Read-only admin query. The server owns Unicode casefold and current role
/// authority; the exact submitted prefix/limit bind the RAM-only continuation.
final class TimewebAdminUsersRequest {
  factory TimewebAdminUsersRequest({String query = '', int limit = 30}) {
    if (limit < 1 || limit > 30 || !acceptsQuery(query)) {
      throw ArgumentError('Invalid admin users request.');
    }
    return TimewebAdminUsersRequest._(query.trim(), limit);
  }
  TimewebAdminUsersRequest._(this.query, this.limit);
  final String query;
  final int limit;
  static bool acceptsQuery(String query) =>
      query.runes.length <= 100 &&
      utf8.encode(query).length <= 400 &&
      utf8.decode(utf8.encode(query)) == query &&
      !query.runes.any((r) => r < 32 || r == 127) &&
      (query.trim().isEmpty || query.trim().runes.length >= 2);
  Map<String, String> get _query => {
    'limit': '$limit',
    if (query.isNotEmpty) 'query': query,
  };
  String get _scope => jsonEncode(_query);
  @override
  String toString() => 'TimewebAdminUsersRequest(<redacted>)';
}

/// A denied admin role leaves the valid ordinary native session signed in.
final class TimewebAdminAccessDenied implements Exception {
  const TimewebAdminAccessDenied();
  @override
  String toString() => 'TimewebAdminAccessDenied';
}

final class TimewebAdminUsersCursor {
  TimewebAdminUsersCursor._(
    this._value,
    this._owner,
    this._scope,
    this._check,
    this._expiresAt,
  );
  final String _value, _scope;
  final TimewebAuthClient _owner;
  final void Function() _check;
  final DateTime _expiresAt;
  void requireCurrent() {
    _check();
    if (!_owner._clock().isBefore(_expiresAt)) {
      throw const TimewebAuthException(
        _adminUsersOperation,
        TimewebAuthError.invalidRequest,
      );
    }
  }

  @override
  String toString() => 'TimewebAdminUsersCursor(<redacted>)';
}

final class TimewebAdminUser {
  TimewebAdminUser._(this._values, this._check);
  final Map<String, dynamic> _values;
  final void Function() _check;
  void requireCurrent() => _check();
  T _value<T>(String key) {
    _check();
    return _values[key] as T;
  }

  String get uid => _value('uid');
  String? get email => _value('email');
  String? get fullName => _value('fullName');
  int? get age => _value('age');
  String get lifecycle => _value('lifecycle');
  bool get disabled => _value('disabled');
  TimewebAdminUser _bind(void Function() guard) =>
      TimewebAdminUser._(_values, () {
        requireCurrent();
        guard();
      });
  @override
  String toString() => 'TimewebAdminUser(<redacted>)';
}

final class TimewebAdminUsersResult {
  TimewebAdminUsersResult._(this._items, this._cursor, this._check);
  final List<TimewebAdminUser> _items;
  final TimewebAdminUsersCursor? _cursor;
  final void Function() _check;
  void requireCurrent() => _check();
  List<TimewebAdminUser> get items {
    _check();
    return _items;
  }

  TimewebAdminUsersCursor? get nextCursor {
    _check();
    return _cursor;
  }

  TimewebAdminUsersResult bindSessionGuard(void Function() guard) {
    void check() {
      requireCurrent();
      guard();
    }

    final cursor = _cursor;
    return TimewebAdminUsersResult._(
      List.unmodifiable(_items.map((row) => row._bind(guard))),
      cursor == null
          ? null
          : TimewebAdminUsersCursor._(
              cursor._value,
              cursor._owner,
              cursor._scope,
              () {
                cursor.requireCurrent();
                guard();
              },
              cursor._expiresAt,
            ),
      check,
    );
  }

  @override
  String toString() => 'TimewebAdminUsersResult(<redacted>)';
}

final class _AdminUsersFlight {
  _AdminUsersFlight(
    this.owner,
    this.request,
    this.cursor,
    this.epoch,
    this.uid,
    this.key,
  ) {
    startedAt = owner._clock();
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    timer = Timer(
      owner.requestDeadline,
      () => abort(TimewebAuthError.deadline),
    );
  }
  final TimewebAuthClient owner;
  final TimewebAdminUsersRequest request;
  final TimewebAdminUsersCursor? cursor;
  final int epoch;
  final String uid, key;
  final result = Completer<Object>();
  final settled = Completer<void>();
  final elapsed = Stopwatch()..start();
  final aborts = <Completer<void>>{};
  final cancellations = <Future<void> Function()>{};
  late final Timer timer;
  late final DateTime startedAt;
  TimewebAuthError? reason;
  void checkSession() {
    owner._checkEpoch(epoch, _adminUsersOperation);
    if (owner._secureStoreUnsafe || owner._session?.uid != uid) {
      throw const TimewebAuthException(
        _adminUsersOperation,
        TimewebAuthError.staleSession,
      );
    }
  }

  void check() {
    checkSession();
    if (reason == null && elapsed.elapsed >= owner.requestDeadline) {
      abort(TimewebAuthError.deadline);
    }
    if (reason != null) {
      throw TimewebAuthException(_adminUsersOperation, reason!);
    }
  }

  void abort(TimewebAuthError error) {
    reason ??= error;
    timer.cancel();
    for (final abort in aborts.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    for (final cancel in cancellations.toList()) {
      unawaited(cancel().catchError((Object _) {}));
    }
    if (!result.isCompleted) {
      result.completeError(TimewebAuthException(_adminUsersOperation, reason!));
    }
  }
}

Future<void> _cancelAdminUsersReads(TimewebAuthClient owner) async {
  final flights = owner._adminUsersFlights.values.toList();
  for (final flight in flights) {
    flight.abort(TimewebAuthError.staleSession);
  }
  await Future.wait(flights.map((flight) => flight.settled.future));
}

Future<Object> _startAdminUsersRead(
  TimewebAuthClient owner,
  TimewebAdminUsersRequest request,
  TimewebAdminUsersCursor? cursor,
) {
  try {
    owner._checkEnabled(_adminUsersOperation);
    if (!owner.configuration.currentReadsEnabled ||
        !owner.configuration.runtimeWritesEnabled) {
      throw const TimewebAuthException(
        _adminUsersOperation,
        TimewebAuthError.disabled,
      );
    }
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) {
      throw const TimewebAuthException(
        _adminUsersOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    if (cursor != null) {
      if (!identical(cursor._owner, owner) || cursor._scope != request._scope) {
        throw const TimewebAuthException(
          _adminUsersOperation,
          TimewebAuthError.invalidRequest,
        );
      }
      cursor.requireCurrent();
    }
    final key =
        '${owner._epoch}\u0000${request._scope}\u0000${cursor?._value ?? ''}';
    final existing = owner._adminUsersFlights[key];
    if (existing != null) return existing.result.future;
    if (owner._adminUsersFlights.length >= 4) {
      throw const TimewebAuthException(
        _adminUsersOperation,
        TimewebAuthError.unavailable,
      );
    }
    final flight = _AdminUsersFlight(
      owner,
      request,
      cursor,
      owner._epoch,
      session.uid,
      key,
    );
    owner._adminUsersFlights[key] = flight;
    unawaited(_executeAdminUsersRead(flight));
    return flight.result.future;
  } catch (error) {
    return Future.error(error);
  }
}

Future<void> _executeAdminUsersRead(_AdminUsersFlight flight) async {
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
    var reply = await _adminUsersAttempt(flight, session.accessToken);
    flight.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken) {
        await owner.refresh();
      }
      flight.check();
      session = owner._session!;
      reply = await _adminUsersAttempt(flight, session.accessToken);
      flight.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(flight.epoch);
      }
      if (reply.status == 403) {
        throw const TimewebAdminAccessDenied();
      }
      throw owner._statusError(_adminUsersOperation, reply.status);
    }
    final value = _decodeAdminUsersRead(flight, reply.body!);
    flight.check();
    if (!flight.result.isCompleted) {
      flight.result.complete(value);
    }
  } catch (error) {
    if (!flight.result.isCompleted) {
      try {
        flight.check();
        flight.result.completeError(
          error is TimewebAuthException || error is TimewebAdminAccessDenied
              ? error
              : const TimewebAuthException(
                  _adminUsersOperation,
                  TimewebAuthError.network,
                ),
        );
      } on TimewebAuthException catch (stale) {
        if (!flight.result.isCompleted) {
          flight.result.completeError(stale);
        }
      }
    }
  } finally {
    flight.timer.cancel();
    if (identical(owner._adminUsersFlights[flight.key], flight)) {
      owner._adminUsersFlights.remove(flight.key);
    }
    flight.settled.complete();
  }
}

Future<_Reply> _adminUsersAttempt(
  _AdminUsersFlight flight,
  String bearer,
) async {
  final owner = flight.owner;
  flight.check();
  if (owner._inflightRequests >= 4) {
    throw const TimewebAuthException(
      _adminUsersOperation,
      TimewebAuthError.unavailable,
    );
  }
  final abort = Completer<void>();
  final request =
      http.AbortableRequest(
          'GET',
          owner.configuration.endpoint.replace(
            path: '/v1/runtime/admin/users',
            queryParameters: {
              ...flight.request._query,
              if (flight.cursor != null) 'cursor': flight.cursor!._value,
            },
          ),
          abortTrigger: abort.future,
        )
        ..followRedirects = false
        ..headers['Accept'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $bearer'
        ..headers['Cache-Control'] = 'no-store';
  StreamIterator<List<int>>? reader;
  Future<void>? cancellation;
  Future<void> cancelReader() {
    final current = reader;
    if (current == null) {
      return Future.value();
    }
    return cancellation ??= current.cancel();
  }

  flight.aborts.add(abort);
  flight.cancellations.add(cancelReader);
  owner._inflightRequests++;
  try {
    final response = await owner._http.send(request);
    reader = StreamIterator(response.stream);
    var moving = reader.moveNext();
    unawaited(moving.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    flight.check();
    if (response.isRedirect ||
        response.statusCode >= 300 && response.statusCode < 400) {
      _adminUsersInvalid();
    }
    if (response.statusCode != 200) {
      return _Reply(response.statusCode, null);
    }
    final mime = response.headers['content-type']?.toLowerCase() ?? '';
    final cache = (response.headers['cache-control'] ?? '')
        .toLowerCase()
        .split(',')
        .map((v) => v.trim());
    final encoding = response.headers['content-encoding']?.toLowerCase();
    if (mime.split(';').first.trim() != 'application/json' ||
        !cache.contains('no-store') ||
        cache.contains('public') ||
        (encoding != null && encoding != 'identity') ||
        (response.contentLength != null && response.contentLength! > 65536)) {
      _adminUsersInvalid();
    }
    final bytes = <int>[];
    while (await moving) {
      flight.check();
      final chunk = reader.current;
      if (bytes.length + chunk.length > 65536) {
        _adminUsersInvalid();
      }
      bytes.addAll(chunk);
      moving = reader.moveNext();
    }
    flight.check();
    if (response.contentLength != null &&
        response.contentLength != bytes.length) {
      _adminUsersInvalid();
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      _adminUsersInvalid();
    }
    return _Reply(200, decoded);
  } on FormatException {
    _adminUsersInvalid();
  } finally {
    try {
      if (!abort.isCompleted) abort.complete();
      await cancelReader();
    } finally {
      flight.aborts.remove(abort);
      flight.cancellations.remove(cancelReader);
      owner._inflightRequests--;
    }
  }
}

TimewebAdminUsersResult _decodeAdminUsersRead(
  _AdminUsersFlight flight,
  Map<String, dynamic> body,
) {
  if (!_mutationExact(body, {'kind', 'ordering', 'items', 'nextCursor'}) ||
      body['kind'] != 'canonical-admin-users' ||
      body['ordering'] != 'uid_binary_asc' ||
      body['items'] is! List ||
      (body['items'] as List).length > flight.request.limit) {
    _adminUsersInvalid();
  }
  final rows = <TimewebAdminUser>[];
  String? previous;
  for (final value in body['items'] as List) {
    if (value is! Map<String, dynamic> ||
        !_mutationExact(value, {
          'uid',
          'email',
          'fullName',
          'age',
          'lifecycle',
          'disabled',
        }) ||
        !_currentIdentifier(value['uid']) ||
        (value['uid'] as String).contains('/') ||
        const ['.', '..'].contains(value['uid']) ||
        !_currentNullableText(value['fullName'], 1000) ||
        !_currentNullableText(value['email'], 320) ||
        value['disabled'] is! bool ||
        !const ['active', 'blocked', 'deleted'].contains(value['lifecycle'])) {
      _adminUsersInvalid();
    }
    final email = value['email'] as String?, age = value['age'];
    if (email != null &&
            (email.isEmpty ||
                email != email.trim().toLowerCase() ||
                email.runes.any((r) => r < 32 || r == 127)) ||
        age != null && (age is! int || age < 0 || age > 130)) {
      _adminUsersInvalid();
    }
    final uid = value['uid'] as String;
    if (previous != null && _currentCompareIds(previous, uid) >= 0) {
      _adminUsersInvalid();
    }
    rows.add(TimewebAdminUser._(Map.unmodifiable(value), flight.checkSession));
    previous = uid;
  }
  final next = body['nextCursor'];
  if (next != null &&
      (!_validReadCursor(next is String ? next : '') ||
          next == flight.cursor?._value)) {
    _adminUsersInvalid();
  }
  return TimewebAdminUsersResult._(
    List.unmodifiable(rows),
    next == null
        ? null
        : TimewebAdminUsersCursor._(
            next,
            flight.owner,
            flight.request._scope,
            flight.checkSession,
            flight.startedAt.add(const Duration(seconds: 300)),
          ),
    flight.checkSession,
  );
}

Never _adminUsersInvalid() => throw const TimewebAuthException(
  _adminUsersOperation,
  TimewebAuthError.invalidResponse,
);
