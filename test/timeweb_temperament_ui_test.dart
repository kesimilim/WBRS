import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/test/red_group.dart';
import 'package:wbrs/presentation/screens/test/timeweb_temperament_page.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_temperament_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

final _now = DateTime.utc(2026, 10, 2);
const _stamp = '2026-10-02T12:00:00.000001Z';
const _nextStamp = '2026-10-02T12:00:00.000002Z';

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

http.StreamedResponse _reply(Object body) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  200,
  headers: {'content-type': 'application/json', 'cache-control': 'no-store'},
);
Map<String, dynamic> _full(bool complete) => {
  'uid': 'A',
  'profileExists': true,
  'onboarding': complete ? 'search' : 'test',
  'profileAuthority': 'canonical-current-v1',
  'mediaReady': false,
  'profile': {
    'fullName': 'Current A',
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
    'primaryGroup': complete ? 'белая' : null,
    'secondaryGroup': null,
    'profileDetailsSaved': true,
    'isRegistrationEnd': complete,
    'updatedAt': complete ? _nextStamp : _stamp,
  },
};
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  var settled = false;
  final original = runtime.stop().then((value) {
    settled = true;
    return value;
  });
  await _until(tester, () => settled);
  expect(await original, isTrue);
}

void main() {
  testWidgets(
    'saved native profile reuses 80questions, minimum20 and tie counts; server group rereads own profile',
    (tester) async {
      expect(AppBackend.timewebTemperamentEnabled, isFalse);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-temperament-ui-'),
      ))!;
      var complete = false, posts = 0, fullReads = 0;
      final wire = _Wire((request) async {
        if (request.method == 'GET') {
          expect(request.url.path, '/v1/runtime/me/full-profile');
          fullReads++;
          return _reply(_full(complete));
        }
        expect(request.url.path, '/v1/runtime/me/temperament');
        posts++;
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(body['expectedUpdatedAt'], _stamp);
        expect(body['scores'], {'brown': 5, 'red': 5, 'blue': 5, 'white': 5});
        final operation = TimewebMutationRequest.completeOwnTemperament(
          operationId: body['operationId'],
          expectedUpdatedAt: body['expectedUpdatedAt'],
          scores: TimewebTemperamentScores(brown: 5, red: 5, blue: 5, white: 5),
        );
        final files = directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.json'))
            .toList();
        expect(files, hasLength(1));
        final durable =
            jsonDecode(files.single.readAsStringSync()) as Map<String, dynamic>;
        expect(durable['operationId'], operation.operationId);
        expect(durable['answers'], List<bool>.generate(80, (i) => i % 20 < 5));
        complete = true;
        return _reply({
          'operation': operation.operation,
          'operationId': operation.operationId,
          'requestHash': operation.requestHash,
          'state': 'committed',
          'replayed': false,
          'entityRevision': null,
          'result': {
            'uid': 'A',
            'primaryGroup': 'белая',
            'isRegistrationEnd': true,
            'onboarding': 'search',
            'updatedAt': _nextStamp,
            'profileAuthority': 'canonical-current-v1',
          },
        });
      });
      final runtime = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: _Store(),
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        transport: wire,
        clock: () => _now,
        currentOwnProfileEnabled: true,
        currentTemperamentEnabled: true,
        profileEditorEnabled: false,
        temperamentJournal: TimewebTemperamentJournal(
          directory: () async => directory,
        ),
      );
      await tester.binding.setSurfaceSize(const Size(360, 640));
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebSessionGate(runtime: runtime),
          ),
        );
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-open-temperament'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('timeweb-open-temperament')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(
          find.byKey(const ValueKey('timeweb-open-temperament')),
        );
        await _until(
          tester,
          () => find.byType(TimewebTemperamentPage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.byType(FirstGroupRed), findsOneWidget);
        expect(find.byKey(const ValueKey('question-79')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('questionnaire-submit')),
          findsNothing,
        );
        final indexes = [
          for (var g = 0; g < 4; g++)
            for (var n = 0; n < 5; n++) g * 10 + n,
        ];
        for (final index in indexes.take(19)) {
          tester
              .widget<IconButton>(find.byKey(ValueKey('question-$index')))
              .onPressed!();
          await tester.pump();
        }
        expect(
          find.byKey(const ValueKey('questionnaire-submit')),
          findsNothing,
        );
        expect(
          find.text('Выберите минимум 20 утверждений, чтобы завершить тест'),
          findsOneWidget,
        );
        tester
            .widget<IconButton>(
              find.byKey(ValueKey('question-${indexes.last}')),
            )
            .onPressed!();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('questionnaire-submit')),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('questionnaire-submit')),
              )
              .onPressed!();
          for (var i = 0; i < 100 && posts == 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        });
        await _until(
          tester,
          () =>
              fullReads == 2 &&
              find.byType(TimewebTemperamentPage).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
        expect(posts, 1);
        expect(find.text('Тест завершён'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('timeweb-open-temperament')),
          findsNothing,
        );
        expect(find.text('белая'), findsAtLeastNWidgets(1));
        expect(Firebase.apps, isEmpty);
        expect(tester.takeException(), isNull);
        expect(
          directory
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('.json')),
          isEmpty,
        );
      } finally {
        await tester.binding.setSurfaceSize(null);
        await tester.pumpWidget(const SizedBox());
        await _stop(tester, runtime);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
