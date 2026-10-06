part of 'timeweb_auth_client.dart';

const _currentReadOperation = TimewebAuthOperation.currentRead;
const _currentReadMaximumBytes = 65536;

enum TimewebCurrentReadResource { chats, messages, events }

enum TimewebCurrentEventKind { messageCreated, readUpdated }

/// Exact current SQL routes only. Integer pagination values are minted from a
/// verified page, never supplied as a foreign account's bare checkpoint.
final class TimewebCurrentReadRequest {
  TimewebCurrentReadRequest._(
    this.resource,
    this.limit,
    this._chatId,
    this._cursor,
  ) {
    if (limit < 1 ||
        limit > 100 ||
        (resource == TimewebCurrentReadResource.messages &&
            !_mutationId(_chatId))) {
      throw ArgumentError('Invalid current read request.');
    }
  }
  factory TimewebCurrentReadRequest.chats({
    int limit = 50,
    TimewebCurrentReadCursor? cursor,
  }) => TimewebCurrentReadRequest._(
    TimewebCurrentReadResource.chats,
    limit,
    null,
    cursor,
  );
  factory TimewebCurrentReadRequest.messages(
    String chatId, {
    int limit = 50,
    TimewebCurrentReadCursor? before,
  }) => TimewebCurrentReadRequest._(
    TimewebCurrentReadResource.messages,
    limit,
    chatId,
    before,
  );
  factory TimewebCurrentReadRequest.events({
    int limit = 50,
    TimewebCurrentReadCursor? after,
  }) => TimewebCurrentReadRequest._(
    TimewebCurrentReadResource.events,
    limit,
    null,
    after,
  );
  final TimewebCurrentReadResource resource;
  final int limit;
  final String? _chatId;
  final TimewebCurrentReadCursor? _cursor;
  String get _scope => '${resource.name}\u0000${_chatId ?? ''}\u0000$limit';
  Uri _uri(Uri origin) => origin.replace(
    pathSegments: switch (resource) {
      TimewebCurrentReadResource.chats => ['v1', 'runtime', 'chats'],
      TimewebCurrentReadResource.messages => [
        'v1',
        'runtime',
        'chats',
        _chatId!,
        'messages',
      ],
      TimewebCurrentReadResource.events => ['v1', 'runtime', 'events'],
    },
    queryParameters: {
      'limit': '$limit',
      if (_cursor != null)
        switch (resource) {
          TimewebCurrentReadResource.chats => 'cursor',
          TimewebCurrentReadResource.messages => 'beforeSequence',
          TimewebCurrentReadResource.events => 'afterEventId',
        }: '${_cursor._value}',
    },
  );
  @override
  String toString() => 'TimewebCurrentReadRequest(<redacted>)';
}

final class TimewebCurrentReadCursor {
  TimewebCurrentReadCursor._(
    this._value,
    this._owner,
    this._scope,
    this._check,
  );
  final Object _value;
  final TimewebAuthClient _owner;
  final String _scope;
  final void Function() _check;
  void requireCurrent() => _check();
  @override
  String toString() => 'TimewebCurrentReadCursor(<redacted>)';
}

/// Whole records only; the server can return fewer than limit to respect its
/// 64KiB budget. Its continuation belongs to the last record actually emitted.
final class TimewebCurrentReadPage {
  TimewebCurrentReadPage._(
    this._resource,
    this._check, {
    List<TimewebCurrentChat>? chats,
    List<TimewebCurrentMessage>? messages,
    List<TimewebCurrentEvent>? events,
    TimewebCurrentReadCursor? cursor,
    TimewebCurrentReadCursor? eventCheckpoint,
    String? chatId,
    int? chatRevision,
  }) : _chats = chats,
       _messages = messages,
       _events = events,
       _cursor = cursor,
       _checkpoint = eventCheckpoint,
       _chatId = chatId,
       _chatRevision = chatRevision;
  final TimewebCurrentReadResource _resource;
  final void Function() _check;
  final List<TimewebCurrentChat>? _chats;
  final List<TimewebCurrentMessage>? _messages;
  final List<TimewebCurrentEvent>? _events;
  final TimewebCurrentReadCursor? _cursor;
  final TimewebCurrentReadCursor? _checkpoint;
  final String? _chatId;
  final int? _chatRevision;
  void requireCurrent() => _check();
  TimewebCurrentReadResource get resource {
    _check();
    return _resource;
  }

  List<TimewebCurrentChat> get chats {
    _check();
    if (_chats == null) _currentReadInvalid();
    return _chats;
  }

  List<TimewebCurrentMessage> get messages {
    _check();
    if (_messages == null) _currentReadInvalid();
    return _messages;
  }

  List<TimewebCurrentEvent> get events {
    _check();
    if (_events == null) _currentReadInvalid();
    return _events;
  }

  TimewebCurrentReadCursor? get nextCursor {
    _check();
    return _cursor;
  }

  /// Polling checkpoint can exist at EOF. It is an in-memory verified lease,
  /// not a caller-manufactured or cross-account persisted integer.
  TimewebCurrentReadCursor? get eventCheckpoint {
    _check();
    return _checkpoint;
  }

  String? get chatId {
    _check();
    return _chatId;
  }

  int? get chatRevision {
    _check();
    return _chatRevision;
  }

  @override
  String toString() => 'TimewebCurrentReadPage(<redacted>)';
}

final class TimewebCurrentChat {
  TimewebCurrentChat._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  String get chatId {
    _check();
    return _data['chatId'];
  }

  String get counterpartUid {
    _check();
    return _data['counterpartUid'];
  }

  String? get name {
    _check();
    return _data['name'];
  }

  String? get updatedAt {
    _check();
    return _data['updatedAt'];
  }

  int get lastSequence {
    _check();
    return _data['lastSequence'];
  }

  int get revision {
    _check();
    return _data['revision'];
  }

  int get readThrough {
    _check();
    return _data['readThrough'];
  }

  bool get archived {
    _check();
    return _data['archived'];
  }

  bool get notifications {
    _check();
    return _data['notifications'];
  }

  // Avatar hydration is a separate reviewed media capability, currently absent.
  TimewebPrivateMediaRequest? get avatar {
    _check();
    return null;
  }

  @override
  String toString() => 'TimewebCurrentChat(<redacted>)';
}

final class TimewebCurrentMessage {
  TimewebCurrentMessage._(this._data, this._check, this._quote);
  final Map<String, dynamic> _data;
  final void Function() _check;
  final TimewebQuotedMessage? _quote;
  void requireCurrent() => _check();
  String get chatId {
    _check();
    return _data['chatId'];
  }

  String get messageId {
    _check();
    return _data['messageId'];
  }

  int get sequence {
    _check();
    return _data['sequence'];
  }

  String get senderUid {
    _check();
    return _data['senderUid'];
  }

  String? get text {
    _check();
    return _data['text'];
  }

  String? get createdAt {
    _check();
    return _data['createdAt'];
  }

  TimewebQuotedMessage? get quote {
    _check();
    return _quote;
  }

  @override
  String toString() => 'TimewebCurrentMessage(<redacted>)';
}

final class TimewebCurrentEvent {
  TimewebCurrentEvent._(this._data, this._check, this._kind);
  final Map<String, dynamic> _data;
  final void Function() _check;
  final TimewebCurrentEventKind _kind;
  void requireCurrent() => _check();
  int get eventId {
    _check();
    return _data['eventId'];
  }

  TimewebCurrentEventKind get kind {
    _check();
    return _kind;
  }

  String get chatId {
    _check();
    return _data['chatId'];
  }

  String? get messageId {
    _check();
    return _data['messageId'];
  }

  int? get sequence {
    _check();
    return _data['sequence'];
  }

  String? get senderUid {
    _check();
    return _data['senderUid'];
  }

  String? get readerUid {
    _check();
    return _data['readerUid'];
  }

  int? get readThroughSequence {
    _check();
    return _data['readThroughSequence'];
  }

  int get chatRevision {
    _check();
    return _data['chatRevision'];
  }

  String get createdAt {
    _check();
    return _data['createdAt'];
  }

  @override
  String toString() => 'TimewebCurrentEvent(<redacted>)';
}

final class _CurrentReadFlight {
  _CurrentReadFlight(this.owner, this.request, this.epoch, this.uid, this.key) {
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    timer = Timer(
      owner.requestDeadline,
      () => abort(TimewebAuthError.deadline),
    );
  }
  final TimewebAuthClient owner;
  final TimewebCurrentReadRequest request;
  final int epoch;
  final String uid, key;
  final result = Completer<TimewebCurrentReadPage>();
  final elapsed = Stopwatch()..start();
  final aborts = <Completer<void>>{};
  final cancellations = <Future<void> Function()>{};
  late final Timer timer;
  TimewebAuthError? reason;
  void checkSession() {
    owner._checkEpoch(epoch, _currentReadOperation);
    if (owner._secureStoreUnsafe || owner._session?.uid != uid) {
      throw const TimewebAuthException(
        _currentReadOperation,
        TimewebAuthError.staleSession,
      );
    }
  }

  void check() {
    checkSession();
    if (reason == null && elapsed.elapsed >= owner.requestDeadline)
      abort(TimewebAuthError.deadline);
    if (reason != null)
      throw TimewebAuthException(_currentReadOperation, reason!);
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
    if (!result.isCompleted)
      result.completeError(
        TimewebAuthException(_currentReadOperation, reason!),
      );
  }
}

void _cancelCurrentReads(TimewebAuthClient owner) {
  for (final flight in owner._currentReadFlights.values.toList()) {
    flight.abort(TimewebAuthError.staleSession);
  }
}

Future<TimewebCurrentReadPage> _readCurrent(
  TimewebAuthClient owner,
  TimewebCurrentReadRequest request,
) {
  try {
    owner._checkEnabled(_currentReadOperation);
    if (!owner.configuration.currentReadsEnabled) {
      throw const TimewebAuthException(
        _currentReadOperation,
        TimewebAuthError.disabled,
      );
    }
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) {
      throw const TimewebAuthException(
        _currentReadOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    final cursor = request._cursor;
    if (cursor != null) {
      if (!identical(cursor._owner, owner) || cursor._scope != request._scope) {
        throw const TimewebAuthException(
          _currentReadOperation,
          TimewebAuthError.invalidRequest,
        );
      }
      cursor._check();
    }
    final key =
        '${owner._epoch}\u0000${request._scope}\u0000${cursor?._value ?? ''}';
    final existing = owner._currentReadFlights[key];
    if (existing != null) return existing.result.future;
    if (owner._currentReadFlights.length >= 4) {
      throw const TimewebAuthException(
        _currentReadOperation,
        TimewebAuthError.unavailable,
      );
    }
    final flight = _CurrentReadFlight(
      owner,
      request,
      owner._epoch,
      session.uid,
      key,
    );
    owner._currentReadFlights[key] = flight;
    unawaited(_executeCurrentRead(flight));
    return flight.result.future;
  } on TimewebAuthException catch (error) {
    return Future.error(error);
  }
}

Future<void> _executeCurrentRead(_CurrentReadFlight flight) async {
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
    var reply = await _currentReadAttempt(flight, session.accessToken);
    flight.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken)
        await owner.refresh();
      flight.check();
      session = owner._session!;
      reply = await _currentReadAttempt(flight, session.accessToken);
      flight.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken)
        await owner._invalidate(flight.epoch);
      throw owner._statusError(_currentReadOperation, reply.status);
    }
    final page = _decodeCurrentRead(flight, reply.body!);
    flight.check();
    if (!flight.result.isCompleted) flight.result.complete(page);
  } catch (error) {
    if (!flight.result.isCompleted) {
      try {
        flight.check();
        flight.result.completeError(
          error is TimewebAuthException
              ? error
              : const TimewebAuthException(
                  _currentReadOperation,
                  TimewebAuthError.network,
                ),
        );
      } on TimewebAuthException catch (stale) {
        if (!flight.result.isCompleted) flight.result.completeError(stale);
      }
    }
  } finally {
    flight.timer.cancel();
    if (identical(owner._currentReadFlights[flight.key], flight))
      owner._currentReadFlights.remove(flight.key);
  }
}

Future<_Reply> _currentReadAttempt(
  _CurrentReadFlight flight,
  String bearer,
) async {
  final owner = flight.owner;
  flight.check();
  if (owner._inflightRequests >= 4) {
    throw const TimewebAuthException(
      _currentReadOperation,
      TimewebAuthError.unavailable,
    );
  }
  final abort = Completer<void>();
  final request =
      http.AbortableRequest(
          'GET',
          flight.request._uri(owner.configuration.endpoint),
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
        response.statusCode >= 300 && response.statusCode < 400)
      _currentReadInvalid();
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
        (response.contentLength != null &&
            response.contentLength! > _currentReadMaximumBytes))
      _currentReadInvalid();
    final bytes = <int>[];
    while (await moving) {
      flight.check();
      final chunk = reader.current;
      if (bytes.length + chunk.length > _currentReadMaximumBytes)
        _currentReadInvalid();
      bytes.addAll(chunk);
      moving = reader.moveNext();
    }
    flight.check();
    if (response.contentLength != null &&
        response.contentLength != bytes.length)
      _currentReadInvalid();
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) _currentReadInvalid();
    return _Reply(200, decoded);
  } on FormatException {
    _currentReadInvalid();
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

TimewebCurrentReadPage _decodeCurrentRead(
  _CurrentReadFlight flight,
  Map<String, dynamic> body,
) {
  final request = flight.request, check = flight.checkSession;
  if (body['kind'] != 'canonical-current' ||
      body['items'] is! List ||
      (body['items'] as List).length > request.limit)
    _currentReadInvalid();
  final items = body['items'] as List;
  TimewebCurrentReadCursor cursor(Object value) =>
      TimewebCurrentReadCursor._(value, flight.owner, request._scope, check);
  if (request.resource == TimewebCurrentReadResource.chats) {
    if (!_mutationExact(body, {'kind', 'ordering', 'items', 'nextCursor'}) ||
        body['ordering'] != 'updated_at_desc_chat_id_asc_null_last')
      _currentReadInvalid();
    final rows = <TimewebCurrentChat>[];
    final seen = <String>{};
    Map<String, dynamic>? previous;
    for (final value in items) {
      if (value is! Map<String, dynamic> ||
          !_mutationExact(value, {
            'chatId',
            'counterpartUid',
            'name',
            'avatar',
            'updatedAt',
            'lastSequence',
            'revision',
            'readThrough',
            'archived',
            'notifications',
          }) ||
          !_currentIdentifier(value['chatId']) ||
          !_currentIdentifier(value['counterpartUid']) ||
          value['counterpartUid'] == flight.uid ||
          !_currentNullableText(value['name'], 1000) ||
          value['avatar'] != null ||
          !_currentNullableStamp(value['updatedAt']) ||
          !_mutationInteger(value['lastSequence']) ||
          !_mutationInteger(value['revision']) ||
          !_mutationInteger(value['readThrough']) ||
          value['readThrough'] > value['lastSequence'] ||
          value['archived'] is! bool ||
          value['notifications'] is! bool ||
          !seen.add(value['chatId']))
        _currentReadInvalid();
      if (previous != null) {
        final before = previous['updatedAt'] as String?,
            after = value['updatedAt'] as String?;
        if ((before == null && after != null) ||
            (before != null && after != null && before.compareTo(after) < 0) ||
            (before == after &&
                _currentCompareIds(previous['chatId'], value['chatId']) >= 0))
          _currentReadInvalid();
      }
      rows.add(TimewebCurrentChat._(Map.unmodifiable(value), check));
      previous = value;
    }
    final next = body['nextCursor'];
    if (next != null &&
        (!_validReadCursor(next is String ? next : '') ||
            items.isEmpty ||
            next == request._cursor?._value))
      _currentReadInvalid();
    return TimewebCurrentReadPage._(
      request.resource,
      check,
      chats: List.unmodifiable(rows),
      cursor: next == null ? null : cursor(next),
    );
  }
  if (request.resource == TimewebCurrentReadResource.messages) {
    if (!_mutationExact(body, {
          'kind',
          'chatId',
          'chatRevision',
          'ordering',
          'items',
          'nextBeforeSequence',
        }) ||
        body['chatId'] != request._chatId ||
        !_mutationInteger(body['chatRevision']) ||
        body['ordering'] != 'sequence_desc')
      _currentReadInvalid();
    final rows = <TimewebCurrentMessage>[];
    final seen = <String>{};
    int? previous = request._cursor?._value as int?;
    for (final value in items) {
      if (value is! Map<String, dynamic> ||
          !_mutationExact(value, {
            'chatId',
            'messageId',
            'sequence',
            'senderUid',
            'text',
            'quote',
            'createdAt',
          }) ||
          value['chatId'] != request._chatId ||
          !_currentIdentifier(value['messageId']) ||
          !_mutationInteger(value['sequence'], positive: true) ||
          !_currentIdentifier(value['senderUid']) ||
          !_currentNullableText(value['text'], 4096) ||
          !_currentNullableStamp(value['createdAt']) ||
          !seen.add(value['messageId']) ||
          (previous != null && value['sequence'] >= previous))
        _currentReadInvalid();
      final quote = value['quote'];
      TimewebQuotedMessage? quoteView;
      if (quote != null) {
        if (quote is! Map<String, dynamic> ||
            !_mutationExact(quote, {
              'messageId',
              'sequence',
              'senderUid',
              'text',
            }) ||
            !_currentIdentifier(quote['messageId']) ||
            !_mutationInteger(quote['sequence'], positive: true) ||
            !_currentIdentifier(quote['senderUid']) ||
            !_currentNullableText(quote['text'], 4096))
          _currentReadInvalid();
        quoteView = TimewebQuotedMessage._(Map.unmodifiable(quote), check);
      }
      rows.add(
        TimewebCurrentMessage._(Map.unmodifiable(value), check, quoteView),
      );
      previous = value['sequence'];
    }
    final next = body['nextBeforeSequence'];
    if (next != null &&
        (!_mutationInteger(next, positive: true) ||
            items.isEmpty ||
            next != previous))
      _currentReadInvalid();
    return TimewebCurrentReadPage._(
      request.resource,
      check,
      messages: List.unmodifiable(rows),
      cursor: next == null ? null : cursor(next),
      chatId: request._chatId,
      chatRevision: body['chatRevision'],
    );
  }
  if (!_mutationExact(body, {
        'kind',
        'ordering',
        'items',
        'nextAfterEventId',
      }) ||
      body['ordering'] != 'event_id_asc')
    _currentReadInvalid();
  final rows = <TimewebCurrentEvent>[];
  var previous = request._cursor?._value as int? ?? 0;
  for (final value in items) {
    if (value is! Map<String, dynamic> ||
        !_mutationExact(value, {
          'eventId',
          'kind',
          'chatId',
          'messageId',
          'sequence',
          'senderUid',
          'readerUid',
          'readThroughSequence',
          'chatRevision',
          'createdAt',
        }) ||
        !_mutationInteger(value['eventId'], positive: true) ||
        value['eventId'] <= previous ||
        !_currentIdentifier(value['chatId']) ||
        !_mutationInteger(value['chatRevision']) ||
        !_mutationStamp(value['createdAt']))
      _currentReadInvalid();
    TimewebCurrentEventKind kind;
    if (value['kind'] == 'chat.message.created.v1') {
      if (!_currentIdentifier(value['messageId']) ||
          !_mutationInteger(value['sequence'], positive: true) ||
          !_currentIdentifier(value['senderUid']) ||
          value['readerUid'] != null ||
          value['readThroughSequence'] != null)
        _currentReadInvalid();
      kind = TimewebCurrentEventKind.messageCreated;
    } else if (value['kind'] == 'chat.read.updated.v1') {
      if (value['messageId'] != null ||
          value['sequence'] != null ||
          value['senderUid'] != null ||
          !_currentIdentifier(value['readerUid']) ||
          !_mutationInteger(value['readThroughSequence']))
        _currentReadInvalid();
      kind = TimewebCurrentEventKind.readUpdated;
    } else {
      _currentReadInvalid();
    }
    rows.add(TimewebCurrentEvent._(Map.unmodifiable(value), check, kind));
    previous = value['eventId'];
  }
  final next = body['nextAfterEventId'];
  if (next != null &&
      (!_mutationInteger(next, positive: true) ||
          items.isEmpty ||
          next != previous))
    _currentReadInvalid();
  return TimewebCurrentReadPage._(
    request.resource,
    check,
    events: List.unmodifiable(rows),
    cursor: next == null ? null : cursor(next),
    eventCheckpoint: items.isEmpty ? request._cursor : cursor(previous),
  );
}

Never _currentReadInvalid() => throw const TimewebAuthException(
  _currentReadOperation,
  TimewebAuthError.invalidResponse,
);
bool _currentNullableStamp(Object? value) =>
    value == null || _mutationStamp(value);
bool _currentIdentifier(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.runes.length <= 191 &&
    utf8.encode(value).length <= 764 &&
    utf8.decode(utf8.encode(value)) == value &&
    !value.runes.any((r) => r < 32 || r == 127);
bool _currentNullableText(Object? value, int maximum) =>
    value == null ||
    value is String &&
        value.runes.length <= maximum &&
        utf8.encode(value).length <= maximum * 4 &&
        utf8.decode(utf8.encode(value)) == value &&
        !value.runes.any(
          (r) => (r < 32 && !const [9, 10, 13].contains(r)) || r == 127,
        );
int _currentCompareIds(String a, String b) {
  final left = utf8.encode(a), right = utf8.encode(b);
  for (var i = 0; i < left.length && i < right.length; i++) {
    if (left[i] != right[i]) return left[i].compareTo(right[i]);
  }
  return left.length.compareTo(right.length);
}
