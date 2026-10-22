import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_users/profiles_list.dart';
import 'package:wbrs/presentation/screens/meet_chat_screen/chat_page.dart';
import 'package:wbrs/service/chat_submission.dart';
import 'package:wbrs/service/meeting_membership_service.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/group_badge.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/profile_composition.dart';

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

class _PeopleDatabase extends LayoutFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      path == 'users' ? _PeopleQuery(this, path) : super.collection(path);
}

// Test-only query double. These tests read stored profiles, never write them.
// ignore: subtype_of_sealed_class
class _PeopleQuery extends LayoutCollection {
  _PeopleQuery(super.db, super.path);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #where) return this;
    return super.noSuchMethod(invocation);
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get(
          [GetOptions? options]) async =>
      LayoutQuerySnapshot([
        for (final entry in db.documents.entries.where(
            (e) => e.key.startsWith('users/') && e.key.split('/').length == 2))
          LayoutSnapshot(db, entry.key, entry.value),
      ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ['en', 'de'])
      code: Map<String, dynamic>.from(
          jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map),
  };
  late _PeopleDatabase db;
  late String before;
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    await GeoCatalog.load();
  });
  test('Russian region menus keep republics last and Dagestan last', () async {
    final country = GeoCatalog.byCode(await GeoCatalog.load(), 'RU')!;
    final firstRepublic = country.regions
        .indexWhere((region) => region.toLowerCase().contains('республика'));
    expect(firstRepublic, greaterThan(0));
    expect(
        country.regions
            .take(firstRepublic)
            .any((region) => region.toLowerCase().contains('республика')),
        isFalse);
    expect(
        country.regions
            .skip(firstRepublic)
            .every((region) => region.toLowerCase().contains('республика')),
        isTrue);
    expect(country.regions.last, 'Республика Дагестан');
  });
  setUp(() {
    db = _PeopleDatabase();
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = LayoutMessaging();
    filterByGroup = false;
    filterCountry.clear();
    filterRegion.clear();
    filtrPol = '';
    ageStart = 18;
    ageEnd = 100;
    for (final uid in ['viewer', 'other']) {
      db.documents['users/$uid'] = {
        'uid': uid,
        'status': 'active',
        'fullName': uid == 'other' ? 'Анна Петрова' : 'Участник',
        'age': 33,
        'country': 'Россия',
        'region': 'Москва',
        'profilePic': '',
        'группа': '  КоРиЧнЕвАя  ',
      };
    }
    db.documents['meets/meeting'] = {
      'users': ['viewer', 'other'],
      'admin': 'viewer',
      'description': '',
      'usersWithoutNotification': <String>[],
    };
    before = jsonEncode(db.documents);
  });
  tearDown(() async {
    expect(db.updates, 0);
    expect(db.commits, 0);
    expect(db.transactions, 0);
    expect(jsonEncode(db.documents), before);
    await db.close();
  });

  Future<void> page(WidgetTester tester, Widget screen, String code,
      {bool settle = true}) async {
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        locale: Locale(code),
        supportedLocales: const [Locale('en'), Locale('de')],
        localizationsDelegates: [
          _CatalogDelegate(catalogs),
          ...ClrsLocalizations.delegates.skip(1),
        ],
        home: screen));
    await tester.pump();
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets(
      'People results translate country on locale change and retain region/name',
      (tester) async {
    const screen = ProfilesList(group: '', startPosition: 0);
    await page(tester, screen, 'en');
    final state = tester.state(find.byType(ProfilesList));
    await tester.scrollUntilVisible(find.text('Анна Петрова, 33'), 200,
        maxScrolls: 30, scrollable: find.byType(Scrollable).first);
    expect(find.text('Russia · Москва'), findsOneWidget);
    expect(find.text('Россия · Москва'), findsNothing);
    await page(tester, screen, 'de');
    expect(identical(tester.state(find.byType(ProfilesList)), state), isTrue);
    expect(find.text('Russland · Москва'), findsOneWidget);
    expect(find.text('Анна Петрова, 33'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Meeting participants translate country while the sheet stays open',
      (tester) async {
    final screen = ChatPage(
        groupId: 'meeting',
        groupName: 'Встреча друзей',
        users: const ['viewer', 'other'],
        isUserJoin: true,
        submissions: ChatSubmissionService(journal: MemorySubmissionJournal()),
        membershipService: MeetingMembershipService(
            meetingId: 'meeting',
            firestore: db,
            journal: MemorySubmissionJournal(),
            currentUid: () => 'viewer'));
    await page(tester, screen, 'en', settle: false);
    db.emit('meets/meeting/messages', []);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('meeting-participants-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('meeting-participants-action')));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('meeting-participants'));
    expect(sheet, findsOneWidget);
    expect(find.text('33 · Russia · Москва'), findsNWidgets(2));
    expect(find.text('Анна Петрова'), findsOneWidget);
    await page(tester, screen, 'de');
    expect(sheet, findsOneWidget);
    expect(find.text('33 · Russland · Москва'), findsNWidgets(2));
    expect(find.text('33 · Russia · Москва'), findsNothing);
    expect(find.text('Анна Петрова'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Profile facts canonicalize only known legacy groups for display',
      (tester) async {
    final data = Map<String, dynamic>.unmodifiable({
      'группа': '  КоРиЧнЕвАя  ',
      'country': 'Россия',
      'region': 'Москва',
    });
    final screen = Scaffold(body: ProfileFacts(data: data));
    await page(tester, screen, 'en');
    expect(find.text('brown'), findsOneWidget);
    expect(find.text('  КоРиЧнЕвАя  '), findsNothing);
    await page(tester, screen, 'de');
    expect(find.text('braun'), findsOneWidget);
    expect(find.text('Russland · Москва'), findsOneWidget);
    expect(data['группа'], '  КоРиЧнЕвАя  ');
    const unknown = '  Моя Неизвестная Группа  ';
    await page(tester,
        const Scaffold(body: ProfileFacts(data: {'группа': unknown})), 'en');
    expect(find.text(unknown), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Compound group ring translates visible and accessible labels on locale change',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      const raw = '  КрАсНо-БеЛаЯ  ';
      const screen = Scaffold(body: GroupBadge(group: raw, showLabel: true));
      await page(tester, screen, 'en');
      expect(find.text('red–white'), findsOneWidget);
      expect(find.byType(GroupRing), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Group: red–white')), findsOneWidget);
      await page(tester, screen, 'de');
      expect(find.text('rot–weiß'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Gruppe: rot–weiß')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
      'profile group caption colors each localized segment independently',
      (tester) async {
    const actual = 'красно-белая';
    await page(
        tester,
        const Scaffold(
            body: Column(children: [
          GroupCaption(group: actual, own: true),
          GroupCaption(group: actual, own: false, gender: 'м'),
          GroupCaption(group: actual, own: false, gender: 'ж'),
          GroupCaption(group: actual, own: false, gender: 'male'),
          GroupCaption(group: actual, own: false, gender: 'female'),
          GroupCaption(group: actual, own: false),
          GroupBadge(group: actual),
        ])),
        'en');
    expect(find.text('My group — red–white'), findsOneWidget);
    expect(find.text('His group — red–white'), findsNWidgets(2));
    expect(find.text('Her group — red–white'), findsNWidgets(2));
    expect(find.text('Group: red–white'), findsOneWidget);
    final own = tester.widget<Text>(find.text('My group — red–white'));
    final pieces = (own.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(pieces.first.text, 'My group — ');
    expect(pieces.first.style?.color, isNot(GroupBadge.colors['красно']));
    expect(pieces[1].text, 'red');
    expect(pieces[1].style?.color, GroupBadge.colors['красно']);
    expect(pieces.last.text, 'white');
    expect(pieces.last.style?.color, GroupBadge.colors['белая']);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    await page(tester,
        const Scaffold(body: GroupCaption(group: actual, own: true)), 'de');
    expect(find.text('Meine Gruppe — rot–weiß'), findsOneWidget);
    final german = tester.widget<Text>(find.text('Meine Gruppe — rot–weiß'));
    expect(
        (german.textSpan! as TextSpan)
            .children!
            .cast<TextSpan>()
            .last
            .style
            ?.color,
        GroupBadge.colors['белая']);
  });
  testWidgets(
      'Legacy avatar keeps canonical group color and translated semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      const screen =
          Scaffold(body: GroupAvatar(url: '', group: '  КоРиЧнЕвАя  '));
      await page(tester, screen, 'en');
      expect(find.bySemanticsLabel('Group: brown'), findsOneWidget);
      final ring = tester.widget<CustomPaint>(find.descendant(
          of: find.byType(GroupAvatar), matching: find.byType(CustomPaint)));
      expect(
          (ring.painter as dynamic).colors, [GroupBadge.colors['коричневая']]);
      await page(tester, screen, 'de');
      expect(find.bySemanticsLabel('Gruppe: braun'), findsOneWidget);
      expect(find.bySemanticsLabel('Group: brown'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
