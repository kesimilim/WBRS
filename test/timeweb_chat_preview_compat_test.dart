import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_auth_client.dart';

import 'support/timeweb_people_fixtures.dart';

TimewebAuthClient _client(PeopleWire wire, {Duration? deadline}) =>
    TimewebAuthClient(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse('https://api.example.invalid'),
        enabled: true,
        currentReadsEnabled: true,
      ),
      secureStore: PeopleStore(),
      transport: wire,
      clock: () => peopleNow,
      requestDeadline: deadline ?? const Duration(seconds: 1),
    );

Map<String, dynamic> _page({bool preview = false, String? cursor}) => {
  'kind': 'canonical-current',
  'ordering': 'updated_at_desc_chat_id_asc_null_last',
  'items': [
    {
      'chatId': 'chat-1',
      'counterpartUid': 'P0',
      'name': 'Peer',
      'avatar': null,
      'updatedAt': peopleStamp,
      'lastSequence': 1,
      'revision': 1,
      'readThrough': 0,
      'archived': false,
      'notifications': true,
      if (preview) ...{
        'lastMessage': 'Original preview',
        'lastMessageSenderUid': 'P0',
      },
    },
  ],
  'nextCursor': cursor,
};

List<http.BaseRequest> _reads(PeopleWire wire) =>
    wire.calls.where((request) => request.method == 'GET').toList();

TypeMatcher<TimewebAuthException> get _authError => isA<TimewebAuthException>();

void main() {
  test('new preview provider stays exactly one authenticated GET', () async {
    final wire = PeopleWire(
      (request) async => peopleReply(_page(preview: true)),
    );
    final client = _client(wire);
    addTearDown(client.close);
    await client.restore();
    final page = await client.readCurrent(
      TimewebCurrentReadRequest.chats(limit: 3),
    );
    expect(page.chats.single.lastMessage, 'Original preview');
    expect(_reads(wire), hasLength(1));
    expect(_reads(wire).single.url.queryParameters, {
      'limit': '3',
      'includePreview': '1',
    });
    expect(_reads(wire).single.headers['Authorization'], 'Bearer na1.A.first');
  });

  test(
    'exact old-provider400 permits one bare GET preserving pagination/UID',
    () async {
      final wire = PeopleWire((request) async {
        expect(request.headers['Authorization'], 'Bearer na1.A.first');
        if (request.url.queryParameters['includePreview'] == '1') {
          return peopleReply({'error': 'invalid_request'}, status: 400);
        }
        return peopleReply(
          _page(
            cursor: request.url.queryParameters.containsKey('cursor')
                ? null
                : 'Synthetic_next_cursor',
          ),
        );
      });
      final client = _client(wire);
      addTearDown(client.close);
      await client.restore();
      final page = await client.readCurrent(
        TimewebCurrentReadRequest.chats(limit: 3),
      );
      expect(page.chats.single.name, 'Peer');
      expect(page.chats.single.lastMessage, isNull);
      expect(_reads(wire), hasLength(2));
      expect(_reads(wire)[0].url.queryParameters, {
        'limit': '3',
        'includePreview': '1',
      });
      expect(_reads(wire)[1].url.queryParameters, {'limit': '3'});
      await client.readCurrent(
        TimewebCurrentReadRequest.chats(limit: 3, cursor: page.nextCursor),
      );
      expect(_reads(wire), hasLength(4));
      expect(_reads(wire)[2].url.queryParameters, {
        'limit': '3',
        'includePreview': '1',
        'cursor': 'Synthetic_next_cursor',
      });
      expect(_reads(wire)[3].url.queryParameters, {
        'limit': '3',
        'cursor': 'Synthetic_next_cursor',
      });
      expect(wire.calls.where((request) => request.method != 'GET'), isEmpty);
    },
  );

  test('401/403/5xx never downgrade the chats query', () async {
    for (final status in [401, 403, 500, 503]) {
      final wire = PeopleWire(
        (request) async =>
            peopleReply({'error': 'invalid_request'}, status: status),
      );
      final client = _client(wire);
      await client.restore();
      await expectLater(
        client.readCurrent(TimewebCurrentReadRequest.chats()),
        throwsA(_authError),
      );
      expect(_reads(wire), hasLength(1), reason: 'status$status');
      expect(_reads(wire).single.url.queryParameters['includePreview'], '1');
      await client.close();
    }
  });

  test('malformed/extra/wrong400 body never starts a bare GET', () async {
    final cases = <http.StreamedResponse Function()>[
      () => peopleReply({'error': 'other_error'}, status: 400),
      () =>
          peopleReply({'error': 'invalid_request', 'extra': true}, status: 400),
      () => peopleReply(
        {'error': 'invalid_request'},
        status: 400,
        stream: Stream.value(utf8.encode('{broken')),
      ),
      () => peopleReply(
        {'error': 'invalid_request'},
        status: 400,
        headers: {'content-type': 'text/html'},
      ),
      () => peopleReply(
        {'error': 'invalid_request'},
        status: 400,
        stream: Stream.value(List.filled(4097, 32)),
      ),
    ];
    for (final response in cases) {
      final wire = PeopleWire((request) async => response());
      final client = _client(wire);
      await client.restore();
      await expectLater(
        client.readCurrent(TimewebCurrentReadRequest.chats()),
        throwsA(_authError),
      );
      expect(_reads(wire), hasLength(1));
      expect(_reads(wire).single.url.queryParameters['includePreview'], '1');
      await client.close();
    }
  });

  test('bare-read rejection ends the one compatibility attempt', () async {
    final wire = PeopleWire(
      (request) async => peopleReply({'error': 'invalid_request'}, status: 400),
    );
    final client = _client(wire);
    addTearDown(client.close);
    await client.restore();
    await expectLater(
      client.readCurrent(TimewebCurrentReadRequest.chats()),
      throwsA(_authError),
    );
    expect(_reads(wire), hasLength(2));
    expect(
      _reads(wire).last.url.queryParameters.containsKey('includePreview'),
      isFalse,
    );
  });

  test('deadline before late400 starts zero compatibility GET', () async {
    final late = Completer<http.StreamedResponse>();
    final wire = PeopleWire((request) => late.future);
    final client = _client(wire, deadline: const Duration(milliseconds: 30));
    await client.restore();
    await expectLater(
      client.readCurrent(TimewebCurrentReadRequest.chats()),
      throwsA(
        _authError.having((e) => e.error, 'error', TimewebAuthError.deadline),
      ),
    );
    late.complete(peopleReply({'error': 'invalid_request'}, status: 400));
    await client.close();
    expect(_reads(wire), hasLength(1));
  });

  test(
    'late A400 after B login cannot send compatibility GET as either account',
    () async {
      final late = Completer<http.StreamedResponse>();
      final wire = PeopleWire((request) async {
        if (request.method == 'POST') {
          return peopleReply(peopleTokens('B'));
        }
        return late.future;
      });
      final client = _client(wire);
      await client.restore();
      final read = client.readCurrent(TimewebCurrentReadRequest.chats());
      final rejected = expectLater(
        read,
        throwsA(
          _authError.having(
            (e) => e.error,
            'error',
            TimewebAuthError.staleSession,
          ),
        ),
      );
      await client.login(
        email: 'b@example.invalid',
        password: 'synthetic-password',
        deviceId: 'synthetic-device',
      );
      await rejected;
      expect(client.currentUid, 'B');
      late.complete(peopleReply({'error': 'invalid_request'}, status: 400));
      await client.close();
      expect(_reads(wire), hasLength(1));
      expect(
        _reads(wire).single.headers['Authorization'],
        'Bearer na1.A.first',
      );
    },
  );
}
