import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_auth_client.dart';

final _now = DateTime.utc(2026, 10, 1);
const _stamp = '2026-10-01T12:00:00.000001Z';
TimewebSession _session(String uid, [String revision = 'first']) =>
    TimewebSession(
      uid: uid,
      emailVerified: true,
      accessToken: 'na1.$uid.$revision',
      refreshToken: 'nr1.$uid.$revision',
      accessExpiresAt: _now.add(const Duration(minutes: 15)),
      refreshExpiresAt: _now.add(const Duration(days: 14)),
    );

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = _session('A');
  @override
  Future<TimewebSession?> read() async => value;
  @override
  Future<void> write(TimewebSession value) async {
    this.value = value;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

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

TimewebAuthClient _client(
  _Wire wire, {
  bool writes = true,
  Duration deadline = const Duration(seconds: 1),
  _Store? store,
  DateTime Function()? clock,
}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://clrs-api.example.invalid'),
    enabled: true,
    runtimeWritesEnabled: writes,
    currentReadsEnabled: true,
  ),
  secureStore: store ?? _Store(),
  transport: wire,
  clock: clock ?? () => _now,
  requestDeadline: deadline,
);
Map<String, dynamic> _tokens(String uid, [String revision = 'rotated']) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid.$revision',
  'refreshToken': 'nr1.$uid.$revision',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
Map<String, dynamic> _profile() => {
  'fullName': 'Synthetic name',
  'age': 28,
  'rost': 180,
  'about': 'Synthetic about',
  'hobbi': 'Synthetic interests',
  'deti': false,
  'pol': 'male',
  'relationStatus': 'single',
  'profileDetailsSaved': null,
  'isRegistrationEnd': false,
  'updatedAt': _stamp,
};
Map<String, dynamic> _view({
  String uid = 'A',
  bool exists = true,
  Map<String, dynamic>? profile,
}) => {
  'uid': uid,
  'profile': exists ? (profile ?? _profile()) : null,
  'profileExists': exists,
  'profileAuthority': 'canonical-current-v1',
  'editableFields': [
    'fullName',
    'age',
    'rost',
    'about',
    'hobbi',
    'deti',
    'pol',
    'relationStatus',
  ],
};
http.StreamedResponse _reply(
  Object body, {
  int status = 200,
  Stream<List<int>>? stream,
  int? length,
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  stream ?? Stream.value(utf8.encode(jsonEncode(body))),
  status,
  contentLength: length,
  headers: {
    'content-type': 'application/json',
    'cache-control': 'private,no-store',
    ...headers,
  },
);
Matcher _error(TimewebAuthError error) =>
    isA<TimewebAuthException>().having((v) => v.error, 'safe error', error);
Future<void> _waitFor(bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue);
}

Future<void> _login(TimewebAuthClient client, String uid) => client
    .login(
      email: '$uid@example.invalid',
      password: 'synthetic',
      deviceId: 'test-device',
    )
    .then((_) {});
const _request = TimewebProfileEditorRequest.own();

void main() {
  test('editor read is default-off and own-only before HTTP', () async {
    final wire = _Wire((_) async => _reply(_view()));
    final off = _client(wire, writes: false);
    await off.restore();
    expect(
      TimewebAuthConfiguration(
        endpoint: Uri.parse('https://api.example.invalid'),
      ).runtimeWritesEnabled,
      isFalse,
    );
    await expectLater(
      off.readProfileForEdit(_request),
      throwsA(_error(TimewebAuthError.disabled)),
    );
    final noSession = _client(wire, store: _Store()..value = null);
    await noSession.restore();
    await expectLater(
      noSession.readProfileForEdit(_request),
      throwsA(_error(TimewebAuthError.notAuthenticated)),
    );
    expect(wire.calls, isEmpty);
    expect(_request.toString(), isNot(contains('A')));
    await off.close();
    await noSession.close();
  });

  test(
    'typed current editor retains nullable history and exact CAS without hydration or writes',
    () async {
      final wire = _Wire(
        (_) async => _reply(
          _view(
            profile: _profile()
              ..['fullName'] = ''
              ..['age'] = 0
              ..['rost'] = 0
              ..['about'] = ' \r\n'
              ..['hobbi'] = null
              ..['deti'] = null
              ..['pol'] = null
              ..['relationStatus'] = null,
          ),
        ),
      );
      final client = _client(wire);
      await client.restore();
      final view = await client.readProfileForEdit(_request);
      final profile = view.profile!;
      expect(view.uid, 'A');
      expect(view.profileExists, isTrue);
      expect(view.profileAuthority, 'canonical-current-v1');
      expect(profile.fullName, '');
      expect(profile.age, 0);
      expect(profile.rost, 0);
      expect(profile.about, ' \r\n');
      expect(profile.hobbi, isNull);
      expect(profile.deti, isNull);
      expect(profile.pol, isNull);
      expect(profile.relationStatus, isNull);
      expect(profile.profileDetailsSaved, isNull);
      expect(profile.isRegistrationEnd, isFalse);
      expect(profile.updatedAt, _stamp);
      expect(view.editableFields, TimewebEditableProfileField.values);
      expect(() => view.editableFields.clear(), throwsUnsupportedError);
      final mutation = TimewebMutationRequest.editOwnProfile(
        operationId: '00000000-0000-4000-8000-000000000001',
        expectedUpdatedAt: profile.updatedAt,
        changes: TimewebProfileChanges(
          about: 'New synthetic description long enough',
        ),
      );
      expect(
        client.bindMutation(mutation, expectedOwnerUid: view.uid).requestHash,
        mutation.requestHash,
      );
      final call = wire.calls.single;
      expect(call.method, 'GET');
      expect(call.followRedirects, isFalse);
      expect(
        call.url.toString(),
        'https://clrs-api.example.invalid/v1/runtime/me/profile',
      );
      expect(call.url.hasQuery, isFalse);
      expect(call.headers['Authorization'], 'Bearer na1.A.first');
      expect(profile.toString(), isNot(contains('Synthetic')));
      expect(view.toString(), isNot(contains(_stamp)));
      await client.close();
    },
  );

  test(
    'absent profile remains absent with the same exact editor capability list',
    () async {
      final wire = _Wire((_) async => _reply(_view(exists: false)));
      final client = _client(wire);
      await client.restore();
      final view = await client.readProfileForEdit(_request);
      expect(view.profile, isNull);
      expect(view.profileExists, isFalse);
      expect(view.editableFields.length, 8);
      expect(view.uid, 'A');
      expect(wire.calls.single.method, 'GET');
      await client.close();
    },
  );

  test(
    'foreign UID, raw/financial fields, wrong null/types and editable permission expansion fail closed',
    () async {
      final cases = <Map<String, dynamic>>[
        _view(uid: 'B'),
        _view()..['profileAuthority'] = 'immutable-reviewed-snapshot',
        _view()..['balance'] = 123,
        _view()..['profileExists'] = 0,
        _view(exists: false)..['profileExists'] = true,
        _view()
          ..['editableFields'] = [
            'fullName',
            'age',
            'rost',
            'about',
            'hobbi',
            'deti',
            'pol',
            'balance',
          ],
        _view()
          ..['editableFields'] = [
            'fullName',
            'age',
            'rost',
            'about',
            'hobbi',
            'deti',
            'pol',
            'pol',
          ],
        _view(profile: _profile()..['role'] = 'admin'),
        _view(profile: _profile()..remove('hobbi')),
        _view(profile: _profile()..['age'] = 28.0),
        _view(profile: _profile()..['age'] = 131),
        _view(profile: _profile()..['rost'] = 301),
        _view(profile: _profile()..['deti'] = 1),
        _view(profile: _profile()..['profileDetailsSaved'] = 'true'),
        _view(profile: _profile()..['updatedAt'] = null),
        _view(
          profile: _profile()..['updatedAt'] = '2026-02-30T12:00:00.000001Z',
        ),
        _view(profile: _profile()..['about'] = 'bad\u0000value'),
        _view(profile: _profile()..['fullName'] = 'x' * 4097),
      ];
      for (final body in cases) {
        final wire = _Wire((_) async => _reply(body));
        final client = _client(wire);
        await client.restore();
        await expectLater(
          client.readProfileForEdit(_request),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        expect(wire.calls.length, 1);
        await client.close();
      }
    },
  );

  test(
    'stream byte bound and redirect/header/length refusals really cancel the body',
    () async {
      for (var sample = 0; sample < 6; sample++) {
        var cancelled = 0;
        final controller = StreamController<List<int>>(
          onCancel: () {
            cancelled++;
          },
        );
        final wire = _Wire(
          (_) async => _reply(
            _view(),
            stream: controller.stream,
            status: sample == 1 ? 302 : 200,
            length: sample == 2
                ? 65537
                : sample == 3
                ? 1
                : null,
            headers: sample == 1
                ? {'location': 'https://other.invalid/secret'}
                : sample == 4
                ? {'cache-control': 'public,no-store'}
                : sample == 5
                ? {'content-encoding': 'gzip'}
                : {},
          ),
        );
        final client = _client(wire);
        await client.restore();
        final result = client.readProfileForEdit(_request);
        final rejected = expectLater(
          result,
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        if (sample == 0) {
          controller.add(List.filled(32768, 32));
          controller.add(List.filled(32769, 32));
        }
        if (sample == 3) {
          controller.add(utf8.encode(jsonEncode(_view())));
          unawaited(controller.close());
        }
        await rejected;
        expect(cancelled, 1);
        expect(wire.calls.length, 1);
        expect(wire.calls.single.followRedirects, isFalse);
        await client.close();
        unawaited(controller.close());
      }
    },
  );

  test(
    'dedup and deadline retain flight until actual stream cleanup then allow a fresh GET',
    () async {
      var cancelled = 0, released = false;
      final cleanup = Completer<void>();
      final controller = StreamController<List<int>>(
        onCancel: () {
          cancelled++;
          return cleanup.future;
        },
      );
      final wire = _Wire(
        (_) async => released
            ? _reply(_view())
            : _reply(_view(), stream: controller.stream),
      );
      final client = _client(wire, deadline: const Duration(milliseconds: 60));
      await client.restore();
      final first = client.readProfileForEdit(_request),
          same = client.readProfileForEdit(_request);
      expect(identical(first, same), isTrue);
      await expectLater(first, throwsA(_error(TimewebAuthError.deadline)));
      expect(cancelled, 1);
      final retained = client.readProfileForEdit(_request);
      expect(identical(first, retained), isTrue);
      await expectLater(retained, throwsA(_error(TimewebAuthError.deadline)));
      expect(wire.calls.length, 1);
      released = true;
      cleanup.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        (await client.readProfileForEdit(_request)).profile!.updatedAt,
        _stamp,
      );
      expect(wire.calls.length, 2);
      await client.close();
      unawaited(controller.close());
    },
  );

  test(
    'shared GET refresh rotates once and expired editor reads pre-refresh safely',
    () async {
      var refreshes = 0;
      final rotation = Completer<http.StreamedResponse>();
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          refreshes++;
          return rotation.future;
        }
        if (request.headers['Authorization'] == 'Bearer na1.A.first') {
          return _reply({}, status: 401);
        }
        return _reply(
          request.url.path.endsWith('/profile')
              ? _view()
              : {
                  'kind': 'canonical-current',
                  'ordering': 'event_id_asc',
                  'items': [],
                  'nextAfterEventId': null,
                },
        );
      });
      final client = _client(wire);
      await client.restore();
      final editor = client.readProfileForEdit(_request),
          events = client.readCurrent(TimewebCurrentReadRequest.events());
      await _waitFor(() => refreshes == 1);
      rotation.complete(_reply(_tokens('A')));
      expect((await editor).profile!.updatedAt, _stamp);
      expect((await events).events, isEmpty);
      expect(refreshes, 1);
      expect(wire.calls.where((r) => r.method == 'GET').length, 4);
      expect(
        wire.calls.where((r) => r.method == 'POST').single.url.path,
        '/v1/auth/refresh',
      );
      await client.close();
      final expiredWire = _Wire(
        (request) async =>
            _reply(request.method == 'POST' ? _tokens('A') : _view()),
      );
      final expired = _client(
        expiredWire,
        clock: () => _now.add(const Duration(minutes: 15)),
      );
      await expired.restore();
      expect((await expired.readProfileForEdit(_request)).profile!.age, 28);
      expect(expiredWire.calls.map((r) => r.url.path), [
        '/v1/auth/refresh',
        '/v1/runtime/me/profile',
      ]);
      await expired.close();

      // Stopping an editor must not discard the real auth rotation already
      // started for its GET. Persist the new tokens but expose no old read/UID.
      final duringStop = Completer<http.StreamedResponse>();
      final protectedStore = _Store();
      final stopWire = _Wire((_) => duringStop.future);
      final stopping = _client(
        stopWire,
        store: protectedStore,
        clock: () => _now.add(const Duration(minutes: 15)),
      );
      await stopping.restore();
      final pendingEditor = stopping.readProfileForEdit(_request);
      final rejected = expectLater(
        pendingEditor,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _waitFor(() => stopWire.calls.length == 1);
      final stopped = stopping.stop();
      await rejected;
      expect(stopping.currentUid, isNull);
      await expectLater(
        stopping.readProfileForEdit(_request),
        throwsA(_error(TimewebAuthError.closed)),
      );
      duringStop.complete(_reply(_tokens('A')));
      final stopResult = await stopped;
      expect(stopResult.protectedStateSafe, isTrue);
      expect(stopResult.remoteOutcomeUnknown, isFalse);
      expect(protectedStore.value!.accessToken, 'na1.A.rotated');
      expect(stopWire.calls.single.url.path, '/v1/auth/refresh');
      expect(stopWire.calls.single.method, 'POST');
    },
  );

  test(
    'retained nested editor rejects B/ABA/logout/close and a late old response is cancelled',
    () async {
      var uid = 'A', aborted = 0, cancelled = 0;
      final late = Completer<http.StreamedResponse>();
      var reads = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') {
          uid = (jsonDecode((request as http.Request).body)['email'] as String)
              .split('@')
              .first;
          return _reply(_tokens(uid));
        }
        if (request.url.path == '/v1/auth/logout') {
          return _reply({'revoked': true});
        }
        if (++reads == 2) {
          unawaited(
            (request as http.AbortableRequest).abortTrigger!.then((_) {
              aborted++;
            }),
          );
          return late.future;
        }
        return _reply(_view(uid: uid));
      });
      final client = _client(wire);
      await client.restore();
      final snapshot = await client.readProfileForEdit(_request);
      final profile = snapshot.profile!;
      final old = client.readProfileForEdit(_request);
      final rejected = expectLater(
        old,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _login(client, 'B');
      await rejected;
      await _waitFor(() => aborted == 1);
      expect(
        () => snapshot.uid,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      expect(
        () => snapshot.editableFields,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      expect(
        () => profile.updatedAt,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled++;
        },
      );
      late.complete(_reply(_view(), stream: stream.stream));
      await _waitFor(() => cancelled == 1);
      await _login(client, 'A');
      expect(() => profile.age, throwsA(_error(TimewebAuthError.staleSession)));
      final current = await client.readProfileForEdit(_request);
      final nested = current.profile!;
      await client.logout();
      expect(
        () => nested.fullName,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _login(client, 'A');
      final closed = await client.readProfileForEdit(_request);
      final last = closed.profile!;
      await client.close();
      expect(
        () => last.updatedAt,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      unawaited(stream.close());
    },
  );
}
