import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/layout_firebase_fakes.dart';

class _CatalogDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _CatalogDelegate(this.catalogs);
  final Map<String, Map<String, dynamic>> catalogs;
  @override
  bool isSupported(Locale locale) => catalogs.containsKey(locale.languageCode);
  @override
  Future<ClrsLocalizations> load(Locale locale) => SynchronousFuture(
    ClrsLocalizations(locale, catalogs[locale.languageCode]!),
  );
  @override
  bool shouldReload(_CatalogDelegate old) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ClrsLocalizations.codes)
      code: Map<String, dynamic>.from(
        jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map,
      ),
  };
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'Lato': 'assets/fonts/Lato-Regular.ttf',
      'CormorantGaramond': 'assets/fonts/CormorantGaramond-Variable.ttf',
      'Caveat': 'assets/fonts/Caveat-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    firebaseAuth = LayoutAuth();
    firebaseFirestore = LayoutFirestore();
  });

  Future<void> pump(WidgetTester tester, String code, Widget page) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: LrsTheme.theme,
        locale: ClrsLocalizations.localeFor(code),
        supportedLocales: ClrsLocalizations.supportedLocales,
        localizationsDelegates: [
          _CatalogDelegate(catalogs),
          ...ClrsLocalizations.delegates.skip(1),
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '$code initial layout');
  }

  Future<void> reach(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  for (final code in ClrsLocalizations.codes) {
    testWidgets('Actual $code login: 320px/2x, validation and lower actions', (
      tester,
    ) async {
      await pump(tester, code, const LoginPage());
      final submit = find.widgetWithText(
        ElevatedButton,
        catalogs[code]!['Вход'],
      );
      expect(find.byType(TextFormField), findsNWidgets(2));
      await reach(tester, submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(
        find.text(catalogs[code]!['Введите корректный email']),
        findsOneWidget,
      );
      expect(
        find.text(catalogs[code]!['Пароль должен содержать 6 символов']),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: '$code validation layout');
      await reach(
        tester,
        find.widgetWithText(TextButton, catalogs[code]!['Регистрация']),
      );
      await reach(
        tester,
        find.widgetWithText(TextButton, catalogs[code]!['Забыли пароль?']),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
    testWidgets('Actual $code meeting guide: 320px/2x, complete scroll', (
      tester,
    ) async {
      await pump(tester, code, const MeetingGuidePage());
      // Approved compact cards open the full paragraphs in a detail dialog.
      // Verify both levels at large text instead of looking for removed inline copy.
      const details = [
        [
          'Вы один(одна) и хотите пригласить кого-то. Создавайте индивидуальную встречу, укажите в описании куда идёте, что будете делать.',
        ],
        [
          'Вас, например, двое. Один создаёт коллективную встречу и пишет: ждём двух девушек, и что вы предлагаете. (К примеру, пьём кофе на набережной и т.п.)',
          'Вы — компания и хотите устроить что-то масштабное. Один пусть создаёт коллективную встречу, опишите кратко предложение.',
        ],
        ['Выберите страну и регион, укажите дату и время.'],
        ['Когда кто-нибудь вступит, придёт уведомление как создателю.'],
      ];
      for (var i = 0; i < details.length; i++) {
        final card = find.byKey(ValueKey('meeting-guide-step-${i + 1}'));
        await tester.scrollUntilVisible(
          card,
          220,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('meeting-guide-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        await reach(tester, card);
        expect(tester.getSize(card).width, lessThanOrEqualTo(320 * 2 / 3));
        await tester.tap(card);
        await tester.pumpAndSettle();
        for (final key in details[i]) {
          final paragraph = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(catalogs[code]![key]),
          );
          expect(paragraph, findsOneWidget);
          // A paragraph may be taller than the dialog at 2x. Verify that both
          // ends can be scrolled into the viewport instead of tapping its center.
          final scrollable = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          );
          final position = tester.state<ScrollableState>(scrollable).position;
          await Scrollable.ensureVisible(
            tester.element(paragraph),
            alignment: 0,
          );
          await tester.pumpAndSettle();
          final viewport = tester.getRect(scrollable);
          expect(
            tester.getTopLeft(paragraph).dy,
            greaterThanOrEqualTo(viewport.top - 1),
          );
          await Scrollable.ensureVisible(
            tester.element(paragraph),
            alignment: 1,
          );
          await tester.pumpAndSettle();
          expect(
            tester.getBottomLeft(paragraph).dy,
            lessThanOrEqualTo(viewport.bottom + 1),
          );
          expect(position.outOfRange, isFalse);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(
              TextButton,
              catalogs[code]!['Понятно'],
            ),
          ),
        );
        await tester.pumpAndSettle();
      }
      final done = find.byKey(const ValueKey('meeting-guide-done'));
      await tester.scrollUntilVisible(
        done,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await reach(tester, done);
      expect(
        tester.takeException(),
        isNull,
        reason: '$code guide final layout',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
