import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/message_tile.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/presentation/screens/meet_chat_screen/chat_page.dart';
import 'package:wbrs/service/chat_submission.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/translatable_text.dart';

import 'support/layout_firebase_fakes.dart';
import 'support/memory_submission_journal.dart';

class _RussianCatalog extends LocalizationsDelegate<ClrsLocalizations> {
  _RussianCatalog()
    : catalog = Map<String, dynamic>.from(
        jsonDecode(File('assets/l10n/ru.json').readAsStringSync()) as Map,
      );
  final Map<String, dynamic> catalog;
  @override
  bool isSupported(Locale locale) => locale.languageCode == 'ru';
  @override
  Future<ClrsLocalizations> load(Locale locale) =>
      SynchronousFuture(ClrsLocalizations(locale, catalog));
  @override
  bool shouldReload(_RussianCatalog old) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LayoutFirestore db;
  late ChatSubmissionService submissions;
  late ContentTranslationService translator;
  late GlobalKey boundaryKey;
  late ValueNotifier<double> keyboard;
  final meeting = <String, dynamic>{
    'name': 'Прогулка в парке',
    'description':
        'Неспешная прогулка, общение и новые знакомства на свежем воздухе.',
    'datetime': Timestamp.fromDate(DateTime(2026, 9, 26, 15)),
    'type': 'групповая',
    'country': 'Россия',
    'countryCode': 'RU',
    'region': 'Ленинградская область',
    'admin': 'other',
    'users': ['viewer', 'other'],
    'usersWithoutNotification': <String>[],
  };

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/font_awesome_flutter/FontAwesomeSolid': 'packages/font_awesome_flutter/lib/fonts/fa-solid-900.ttf',
      'Lato': 'assets/fonts/Lato-Regular.ttf',
      'CormorantGaramond': 'assets/fonts/CormorantGaramond-Variable.ttf',
      'Caveat': 'assets/fonts/Caveat-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });
  setUp(() {
    db = LayoutFirestore();
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = LayoutMessaging();
    selectedIndex = 3;
    submissions = ChatSubmissionService(journal: MemorySubmissionJournal());
    translator = ContentTranslationService(
      endpoint: Uri.parse('https://translation.example.test/translate'),
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        return http.Response(jsonEncode({
          'translatedText': (body['text'] as String).startsWith('Hello') ? 'Перевод: ${body['text']}' : body['text'],
          'detectedSourceLanguage': (body['text'] as String).startsWith('Hello') ? 'en' : 'ru',
          'targetLanguage': body['targetLanguage'],
        }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
      currentUserId: () => 'viewer',
      idToken: () async => 'fixture',
    );
    db.documents['meets/meeting'] = Map.of(meeting);
    for (final uid in ['viewer', 'other']) {
      db.documents['users/$uid'] = {
        'uid': uid,
        'fullName': uid == 'viewer' ? 'Анна' : 'Алексей',
        'age': 33,
        'country': 'Россия',
        'region': 'Ленинградская область',
        'profilePic': '',
        'группа': 'синяя',
      };
    }
    boundaryKey = GlobalKey();
    keyboard = ValueNotifier(0);
  });
  tearDown(() async {
    keyboard.dispose();
    translator.dispose();
    await db.close();
  });

  Future<void> open(WidgetTester tester, Widget screen, {double textScale = 1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 744);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ContentTranslationScope(
        service: translator,
        child: RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
          theme: LrsTheme.theme,
            locale: const Locale('ru'),
            supportedLocales: ClrsLocalizations.supportedLocales,
            localizationsDelegates: [
              _RussianCatalog(),
              ...ClrsLocalizations.delegates.skip(1),
            ],
            builder: (context, child) => ValueListenableBuilder<double>(
              valueListenable: keyboard,
              builder: (context, inset, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                  padding: const EdgeInsets.only(top: 24, bottom: 24),
                  viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
                  viewInsets: EdgeInsets.only(bottom: inset),
                ),
                child: child!,
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => screen)),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.runAsync(() async {
      await Future.wait([
        for (final asset in ['family_right.png', 'family_front.png', 'family_back.png', 'meeting_park.jpg'])
          precacheImage(AssetImage('assets/final_design/$asset'), boundaryKey.currentContext!),
        precacheImage(const AssetImage('assets/family_main.jpg'), boundaryKey.currentContext!),
      ]);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  }

  Future<void> render(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('artifacts/meeting_ui_20261002/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('Photo 1 manual has four compact cards and full details on tap', (
    tester,
  ) async {
    await open(tester, const MeetingGuidePage());
    for (var index = 1; index <= 4; index++) {
      final card = find.byKey(ValueKey('meeting-guide-step-$index'));
      expect(card.hitTestable(), findsOneWidget);
      expect(tester.getRect(card).left, 12);
      expect(tester.getRect(card).right, closeTo(240, .01));
    }
    expect(find.byType(ClrsLogo), findsOneWidget);
    expect(find.byType(ClrsMotto), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.favorite_border)), findsOneWidget);
    final done = find.byKey(const ValueKey('meeting-guide-done'));
    await render(tester, 'photo1_manual_360');
    expect(done.hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('meeting-guide-step-2')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Вас, например, двое. Один создаёт коллективную встречу и пишет: ждём двух девушек, и что вы предлагаете. (К примеру, пьём кофе на набережной и т.п.)',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Вы — компания и хотите устроить что-то масштабное. Один пусть создаёт коллективную встречу, опишите кратко предложение.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Photo 5 meetings has horizontal filters and full width cards', (
    tester,
  ) async {
    await open(tester, const MeetingPage());
    db.emit('meets', [meeting], ids: ['meeting']);
    await tester.pumpAndSettle();
    final fields = find.byType(DropdownButtonFormField<String>);
    for (var i = 0; i < 50 && fields.evaluate().length != 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(fields, findsNWidgets(2));
    final country = tester.getRect(fields.at(0));
    final region = tester.getRect(fields.at(1));
    expect(country.top, region.top);
    expect(country.height, lessThanOrEqualTo(36));
    expect(country.right, lessThan(region.left));
    await tester.tap(fields.at(0));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Россия').hitTestable(), 200,
      scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Россия').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(fields.at(1));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Ленинградская область').hitTestable(), 200,
      scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ленинградская область').hitTestable());
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButtonFormField<String>>(fields.at(0)).initialValue, 'RU');
    expect(tester.widget<DropdownButtonFormField<String>>(fields.at(1)).initialValue, 'Ленинградская область');
    final card = find.byKey(const ValueKey('meeting-card-meeting'));
    expect(tester.getRect(card).left, 16);
    expect(tester.getRect(card).right, 344);
    final image = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName ==
              'assets/final_design/meeting_park.jpg',
    );
    expect(
      tester.getRect(find.text(meeting['description']! as String)).left,
      greaterThanOrEqualTo(tester.getRect(image).right),
    );
    final create = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('meeting-create-action')),
    );
    expect(
      create.style!.backgroundColor!.resolve({})!.a,
      closeTo(64 / 255, .001),
    );
    expect(find.text('Создать'), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.favorite_border)), findsOneWidget);
    await render(tester, 'photo5_meetings_360');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Photo 4 meeting chat leaves right photo free and messages before composer',
    (tester) async {
      await open(
        tester,
        ChatPage(
          groupId: 'meeting',
          groupName: 'Прогулка в парке',
          users: const ['viewer', 'other'],
          isUserJoin: true,
          submissions: submissions,
        ),
      );
      db.emit('meets/meeting/messages', [
        {
          'message': 'Отличная идея! Буду к 15:00.',
          'name': 'Анна',
          'sender': 'viewer',
          'time': Timestamp.fromDate(DateTime(2026, 9, 25, 12, 45)),
        },
        {
          'message': 'Привет! Встречаемся у главного входа?',
          'name': 'Алексей',
          'sender': 'other',
          'time': Timestamp.fromDate(DateTime(2026, 9, 25, 12, 40)),
        },
      ]);
      await tester.pumpAndSettle();
      final info = tester.getRect(
        find.byKey(const ValueKey('meeting-chat-column')),
      );
      expect(info.left, 0);
      expect(info.right, 240);
      final composer = tester.getRect(
        find.byKey(const ValueKey('meeting-message-composer')),
      );
      expect(composer.left, 0);
      expect(composer.right, 360);
      final incoming = find.text('Привет! Встречаемся у главного входа?');
      final outgoing = find.text('Отличная идея! Буду к 15:00.');
      expect(tester.getRect(incoming).top, greaterThan(info.bottom));
      expect(tester.getRect(outgoing).bottom, lessThan(composer.top));
      final translationActions = find.widgetWithText(TextButton, 'Перевести');
      expect(translationActions, findsNWidgets(2));
      final incomingBubble = find.ancestor(of: incoming, matching: find.byKey(const ValueKey('compact-meeting-bubble')));
      final outgoingBubble = find.ancestor(of: outgoing, matching: find.byKey(const ValueKey('compact-meeting-bubble')));
      expect(tester.getRect(incomingBubble).right, lessThanOrEqualTo(240));
      expect(tester.getRect(incomingBubble).height, lessThan(75));
      expect(tester.getRect(outgoingBubble).right, 350);
      expect(tester.getRect(find.text('Алексей')).bottom, lessThanOrEqualTo(tester.getRect(incomingBubble).top));
      final incomingTranslation = find.descendant(of: find.ancestor(of: incoming, matching: find.byType(TranslatableText)), matching: find.widgetWithText(TextButton, 'Перевести'));
      expect(tester.getRect(incomingTranslation).top, greaterThanOrEqualTo(tester.getRect(incomingBubble).bottom));
      for (final action in translationActions.evaluate()) {
        expect(
          tester.getRect(find.byWidget(action.widget)).top,
          greaterThan(info.bottom),
        );
        expect(
          tester.getRect(find.byWidget(action.widget)).bottom,
          lessThan(composer.top),
        );
      }
      expect(
        tester
            .getRect(find.byKey(const ValueKey('meeting-participants-action')))
            .bottom,
        lessThan(info.top),
      );
      expect(find.byWidgetPredicate((widget) => widget is Image &&
        widget.image is AssetImage &&
        (widget.image as AssetImage).assetName == 'assets/family_main.jpg'), findsOneWidget);
      final send = tester.widget<IconButton>(find.byKey(const ValueKey('meeting-send-action')));
      expect(send.style!.backgroundColor!.resolve({}), LrsTheme.peach);
      expect(send.style!.shape!.resolve({}), isA<CircleBorder>());
      await render(tester, 'photo4_meeting_chat_360');
      await tester.tap(find.byType(TextField));
      keyboard.value = 280;
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.send).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Compact meeting translation keeps original copy and edit', (tester) async {
    const original = 'Hello, this is my original message.';
    final data = <String, dynamic>{
      'message': original, 'sender': 'viewer', 'name': 'Анна',
      'time': Timestamp.fromDate(DateTime(2026, 10, 2, 15)),
    };
    db.documents['meets/meeting/messages/original'] = data;
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester, Scaffold(body: SingleChildScrollView(child: MessageTile(
      compactMeeting: true,
      message: LayoutSnapshot(db, 'meets/meeting/messages/original', data),
      chatId: 'meeting', sender: 'viewer', sentByMe: true, isRead: true,
      name: 'Анна', isChat: false,
    ))));
    await tester.tap(find.text('Перевести'));
    await tester.pumpAndSettle();
    expect(find.text('Перевод: $original'), findsOneWidget);
    await tester.longPress(find.text('Перевод: $original'));
    await tester.pumpAndSettle();
    expect(find.text('Ответить'), findsOneWidget);
    expect(find.text('Удалить у меня'), findsOneWidget);
    expect(find.text('Удалить для всех'), findsOneWidget);
    await tester.tap(find.text('Копировать'));
    await tester.pumpAndSettle();
    expect(copied, original);
    await tester.longPress(find.text('Перевод: $original'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Редактировать'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, original);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Показать оригинал'));
    await tester.pumpAndSettle();
    expect(find.text(original), findsOneWidget);
    expect(db.documents['meets/meeting/messages/original']!['message'], original);
    expect(db.updates, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Compact meeting full quote and keyboard fit at 200%', (tester) async {
    final original = List.filled(8, 'Подробное сообщение о прогулке и месте встречи.').join(' ');
    await open(tester, ChatPage(groupId: 'meeting', groupName: 'Прогулка в парке',
      users: const ['viewer', 'other'], isUserJoin: true, submissions: submissions), textScale: 2);
    db.emit('meets/meeting/messages', [{
      'message': original, 'sender': 'other', 'name': 'Алексей',
      'time': Timestamp.fromDate(DateTime(2026, 10, 2, 15)),
      'replyMessage': {'name': 'Анна', 'message': original},
    }]);
    await tester.pumpAndSettle();
    expect(find.text(original), findsNWidgets(2));
    for (final text in tester.widgetList<Text>(find.text(original))) {
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    }
    keyboard.value = 280;
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Отправить сообщение'));
    expect(find.byTooltip('Отправить сообщение').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
