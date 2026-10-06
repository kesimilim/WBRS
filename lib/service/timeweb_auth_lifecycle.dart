import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebLifecyclePurpose { passwordReset, registerEmail }

enum TimewebLifecycleStage { request, complete }

enum TimewebLifecycleState { accepted, completed, refused, rejected, unknown }

enum TimewebLifecycleError {
  disabled,
  invalidRequest,
  unavailable,
  network,
  deadline,
  invalidResponse,
  rateLimited,
  staleScope,
  closed,
}

/// No raw server answer, email, code, password or reconciliation token.
final class TimewebLifecycleException implements Exception {
  const TimewebLifecycleException(this.error);
  final TimewebLifecycleError error;
  @override
  String toString() => 'TimewebLifecycleException(${error.name})';
}

String _purpose(TimewebLifecyclePurpose purpose) => switch (purpose) {
  TimewebLifecyclePurpose.passwordReset => 'password-reset.v1',
  TimewebLifecyclePurpose.registerEmail => 'register-email.v1',
};
bool _uuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(value);
bool _token(String value) =>
    value.isNotEmpty &&
    value.length <= 768 &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
bool _utf8Exact(String value) => utf8.decode(utf8.encode(value)) == value;
bool _email(String value) {
  final canonical = value.trim().toLowerCase();
  return value.runes.isNotEmpty &&
      value.runes.length <= 320 &&
      utf8.encode(value).length <= 1280 &&
      _utf8Exact(value) &&
      RegExp(
        r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$",
      ).hasMatch(canonical) &&
      !canonical.contains('..') &&
      canonical.split('@').last.length <= 253;
}

/// A screen scope also captures the optional Timeweb AppSession epoch. A -> B
/// -> A, logout, stop and navigation invalidate retained results immediately.
final class TimewebLifecycleScope {
  TimewebLifecycleScope._(this._owner, this._epoch, this._sessionEpoch);
  final TimewebAuthLifecycleClient _owner;
  final int _epoch;
  final int? _sessionEpoch;
  bool get isCurrent => _owner._current(this);
  void requireCurrent() {
    if (!isCurrent) {
      throw const TimewebLifecycleException(TimewebLifecycleError.staleScope);
    }
  }

  @override
  String toString() => 'TimewebLifecycleScope(<redacted>)';
}

/// Original operation and exact POST body live only in this client's memory.
/// Submit is permanently deduplicated; timeout never authorizes another POST.
/// Explicit lookup uses a sealed token or the original-body READ-only route.
final class TimewebLifecycleOperation {
  TimewebLifecycleOperation._(
    this._scope,
    this.purpose,
    this.stage,
    this._body,
  );
  final TimewebLifecycleScope _scope;
  final TimewebLifecyclePurpose purpose;
  final TimewebLifecycleStage stage;
  Map<String, String>? _body;
  String? _operationToken;
  Future<TimewebLifecycleResult>? _submitted;
  Future<TimewebLifecycleResult>? _lookup;
  @override
  String toString() =>
      'TimewebLifecycleOperation(${purpose.name}, ${stage.name}, <redacted>)';
}

/// Not a session or login success. Completion must be followed by a separate
/// explicit sign-in; no access/refresh credentials are accepted or stored here.
final class TimewebLifecycleResult {
  TimewebLifecycleResult._(
    this._operation,
    this._state,
    this._error,
    this._challengeId,
  );
  final TimewebLifecycleOperation _operation;
  final TimewebLifecycleState _state;
  final TimewebLifecycleError? _error;
  final String? _challengeId;
  TimewebLifecycleState get state {
    _operation._scope.requireCurrent();
    return _state;
  }

  TimewebLifecycleError? get error {
    _operation._scope.requireCurrent();
    return _error;
  }

  String? get challengeId {
    _operation._scope.requireCurrent();
    return _challengeId;
  }

  bool get canLookup => state == TimewebLifecycleState.unknown;
  @override
  String toString() => 'TimewebLifecycleResult(${_state.name}, <redacted>)';
}

final class _Flight {
  _Flight(this.owner, this.operation, this.lookup) {
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    timer = Timer(
      owner.requestDeadline,
      () => abort(TimewebLifecycleError.deadline),
    );
  }
  final TimewebAuthLifecycleClient owner;
  final TimewebLifecycleOperation operation;
  final bool lookup;
  final result = Completer<TimewebLifecycleResult>();
  final abortSignal = Completer<void>();
  final settled = Completer<void>();
  late final Timer timer;
  StreamIterator<List<int>>? reader;
  Future<void>? _cancellation;
  TimewebLifecycleError? reason;
  Future<void> cancelReader() =>
      _cancellation ??= reader?.cancel() ?? Future<void>.value();
  void check() {
    operation._scope.requireCurrent();
    if (reason != null) throw TimewebLifecycleException(reason!);
  }

  void abort(TimewebLifecycleError error) {
    reason ??= error;
    timer.cancel();
    if (!abortSignal.isCompleted) abortSignal.complete();
    if (reader != null) unawaited(cancelReader().catchError((Object _) {}));
    if (!result.isCompleted) {
      if (error == TimewebLifecycleError.staleScope ||
          error == TimewebLifecycleError.closed) {
        result.completeError(TimewebLifecycleException(error));
      } else {
        result.complete(
          TimewebLifecycleResult._(
            operation,
            TimewebLifecycleState.unknown,
            error,
            null,
          ),
        );
      }
    }
  }
}

/// Prepared, default-off transport. No UI, backend default, Firebase auth,
/// password/token persistence, automatic retries, SMTP or account hydration.
/// The injected transport must honor AbortableRequest for physical cancellation;
/// ignored cancellation retains one of four slots until actual cleanup settles.
final class TimewebAuthLifecycleClient {
  TimewebAuthLifecycleClient({
    required this.configuration,
    this.enabled = false,
    http.Client? transport,
    AppSession? session,
    this.requestDeadline = const Duration(seconds: 10),
  }) : _http = transport ?? http.Client(),
       _ownsTransport = transport == null,
       _session = session {
    if (requestDeadline <= Duration.zero ||
        requestDeadline > const Duration(seconds: 20) ||
        (session != null && session.backend != AppSessionBackend.timeweb)) {
      throw ArgumentError('Invalid lifecycle client configuration.');
    }
    _sessionEpoch = session?.state.epoch;
    _subscription = session?.states.listen((state) {
      if (state.epoch != _sessionEpoch) {
        _sessionEpoch = state.epoch;
        _invalidate();
      }
    }, onError: (Object _) => _invalidate());
  }
  final TimewebAuthConfiguration configuration;
  final bool enabled;
  final Duration requestDeadline;
  final http.Client _http;
  final bool _ownsTransport;
  final AppSession? _session;
  StreamSubscription<AppSessionState>? _subscription;
  int? _sessionEpoch;
  int _epoch = 0;
  bool _closed = false;
  final _operations = <String, TimewebLifecycleOperation>{};
  final _flights = <_Flight>{};
  Future<bool>? _closing;

  bool _current(TimewebLifecycleScope scope) {
    if (_closed || !identical(scope._owner, this) || scope._epoch != _epoch) {
      return false;
    }
    try {
      final state = _session?.state;
      return scope._sessionEpoch == state?.epoch &&
          state?.phase != AppSessionPhase.closed &&
          state?.phase != AppSessionPhase.stopped;
    } catch (_) {
      return false;
    }
  }

  void _checkEnabled() {
    if (_closed) {
      throw const TimewebLifecycleException(TimewebLifecycleError.closed);
    }
    if (!enabled || !configuration.enabled) {
      throw const TimewebLifecycleException(TimewebLifecycleError.disabled);
    }
  }

  void _invalidate() {
    _epoch++;
    for (final flight in _flights.toList()) {
      flight.abort(TimewebLifecycleError.staleScope);
    }
    for (final operation in _operations.values) {
      operation._body = null;
      operation._operationToken = null;
    }
    _operations.clear();
  }

  TimewebLifecycleScope beginScope() {
    _checkEnabled();
    _invalidate();
    _sessionEpoch = _session?.state.epoch;
    return TimewebLifecycleScope._(this, _epoch, _sessionEpoch);
  }

  TimewebLifecycleOperation request({
    required TimewebLifecycleScope scope,
    required TimewebLifecyclePurpose purpose,
    required String operationId,
    required String email,
  }) {
    if (!_email(email)) {
      throw const TimewebLifecycleException(
        TimewebLifecycleError.invalidRequest,
      );
    }
    return _bind(scope, purpose, TimewebLifecycleStage.request, {
      'email': email,
      'operationId': operationId,
    });
  }

  TimewebLifecycleOperation complete({
    required TimewebLifecycleScope scope,
    required TimewebLifecyclePurpose purpose,
    required String operationId,
    required String challengeId,
    required String code,
    required String password,
  }) {
    if (!_uuid(challengeId) ||
        !RegExp(r'^[0-9]{6}$').hasMatch(code) ||
        password.runes.length < 6 ||
        utf8.encode(password).length > 4096 ||
        !_utf8Exact(password)) {
      throw const TimewebLifecycleException(
        TimewebLifecycleError.invalidRequest,
      );
    }
    return _bind(scope, purpose, TimewebLifecycleStage.complete, {
      'challengeId': challengeId,
      'code': code,
      'password': password,
      'operationId': operationId,
    });
  }

  TimewebLifecycleOperation _bind(
    TimewebLifecycleScope scope,
    TimewebLifecyclePurpose purpose,
    TimewebLifecycleStage stage,
    Map<String, String> body,
  ) {
    _checkEnabled();
    scope.requireCurrent();
    if (!identical(scope._owner, this) ||
        !_uuid(body['operationId']!) ||
        utf8
                .encode(
                  jsonEncode({
                    'purpose': _purpose(purpose),
                    'stage': stage.name,
                    'original': body,
                  }),
                )
                .length >
            8192) {
      throw const TimewebLifecycleException(
        TimewebLifecycleError.invalidRequest,
      );
    }
    final key = body['operationId']!;
    final old = _operations[key];
    if (old != null) {
      if (old.purpose != purpose ||
          old.stage != stage ||
          jsonEncode(old._body) != jsonEncode(body)) {
        throw const TimewebLifecycleException(
          TimewebLifecycleError.invalidRequest,
        );
      }
      return old;
    }
    if (_operations.length >= 16) {
      throw const TimewebLifecycleException(TimewebLifecycleError.unavailable);
    }
    return _operations[key] = TimewebLifecycleOperation._(
      scope,
      purpose,
      stage,
      Map.unmodifiable(body),
    );
  }

  void _checkOperation(TimewebLifecycleOperation operation) {
    _checkEnabled();
    operation._scope.requireCurrent();
    if (!identical(operation._scope._owner, this) ||
        operation._body == null ||
        !identical(_operations[operation._body!['operationId']], operation)) {
      throw const TimewebLifecycleException(
        TimewebLifecycleError.invalidRequest,
      );
    }
  }

  Future<TimewebLifecycleResult> submit(TimewebLifecycleOperation operation) {
    _checkOperation(operation);
    return operation._submitted ??= _start(operation, lookup: false);
  }

  Future<TimewebLifecycleResult> lookup(TimewebLifecycleOperation operation) {
    _checkOperation(operation);
    if (operation._submitted == null) {
      throw const TimewebLifecycleException(
        TimewebLifecycleError.invalidRequest,
      );
    }
    return operation._lookup ??= _start(operation, lookup: true);
  }

  Future<TimewebLifecycleResult> _start(
    TimewebLifecycleOperation operation, {
    required bool lookup,
  }) {
    if (_flights.length >= 4) {
      throw const TimewebLifecycleException(TimewebLifecycleError.unavailable);
    }
    final flight = _Flight(this, operation, lookup);
    _flights.add(flight);
    unawaited(_transfer(flight));
    return flight.result.future;
  }

  Future<void> _transfer(_Flight flight) async {
    try {
      final operation = flight.operation;
      final body = flight.lookup
          ? operation._operationToken != null
                ? <String, Object>{'operationToken': operation._operationToken!}
                : <String, Object>{
                    'purpose': _purpose(operation.purpose),
                    'stage': operation.stage.name,
                    'original': operation._body!,
                  }
          : operation._body!;
      final path = flight.lookup
          ? '/v1/auth/operations/lookup'
          : '/v1/auth/${operation.purpose == TimewebLifecyclePurpose.passwordReset ? 'password-reset' : 'register-email'}/${operation.stage.name}';
      final request =
          http.AbortableRequest(
              'POST',
              configuration.endpoint.resolve(path),
              abortTrigger: flight.abortSignal.future,
            )
            ..followRedirects = false
            ..headers['Accept'] = 'application/json'
            ..headers['Cache-Control'] = 'no-store'
            ..headers['Content-Type'] = 'application/json; charset=utf-8'
            ..body = jsonEncode(body);
      flight.check();
      final response = await _http.send(request);
      flight.reader = StreamIterator(response.stream);
      // StreamIterator subscribes lazily. Start it before checking a canceled
      // owner so even a late response has a real subscription to cancel.
      var next = flight.reader!.moveNext();
      unawaited(next.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      flight.check();
      final type = response.headers['content-type']
          ?.toLowerCase()
          .split(';')
          .first
          .trim();
      final cache = response.headers['cache-control']
          ?.toLowerCase()
          .split(',')
          .map((v) => v.trim());
      if (type != 'application/json' ||
          !(cache?.contains('no-store') ?? false) ||
          (response.contentLength != null && response.contentLength! > 16384)) {
        throw const TimewebLifecycleException(
          TimewebLifecycleError.invalidResponse,
        );
      }
      final bytes = <int>[];
      while (await next) {
        flight.check();
        final chunk = flight.reader!.current;
        if (bytes.length + chunk.length > 16384) {
          throw const TimewebLifecycleException(
            TimewebLifecycleError.invalidResponse,
          );
        }
        bytes.addAll(chunk);
        next = flight.reader!.moveNext();
      }
      flight.check();
      if (response.contentLength != null &&
          response.contentLength != bytes.length) {
        throw const TimewebLifecycleException(
          TimewebLifecycleError.invalidResponse,
        );
      }
      final parsed = _flatJson(utf8.decode(bytes));
      final result = _decode(
        operation,
        response.statusCode,
        parsed,
        lookup: flight.lookup,
      );
      flight.check();
      if (parsed['operationToken'] case final String token) {
        operation._operationToken = token;
      }
      if (!flight.result.isCompleted) flight.result.complete(result);
    } on TimewebLifecycleException catch (error) {
      flight.abort(error.error);
    } on FormatException {
      flight.abort(TimewebLifecycleError.invalidResponse);
    } catch (_) {
      flight.abort(TimewebLifecycleError.network);
    } finally {
      flight.timer.cancel();
      try {
        await flight.cancelReader();
      } catch (_) {
        /* No private transport error escapes. */
      }
      _flights.remove(flight);
      if (flight.lookup) flight.operation._lookup = null;
      if (!flight.settled.isCompleted) flight.settled.complete();
    }
  }

  TimewebLifecycleResult _decode(
    TimewebLifecycleOperation operation,
    int status,
    Map<String, String> body, {
    required bool lookup,
  }) {
    final token = body['operationToken'];
    if (token != null && !_token(token)) {
      throw const TimewebLifecycleException(
        TimewebLifecycleError.invalidResponse,
      );
    }
    bool keys(Set<String> expected) =>
        body.length == expected.length && body.keys.every(expected.contains);
    TimewebLifecycleResult result(
      TimewebLifecycleState state, [
      TimewebLifecycleError? error,
      String? id,
    ]) => TimewebLifecycleResult._(operation, state, error, id);
    if (status == 202 &&
        operation.stage == TimewebLifecycleStage.request &&
        keys({'status', 'challengeId', 'operationToken'}) &&
        body['status'] == 'accepted' &&
        _uuid(body['challengeId']!)) {
      return result(TimewebLifecycleState.accepted, null, body['challengeId']);
    }
    if (status == 200 &&
        operation.stage == TimewebLifecycleStage.complete &&
        keys({'status', 'operationToken'}) &&
        body['status'] == 'completed') {
      return result(TimewebLifecycleState.completed);
    }
    if (status == 400 &&
        operation.stage == TimewebLifecycleStage.complete &&
        ((!lookup && keys({'status'})) || keys({'status', 'operationToken'})) &&
        body['status'] == 'refused') {
      return result(TimewebLifecycleState.refused);
    }
    if (status == 503 &&
        keys({'error', 'operationToken'}) &&
        body['error'] == 'outcome_unknown') {
      return result(
        TimewebLifecycleState.unknown,
        TimewebLifecycleError.unavailable,
      );
    }
    final expected = switch (status) {
      400 => 'invalid_request',
      404 => 'not_found',
      405 => 'method_not_allowed',
      429 => 'rate_limited',
      503 => 'service_unavailable',
      _ => null,
    };
    if (expected != null && keys({'error'}) && body['error'] == expected) {
      return result(
        lookup || status == 503
            ? TimewebLifecycleState.unknown
            : TimewebLifecycleState.rejected,
        status == 429
            ? TimewebLifecycleError.rateLimited
            : status == 400
            ? TimewebLifecycleError.invalidRequest
            : TimewebLifecycleError.unavailable,
      );
    }
    throw const TimewebLifecycleException(
      TimewebLifecycleError.invalidResponse,
    );
  }

  /// Cancel runtime ownership and erase in-memory originals. This never calls
  /// session logout, Firebase signOut or protected token-store clear. False
  /// means an injected transport has not confirmed physical cleanup in time.
  Future<bool> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _invalidate();
    if (_ownsTransport) _http.close();
    final settled = _flights.map((flight) => flight.settled.future).toList();
    return _closing = () async {
      await _subscription?.cancel();
      try {
        await Future.wait(settled).timeout(requestDeadline);
        return true;
      } catch (_) {
        return false;
      }
    }();
  }
}

/// The wire has at most three string fields. Reject duplicate keys and nested
/// values instead of jsonDecode silently accepting a duplicate status/token.
Map<String, String> _flatJson(String raw) {
  final literal = RegExp(
    r'"(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"',
  );
  var index = 0;
  void space() {
    while (index < raw.length && ' \t\r\n'.contains(raw[index])) {
      index++;
    }
  }

  Never invalid() => throw const TimewebLifecycleException(
    TimewebLifecycleError.invalidResponse,
  );
  String string() {
    space();
    final match = literal.matchAsPrefix(raw, index);
    if (match == null) invalid();
    index = match.end;
    final value = jsonDecode(match.group(0)!);
    if (value is! String || !_utf8Exact(value)) invalid();
    return value;
  }

  space();
  if (index >= raw.length || raw[index++] != '{') invalid();
  final values = <String, String>{};
  while (true) {
    final key = string();
    space();
    if (index >= raw.length || raw[index++] != ':' || values.containsKey(key)) {
      invalid();
    }
    values[key] = string();
    space();
    if (values.length > 3 || index >= raw.length) invalid();
    final separator = raw[index++];
    if (separator == '}') break;
    if (separator != ',') invalid();
  }
  space();
  if (index != raw.length) invalid();
  return values;
}
