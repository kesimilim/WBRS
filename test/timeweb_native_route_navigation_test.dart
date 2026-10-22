import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/feed/timeweb_feed_page.dart';
import 'package:wbrs/presentation/screens/home/timeweb_home_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/presentation/screens/notifications_center/timeweb_notifications_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/presentation/screens/settings/timeweb_account_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/service/timeweb_preferences_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/timeweb_bottom_navigation.dart';

import 'support/timeweb_people_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 160 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
  await tester.pump(const Duration(milliseconds: 350));
  expect(tester.takeException(), isNull);
}

Future<void> _drawer(WidgetTester tester, String label) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.byIcon(Icons.menu).hitTestable().last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  final entry = find.text(label);
  await tester.scrollUntilVisible(entry, 200, scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
  await tester.pumpAndSettle();
  await tester.tap(entry.last);
  await tester.pump();
}

Future<void> _tab(WidgetTester tester, int index) async {
  final bar = find
      .byKey(const ValueKey('timeweb-route-navigation'))
      .hitTestable();
  final label = find.descendant(
    of: bar,
    matching: find.text(
      const ['Лента', 'Поиск', 'Чаты', 'Встречи', 'Профиль'][index],
    ),
  );
  await tester.tap(label.last);
  await tester.pump();
}

void main() {
  testWidgets(
    'native five-slot pushed routes return to original owner without bypassing onboarding or duplicate Home bars',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('native-route-nav-'),
      ))!;
      var stage = 'test', notices = 0, meetings = 0;
      final wire = PeopleWire((request) async {
        final uid = request.headers['Authorization']?.split('.')[1] ?? 'A';
        final path = request.url.path;
        if (path.endsWith('/auth/login')) return peopleReply(peopleTokens('B'));
        if (path.endsWith('/me/full-profile')) {
          return peopleReply(peopleOwn(uid, stage: stage));
        }
        if (path.endsWith('/me/notifications')) {
          notices++;
          return peopleReply({
            'kind': 'native-notifications',
            'items': <Object?>[],
            'nextCursor': null,
          });
        }
        if (path.endsWith('/me/preferences')) {
          return peopleReply({
            'kind': 'native-preferences',
            'messages': true,
            'meetings': true,
            'sound': true,
            'revision': 0,
            'updatedAt': null,
          });
        }
        if (path == '/v1/runtime/meetings') {
          meetings++;
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'starts_at_asc_meeting_id_asc_null_first',
            'scope': 'group',
            'items': <Object?>[],
            'nextCursor': null,
            'mediaReady': false,
          });
        }
        if (path.endsWith('/people')) return peopleReply(directoryReply([]));
        return peopleReply({'error': 'unavailable'}, status: 404);
      });
      final runtime = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: PeopleStore(),
        transport: wire,
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        clock: () => peopleNow,
        currentOwnProfileEnabled: true,
        currentChatsEnabled: true,
        initialProfileJournal: TimewebInitialProfileJournal(
          directory: () async => folder,
        ),
        preferencesJournal: TimewebPreferencesJournal(
          directory: () async => folder,
        ),
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
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      await tester.runAsync(() => runtime.start(remember: true));
      final own = (await tester.runAsync(runtime.readCurrentOwnProfile))!;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: LrsTheme.theme,
          home: TimewebOwnProfilePage(runtime: runtime, initialProfile: own),
        ),
      );
      await _until(
        tester,
        () => find.textContaining('Own A').evaluate().isNotEmpty,
      );
      final rootBar = tester.widget<BottomNavigationBar>(
        find.byKey(const ValueKey('timeweb-route-navigation')),
      );
      expect(rootBar.items.map((item) => item.label), [
        'Лента',
        'Поиск',
        'Чаты',
        'Встречи',
        'Профиль',
      ]);
      await _tab(tester, 1);
      await tester.pump(const Duration(milliseconds: 350));
      expect(navigator.currentState!.canPop(), isFalse);
      expect(find.byType(TimewebHomePage), findsNothing);
      expect(wire.calls.where((r) => r.url.path.endsWith('/people')), isEmpty);

      await _drawer(tester, 'Уведомления');
      await _until(
        tester,
        () =>
            notices == 1 &&
            find.byType(TimewebNotificationsPage).evaluate().isNotEmpty,
      );
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      await _tab(tester, 4);
      await _until(
        tester,
        () => find.byType(TimewebNotificationsPage).evaluate().isEmpty,
      );
      expect(navigator.currentState!.canPop(), isFalse);
      expect(find.textContaining('Own A'), findsOneWidget);

      await _drawer(tester, 'Настройки');
      await _until(
        tester,
        () => find.byType(TimewebAccountPage).evaluate().isNotEmpty,
      );
      final about = find.byKey(const ValueKey('timeweb-settings-about'));
      await tester.ensureVisible(about);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(about);
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-about-scroll'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      await _tab(tester, 3);
      await _until(
        tester,
        () =>
            meetings == 1 &&
            find.byType(TimewebMeetingsPageView).evaluate().isNotEmpty,
      );
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      await _tab(tester, 4);
      await _until(
        tester,
        () => find.byType(TimewebMeetingsPageView).evaluate().isEmpty,
      );
      expect(navigator.currentState!.canPop(), isFalse);

      stage = 'search';
      final searchOwn = (await tester.runAsync(runtime.readCurrentOwnProfile))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebHomePage(
            runtime: runtime,
            initialOwnProfile: searchOwn,
            nativeFeedBuilder: (runtime) => TimewebFeedPage(runtime: runtime),
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-home-navigation'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      expect(find.byType(TimewebBottomNavigationBar), findsNothing);
      final currentNav = tester.widget<BottomNavigationBar>(
        find.byKey(const ValueKey('timeweb-home-navigation')),
      );
      await tester.runAsync(
        () => runtime.login(
          email: 'b@example.invalid',
          password: 'synthetic-password',
        ),
      );
      await tester.pump();
      currentNav.onTap!(4);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('Own A'), findsNothing);
      expect(find.byType(BottomNavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
