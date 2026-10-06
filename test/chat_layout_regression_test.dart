import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// Firebase's test initializer supplies only platform-channel metadata.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/message_tile.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/presentation/screens/meet_chat_screen/chat_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/layout_firebase_fakes.dart';
import 'support/memory_submission_journal.dart';
import 'package:wbrs/service/meeting_membership_service.dart';
import 'package:wbrs/service/chat_submission.dart';

const longName = 'Александра Константинопольская Очень Длинное Имя';
const longMessage =
    'Подробное сообщение о встрече, которое должно переноситься без потери текста. ';
const longDescription = '$longMessage$longMessage$longMessage$longMessage';

class _GiftEnglishDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _GiftEnglishDelegate();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<ClrsLocalizations> load(Locale locale) =>
      SynchronousFuture(ClrsLocalizations(locale, const {
        'Подарок {name} подарен!': 'Gift {name} sent!',
        'Кофе и круассан': 'Coffee and croissant',
      }));
  @override
  bool shouldReload(_GiftEnglishDelegate old) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  late LayoutFirestore db;
  late ChatSubmissionService submissions;
  setUp(() {
    db = LayoutFirestore();
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = LayoutMessaging();
    submissions = ChatSubmissionService(journal: MemorySubmissionJournal());
    db.documents['meets/meeting'] = {
      'description': longDescription,
      'users': ['viewer', 'other'],
      'admin': 'viewer',
      'usersWithoutNotification': <String>[],
    };
    for (final uid in ['viewer', 'other']) {
      db.documents['users/$uid'] = {
        'uid': uid,
        'fullName': longName,
        'age': 33,
        'city': 'Москва',
        'country': 'Россия',
        'region': 'Москва',
        'profilePic': '',
        'группа': 'красно-белая'
      };
    }
  });
  tearDown(() async => db.close());

  Future<void> pumpScreen(
      WidgetTester tester, Widget screen, Size size, double scale,
      {double keyboard = 0}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard)),
            child: child!),
        home: screen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.3, 2.0]) {
      for (final sentByMe in [false, true]) {
        testWidgets(
            'Message and quote fit $width dp scale $scale own=$sentByMe',
            (tester) async {
          final data = {
            'message': '$longMessage$longMessage',
            'name': longName,
            'sender': 'other',
            'time': Timestamp.fromDate(DateTime(2026, 9, 21, 23, 59)),
            'replyMessage': {
              'message': longDescription,
              'name': longName,
              'sendBy': longName
            }
          };
          await pumpScreen(
              tester,
              Scaffold(
                  body: SingleChildScrollView(
                      child: MessageTile(
                          message: LayoutSnapshot(db, 'messages/example', data),
                          chatId: 'meeting',
                          sender: 'other',
                          sentByMe: sentByMe,
                          isRead: true,
                          name: longName,
                          isChat: false,
                          avatar: const CircleAvatar(radius: 22)))),
              Size(width, 640),
              scale);
          expect(tester.takeException(), isNull);
          expect(find.text('$longMessage$longMessage'), findsOneWidget);
        });
      }
    }
  }

  testWidgets('Landscape gift art fits a 320dp chat bubble without cropping',
      (tester) async {
    await pumpScreen(
        tester,
        Scaffold(
            body: SingleChildScrollView(
                child: MessageTile(
                    message: LayoutSnapshot(db, 'messages/gift', {
                      'image': 'assets/gifts/2.png',
                      'name': 'Кофе и круассан',
                      'ts': Timestamp.fromDate(DateTime(2026, 9, 21, 12)),
                    }),
                    chatId: 'meeting',
                    sender: 'other',
                    sentByMe: false,
                    isRead: true,
                    name: longName,
                    isChat: true,
                    avatar: const CircleAvatar(radius: 22)))),
        const Size(320, 640),
        1.3);
    final gift = find.byWidgetPredicate((widget) =>
        widget is Image &&
        widget.image is AssetImage &&
        (widget.image as AssetImage).assetName == 'assets/gifts/2.png');
    expect(gift, findsOneWidget);
    expect(tester.widget<Image>(gift).fit, BoxFit.contain);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Structured gift notice follows the viewer language',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: [
          const _GiftEnglishDelegate(),
          ...ClrsLocalizations.delegates.skip(1),
        ],
        supportedLocales: ClrsLocalizations.supportedLocales,
        theme: LrsTheme.theme,
        home: Scaffold(
            body: MessageTile(
                message: LayoutSnapshot(db, 'messages/gift-notice', {
                  'message': 'Старый текст для обратной совместимости',
                  'giftNoticeName': 'Кофе и круассан',
                  'ts': Timestamp.fromDate(DateTime(2026, 9, 21, 12)),
                }),
                chatId: 'meeting',
                sender: 'other',
                sentByMe: true,
                isRead: true,
                name: longName,
                isChat: true))));
    await tester.pumpAndSettle();
    expect(find.text('Gift Coffee and croissant sent! ❤️'), findsOneWidget);
    expect(find.text('Старый текст для обратной совместимости'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Meetings filters and lazy list scroll together in landscape at 2x',
      (tester) async {
    await pumpScreen(tester, const MeetingPage(), const Size(640, 320), 2);
    db.emit('meets', [
      for (var i = 0; i < 40; i++)
        {
          'name': 'Встреча $i',
          'description': longDescription,
          'datetime': '21.09.2026',
          'users': <String>[],
        }
    ]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Встреча 0'), 250);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Встреча 0'));
    await tester.pumpAndSettle();
    expect(find.text('Встреча 0').hitTestable(), findsOneWidget);
    expect(find.text('Встреча 39'), findsNothing);
  });

  testWidgets('Meetings show approved thumbnail without a saved image URL',
      (tester) async {
    await pumpScreen(tester, const MeetingPage(), const Size(320, 568), 1.3);
    db.emit('meets', [
      {
        'name': 'Прогулка в парке',
        'description': longDescription,
        'datetime': '21.09.2026',
        'users': <String>[],
      }
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Исходящие приглашения'), findsNothing);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/final_design/meeting_park.jpg'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Meeting details stay reachable on a short Android screen',
      (tester) async {
    db.documents['meets/meeting']!['datetime'] =
        Timestamp.fromDate(DateTime(2026, 9, 24, 12));
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: longName,
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(320, 568),
        1.3);
    await tester.pumpAndSettle();
    final summaryText = tester
        .widgetList<Text>(find.descendant(
            of: find.byKey(const ValueKey('meeting-summary-scroll')),
            matching: find.byType(Text)))
        .map((text) => text.data ?? '')
        .join(' | ');
    expect(summaryText, contains('2026'));
    expect(
        find.byKey(const ValueKey('meeting-summary-scroll')), findsOneWidget);
    final participantAction =
        find.byKey(const ValueKey('meeting-participants-action'));
    expect(tester.widget(participantAction), isA<TextButton>());
    expect(tester.getSize(participantAction).width, lessThan(280));
    expect(tester.getTopLeft(participantAction).dy,
        lessThan(tester.getTopLeft(find.text('О встрече')).dy));
    expect(participantAction.hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('О встрече'));
    await tester.pumpAndSettle();
    expect(find.text('О встрече').hitTestable(), findsOneWidget);
    await tester.tap(find.text('О встрече'));
    await tester.pumpAndSettle();
    expect(find.text('Описание встречи'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Group meeting pages leave the family background visible',
      (tester) async {
    final members = ['viewer', 'other', for (var i = 0; i < 12; i++) 'member$i'];
    db.documents['meets/meeting']!['users'] = members;
    for (var i = 0; i < 12; i++) {
      db.documents['users/member$i'] = {
        'uid': 'member$i',
        'fullName': 'Участник $i с длинным именем',
        'age': 33,
        'country': 'Россия',
        'region': 'Москва',
        'profilePic': '',
        'группа': 'красно-белая',
      };
    }
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: longName,
            users: members,
            isUserJoin: true),
        const Size(390, 844),
        1.3);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();

    void expectLeftColumn(String key) {
      final column = find.byKey(ValueKey(key));
      expect(column, findsOneWidget);
      expect(tester.getTopLeft(column).dx, 0);
      expect(tester.getSize(column).width, closeTo(390 * 2 / 3, 1));
    }

    expectLeftColumn('meeting-chat-column');
    await tester.ensureVisible(find.text('О встрече'));
    await tester.tap(find.text('О встрече'));
    await tester.pumpAndSettle();
    expectLeftColumn('meeting-description-column');
    expect(find.textContaining(longMessage), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('meeting-participants-action')));
    await tester.pumpAndSettle();
    expectLeftColumn('meeting-participants-column');
    await tester.scrollUntilVisible(
        find.text('Участник 11 с длинным именем'), 250,
        scrollable: find
            .descendant(
                of: find.byKey(const ValueKey('meeting-participants')),
                matching: find.byType(Scrollable))
            .first);
    await tester.pumpAndSettle();
    expect(find.text('Участник 11 с длинным именем').hitTestable(),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final entry in [
    ('Пикник в парке', 'Прогулка после обеда', 'meeting_picnic.jpg'),
    ('Кофе в парке', 'Встречаемся у кафе', 'meeting_coffee.jpg'),
    ('Пойдёмте в бар', 'Пиво и крылышки', 'meeting_bar.jpg'),
    ('Субботняя встреча', 'Прогулка по набережной', 'meeting_park.jpg'),
  ]) {
    testWidgets('Meetings use thematic image for ${entry.$1}', (tester) async {
      await pumpScreen(tester, const MeetingPage(), const Size(320, 568), 1.3);
      db.emit('meets', [
        {
          'name': entry.$1,
          'description': entry.$2,
          'datetime': '21.09.2026',
          'users': <String>[],
        }
      ]);
      await tester.pumpAndSettle();
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName ==
                  'assets/final_design/${entry.$3}'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Unknown meeting topic does not get a random park picture', (
    tester,
  ) async {
    await pumpScreen(tester, const MeetingPage(), const Size(320, 568), 1.3);
    db.emit('meets', [
      {
        'name': 'Встреча друзей',
        'description': 'Обсудим планы',
        'datetime': '21.09.2026',
        'users': <String>[],
      },
    ]);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/final_design/house.png',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chat load completing after dispose causes no state update',
      (tester) async {
    final pending = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['meets/meeting'] = pending.future;
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: longName,
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(320, 640),
        1.3);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(
        LayoutSnapshot(db, 'meets/meeting', db.documents['meets/meeting']));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chat stream failure is visible', (tester) async {
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: longName,
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(390, 844),
        1.3);
    db.streams['meets/meeting/messages']!.addError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Не удалось загрузить сообщения'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(640, 320)
  ]) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('Chat and participants fit $size at $scale with long content',
          (tester) async {
        await pumpScreen(
            tester,
            ChatPage(
                submissions: submissions,
                groupId: 'meeting',
                groupName: longName,
                users: ['viewer', 'other'],
                isUserJoin: true),
            size,
            scale);
        db.emit('meets/meeting/messages', [
          {
            'message': longDescription,
            'name': longName,
            'sender': 'other',
            'time': Timestamp.now(),
            'replyMessage': {'name': longName, 'message': longDescription}
          },
        ]);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Список участников'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Список участников'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
            find.byKey(const ValueKey('meeting-participants')), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Выйти из встречи'), 250,
            scrollable: find
                .descendant(
                    of: find.byKey(const ValueKey('meeting-participants')),
                    matching: find.byType(Scrollable))
                .first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Выйти из встречи'));
        await tester.pumpAndSettle();
        expect(find.text('Выйти из встречи').hitTestable(), findsOneWidget);
        final leave = tester.widget<OutlinedButton>(find.ancestor(
            of: find.text('Выйти из встречи'),
            matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
        final back = tester.widget<OutlinedButton>(find.ancestor(
            of: find.text('Вернуться в чат'),
            matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
        expect(leave.style, back.style);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Keyboard in landscape leaves send action reachable at 2x',
      (tester) async {
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: longName,
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(640, 320),
        2,
        keyboard: 160);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('Отправить сообщение'));
    expect(find.byTooltip('Отправить сообщение').hitTestable(), findsOneWidget);
  });

  testWidgets('Rebuild preserves chat scroll offset and subscription',
      (tester) async {
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: 'Встреча',
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(390, 844),
        1.3);
    db.emit('meets/meeting/messages', [
      for (var i = 0; i < 40; i++)
        {
          'message': '$longMessage$i',
          'name': longName,
          'sender': 'other',
          'time': Timestamp.now()
        }
    ]);
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    await tester.drag(list, const Offset(0, 300));
    await tester.pumpAndSettle();
    final controller = tester.widget<ListView>(list).controller!;
    final offset = controller.offset;
    expect(offset, greaterThan(0));
    // Notification state changes rebuild the page without replacing its stream/controller.
    await tester.tap(find.byTooltip('Выключить уведомления'));
    await tester.pump();
    expect(tester.widget<ListView>(list).controller, same(controller));
    expect(controller.offset, offset);
    expect(db.subscriptions['meets/meeting/messages'], 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Repeated send and uncertain retry commit once; confirmed send clears draft',
      (tester) async {
    db.commitGate = Completer<void>();
    final suppliedUsers = ['viewer', 'other'];
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: 'Встреча',
            users: suppliedUsers,
            isUserJoin: true),
        const Size(390, 844),
        1.3);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Один ответ');
    await tester.tap(find.byTooltip('Отправить сообщение'));
    await tester.pump();
    expect(db.transactions, 1);
    // A second tap cannot dispatch while the SDK future is pending.
    final sendingButton = find.byWidgetPredicate((widget) =>
        widget is IconButton &&
        (widget.tooltip == 'Проверить отправку' ||
            widget.tooltip == 'Отправить сообщение'));
    expect(tester.widget<IconButton>(sendingButton).onPressed, isNull);
    await tester.tap(sendingButton);
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.textContaining('Результат отправки пока неизвестен'),
        findsOneWidget);
    await tester.tap(find.byTooltip('Проверить отправку'));
    await tester.pump();
    expect(db.transactions, 1);
    db.commitGate!.complete();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        isEmpty);
    expect(
        db.documents.keys
            .where((path) => path.startsWith('meets/meeting/messages/')),
        hasLength(1));
    expect(suppliedUsers, ['viewer', 'other']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Failed send preserves text and permits a safe retry',
      (tester) async {
    db.commitError = StateError('denied');
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: 'Встреча',
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(390, 844),
        1.3);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Не терять текст');
    await tester.tap(find.byTooltip('Отправить сообщение'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'Не терять текст');
    expect(
        find.textContaining('Не удалось отправить сообщение'), findsOneWidget);
    db.commitError = null;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Отправить сообщение'));
    await tester.pumpAndSettle();
    expect(db.transactions, 2);
    expect(db.commits, 1);
    expect(
        db.documents.keys
            .where((path) => path.startsWith('meets/meeting/messages/')),
        hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Account change while preparing send performs no write',
      (tester) async {
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: 'Встреча',
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(390, 844),
        1.3);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    final pending = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['users/viewer'] = pending.future;
    await tester.enterText(find.byType(TextFormField), 'Приватное сообщение');
    await tester.tap(find.byTooltip('Отправить сообщение'));
    await tester.pump();
    (firebaseAuth as LayoutAuth).user = null;
    pending.complete(
        LayoutSnapshot(db, 'users/viewer', db.documents['users/viewer']));
    await tester.pump();
    expect(db.commits, 0);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Leaving and reopening pending chat checks original write',
      (tester) async {
    db.commitGate = Completer<void>();
    final page = ChatPage(
        submissions: submissions,
        groupId: 'meeting',
        groupName: 'Встреча',
        users: ['viewer', 'other'],
        isUserJoin: true);
    await pumpScreen(tester, page, const Size(390, 844), 1.3);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextFormField), 'Одна отправка через выход');
    await tester.tap(find.byTooltip('Отправить сообщение'));
    await tester.pump();
    expect(db.transactions, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await pumpScreen(tester, page, const Size(390, 844), 1.3);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'Одна отправка через выход');
    await tester.tap(find.byTooltip('Проверить отправку'));
    await tester.pump();
    expect(db.transactions, 1);
    db.commitGate!.complete();
    await tester.pumpAndSettle();
    expect(
        db.documents.keys
            .where((path) => path.startsWith('meets/meeting/messages/')),
        hasLength(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'Archived chat loads older messages without subscribing to all at once',
      (tester) async {
    db.serveEmittedQueries = true;
    db.documents['meets/meeting']!['users'] = ['other'];
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: 'Архив',
            users: ['other'],
            isUserJoin: false),
        const Size(390, 844),
        1.3);
    final archived = [
      for (var i = 0; i < 100; i++)
        {
          'message': 'Архив $i',
          'name': longName,
          'sender': 'other',
          'time': Timestamp.now()
        }
    ];
    db.emit('users/viewer/removed_meets/meeting/messages', archived);
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
        (list.childrenDelegate as SliverChildBuilderDelegate).childCount, 81);
    await tester.scrollUntilVisible(find.text('Загрузить ещё'), 400,
        maxScrolls: 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Загрузить ещё'));
    await tester.pumpAndSettle();
    final expanded = tester.widget<ListView>(find.byType(ListView));
    expect((expanded.childrenDelegate as SliverChildBuilderDelegate).childCount,
        100);
    expect(db.streamedDocuments, 81);
    expect(db.fetchedDocuments, 20);
    expect(db.fetchedQueries, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Silent meeting chat stream offers retry', (tester) async {
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: 'Встреча',
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(390, 844),
        1);
    await tester.pump(const Duration(seconds: 21));
    expect(
        find.textContaining('Не удалось загрузить сообщения'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    db.emit('meets/meeting/messages', [
      {
        'message': 'После повтора',
        'name': longName,
        'sender': 'other',
        'time': Timestamp.now()
      }
    ]);
    await tester.pumpAndSettle();
    expect(find.text('После повтора'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Successful join refreshes participants without reopening the chat',
      (tester) async {
    db.documents['meets/meeting']!['users'] = ['other'];
    db.documents['users/viewer']!['fullName'] = 'Новый участник';
    db.documents['meets/meeting']!['description'] = '';
    db.updateHandler = (path, data) async {
      expect(path, 'meets/meeting');
      expect(data.containsKey('users'), isTrue);
      db.documents[path]!['users'] = ['other', 'viewer'];
    };
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            membershipService: MeetingMembershipService(
                meetingId: 'meeting',
                firestore: db,
                journal: MemorySubmissionJournal(),
                currentUid: () => 'viewer'),
            groupId: 'meeting',
            groupName: 'Встреча',
            users: ['other'],
            isUserJoin: false),
        const Size(390, 844),
        1.3);
    db.emit('users/viewer/removed_meets/meeting/messages', []);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Присоединиться'));
    await tester.pump();
    await tester.pump();
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Список участников'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Список участников'));
    await tester.pumpAndSettle();
    expect(find.text('Новый участник'), findsOneWidget);
    expect(db.updates, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Repeated notification toggle waits for its pending write',
      (tester) async {
    final update = Completer<void>();
    db.updateHandler = (_, __) => update.future;
    await pumpScreen(
        tester,
        ChatPage(
            submissions: submissions,
            groupId: 'meeting',
            groupName: 'Встреча',
            users: ['viewer', 'other'],
            isUserJoin: true),
        const Size(390, 844),
        1.3);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    final toggle = find.byTooltip('Выключить уведомления');
    await tester.tap(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    expect(db.updates, 1);
    update.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Включить уведомления'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
