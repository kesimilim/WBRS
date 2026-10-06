import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import '../lib/service/timeweb_auth_client.dart';

final _now = DateTime.utc(2026, 10, 1);
const _stamp = '2026-10-01T12:00:00.000001Z';
String _id(int number) =>
    '00000000-0000-4000-8000-${number.toString().padLeft(12, '0')}';
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
  DateTime Function()? clock,
  Duration deadline = const Duration(seconds: 1),
}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://clrs-api.example.invalid'),
    enabled: true,
    runtimeWritesEnabled: writes,
  ),
  secureStore: _Store(),
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
http.StreamedResponse _reply(Object body, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: {
        'content-type': 'application/json',
        'cache-control': 'private,no-store',
      },
    );
TimewebMutationRequest _send(
  int number, {
  String text = 'Synthetic message',
  String? quote,
}) => TimewebMutationRequest.sendMessage(
  operationId: _id(number),
  chatId: 'chat-1',
  text: text,
  quoteMessageId: quote,
);
TimewebMutationReference _bind(
  TimewebAuthClient client,
  TimewebMutationRequest request,
) => client.bindMutation(request, expectedOwnerUid: 'A');
Map<String, dynamic> _message(
  TimewebMutationRequest request, {
  String uid = 'A',
}) => {
  'chatId': 'chat-1',
  'messageId': 'message-1',
  'sequence': 1,
  'senderUid': uid,
  'text': 'Synthetic message',
  'quote': null,
  'createdAt': _stamp,
  'chatRevision': 1,
  'eventIds': [1, 2],
};
Map<String, dynamic> _envelope(
  TimewebMutationRequest request,
  Object? result, {
  String state = 'committed',
  bool replayed = false,
  int? revision = 1,
}) => {
  'operation': request.operation,
  'operationId': request.operationId,
  'requestHash': request.requestHash,
  'state': state,
  'replayed': replayed,
  'result': result,
  'entityRevision': revision,
};
Map<String, dynamic> _profile() => {
  'fullName': 'Synthetic name',
  'age': 28,
  'rost': 180,
  'about': 'Synthetic description long enough',
  'hobbi': 'Synthetic interests long enough',
  'deti': false,
  'pol': 'male',
  'relationStatus': 'single',
  'profileDetailsSaved': null,
  'isRegistrationEnd': false,
  'updatedAt': _stamp,
};
Matcher _error(TimewebAuthError value) =>
    isA<TimewebAuthException>().having((e) => e.error, 'safe error', value);
Future<void> _waitFor(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue);
}

void main() {
  test(
    'shared Python request-digest fixture covers send/read/profile ORIGINAL payloads',
    () {
      final fixture = jsonDecode(
        File(
          'server/timeweb/test/fixtures/runtime-request-digests.json',
        ).readAsStringSync(),
      );
      for (final item in fixture['cases']) {
        final payload = item['payload'] as Map<String, dynamic>;
        final request = payload.containsKey('text')
            ? TimewebMutationRequest.sendMessage(
                operationId: _id(1),
                chatId: payload['chatId'],
                text: payload['text'],
                quoteMessageId: payload['quoteMessageId'],
              )
            : payload.containsKey('throughSequence')
            ? TimewebMutationRequest.markRead(
                operationId: _id(1),
                chatId: payload['chatId'],
                throughSequence: payload['throughSequence'],
              )
            : TimewebMutationRequest.editOwnProfile(
                operationId: _id(1),
                expectedUpdatedAt: payload['expectedUpdatedAt'],
                changes: TimewebProfileChanges(
                  about: payload['changes']['about'],
                  hobbi: payload['changes']['hobbi'],
                  deti: payload['changes']['deti'],
                ),
              );
        expect(request.requestHash, item['sha256']);
      }
    },
  );

  test(
    'default off, original owner, typed field/UUID bounds reject locally',
    () async {
      final wire = _Wire((_) async => _reply({}));
      final off = _client(wire, writes: false);
      await off.restore();
      expect(
        () => _bind(off, _send(1)),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      final client = _client(wire);
      await client.restore();
      expect(
        () => client.bindMutation(_send(1), expectedOwnerUid: 'B'),
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      expect(
        () => TimewebMutationRequest.sendMessage(
          operationId: 'random',
          chatId: 'chat-1',
          text: 'test',
        ),
        throwsArgumentError,
      );
      for (final chat in [
        '../path',
        'https://other.invalid/route',
        'chat\u0000',
      ]) {
        expect(
          () => TimewebMutationRequest.sendMessage(
            operationId: _id(1),
            chatId: chat,
            text: 'test',
          ),
          throwsArgumentError,
        );
      }
      expect(() => _send(1, text: '  \n\t'), throwsArgumentError);
      expect(() => _send(1, text: 'x' * 4097), throwsArgumentError);
      expect(() => TimewebProfileChanges(), throwsArgumentError);
      expect(() => TimewebProfileChanges(about: 'short'), throwsArgumentError);
      expect(
        () => TimewebMutationRequest.editOwnProfile(
          operationId: _id(1),
          expectedUpdatedAt: '2026-02-30T00:00:00.000000Z',
          changes: TimewebProfileChanges(fullName: 'Synthetic'),
        ),
        throwsArgumentError,
      );
      expect(wire.calls, isEmpty);
      await client.close();
      await off.close();
    },
  );

  test('canonical ORIGINAL payload hash matches Python Unicode vector', () {
    final request = TimewebMutationRequest.sendMessage(
      operationId: _id(1),
      chatId: 'chat-1',
      text: '  Привет 👋\nссылка?\t"да"\u2028  ',
    );
    expect(
      request.requestHash,
      '639f9bebcc6b78ca419ed28e902266a0d4f24b605c941c6cef8eaccfb935697a',
    );
    expect(
      request.requestHash,
      isNot(_send(1, text: 'Привет 👋\nссылка?\t"да"').requestHash),
    );
    expect(request.toString(), isNot(contains('Привет')));
  });

  test(
    'fixed flat POST, UUID/hash dedup, immutable typed send/read/profile receipts',
    () async {
      final send = _send(1), pending = Completer<http.StreamedResponse>();
      final read = TimewebMutationRequest.markRead(
        operationId: _id(2),
        chatId: 'chat-1',
        throughSequence: 1,
      );
      final profile = TimewebMutationRequest.editOwnProfile(
        operationId: _id(3),
        expectedUpdatedAt: _stamp,
        changes: TimewebProfileChanges(fullName: 'Synthetic name'),
      );
      final wire = _Wire((request) async {
        expect(request.url.host, 'clrs-api.example.invalid');
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer na1.A.first');
        expect(
          request.headers.keys.any((k) => k.toLowerCase().contains('preview')),
          isFalse,
        );
        final body = jsonDecode((request as http.Request).body);
        expect(body.containsKey('uid'), isFalse);
        expect(body.containsKey('payload'), isFalse);
        if (request.url.path.endsWith('/messages')) {
          expect(body, {
            'operationId': _id(1),
            'text': 'Synthetic message',
            'quoteMessageId': null,
          });
          return pending.future;
        }
        if (request.url.path.endsWith('/read'))
          return _reply(
            _envelope(read, {
              'chatId': 'chat-1',
              'readThroughSequence': 1,
              'changed': false,
              'chatRevision': 1,
              'eventIds': [],
            }),
          );
        return _reply(
          _envelope(profile, {
            'uid': 'A',
            'profile': _profile(),
            'operationId': _id(3),
            'profileAuthority': 'canonical-current-v1',
          }, revision: null),
        );
      });
      final client = _client(wire);
      await client.restore();
      final ref = _bind(client, send);
      expect(identical(ref, _bind(client, _send(1))), isTrue);
      expect(
        () => _bind(client, _send(1, text: 'Changed payload')),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      final first = client.mutate(ref), second = client.mutate(ref);
      expect(identical(first, second), isTrue);
      expect(wire.calls.length, 1);
      pending.complete(_reply(_envelope(send, _message(send)), status: 201));
      final result = await first;
      expect(result.state, TimewebMutationState.confirmed);
      expect(result.hasReceipt, isTrue);
      expect(result.message!.text, 'Synthetic message');
      expect(result.message!.eventIds, [1, 2]);
      expect(() => result.message!.eventIds.add(3), throwsUnsupportedError);
      expect((await client.mutate(ref)).message!.sequence, 1);
      expect(wire.calls.length, 1);
      expect(
        (await client.mutate(_bind(client, read))).readReceipt!.changed,
        isFalse,
      );
      expect(
        (await client.mutate(
          _bind(client, profile),
        )).editedProfile!.isRegistrationEnd,
        isFalse,
      );
      expect(result.toString(), isNot(contains('Synthetic')));
      await client.close();
    },
  );

  test(
    'timeout/network/redirect/503/malformed results stay unknown, never replay POST',
    () async {
      for (var sample = 0; sample < 7; sample++) {
        final request = _send(sample + 1),
            pending = Completer<http.StreamedResponse>();
        var cancelled = 0, aborted = 0;
        final wire = _Wire((wireRequest) async {
          unawaited(
            (wireRequest as http.AbortableRequest).abortTrigger!.then((_) {
              aborted++;
            }),
          );
          switch (sample) {
            case 0:
              return pending.future;
            case 1:
              throw StateError('Do not expose low-level message');
            case 2:
              return http.StreamedResponse(
                Stream.value([1]),
                302,
                headers: {'location': 'https://foreign.invalid'},
              );
            case 3:
              return _reply({'error': 'outcome_unknown'}, status: 503);
            case 4:
              return _reply({
                ..._envelope(request, _message(request)),
                'requestHash': '0' * 64,
              });
            case 5:
              return _reply(
                _envelope(request, {
                  ..._message(request),
                  'mediaUrl': 'https://forbidden.invalid',
                }),
              );
            default:
              late StreamController<List<int>> controller;
              controller = StreamController(
                onListen: () => controller.add(List.filled(65537, 32)),
                onCancel: () {
                  cancelled++;
                },
              );
              return http.StreamedResponse(
                controller.stream,
                200,
                headers: {
                  'content-type': 'application/json',
                  'cache-control': 'no-store',
                },
              );
          }
        });
        final client = _client(
          wire,
          deadline: const Duration(milliseconds: 20),
        );
        await client.restore();
        final ref = _bind(client, request);
        final result = await client.mutate(ref);
        expect(result.state, TimewebMutationState.unknown);
        expect(result.reference, ref);
        expect((await client.mutate(ref)).state, TimewebMutationState.unknown);
        expect(wire.calls.length, 1);
        expect(
          () => client.acknowledgeMutation(ref),
          throwsA(_error(TimewebAuthError.invalidRequest)),
        );
        if (sample == 0) {
          expect(aborted, 1);
          pending.complete(_reply(_envelope(request, _message(request))));
        }
        if (sample == 6) expect(cancelled, 1);
        expect(result.toString(), isNot(contains('low-level')));
        await client.close();
      }
    },
  );

  test(
    'pre-refresh deduplicates before POST; POST401 never refreshes or replays',
    () async {
      final rotation = Completer<http.StreamedResponse>();
      final requests = [_send(1), _send(2)];
      var refreshes = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          refreshes++;
          return rotation.future;
        }
        expect(request.headers['Authorization'], 'Bearer na1.A.rotated');
        final number =
            jsonDecode((request as http.Request).body)['operationId'] == _id(1)
            ? 0
            : 1;
        return _reply(_envelope(requests[number], _message(requests[number])));
      });
      final client = _client(
        wire,
        clock: () => _now.add(const Duration(minutes: 16)),
      );
      await client.restore();
      final first = client.mutate(_bind(client, requests[0])),
          second = client.mutate(_bind(client, requests[1]));
      expect(refreshes, 1);
      expect(wire.calls.length, 1);
      rotation.complete(_reply(_tokens('A')));
      await Future.wait([first, second]);
      expect(wire.calls.length, 3);
      await client.close();
      final rejected = _Wire(
        (_) async => _reply({'error': 'unauthorized'}, status: 401),
      );
      final live = _client(rejected);
      await live.restore();
      final ref = _bind(live, _send(3));
      expect(
        (await live.mutate(ref)).failure,
        TimewebMutationFailure.unauthorized,
      );
      await live.mutate(ref);
      expect(rejected.calls.length, 1);
      expect(live.currentUid, 'A');
      await live.close();
    },
  );

  test(
    'explicit GET reconcile shares refresh, binds hash and cannot unlock absent journal POST',
    () async {
      final request = _send(1), rotation = Completer<http.StreamedResponse>();
      var refreshes = 0;
      final wire = _Wire((wireRequest) async {
        if (wireRequest.method == 'POST') {
          if (wireRequest.url.path == '/v1/auth/refresh') {
            refreshes++;
            return rotation.future;
          }
          return _reply({'error': 'outcome_unknown'}, status: 503);
        }
        expect(
          wireRequest.url.path,
          '/v1/runtime/operations/chat.send-text.v1/${_id(1)}',
        );
        expect(wireRequest.url.queryParameters, {
          'requestHash': request.requestHash,
        });
        return wireRequest.headers['Authorization'] == 'Bearer na1.A.first'
            ? _reply({}, status: 401)
            : _reply(_envelope(request, _message(request), replayed: true));
      });
      final client = _client(wire);
      await client.restore();
      final ref = _bind(client, request);
      expect((await client.mutate(ref)).state, TimewebMutationState.unknown);
      final one = client.reconcileMutation(ref),
          same = client.reconcileMutation(ref);
      expect(identical(one, same), isTrue);
      await _waitFor(() => refreshes == 1);
      rotation.complete(_reply(_tokens('A')));
      final found = await one;
      expect(found.state, TimewebMutationState.confirmed);
      expect(found.replayed, isTrue);
      expect((await client.mutate(ref)).state, TimewebMutationState.confirmed);
      expect(wire.calls.length, 4);
      await client.close();
      final absent = _Wire(
        (_) async => _reply(
          _envelope(request, null, state: 'not_found', revision: null),
        ),
      );
      final restored = _client(absent);
      await restored.restore();
      final recovered = _bind(restored, request);
      expect(
        (await restored.reconcileMutation(recovered)).state,
        TimewebMutationState.notFound,
      );
      expect(
        (await restored.mutate(recovered)).state,
        TimewebMutationState.notFound,
      );
      expect(absent.calls.single.method, 'GET');
      expect(
        () => restored.acknowledgeMutation(recovered),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      await restored.close();
      var posted = 0;
      final deniedWire = _Wire((wireRequest) async {
        if (wireRequest.url.path == '/v1/auth/refresh') {
          return _reply(_tokens('A'));
        }
        if (wireRequest.method == 'POST') {
          posted++;
          return _reply({'error': 'outcome_unknown'}, status: 503);
        }
        return _reply({'error': 'unauthorized'}, status: 401);
      });
      final deniedClient = _client(deniedWire);
      await deniedClient.restore();
      final uncertain = _bind(deniedClient, request);
      await deniedClient.mutate(uncertain);
      await expectLater(
        deniedClient.reconcileMutation(uncertain),
        throwsA(_error(TimewebAuthError.unauthorized)),
      );
      expect(
        (await deniedClient.mutate(uncertain)).state,
        TimewebMutationState.unknown,
      );
      expect(posted, 1);
      await deniedClient.close();
    },
  );

  test(
    'profile conflict is a confirmed failure receipt; retained A/ABA and late POST cannot escape',
    () async {
      final profile = TimewebMutationRequest.editOwnProfile(
        operationId: _id(1),
        expectedUpdatedAt: _stamp,
        changes: TimewebProfileChanges(fullName: 'Synthetic'),
      );
      final late = Completer<http.StreamedResponse>();
      var posts = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') {
          final email =
              jsonDecode((request as http.Request).body)['email'] as String;
          return _reply(_tokens(email.split('@').first));
        }
        if (++posts == 1)
          return _reply(
            _envelope(profile, {
              'error': 'profile_changed',
              'updatedAt': _stamp,
            }, revision: null),
            status: 409,
          );
        return late.future;
      });
      final client = _client(wire);
      await client.restore();
      final ref = _bind(client, profile);
      final result = await client.mutate(ref);
      expect(result.failure, TimewebMutationFailure.profileChanged);
      expect(result.hasReceipt, isTrue);
      final pending = client.mutate(_bind(client, _send(2)));
      final denied = expectLater(
        pending,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await client.login(
        email: 'B@example.invalid',
        password: 'synthetic',
        deviceId: 'device-test',
      );
      late.complete(_reply(_envelope(_send(2), _message(_send(2)))));
      await denied;
      for (final access in <void Function()>[
        ref.requireCurrent,
        result.requireCurrent,
        () => result.state,
        () => result.reference,
      ]) {
        expect(access, throwsA(_error(TimewebAuthError.staleSession)));
      }
      await client.login(
        email: 'A@example.invalid',
        password: 'synthetic',
        deviceId: 'device-test',
      );
      expect(
        () => ref.operationId,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      expect(
        () => client.bindMutation(_send(3), expectedOwnerUid: 'B'),
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await client.close();
    },
  );

  test(
    'explicit durable receipt acknowledgment frees bounded registry, old reference cannot POST again',
    () async {
      final first = _send(1);
      final wire = _Wire(
        (_) async => _reply(_envelope(first, _message(first))),
      );
      final client = _client(wire);
      await client.restore();
      final refs = [for (var i = 1; i <= 64; i++) _bind(client, _send(i))];
      expect(
        () => _bind(client, _send(65)),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      expect(
        () => client.acknowledgeMutation(refs[1]),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      await client.mutate(refs.first);
      client.acknowledgeMutation(refs.first);
      expect(_bind(client, _send(65)), isA<TimewebMutationReference>());
      expect(
        (await client.mutate(refs.first)).state,
        TimewebMutationState.confirmed,
      );
      expect(wire.calls.length, 1);
      client.acknowledgeMutation(refs.first);
      await client.close();
    },
  );

  test(
    'definite original POST400 can retire; lookup400 cannot resolve or retire a journal',
    () async {
      final wire = _Wire(
        (_) async => _reply({'error': 'invalid_request'}, status: 400),
      );
      final client = _client(wire);
      await client.restore();
      final reference = _bind(client, _send(1));
      final result = await client.mutate(reference);
      expect(result.state, TimewebMutationState.declaredFailure);
      expect(result.hasReceipt, isFalse);
      expect(result.canAcknowledge, isTrue);
      client.acknowledgeMutation(reference);
      await client.mutate(reference);
      expect(wire.calls.length, 1);
      final journal = _bind(client, _send(2));
      await expectLater(
        client.reconcileMutation(journal),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(
        (await client.mutate(journal)).state,
        TimewebMutationState.unknown,
      );
      expect(
        () => client.acknowledgeMutation(journal),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(wire.calls.last.method, 'GET');
      expect(wire.calls.length, 2);
      await client.close();
    },
  );
}
