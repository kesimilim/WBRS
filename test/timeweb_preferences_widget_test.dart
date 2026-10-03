import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/settings/timeweb_account_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_preferences_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/timeweb_people_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  await tester.pump();
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 500));
  for (var i = 0; i < 8 && target.hitTestable().evaluate().isEmpty; i++) {
    final scroll = find.ancestor(of: target, matching: find.byType(Scrollable));
    await tester.drag(
      scroll.last,
      Offset(0, tester.getCenter(target).dy < 0 ? 300 : -300),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pump();
}

Map<String, dynamic> _data({
  int revision = 0,
  bool messages = true,
  bool meetings = false,
  bool sound = true,
}) => {
  'kind': 'native-preferences',
  'messages': messages,
  'meetings': meetings,
  'sound': sound,
  'revision': revision,
  'updatedAt': revision == 0 ? null : peopleStamp,
};
TimewebMutationRequest _request(Map<String, dynamic> body) =>
    TimewebMutationRequest.savePreferences(
      operationId: body['operationId'],
      action: TimewebPreferenceChanges(
        expectedRevision: body['expectedRevision'],
        messages: body['messages'],
        meetings: body['meetings'],
        sound: body['sound'],
      ),
    );
Map<String, dynamic> _receipt(
  Map<String, dynamic> body, {
  required bool found,
  bool replayed = true,
}) {
  final op = _request(body), revision = body['expectedRevision'] + 1;
  return {
    'operation': op.operation,
    'operationId': op.operationId,
    'requestHash': op.requestHash,
    'state': found ? 'committed' : 'not_found',
    'replayed': found ? replayed : false,
    'entityRevision': found ? revision : null,
    'result': found
        ? _data(
            revision: revision,
            messages: body['messages'],
            meetings: body['meetings'],
            sound: body['sound'],
          )
        : null,
  };
}

void main() {
  testWidgets(
    'three server switches, original lost ACK restart/not-found, late A-to-B, owner-only restore',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('native-preferences-'),
      ))!;
      final wireStore = PeopleStore();
      final late = Completer<http.StreamedResponse>();
      var posts = 0, gets = 0, lookups = 0;
      var notFound = true, held = false;
      final originals = <String, Map<String, dynamic>>{};
      var server = _data();
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/auth/login')) {
          return peopleReply(peopleTokens('B'));
        }
        if (r.url.path.endsWith('/auth/logout')) {
          return peopleReply({'revoked': true});
        }
        if (r.url.path == '/v1/runtime/me/preferences') {
          if (r.method == 'GET') {
            gets++;
            return peopleReply(server);
          }
          posts++;
          final body =
              jsonDecode((r as http.Request).body) as Map<String, dynamic>;
          expect(body.keys.toSet(), {
            'operationId',
            'expectedRevision',
            'messages',
            'meetings',
            'sound',
          });
          final op = _request(body);
          originals[op.operationId] = body;
          final changes = TimewebPreferenceChanges.fromPayload(
            Map<String, dynamic>.from(body)..remove('operationId'),
          );
          server = _data(
            revision: changes.expectedRevision + 1,
            messages: changes.messages,
            meetings: changes.meetings,
            sound: changes.sound,
          );
          if (posts == 1) {
            return peopleReply({'error': 'outcome_unknown'}, status: 503);
          }
          held = true;
          return late.future;
        }
        expect(r.method, 'GET');
        lookups++;
        final body = originals[r.url.pathSegments.last]!;
        expect(r.url.queryParameters, {
          'requestHash': _request(body).requestHash,
        });
        return peopleReply(_receipt(body, found: !notFound));
      });
      TimewebAppRuntime create(PeopleStore store) => TimewebAppRuntime(
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
        preferencesJournal: TimewebPreferencesJournal(
          directory: () async => folder,
        ),
      );
      var app = create(wireStore);
      final apps = <TimewebAppRuntime>[app];
      await tester.runAsync(() => app.start(remember: true));
      tester.view.physicalSize = const Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        if (!late.isCompleted && originals.isNotEmpty) {
          late.complete(
            peopleReply(
              _receipt(originals.values.last, found: true, replayed: false),
            ),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        for (final owner in apps) {
          var done = false;
          final stop = owner.stop().then((_) => done = true);
          await _until(tester, () => done);
          await stop;
        }
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      final nav = GlobalKey<NavigatorState>();
      Widget screen(TimewebAppRuntime owner) => MaterialApp(
        navigatorKey: nav,
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: TimewebAccountPage(
          runtime: owner,
          lease: owner.session.captureLease(),
        ),
      );
      await tester.pumpWidget(screen(app));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-preferences-messages'))
            .evaluate()
            .isNotEmpty,
      );
      expect(gets, 1);
      SwitchListTile item(String key) => tester.widget<SwitchListTile>(
        find.byKey(ValueKey('timeweb-preferences-$key')),
      );
      expect(item('messages').value, isTrue);
      expect(item('meetings').value, isFalse);
      expect(item('sound').value, isTrue);
      await _tap(tester, 'timeweb-preferences-messages');
      await _tap(tester, 'timeweb-preferences-meetings');
      await _tap(tester, 'timeweb-preferences-sound');
      await _tap(tester, 'timeweb-preferences-save');
      await _until(
        tester,
        () =>
            posts == 1 &&
            find.text('Проверить результат').evaluate().isNotEmpty,
      );
      expect(item('messages').onChanged, isNull);
      expect(tester.takeException(), isNull);
      expect(Firebase.apps, isEmpty);
      final originalId = originals.keys.single;
      await tester.pumpWidget(const SizedBox.shrink());
      var stopped = false;
      final stop = app.stop().then((_) => stopped = true);
      await _until(tester, () => stopped);
      await stop;
      app = create(wireStore);
      apps.add(app);
      await tester.runAsync(() => app.start(remember: true));
      await tester.pumpWidget(screen(app));
      await _until(
        tester,
        () => find.text('Проверить результат').evaluate().isNotEmpty,
      );
      expect(gets, 1);
      expect(posts, 1);
      expect(item('messages').value, isFalse);
      expect(item('meetings').value, isTrue);
      expect(item('sound').value, isFalse);
      await _tap(tester, 'timeweb-preferences-save');
      await _until(
        tester,
        () =>
            lookups == 1 &&
            tester
                    .widget<TextButton>(
                      find.byKey(const ValueKey('timeweb-preferences-save')),
                    )
                    .onPressed !=
                null,
      );
      expect(posts, 1);
      expect(originals.keys.single, originalId);
      expect(item('sound').onChanged, isNull);
      notFound = false;
      await _tap(tester, 'timeweb-preferences-save');
      await _until(
        tester,
        () =>
            lookups == 2 &&
            find.text('Сохранить настройки').evaluate().isNotEmpty,
      );
      expect(item('messages').onChanged, isNotNull);
      expect(gets, 2); // Confirmed original receipt is followed by current GET.
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('timeweb-preferences-save')),
            )
            .onPressed,
        isNull,
      );
      expect(
        (await tester.runAsync(
          () => Directory(
            '${folder.path}/clrs_native_preferences',
          ).list().toList(),
        ))!,
        isEmpty,
      );
      final old = (await tester.runAsync(app.readPreferences))!;
      await _tap(tester, 'timeweb-preferences-messages');
      await _tap(tester, 'timeweb-preferences-save');
      await _until(tester, () => held);
      final pendingId = originals.keys.last;
      var logged = false;
      final login = app
          .login(email: 'b@example.invalid', password: 'synthetic')
          .then((_) => logged = true);
      unawaited(
        nav.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('New B route')),
          ),
        ),
      );
      await _until(tester, () => logged);
      await login;
      late.complete(
        peopleReply(
          _receipt(originals[pendingId]!, found: true, replayed: false),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-preferences-save'))
            .evaluate()
            .isEmpty,
      );
      expect(find.text('New B route'), findsOneWidget);
      expect(app.session.state.identity?.uid, 'B');
      expect(() => old.messages, throwsA(isA<Exception>()));
      expect(posts, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final resumed = create(PeopleStore());
      apps.add(resumed);
      await tester.runAsync(() => resumed.start(remember: true));
      final flow = (await tester.runAsync(resumed.openPreferences))!;
      expect(flow.needsCheck, isTrue);
      expect(flow.pendingAction!.messages, isTrue);
      expect(
        await tester.runAsync(flow.check),
        TimewebPreferencesOutcome.confirmed,
      );
      expect(posts, 2);
      expect(originals.keys.last, pendingId);
      flow.close();
    },
  );
}
