import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../lib/service/timeweb_auth_client.dart';

final _now = DateTime.utc(2026, 10, 1);
final _origin = Uri.parse('https://clrs-api.example.invalid');

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = TimewebSession(
    uid: 'A',
    emailVerified: true,
    accessToken: 'na1.A.first',
    refreshToken: 'nr1.A.first',
    accessExpiresAt: _now.add(const Duration(minutes: 15)),
    refreshExpiresAt: _now.add(const Duration(days: 14)),
  );
  @override
  Future<TimewebSession?> read() async => value;
  @override
  Future<void> write(TimewebSession session) async {
    value = session;
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
  bool media = true,
  Duration deadline = const Duration(seconds: 1),
}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: _origin,
    enabled: true,
    privateMediaEnabled: media,
  ),
  secureStore: _Store(),
  transport: wire,
  clock: () => _now,
  mediaRequestDeadline: deadline,
);

Map<String, dynamic> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid.rotated',
  'refreshToken': 'nr1.$uid.rotated',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
http.StreamedResponse _json(Object value) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(value))),
  200,
  headers: {'content-type': 'application/json', 'cache-control': 'no-store'},
);
http.StreamedResponse _image({
  Stream<List<int>>? stream,
  int length = 3,
  int status = 200,
  Map<String, String>? changes,
}) => http.StreamedResponse(
  stream ?? Stream.value([1, 2, 3]),
  status,
  headers: {
    'content-length': '$length',
    'content-type': 'image/png',
    'cache-control': 'private, no-store',
    'x-content-type-options': 'nosniff',
    ...?changes,
  },
);
TimewebPrivateMediaRequest _request([String suffix = 'one']) =>
    TimewebPrivateMediaRequest('Synthetic_opaque-$suffix');
Matcher _error(TimewebAuthError error) => isA<TimewebAuthException>().having(
  (value) => value.error,
  'safe typed error',
  error,
);
Future<void> _waitFor(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue);
}

Future<void> _login(TimewebAuthClient client, String uid) async {
  await client.login(
    email: '$uid@example.invalid',
    password: 'Synthetic password',
    deviceId: 'synthetic-device',
  );
}

void main() {
  test(
    'media is separately default-off and accepts no URL/path/query input',
    () async {
      final wire = _Wire((_) async => _image());
      final client = _client(wire, media: false);
      await client.restore();
      await expectLater(
        client.readPrivateMedia(_request()),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      expect(wire.calls, isEmpty);
      for (final reference in [
        '',
        'https://other.invalid/image',
        '../image',
        'opaque?token=x',
        'opaque=',
        'a' * 4097,
      ]) {
        expect(
          () => TimewebPrivateMediaRequest(reference),
          throwsArgumentError,
        );
      }
      expect(
        () => _client(wire, deadline: const Duration(seconds: 61)),
        throwsArgumentError,
      );
      await client.close();
    },
  );

  test(
    'verified bytes use fixed GET origin, immutable copies and no completed cache',
    () async {
      final wire = _Wire(
        (_) async => _image(
          stream: Stream.fromIterable([
            [1],
            [2, 3],
          ]),
        ),
      );
      final client = _client(wire);
      await client.restore();
      final request = _request();
      final image = await client.readPrivateMedia(request);
      expect(image.bytes, [1, 2, 3]);
      expect(image.length, 3);
      final copy = image.bytes;
      copy[0] = 99;
      expect(image.bytes, [1, 2, 3]);
      expect(image.contentType, 'image/png');
      expect('$image$request', isNot(contains('Synthetic_opaque')));
      final sent = wire.calls.single;
      expect(sent, isA<http.AbortableRequest>());
      expect(sent.url.origin, _origin.origin);
      expect(sent.url.path, '/v1/media/Synthetic_opaque-one');
      expect(sent.url.query, isEmpty);
      expect(sent.method, 'GET');
      expect(sent.followRedirects, isFalse);
      expect(sent.headers['Authorization'], 'Bearer na1.A.first');
      expect(
        sent.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('x-clrs-preview-key')),
      );
      await client.readPrivateMedia(request);
      expect(wire.calls.length, 2);
      await client.close();
    },
  );

  test(
    'header size bounds, real streamed exceed and truncation cancel the subscription',
    () async {
      final cases =
          <({int length, List<int>? bytes, Map<String, String>? changes})>[
            (length: 32000001, bytes: null, changes: null),
            (length: 2, bytes: [1, 2, 3], changes: null),
            (length: 3, bytes: [1], changes: null),
            (length: 3, bytes: null, changes: {'content-type': 'text/html'}),
            (
              length: 3,
              bytes: null,
              changes: {'cache-control': 'public, no-store'},
            ),
            (length: 3, bytes: null, changes: {'x-content-type-options': ''}),
          ];
      for (final sample in cases) {
        var cancelled = 0;
        late StreamController<List<int>> controller;
        controller = StreamController(
          onListen: () {
            if (sample.bytes != null) {
              controller.add(sample.bytes!);
              if (sample.bytes!.length < sample.length)
                unawaited(controller.close());
            }
          },
          onCancel: () {
            cancelled++;
          },
        );
        final wire = _Wire(
          (_) async => _image(
            stream: controller.stream,
            length: sample.length,
            changes: sample.changes,
          ),
        );
        final client = _client(wire);
        await client.restore();
        await expectLater(
          client.readPrivateMedia(_request()),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        expect(cancelled, 1);
        await client.close();
        unawaited(controller.close());
      }
    },
  );

  test(
    'deadline aborts real subscriptions and holds both slots until cleanup settles',
    () async {
      final gates = [Completer<void>(), Completer<void>()];
      final controllers = <StreamController<List<int>>>[];
      var cancelled = 0, aborted = 0;
      final wire = _Wire((request) async {
        if (controllers.length >= 2) return _image();
        final index = controllers.length;
        final controller = StreamController<List<int>>(
          onCancel: () {
            cancelled++;
            return gates[index].future;
          },
        );
        controllers.add(controller);
        unawaited(
          (request as http.AbortableRequest).abortTrigger!.then((_) {
            aborted++;
          }),
        );
        return _image(stream: controller.stream);
      });
      final client = _client(wire, deadline: const Duration(milliseconds: 30));
      await client.restore();
      final one = client.readPrivateMedia(_request('one'));
      final two = client.readPrivateMedia(_request('two'));
      await Future.wait([
        expectLater(one, throwsA(_error(TimewebAuthError.deadline))),
        expectLater(two, throwsA(_error(TimewebAuthError.deadline))),
      ]);
      await _waitFor(() => cancelled == 2 && aborted == 2);
      await expectLater(
        client.readPrivateMedia(_request('three')),
        throwsA(_error(TimewebAuthError.deadline)),
      );
      expect(wire.calls.length, 2);
      for (final gate in gates) {
        gate.complete();
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect((await client.readPrivateMedia(_request('three'))).bytes, [
        1,
        2,
        3,
      ]);
      await client.close();
      for (final controller in controllers) {
        unawaited(controller.close());
      }
    },
  );

  test(
    'same epoch/reference shares one flight; a third transfer waits for cleanup',
    () async {
      final pending = <Completer<http.StreamedResponse>>[];
      final wire = _Wire((_) {
        final next = Completer<http.StreamedResponse>();
        pending.add(next);
        return next.future;
      });
      final client = _client(wire);
      await client.restore();
      final one = client.readPrivateMedia(_request('one'));
      final same = client.readPrivateMedia(_request('one'));
      expect(identical(one, same), isTrue);
      final two = client.readPrivateMedia(_request('two'));
      final three = client.readPrivateMedia(_request('three'));
      expect(wire.calls.length, 2);
      pending[0].complete(_image());
      await _waitFor(() => pending.length == 3);
      expect((await one).bytes, [1, 2, 3]);
      pending[2].complete(_image());
      pending[1].complete(_image());
      expect((await two).bytes, [1, 2, 3]);
      expect((await three).bytes, [1, 2, 3]);
      await client.close();
    },
  );

  test(
    'bounded FIFO drains three queued transfers and account switch removes waiting jobs without I/O',
    () async {
      final pending = <Completer<http.StreamedResponse>>[];
      final wire = _Wire((request) {
        if (request.url.path == '/v1/auth/login') {
          return Future.value(_json(_tokens('B')));
        }
        final next = Completer<http.StreamedResponse>();
        pending.add(next);
        return next.future;
      });
      final client = _client(wire);
      await client.restore();
      final first = client.readPrivateMedia(_request('active_one'));
      final second = client.readPrivateMedia(_request('active_two'));
      final waiting = [
        for (var i = 0; i < 3; i++)
          client.readPrivateMedia(_request('queued_$i')),
      ];
      expect(pending.length, 2);
      for (var i = 0; i < 3; i++) {
        pending[i].complete(_image());
        await _waitFor(() => pending.length == i + 3);
        expect(
          wire.calls.last.url.path,
          '/v1/media/Synthetic_opaque-queued_$i',
        );
      }
      pending[3].complete(_image());
      pending[4].complete(_image());
      await Future.wait([first, second, ...waiting]);

      final cancelled = [
        for (var i = 0; i < 32; i++)
          client.readPrivateMedia(_request('switch_$i')),
      ];
      final rejected = Future.wait([
        for (final future in cancelled)
          expectLater(future, throwsA(_error(TimewebAuthError.staleSession))),
      ]);
      expect(pending.length, 7);
      await expectLater(
        client.readPrivateMedia(_request('over_bound')),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      await client.login(
        email: 'synthetic@example.invalid',
        password: 'synthetic',
        deviceId: 'test-device',
      );
      await rejected;
      expect(pending.length, 7);
      pending[5].complete(_image());
      pending[6].complete(_image());
      await Future<void>.delayed(Duration.zero);
      expect(pending.length, 7);
      await client.close();
    },
  );

  test(
    'redirect is never followed; concurrent 401 GETs share a single refresh POST',
    () async {
      var cancelled = 0;
      final controller = StreamController<List<int>>(
        onCancel: () {
          cancelled++;
        },
      );
      final redirectWire = _Wire(
        (_) async => _image(
          stream: controller.stream,
          status: 302,
          changes: {'location': 'https://other.invalid/secret'},
        ),
      );
      final redirectClient = _client(redirectWire);
      await redirectClient.restore();
      await expectLater(
        redirectClient.readPrivateMedia(_request()),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      expect(redirectWire.calls.length, 1);
      expect(cancelled, 1);
      await redirectClient.close();
      unawaited(controller.close());
      final rotation = Completer<http.StreamedResponse>();
      var refreshPosts = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          refreshPosts++;
          return rotation.future;
        }
        return request.headers['Authorization'] == 'Bearer na1.A.first'
            ? _image(status: 401)
            : _image();
      });
      final client = _client(wire);
      await client.restore();
      final one = client.readPrivateMedia(_request('one'));
      final two = client.readPrivateMedia(_request('two'));
      await _waitFor(() => refreshPosts == 1);
      rotation.complete(_json(_tokens('A')));
      expect((await one).bytes, [1, 2, 3]);
      expect((await two).bytes, [1, 2, 3]);
      expect(refreshPosts, 1);
      expect(wire.calls.where((call) => call.method == 'GET').length, 4);
      await client.close();
    },
  );

  test(
    'A to B immediately aborts a pending send and closes its late response stream',
    () async {
      final pending = Completer<http.StreamedResponse>();
      var aborted = 0, cancelled = 0;
      final wire = _Wire((request) async {
        if (request.method == 'POST') return _json(_tokens('B'));
        unawaited(
          (request as http.AbortableRequest).abortTrigger!.then((_) {
            aborted++;
          }),
        );
        return pending.future;
      });
      final client = _client(wire);
      await client.restore();
      final old = client.readPrivateMedia(_request());
      final rejected = expectLater(
        old,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _login(client, 'B');
      await rejected;
      expect(client.currentUid, 'B');
      await _waitFor(() => aborted == 1);
      final late = StreamController<List<int>>(
        onCancel: () {
          cancelled++;
        },
      );
      pending.complete(_image(stream: late.stream));
      await _waitFor(() => cancelled == 1);
      await client.close();
      unawaited(late.close());
    },
  );

  test('retained bytes reject ABA, logout and closed-client access', () async {
    for (final action in ['ABA', 'logout', 'close']) {
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/logout')
          return _json({'loggedOut': true});
        if (request.method == 'POST') {
          final email =
              (jsonDecode((request as http.Request).body) as Map)['email']
                  as String;
          return _json(_tokens(email.split('@').first));
        }
        return _image();
      });
      final client = _client(wire);
      await client.restore();
      final image = await client.readPrivateMedia(_request());
      if (action == 'ABA') {
        await _login(client, 'B');
        await _login(client, 'A');
      }
      if (action == 'logout') await client.logout();
      if (action == 'close') await client.close();
      expect(() => image.bytes, throwsA(_error(TimewebAuthError.staleSession)));
      expect(
        () => image.requireCurrent(),
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await client.close();
    }
  });
}
