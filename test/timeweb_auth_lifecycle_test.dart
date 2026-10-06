import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_auth_lifecycle.dart';

const _id = '00000000-0000-4000-8000-000000000001';
const _challenge = '00000000-0000-4000-8000-000000000009';
String _operationId(int index) =>
    '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
const _email = '  Mixed.Case@example.invalid  ';
const _password = '  six spaces  ';
const _token = 'Opaque_sealed-digest_123';
Matcher _error(TimewebLifecycleError error) => isA<TimewebLifecycleException>()
    .having((value) => value.error, 'safe error', error);

class _Wire extends http.BaseClient {
  _Wire(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handler(request);
  }
}

http.StreamedResponse _reply(
  Object value, {
  int status = 200,
  Stream<List<int>>? stream,
}) => http.StreamedResponse(
  stream ??
      Stream.value(utf8.encode(value is String ? value : jsonEncode(value))),
  status,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'private, no-store',
  },
);
Map<String, dynamic> _body(http.BaseRequest request) =>
    jsonDecode((request as http.Request).body);
TimewebAuthLifecycleClient _client(
  _Wire wire, {
  bool enabled = true,
  Duration deadline = const Duration(seconds: 1),
  AppSession? session,
}) => TimewebAuthLifecycleClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
  ),
  enabled: enabled,
  transport: wire,
  requestDeadline: deadline,
  session: session,
);
TimewebLifecycleOperation _request(
  TimewebAuthLifecycleClient client,
  TimewebLifecycleScope scope, {
  String id = _id,
  TimewebLifecyclePurpose purpose = TimewebLifecyclePurpose.passwordReset,
}) => client.request(
  scope: scope,
  purpose: purpose,
  operationId: id,
  email: _email,
);
Future<void> _pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _SessionAdapter implements AppSessionAdapter {
  final changes = StreamController<AppSessionIdentity?>.broadcast();
  AppSessionIdentity? identity = AppSessionIdentity(
    backend: AppSessionBackend.timeweb,
    uid: 'A',
    emailVerified: true,
  );
  @override
  AppSessionBackend get backend => AppSessionBackend.timeweb;
  @override
  AppSessionIdentity? get currentIdentity => identity;
  @override
  Stream<AppSessionIdentity?> get identityChanges => changes.stream;
  @override
  Future<AppSessionIdentity?> restore() async => identity;
  @override
  Future<AppSessionIdentity> login({
    required String email,
    required String password,
    required String deviceId,
  }) async {
    identity = AppSessionIdentity(
      backend: backend,
      uid: email,
      emailVerified: true,
    );
    return identity!;
  }

  @override
  Future<AppSessionIdentity> refresh() async => identity!;
  @override
  Future<AppSessionLogout> logout({required bool allSessions}) async =>
      AppSessionLogout(
        remote: AppSessionRemoteLogout.localOnly,
        localCleared: true,
        allSessions: allSessions,
      );
  @override
  Future<AppSessionStop> stop() async =>
      const AppSessionStop(protectedStateSafe: true);
  @override
  Future<bool> close() async => true;
}

void main() {
  test(
    'exact original body, permanent submit dedup, real cancellation/slot bound and A-B-A isolation',
    () async {
      final pending = <Completer<http.StreamedResponse>>[];
      final wire = _Wire((request) {
        final response = Completer<http.StreamedResponse>();
        pending.add(response);
        return response.future;
      });
      final off = _client(wire, enabled: false);
      expect(
        () => off.beginScope(),
        throwsA(_error(TimewebLifecycleError.disabled)),
      );
      expect(
        () => TimewebAuthConfiguration(
          endpoint: Uri.parse('http://api.example.invalid'),
        ),
        throwsArgumentError,
      );
      expect(wire.calls, isEmpty);
      expect(await off.close(), isTrue);
      final adapter = _SessionAdapter();
      final session = AppSession(
        adapter: adapter,
        backend: AppSessionBackend.timeweb,
        clearLocal: () async {},
      );
      await session.restore();
      final client = _client(
        wire,
        deadline: const Duration(milliseconds: 30),
        session: session,
      );
      final scope = client.beginScope();
      final operation = client.complete(
        scope: scope,
        purpose: TimewebLifecyclePurpose.registerEmail,
        operationId: _id,
        challengeId: _challenge,
        code: '012345',
        password: _password,
      );
      final first = client.submit(operation);
      expect(identical(first, client.submit(operation)), isTrue);
      expect(_body(wire.calls.single), {
        'challengeId': _challenge,
        'code': '012345',
        'password': _password,
        'operationId': _id,
      });
      expect(wire.calls.single.url.path, '/v1/auth/register-email/complete');
      expect(wire.calls.single.url.hasQuery, isFalse);
      expect(wire.calls.single.headers.containsKey('Authorization'), isFalse);
      expect(wire.calls.single.followRedirects, isFalse);
      final unknown = await first;
      expect(unknown.state, TimewebLifecycleState.unknown);
      expect(unknown.error, TimewebLifecycleError.deadline);
      await (wire.calls.single as http.AbortableRequest).abortTrigger;
      expect(identical(first, client.submit(operation)), isTrue);
      expect(wire.calls.length, 1);
      // A transport ignoring cancellation keeps its slot until actual cleanup.
      final extra = <Future<TimewebLifecycleResult>>[];
      for (var i = 2; i <= 4; i++) {
        extra.add(client.submit(_request(client, scope, id: _operationId(i))));
      }
      expect(
        () => client.submit(_request(client, scope, id: _operationId(5))),
        throwsA(_error(TimewebLifecycleError.unavailable)),
      );
      expect(wire.calls.length, 4);
      await Future.wait(extra);
      await session.login(
        email: 'B',
        password: 'synthetic',
        deviceId: 'synthetic',
      );
      await session.login(
        email: 'A',
        password: 'synthetic',
        deviceId: 'synthetic',
      );
      expect(session.currentUid, 'A');
      expect(scope.isCurrent, isFalse);
      expect(
        () => unknown.state,
        throwsA(_error(TimewebLifecycleError.staleScope)),
      );
      expect(
        () => client.lookup(operation),
        throwsA(_error(TimewebLifecycleError.staleScope)),
      );
      var canceled = 0;
      for (final response in pending) {
        final stream = StreamController<List<int>>(
          onCancel: () {
            canceled++;
          },
        );
        response.complete(
          _reply({
            'status': 'completed',
            'operationToken': _token,
          }, stream: stream.stream),
        );
      }
      await _pump();
      expect(canceled, 4); // Late response streams are canceled, never adopted.
      final current = client.beginScope();
      final late = _request(client, current, id: _operationId(8));
      final lateFuture = client.submit(late);
      final staleCheck = expectLater(
        lateFuture,
        throwsA(_error(TimewebLifecycleError.staleScope)),
      );
      client.beginScope();
      await staleCheck;
      pending.last.complete(
        _reply({
          'status': 'accepted',
          'challengeId': _challenge,
          'operationToken': _token,
        }, status: 202),
      );
      await _pump();
      expect(await client.close(), isTrue);
      await session.stop();
      await adapter.changes.close();
      expect(operation.toString(), isNot(contains(_password)));
      expect(unknown.toString(), isNot(contains(_token)));
    },
  );

  test(
    'offline/lost ACK explicit original lookup, sealed lookup, strict server failures and stream cancellation',
    () async {
      final calls = <http.BaseRequest>[];
      var responseMode = 'offline';
      final lookupGate = Completer<http.StreamedResponse>();
      final slowBody = StreamController<List<int>>();
      var slowCanceled = false;
      slowBody.onCancel = () {
        slowCanceled = true;
      };
      final wire = _Wire((request) async {
        calls.add(request);
        if (responseMode == 'offline') {
          throw StateError('private transport text must never escape');
        }
        if (responseMode == 'lookup') return lookupGate.future;
        if (responseMode == 'unknown') {
          return _reply({
            'error': 'outcome_unknown',
            'operationToken': _token,
          }, status: 503);
        }
        if (responseMode == 'accepted') {
          return _reply({
            'status': 'accepted',
            'challengeId': _challenge,
            'operationToken': _token,
          }, status: 202);
        }
        if (responseMode == 'refused') {
          return _reply({
            'status': 'refused',
            'operationToken': _token,
          }, status: 400);
        }
        if (responseMode == 'rate') {
          return _reply({'error': 'rate_limited'}, status: 429);
        }
        if (responseMode == 'lookupBad') {
          return _reply({'error': 'invalid_request'}, status: 400);
        }
        if (responseMode == 'duplicate') {
          return _reply(
            '{"status":"completed","status":"completed","operationToken":"$_token"}',
          );
        }
        if (responseMode == 'big') return _reply('x' * 16385);
        return _reply({}, stream: slowBody.stream);
      });
      final client = _client(wire, deadline: const Duration(milliseconds: 50));
      final scope = client.beginScope();
      // The mutation might fit 8192 bytes while its original-body lookup does
      // not. Reject before sending so every accepted handle is reconcilable.
      expect(
        () => client.complete(
          scope: scope,
          purpose: TimewebLifecyclePurpose.passwordReset,
          operationId: _operationId(6),
          challengeId: _challenge,
          code: '012345',
          password: '\u0000' * 1333,
        ),
        throwsA(_error(TimewebLifecycleError.invalidRequest)),
      );
      final operation = _request(client, scope);
      expect(identical(operation, _request(client, scope)), isTrue);
      expect(
        () => client.request(
          scope: scope,
          purpose: TimewebLifecyclePurpose.passwordReset,
          operationId: _id,
          email: _email.toLowerCase(),
        ),
        throwsA(_error(TimewebLifecycleError.invalidRequest)),
      );
      final submit = client.submit(operation);
      final lost = await submit;
      expect(lost.state, TimewebLifecycleState.unknown);
      expect(lost.error, TimewebLifecycleError.network);
      await _pump();
      responseMode = 'lookup';
      final lookup = client.lookup(operation);
      expect(identical(lookup, client.lookup(operation)), isTrue);
      expect(calls.last.url.path, '/v1/auth/operations/lookup');
      expect(_body(calls.last), {
        'purpose': 'password-reset.v1',
        'stage': 'request',
        'original': {'email': _email, 'operationId': _id},
      });
      lookupGate.complete(
        _reply({
          'status': 'accepted',
          'challengeId': _challenge,
          'operationToken': _token,
        }, status: 202),
      );
      final accepted = await lookup;
      expect(accepted.state, TimewebLifecycleState.accepted);
      expect(accepted.challengeId, _challenge);
      expect(identical(submit, client.submit(operation)), isTrue);
      await _pump();
      responseMode = 'accepted';
      expect(
        (await client.lookup(operation)).state,
        TimewebLifecycleState.accepted,
      );
      expect(_body(calls.last), {'operationToken': _token});
      expect(
        calls.every(
          (call) =>
              call.method == 'POST' &&
              !call.url.hasQuery &&
              !call.followRedirects,
        ),
        isTrue,
      );
      await _pump();
      responseMode = 'lookupBad';
      expect(
        (await client.lookup(operation)).state,
        TimewebLifecycleState.unknown,
      );
      await _pump();
      responseMode = 'unknown';
      final next = _request(
        client,
        scope,
        id: _operationId(2),
        purpose: TimewebLifecyclePurpose.registerEmail,
      );
      final result = await client.submit(next);
      expect(result.canLookup, isTrue);
      expect(calls.last.url.path, '/v1/auth/register-email/request');
      await _pump();
      responseMode = 'rate';
      expect((await client.lookup(next)).state, TimewebLifecycleState.unknown);
      await _pump();
      final limited = await client.submit(
        _request(client, scope, id: _operationId(3)),
      );
      expect(limited.state, TimewebLifecycleState.rejected);
      expect(limited.error, TimewebLifecycleError.rateLimited);
      await _pump();
      final completion = client.complete(
        scope: scope,
        purpose: TimewebLifecyclePurpose.passwordReset,
        operationId: _operationId(4),
        challengeId: _challenge,
        code: '012345',
        password: '      ',
      );
      expect(
        () => client.complete(
          scope: scope,
          purpose: TimewebLifecyclePurpose.passwordReset,
          operationId: _operationId(6),
          challengeId: _challenge,
          code: '012345',
          password: '12345',
        ),
        throwsA(_error(TimewebLifecycleError.invalidRequest)),
      );
      responseMode = 'refused';
      expect(
        (await client.submit(completion)).state,
        TimewebLifecycleState.refused,
      );
      expect(_body(calls.last)['password'], '      ');
      await _pump();
      responseMode = 'duplicate';
      expect(
        (await client.lookup(completion)).error,
        TimewebLifecycleError.invalidResponse,
      );
      await _pump();
      responseMode = 'big';
      expect(
        (await client.lookup(completion)).error,
        TimewebLifecycleError.invalidResponse,
      );
      await _pump();
      responseMode = 'slow';
      final slow = client.lookup(completion);
      slowBody.add(utf8.encode('{"status":"completed"'));
      expect((await slow).error, TimewebLifecycleError.deadline);
      await _pump();
      expect(slowCanceled, isTrue);
      expect(await client.close(), isTrue);
      expect(
        () => accepted.challengeId,
        throwsA(_error(TimewebLifecycleError.staleScope)),
      );
      expect(lost.toString(), isNot(contains(_email)));
      expect(operation.toString(), isNot(contains(_email)));
    },
  );
}
