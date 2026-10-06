part of 'timeweb_auth_client.dart';

/// The current account's editor only: no caller UID, URL or raw query.
final class TimewebProfileEditorRequest {
  const TimewebProfileEditorRequest.own();
  @override
  String toString() => 'TimewebProfileEditorRequest(<redacted>)';
}

enum TimewebEditableProfileField {
  fullName,
  age,
  rost,
  about,
  hobbi,
  deti,
  pol,
  relationStatus,
}

/// Current editor data and its CAS stamp. This is not a full profile, an
/// onboarding decision, registration creation or a financial/admin capability.
final class TimewebProfileEditorSnapshot {
  TimewebProfileEditorSnapshot._(this._uid, this._profile, this._check);
  final String _uid;
  final TimewebEditableProfile? _profile;
  final void Function() _check;
  void requireCurrent() => _check();
  String get uid {
    _check();
    return _uid;
  }

  bool get profileExists {
    _check();
    return _profile != null;
  }

  TimewebEditableProfile? get profile {
    _check();
    return _profile;
  }

  String get profileAuthority {
    _check();
    return 'canonical-current-v1';
  }

  List<TimewebEditableProfileField> get editableFields {
    _check();
    return List.unmodifiable(TimewebEditableProfileField.values);
  }

  @override
  String toString() => 'TimewebProfileEditorSnapshot(<redacted>)';
}

/// Nullable source values remain nullable. No map/JSON/session hydration API.
final class TimewebEditableProfile {
  TimewebEditableProfile._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  T _read<T>(String key) {
    _check();
    return _data[key] as T;
  }

  String? get fullName => _read<String?>('fullName');
  int? get age => _read<int?>('age');
  int? get rost => _read<int?>('rost');
  String? get about => _read<String?>('about');
  String? get hobbi => _read<String?>('hobbi');
  bool? get deti => _read<bool?>('deti');
  String? get pol => _read<String?>('pol');
  String? get relationStatus => _read<String?>('relationStatus');
  bool? get profileDetailsSaved => _read<bool?>('profileDetailsSaved');
  bool? get isRegistrationEnd => _read<bool?>('isRegistrationEnd');
  String get updatedAt => _read<String>('updatedAt');
  @override
  String toString() => 'TimewebEditableProfile(<redacted>)';
}

const _profileEditorOperation = TimewebAuthOperation.profile;

final class _ProfileEditorFlight {
  _ProfileEditorFlight(this.owner, this.epoch, this.uid) {
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
  final result = Completer<TimewebProfileEditorSnapshot>();
  final settled = Completer<void>();
  final elapsed = Stopwatch()..start();
  final aborts = <Completer<void>>{};
  final cancellations = <Future<void> Function()>{};
  late final Timer timer;
  TimewebAuthError? reason;
  void checkSession() {
    owner._checkEpoch(epoch, _profileEditorOperation);
    if (owner._secureStoreUnsafe || owner._session?.uid != uid) {
      throw const TimewebAuthException(
        _profileEditorOperation,
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
      throw TimewebAuthException(_profileEditorOperation, reason!);
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
        TimewebAuthException(_profileEditorOperation, reason!),
      );
    }
  }
}

/// Cancels immediately; completion represents actual transport cleanup. Lifecycle
/// stop may await this without losing a successful protected auth rotation.
Future<void> _cancelProfileEditorRead(TimewebAuthClient owner) {
  final flights = owner._profileEditorFlights.values.toList();
  for (final flight in flights) {
    flight.abort(TimewebAuthError.staleSession);
  }
  return Future.wait([for (final flight in flights) flight.settled.future]);
}

Future<TimewebProfileEditorSnapshot> _readProfileForEdit(
  TimewebAuthClient owner,
  TimewebProfileEditorRequest request,
) {
  try {
    owner._checkEnabled(_profileEditorOperation);
    if (!owner.configuration.runtimeWritesEnabled) {
      throw const TimewebAuthException(
        _profileEditorOperation,
        TimewebAuthError.disabled,
      );
    }
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) {
      throw const TimewebAuthException(
        _profileEditorOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    final existing = owner._profileEditorFlights[owner._epoch];
    if (existing != null) return existing.result.future;
    // Abandoned transports keep their real slots until cleanup settles.
    if (owner._profileEditorFlights.length >= 4) {
      throw const TimewebAuthException(
        _profileEditorOperation,
        TimewebAuthError.unavailable,
      );
    }
    final flight = _ProfileEditorFlight(owner, owner._epoch, session.uid);
    owner._profileEditorFlights[flight.epoch] = flight;
    unawaited(_executeProfileEditor(flight));
    return flight.result.future;
  } on TimewebAuthException catch (error) {
    return Future.error(error);
  }
}

Future<void> _executeProfileEditor(_ProfileEditorFlight flight) async {
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
    var reply = await _profileEditorAttempt(flight, session.accessToken);
    flight.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken) {
        await owner.refresh();
      }
      flight.check();
      session = owner._session!;
      reply = await _profileEditorAttempt(flight, session.accessToken);
      flight.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(flight.epoch);
      }
      throw owner._statusError(_profileEditorOperation, reply.status);
    }
    final view = _decodeProfileEditor(flight, reply.body!);
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
                  _profileEditorOperation,
                  TimewebAuthError.network,
                ),
        );
      } on TimewebAuthException catch (stale) {
        if (!flight.result.isCompleted) flight.result.completeError(stale);
      }
    }
  } finally {
    flight.timer.cancel();
    if (identical(owner._profileEditorFlights[flight.epoch], flight)) {
      owner._profileEditorFlights.remove(flight.epoch);
    }
    flight.settled.complete();
  }
}

/// Uses the client's approved origin, bearer, shared refresh and HTTP budget.
/// A small route-specific runner keeps frozen read/mutation DTOs unchanged.
Future<_Reply> _profileEditorAttempt(
  _ProfileEditorFlight flight,
  String bearer,
) async {
  final owner = flight.owner;
  flight.check();
  if (owner._inflightRequests >= 4) {
    throw const TimewebAuthException(
      _profileEditorOperation,
      TimewebAuthError.unavailable,
    );
  }
  final abort = Completer<void>();
  final request =
      http.AbortableRequest(
          'GET',
          owner.configuration.endpoint.replace(path: '/v1/runtime/me/profile'),
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
      _profileEditorInvalid();
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
      _profileEditorInvalid();
    }
    final bytes = <int>[];
    while (await moving) {
      flight.check();
      final chunk = reader.current;
      if (bytes.length + chunk.length > 65536) _profileEditorInvalid();
      bytes.addAll(chunk);
      moving = reader.moveNext();
    }
    flight.check();
    if (response.contentLength != null &&
        response.contentLength != bytes.length) {
      _profileEditorInvalid();
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) _profileEditorInvalid();
    return _Reply(200, decoded);
  } on FormatException {
    _profileEditorInvalid();
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

TimewebProfileEditorSnapshot _decodeProfileEditor(
  _ProfileEditorFlight flight,
  Map<String, dynamic> body,
) {
  if (!_mutationExact(body, {
        'uid',
        'profile',
        'profileExists',
        'profileAuthority',
        'editableFields',
      }) ||
      body['uid'] != flight.uid ||
      body['profileAuthority'] != 'canonical-current-v1' ||
      body['profileExists'] is! bool ||
      body['profileExists'] != (body['profile'] != null)) {
    _profileEditorInvalid();
  }
  final editable = body['editableFields'];
  final names = TimewebEditableProfileField.values
      .map((field) => field.name)
      .toSet();
  if (editable is! List ||
      editable.length != names.length ||
      editable.any((v) => v is! String) ||
      editable.toSet().length != names.length ||
      !editable.toSet().containsAll(names)) {
    _profileEditorInvalid();
  }
  final profile = body['profile'];
  TimewebEditableProfile? view;
  if (profile != null) {
    if (profile is! Map<String, dynamic> || !_mutationProfile(profile)) {
      _profileEditorInvalid();
    }
    // Source limits differ from new-edit validation. In particular, historical
    // age 0 and short/empty descriptions must not be reinterpreted or trimmed.
    for (final key in ['fullName', 'about', 'hobbi', 'pol', 'relationStatus']) {
      if (!_currentNullableText(
        profile[key],
        key == 'pol' || key == 'relationStatus' ? 191 : 4096,
      )) {
        _profileEditorInvalid();
      }
    }
    if (profile['age'] != null &&
            (profile['age'] < 0 || profile['age'] > 130) ||
        profile['rost'] != null &&
            (profile['rost'] < 0 || profile['rost'] > 300)) {
      _profileEditorInvalid();
    }
    view = TimewebEditableProfile._(
      Map.unmodifiable(profile),
      flight.checkSession,
    );
  }
  return TimewebProfileEditorSnapshot._(flight.uid, view, flight.checkSession);
}

Never _profileEditorInvalid() => throw const TimewebAuthException(
  _profileEditorOperation,
  TimewebAuthError.invalidResponse,
);
