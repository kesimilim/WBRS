import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_push_coordinator.dart';
import 'package:wbrs/service/timeweb_push_flow.dart';
import 'support/timeweb_people_fixtures.dart';

const sidA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const sidR = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const sidB = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const token1 = 'fixture-current-fcm-token-111111';
const token2 = 'fixture-current-fcm-token-222222';
TimewebSession _session(String uid, String sid) => TimewebSession(
  uid: uid,
  emailVerified: true,
  accessToken: 'na1.$sid.secret',
  refreshToken: 'nr1.$sid.secret',
  accessExpiresAt: peopleNow.add(const Duration(minutes: 15)),
  refreshExpiresAt: peopleNow.add(const Duration(days: 14)),
);
Map<String, dynamic> _tokens(String uid, String sid) => {
  ...peopleTokens(uid),
  'accessToken': 'na1.$sid.secret',
  'refreshToken': 'nr1.$sid.secret',
};
Map<String, dynamic> _envelope(
  TimewebMutationRequest request,
  String sid, {
  bool found = true,
  bool register = true,
  bool replayed = true,
  String? error,
}) => {
  'operation': request.operation,
  'operationId': request.operationId,
  'requestHash': request.requestHash,
  'state': found ? 'committed' : 'not_found',
  'replayed': found ? replayed : false,
  'entityRevision': null,
  'result': found
      ? error != null
            ? {'error': error}
            : {
                'kind': 'canonical-native-push',
                'sessionId': sid,
                register ? 'registered' : 'revoked': true,
              }
      : null,
};
Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}

void main() {
  test(
    'durable original push, restart lookup/not-found, refresh, late A-to-B and revoke',
    () async {
      final folder = await Directory.systemTemp.createTemp('native-push-');
      final store = PeopleStore()..value = _session('A', sidA);
      final events = StreamController<String>.broadcast();
      final originals = <String, TimewebMutationRequest>{};
      final originalSid = <String, String>{};
      final late = Completer<http.StreamedResponse>();
      var lost = true,
          missing = true,
          hold = false,
          held = false,
          posts = 0,
          gets = 0;
      String? serverUid, serverSid, serverToken;
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/auth/refresh')) {
          serverSid = sidR;
          return peopleReply(_tokens('A', sidR));
        }
        if (r.url.path.endsWith('/auth/logout')) {
          serverUid = null;
          serverSid = null;
          serverToken = null;
          return peopleReply({'loggedOut': true});
        }
        if (r.url.path.endsWith('/auth/login')) {
          return peopleReply(_tokens('B', sidB));
        }
        if (r.method == 'POST') {
          posts++;
          final body =
              jsonDecode((r as http.Request).body) as Map<String, dynamic>;
          final sid = r.headers['Authorization']!.split('.')[1];
          final disk = (await Directory(
            '${folder.path}/clrs_native_push',
          ).list().toList()).whereType<File>();
          final saved = [
            for (final file in disk) jsonDecode(await file.readAsString()),
          ];
          expect(
            saved.any(
              (v) =>
                  v['operationId'] == body['operationId'] &&
                  v['acknowledged'] == false,
            ),
            isTrue,
          );
          final register = r.url.path.endsWith('/register');
          expect(
            body.keys.toSet(),
            register ? {'operationId', 'token'} : {'operationId'},
          );
          final action = register
              ? TimewebPushAction.register(sessionId: sid, token: body['token'])
              : TimewebPushAction.revoke(sessionId: sid);
          final request = TimewebMutationRequest.pushToken(
            operationId: body['operationId'],
            action: action,
          );
          originals[request.operationId] = request;
          originalSid[request.operationId] = sid;
          if (hold) {
            held = true;
            return late.future;
          }
          serverUid = sid == sidB ? 'B' : 'A';
          serverSid = sid;
          serverToken = register ? body['token'] : null;
          if (lost) {
            lost = false;
            return peopleReply({'error': 'outcome_unknown'}, status: 503);
          }
          return peopleReply(
            _envelope(request, sid, register: register, replayed: false),
          );
        }
        gets++;
        expect(r.url.pathSegments[r.url.pathSegments.length - 3], 'operations');
        final request = originals[r.url.pathSegments.last]!;
        expect(r.url.queryParameters, {'requestHash': request.requestHash});
        return peopleReply(
          _envelope(
            request,
            originalSid[request.operationId]!,
            found: !missing,
            register: request.kind == TimewebMutationKind.registerPushToken,
          ),
        );
      });
      TimewebAppRuntime create() => TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: store,
        transport: wire,
        deviceId: 'fixture',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        clock: () => peopleNow,
        currentOwnProfileEnabled: true,
        pushJournal: TimewebPushJournal(directory: () async => folder),
      );
      final apps = <TimewebAppRuntime>[];
      TimewebPushCoordinator? coordinator;
      addTearDown(() async {
        coordinator?.close();
        if (!late.isCompleted && originals.isNotEmpty) {
          final op = originals.values.last;
          late.complete(
            peopleReply(
              _envelope(op, originalSid[op.operationId]!, replayed: false),
            ),
          );
        }
        await events.close();
        for (final app in apps) {
          await app.stop();
        }
        await folder.delete(recursive: true);
      });
      var app = create();
      apps.add(app);
      await app.start(remember: true);
      var flow = await app.openPush();
      final first = flow.submit(
        TimewebPushAction.register(sessionId: sidA, token: token1),
      );
      expect(
        identical(
          first,
          flow.submit(
            TimewebPushAction.register(sessionId: sidA, token: token1),
          ),
        ),
        isTrue,
      );
      expect(await first, TimewebPushOutcome.unknown);
      expect(posts, 1);
      final digest = sha256.convert(utf8.encode(token1)).toString();
      expect(
        originals.values.single.requestHash,
        sha256
            .convert(utf8.encode('{"sessionId":"$sidA","tokenHash":"$digest"}'))
            .toString(),
      );
      expect(flow.needsCheck, isTrue);
      final file = (await Directory(
        '${folder.path}/clrs_native_push',
      ).list().toList()).whereType<File>().single;
      final stored = await file.readAsString();
      expect(stored, isNot(contains(token1)));
      expect(stored, isNot(contains('na1.')));
      final original = flow.pendingAction!.payload;
      final originalId = originals.keys.single;
      flow.close();
      await app.stop();
      app = create();
      apps.add(app);
      await app.start(remember: true);
      coordinator = TimewebPushCoordinator(
        runtime: app,
        readToken: () async => token1,
        tokenRefreshes: events.stream,
      );
      await coordinator.synchronize();
      expect(posts, 1);
      expect(gets, 1);
      missing = false;
      await coordinator.synchronize();
      expect(posts, 1);
      expect(gets, 2);
      expect(jsonDecode(await file.readAsString())['acknowledged'], isTrue);
      // A fresh coordinator in the same SID confirms the retained original memo,
      // rather than issuing a duplicate automatic register POST.
      coordinator.close();
      coordinator = TimewebPushCoordinator(
        runtime: app,
        readToken: () async => token1,
        tokenRefreshes: events.stream,
      );
      await coordinator.synchronize();
      expect(posts, 1);
      expect(originals.keys.single, originalId);
      expect(original['sessionId'], sidA);
      coordinator.start();
      await app.session.refresh();
      await _until(() => posts == 2);
      await coordinator.synchronize();
      expect(serverSid, sidR);
      expect(serverToken, token1);
      expect(
        originals.values.last.requestHash,
        isNot(originals.values.first.requestHash),
      );
      final acknowledged = await app.openPush();
      await acknowledged.check();
      final oldReceipt = acknowledged.receipt!;
      acknowledged.close();
      hold = true;
      events.add(token2);
      await _until(() => held);
      await app.session.logout();
      expect(serverUid, isNull);
      expect(serverToken, isNull);
      await app.session.login(
        email: 'B@example.invalid',
        password: 'fixture-password',
        deviceId: 'fixture',
      );
      expect(() => oldReceipt.requireCurrent(), throwsA(isA<Exception>()));
      final lateOp = originals.values.last;
      late.complete(peopleReply(_envelope(lateOp, sidR, replayed: false)));
      hold = false;
      await _until(() => serverUid == 'B');
      await coordinator.synchronize();
      expect(serverSid, sidB);
      expect(serverToken, token1); // late A refresh-token buffer purged
      expect(posts, 4);
      final pendingA = jsonDecode(await file.readAsString());
      expect(pendingA['operationId'], lateOp.operationId);
      expect(pendingA['acknowledged'], isFalse);
      final revoke = await app.openPush();
      expect(revoke.needsCheck, isTrue);
      expect(await revoke.check(), TimewebPushOutcome.confirmed);
      coordinator.close();
      expect(
        await revoke.submit(TimewebPushAction.revoke(sessionId: sidB)),
        TimewebPushOutcome.confirmed,
      );
      expect(revoke.receipt!.registered, isFalse);
      expect(serverToken, isNull);
      expect(posts, 5);
      revoke.close();
      expect(Firebase.apps, isEmpty);
    },
  );
}
