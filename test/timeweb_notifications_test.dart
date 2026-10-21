import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/home/timeweb_home_page.dart';
import 'package:wbrs/presentation/screens/notifications_center/timeweb_notifications_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_chat_flow.dart';
import 'package:wbrs/service/timeweb_notification_delivery.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/timeweb_people_fixtures.dart';

Map<String, dynamic> _notice(
  String id, {
  String? kind = 'chat',
  String? target = 'off-page-chat',
}) => {
  'id': id,
  'type': kind == 'chat' ? 'chat.message.created.v1' : 'legacy',
  'targetKind': kind,
  'targetId': target,
  'createdAt': null,
  'read': null,
};
Map<String, dynamic> _list(List<Object?> items, [String? cursor]) => {
  'kind': 'native-notifications',
  'items': items,
  'nextCursor': cursor,
};
Map<String, dynamic> _push({
  String uid = 'A',
  String id = 'e:7',
  String target = 'off-page-chat',
}) => {
  'kind': 'native-chat',
  'recipientUid': uid,
  'messageId': 'exact-event-message',
  'notificationId': id,
  'chatId': target,
  'soundEnabled': 'true',
};
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

void main() {
  testWidgets(
    'native bell source-bound taps, sparse/malformed/cursor, preferences and late A-to-B',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('native-notifications-'),
      ))!;
      final late = StreamController<List<int>>();
      final navigator = GlobalKey<NavigatorState>();
      final scale = ValueNotifier<double>(1);
      var clock = peopleNow,
          malformed = true,
          hold = false,
          held = false,
          cancelled = false;
      var resolves = 0, messages = 0, posts = 0;
      final messageMethods = <String>[];
      final wire = PeopleWire((r) async {
        final path = r.url.path,
            uid = r.headers['Authorization']?.split('.')[1] ?? 'A';
        if (path.endsWith('/auth/logout')) {
          return peopleReply({'loggedOut': true});
        }
        if (path.endsWith('/auth/login')) return peopleReply(peopleTokens('B'));
        if (path.endsWith('/me/full-profile')) {
          return peopleReply(peopleOwn(uid));
        }
        if (path.endsWith('/people')) {
          return peopleReply(
            directoryReply([
              publicPerson('peer-$uid', name: 'Current person $uid'),
            ]),
          );
        }
        if (path.endsWith('/me/preferences')) {
          return peopleReply({
            'kind': 'native-preferences',
            'messages': true,
            'meetings': true,
            'sound': false,
            'revision': 0,
            'updatedAt': null,
          });
        }
        if (path == '/v1/runtime/me/notifications') {
          if (malformed) {
            return peopleReply(
              _list([
                {..._notice('e:7'), 'read': 'false'},
              ]),
            );
          }
          if (uid == 'B') return peopleReply(_list([]));
          if (r.url.queryParameters['cursor'] == null) {
            return peopleReply(_list([], 'Opaque_original_cursor'));
          }
          return peopleReply(
            _list([
              _notice('e:7'),
              _notice('n:retained', kind: null, target: null),
            ]),
          );
        }
        if (path.startsWith('/v1/runtime/me/notifications/')) {
          resolves++;
          final id = r.url.pathSegments.last;
          if (id == 'e:8') return peopleReply(_notice('e:7')); // substitution.
          if (id == 'e:10') {
            return peopleReply({
              'error': 'notification_unavailable',
            }, status: 404);
          }
          if (hold) {
            held = true;
            late.onCancel = () {
              cancelled = true;
            };
            return peopleReply(_notice(id), stream: late.stream);
          }
          return peopleReply(_notice(id));
        }
        if (path == '/v1/runtime/chats/off-page-chat/messages') {
          messageMethods.add(r.method);
          messages++;
          return peopleReply({
            'kind': 'canonical-current',
            'chatId': 'off-page-chat',
            'chatRevision': 0,
            'ordering': 'sequence_desc',
            'items': <Object?>[],
            'nextBeforeSequence': null,
          });
        }
        if (path == '/v1/runtime/events') {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'event_id_asc',
            'items': <Object?>[],
            'nextAfterEventId': null,
          });
        }
        if (r.method == 'POST') posts++;
        return peopleReply({'error': 'unavailable'}, status: 503);
      });
      final app = TimewebAppRuntime(
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
        clock: () => clock,
        currentOwnProfileEnabled: true,
        currentChatsEnabled: true,
        chatJournal: TimewebChatJournal(directory: () async => folder),
      );
      TimewebNotificationDelivery? delivery;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        delivery?.close();
        unawaited(late.close());
        scale.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        var stopped = false;
        final stopping = app.stop().then((_) => stopped = true);
        await _until(tester, () => stopped);
        await stopping;
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      expect(
        (await tester.runAsync(() => app.start(remember: true)))!.confirmed,
        isTrue,
      );
      await tester.runAsync(() async {
        await expectLater(
          app.readNotifications(),
          throwsA(isA<TimewebAuthException>()),
        );
        malformed = false;
        await expectLater(
          app.readNotification('e:8'),
          throwsA(isA<TimewebAuthException>()),
        );
        await expectLater(
          app.readNotification('e:10'),
          throwsA(isA<TimewebNotificationUnavailable>()),
        );
      });
      expect(app.session.state.authenticated, isTrue);
      expect(Firebase.apps, isEmpty);
      final own = (await tester.runAsync(app.readCurrentOwnProfile))!;
      final first = (await tester.runAsync(app.readNotifications))!;
      expect(first.items, isEmpty);
      final cursor = first.nextCursor!;
      await tester.runAsync(
        () => expectLater(
          app.readNotifications(limit: 2, cursor: cursor),
          throwsArgumentError,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: LrsTheme.theme,
          builder: (context, child) => ValueListenableBuilder<double>(
            valueListenable: scale,
            builder: (context, value, _) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(value)),
              child: child!,
            ),
          ),
          home: TimewebHomePage(runtime: app, initialOwnProfile: own),
        ),
      );
      await _until(
        tester,
        () => find.textContaining('Current person A').evaluate().isNotEmpty,
      );
      await tester.tap(
        find.byKey(const ValueKey('timeweb-home-tab-profile')),
      );
      await _until(tester, () => find.byIcon(Icons.menu).evaluate().isNotEmpty);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Уведомления'),
        300,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('timeweb-profile-drawer-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Уведомления'));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-notifications-more'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Здесь появятся важные уведомления'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('timeweb-notifications-more')),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-notification:e:7'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byIcon(Icons.circle),
        findsNothing,
      ); // read:null is not unread.
      expect(
        find.textContaining('retained'),
        findsNothing,
      ); // no technical ID copy.
      scale.value = 2;
      await tester.pump();
      expect(tester.takeException(), isNull);
      scale.value = 1;
      await tester.pump();
      final beforeTap = resolves;
      await tester.tap(find.byKey(const ValueKey('timeweb-notification:e:7')));
      await _until(
        tester,
        () => find.byType(TimewebChatPage).evaluate().isNotEmpty,
      );
      expect(resolves, beforeTap + 1);
      expect(messages, 1);
      expect(
        tester
            .widget<TimewebChatPage>(find.byType(TimewebChatPage))
            .flow
            .chatId,
        'off-page-chat',
      );
      navigator.currentState!.pop();
      await _until(
        tester,
        () => find.byType(TimewebChatPage).evaluate().isEmpty,
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-notifications-busy'))
            .evaluate()
            .isEmpty,
      );
      final foreground = <bool>[];
      var taps = 0;
      Object? tapError;
      delivery = TimewebNotificationDelivery(
        runtime: app,
        onForeground: (item, sound) async {
          item.requireCurrent();
          foreground.add(sound);
        },
        onTap: (item) async {
          taps++;
          try {
            await openTimewebNotification(
              navigator.currentContext!,
              app,
              item,
              refresh: false,
            );
          } catch (e) {
            tapError = e;
            rethrow;
          }
        },
      )..start();
      final beforeMalformed = resolves;
      await tester.runAsync(() async {
        await delivery!.receive({
          ..._push(),
          'notificationId': 'e:0',
        }, opened: true);
        await delivery.receive(_push(uid: 'B'), opened: true);
        await delivery.receive({'chatId': 'off-page-chat'}, opened: true);
      });
      expect(resolves, beforeMalformed);
      expect(taps, 0);
      await tester.runAsync(() => delivery!.receive(_push(), opened: false));
      expect(foreground, [false]); // actual preferences sound false.
      await tester.runAsync(
        () => delivery!.receive(_push(target: 'substituted'), opened: false),
      );
      expect(foreground.length, 1);
      unawaited(delivery.receive(_push(), opened: true));
      await _until(
        tester,
        () =>
            find.byType(TimewebChatPage).evaluate().isNotEmpty ||
            tapError != null,
      );
      expect(
        tapError,
        isNull,
        reason:
            'messages=$messages paths=${wire.calls.map((r) => r.url.path).toList()}',
      );
      expect(taps, 1);
      expect(messages, 2);
      expect(messageMethods, ['GET', 'GET']);
      navigator.currentState!.pop();
      await _until(
        tester,
        () => find.byType(TimewebChatPage).evaluate().isEmpty,
      );
      clock = peopleNow.add(const Duration(seconds: 301));
      await tester.runAsync(
        () => expectLater(
          app.readNotifications(cursor: cursor),
          throwsA(isA<TimewebAuthException>()),
        ),
      );
      hold = true;
      unawaited(delivery.receive(_push(id: 'e:9'), opened: true));
      await _until(tester, () => held);
      var switched = false;
      bool? logoutConfirmed, loginConfirmed;
      final switching = () async {
        logoutConfirmed = (await app.session.logout()).confirmed;
        loginConfirmed = (await app.login(
          email: 'b@example.test',
          password: 'fixture-password',
        )).confirmed;
        switched = true;
      }();
      // New unrelated route exists above A before A's cleanup frame.
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('B current route')),
        ),
      );
      await _until(tester, () => switched);
      await switching;
      expect(logoutConfirmed, isTrue);
      expect(loginConfirmed, isTrue);
      expect(cancelled, isTrue);
      late.add(utf8.encode(jsonEncode(_notice('e:9'))));
      await _until(
        tester,
        () => find.text('B current route').evaluate().isNotEmpty,
      );
      expect(taps, 1);
      await _until(
        tester,
        () => find.byType(TimewebNotificationsPage).evaluate().isEmpty,
      );
      expect(find.text('B current route'), findsOneWidget);
      expect(() => first.items, throwsA(isA<Exception>()));
      hold = false;
      final b = (await tester.runAsync(app.readNotifications))!;
      expect(b.items, isEmpty);
      expect(posts, 0);
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
