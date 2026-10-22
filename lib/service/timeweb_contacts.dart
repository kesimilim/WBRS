part of 'timeweb_auth_client.dart';

final class TimewebContactAction {
  TimewebContactAction({
    required String kind,
    required String targetUid,
    required int expectedRevision,
  }) : this.fromPayload({
         'kind': kind,
         'targetUid': targetUid,
         'expectedRevision': expectedRevision,
       });
  TimewebContactAction.fromPayload(Map<String, dynamic> value) {
    if (!_mutationExact(value, {'kind', 'targetUid', 'expectedRevision'}) ||
        !const {
          'send',
          'accept',
          'decline',
          'cancel',
          'remove',
          'visit',
        }.contains(value['kind']) ||
        !_notificationResource(value['targetUid']) ||
        !_mutationInteger(value['expectedRevision']) ||
        value['expectedRevision'] >= _mutationMax63 ||
        value['kind'] == 'visit' && value['expectedRevision'] != 0) {
      throw ArgumentError('Invalid contact action.');
    }
    payload = Map.unmodifiable(value);
  }
  late final Map<String, dynamic> payload;
  String get kind => payload['kind'];
  String get targetUid => payload['targetUid'];
  @override
  String toString() => 'TimewebContactAction(<redacted>)';
}

bool _contactRelationship(Map<String, dynamic> data) =>
    _mutationExact(data, {'kind', 'targetUid', 'status', 'revision'}) &&
    data['kind'] == 'native-relationship' &&
    _notificationResource(data['targetUid']) &&
    const {
      'none',
      'incoming',
      'outgoing',
      'friends',
    }.contains(data['status']) &&
    _mutationInteger(data['revision']);

final class TimewebContactReceipt {
  TimewebContactReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  String get targetUid {
    _check();
    return _data['targetUid'];
  }

  String get status {
    _check();
    return _data['status'] ?? 'guest';
  }

  int get revision {
    _check();
    return _data['revision'] ?? 0;
  }

  TimewebContactReceipt bindSessionGuard(void Function() guard) =>
      TimewebContactReceipt._(_data, () {
        _check();
        guard();
      });
  @override
  String toString() => 'TimewebContactReceipt(<redacted>)';
}

TimewebMutationResult _decodeContactReceipt(
  TimewebMutationReference ref,
  _Reply reply,
  Map<String, dynamic> result,
  bool replayed,
  int? revision,
) {
  final action = ref._request._payload;
  if (reply.status == 404) {
    if (!_mutationExact(result, {'error'}) ||
        result['error'] != 'contact_unavailable' ||
        revision != null) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      404,
      failure: TimewebMutationFailure.personUnavailable,
      replayed: replayed,
      receiptConfirmed: true,
    );
  }
  if (reply.status == 409) {
    if (!_mutationExact(result, {'error'}) ||
        result['error'] != 'relationship_changed' ||
        revision == null)
      _mutationInvalidReply();
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      409,
      failure: TimewebMutationFailure.relationshipChanged,
      revision: revision,
      replayed: replayed,
      receiptConfirmed: true,
    );
  }
  final visit = action['kind'] == 'visit';
  final expected = const {
    'send': 'outgoing',
    'accept': 'friends',
    'decline': 'none',
    'cancel': 'none',
    'remove': 'none',
  }[action['kind']];
  if (reply.status != 200 ||
      result['targetUid'] != action['targetUid'] ||
      (visit
          ? !_mutationExact(result, {'kind', 'targetUid', 'recorded'}) ||
                result['kind'] != 'native-visit' ||
                result['recorded'] is! bool ||
                revision != null
          : !_contactRelationship(result) ||
                result['status'] != expected ||
                result['revision'] != action['expectedRevision'] + 1 ||
                revision != result['revision'])) {
    _mutationInvalidReply();
  }
  return TimewebMutationResult._(
    ref,
    TimewebMutationState.confirmed,
    200,
    revision: revision,
    replayed: replayed,
    receiptConfirmed: true,
    contact: TimewebContactReceipt._(
      Map.unmodifiable(result),
      ref.requireCurrent,
    ),
  );
}

final class TimewebContactItem {
  TimewebContactItem._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  String get uid {
    _check();
    return _data['uid'];
  }

  String get fullName {
    _check();
    return _data['fullName'] ?? '';
  }

  String? get group {
    _check();
    return _data['primaryGroup'];
  }

  String? get city {
    _check();
    return _data['city'];
  }

  String? get updatedAt {
    _check();
    return _data['updatedAt'];
  }

  String get status {
    _check();
    return _data['status'];
  }

  int get revision {
    _check();
    return _data['revision'];
  }
}

final class TimewebContactsPage {
  TimewebContactsPage._(this._items, this._cursor, this._kind, this._check);
  final List<TimewebContactItem> _items;
  final String? _cursor;
  final String _kind;
  final void Function() _check;
  void requireCurrent() => _check();
  List<TimewebContactItem> get items {
    _check();
    return _items;
  }

  bool get hasMore {
    _check();
    return _cursor != null;
  }

  TimewebContactsPage bindSessionGuard(void Function() guard) {
    void check() {
      _check();
      guard();
    }

    return TimewebContactsPage._(
      List.unmodifiable(
        _items.map((v) => TimewebContactItem._(v._data, check)),
      ),
      _cursor,
      _kind,
      check,
    );
  }
}

extension TimewebContactReads on TimewebAuthClient {
  Future<TimewebContactsPage> readContacts(
    String kind, {
    TimewebContactsPage? after,
  }) => _contactRead(
    this,
    kind: kind,
    after: after,
  ).then((v) => v as TimewebContactsPage);
  Future<TimewebContactReceipt> readRelationship(String uid) =>
      _contactRead(this, target: uid).then((v) => v as TimewebContactReceipt);
}

Future<Object> _contactRead(
  TimewebAuthClient owner, {
  String? kind,
  String? target,
  TimewebContactsPage? after,
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
    if (target != null
        ? !_notificationResource(target)
        : !const {'friends', 'incoming', 'outgoing', 'guests'}.contains(kind)) {
      throw ArgumentError('Invalid contacts request.');
    }
    after?.requireCurrent();
    if (after != null && (after._kind != kind || !after.hasMore))
      throw ArgumentError('Invalid contacts cursor.');
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe)
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.notAuthenticated,
      );
    final key =
        '${owner._epoch}\u0000contacts\u0000$kind\u0000$target\u0000${after?._cursor}';
    final previous = owner._peopleFlights[key];
    if (previous != null) return previous.result.future;
    if (owner._peopleFlights.length >= 4)
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.unavailable,
      );
    final f = _PeopleFlight(
      owner,
      null,
      null,
      null,
      owner._epoch,
      session.uid,
      key,
    );
    owner._peopleFlights[key] = f;
    unawaited(_executeContactRead(f, kind, target, after?._cursor));
    return f.result.future;
  } catch (e) {
    return Future.error(e);
  }
}

Future<void> _executeContactRead(
  _PeopleFlight f,
  String? kind,
  String? target,
  String? cursor,
) async {
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
      pathSegments: [
        'v1',
        'runtime',
        'contacts',
        if (target != null) ...['people', target],
      ],
      queryParameters: target == null
          ? {'kind': kind!, 'limit': '20', if (cursor != null) 'cursor': cursor}
          : null,
    );
    var reply = await _meetingAttempt(f, uri, session.accessToken);
    f.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken)
        await owner.refresh();
      f.check();
      session = owner._session!;
      reply = await _meetingAttempt(f, uri, session.accessToken);
      f.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken)
        await owner._invalidate(f.epoch);
      throw owner._statusError(_peopleOperation, reply.status);
    }
    final data = reply.body;
    if (data == null) _mutationInvalidReply();
    Object result;
    if (target != null) {
      if (!_contactRelationship(data) || data['targetUid'] != target)
        _mutationInvalidReply();
      result = TimewebContactReceipt._(Map.unmodifiable(data), f.checkSession);
    } else {
      if (!_mutationExact(data, {'kind', 'list', 'items', 'nextCursor'}) ||
          data['kind'] != 'native-contacts' ||
          data['list'] != kind ||
          data['items'] is! List ||
          (data['items'] as List).length > 20 ||
          data['nextCursor'] != null &&
              (data['nextCursor'] is! String ||
                  (data['nextCursor'] as String).isEmpty ||
                  (data['nextCursor'] as String).length > 2048))
        _mutationInvalidReply();
      final items = <TimewebContactItem>[];
      final seen = <String>{};
      for (final raw in data['items']) {
        if (raw is! Map<String, dynamic> ||
            !_mutationExact(raw, {
              'uid',
              'fullName',
              'primaryGroup',
              'city',
              'age',
              'status',
              'revision',
              'updatedAt',
            }) ||
            !_notificationResource(raw['uid']) ||
            raw['uid'] == f.uid ||
            !seen.add(raw['uid']) ||
            raw['status'] != (kind == 'guests' ? 'guest' : kind) ||
            !_mutationInteger(raw['revision']) ||
            !_notificationStamp(raw['updatedAt']) ||
            raw['age'] != null &&
                (raw['age'] is! int || raw['age'] < 0 || raw['age'] > 130))
          _mutationInvalidReply();
        for (final field in ['fullName', 'primaryGroup', 'city']) {
          if (raw[field] != null &&
              !_mutationText(
                raw[field],
                maximum: field == 'fullName' ? 1000 : 191,
                multiline: false,
              ))
            _mutationInvalidReply();
        }
        items.add(TimewebContactItem._(Map.unmodifiable(raw), f.checkSession));
      }
      result = TimewebContactsPage._(
        List.unmodifiable(items),
        data['nextCursor'],
        kind!,
        f.checkSession,
      );
    }
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
    if (identical(owner._peopleFlights[f.key], f))
      owner._peopleFlights.remove(f.key);
    f.settled.complete();
  }
}
