import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

import '../lib/service/timeweb_auth_client.dart';

final _now = DateTime.utc(2026, 10, 1);
const _stamp = '2026-10-01T12:00:00.000001Z';
const _nextStamp = '2026-10-01T12:00:00.000002Z';
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
  bool reads = true,
  Duration deadline = const Duration(seconds: 1),
  DateTime Function()? clock,
  _Store? store,
}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://clrs-api.example.invalid'),
    enabled: true,
    currentReadsEnabled: reads,
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
Map<String, dynamic> _chat(
  String id, {
  String? date = _stamp,
  String? name = 'Synthetic',
  int sequence = 7,
}) => {
  'chatId': id,
  'counterpartUid': 'B',
  'name': name,
  'avatar': null,
  'updatedAt': date,
  'lastSequence': sequence,
  'revision': 3,
  'readThrough': 2,
  'archived': false,
  'notifications': true,
};
Map<String, dynamic> _chats([List<Object?> items = const [], String? cursor]) =>
    {
      'kind': 'canonical-current',
      'ordering': 'updated_at_desc_chat_id_asc_null_last',
      'items': items,
      'nextCursor': cursor,
    };
Map<String, dynamic> _message(
  int sequence, {
  String? text = 'Synthetic text',
  String? date = _stamp,
  Object? quote,
}) => {
  'chatId': 'chat-1',
  'messageId': 'message-$sequence',
  'sequence': sequence,
  'senderUid': 'B',
  'text': text,
  'quote': quote,
  'createdAt': date,
};
Map<String, dynamic> _messages(List<Object?> items, [int? next]) => {
  'kind': 'canonical-current',
  'chatId': 'chat-1',
  'chatRevision': 4,
  'ordering': 'sequence_desc',
  'items': items,
  'nextBeforeSequence': next,
};
Map<String, dynamic> _event(int id, {bool read = false}) => {
  'eventId': id,
  'kind': read ? 'chat.read.updated.v1' : 'chat.message.created.v1',
  'chatId': 'chat-1',
  'messageId': read ? null : 'message-3',
  'sequence': read ? null : 3,
  'senderUid': read ? null : 'B',
  'readerUid': read ? 'A' : null,
  'readThroughSequence': read ? 0 : null,
  'chatRevision': 4,
  'createdAt': _stamp,
};
Map<String, dynamic> _events(List<Object?> items, [int? next]) => {
  'kind': 'canonical-current',
  'ordering': 'event_id_asc',
  'items': items,
  'nextAfterEventId': next,
};
Matcher _error(TimewebAuthError error) => isA<TimewebAuthException>().having(
  (value) => value.error,
  'safe error',
  error,
);
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

void main() {
  test('default-off, fixed path and input bounds refuse before HTTP', () async {
    final wire = _Wire((_) async => _reply(_chats()));
    final off = _client(wire, reads: false);
    await off.restore();
    expect(
      TimewebAuthConfiguration(
        endpoint: Uri.parse('https://api.example.invalid'),
      ).currentReadsEnabled,
      isFalse,
    );
    await expectLater(
      off.readCurrent(TimewebCurrentReadRequest.chats()),
      throwsA(_error(TimewebAuthError.disabled)),
    );
    for (final limit in [0, 101]) {
      expect(
        () => TimewebCurrentReadRequest.events(limit: limit),
        throwsArgumentError,
      );
    }
    for (final id in ['', '..', 'https://other.invalid/steal', 'bad\u0000id']) {
      expect(() => TimewebCurrentReadRequest.messages(id), throwsArgumentError);
    }
    final noSessionStore = _Store()..value = null;
    final empty = _client(wire, store: noSessionStore);
    await empty.restore();
    await expectLater(
      empty.readCurrent(TimewebCurrentReadRequest.chats()),
      throwsA(_error(TimewebAuthError.notAuthenticated)),
    );
    expect(wire.calls, isEmpty);
    await off.close();
    await empty.close();
  });

  test(
    'typed chats preserve historical values, exact GET and same-flight dedup',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final wire = _Wire(
        (request) => request.url.queryParameters.containsKey('cursor')
            ? Future.value(_reply(_chats()))
            : pending.future,
      );
      final client = _client(wire);
      await client.restore();
      final request = TimewebCurrentReadRequest.chats(limit: 3);
      final first = client.readCurrent(request),
          same = client.readCurrent(request);
      expect(identical(first, same), isTrue);
      pending.complete(
        _reply(
          _chats([
            _chat('a', date: _nextStamp, name: ''),
            _chat('b', date: _stamp, name: '  \n'),
            _chat('c', date: null, name: null),
          ], 'Synthetic_cursor-next'),
        ),
      );
      final page = await first;
      expect(identical(page, await same), isTrue);
      final rows = page.chats;
      expect(rows.map((row) => row.chatId), ['a', 'b', 'c']);
      expect(rows[0].name, '');
      expect(rows[1].name, '  \n');
      expect(rows[2].updatedAt, isNull);
      expect(rows[2].name, isNull);
      expect(rows[0].avatar, isNull);
      expect(rows[0].lastSequence, 7);
      expect(rows[0].readThrough, 2);
      expect(rows[0].archived, isFalse);
      expect(rows[0].notifications, isTrue);
      expect(() => rows.clear(), throwsUnsupportedError);
      expect(page.toString(), isNot(contains('Synthetic')));
      expect(rows[0].toString(), isNot(contains('Synthetic')));
      expect(page.nextCursor.toString(), isNot(contains('cursor-next')));
      final call = wire.calls.single;
      expect(call.method, 'GET');
      expect(call.followRedirects, isFalse);
      expect(call.url.origin, 'https://clrs-api.example.invalid');
      expect(call.url.path, '/v1/runtime/chats');
      expect(call.url.queryParameters, {'limit': '3'});
      expect(call.headers['Authorization'], 'Bearer na1.A.first');
      expect(
        call.headers.keys.any((key) => key.toLowerCase().contains('preview')),
        isFalse,
      );
      await client.readCurrent(
        TimewebCurrentReadRequest.chats(limit: 3, cursor: page.nextCursor),
      );
      expect(wire.calls.last.url.queryParameters, {
        'limit': '3',
        'cursor': 'Synthetic_cursor-next',
      });
      expect(wire.calls.length, 2);
      await client.close();
    },
  );

  test(
    'message and quote NULL stay distinct; continuation is context-bound last emitted row',
    () async {
      final wire = _Wire(
        (request) async => _reply(
          request.url.queryParameters.containsKey('beforeSequence')
              ? _messages([_message(1, text: '', date: null)])
              : _messages([
                  _message(3, text: null, date: null),
                  _message(
                    2,
                    text: ' \r\n\t',
                    quote: {
                      'messageId': 'imported-media',
                      'sequence': 1,
                      'senderUid': 'A',
                      'text': null,
                    },
                  ),
                ], 2),
        ),
      );
      final client = _client(wire);
      await client.restore();
      final page = await client.readCurrent(
        TimewebCurrentReadRequest.messages('chat-1', limit: 2),
      );
      expect(page.chatId, 'chat-1');
      expect(page.chatRevision, 4);
      expect(page.messages[0].text, isNull);
      expect(page.messages[0].createdAt, isNull);
      expect(page.messages[1].text, ' \r\n\t');
      expect(page.messages[1].quote!.text, isNull);
      expect(page.messages[1].quote!.messageId, 'imported-media');
      final cursor = page.nextCursor!;
      for (final request in [
        TimewebCurrentReadRequest.messages('other', limit: 2, before: cursor),
        TimewebCurrentReadRequest.messages('chat-1', limit: 3, before: cursor),
        TimewebCurrentReadRequest.events(limit: 2, after: cursor),
      ]) {
        await expectLater(
          client.readCurrent(request),
          throwsA(_error(TimewebAuthError.invalidRequest)),
        );
      }
      final other = _client(wire);
      await other.restore();
      await expectLater(
        other.readCurrent(
          TimewebCurrentReadRequest.messages(
            'chat-1',
            limit: 2,
            before: cursor,
          ),
        ),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(wire.calls.length, 1);
      final next = await client.readCurrent(
        TimewebCurrentReadRequest.messages('chat-1', limit: 2, before: cursor),
      );
      expect(next.messages.single.text, '');
      expect(next.nextCursor, isNull);
      expect(wire.calls.last.url.queryParameters, {
        'limit': '2',
        'beforeSequence': '2',
      });
      await other.close();
      await client.close();
    },
  );

  test(
    'event checkpoint advances at EOF and survives empty polling without invented wire fields',
    () async {
      var calls = 0;
      final wire = _Wire(
        (_) async => _reply(
          ++calls == 1
              ? _events([_event(11), _event(12, read: true)])
              : calls == 2
              ? _events([])
              : _events([_event(13)], 13),
        ),
      );
      final client = _client(wire);
      await client.restore();
      final page = await client.readCurrent(
        TimewebCurrentReadRequest.events(limit: 2),
      );
      expect(page.nextCursor, isNull);
      expect(page.eventCheckpoint, isNotNull);
      expect(page.events[0].kind, TimewebCurrentEventKind.messageCreated);
      expect(page.events[0].readerUid, isNull);
      expect(page.events[0].senderUid, 'B');
      expect(page.events[1].kind, TimewebCurrentEventKind.readUpdated);
      expect(page.events[1].sequence, isNull);
      expect(page.events[1].readThroughSequence, 0);
      final checkpoint = page.eventCheckpoint;
      final empty = await client.readCurrent(
        TimewebCurrentReadRequest.events(limit: 2, after: checkpoint),
      );
      expect(empty.events, isEmpty);
      expect(identical(empty.eventCheckpoint, checkpoint), isTrue);
      expect(wire.calls.last.url.queryParameters, {
        'limit': '2',
        'afterEventId': '12',
      });
      final next = await client.readCurrent(
        TimewebCurrentReadRequest.events(
          limit: 2,
          after: empty.eventCheckpoint,
        ),
      );
      expect(next.events.single.eventId, 13);
      expect(next.nextCursor, isNotNull);
      expect(next.eventCheckpoint, isNotNull);
      await client.close();
    },
  );

  test(
    'unknown/raw fields, incorrect types/order/anchors and discriminants fail closed',
    () async {
      final cases =
          <({TimewebCurrentReadRequest request, Map<String, dynamic> body})>[
            (
              request: TimewebCurrentReadRequest.chats(),
              body: _chats([
                _chat('x')..['avatar'] = 'https://foreign.invalid/a',
              ]),
            ),
            (
              request: TimewebCurrentReadRequest.chats(),
              body: _chats([
                _chat('x')..['raw'] = {'email': 'synthetic'},
              ]),
            ),
            (
              request: TimewebCurrentReadRequest.chats(),
              body: _chats([_chat('x')..['lastSequence'] = 1.5]),
            ),
            (
              request: TimewebCurrentReadRequest.chats(),
              body: _chats([_chat('x')..['readThrough'] = 8]),
            ),
            (
              request: TimewebCurrentReadRequest.chats(),
              body: _chats([_chat('x', date: null), _chat('y')]),
            ),
            (
              request: TimewebCurrentReadRequest.chats(),
              body: _chats([_chat('x'), _chat('x')]),
            ),
            (
              request: TimewebCurrentReadRequest.chats(),
              body: _chats([], 'nonempty_cursor'),
            ),
            (
              request: TimewebCurrentReadRequest.messages('chat-1'),
              body: _messages([_message(2), _message(3)]),
            ),
            (
              request: TimewebCurrentReadRequest.messages('chat-1'),
              body: _messages([_message(2)], 1),
            ),
            (
              request: TimewebCurrentReadRequest.messages('chat-1'),
              body: _messages([_message(2, text: 'bad\u0000text')]),
            ),
            (
              request: TimewebCurrentReadRequest.messages('chat-1'),
              body: _messages([
                _message(2, date: '2026-02-30T12:00:00.000001Z'),
              ]),
            ),
            (
              request: TimewebCurrentReadRequest.events(),
              body: _events([_event(1)..['kind'] = 'legacy.raw']),
            ),
            (
              request: TimewebCurrentReadRequest.events(),
              body: _events([_event(1)..['readerUid'] = 'A']),
            ),
            (
              request: TimewebCurrentReadRequest.events(),
              body: _events([_event(1)..['eventId'] = 9223372036854776000.0]),
            ),
            (
              request: TimewebCurrentReadRequest.events(),
              body: _events([_event(2), _event(1)]),
            ),
            (
              request: TimewebCurrentReadRequest.events(),
              body: _events([_event(1)], 2),
            ),
          ];
      for (final sample in cases) {
        final wire = _Wire((_) async => _reply(sample.body));
        final client = _client(wire);
        await client.restore();
        await expectLater(
          client.readCurrent(sample.request),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        expect(wire.calls.length, 1);
        await client.close();
      }
    },
  );

  test(
    'actual stream byte cap, redirects, length/header rejection cancel the subscribed body',
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
            _chats(),
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
        final result = client.readCurrent(TimewebCurrentReadRequest.chats());
        final rejected = expectLater(
          result,
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        if (sample == 0) {
          controller.add(List.filled(32000, 32));
          controller.add(List.filled(33537, 32));
        }
        if (sample == 3) {
          controller.add(utf8.encode(jsonEncode(_chats())));
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
    'deadline holds bounded slots until real cancellation; late account-switch stream is closed',
    () async {
      final cleanup = Completer<void>();
      var cancelled = 0;
      final controllers = <StreamController<List<int>>>[];
      var released = false;
      final wire = _Wire((request) async {
        if (released) return _reply(_events([]));
        final controller = StreamController<List<int>>(
          onCancel: () {
            cancelled++;
            return cleanup.future;
          },
        );
        controllers.add(controller);
        return _reply(_events([]), stream: controller.stream);
      });
      final client = _client(wire, deadline: const Duration(milliseconds: 60));
      await client.restore();
      final results = [
        for (var limit = 1; limit <= 4; limit++)
          client.readCurrent(TimewebCurrentReadRequest.events(limit: limit)),
      ];
      await Future.wait([
        for (final result in results)
          expectLater(result, throwsA(_error(TimewebAuthError.deadline))),
      ]);
      expect(cancelled, 4);
      await expectLater(
        client.readCurrent(TimewebCurrentReadRequest.events(limit: 5)),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      expect(wire.calls.length, 4);
      released = true;
      cleanup.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        (await client.readCurrent(
          TimewebCurrentReadRequest.events(limit: 5),
        )).events,
        isEmpty,
      );
      await client.close();
      for (final controller in controllers) {
        unawaited(controller.close());
      }

      final pending = Completer<http.StreamedResponse>();
      var aborted = 0, lateCancelled = 0;
      final lateWire = _Wire((request) async {
        if (request.method == 'POST') return _reply(_tokens('B'));
        unawaited(
          (request as http.AbortableRequest).abortTrigger!.then((_) {
            aborted++;
          }),
        );
        return pending.future;
      });
      final switched = _client(lateWire);
      await switched.restore();
      final old = switched.readCurrent(TimewebCurrentReadRequest.chats());
      final rejected = expectLater(
        old,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _login(switched, 'B');
      await rejected;
      await _waitFor(() => aborted == 1);
      final late = StreamController<List<int>>(
        onCancel: () {
          lateCancelled++;
        },
      );
      pending.complete(_reply(_chats(), stream: late.stream));
      await _waitFor(() => lateCancelled == 1);
      await switched.close();
      unawaited(late.close());
    },
  );

  test(
    'GET 401 shares refresh; retained page/quote/checkpoints reject B, ABA, logout and close',
    () async {
      final rotation = Completer<http.StreamedResponse>();
      var refreshPosts = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          refreshPosts++;
          return rotation.future;
        }
        if (request.url.path == '/v1/auth/login') {
          final email =
              jsonDecode((request as http.Request).body)['email'] as String;
          return _reply(_tokens(email.split('@').first));
        }
        if (request.url.path == '/v1/auth/logout')
          return _reply({'revoked': true});
        if (request.headers['Authorization'] == 'Bearer na1.A.first')
          return _reply({}, status: 401);
        return _reply(
          request.url.path.endsWith('/messages')
              ? _messages([
                  _message(
                    2,
                    quote: {
                      'messageId': 'message-1',
                      'sequence': 1,
                      'senderUid': 'A',
                      'text': 'Retained text',
                    },
                  ),
                ], 2)
              : request.url.path.endsWith('/events')
              ? _events([_event(11)])
              : _chats([_chat('chat-1')]),
        );
      });
      final client = _client(wire);
      await client.restore();
      final messages = client.readCurrent(
        TimewebCurrentReadRequest.messages('chat-1'),
      );
      final events = client.readCurrent(TimewebCurrentReadRequest.events());
      await _waitFor(() => refreshPosts == 1);
      rotation.complete(_reply(_tokens('A')));
      final page = await messages, eventPage = await events;
      expect(refreshPosts, 1);
      expect(wire.calls.where((r) => r.method == 'GET').length, 4);
      expect(
        wire.calls.where((r) => r.method == 'POST').single.url.path,
        '/v1/auth/refresh',
      );
      final message = page.messages.single,
          quote = message.quote!,
          cursor = page.nextCursor!,
          checkpoint = eventPage.eventCheckpoint!;
      await _login(client, 'B');
      for (final read in [
        () => page.messages,
        () => message.text,
        () => quote.text,
        () => cursor.requireCurrent(),
        () => eventPage.events,
        () => checkpoint.requireCurrent(),
      ]) {
        expect(read, throwsA(_error(TimewebAuthError.staleSession)));
      }
      await _login(client, 'A');
      expect(
        () => message.text,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await expectLater(
        client.readCurrent(
          TimewebCurrentReadRequest.messages('chat-1', before: cursor),
        ),
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      final current = await client.readCurrent(
        TimewebCurrentReadRequest.events(),
      );
      final retained = current.events.single;
      await client.logout();
      expect(
        () => retained.eventId,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _login(client, 'A');
      final closed = await client.readCurrent(
        TimewebCurrentReadRequest.chats(),
      );
      final chat = closed.chats.single;
      await client.close();
      expect(() => chat.name, throwsA(_error(TimewebAuthError.staleSession)));
    },
  );
}
