import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/edit_profile/timeweb_profile_edit_page.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_profile_edit_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

final _now = DateTime.utc(2026, 10, 2);
const _stamp = '2026-10-02T12:00:00.000001Z';
const _nextStamp = '2026-10-02T12:00:00.000002Z';
const _origin = 'https://api.example.invalid';
TimewebSession _session(String uid) => TimewebSession(
  uid: uid,
  emailVerified: true,
  accessToken: 'na1.$uid',
  refreshToken: 'nr1.$uid',
  accessExpiresAt: _now.add(const Duration(minutes: 15)),
  refreshExpiresAt: _now.add(const Duration(days: 14)),
);

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = _session('A');
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
Map<String, dynamic> _profile(String uid, {String stamp = _stamp}) => {
  'fullName': 'Current $uid',
  'age': 28,
  'rost': 180,
  'about': 'old',
  'hobbi': null,
  'deti': null,
  'pol': null,
  'relationStatus': null,
  'profileDetailsSaved': false,
  'isRegistrationEnd': false,
  'updatedAt': stamp,
};
Map<String, dynamic> _view(String uid, {String stamp = _stamp}) => {
  'uid': uid,
  'profile': _profile(uid, stamp: stamp),
  'profileExists': true,
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
Map<String, dynamic> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid',
  'refreshToken': 'nr1.$uid',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
TimewebMutationRequest _request(Map<String, dynamic> body) =>
    TimewebMutationRequest.editOwnProfile(
      operationId: body['operationId'],
      expectedUpdatedAt: body['expectedUpdatedAt'],
      changes: TimewebProfileChanges(
        fullName: body['changes']['fullName'],
        about: body['changes']['about'],
        hobbi: body['changes']['hobbi'],
      ),
    );
Map<String, dynamic> _receipt(
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
List<File> _journals(Directory directory) => directory
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.json'))
    .toList();
TimewebAppRuntime _runtime(
  _Store store,
  _Wire wire,
  Directory directory, {
  TimewebProfileEditJournal? journal,
}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse(_origin),
    enabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: store,
  deviceId: 'synthetic-device',
  expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {},
  transport: wire,
  clock: () => _now,
  profileEditJournal:
      journal ?? TimewebProfileEditJournal(directory: () async => directory),
);

// File IO is real; advance UI microtasks without fast-forwarding its deadline
// while waiting for OS callbacks outside the widget runner's FakeAsync zone.
Future<void> _waitForWidget(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
  expect(finder, findsOneWidget);
}

Future<void> _stopRuntime(
  WidgetTester tester,
  TimewebAppRuntime runtime,
) async {
  var settled = false;
  final original = runtime.stop().then((value) {
    settled = true;
    return value;
  });
  for (var i = 0; i < 100 && !settled; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(settled, isTrue);
  expect(await original, isTrue);
}

void main() {
  test(
    'current CAS refusal requires reread; lost ACK survives restart as lookup-only original UUID',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-profile-edit-',
      );
      final store = _Store();
      var stamp = _stamp;
      var posts = 0;
      TimewebMutationRequest? original;
      var lookupConfirmed = false;
      final wire = _Wire((request) async {
        expect(request.url.host, 'api.example.invalid');
        if (request.method == 'GET' &&
            request.url.path == '/v1/runtime/me/profile') {
          return _reply(_view('A', stamp: stamp));
        }
        if (request.method == 'POST' &&
            request.url.path == '/v1/runtime/me/profile') {
          posts++;
          // The exact operation is already durable when transport sees a POST.
          final body =
              jsonDecode((request as http.Request).body)
                  as Map<String, dynamic>;
          final persisted = jsonDecode(
            _journals(directory).single.readAsStringSync(),
          );
          expect(persisted['operationId'], body['operationId']);
          expect(persisted['expectedUpdatedAt'], body['expectedUpdatedAt']);
          expect(persisted['changes'], body['changes']);
          final operation = _request(body);
          expect(persisted['requestHash'], operation.requestHash);
          if (posts == 1) {
            stamp = _nextStamp;
            return _reply(
              _receipt(operation, {
                'error': 'profile_changed',
                'updatedAt': stamp,
              }),
              status: 409,
            );
          }
          original = operation;
          expect(body['changes'], {'fullName': '  New current name  '});
          // A real response can be lost after the server committed.
          throw const SocketException('Synthetic lost ACK');
        }
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/v1/runtime/operations/profile.edit.v1/${original!.operationId}',
        );
        expect(request.url.queryParameters, {
          'requestHash': original!.requestHash,
        });
        if (!lookupConfirmed) {
          return _reply({
            'operation': original!.operation,
            'operationId': original!.operationId,
            'requestHash': original!.requestHash,
            'state': 'not_found',
            'replayed': false,
            'result': null,
            'entityRevision': null,
          });
        }
        return _reply(
          _receipt(original!, {
            'uid': 'A',
            'profile': _profile('A')
              ..['fullName'] = '  New current name  '
              ..['updatedAt'] = _nextStamp,
            'operationId': original!.operationId,
            'profileAuthority': 'canonical-current-v1',
          }, replayed: true),
        );
      });
      final first = _runtime(store, wire, directory);
      try {
        expect(AppBackend.timewebProfileEditorEnabled, isFalse);
        await first.start(remember: true);
        final conflict = await first.openProfileEditor();
        expect(
          await conflict.save(fullName: 'Changed A', about: 'old', hobbi: ''),
          TimewebProfileEditOutcome.rejected,
        );
        expect(conflict.requiresReload, isTrue);
        expect(_journals(directory), isEmpty);
        expect(
          () =>
              conflict.save(fullName: 'Changed again', about: 'old', hobbi: ''),
          throwsStateError,
        );
        conflict.close();
        final uncertain = await first.openProfileEditor();
        final initial = uncertain.save(
          fullName: '  New current name  ',
          about: 'old',
          hobbi: '',
        );
        final duplicate = uncertain.save(
          fullName: 'ignored duplicate',
          about: 'old',
          hobbi: '',
        );
        expect(identical(initial, duplicate), isTrue);
        expect(await initial, TimewebProfileEditOutcome.unknown);
        expect(posts, 2);
        final durableFile = _journals(directory).single;
        final durable = durableFile.readAsStringSync();
        expect(durable, isNot(contains('accessToken')));
        expect(durable, isNot(contains('na1.A')));
        uncertain.close();
        await first.stop();
        // New runtime/process analogue reads the disk UUID, not a RAM reference.
        final restarted = _runtime(store, wire, directory);
        await restarted.start(remember: true);
        final recovered = await restarted.openProfileEditor();
        expect(recovered.needsCheck, isTrue);
        expect(recovered.fullName, '  New current name  ');
        expect(recovered.about, 'old');
        expect(recovered.hobbi, '');
        expect(
          () =>
              recovered.save(fullName: 'replacement', about: 'old', hobbi: ''),
          throwsStateError,
        );
        expect(await recovered.check(), TimewebProfileEditOutcome.unknown);
        expect(_journals(directory).single.readAsStringSync(), durable);
        expect(posts, 2); // not_found never permits another POST.
        lookupConfirmed = true;
        expect(await recovered.check(), TimewebProfileEditOutcome.confirmed);
        expect(_journals(directory), isEmpty);
        expect(posts, 2);
        recovered.close();
        await restarted.stop();
        // Tampering with the original digest fails before mutation/lookup.
        final altered = jsonDecode(durable)..['requestHash'] = '0' * 64;
        await durableFile.writeAsString(jsonEncode(altered), flush: true);
        final damaged = _runtime(store, wire, directory);
        await damaged.start(remember: true);
        await expectLater(damaged.openProfileEditor(), throwsFormatException);
        expect(posts, 2);
        await damaged.stop();
        await durableFile.delete();
        // A new owner cannot start while a stopped owner still writes the
        // original disk intent. That stale flow must never reach transport.
        final io = Completer<Directory>();
        var blockIO = false;
        final draining = _runtime(
          store,
          wire,
          directory,
          journal: TimewebProfileEditJournal(
            directory: () async => blockIO ? io.future : directory,
          ),
        );
        await draining.start(remember: true);
        final oldEditor = await draining.openProfileEditor();
        blockIO = true;
        final oldSave = expectLater(
          oldEditor.save(fullName: 'Must never POST', about: 'old', hobbi: ''),
          throwsA(isA<AppSessionException>()),
        );
        var stopped = false;
        final drain = draining.stop().then((safe) {
          stopped = true;
          return safe;
        });
        await Future<void>.delayed(Duration.zero);
        expect(stopped, isFalse);
        expect(posts, 2);
        io.complete(directory);
        expect(await drain, isTrue);
        await oldSave;
        expect(posts, 2);
        oldEditor.close();
      } finally {
        await first.stop();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'native gate opens current editor; A to B closes fields and quarantines late A POST',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-profile-ui-'),
      ))!;
      final store = _Store();
      final lostAck = Completer<http.StreamedResponse>();
      TimewebMutationRequest? operation;
      var readsA = 0, readsB = 0;
      var posts = 0;
      var currentAbout = 'old';
      var currentStamp = _stamp;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') return _reply(_tokens('B'));
        if (request.method == 'GET') {
          expect(request.url.path, '/v1/runtime/me/profile');
          final uid = request.headers['Authorization'] == 'Bearer na1.B'
              ? 'B'
              : 'A';
          uid == 'A' ? readsA++ : readsB++;
          return _reply(
            _view(uid, stamp: uid == 'A' ? currentStamp : _stamp)
              ..['profile']['about'] = uid == 'A' ? currentAbout : 'old',
          );
        }
        expect(request.url.path, '/v1/runtime/me/profile');
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        posts++;
        operation = _request(body);
        if (posts == 1) {
          expect(body['changes'], {
            'about': '  This updated description has twenty characters  ',
          });
          currentAbout = body['changes']['about'];
          currentStamp = _nextStamp;
          return _reply(
            _receipt(operation!, {
              'uid': 'A',
              'profile': _profile('A', stamp: currentStamp)
                ..['about'] = currentAbout,
              'operationId': operation!.operationId,
              'profileAuthority': 'canonical-current-v1',
            }),
          );
        }
        expect(body['expectedUpdatedAt'], _nextStamp);
        expect(body['changes'], {
          'about': 'Second pending description with enough characters',
        });
        return lostAck.future;
      });
      final runtime = _runtime(store, wire, directory);
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebSessionGate(runtime: runtime),
          ),
        );
        await _waitForWidget(
          tester,
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await tester.pumpAndSettle();
        expect(readsA, 1);
        expect(Firebase.apps, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TimewebProfileEditPage), findsOneWidget);
        expect(find.text('Current A'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-about')),
          '  This updated description has twenty characters  ',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('timeweb-profile-save')),
        );
        await tester.runAsync(() async {
          final button = tester.widget<ElevatedButton>(
            find.byKey(const ValueKey('timeweb-profile-save')),
          );
          button.onPressed!();
          for (var i = 0; i < 100 && posts == 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        });
        await _waitForWidget(
          tester,
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TimewebProfileEditPage), findsNothing);
        expect(find.text('Профиль сохранён'), findsOneWidget);
        ScaffoldMessenger.of(
          tester.element(find.byType(TimewebSessionGate)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
        expect(_journals(directory), isEmpty);
        expect(readsA, 2);
        await tester.tap(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await tester.pumpAndSettle();
        expect(find.text(currentAbout), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-about')),
          'Second pending description with enough characters',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('timeweb-profile-save')),
        );
        await tester.runAsync(() async {
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('timeweb-profile-save')),
              )
              .onPressed!();
          for (var i = 0; i < 100 && posts < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        });
        expect(operation, isNotNull);
        expect(_journals(directory), hasLength(1));
        await tester.runAsync(
          () => runtime.login(
            email: 'B@example.invalid',
            password: 'synthetic password',
          ),
        );
        await _waitForWidget(
          tester,
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TimewebProfileEditPage), findsNothing);
        expect(find.text('Current A'), findsNothing);
        expect(readsB, 1);
        await tester.runAsync(() async {
          lostAck.complete(
            _reply(
              _receipt(operation!, {
                'uid': 'A',
                'profile': _profile('A')
                  ..['about'] =
                      'Second pending description with enough characters',
                'operationId': operation!.operationId,
                'profileAuthority': 'canonical-current-v1',
              }),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pumpAndSettle();
        expect(find.text('Профиль сохранён'), findsNothing);
        expect(
          _journals(directory),
          hasLength(1),
        ); // A only; B cannot retire it.
        expect(
          wire.calls.where(
            (c) => c.method == 'POST' && c.url.path == '/v1/runtime/me/profile',
          ),
          hasLength(2),
        );
        await tester.tap(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Current B'), findsOneWidget);
        expect(find.text('Проверить результат'), findsNothing);
        expect(Firebase.apps, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await _stopRuntime(tester, runtime);
      } finally {
        if (!lostAck.isCompleted) lostAck.complete(_reply({}, status: 503));
        await _stopRuntime(tester, runtime);
        await tester.runAsync(() async {
          await directory.delete(recursive: true);
        });
      }
    },
  );
}
