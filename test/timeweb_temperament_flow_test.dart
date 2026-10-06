import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_temperament_flow.dart';

final _now = DateTime.utc(2026, 10, 2);
const _stamp = '2026-10-02T12:00:00.000001Z';
const _nextStamp = '2026-10-02T12:00:00.000002Z';
const _origin = 'https://api.example.invalid';
const _assignedGroup = 'красно-коричневая';

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = TimewebSession(
    uid: 'A',
    emailVerified: true,
    accessToken: 'na1.A',
    refreshToken: 'nr1.A',
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

http.StreamedResponse _reply(Object body, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
Map<String, Object> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid',
  'refreshToken': 'nr1.$uid',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
Map<String, Object?> _full(String uid, {String stage = 'test'}) => {
  'uid': uid,
  'profileExists': true,
  'profile': {
    'fullName': 'Current $uid',
    'age': 28,
    'rost': null,
    'about': null,
    'hobbi': null,
    'deti': null,
    'pol': null,
    'relationStatus': null,
    'country': null,
    'countryCode': null,
    'region': null,
    'city': null,
    'languageCode': null,
    'primaryGroup': stage == 'search' ? _assignedGroup : null,
    'secondaryGroup': null,
    'profileDetailsSaved': stage != 'registration',
    'isRegistrationEnd': stage == 'search',
    'updatedAt': stage == 'search' ? _nextStamp : _stamp,
  },
  'onboarding': stage,
  'profileAuthority': 'canonical-current-v1',
  'mediaReady': false,
};
List<bool> _answers() => List<bool>.generate(
  80,
  (i) => i < 6 || i >= 20 && i < 29 || i >= 40 && i < 44 || i == 60,
);
List<File> _files(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.json'))
    .toList();
TimewebMutationRequest _request(Map<String, dynamic> body) =>
    TimewebMutationRequest.completeOwnTemperament(
      operationId: body['operationId'],
      expectedUpdatedAt: body['expectedUpdatedAt'],
      scores: TimewebTemperamentScores(
        brown: body['scores']['brown'],
        red: body['scores']['red'],
        blue: body['scores']['blue'],
        white: body['scores']['white'],
      ),
    );
Map<String, Object?> _receipt(
  TimewebMutationRequest request,
  Object result, {
  bool replayed = false,
}) => {
  'operation': request.operation,
  'operationId': request.operationId,
  'requestHash': request.requestHash,
  'state': 'committed',
  'replayed': replayed,
  'result': result,
  'entityRevision': null,
};
Map<String, Object> _completed(String uid) => {
  'uid': uid,
  'primaryGroup': _assignedGroup,
  'isRegistrationEnd': true,
  'onboarding': 'search',
  'updatedAt': _nextStamp,
  'profileAuthority': 'canonical-current-v1',
};
TimewebAuthClient _client(_Store store, _Wire wire) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse(_origin),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: store,
  transport: wire,
  clock: () => _now,
);
Future<TimewebTemperamentFlow> _open(
  TimewebAuthClient client,
  AppSession session,
  TimewebTemperamentJournal journal,
) async {
  final lease = session.captureLease();
  final snapshot = await client.readCurrentOwnProfile();
  return TimewebTemperamentFlow.open(
    client: client,
    session: session,
    lease: lease,
    journal: journal,
    snapshot: snapshot.bindSessionGuard(lease.requireCurrent),
  );
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}

void main() {
  test(
    'canonical answers are durable before POST; one in-flight submit and server group',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-test-flow-',
      );
      final journal = TimewebTemperamentJournal(
        directory: () async => directory,
      );
      var posts = 0;
      final wire = _Wire((request) async {
        if (request.method == 'GET') return _reply(_full('A'));
        expect(request.url.path, '/v1/runtime/me/temperament');
        expect(request.headers['Authorization'], 'Bearer na1.A');
        posts++;
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(body['expectedUpdatedAt'], _stamp);
        expect(body['scores'], {'brown': 6, 'red': 9, 'blue': 4, 'white': 1});
        final operation = _request(body);
        final durable = jsonDecode(_files(directory).single.readAsStringSync());
        expect(durable['answers'], _answers());
        expect(durable['operationId'], operation.operationId);
        expect(durable['requestHash'], operation.requestHash);
        expect(durable['expectedUpdatedAt'], _stamp);
        expect(durable['operation'], 'profile.complete-test.v1');
        expect(durable.toString(), isNot(contains('na1.A')));
        return _reply(_receipt(operation, _completed('A')));
      });
      final client = _client(_Store(), wire);
      final session = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      try {
        await session.restore();
        final flow = await _open(client, session, journal);
        expect(flow.initialAnswers, List<bool>.filled(80, false));
        expect(() => flow.initialAnswers[0] = true, throwsUnsupportedError);
        expect(
          () => flow.submit(List<bool>.filled(79, true)),
          throwsArgumentError,
        );
        expect(
          () => flow.submit(List<bool>.generate(80, (i) => i < 19)),
          throwsArgumentError,
        );
        expect(posts, 0);
        final original = flow.submit(_answers());
        final duplicate = flow.submit(List<bool>.filled(80, true));
        expect(identical(original, duplicate), isTrue);
        expect(await original, TimewebTemperamentOutcome.confirmed);
        expect(flow.confirmedGroup, _assignedGroup);
        expect(flow.requiresReload, isFalse);
        expect(_files(directory), isEmpty);
        expect(posts, 1);
        expect(() => flow.submit(_answers()), throwsStateError);
        flow.close();
      } finally {
        await session.stop();
        await journal.drain();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'lost ACK restarts with exact answers and lookup only; not_found retains intent',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-test-restart-',
      );
      final store = _Store();
      var stage = 'test', posts = 0, lookups = 0;
      var found = false;
      TimewebMutationRequest? original;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return _reply(_full('A', stage: stage));
        }
        if (request.method == 'POST') {
          posts++;
          original = _request(jsonDecode((request as http.Request).body));
          stage = 'search';
          throw const SocketException('Synthetic lost response');
        }
        lookups++;
        expect(
          request.url.path,
          '/v1/runtime/operations/profile.complete-test.v1/${original!.operationId}',
        );
        expect(request.url.queryParameters, {
          'requestHash': original!.requestHash,
        });
        return _reply(
          found
              ? _receipt(original!, _completed('A'), replayed: true)
              : {
                  'operation': original!.operation,
                  'operationId': original!.operationId,
                  'requestHash': original!.requestHash,
                  'state': 'not_found',
                  'replayed': false,
                  'result': null,
                  'entityRevision': null,
                },
        );
      });
      final journal = TimewebTemperamentJournal(
        directory: () async => directory,
      );
      final firstClient = _client(store, wire);
      final firstSession = AppSession.timeweb(
        client: firstClient,
        clearLocal: () async {},
      );
      AppSession? restarted;
      try {
        await firstSession.restore();
        final first = await _open(firstClient, firstSession, journal);
        expect(
          await first.submit(_answers()),
          TimewebTemperamentOutcome.unknown,
        );
        expect(first.needsCheck, isTrue);
        final durableFile = _files(directory).single;
        final durable = durableFile.readAsStringSync();
        first.close();
        await firstSession.stop();
        await journal.drain();
        final nextClient = _client(store, wire);
        restarted = AppSession.timeweb(
          client: nextClient,
          clearLocal: () async {},
        );
        await restarted.restore();
        final recovered = await _open(nextClient, restarted, journal);
        expect(recovered.initialAnswers, _answers());
        expect(recovered.needsCheck, isTrue);
        expect(() => recovered.submit(_answers()), throwsStateError);
        expect(await recovered.check(), TimewebTemperamentOutcome.unknown);
        expect(durableFile.readAsStringSync(), durable);
        found = true;
        expect(await recovered.check(), TimewebTemperamentOutcome.confirmed);
        expect(recovered.confirmedGroup, _assignedGroup);
        expect(posts, 1);
        expect(lookups, 2);
        expect(_files(directory), isEmpty);
        recovered.close();
        final damaged = jsonDecode(durable)..['requestHash'] = '0' * 64;
        final swapped = jsonDecode(durable);
        swapped['answers'][0] = false;
        swapped['answers'][6] =
            true; // Same score/hash, different original bits.
        for (final invalid in [
          jsonEncode(damaged),
          jsonEncode(swapped),
          durable.replaceFirst('"version":1', '"version":1,"version":1'),
          'x' * 16385,
        ]) {
          await durableFile.writeAsString(invalid, flush: true);
          await expectLater(
            _open(nextClient, restarted, journal),
            throwsFormatException,
          );
        }
        expect(posts, 1);
        expect(lookups, 2);
      } finally {
        await firstSession.stop();
        await restarted?.stop();
        await journal.drain();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'declared CAS, completed, incomplete and missing profile refusals require reread',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-test-refusal-',
      );
      final journal = TimewebTemperamentJournal(
        directory: () async => directory,
      );
      final cases = <(String, TimewebMutationFailure, int)>[
        ('profile_changed', TimewebMutationFailure.profileChanged, 409),
        (
          'test_already_completed',
          TimewebMutationFailure.testAlreadyCompleted,
          409,
        ),
        ('profile_incomplete', TimewebMutationFailure.profileIncomplete, 409),
        ('profile_not_found', TimewebMutationFailure.notFound, 404),
      ];
      var sample = 0;
      final wire = _Wire((request) async {
        if (request.method == 'GET') return _reply(_full('A'));
        final operation = _request(jsonDecode((request as http.Request).body));
        final error = cases[sample];
        return _reply(
          _receipt(operation, {
            'error': error.$1,
            if (const {
              'profile_changed',
              'test_already_completed',
            }.contains(error.$1))
              'updatedAt': _nextStamp,
          }),
          status: error.$3,
        );
      });
      final client = _client(_Store(), wire);
      final session = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      try {
        await session.restore();
        for (sample = 0; sample < cases.length; sample++) {
          final flow = await _open(client, session, journal);
          expect(
            await flow.submit(_answers()),
            TimewebTemperamentOutcome.rejected,
          );
          expect(flow.requiresReload, isTrue);
          expect(flow.rejectionFailure, cases[sample].$2);
          expect(flow.confirmedGroup, isNull);
          expect(_files(directory), isEmpty);
          expect(() => flow.submit(_answers()), throwsStateError);
          flow.close();
        }
      } finally {
        await session.stop();
        await journal.drain();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'A/B revokes an ACK waiting on journal IO; old A cannot retire durable answers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-test-owner-',
      );
      final blockedDirectory = Completer<Directory>();
      var blockIO = false, waiting = false, posts = 0;
      final journal = TimewebTemperamentJournal(
        directory: () async {
          if (blockIO) {
            waiting = true;
            return blockedDirectory.future;
          }
          return directory;
        },
      );
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') return _reply(_tokens('B'));
        if (request.method == 'GET') {
          return _reply(
            _full(
              request.headers['Authorization'] == 'Bearer na1.B' ? 'B' : 'A',
            ),
          );
        }
        posts++;
        final operation = _request(jsonDecode((request as http.Request).body));
        blockIO = true;
        return _reply(_receipt(operation, _completed('A')));
      });
      final client = _client(_Store(), wire);
      final session = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      try {
        await session.restore();
        final old = await _open(client, session, journal);
        final outcome = expectLater(
          old.submit(_answers()),
          throwsA(isA<AppSessionException>()),
        );
        await _until(() => waiting);
        final durable = _files(directory).single.readAsStringSync();
        final login = session.login(
          email: 'B@example.invalid',
          password: 'password',
          deviceId: 'synthetic-device',
        );
        expect(old.requireCurrent, throwsA(isA<AppSessionException>()));
        expect(() => old.confirmedGroup, throwsA(isA<AppSessionException>()));
        await login;
        blockIO = false;
        blockedDirectory.complete(directory);
        await outcome;
        expect(_files(directory).single.readAsStringSync(), durable);
        final b = await _open(client, session, journal);
        expect(b.initialAnswers, List<bool>.filled(80, false));
        expect(b.needsCheck, isFalse);
        expect(posts, 1);
        old.close();
        b.close();
      } finally {
        if (!blockedDirectory.isCompleted) blockedDirectory.complete(directory);
        await session.stop();
        await journal.drain();
        await directory.delete(recursive: true);
      }
    },
  );
}
