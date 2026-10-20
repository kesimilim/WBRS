import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/comment_submission.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/presentation/screens/feed/post_detail_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/show/about_individual_meet.dart';
import 'package:wbrs/presentation/screens/notifications_center/notifications_page.dart';
import 'package:wbrs/service/meeting_membership_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/profile_composition.dart';
import 'package:wbrs/shared/translatable_text.dart';

import 'support/layout_firebase_fakes.dart';
import 'support/memory_submission_journal.dart';

class _CatalogDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _CatalogDelegate(this.catalogs);
  final Map<String, Map<String, dynamic>> catalogs;
  @override
  bool isSupported(Locale locale) => catalogs.containsKey(locale.languageCode);
  @override
  Future<ClrsLocalizations> load(Locale locale) => SynchronousFuture(
      ClrsLocalizations(locale, catalogs[locale.languageCode]!));
  @override
  bool shouldReload(_CatalogDelegate old) => false;
}

class _Comments extends Fake implements SocialService {
  _Comments(this.rows);
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> rows;
  @override
  Future<bool> canModerateComments() async => false;
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> comments(String postId) =>
      Stream.value(LayoutQuerySnapshot(rows));
}

class _StorageFirebaseApp extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    final apps = await super.initializeCore();
    for (final app in apps) {
      app.options.storageBucket = 'clrs-test-bucket';
    }
    return apps;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ['en', 'de', 'sr'])
      code: Map<String, dynamic>.from(
          jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map),
  };
  const interests = 'Люблю читать и гулять по вечерам';
  const about = 'Ищу серьёзные отношения и человека с чувством юмора';
  final profile = Map<String, dynamic>.unmodifiable({
    'fullName': 'Екатерина Петрова',
    'age': 32,
    'rost': 171,
    'country': 'Германия',
    'region': 'Berlin',
    'группа': 'коричневая',
    'deti': false,
    'hobbi': interests,
    'about': about,
  });
  late LayoutFirestore db;
  setUpAll(() async {
    setupFirebaseCoreMocks();
    TestFirebaseCoreHostApi.setUp(_StorageFirebaseApp());
    await Firebase.initializeApp();
  });
  setUp(() {
    firebaseAuth = LayoutAuth();
    db = LayoutFirestore();
    firebaseFirestore = db;
    db.documents['users/owner'] = Map.of(profile);
  });
  tearDown(() => db.close());

  Future<void> pumpProfile(
      WidgetTester tester, ContentTranslationService service, String code,
      {double scale = 1, Size size = const Size(320, 640)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(ContentTranslationScope(
      service: service,
      child: MaterialApp(
        theme: LrsTheme.theme,
        locale: Locale(code),
        supportedLocales: const [Locale('en'), Locale('de')],
        localizationsDelegates: [
          _CatalogDelegate(catalogs),
          ...ClrsLocalizations.delegates.skip(1),
        ],
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(children: [
              ProfilePortrait(
                  photo: '',
                  name: profile['fullName'],
                  group: profile['группа'],
                  location: 'Berlin',
                  online: true),
              ProfileFacts(data: profile),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Profile interests/about automatically translate on locale change; originals and identities never write',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <Map<String, dynamic>>[];
    final translations = {
      'en': {
        interests: 'I enjoy reading and evening walks',
        about:
            'Looking for a serious relationship and someone with a sense of humor',
      },
      'de': {
        interests: 'Ich lese gern und gehe abends spazieren',
        about: 'Ich suche eine feste Beziehung und einen Menschen mit Humor',
      },
    };
    final service = ContentTranslationService(
        endpoint: Uri.parse('https://translation.example.invalid'),
        currentUserId: () => 'viewer',
        idToken: () async => 'test-token',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.headers['Authorization'], 'Bearer test-token');
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(payload);
          final language = payload['targetLanguage'] as String;
          return http.Response(
              jsonEncode({
                'translatedText': translations[language]![payload['text']],
                'targetLanguage': language,
                'detectedSourceLanguage': 'ru',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(service.dispose);
    await pumpProfile(tester, service, 'en');
    expect(find.text('Interests and hobbies'), findsOneWidget);
    expect(find.text('About me'), findsOneWidget);
    for (final text in translations['en']!.values) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.text(interests), findsNothing);
    expect(find.textContaining('Екатерина Петрова', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('brown', findRichText: true), findsWidgets);
    expect(requests.map((r) => r['text']), unorderedEquals([interests, about]));
    expect(tester.takeException(), isNull);

    // Locale changes while the same profile widgets remain mounted.
    await pumpProfile(tester, service, 'de', scale: 2);
    for (final text in translations['de']!.values) {
      expect(find.text(text), findsOneWidget);
    }
    expect(requests.where((r) => r['targetLanguage'] == 'de').length, 2);
    expect(find.textContaining('Екатерина Петрова', findRichText: true),
        findsOneWidget);
    expect(tester.takeException(), isNull);

    // A real original/translation toggle belongs to each field, not to a fake
    // translatedText database value. The source is never replaced in storage.
    final field = find
        .byWidgetPredicate((w) => w is TranslatableText && w.text == interests);
    final originalButton =
        find.descendant(of: field, matching: find.byType(TextButton));
    await tester.ensureVisible(originalButton);
    await tester.tap(originalButton);
    await tester.pumpAndSettle();
    expect(find.text(interests), findsOneWidget);
    expect(profile['hobbi'], interests);
    expect(profile['about'], about);
    expect(db.documents['users/owner'], profile);
    expect(db.commits, 0);
    expect(db.updates, 0);
    expect(requests.length, 4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Profile translation failure preserves original with retry at phone and landscape 2x',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var requests = 0;
    final service = ContentTranslationService(
        endpoint: Uri.parse('https://translation.example.invalid'),
        currentUserId: () => 'viewer',
        idToken: () async => 'test-token',
        client: MockClient((_) async {
          requests++;
          return http.Response('Unavailable', 503);
        }));
    addTearDown(service.dispose);
    for (final size in [const Size(320, 640), const Size(640, 320)]) {
      await pumpProfile(tester, service, 'en', scale: 2, size: size);
      expect(find.text(interests), findsOneWidget);
      expect(find.text(about), findsOneWidget);
      expect(find.text('Could not translate. Please try again.'),
          findsNWidgets(2));
      expect(tester.takeException(), isNull);
      final field = find
          .byWidgetPredicate((w) => w is TranslatableText && w.text == about);
      final retry =
          find.descendant(of: field, matching: find.byType(TextButton));
      await tester.ensureVisible(retry);
      expect(retry.hitTestable(), findsOneWidget);
      final before = requests;
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(requests, before + 1);
      expect(find.text(about), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(db.documents['users/owner'], profile);
    expect(db.commits, 0);
    expect(db.updates, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Meeting description reaches backend for English and Serbian',
      (tester) async {
    const description = 'Приходите на вечернюю прогулку в нашем парке';
    final requests = <Map<String, dynamic>>[];
    db.documents['meets/translation-meet'] = {
      'name': 'Вечерняя прогулка',
      'description': description,
      'admin': 'owner',
      'users': ['owner'],
      'country': 'Россия',
      'region': 'Москва',
    };
    final service = ContentTranslationService(
        endpoint: Uri.parse('https://translation.example.invalid'),
        currentUserId: () => 'viewer',
        idToken: () async => 'test-token',
        client: MockClient((request) async {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(payload);
          final language = payload['targetLanguage'] as String;
          return http.Response(
              jsonEncode({
                'translatedText': payload['text'] == description
                    ? language == 'en'
                        ? 'Join our evening walk in the park'
                        : 'Pridružite nam se u večernjoj šetnji parkom'
                    : payload['text'],
                'targetLanguage': language,
                'detectedSourceLanguage': 'ru',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(service.dispose);
    final membership = MeetingMembershipService(
      meetingId: 'translation-meet',
      firestore: db,
      journal: MemorySubmissionJournal(),
      currentUid: () => 'viewer',
    );
    for (final language in ['en', 'sr']) {
      await tester.pumpWidget(ContentTranslationScope(
          service: service,
          child: MaterialApp(
            theme: LrsTheme.theme,
            locale: ClrsLocalizations.localeFor(language),
            supportedLocales: ClrsLocalizations.supportedLocales,
            localizationsDelegates: [
              _CatalogDelegate(catalogs),
              ...ClrsLocalizations.delegates.skip(1),
            ],
            home: AboutIndividualMeet(
              key: ValueKey(language),
              meetingDoc: LayoutSnapshot(db, 'meets/translation-meet',
                  db.documents['meets/translation-meet']),
              doc: LayoutSnapshot(db, 'users/owner', profile),
              membershipService: membership,
            ),
          )));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byWidgetPredicate((widget) =>
              widget is TranslatableText && widget.text == description),
          120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final expected = language == 'en'
          ? 'Join our evening walk in the park'
          : 'Pridružite nam se u večernjoj šetnji parkom';
      expect(find.text(expected), findsOneWidget);
      expect(
          requests.where((request) =>
              request['text'] == description &&
              request['targetLanguage'] == language),
          hasLength(1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Gift notification free text is translated without writes',
      (tester) async {
    const title = 'Вам прислали подарок';
    const body = 'Друг прислал вам зайчика с капустой';
    final requests = <String>[];
    final service = ContentTranslationService(
        endpoint: Uri.parse('https://translation.example.invalid'),
        currentUserId: () => 'viewer',
        idToken: () async => 'test-token',
        client: MockClient((request) async {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          final source = payload['text'] as String;
          requests.add(source);
          return http.Response(
              jsonEncode({
                'translatedText': source == title
                    ? 'You received a gift'
                    : 'A friend sent you a bunny with cabbage',
                'targetLanguage': 'en',
                'detectedSourceLanguage': 'ru',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(service.dispose);
    await tester.pumpWidget(ContentTranslationScope(
        service: service,
        child: MaterialApp(
          theme: LrsTheme.theme,
          locale: const Locale('en'),
          supportedLocales: ClrsLocalizations.supportedLocales,
          localizationsDelegates: [
            _CatalogDelegate(catalogs),
            ...ClrsLocalizations.delegates.skip(1),
          ],
          home: const NotificationsPage(),
        )));
    await tester.pump();
    db.emit('users/viewer/notifications', [
      {'type': 'gift', 'title': title, 'body': body, 'read': false}
    ]);
    await tester.pumpAndSettle();
    expect(find.text('You received a gift'), findsOneWidget);
    expect(find.text('A friend sent you a bunny with cabbage'), findsOneWidget);
    expect(requests, unorderedEquals([title, body]));

    db.emit('users/viewer/notifications', [
      {'type': 'gift', 'giftName': 'Кофе и круассан', 'read': false}
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Gift'), findsOneWidget);
    expect(find.text('Coffee and croissant'), findsOneWidget);
    expect(requests, unorderedEquals([title, body]));
    expect(db.updates, 0);
    expect(db.commits, 0);
  });

  testWidgets(
      'Post, comment and expanded reply use real translation; draft and stale database translation stay untouched',
      (tester) async {
    final requests = <String>[];
    final originals = [
      'Текст публикации о прогулке',
      'Комментарий о прекрасной погоде',
      'Ответ о вечерней прогулке'
    ];
    final translated = [
      'A post about a walk',
      'A comment about lovely weather',
      'A reply about an evening walk'
    ];
    final service = ContentTranslationService(
        endpoint: Uri.parse('https://translation.example.invalid'),
        currentUserId: () => 'viewer',
        idToken: () async => 'test-token',
        client: MockClient((request) async {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          final source = payload['text'] as String;
          requests.add(source);
          return http.Response(
              jsonEncode({
                'translatedText': translated[originals.indexOf(source)],
                'targetLanguage': 'en',
                'detectedSourceLanguage': 'ru',
              }),
              200);
        }));
    addTearDown(service.dispose);
    final post = Map<String, dynamic>.unmodifiable({
      'text': originals[0],
      'authorName': 'Мария',
      'translatedText': 'STALE DATABASE TRANSLATION MUST NEVER DISPLAY',
    });
    final rootData = Map<String, dynamic>.unmodifiable(
        {'authorName': 'Иван', 'text': originals[1]});
    final replyData = Map<String, dynamic>.unmodifiable(
        {'authorName': 'Пётр', 'text': originals[2], 'parentId': 'root'});
    final social = _Comments([
      LayoutSnapshot(db, 'posts/post/comments/root', rootData),
      LayoutSnapshot(db, 'posts/post/comments/reply', replyData),
    ]);
    final journal = MemorySubmissionJournal();
    await tester.pumpWidget(ContentTranslationScope(
      service: service,
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en')],
        localizationsDelegates: [
          _CatalogDelegate(catalogs),
          ...ClrsLocalizations.delegates.skip(1)
        ],
        home: PostDetailPage(
            postId: 'post',
            post: post,
            social: social,
            submissions: CommentSubmissionService(
                social: social, currentUid: () => 'viewer', journal: journal)),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(translated[0]), findsOneWidget);
    expect(find.text(post['translatedText']), findsNothing);
    expect(find.text('Мария'), findsOneWidget);
    final expand = find.text(catalogs['en']!['Показать ответы']);
    await tester.scrollUntilVisible(expand, 150,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await tester.pumpAndSettle();
    expect(find.text(translated[1]), findsOneWidget);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(translated[2]));
    expect(find.text(translated[2]), findsOneWidget);
    expect(find.text('Пётр'), findsOneWidget);
    const draft = 'Мой неопубликованный комментарий';
    await tester.enterText(find.byType(TextField), draft);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        draft);
    expect(requests, unorderedEquals(originals));
    expect(post['text'], originals[0]);
    expect(rootData['text'], originals[1]);
    expect(replyData['text'], originals[2]);
    expect(journal.records, isEmpty);
    expect(db.commits, 0);
    expect(db.updates, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
