part of 'timeweb_auth_client.dart';

final class TimewebPreferenceChanges {
  TimewebPreferenceChanges({
    required int expectedRevision,
    required bool messages,
    required bool meetings,
    required bool sound,
  }) : this.fromPayload({
         'expectedRevision': expectedRevision,
         'messages': messages,
         'meetings': meetings,
         'sound': sound,
       });
  TimewebPreferenceChanges.fromPayload(Map<String, dynamic> value) {
    if (!_mutationExact(value, {
          'expectedRevision',
          'messages',
          'meetings',
          'sound',
        }) ||
        !_mutationInteger(value['expectedRevision']) ||
        value['expectedRevision'] >= _mutationMax63 ||
        value['messages'] is! bool ||
        value['meetings'] is! bool ||
        value['sound'] is! bool) {
      throw ArgumentError('Invalid current preferences.');
    }
    payload = Map<String, dynamic>.unmodifiable(value);
  }
  late final Map<String, dynamic> payload;
  int get expectedRevision => payload['expectedRevision'];
  bool get messages => payload['messages'];
  bool get meetings => payload['meetings'];
  bool get sound => payload['sound'];
  @override
  String toString() => 'TimewebPreferenceChanges(<redacted>)';
}

bool _preferencesValid(Map<String, dynamic> data) =>
    _mutationExact(data, {
      'kind',
      'messages',
      'meetings',
      'sound',
      'revision',
      'updatedAt',
    }) &&
    data['kind'] == 'native-preferences' &&
    data['messages'] is bool &&
    data['meetings'] is bool &&
    data['sound'] is bool &&
    _mutationInteger(data['revision']) &&
    (data['revision'] == 0
        ? data['updatedAt'] == null
        : _mutationStamp(data['updatedAt']));

final class TimewebPreferences {
  TimewebPreferences._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  bool get messages {
    _check();
    return _data['messages'];
  }

  bool get meetings {
    _check();
    return _data['meetings'];
  }

  bool get sound {
    _check();
    return _data['sound'];
  }

  int get revision {
    _check();
    return _data['revision'];
  }

  String? get updatedAt {
    _check();
    return _data['updatedAt'];
  }

  TimewebPreferences bindSessionGuard(void Function() guard) =>
      TimewebPreferences._(_data, () {
        _check();
        guard();
      });
  @override
  String toString() => 'TimewebPreferences(<redacted>)';
}

TimewebMutationResult _decodePreferencesReceipt(
  TimewebMutationReference ref,
  _Reply reply,
  Map<String, dynamic> result,
  bool replayed,
  int? revision,
) {
  if (reply.status == 409) {
    if (!_mutationExact(result, {'error'}) ||
        result['error'] != 'preferences_changed' ||
        revision == null ||
        revision == ref._request._payload['expectedRevision']) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      409,
      failure: TimewebMutationFailure.preferencesChanged,
      revision: revision,
      replayed: replayed,
      receiptConfirmed: true,
    );
  }
  final p = ref._request._payload;
  if (reply.status != 200 ||
      !_preferencesValid(result) ||
      result['revision'] != p['expectedRevision'] + 1 ||
      revision != result['revision'] ||
      result['messages'] != p['messages'] ||
      result['meetings'] != p['meetings'] ||
      result['sound'] != p['sound']) {
    _mutationInvalidReply();
  }
  return TimewebMutationResult._(
    ref,
    TimewebMutationState.confirmed,
    200,
    revision: revision,
    replayed: replayed,
    receiptConfirmed: true,
    preferences: TimewebPreferences._(
      Map<String, dynamic>.unmodifiable(result),
      ref.requireCurrent,
    ),
  );
}

extension TimewebPreferenceReads on TimewebAuthClient {
  Future<TimewebPreferences> readPreferences() {
    try {
      _checkEnabled(_peopleOperation);
      if (!configuration.currentReadsEnabled ||
          !configuration.runtimeWritesEnabled) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.disabled,
        );
      }
      final session = _session;
      if (session == null || _secureStoreUnsafe) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.notAuthenticated,
        );
      }
      final key = '$_epoch\u0000preferences';
      final previous = _peopleFlights[key];
      if (previous != null) {
        return previous.result.future.then((v) => v as TimewebPreferences);
      }
      if (_peopleFlights.length >= 4) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.unavailable,
        );
      }
      final flight = _PeopleFlight(
        this,
        null,
        null,
        null,
        _epoch,
        session.uid,
        key,
      );
      _peopleFlights[key] = flight;
      unawaited(_executePreferencesRead(flight));
      return flight.result.future.then((v) => v as TimewebPreferences);
    } catch (error) {
      return Future.error(error);
    }
  }
}

Future<void> _executePreferencesRead(_PeopleFlight f) async {
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
    final uri = owner.configuration.endpoint.replace(
      pathSegments: ['v1', 'runtime', 'me', 'preferences'],
    );
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
      throw owner._statusError(_peopleOperation, reply.status);
    }
    if (reply.body == null || !_preferencesValid(reply.body!)) {
      _mutationInvalidReply();
    }
    final result = TimewebPreferences._(
      Map<String, dynamic>.unmodifiable(reply.body!),
      f.checkSession,
    );
    f.check();
    if (!f.result.isCompleted) f.result.complete(result);
  } catch (error) {
    if (!f.result.isCompleted) {
      try {
        f.check();
        f.result.completeError(
          error is TimewebAuthException
              ? error
              : const TimewebAuthException(
                  _peopleOperation,
                  TimewebAuthError.invalidResponse,
                ),
        );
      } catch (stale) {
        if (!f.result.isCompleted) f.result.completeError(stale);
      }
    }
  } finally {
    f.timer.cancel();
    if (identical(owner._peopleFlights[f.key], f)) {
      owner._peopleFlights.remove(f.key);
    }
    f.settled.complete();
  }
}
