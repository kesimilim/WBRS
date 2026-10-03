part of 'timeweb_auth_client.dart';

/// Healthy current owner, unavailable notification or target. Never logs out.
final class TimewebNotificationUnavailable implements Exception {
  const TimewebNotificationUnavailable();
  @override
  String toString() => 'Native notification is unavailable.';
}

bool _notificationId(Object? v) {
  if (v is! String || v.length < 3) return false;
  if (v.startsWith('e:')) {
    final suffix = v.substring(2);
    return RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(suffix) &&
        int.tryParse(suffix) != null &&
        int.parse(suffix) <= _mutationMax63;
  }
  return v.startsWith('n:') && _notificationResource(v.substring(2));
}

bool _notificationResource(Object? v) =>
    _currentIdentifier(v) &&
    v != '.' &&
    v != '..' &&
    !(v as String).contains('/');
bool _notificationStamp(Object? v) =>
    v == null ||
    v is String &&
        RegExp(
          r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$',
        ).hasMatch(v) &&
        _mutationStamp(v) &&
        int.parse(v.substring(0, 4)) >= 1000;

final class TimewebNotification {
  TimewebNotification._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  T _get<T>(String k) {
    _check();
    return _data[k] as T;
  }

  String get id => _get('id');
  String get type => _get('type');
  String? get targetKind => _get('targetKind');
  String? get targetId => _get('targetId');
  String? get createdAt => _get('createdAt');
  bool? get read => _get('read');
  TimewebNotification bindSessionGuard(void Function() guard) =>
      TimewebNotification._(_data, () {
        _check();
        guard();
      });
  @override
  String toString() => 'TimewebNotification(<redacted>)';
}

final class TimewebNotificationCursor {
  TimewebNotificationCursor._(
    this._value,
    this._owner,
    this._limit,
    this._expiry,
    this._check,
  );
  final String _value;
  final TimewebAuthClient _owner;
  final int _limit;
  final DateTime _expiry;
  final void Function() _check;
  void requireCurrent() {
    _check();
    if (!_owner._clock().isBefore(_expiry)) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.invalidRequest,
      );
    }
  }

  @override
  String toString() => 'TimewebNotificationCursor(<redacted>)';
}

final class TimewebNotificationPage {
  TimewebNotificationPage._(this._items, this._cursor, this._check);
  final List<TimewebNotification> _items;
  final TimewebNotificationCursor? _cursor;
  final void Function() _check;
  void requireCurrent() => _check();
  List<TimewebNotification> get items {
    _check();
    return _items;
  }

  TimewebNotificationCursor? get nextCursor {
    _check();
    return _cursor;
  }

  TimewebNotificationPage bindSessionGuard(void Function() guard) {
    void check() {
      _check();
      guard();
    }

    final cursor = _cursor;
    return TimewebNotificationPage._(
      List.unmodifiable(_items.map((v) => v.bindSessionGuard(guard))),
      cursor == null
          ? null
          : TimewebNotificationCursor._(
              cursor._value,
              cursor._owner,
              cursor._limit,
              cursor._expiry,
              () {
                cursor.requireCurrent();
                guard();
              },
            ),
      check,
    );
  }

  @override
  String toString() => 'TimewebNotificationPage(<redacted>)';
}

TimewebNotification _decodeNotification(Object? value, void Function() check) {
  if (value is! Map<String, dynamic> ||
      !_mutationExact(value, {
        'id',
        'type',
        'targetKind',
        'targetId',
        'createdAt',
        'read',
      }) ||
      !_notificationId(value['id']) ||
      !_notificationResource(value['type']) ||
      !(value['targetKind'] == null
          ? value['targetId'] == null
          : const ['chat', 'meeting', 'post'].contains(value['targetKind']) &&
                _notificationResource(value['targetId'])) ||
      !_notificationStamp(value['createdAt']) ||
      value['read'] != null && value['read'] is! bool) {
    _peopleInvalid();
  }
  return TimewebNotification._(Map<String, dynamic>.unmodifiable(value), check);
}

extension TimewebNotificationReads on TimewebAuthClient {
  Future<TimewebNotificationPage> readNotifications({
    int limit = 30,
    TimewebNotificationCursor? cursor,
  }) => _notificationRead(
    this,
    limit,
    cursor,
    null,
  ).then((v) => v as TimewebNotificationPage);
  Future<TimewebNotification> readNotification(String id) => _notificationRead(
    this,
    30,
    null,
    id,
  ).then((v) => v as TimewebNotification);
}

Future<Object> _notificationRead(
  TimewebAuthClient owner,
  int limit,
  TimewebNotificationCursor? cursor,
  String? id,
) {
  try {
    owner._checkEnabled(_peopleOperation);
    if (!owner.configuration.currentReadsEnabled ||
        !owner.configuration.runtimeWritesEnabled) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.disabled,
      );
    }
    if (limit < 1 || limit > 30 || id != null && !_notificationId(id)) {
      throw ArgumentError('Invalid notification request.');
    }
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    if (cursor != null) {
      cursor.requireCurrent();
      if (!identical(cursor._owner, owner) || cursor._limit != limit) {
        throw ArgumentError('Foreign notification cursor.');
      }
    }
    final key =
        '${owner._epoch}\u0000notifications\u0000$limit\u0000${cursor?._value ?? ''}\u0000${id ?? ''}';
    final previous = owner._peopleFlights[key];
    if (previous != null) return previous.result.future;
    if (owner._peopleFlights.length >= 4) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.unavailable,
      );
    }
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
    unawaited(_executeNotificationRead(f, limit, cursor, id));
    return f.result.future;
  } catch (e) {
    return Future.error(e);
  }
}

Future<void> _executeNotificationRead(
  _PeopleFlight f,
  int limit,
  TimewebNotificationCursor? cursor,
  String? id,
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
        'me',
        'notifications',
        if (id != null) id,
      ],
      queryParameters: id != null
          ? null
          : {'limit': '$limit', if (cursor != null) 'cursor': cursor._value},
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
    if (reply.status == 404) throw const TimewebNotificationUnavailable();
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(f.epoch);
      }
      throw owner._statusError(_peopleOperation, reply.status);
    }
    Object result;
    if (id != null) {
      final item = _decodeNotification(reply.body, f.checkSession);
      if (item.id != id || item.targetKind == null) _peopleInvalid();
      result = item;
    } else {
      final data = reply.body;
      if (data == null ||
          !_mutationExact(data, {'kind', 'items', 'nextCursor'}) ||
          data['kind'] != 'native-notifications' ||
          data['items'] is! List ||
          (data['items'] as List).length > (limit < 3 ? limit : 3) ||
          data['nextCursor'] != null &&
              (data['nextCursor'] is! String ||
                  !_validReadCursor(data['nextCursor']))) {
        _peopleInvalid();
      }
      final items = <TimewebNotification>[], seen = <String>{};
      for (final value in data['items']) {
        final item = _decodeNotification(value, f.checkSession);
        if (!seen.add(item.id)) _peopleInvalid();
        items.add(item);
      }
      final opaque = data['nextCursor'] as String?;
      if (opaque != null && opaque == cursor?._value) _peopleInvalid();
      result = TimewebNotificationPage._(
        List.unmodifiable(items),
        opaque == null
            ? null
            : TimewebNotificationCursor._(
                opaque,
                owner,
                limit,
                cursor?._expiry ??
                    f.startedAt.add(const Duration(seconds: 300)),
                f.checkSession,
              ),
        f.checkSession,
      );
    }
    f.check();
    if (!f.result.isCompleted) f.result.complete(result);
  } catch (e) {
    if (!f.result.isCompleted) {
      try {
        f.check();
        f.result.completeError(
          e is TimewebAuthException || e is TimewebNotificationUnavailable
              ? e
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
