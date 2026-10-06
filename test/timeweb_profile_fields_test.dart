import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/edit_profile/timeweb_profile_edit_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_profile_edit_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

const _origin = 'https://api.example.invalid';
const _stamp = '2026-10-02T12:00:00.000001Z';
const _nextStamp = '2026-10-02T12:00:00.000002Z';
const _uuid = '12345678-1234-4234-8234-123456789abc';
final _now = DateTime.utc(2026, 10, 2);

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = TimewebSession(
    uid: 'A',
    emailVerified: true,
    accessToken: 'na1.synthetic-A',
    refreshToken: 'nr1.synthetic-A',
    accessExpiresAt: _now.add(const Duration(minutes: 15)),
    refreshExpiresAt: _now.add(const Duration(days: 14)),
  );
  @override
  Future<TimewebSession?> read() async => value;
  @override
  Future<void> write(TimewebSession session) async => value = session;
  @override
  Future<void> clear() async => value = null;
}

class _Wire extends http.BaseClient {
  _Wire(this.handle);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handle(request);
  }
}

http.StreamedResponse _reply(Object body) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  200,
  headers: {'content-type': 'application/json', 'cache-control': 'no-store'},
);

Map<String, dynamic> _profile() => {
  'fullName': 'Current A',
  'age': 0,
  'rost': null,
  'about': 'old',
  'hobbi': null,
  'deti': null,
  'pol': 'historical gender',
  'relationStatus': 'historical relation',
  'profileDetailsSaved': false,
  'isRegistrationEnd': false,
  'updatedAt': _stamp,
};

Map<String, dynamic> _view() => {
  'uid': 'A',
  'profile': _profile(),
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

TimewebMutationRequest _request(Map<String, dynamic> body) {
  final changes = body['changes'] as Map<String, dynamic>;
  return TimewebMutationRequest.editOwnProfile(
    operationId: body['operationId'],
    expectedUpdatedAt: body['expectedUpdatedAt'],
    changes: TimewebProfileChanges(
      fullName: changes['fullName'],
      age: changes['age'],
      rost: changes['rost'],
      about: changes['about'],
      hobbi: changes['hobbi'],
      deti: changes['deti'],
      pol: changes['pol'],
      relationStatus: changes['relationStatus'],
    ),
  );
}

Map<String, dynamic> _receipt(
  TimewebMutationRequest operation,
  Map<String, dynamic>? profile,
) => {
  'operation': operation.operation,
  'operationId': operation.operationId,
  'requestHash': operation.requestHash,
  'state': profile == null ? 'not_found' : 'committed',
  'replayed': profile != null,
  'result': profile == null
      ? null
      : {
          'uid': 'A',
          'profile': profile,
          'operationId': operation.operationId,
          'profileAuthority': 'canonical-current-v1',
        },
  'entityRevision': null,
};

List<File> _journals(Directory directory) => directory
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.json'))
    .toList();

TimewebAppRuntime _runtime(_Store store, _Wire wire, Directory directory) =>
    TimewebAppRuntime(
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
      profileEditJournal: TimewebProfileEditJournal(
        directory: () async => directory,
      ),
    );

Future<void> _waitFor(WidgetTester tester, bool Function() completed) async {
  for (var i = 0; i < 100 && !completed(); i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
  expect(completed(), isTrue);
}

void main() {
  test(
    'all eight typed fields survive lost ACK and lookup-only restart',
    () async {
      final directory = await Directory.systemTemp.createTemp('clrs-fields-');
      final store = _Store();
      final changes = <String, Object>{
        'fullName': '  New A  ',
        'age': 30,
        'rost': 175,
        'about': '  A description longer than twenty characters  ',
        'hobbi': '  Interests longer than twenty characters  ',
        'deti': false,
        'pol': 'м',
        'relationStatus': 'свободен',
      };
      var posts = 0;
      var committed = false;
      TimewebMutationRequest? operation;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/runtime/me/profile' &&
            request.method == 'GET') {
          return _reply(_view());
        }
        if (request.method == 'POST') {
          posts++;
          final body =
              jsonDecode((request as http.Request).body)
                  as Map<String, dynamic>;
          expect(body['expectedUpdatedAt'], _stamp);
          expect(body['changes'], changes);
          operation = _request(body);
          final durable = jsonDecode(
            _journals(directory).single.readAsStringSync(),
          );
          expect(durable['version'], 1);
          expect(durable['changes'], changes);
          expect(durable['changes']['age'], isA<int>());
          expect(durable['changes']['rost'], isA<int>());
          expect(durable['changes']['deti'], isA<bool>());
          expect(durable['requestHash'], operation!.requestHash);
          expect(durable['operationId'], operation!.operationId);
          throw const SocketException('Synthetic lost ACK');
        }
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/v1/runtime/operations/profile.edit.v1/${operation!.operationId}',
        );
        expect(request.url.queryParameters, {
          'requestHash': operation!.requestHash,
        });
        return _reply(
          _receipt(
            operation!,
            committed
                ? (_profile()
                    ..addAll(changes)
                    ..['updatedAt'] = _nextStamp)
                : null,
          ),
        );
      });
      final first = _runtime(store, wire, directory);
      TimewebAppRuntime? restarted;
      try {
        await first.start(remember: true);
        final flow = await first.openProfileEditor();
        final original = flow.save(
          fullName: changes['fullName'] as String,
          age: 30,
          rost: 175,
          about: changes['about'] as String,
          hobbi: changes['hobbi'] as String,
          deti: false,
          pol: 'м',
          relationStatus: 'свободен',
        );
        expect(
          identical(
            original,
            flow.save(fullName: 'ignored', about: 'old', hobbi: ''),
          ),
          isTrue,
        );
        expect(await original, TimewebProfileEditOutcome.unknown);
        final durable = _journals(directory).single.readAsStringSync();
        expect(durable, isNot(contains('na1.synthetic-A')));
        expect(durable, isNot(contains('refreshToken')));
        flow.close();
        expect(await first.stop(), isTrue);
        restarted = _runtime(store, wire, directory);
        await restarted.start(remember: true);
        final recovered = await restarted.openProfileEditor();
        expect(recovered.fullName, changes['fullName']);
        expect(recovered.age, 30);
        expect(recovered.rost, 175);
        expect(recovered.deti, isFalse);
        expect(recovered.pol, 'м');
        expect(recovered.relationStatus, 'свободен');
        expect(
          () => recovered.save(fullName: 'new', about: 'old', hobbi: ''),
          throwsStateError,
        );
        expect(await recovered.check(), TimewebProfileEditOutcome.unknown);
        expect(_journals(directory).single.readAsStringSync(), durable);
        expect(posts, 1);
        committed = true;
        expect(await recovered.check(), TimewebProfileEditOutcome.confirmed);
        expect(_journals(directory), isEmpty);
        expect(posts, 1);
        recovered.close();
      } finally {
        await first.stop();
        await restarted?.stop();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'old v1 text intent loads; wrong types, bounds and extra fields fail closed',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-v1-fields-',
      );
      final store = _Store();
      final operation = TimewebMutationRequest.editOwnProfile(
        operationId: _uuid,
        expectedUpdatedAt: _stamp,
        changes: TimewebProfileChanges(fullName: 'Old v1 name'),
      );
      final folder = Directory('${directory.path}/clrs_native_profile_edits');
      await folder.create();
      final digest = sha256.convert(utf8.encode('$_origin\u0000A'));
      final file = File('${folder.path}/$digest.json');
      final intent = <String, Object>{
        'version': 1,
        'origin': _origin,
        'uid': 'A',
        'operation': 'profile.edit.v1',
        'operationId': _uuid,
        'expectedUpdatedAt': _stamp,
        'changes': {'fullName': 'Old v1 name'},
        'requestHash': operation.requestHash,
      };
      var lookups = 0;
      final wire = _Wire((request) async {
        expect(request.method, 'GET');
        if (request.url.path == '/v1/runtime/me/profile') {
          return _reply(_view());
        }
        lookups++;
        expect(
          request.url.path,
          '/v1/runtime/operations/profile.edit.v1/$_uuid',
        );
        expect(request.url.queryParameters, {
          'requestHash': operation.requestHash,
        });
        return _reply(_receipt(operation, null));
      });
      final runtime = _runtime(store, wire, directory);
      try {
        await file.writeAsString(jsonEncode(intent), flush: true);
        await runtime.start(remember: true);
        final restored = await runtime.openProfileEditor();
        expect(restored.fullName, 'Old v1 name');
        expect(restored.age, 0);
        expect(restored.rost, isNull);
        expect(restored.deti, isNull);
        expect(restored.about, 'old');
        expect(restored.hobbi, '');
        expect(restored.pol, 'historical gender');
        expect(await restored.check(), TimewebProfileEditOutcome.unknown);
        restored.close();
        for (final invalid in [
          {'age': '30'},
          {'age': 30.0},
          {'age': null},
          {'age': 17},
          {'rost': 301},
          {'deti': 0},
          {'deti': 'false'},
          {'fullName': true},
          {'pol': 1},
          {'relationStatus': false},
          {'isRegistrationEnd': true},
        ]) {
          await file.writeAsString(
            jsonEncode({...intent, 'changes': invalid}),
            flush: true,
          );
          await expectLater(runtime.openProfileEditor(), throwsFormatException);
        }
        await file.writeAsString(
          jsonEncode({...intent, 'version': 1.0}),
          flush: true,
        );
        await expectLater(runtime.openProfileEditor(), throwsFormatException);
        await file.writeAsString('x' * 65537, flush: true);
        await expectLater(runtime.openProfileEditor(), throwsFormatException);
        expect(lookups, 1);
        expect(wire.calls.where((call) => call.method == 'POST'), isEmpty);
      } finally {
        await runtime.stop();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'original three-field save preserves nullable, short and historical values',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-preserved-fields-',
      );
      final wire = _Wire((request) async {
        if (request.method == 'GET') return _reply(_view());
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(body['changes'], {'fullName': 'New A'});
        return _reply(
          _receipt(
            _request(body),
            _profile()
              ..['fullName'] = 'New A'
              ..['updatedAt'] = _nextStamp,
          ),
        );
      });
      final runtime = _runtime(_Store(), wire, directory);
      try {
        await runtime.start(remember: true);
        final flow = await runtime.openProfileEditor();
        expect(
          flow.hasChanges(fullName: 'Current A', about: 'old', hobbi: ''),
          isFalse,
        );
        expect(
          flow.hasChanges(
            fullName: 'Current A',
            about: 'old',
            hobbi: '',
            age: 0,
          ),
          isFalse,
        );
        expect(
          await flow.save(fullName: 'New A', about: 'old', hobbi: ''),
          TimewebProfileEditOutcome.confirmed,
        );
        expect(_journals(directory), isEmpty);
        expect(wire.calls.where((call) => call.method == 'POST'), hasLength(1));
        flow.close();
      } finally {
        await runtime.stop();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    '360px form validates numbers, preserves null children until chosen, saves mixed types',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-fields-ui-'),
      ))!;
      final ack = Completer<http.StreamedResponse>();
      Map<String, dynamic>? sent;
      var posts = 0;
      final wire = _Wire((request) async {
        if (request.method == 'GET') return _reply(_view());
        posts++;
        sent =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        return ack.future;
      });
      final runtime = _runtime(_Store(), wire, directory);
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        // Journal IO and facade callbacks cross the widget's FakeAsync zone.
        // Observe the original open while pumping its queued callbacks.
        TimewebProfileEditFlow? flow;
        final opening = runtime.openProfileEditor().then(
          (value) => flow = value,
        );
        await _waitFor(tester, () => flow != null);
        await opening;
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async =>
                      result = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => TimewebProfileEditPage(flow: flow!),
                        ),
                      ),
                  child: const Text('Open editor'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        final children = find.byKey(const ValueKey('timeweb-profile-children'));
        expect(
          tester.widget<DropdownButtonFormField<bool>>(children).initialValue,
          isNull,
        );
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-age')),
          '17',
        );
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-height')),
          '301',
        );
        final save = find.byKey(const ValueKey('timeweb-profile-save'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pump();
        expect(posts, 0);
        expect(
          find.text('Возраст должен быть от 18 до 100 лет'),
          findsOneWidget,
        );
        expect(find.text('Укажите корректный рост.'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-name')),
          'New UI A',
        );
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-age')),
          '30',
        );
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-height')),
          '175',
        );
        await tester.ensureVisible(children);
        await tester.tap(children);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Нет').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(save);
        await tester.tap(save);
        await _waitFor(tester, () => posts == 1);
        expect(sent!['expectedUpdatedAt'], _stamp);
        expect(sent!['changes'], {
          'fullName': 'New UI A',
          'age': 30,
          'rost': 175,
          'deti': false,
        });
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('timeweb-profile-age')),
              )
              .enabled,
          isFalse,
        );
        expect(
          tester.widget<DropdownButtonFormField<bool>>(children).onChanged,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          ack.complete(
            _reply(
              _receipt(
                _request(sent!),
                _profile()
                  ..addAll(sent!['changes'])
                  ..['updatedAt'] = _nextStamp,
              ),
            ),
          );
        });
        await _waitFor(tester, () => result == true);
        await tester.pumpAndSettle();
        expect(find.byType(TimewebProfileEditPage), findsNothing);
        expect(find.text('Профиль сохранён'), findsOneWidget);
        expect(_journals(directory), isEmpty);
        expect(posts, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!ack.isCompleted) {
          ack.complete(_reply({}));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        var stopped = false;
        final stopping = runtime.stop().then((_) => stopped = true);
        await _waitFor(tester, () => stopped);
        await stopping;
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets(
    '360px location hook hides by default, blocks drafts, preserves cancel and closes on confirmed save',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-location-hook-'),
      ))!;
      final wire = _Wire((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/runtime/me/profile');
        return _reply(_view());
      });
      final runtime = _runtime(_Store(), wire, directory);
      final pendingChoice = Completer<bool?>();
      var supplied = false;
      var calls = 0;
      bool? routeResult;
      Future<bool?> chooseLocation(BuildContext editorContext) async {
        expect(editorContext.mounted, isTrue);
        expect(ModalRoute.of(editorContext)?.isCurrent, isTrue);
        calls++;
        return switch (calls) {
          1 => null,
          2 => false,
          _ => pendingChoice.future,
        };
      }

      final location = find.byKey(const ValueKey('timeweb-profile-location'));
      Future<void> openEditor() async {
        await tester.tap(find.text('Open editor'));
        await _waitFor(
          tester,
          () => find.byType(TimewebProfileEditPage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
      }

      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    final flow = await runtime.openProfileEditor();
                    if (!context.mounted) return;
                    routeResult = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => TimewebProfileEditPage(
                          flow: flow,
                          onEditLocation: supplied ? chooseLocation : null,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open editor'),
                ),
              ),
            ),
          ),
        );
        await openEditor();
        expect(location, findsNothing);
        await tester.pageBack();
        await tester.pumpAndSettle();

        supplied = true;
        await openEditor();
        expect(location, findsOneWidget);
        expect(tester.widget<TextButton>(location).onPressed, isNotNull);
        for (final field in [
          ('timeweb-profile-name', 'Current A'),
          ('timeweb-profile-age', '0'),
          ('timeweb-profile-height', ''),
          ('timeweb-profile-about', 'old'),
          ('timeweb-profile-interests', ''),
        ]) {
          final finder = find.byKey(ValueKey(field.$1));
          // Invalid numeric drafts must disable navigation without parsing or
          // rewriting the text, just like a valid but unsaved text change.
          await tester.enterText(finder, 'bad');
          await tester.pump();
          expect(tester.widget<TextButton>(location).onPressed, isNull);
          expect(tester.widget<TextFormField>(finder).controller!.text, 'bad');
          await tester.enterText(finder, field.$2);
          await tester.pump();
          expect(tester.widget<TextButton>(location).onPressed, isNotNull);
        }
        final children = find.byKey(const ValueKey('timeweb-profile-children'));
        await tester.ensureVisible(children);
        await tester.tap(children);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Нет').last);
        await tester.pumpAndSettle();
        expect(tester.widget<TextButton>(location).onPressed, isNull);
        expect(calls, 0);
        await tester.pageBack();
        await tester.pumpAndSettle();

        await openEditor();
        await tester.ensureVisible(location);
        await tester.tap(location);
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.byType(TimewebProfileEditPage), findsOneWidget);
        expect(tester.widget<TextButton>(location).onPressed, isNotNull);
        expect(find.text('Current A'), findsOneWidget);
        await tester.tap(location);
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(find.byType(TimewebProfileEditPage), findsOneWidget);
        expect(tester.widget<TextButton>(location).onPressed, isNotNull);
        await tester.tap(location);
        await tester.pump();
        expect(calls, 3);
        expect(tester.widget<TextButton>(location).onPressed, isNull);
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('timeweb-profile-name')),
              )
              .enabled,
          isFalse,
        );
        expect(
          tester.widget<DropdownButtonFormField<bool>>(children).onChanged,
          isNull,
        );
        expect(
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('timeweb-profile-save')),
              )
              .onPressed,
          isNull,
        );
        // Interactive route lifetime is not the network request deadline.
        await tester.pump(const Duration(seconds: 30));
        expect(tester.widget<TextButton>(location).onPressed, isNull);
        expect(
          find.text(
            'Результат пока не подтверждён. Нажмите «Проверить результат».',
          ),
          findsNothing,
        );
        pendingChoice.complete(true);
        await _waitFor(tester, () => routeResult == true);
        await tester.pumpAndSettle();
        expect(find.byType(TimewebProfileEditPage), findsNothing);
        expect(calls, 3);
        expect(
          wire.calls.where((request) => request.method == 'POST'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!pendingChoice.isCompleted) pendingChoice.complete(null);
        await tester.pumpWidget(const SizedBox.shrink());
        var stopped = false;
        final stopping = runtime.stop().then((_) => stopped = true);
        await _waitFor(tester, () => stopped);
        await stopping;
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets(
    '360px null gender correction retains original after lost ACK and preserves fixed gender',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-null-gender-ui-'),
      ))!;
      final current = _profile()..['pol'] = null;
      TimewebMutationRequest? original;
      var posts = 0, lookups = 0;
      final wire = _Wire((request) async {
        expect(request.headers['authorization'], 'Bearer na1.synthetic-A');
        if (request.url.path.contains('/operations/')) {
          lookups++;
          expect(
            request.url.path.endsWith('/${original!.operationId}'),
            isTrue,
          );
          expect(
            request.url.queryParameters['requestHash'],
            original!.requestHash,
          );
          expect(_journals(directory), hasLength(1));
          return _reply(_receipt(original!, current));
        }
        if (request.method == 'GET') {
          return _reply({..._view(), 'profile': current});
        }
        posts++;
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(body['expectedUpdatedAt'], posts == 1 ? _stamp : _nextStamp);
        expect(_journals(directory), hasLength(1));
        if (posts == 1) {
          expect(body['changes'], {'pol': 'ж'});
          original = _request(body);
          current['pol'] = 'ж';
          current['updatedAt'] = _nextStamp;
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"error":"outcome_unknown"}')),
            503,
            headers: {
              'content-type': 'application/json',
              'cache-control': 'no-store',
            },
          );
        }
        expect(body['changes'], {'fullName': 'Corrected A'});
        current['fullName'] = 'Corrected A';
        current['updatedAt'] = '2026-10-02T12:00:00.000003Z';
        return _reply(_receipt(_request(body), current));
      });
      final store = _Store();
      var runtime = _runtime(store, wire, directory);
      TimewebProfileEditFlow? opened;
      bool? routeResult;
      final gender = find.byKey(const ValueKey('timeweb-profile-gender'));
      final location = find.byKey(const ValueKey('timeweb-profile-location'));
      final save = find.byKey(const ValueKey('timeweb-profile-save'));
      Future<void> openEditor() async {
        routeResult = null;
        await tester.tap(find.text('Open editor'));
        await _waitFor(
          tester,
          () => find.byType(TimewebProfileEditPage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
      }

      Future<void> stopRuntime() async {
        var stopped = false;
        final stopping = runtime.stop().then((_) => stopped = true);
        await _waitFor(tester, () => stopped);
        await stopping;
      }

      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    opened = await runtime.openProfileEditor();
                    if (!context.mounted) return;
                    routeResult = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => TimewebProfileEditPage(
                          flow: opened!,
                          onEditLocation: (_) async => null,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open editor'),
                ),
              ),
            ),
          ),
        );
        await openEditor();
        expect(opened!.canSetGender, isTrue);
        expect(
          tester.widget<DropdownButtonFormField<String>>(gender).initialValue,
          isNull,
        );
        expect(tester.widget<TextButton>(location).onPressed, isNotNull);
        expect(posts, 0);
        await tester.ensureVisible(gender);
        await tester.tap(gender);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Женский').last);
        await tester.pumpAndSettle();
        expect(tester.widget<TextButton>(location).onPressed, isNull);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await _waitFor(
          tester,
          () =>
              posts == 1 &&
              tester.widget<ElevatedButton>(save).onPressed != null,
        );
        expect(opened!.needsCheck, isTrue);
        expect(
          tester.widget<DropdownButtonFormField<String>>(gender).onChanged,
          isNull,
        );
        expect(current['profileDetailsSaved'], isFalse);
        expect(current['isRegistrationEnd'], isFalse);
        expect(current['age'], 0);
        expect(current['rost'], isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await stopRuntime();
        expect(() => opened!.canSetGender, throwsStateError);
        runtime = _runtime(store, wire, directory);
        await tester.runAsync(() => runtime.start(remember: true));
        await openEditor();
        expect(opened!.needsCheck, isTrue);
        expect(opened!.pol, 'ж');
        expect(
          opened!.canSetGender,
          isFalse,
        ); // Fresh canonical value is now fixed.
        expect(gender, findsNothing);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await _waitFor(tester, () => routeResult == true);
        await tester.pumpAndSettle();
        expect(posts, 1);
        expect(lookups, 1);
        expect(
          _journals(directory),
          isEmpty,
        ); // Disk ACK precedes the successful return.
        await openEditor();
        expect(gender, findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-name')),
          'Corrected A',
        );
        await tester.ensureVisible(save);
        await tester.tap(save);
        await _waitFor(tester, () => routeResult == true);
        await tester.pumpAndSettle();
        expect(posts, 2);
        expect(current['pol'], 'ж');
        expect(current['relationStatus'], 'historical relation');
        expect(current['profileDetailsSaved'], isFalse);
        expect(current['isRegistrationEnd'], isFalse);
        expect(_journals(directory), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await stopRuntime();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
