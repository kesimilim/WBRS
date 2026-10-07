import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chat_avatar.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/presentation/screens/shop/timeweb_gifts_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_gift_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

TimewebAppRuntime _runtime(PeopleWire wire, {Directory? directory}) =>
    TimewebAppRuntime(
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
      currentChatsEnabled: true,
      giftJournal: directory == null
          ? null
          : TimewebGiftJournal(directory: () async => directory),
    );

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 160 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
  expect(tester.takeException(), isNull);
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var done = false;
  final stop = runtime.stop().then((_) => done = true);
  await _until(tester, () => done);
  await stop;
}

Map<String, dynamic> _chat({bool preview = true, String sender = 'P0'}) => {
  'chatId': 'chat-1',
  'counterpartUid': 'P0',
  'name': 'Имя собеседника',
  'avatar': null,
  'updatedAt': peopleStamp,
  'lastSequence': 2,
  'revision': 2,
  'readThrough': 0,
  'archived': false,
  'notifications': true,
  if (preview) ...{
    'lastMessage': 'Original user text\nSecond line\nThird line',
    'lastMessageSenderUid': sender,
  },
};
Map<String, dynamic> _chats(Map<String, dynamic> row) => {
  'kind': 'canonical-current',
  'ordering': 'updated_at_desc_chat_id_asc_null_last',
  'items': [row],
  'nextCursor': null,
};
Map<String, dynamic> _gifts() => {
  'kind': 'native-gifts',
  'balanceAg': 100,
  'walletRevision': 1,
  'inventory': [],
  'catalog': [
    for (var i = 1; i <= 4; i++)
      {
        'id': 'assets/gifts/$i.png',
        'assetPath': 'assets/gifts/$i.png',
        'name': 'Подарок $i',
        'priceAg': i,
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'chat previews use one opt-in read; old10/new12 and UID guards',
    () async {
      var row = _chat();
      final wire = PeopleWire((request) async {
        if (request.url.path.endsWith('/login')) {
          return peopleReply(peopleTokens('B'));
        }
        expect(request.url.queryParameters['includePreview'], '1');
        return peopleReply(_chats(row));
      });
      final runtime = _runtime(wire);
      await runtime.start(remember: true);
      addTearDown(runtime.stop);
      final snapshot = await runtime.readChats();
      expect(snapshot.chats.single.lastMessage, row['lastMessage']);
      expect(snapshot.chats.single.lastMessageSenderUid, 'P0');
      expect(wire.calls, hasLength(1));
      row = _chat(preview: false);
      expect((await runtime.readChats()).chats.single.lastMessage, isNull);
      row = _chat()..['lastMessage'] = null;
      final noText = (await runtime.readChats()).chats.single;
      expect(noText.lastMessage, isNull);
      expect(noText.lastMessageSenderUid, 'P0');
      row = _chat()
        ..['lastMessage'] = null
        ..['lastMessageSenderUid'] = null;
      expect(
        (await runtime.readChats()).chats.single.lastMessageSenderUid,
        isNull,
      );
      for (final bad in [
        _chat(sender: 'foreign-UID'),
        _chat()..remove('lastMessageSenderUid'),
        _chat()..['lastMessage'] = 'x' * 4097,
        _chat()..['lastMessageSenderUid'] = null,
        _chat()..['unknown'] = 'extra',
      ]) {
        row = bad;
        await expectLater(
          runtime.readChats(),
          throwsA(isA<TimewebAuthException>()),
        );
      }
      await runtime.login(
        email: 'b@example.invalid',
        password: 'synthetic-password',
      );
      expect(
        () => snapshot.chats.single.lastMessage,
        throwsA(anyOf(isA<TimewebAuthException>(), isA<StateError>())),
      );
      expect(Firebase.apps, isEmpty);
    },
  );

  for (final width in [360.0, 430.0]) {
    testWidgets('shop stays two columns at ${width.toInt()}px', (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('oct07-gifts-'),
      ))!;
      final wire = PeopleWire((request) async => peopleReply(_gifts()));
      final runtime = _runtime(wire, directory: folder);
      await tester.runAsync(() => runtime.start(remember: true));
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await _stop(tester, runtime);
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebGiftsPage(runtime: runtime),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-gift-card-assets/gifts/1.png'))
            .evaluate()
            .isNotEmpty,
      );
      final a = find.byKey(
        const ValueKey('timeweb-gift-card-assets/gifts/1.png'),
      );
      final b = find.byKey(
        const ValueKey('timeweb-gift-card-assets/gifts/2.png'),
      );
      final c = find.byKey(
        const ValueKey('timeweb-gift-card-assets/gifts/3.png'),
      );
      expect(tester.getTopLeft(a).dy, tester.getTopLeft(b).dy);
      expect(tester.getTopLeft(b).dx, greaterThan(tester.getTopLeft(a).dx));
      expect(tester.getTopLeft(c).dx, tester.getTopLeft(a).dx);
      expect(tester.getTopLeft(c).dy, greaterThan(tester.getTopLeft(a).dy));
      expect(wire.calls.where((call) => call.method != 'GET'), isEmpty);
      expect(Firebase.apps, isEmpty);
    });
  }

  testWidgets('avatar appears before optional group; preview is two lines', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final group = Completer<http.StreamedResponse>();
    final wire = PeopleWire((request) async {
      if (request.url.path.endsWith('/chats')) {
        return peopleReply(_chats(_chat()));
      }
      if (request.url.path.endsWith('/events')) {
        return peopleReply({
          'kind': 'canonical-current',
          'ordering': 'event_id_asc',
          'items': [],
          'nextAfterEventId': null,
        });
      }
      if (request.url.path.endsWith('/photos')) {
        return peopleReply(photoPage('P0', [photoDescriptor(0)]));
      }
      if (request.url.path.endsWith('/content')) return photoContent();
      if (request.url.path.endsWith('/people/P0')) return group.future;
      fail('Unexpected request ${request.url.path}');
    });
    final runtime = _runtime(wire);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => runtime.start(remember: true));
    final page = (await tester.runAsync(runtime.readChats))!;
    addTearDown(() async {
      if (!group.isCompleted) {
        group.complete(
          peopleReply(personReply(publicPerson('P0', details: true))),
        );
      }
      await _stop(tester, runtime);
    });
    Widget app(double scale) => MaterialApp(
      theme: LrsTheme.theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: TimewebChatsPage(runtime: runtime, initialPage: page),
    );
    await tester.pumpWidget(app(1));
    final image = find.descendant(
      of: find.byType(TimewebChatAvatar),
      matching: find.byType(RawImage),
    );
    await _until(tester, () => image.evaluate().isNotEmpty);
    expect(group.isCompleted, isFalse);
    final preview = tester.widget<Text>(
      find.byKey(const ValueKey('timeweb-chat-preview-chat-1')),
    );
    expect(preview.data, _chat()['lastMessage']);
    expect(preview.maxLines, 2);
    expect(preview.overflow, TextOverflow.ellipsis);
    await tester.pumpWidget(app(2));
    expect(tester.takeException(), isNull);
    expect(
      wire.calls.where((request) => request.url.path.endsWith('/messages')),
      isEmpty,
    );
    expect(Firebase.apps, isEmpty);
    group.complete(peopleReply(personReply(publicPerson('P0', details: true))));
    await _stop(tester, runtime);
  });

  for (final opened in [true, false]) {
    testWidgets(
      'native Support project restores original external link ($opened)',
      (tester) async {
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        final launches = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              launches.add(call);
              return opened;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final wire = PeopleWire((request) async {
          expect(request.method, 'GET');
          if (request.url.path.endsWith('/full-profile')) {
            return peopleReply(peopleOwn('A'));
          }
          if (request.url.path.endsWith('/gifts/mine')) {
            return peopleReply(_gifts());
          }
          if (request.url.path.endsWith('/photos')) {
            return peopleReply(photoPage('A', []));
          }
          return peopleReply({'error': 'not_found'}, status: 404);
        });
        final runtime = _runtime(wire);
        await tester.runAsync(() => runtime.start(remember: true));
        final profile = (await tester.runAsync(runtime.readCurrentOwnProfile))!;
        addTearDown(() => _stop(tester, runtime));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebOwnProfilePage(
              runtime: runtime,
              initialProfile: profile,
            ),
          ),
        );
        // Run real asynchronous response bodies before settling the drawer's
        // animation; fake-time pumping alone starves the transport fixture.
        await _until(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        await tester.tap(find.byIcon(Icons.menu));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final support = find.byKey(const ValueKey('timeweb-support-project'));
        await tester.ensureVisible(support);
        await tester.pump();
        expect(support.hitTestable(), findsOneWidget);
        await tester.tap(support);
        await _until(tester, () => launches.isNotEmpty);
        await tester.pump(const Duration(milliseconds: 400));
        expect(launches, hasLength(1));
        expect(launches.single.method, 'launch');
        final arguments = launches.single.arguments as Map;
        expect(
          arguments['url'],
          'https://qr.nspk.ru/BS2A002KUIKV3G1Q8JGRDS9N32P84DCB?type=01&bank=100000000008&crc=5D81',
        );
        expect(arguments['useWebView'], isFalse);
        expect(arguments['useSafariVC'], isFalse);
        if (!opened) {
          expect(
            find.text('Не удалось открыть раздел. Проверьте подключение.'),
            findsOneWidget,
          );
        }
        expect(find.byType(TimewebOwnProfilePage), findsOneWidget);
        expect(runtime.session.currentUid, 'A');
        expect(wire.calls.where((request) => request.method != 'GET'), isEmpty);
        expect(Firebase.apps, isEmpty);
        await _stop(tester, runtime);
      },
    );
  }
}
