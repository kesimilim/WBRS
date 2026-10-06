import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_chat_flow.dart';
import 'package:wbrs/service/timeweb_personal_chat_flow.dart';

import 'support/timeweb_people_fixtures.dart';

const personalId = '12345678-1234-4234-8234-123456789abc';
const importedChatId = 'legacy-imported-chat';
TimewebMutationRequest personalRequest([String id = personalId]) =>
    TimewebMutationRequest.openPersonalChat(operationId: id, targetUid: 'B');
Map<String, dynamic> personalResult({bool created = false}) => {
  'chatId': importedChatId,
  'peerUid': 'B',
  'created': created,
  'chatRevision': 4,
};
Map<String, dynamic> personalEnvelope(
  TimewebMutationRequest request,
  Object? result, {
  bool replayed = false,
  bool absent = false,
  int? revision = 4,
}) => {
  'operation': request.operation,
  'operationId': request.operationId,
  'requestHash': request.requestHash,
  'state': absent ? 'not_found' : 'committed',
  'replayed': replayed,
  'result': result,
  'entityRevision': absent ? null : revision,
};
TimewebAuthClient personalClient(PeopleWire wire, {bool enabled = true}) =>
    TimewebAuthClient(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse('https://api.example.invalid'),
        enabled: true,
        currentReadsEnabled: true,
        runtimeWritesEnabled: enabled,
      ),
      secureStore: PeopleStore(),
      transport: wire,
      clock: () => peopleNow,
    );
TimewebAppRuntime personalRuntime(
  PeopleWire wire,
  Directory root, {
  PeopleStore? store,
}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: store ?? PeopleStore(),
  transport: wire,
  clock: () => peopleNow,
  deviceId: 'synthetic-device',
  expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {},
  currentOwnProfileEnabled: true,
  currentChatsEnabled: true,
  personalChatJournal: TimewebPersonalChatJournal(directory: () async => root),
  chatJournal: TimewebChatJournal(directory: () async => root),
);
List<File> personalFiles(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.json'))
    .toList();
Future<void> personalTick(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(ready(), isTrue);
}

Matcher personalError(TimewebAuthError error) =>
    isA<TimewebAuthException>().having((e) => e.error, 'error', error);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'exact native personal request/hash, created 201 and imported 200; default off',
    () async {
      final request = personalRequest();
      expect(
        request.requestHash,
        sha256.convert(utf8.encode('{"targetUid":"B"}')).toString(),
      );
      for (final created in [true, false]) {
        final wire = PeopleWire((call) async {
          expect(call.method, 'POST');
          expect(call.url.path, '/v1/runtime/personal-chats');
          expect(call.headers['Authorization'], 'Bearer na1.A.first');
          expect(call.followRedirects, isFalse);
          expect(jsonDecode((call as http.Request).body), {
            'operationId': personalId,
            'targetUid': 'B',
          });
          return peopleReply(
            personalEnvelope(request, personalResult(created: created)),
            status: created ? 201 : 200,
          );
        });
        final client = personalClient(wire);
        await client.restore();
        final ref = client.bindMutation(request, expectedOwnerUid: 'A');
        final first = client.mutate(ref), duplicate = client.mutate(ref);
        expect(identical(first, duplicate), isTrue);
        final result = await first;
        expect(result.state, TimewebMutationState.confirmed);
        expect(result.openedPersonalChat!.chatId, importedChatId);
        expect(result.openedPersonalChat!.peerUid, 'B');
        expect(result.openedPersonalChat!.created, created);
        expect(wire.calls, hasLength(1));
        await client.stop();
        expect(
          () => result.openedPersonalChat,
          throwsA(personalError(TimewebAuthError.staleSession)),
        );
      }
      final wire = PeopleWire((_) async => throw StateError('No HTTP'));
      final client = personalClient(wire, enabled: false);
      await client.restore();
      expect(
        () => client.bindMutation(request, expectedOwnerUid: 'A'),
        throwsA(personalError(TimewebAuthError.disabled)),
      );
      expect(
        () => TimewebMutationRequest.openPersonalChat(
          operationId: personalId,
          targetUid: '../A',
        ),
        throwsArgumentError,
      );
      expect(wire.calls, isEmpty);
      await client.stop();
    },
  );

  test(
    'bounded exact receipt rejects peer/revision/status/extra keys and keeps safe refusal outcomes',
    () async {
      for (final invalid in [
        {'peerUid': 'C'},
        {'chatId': ''},
        {'chatRevision': 3},
        {'created': true},
        {'name': 'private'},
      ]) {
        final wire = PeopleWire(
          (_) async => peopleReply(
            personalEnvelope(personalRequest(), {
              ...personalResult(),
              ...invalid,
            }),
          ),
        );
        final client = personalClient(wire);
        await client.restore();
        final result = await client.mutate(
          client.bindMutation(personalRequest(), expectedOwnerUid: 'A'),
        );
        expect(result.state, TimewebMutationState.unknown);
        expect(result.unknownReason, TimewebAuthError.invalidResponse);
        expect(result.canAcknowledge, isFalse);
        await client.stop();
      }
      for (final refusal in [
        (404, 'person_unavailable', TimewebMutationFailure.personUnavailable),
        (409, 'chat_unavailable', TimewebMutationFailure.chatUnavailable),
      ]) {
        final wire = PeopleWire(
          (_) async => peopleReply(
            personalEnvelope(personalRequest(), {
              'error': refusal.$2,
            }, revision: null),
            status: refusal.$1,
          ),
        );
        final client = personalClient(wire);
        await client.restore();
        final result = await client.mutate(
          client.bindMutation(personalRequest(), expectedOwnerUid: 'A'),
        );
        expect(result.state, TimewebMutationState.declaredFailure);
        expect(result.failure, refusal.$3);
        expect(result.canAcknowledge, isTrue);
        await client.stop();
      }
      final wire = PeopleWire((_) async => peopleReply({}, length: 65537));
      final client = personalClient(wire);
      await client.restore();
      final result = await client.mutate(
        client.bindMutation(personalRequest(), expectedOwnerUid: 'A'),
      );
      expect(result.state, TimewebMutationState.unknown);
      expect(result.canAcknowledge, isFalse);
      await client.stop();
    },
  );

  test(
    'durable original/double tap → lost ACK restart → not_found lookup only → imported real chat',
    () async {
      final root = await Directory.systemTemp.createTemp('personal-chat-');
      TimewebMutationRequest? original;
      var absent = true;
      final wire = PeopleWire((call) async {
        if (call.method == 'POST') {
          final body = jsonDecode((call as http.Request).body);
          original = personalRequest(body['operationId']);
          final data = jsonDecode(
            await personalFiles(root).single.readAsString(),
          );
          expect(data['targetUid'], 'B');
          expect(data['uid'], 'A');
          expect(data['operationId'], body['operationId']);
          expect(data['requestHash'], original!.requestHash);
          expect(
            data.keys,
            unorderedEquals([
              'version',
              'origin',
              'uid',
              'targetUid',
              'operation',
              'operationId',
              'requestHash',
            ]),
          );
          return peopleReply({'error': 'outcome_unknown'}, status: 503);
        }
        if (call.url.path.contains('/operations/')) {
          expect(
            call.url.path,
            '/v1/runtime/operations/chat.open-personal.v1/${original!.operationId}',
          );
          expect(call.url.queryParameters, {
            'requestHash': original!.requestHash,
          });
          return peopleReply(
            personalEnvelope(
              original!,
              absent ? null : personalResult(),
              absent: absent,
              replayed: !absent,
            ),
          );
        }
        expect(call.url.path, '/v1/runtime/chats/$importedChatId/messages');
        return peopleReply({
          'kind': 'canonical-current',
          'chatId': importedChatId,
          'chatRevision': 4,
          'ordering': 'sequence_desc',
          'items': [],
          'nextBeforeSequence': null,
        });
      });
      final first = personalRuntime(wire, root);
      try {
        await first.start(remember: true);
        final action = await first.openPersonalChat('B');
        final a = action.submit(), b = action.submit();
        expect(identical(a, b), isTrue);
        expect(await a, TimewebPersonalChatOutcome.unknown);
        action.close();
        await first.stop();
        final next = personalRuntime(wire, root);
        try {
          await next.start(remember: true);
          final recovered = await next.openPersonalChat('B');
          expect(recovered.needsCheck, isTrue);
          expect(() => recovered.submit(), throwsStateError);
          expect(await recovered.check(), TimewebPersonalChatOutcome.unknown);
          expect(personalFiles(root), hasLength(1));
          absent = false;
          expect(await recovered.check(), TimewebPersonalChatOutcome.confirmed);
          expect(personalFiles(root), isEmpty);
          final chat = await next.openPersonalConversation(recovered.receipt!);
          expect(chat.chatId, importedChatId);
          expect(chat.messages, isEmpty);
          recovered.close();
          chat.requireCurrent(); // action close is not session revocation
          expect(
            wire.calls.where((call) => call.method == 'POST'),
            hasLength(1),
          );
          chat.close();
        } finally {
          await next.stop();
        }
      } finally {
        await first.stop();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'A→B cancels original transfer; late A cannot ACK, expose receipt or POST as B',
    () async {
      final root = await Directory.systemTemp.createTemp('personal-owner-');
      final late = Completer<http.StreamedResponse>();
      TimewebMutationRequest? original;
      http.AbortableRequest? transfer;
      final wire = PeopleWire((call) async {
        if (call.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        transfer = call as http.AbortableRequest;
        original = personalRequest(jsonDecode(transfer!.body)['operationId']);
        return late.future;
      });
      final runtime = personalRuntime(wire, root);
      try {
        await runtime.start(remember: true);
        final action = await runtime.openPersonalChat('B');
        final flight = action.submit();
        final expected = expectLater(
          flight,
          throwsA(personalError(TimewebAuthError.staleSession)),
        );
        await personalTick(() => original != null);
        var aborted = false;
        transfer!.abortTrigger!.then((_) => aborted = true);
        await runtime.login(
          email: 'b@example.invalid',
          password: 'synthetic-password',
        );
        await personalTick(() => aborted);
        late.complete(
          peopleReply(personalEnvelope(original!, personalResult())),
        );
        await expected;
        expect(
          () => action.receipt,
          throwsA(
            isA<AppSessionException>().having(
              (e) => e.error,
              'error',
              AppSessionError.staleSession,
            ),
          ),
        );
        expect(personalFiles(root), hasLength(1));
        final other = await runtime.openPersonalChat('C');
        expect(other.needsCheck, isFalse);
        other.close();
        expect(
          wire.calls.where(
            (call) => call.url.path == '/v1/runtime/personal-chats',
          ),
          hasLength(1),
        );
      } finally {
        if (!late.isCompleted) late.complete(peopleReply({}, status: 503));
        await runtime.stop();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'stop aborts and waits real transfer drain; unresolved original remains durable',
    () async {
      final root = await Directory.systemTemp.createTemp('personal-stop-');
      final late = Completer<http.StreamedResponse>();
      final wire = PeopleWire((_) => late.future);
      final runtime = personalRuntime(wire, root);
      try {
        await runtime.start(remember: true);
        final action = await runtime.openPersonalChat('B');
        final flight = action.submit();
        final expected = expectLater(
          flight,
          throwsA(personalError(TimewebAuthError.staleSession)),
        );
        await personalTick(() => wire.calls.isNotEmpty);
        var drained = false;
        final stop = runtime.stop().then((value) {
          drained = true;
          return value;
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(drained, isFalse);
        late.complete(peopleReply({}, status: 503));
        await expected;
        expect(await stop, isTrue);
        expect(personalFiles(root), hasLength(1));
      } finally {
        if (!late.isCompleted) late.complete(peopleReply({}, status: 503));
        await runtime.stop();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'closed action late confirmed ACK cannot bypass fresh personal lookup refusal/503',
    () async {
      final root = await Directory.systemTemp.createTemp('personal-fresh-');
      final late = Completer<http.StreamedResponse>();
      TimewebMutationRequest? original;
      var unavailable = true;
      final wire = PeopleWire((call) async {
        if (call.method == 'POST') {
          original = personalRequest(
            jsonDecode((call as http.Request).body)['operationId'],
          );
          return late.future;
        }
        return unavailable
            ? peopleReply({'error': 'unavailable'}, status: 503)
            : peopleReply({'error': 'person_unavailable'}, status: 404);
      });
      final runtime = personalRuntime(wire, root);
      try {
        await runtime.start(remember: true);
        final first = await runtime.openPersonalChat('B');
        final submitted = first.submit();
        final expected = expectLater(submitted, throwsStateError);
        await personalTick(() => original != null);
        first.close();
        late.complete(
          peopleReply(personalEnvelope(original!, personalResult())),
        );
        await expected;
        final reopened = await runtime.openPersonalChat('B');
        expect(await reopened.check(), TimewebPersonalChatOutcome.unknown);
        expect(reopened.receipt, isNull);
        expect(personalFiles(root), hasLength(1));
        unavailable = false;
        expect(await reopened.check(), TimewebPersonalChatOutcome.unknown);
        expect(reopened.failure, TimewebMutationFailure.personUnavailable);
        expect(personalFiles(root), hasLength(1));
        expect(reopened.needsCheck, isTrue);
        expect(reopened.receipt, isNull);
        expect(wire.calls.where((call) => call.method == 'POST'), hasLength(1));
        reopened.close();
      } finally {
        if (!late.isCompleted) late.complete(peopleReply({}, status: 503));
        await runtime.stop();
        await root.delete(recursive: true);
      }
    },
  );
}
