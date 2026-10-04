import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chat_avatar.dart';
import 'package:wbrs/presentation/screens/feed/timeweb_feed_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_chat_flow.dart';
import 'package:wbrs/service/timeweb_gift_flow.dart';
import 'package:wbrs/service/timeweb_social_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_badge.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/timeweb_people_fixtures.dart';

const _gift = 'assets/gifts/1.png';
const _capture =
    '/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/private_migration_20260930/native-original-social-presentation-20261004';
Map<String, dynamic> _chat(String id, String name, String at) => {
  'chatId': id,
  'counterpartUid': 'peer-$id',
  'name': name,
  'avatar': null,
  'updatedAt': at,
  'lastSequence': 0,
  'revision': 0,
  'readThrough': 0,
  'archived': false,
  'notifications': true,
};
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 160 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _captureScreen(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    await precacheImage(
      const AssetImage('assets/final_design/family_right.png'),
      tester.element(find.byType(ClrsScaffold).last),
    );
    await precacheImage(
      const AssetImage('assets/final_design/feed_family.png'),
      tester.element(find.byType(ClrsScaffold).last),
    );
  });
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('$_capture/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in {
      'MaterialIcons': ['fonts/MaterialIcons-Regular.otf'],
      'Lato': ['assets/fonts/Lato-Regular.ttf', 'assets/fonts/Lato-Bold.ttf'],
      'CormorantGaramond': ['assets/fonts/CormorantGaramond-Variable.ttf'],
      'Caveat': ['assets/fonts/Caveat-Variable.ttf'],
    }.entries) {
      final loader = FontLoader(font.key);
      for (final path in font.value) {
        loader.addFont(rootBundle.load(path));
      }
      await loader.load();
    }
  });
  testWidgets(
    '360px original chats, keyboard gift chooser, UNKNOWN owner purge and original feed/wall',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('original-ui-'),
      ))!;
      await tester.runAsync(() => Directory(_capture).create(recursive: true));
      SharedPreferences.setMockInitialValues({
        'chat_favorites_A': ['current'],
        'chat_favorites_B': ['current'],
      });
      var posts = 0, lookups = 0;
      Map<String, dynamic>? original;
      final wire = PeopleWire((r) async {
        final path = r.url.path;
        if (path.endsWith('/auth/login')) return peopleReply(peopleTokens('B'));
        if (path == '/v1/runtime/events') {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'event_id_asc',
            'items': [],
            'nextAfterEventId': null,
          });
        }
        if (path == '/v1/runtime/chats') {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'updated_at_desc_chat_id_asc_null_last',
            'items': [
              _chat('current', 'Текущий собеседник', peopleStamp),
              _chat('older', 'Более ранний чат', '2026-10-01T12:00:00.000001Z'),
            ],
            'nextCursor': null,
          });
        }
        if (path == '/v1/runtime/chats/current/messages') {
          return peopleReply({
            'kind': 'canonical-current',
            'chatId': 'current',
            'chatRevision': 0,
            'ordering': 'sequence_desc',
            'items': [],
            'nextBeforeSequence': null,
          });
        }
        if (path == '/v1/runtime/gifts/mine') {
          return peopleReply({
            'kind': 'native-gifts',
            'balanceAg': 100,
            'walletRevision': 2,
            'inventory': [
              {'giftId': _gift, 'ownedQuantity': 1, 'receivedQuantity': 0},
            ],
            'catalog': [
              {
                'id': _gift,
                'assetPath': _gift,
                'name': 'Любовь',
                'priceAg': 44,
              },
            ],
          });
        }
        if (path == '/v1/runtime/gifts/actions') {
          posts++;
          original = jsonDecode((r as http.Request).body);
          final files = await Directory(
            '${folder.path}/clrs_native_gift',
          ).list().where((v) => v.path.endsWith('.json')).toList();
          expect(files, hasLength(1));
          expect(
            jsonDecode(
              await (files.single as File).readAsString(),
            )['operationId'],
            original!['operationId'],
          );
          return peopleReply({'error': 'outcome_unknown'}, status: 503);
        }
        if (path.contains('/operations/')) {
          lookups++;
          expect(path.endsWith(original!['operationId']), isTrue);
          return peopleReply({'error': 'outcome_unknown'}, status: 503);
        }
        if (path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn('B'));
        }
        if (path.startsWith('/v1/runtime/people/') &&
            !path.endsWith('/photos')) {
          final uid = r.url.pathSegments.last;
          return peopleReply(
            personReply(publicPerson(uid, name: 'Имя автора', details: true)),
          );
        }
        if (path == '/v1/runtime/social/feed') {
          return peopleReply({
            'kind': 'native-feed',
            'ordering': 'created_desc_id_desc_null_last',
            'items': r.url.queryParameters.containsKey('wallUid')
                ? []
                : [
                    {
                      'id': 'post-one',
                      'authorUid': 'peer-current',
                      'text': 'Исходная публикация о семье',
                      'mediaId': null,
                      'createdAt': peopleStamp,
                      'likeCount': 2,
                      'commentCount': 0,
                      'liked': false,
                    },
                  ],
            'nextCursor': null,
            'canPublish': false,
            'canModerate': false,
          });
        }
        return peopleReply({'error': 'not_found'}, status: 404);
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
        clock: () => peopleNow,
        deviceId: 'fixture',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        currentOwnProfileEnabled: true,
        currentChatsEnabled: true,
        chatJournal: TimewebChatJournal(directory: () async => folder),
        giftJournal: TimewebGiftJournal(directory: () async => folder),
        socialJournal: TimewebSocialJournal(directory: () async => folder),
      );
      await tester.runAsync(() => app.start(remember: true));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 740);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
      });
      Widget screen(Widget child) => RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
          key: ObjectKey(child),
          theme: LrsTheme.theme,
          home: child,
        ),
      );
      final page = (await tester.runAsync(() => app.readChats()))!;
      await tester.pumpWidget(
        screen(TimewebChatsPage(runtime: app, initialPage: page)),
      );
      await _until(
        tester,
        () => find.byType(TimewebChatAvatar).evaluate().length == 2,
      );
      expect(find.byType(ClrsLogo), findsOneWidget);
      expect(find.byType(ClrsBrandHeader), findsNothing);
      expect(find.text('Чаты'), findsOneWidget);
      await _until(
        tester,
        () => tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('timeweb-chat-menu-current')),
            )
            .enabled,
      );
      await tester.tap(find.text('Избранные'));
      await tester.pump();
      expect(find.text('Текущий собеседник'), findsOneWidget);
      expect(find.text('Более ранний чат'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('timeweb-chat-menu-current')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.tap(find.text('Убрать из избранного'));
      await _until(
        tester,
        () => find.text('Текущий собеседник').evaluate().isEmpty,
      );
      await tester.tap(find.text('Все'));
      await tester.pump();
      await tester.longPress(find.byKey(const ValueKey('timeweb-chat-older')));
      await _until(tester, () => find.byIcon(Icons.star).evaluate().isNotEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('chat_favorites_A'), ['older']);
      expect(prefs.getStringList('chat_favorites_B'), ['current']);
      await _captureScreen(tester, 'chats');
      await tester.tap(find.text('Текущий собеседник'));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-chat-gift'))
            .evaluate()
            .isNotEmpty,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump();
      final giftButton = find.byKey(const ValueKey('timeweb-chat-gift'));
      expect(find.text('Подарить Подарок ❤️'), findsOneWidget);
      expect(tester.getRect(giftButton).bottom, lessThan(460));
      expect(tester.widget<TextButton>(giftButton).onPressed, isNotNull);
      await tester.tap(giftButton);
      tester.view.resetViewInsets();
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-gift-send-$_gift'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.text('Дарите внимание.\nСоздавайте особенные моменты.'),
        findsOneWidget,
      );
      expect(find.text('Ближе, чем кажется.'), findsOneWidget);
      await _captureScreen(tester, 'gifts');
      final sendGift = find.byKey(const ValueKey('timeweb-gift-send-$_gift'));
      await Scrollable.ensureVisible(tester.element(sendGift), alignment: .5);
      await tester.tap(sendGift);
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-gift-recipient-panel'))
            .evaluate()
            .isNotEmpty,
      );
      final panel = tester.getRect(
        find.byKey(const ValueKey('timeweb-gift-recipient-panel')),
      );
      expect(panel.left, 0);
      expect(panel.width, closeTo((360 - 12) * 2 / 3, .01));
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('timeweb-gift-recipient-current')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('timeweb-gift-recipient-older')),
              )
              .dy,
        ),
      );
      await _captureScreen(tester, 'recipients');
      await tester.tap(
        find.byKey(const ValueKey('timeweb-gift-current-recipient')),
      );
      await _until(
        tester,
        () =>
            posts == 1 &&
            find
                .byKey(const ValueKey('timeweb-gift-recipient-check'))
                .evaluate()
                .isNotEmpty &&
            tester
                    .widget<TextButton>(
                      find.byKey(
                        const ValueKey('timeweb-gift-recipient-check'),
                      ),
                    )
                    .onPressed !=
                null,
      );
      expect(posts, 1);
      expect(original!['payload']['chatId'], 'current');
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('timeweb-gift-current-recipient')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('timeweb-gift-recipient-check')),
      );
      await _until(tester, () => lookups == 1);
      expect(posts, 1);
      var changed = false;
      final login = app
          .login(email: 'b@example.invalid', password: 'fixture-password')
          .then((_) => changed = true);
      await _until(tester, () => changed);
      await login;
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('timeweb-gift-recipient-panel')),
        findsNothing,
      );
      expect(find.text('Текущий собеседник'), findsNothing);
      expect(app.session.state.identity!.uid, 'B');
      expect(
        await tester.runAsync(
          () => Directory(
            '${folder.path}/clrs_native_gift',
          ).list().where((v) => v.path.endsWith('.json')).length,
        ),
        1,
      );
      final bPage = (await tester.runAsync(() => app.readChats()))!;
      await tester.pumpWidget(
        screen(TimewebChatsPage(runtime: app, initialPage: bPage)),
      );
      await _until(
        tester,
        () => tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('timeweb-chat-menu-current')),
            )
            .enabled,
      );
      await tester.tap(find.text('Избранные'));
      await tester.pump();
      expect(find.text('Текущий собеседник'), findsOneWidget);
      expect(find.text('Более ранний чат'), findsNothing);
      expect(prefs.getStringList('chat_favorites_A'), ['older']);
      await tester.pumpWidget(screen(TimewebFeedPage(runtime: app)));
      await _until(
        tester,
        () => find.text('Исходная публикация о семье').evaluate().isNotEmpty,
      );
      expect(find.byType(ClrsBrandHeader), findsNothing);
      expect(find.text('Лента'), findsOneWidget);
      await _captureScreen(tester, 'feed');
      final ring = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((v) => v.painter)
          .whereType<GroupRingPainter>();
      expect(ring.isNotEmpty, isTrue);
      expect(ring.first.strokeWidth, 1.2);
      await tester.pumpWidget(
        screen(TimewebFeedPage(runtime: app, wallUid: 'B')),
      );
      await _until(
        tester,
        () => find
            .text('Здесь появятся публикации, которыми вы поделились.')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(ClrsBrandHeader), findsNothing);
      expect(find.text('Стена'), findsOneWidget);
      await _captureScreen(tester, 'wall');
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      var stopped = false;
      final stop = app.stop().then((_) => stopped = true);
      await _until(tester, () => stopped);
      await stop;
      await tester.runAsync(() => folder.delete(recursive: true));
    },
  );
}
