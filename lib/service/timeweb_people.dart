part of 'timeweb_auth_client.dart';

const _peopleOperation = TimewebAuthOperation.currentRead;

/// Exact supported filters only. Geography comes from the pinned catalog;
/// defaults and ordering match the current server contract.
final class TimewebPeopleFilters {
  TimewebPeopleFilters._(this._query);
  final Map<String, String> _query;
  static Future<TimewebPeopleFilters> fromCatalog({
    int limit = 30,
    int minAge = 18,
    int maxAge = 100,
    String? countryCode,
    String? region,
    String? pol,
    String? compatibleGroup,
  }) async {
    if (limit < 1 ||
        limit > 30 ||
        minAge < 18 ||
        maxAge > 100 ||
        minAge > maxAge ||
        pol != null && !const ['м', 'ж'].contains(pol) ||
        compatibleGroup != null &&
            !_ownProfileGroups.contains(compatibleGroup) ||
        region != null && countryCode == null) {
      throw ArgumentError('Invalid people filters.');
    }
    if (countryCode != null) {
      final catalog = await _pinnedGeographyCatalog();
      final countries = catalog['countries'] as List;
      final matches = countries.where((row) => row['code'] == countryCode);
      if (matches.length != 1 ||
          region != null &&
              !(matches.single['regions'] as List).contains(region)) {
        throw ArgumentError('Choose approved geography.');
      }
    }
    return TimewebPeopleFilters._(
      Map.unmodifiable({
        'limit': '$limit',
        'minAge': '$minAge',
        'maxAge': '$maxAge',
        if (countryCode != null) 'countryCode': countryCode,
        if (region != null) 'region': region,
        if (pol != null) 'pol': pol,
        if (compatibleGroup != null) 'compatibleGroup': compatibleGroup,
      }),
    );
  }

  static bool acceptsGroup(String group) => _ownProfileGroups.contains(group);

  int get limit => int.parse(_query['limit']!);
  int get minAge => int.parse(_query['minAge']!);
  int get maxAge => int.parse(_query['maxAge']!);
  String? get countryCode => _query['countryCode'];
  String? get region => _query['region'];
  String? get pol => _query['pol'];
  String? get compatibleGroup => _query['compatibleGroup'];
  String get _scope => jsonEncode(_query);
  @override
  String toString() => 'TimewebPeopleFilters(<redacted>)';
}

/// Opaque encrypted server continuation; RAM only, never persisted or logged.
final class TimewebPeopleCursor {
  TimewebPeopleCursor._(
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
        _peopleOperation,
        TimewebAuthError.invalidRequest,
      );
    }
  }

  @override
  String toString() => 'TimewebPeopleCursor(<redacted>)';
}

final class TimewebPeoplePage {
  TimewebPeoplePage._(this._items, this._cursor, this._check);
  final List<TimewebPublicPerson> _items;
  final TimewebPeopleCursor? _cursor;
  final void Function() _check;
  void requireCurrent() => _check();
  List<TimewebPublicPerson> get items {
    _check();
    return _items;
  }

  TimewebPeopleCursor? get nextCursor {
    _check();
    return _cursor;
  }

  bool get mediaReady {
    _check();
    return false;
  }

  TimewebPeoplePage bindSessionGuard(void Function() guard) {
    void check() {
      requireCurrent();
      guard();
    }

    return TimewebPeoplePage._(
      List.unmodifiable(_items.map((row) => row.bindSessionGuard(guard))),
      _cursor == null
          ? null
          : TimewebPeopleCursor._(
              _cursor._value,
              _cursor._owner,
              _cursor._scope,
              () {
                _cursor.requireCurrent();
                guard();
              },
              _cursor._expiresAt,
            ),
      check,
    );
  }

  @override
  String toString() => 'TimewebPeoplePage(<redacted>)';
}

/// One immutable public allowlist. Sparse historical fields keep null/empty
/// values; this DTO never hydrates from source raw or claims native media.
final class TimewebPublicPerson {
  TimewebPublicPerson._(this._data, this._check, this._hasDetails);
  final Map<String, dynamic> _data;
  final void Function() _check;
  final bool _hasDetails;
  void requireCurrent() => _check();
  TimewebPublicPerson bindSessionGuard(void Function() guard) =>
      TimewebPublicPerson._(_data, () {
        requireCurrent();
        guard();
      }, _hasDetails);
  T? _read<T>(String key) {
    _check();
    return _data[key] as T?;
  }

  String get uid => _read<String>('uid')!;
  String? get fullName => _read<String>('fullName');
  int? get age => _read<int>('age');
  String? get pol => _read<String>('pol');
  String? get country => _read<String>('country');
  String? get countryCode => _read<String>('countryCode');
  String? get region => _read<String>('region');
  String? get city => _read<String>('city');
  String? get primaryGroup => _read<String>('primaryGroup');
  String? get secondaryGroup => _read<String>('secondaryGroup');
  String? get lastOnlineAt => _read<String>('lastOnlineAt');
  int? get rost => _read<int>('rost');
  String? get about => _read<String>('about');
  String? get hobbi => _read<String>('hobbi');
  bool? get deti => _read<bool>('deti');
  String? get relationStatus => _read<String>('relationStatus');
  bool get hasDetails {
    _check();
    return _hasDetails;
  }

  bool get mediaReady {
    _check();
    return false;
  }

  TimewebPrivateMediaRequest? get avatar {
    _check();
    return null;
  }

  @override
  String toString() => 'TimewebPublicPerson(<redacted>)';
}

final class TimewebPersonNotFound implements Exception {
  const TimewebPersonNotFound();
  @override
  String toString() => 'TimewebPersonNotFound';
}

final class _PeopleFlight {
  _PeopleFlight(
    this.owner,
    this.filters,
    this.cursor,
    this.targetUid,
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
  final TimewebPeopleFilters? filters;
  final TimewebPeopleCursor? cursor;
  final String? targetUid;
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
    owner._checkEpoch(epoch, _peopleOperation);
    if (owner._secureStoreUnsafe || owner._session?.uid != uid) {
      throw const TimewebAuthException(
        _peopleOperation,
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
      throw TimewebAuthException(_peopleOperation, reason!);
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
      result.completeError(TimewebAuthException(_peopleOperation, reason!));
    }
  }
}

Future<void> _cancelPeopleReads(TimewebAuthClient owner) async {
  final flights = owner._peopleFlights.values.toList();
  for (final flight in flights) {
    flight.abort(TimewebAuthError.staleSession);
  }
  await Future.wait(flights.map((flight) => flight.settled.future));
}

Future<Object> _startPeopleRead(
  TimewebAuthClient owner, {
  TimewebPeopleFilters? filters,
  TimewebPeopleCursor? cursor,
  String? targetUid,
}) {
  try {
    owner._checkEnabled(_peopleOperation);
    if (!owner.configuration.currentReadsEnabled ||
        !owner.configuration.runtimeWritesEnabled) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.disabled,
      );
    }
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    if (targetUid != null &&
        (!_currentIdentifier(targetUid) || targetUid == session.uid)) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.invalidRequest,
      );
    }
    final scope = targetUid == null
        ? 'directory:${filters!._scope}'
        : 'person:$targetUid';
    if (cursor != null) {
      if (!identical(cursor._owner, owner) || cursor._scope != scope) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.invalidRequest,
        );
      }
      cursor.requireCurrent();
    }
    final key = '${owner._epoch}\u0000$scope\u0000${cursor?._value ?? ''}';
    final existing = owner._peopleFlights[key];
    if (existing != null) {
      return existing.result.future;
    }
    if (owner._peopleFlights.length >= 4) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.unavailable,
      );
    }
    final flight = _PeopleFlight(
      owner,
      filters,
      cursor,
      targetUid,
      owner._epoch,
      session.uid,
      key,
    );
    owner._peopleFlights[key] = flight;
    unawaited(_executePeopleRead(flight));
    return flight.result.future;
  } catch (error) {
    return Future.error(error);
  }
}

Future<void> _executePeopleRead(_PeopleFlight flight) async {
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
    var reply = await _peopleAttempt(flight, session.accessToken);
    flight.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken) {
        await owner.refresh();
      }
      flight.check();
      session = owner._session!;
      reply = await _peopleAttempt(flight, session.accessToken);
      flight.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(flight.epoch);
      }
      if (reply.status == 404 && flight.targetUid != null) {
        throw const TimewebPersonNotFound();
      }
      throw owner._statusError(_peopleOperation, reply.status);
    }
    final value = _decodePeopleRead(flight, reply.body!);
    flight.check();
    if (!flight.result.isCompleted) {
      flight.result.complete(value);
    }
  } catch (error) {
    if (!flight.result.isCompleted) {
      try {
        flight.check();
        flight.result.completeError(
          error is TimewebAuthException || error is TimewebPersonNotFound
              ? error
              : const TimewebAuthException(
                  _peopleOperation,
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
    if (identical(owner._peopleFlights[flight.key], flight)) {
      owner._peopleFlights.remove(flight.key);
    }
    flight.settled.complete();
  }
}

Future<_Reply> _peopleAttempt(_PeopleFlight flight, String bearer) async {
  final owner = flight.owner;
  flight.check();
  if (owner._inflightRequests >= 4) {
    throw const TimewebAuthException(
      _peopleOperation,
      TimewebAuthError.unavailable,
    );
  }
  final abort = Completer<void>();
  final request =
      http.AbortableRequest(
          'GET',
          flight.targetUid != null
              ? owner.configuration.endpoint.replace(
                  pathSegments: ['v1', 'runtime', 'people', flight.targetUid!],
                )
              : owner.configuration.endpoint.replace(
                  path: '/v1/runtime/people',
                  queryParameters: {
                    ...flight.filters!._query,
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
      _peopleInvalid();
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
      _peopleInvalid();
    }
    final bytes = <int>[];
    while (await moving) {
      flight.check();
      final chunk = reader.current;
      if (bytes.length + chunk.length > 65536) {
        _peopleInvalid();
      }
      bytes.addAll(chunk);
      moving = reader.moveNext();
    }
    flight.check();
    if (response.contentLength != null &&
        response.contentLength != bytes.length) {
      _peopleInvalid();
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      _peopleInvalid();
    }
    return _Reply(200, decoded);
  } on FormatException {
    _peopleInvalid();
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

const _personKeys = {
  'uid',
  'fullName',
  'age',
  'pol',
  'country',
  'countryCode',
  'region',
  'city',
  'primaryGroup',
  'secondaryGroup',
  'lastOnlineAt',
  'avatar',
  'mediaReady',
};
TimewebPublicPerson _decodePublicPerson(
  _PeopleFlight flight,
  Object? value, {
  required bool details,
}) {
  if (value is! Map<String, dynamic> ||
      !_mutationExact(value, {
        ..._personKeys,
        if (details) ...{'rost', 'about', 'hobbi', 'deti', 'relationStatus'},
      }) ||
      !_currentIdentifier(value['uid']) ||
      value['uid'] == flight.uid ||
      details && value['uid'] != flight.targetUid ||
      value['avatar'] != null ||
      value['mediaReady'] != false ||
      !_currentNullableStamp(value['lastOnlineAt'])) {
    _peopleInvalid();
  }
  for (final key in [
    'fullName',
    'pol',
    'country',
    'countryCode',
    'region',
    'city',
    'primaryGroup',
    'secondaryGroup',
    if (details) ...['about', 'hobbi', 'relationStatus'],
  ]) {
    if (!_currentNullableText(value[key], switch (key) {
      'fullName' => 1000,
      'about' || 'hobbi' => 4096,
      _ => 191,
    })) {
      _peopleInvalid();
    }
  }
  for (final key in ['age', if (details) 'rost']) {
    final number = value[key];
    if (number != null &&
        (number is! int || number < 0 || number > (key == 'age' ? 130 : 300))) {
      _peopleInvalid();
    }
  }
  if (details && value['deti'] != null && value['deti'] is! bool) {
    _peopleInvalid();
  }
  return TimewebPublicPerson._(
    Map.unmodifiable(value),
    flight.checkSession,
    details,
  );
}

Object _decodePeopleRead(_PeopleFlight flight, Map<String, dynamic> body) {
  if (body['kind'] != 'canonical-current' || body['mediaReady'] != false) {
    _peopleInvalid();
  }
  if (flight.targetUid != null) {
    if (!_mutationExact(body, {'kind', 'profile', 'mediaReady'})) {
      _peopleInvalid();
    }
    return _decodePublicPerson(flight, body['profile'], details: true);
  }
  final filters = flight.filters!;
  if (!_mutationExact(body, {
        'kind',
        'ordering',
        'items',
        'nextCursor',
        'mediaReady',
      }) ||
      body['ordering'] != 'last_online_at_desc_uid_binary_asc_null_last' ||
      body['items'] is! List ||
      (body['items'] as List).length > filters.limit) {
    _peopleInvalid();
  }
  final rows = <TimewebPublicPerson>[];
  final seen = <String>{};
  TimewebPublicPerson? previous;
  for (final value in body['items'] as List) {
    final person = _decodePublicPerson(flight, value, details: false);
    if (!seen.add(person.uid) ||
        person.age == null ||
        person.age! < filters.minAge ||
        person.age! > filters.maxAge ||
        filters.pol != null && person.pol != filters.pol ||
        filters.region != null && person.region != filters.region) {
      _peopleInvalid();
    }
    if (previous != null) {
      final before = previous.lastOnlineAt, after = person.lastOnlineAt;
      if (before == null && after != null ||
          before != null && after != null && before.compareTo(after) < 0 ||
          before == after &&
              _currentCompareIds(previous.uid, person.uid) >= 0) {
        _peopleInvalid();
      }
    }
    rows.add(person);
    previous = person;
  }
  final next = body['nextCursor'];
  if (next != null &&
      (!_validReadCursor(next is String ? next : '') ||
          next == flight.cursor?._value)) {
    _peopleInvalid();
  }
  return TimewebPeoplePage._(
    List.unmodifiable(rows),
    next == null
        ? null
        : TimewebPeopleCursor._(
            next,
            flight.owner,
            'directory:${filters._scope}',
            flight.checkSession,
            flight.startedAt.add(const Duration(seconds: 300)),
          ),
    flight.checkSession,
  );
}

Never _peopleInvalid() => throw const TimewebAuthException(
  _peopleOperation,
  TimewebAuthError.invalidResponse,
);
