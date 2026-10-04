
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
    'loaded gifts survive transport deadline, drawer Back keeps own route, logout invalidates A snapshots',
    (tester) async {
      var notifications = 0, gifts = 0;
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/auth/login') {
          expect(request.method, 'POST');
          return peopleReply(peopleTokens('B', 'first'));
        }
        expect(request.headers['Authorization'], 'Bearer na1.A.first');
        if (request.url.path == '/v1/auth/logout') {
          expect(request.method, 'POST');
          return peopleReply({'loggedOut': true});
        }
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
        if (request.url.path == '/v1/runtime/me/preferences') {
          return peopleReply({
            'kind': 'native-preferences',
            'messages': true,
            'meetings': true,
            'sound': false,
            'revision': 0,
            'updatedAt': null,
          });
        }
        if (request.url.path == '/v1/runtime/gifts/mine') {
          gifts++;
          return peopleReply({
            'kind': 'native-gifts',
            'balanceAg': 27,
            'walletRevision': 0,
            'inventory': [
              {
                'giftId': 'assets/gifts/1.png',
                'ownedQuantity': 1,
                'receivedQuantity': 2,
              },
            ],
            'catalog': [
              {
                'id': 'assets/gifts/1.png',
                'assetPath': 'assets/gifts/1.png',
                'name': 'Подарок',
                'priceAg': 12,
              },
            ],
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
      final heldGifts = (await tester.runAsync(runtime.readGifts))!;
      final heldCatalog = heldGifts.catalog.single;
      final heldInventory = heldGifts.inventory.single;
      final heldPreferences = (await tester.runAsync(runtime.readPreferences))!;
      expect(heldPreferences.messages, isTrue);
      expect(heldCatalog.name, 'Подарок');
      expect(heldInventory.receivedQuantity, 2);
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
        () =>
            gifts == 2 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      // Stopwatch deadlines bound transport, not successfully loaded snapshots.
      await tester.runAsync(
        () => Future<void>.delayed(
          runtime.client.requestDeadline + const Duration(milliseconds: 100),
        ),
      );
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      final ownScaffold = find.descendant(
        of: find.byType(TimewebOwnProfilePage),
        matching: find.byType(Scaffold),
      );
      expect(tester.state<ScaffoldState>(ownScaffold).isDrawerOpen, isTrue);
      expect(
        find.byKey(const ValueKey('timeweb-drawer-profile-card')),
        findsOneWidget,
      );
      expect(find.text('Список пользователей'), findsOneWidget);
      final drawerScroll = find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('timeweb-profile-settings')),
        160,
        scrollable: drawerScroll,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('timeweb-profile-logout')),
        160,
        scrollable: drawerScroll,
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('timeweb-profile-settings')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('timeweb-profile-logout')))
              .dy,
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Уведомления'),
        -160,
        scrollable: drawerScroll,
      );
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
      // Returning starts a fresh gallery read; allow route animation without
      // waiting for an intentionally real-time transport deadline.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TimewebNotificationsPage), findsNothing);
      expect(find.byType(TimewebOwnProfilePage), findsOneWidget);
      expect(find.textContaining('Own A'), findsOneWidget);
      expect(tester.state<ScaffoldState>(ownScaffold).isDrawerOpen, isFalse);
      expect(navigator.currentState!.canPop(), isFalse);
      expect(runtime.session.state.authenticated, isTrue);
      snapshot.requireCurrent();
      expect(snapshot.uid, 'A');
      expect(notifications, 1);
      expect(gifts, 2);
      expect(heldGifts.balanceAg, 27);
      expect(heldCatalog.name, 'Подарок');
      expect(heldInventory.receivedQuantity, 2);
      expect(heldPreferences.messages, isTrue);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => runtime.session.logout());
      await tester.pump();
      await tester.runAsync(
        () => runtime.session.login(
          email: 'synthetic-B@example.invalid',
          password: 'synthetic-password',
          deviceId: 'synthetic-device',
        ),
      );
      await tester.pump();
      expect(runtime.session.currentUid, 'B');
      final stale = isA<TimewebAuthException>().having(
        (error) => error.error,
        'error',
        TimewebAuthError.staleSession,
      );
      expect(() => heldGifts.balanceAg, throwsA(stale));
      expect(() => heldCatalog.name, throwsA(stale));
      expect(() => heldInventory.receivedQuantity, throwsA(stale));
      expect(() => heldPreferences.messages, throwsA(stale));
      expect(
        snapshot.requireCurrent,
        throwsA(anyOf(isA<TimewebAuthException>(), isA<StateError>())),
      );
      expect(find.textContaining('Own A'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
