import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/notifications_center/timeweb_notifications_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

void main() {
  testWidgets(
    'root own-profile drawer → notifications → platform back keeps own route',
    (tester) async {
      var notifications = 0;
      final wire = PeopleWire((request) async {
        expect(request.headers['Authorization'], 'Bearer na1.A.first');
        expect(request.method, 'GET');
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn('A'));
        }
        if (request.url.path == '/v1/runtime/me/notifications') {
          notifications++;
          return peopleReply({
            'kind': 'native-notifications',
            'items': <Object?>[],
            'nextCursor': null,
          });
        }
        if (request.url.path.endsWith('/photos')) {
          return peopleReply({'error': 'not_found'}, status: 404);
        }
        throw StateError('Unexpected synthetic route ${request.url.path}');
      });
      final runtime = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: PeopleStore(),
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        transport: wire,
        clock: () => peopleNow,
        currentOwnProfileEnabled: true,
      );
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        var stopped = false;
        final stopping = runtime.stop().then((_) => stopped = true);
        await _until(tester, () => stopped);
        await stopping;
      });
      await tester.runAsync(() => runtime.start(remember: true));
      final snapshot = await tester.runAsync(runtime.readCurrentOwnProfile);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: LrsTheme.theme,
          home: TimewebOwnProfilePage(
            runtime: runtime,
            initialProfile: snapshot!,
          ),
        ),
      );
      await _until(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      final ownScaffold = find.descendant(
        of: find.byType(TimewebOwnProfilePage),
        matching: find.byType(Scaffold),
      );
      expect(tester.state<ScaffoldState>(ownScaffold).isDrawerOpen, isTrue);
      await tester.tap(find.text('Уведомления'));
      await _until(
        tester,
        () =>
            notifications == 1 &&
            find
                .text('Здесь появятся важные уведомления')
                .evaluate()
                .isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byType(TimewebNotificationsPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TimewebNotificationsPage), findsNothing);
      expect(find.byType(TimewebOwnProfilePage), findsOneWidget);
      expect(find.textContaining('Own A'), findsOneWidget);
      expect(tester.state<ScaffoldState>(ownScaffold).isDrawerOpen, isFalse);
      expect(navigator.currentState!.canPop(), isFalse);
      expect(runtime.session.state.authenticated, isTrue);
      snapshot.requireCurrent();
      expect(snapshot.uid, 'A');
      expect(notifications, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
