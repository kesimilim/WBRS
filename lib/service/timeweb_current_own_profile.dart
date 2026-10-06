part of 'timeweb_auth_client.dart';

/// Current canonical account fields only. Every getter revokes after logout,
/// owner replacement or A/B login; this is never legacy global hydration data.
final class TimewebCurrentOwnProfile {
  TimewebCurrentOwnProfile._(
    this._uid,
    this._profile,
    this._onboarding,
    this._check,
  );
  final String _uid;
  final TimewebCurrentProfile? _profile;
  final TimewebOnboarding _onboarding;
  final void Function() _check;

  /// Add a facade owner lease to this snapshot and every nested getter. The
  /// original client guard is always retained, so this cannot loosen access.
  TimewebCurrentOwnProfile bindSessionGuard(void Function() requireSession) {
    void check() {
      _check();
      requireSession();
    }

    check();
    final profile = _profile;
    return TimewebCurrentOwnProfile._(
      _uid,
      profile == null ? null : TimewebCurrentProfile._(profile._values, check),
      _onboarding,
      check,
    );
  }

  void requireCurrent() => _check();
  String get uid {
    _check();
    return _uid;
  }

  bool get profileExists {
    _check();
    return _profile != null;
  }

  TimewebCurrentProfile? get profile {
    _check();
    return _profile;
  }

  TimewebOnboarding get onboarding {
    _check();
    return _onboarding;
  }

  String get profileAuthority {
    _check();
    return 'canonical-current-v1';
  }

  bool get mediaReady {
    _check();
    return false;
  }

  @override
  String toString() => 'TimewebCurrentOwnProfile(<redacted>)';
}

final class TimewebCurrentProfile {
  TimewebCurrentProfile._(this._values, this._check);
  final Map<String, dynamic> _values;
  final void Function() _check;
  void requireCurrent() => _check();
  T _read<T>(String field) {
    _check();
    return _values[field] as T;
  }

  String? get fullName => _read<String?>('fullName');
  int? get age => _read<int?>('age');
  int? get rost => _read<int?>('rost');
  String? get about => _read<String?>('about');
  String? get hobbi => _read<String?>('hobbi');
  bool? get deti => _read<bool?>('deti');
  String? get pol => _read<String?>('pol');
  String? get relationStatus => _read<String?>('relationStatus');
  String? get country => _read<String?>('country');
  String? get countryCode => _read<String?>('countryCode');
  String? get region => _read<String?>('region');
  String? get city => _read<String?>('city');
  String? get languageCode => _read<String?>('languageCode');
  String? get primaryGroup => _read<String?>('primaryGroup');
  String? get secondaryGroup => _read<String?>('secondaryGroup');
  bool? get profileDetailsSaved => _read<bool?>('profileDetailsSaved');
  bool? get isRegistrationEnd => _read<bool?>('isRegistrationEnd');
  String get updatedAt => _read<String>('updatedAt');
  @override
  String toString() => 'TimewebCurrentProfile(<redacted>)';
}

const _currentOwnProfileOperation = TimewebAuthOperation.profile;

final class _CurrentOwnProfileFlight {
  _CurrentOwnProfileFlight(this.owner, this.epoch, this.uid) {
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    timer = Timer(
      owner.requestDeadline,
      () => abort(TimewebAuthError.deadline),
    );
  }
  final TimewebAuthClient owner;
  final int epoch;
  final String uid;
  final result = Completer<TimewebCurrentOwnProfile>();
  final settled = Completer<void>();
  final elapsed = Stopwatch()..start();
  final aborts = <Completer<void>>{};
  final cancellations = <Future<void> Function()>{};
  late final Timer timer;
  TimewebAuthError? reason;
  void checkSession() {
    owner._checkEpoch(epoch, _currentOwnProfileOperation);
    if (owner._secureStoreUnsafe || owner._session?.uid != uid) {
      throw const TimewebAuthException(
        _currentOwnProfileOperation,
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
      throw TimewebAuthException(_currentOwnProfileOperation, reason!);
    }
  }

  void abort(TimewebAuthError error) {
    reason ??= error;
    timer.cancel();
    for (final signal in aborts.toList()) {
      if (!signal.isCompleted) signal.complete();
    }
    for (final cancel in cancellations.toList()) {
      unawaited(cancel().catchError((Object _) {}));
    }
    if (!result.isCompleted) {
      result.completeError(
        TimewebAuthException(_currentOwnProfileOperation, reason!),
      );
    }
  }
}

/// Cancels immediately; completion represents actual transport cleanup. Lifecycle
/// stop may await this without losing a successful protected auth rotation.
Future<void> _cancelCurrentOwnProfileRead(TimewebAuthClient owner) {
  final flights = owner._currentOwnProfileFlights.values.toList();
  for (final flight in flights) {
    flight.abort(TimewebAuthError.staleSession);
  }
  return Future.wait([for (final flight in flights) flight.settled.future]);
}

Future<TimewebCurrentOwnProfile> _readCurrentOwnProfile(
  TimewebAuthClient owner,
) {
  try {
    owner._checkEnabled(_currentOwnProfileOperation);
    if (!owner.configuration.runtimeWritesEnabled ||
        !owner.configuration.currentReadsEnabled) {
      throw const TimewebAuthException(
        _currentOwnProfileOperation,
        TimewebAuthError.disabled,
      );
    }
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) {
      throw const TimewebAuthException(
        _currentOwnProfileOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    final existing = owner._currentOwnProfileFlights[owner._epoch];
    if (existing != null) return existing.result.future;
    // Abandoned transports keep their real slots until cleanup settles.
    if (owner._currentOwnProfileFlights.length >= 4) {
      throw const TimewebAuthException(
        _currentOwnProfileOperation,
        TimewebAuthError.unavailable,
      );
    }
    final flight = _CurrentOwnProfileFlight(owner, owner._epoch, session.uid);
    owner._currentOwnProfileFlights[flight.epoch] = flight;
    unawaited(_executeCurrentOwnProfile(flight));
    return flight.result.future;
  } on TimewebAuthException catch (error) {
    return Future.error(error);
  }
}

Future<void> _executeCurrentOwnProfile(_CurrentOwnProfileFlight flight) async {
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
    var reply = await _currentOwnProfileAttempt(flight, session.accessToken);
    flight.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken) {
        await owner.refresh();
      }
      flight.check();
      session = owner._session!;
      reply = await _currentOwnProfileAttempt(flight, session.accessToken);
      flight.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(flight.epoch);
      }
      throw owner._statusError(_currentOwnProfileOperation, reply.status);
    }
    final view = _decodeCurrentOwnProfile(flight, reply.body!);
    flight.check();
    if (!flight.result.isCompleted) flight.result.complete(view);
  } catch (error) {
    if (!flight.result.isCompleted) {
      try {
        flight.check();
        flight.result.completeError(
          error is TimewebAuthException
              ? error
              : const TimewebAuthException(
                  _currentOwnProfileOperation,
                  TimewebAuthError.network,
                ),
        );
      } on TimewebAuthException catch (stale) {
        if (!flight.result.isCompleted) flight.result.completeError(stale);
      }
    }
  } finally {
    flight.timer.cancel();
    if (identical(owner._currentOwnProfileFlights[flight.epoch], flight)) {
      owner._currentOwnProfileFlights.remove(flight.epoch);
    }
    flight.settled.complete();
  }
}

/// Uses the client's approved origin, bearer, shared refresh and HTTP budget.
/// A small route-specific runner keeps frozen read/mutation DTOs unchanged.
Future<_Reply> _currentOwnProfileAttempt(
  _CurrentOwnProfileFlight flight,
  String bearer,
) async {
  final owner = flight.owner;
  flight.check();
  if (owner._inflightRequests >= 4) {
    throw const TimewebAuthException(
      _currentOwnProfileOperation,
      TimewebAuthError.unavailable,
    );
  }
  final abort = Completer<void>();
  final request =
      http.AbortableRequest(
          'GET',
          owner.configuration.endpoint.replace(
            path: '/v1/runtime/me/full-profile',
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
    if (current == null) return Future.value();
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
      _currentOwnProfileInvalid();
    }
    if (response.statusCode != 200) return _Reply(response.statusCode, null);
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
      _currentOwnProfileInvalid();
    }
    final bytes = <int>[];
    while (await moving) {
      flight.check();
      final chunk = reader.current;
      if (bytes.length + chunk.length > 65536) _currentOwnProfileInvalid();
      bytes.addAll(chunk);
      moving = reader.moveNext();
    }
    flight.check();
    if (response.contentLength != null &&
        response.contentLength != bytes.length) {
      _currentOwnProfileInvalid();
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) _currentOwnProfileInvalid();
    return _Reply(200, decoded);
  } on FormatException {
    _currentOwnProfileInvalid();
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

TimewebCurrentOwnProfile _decodeCurrentOwnProfile(
  _CurrentOwnProfileFlight flight,
  Map<String, dynamic> body,
) {
  if (!_mutationExact(body, {
        'uid',
        'profileExists',
        'profile',
        'onboarding',
        'profileAuthority',
        'mediaReady',
      }) ||
      body['uid'] != flight.uid ||
      body['profileExists'] is! bool ||
      body['profileExists'] != (body['profile'] != null) ||
      body['profileAuthority'] != 'canonical-current-v1' ||
      body['mediaReady'] != false) {
    _currentOwnProfileInvalid();
  }
  final raw = body['profile'];
  TimewebCurrentProfile? profile;
  var expectedStage = TimewebOnboarding.registration;
  if (raw != null) {
    if (raw is! Map<String, dynamic> ||
        !_mutationExact(raw, {
          'fullName',
          'age',
          'rost',
          'about',
          'hobbi',
          'deti',
          'pol',
          'relationStatus',
          'country',
          'countryCode',
          'region',
          'city',
          'languageCode',
          'primaryGroup',
          'secondaryGroup',
          'profileDetailsSaved',
          'isRegistrationEnd',
          'updatedAt',
        }) ||
        !_mutationStamp(raw['updatedAt'])) {
      _currentOwnProfileInvalid();
    }
    for (final key in [
      'fullName',
      'about',
      'hobbi',
      'pol',
      'relationStatus',
      'country',
      'countryCode',
      'region',
      'city',
      'languageCode',
      'primaryGroup',
      'secondaryGroup',
    ]) {
      final maximum = switch (key) {
        'fullName' => 1000,
        'about' || 'hobbi' => 4096,
        _ => 191,
      };
      if (!_currentNullableText(raw[key], maximum)) _currentOwnProfileInvalid();
    }
    for (final key in ['age', 'rost']) {
      final value = raw[key];
      if (value != null &&
          (value is! int || value < 0 || value > (key == 'age' ? 130 : 300))) {
        _currentOwnProfileInvalid();
      }
    }
    for (final key in ['deti', 'profileDetailsSaved', 'isRegistrationEnd']) {
      if (raw[key] != null && raw[key] is! bool) _currentOwnProfileInvalid();
    }
    bool filled(String key) =>
        raw[key] is String &&
        (key == 'fullName'
            ? (raw[key] as String).trim().isNotEmpty
            : (raw[key] as String).isNotEmpty);
    final primary = raw['primaryGroup'] as String?;
    if (raw['isRegistrationEnd'] == true ||
        primary != null &&
            _ownProfileGroups.contains(primary.trim().toLowerCase())) {
      expectedStage = TimewebOnboarding.search;
    } else if (raw['profileDetailsSaved'] == true ||
        filled('fullName') &&
            raw['age'] != null &&
            filled('pol') &&
            filled('about') &&
            filled('hobbi')) {
      expectedStage = TimewebOnboarding.test;
    }
    profile = TimewebCurrentProfile._(
      Map.unmodifiable(raw),
      flight.checkSession,
    );
  }
  if (body['onboarding'] != expectedStage.name) _currentOwnProfileInvalid();
  return TimewebCurrentOwnProfile._(
    flight.uid,
    profile,
    expectedStage,
    flight.checkSession,
  );
}

Never _currentOwnProfileInvalid() => throw const TimewebAuthException(
  _currentOwnProfileOperation,
  TimewebAuthError.invalidResponse,
);
