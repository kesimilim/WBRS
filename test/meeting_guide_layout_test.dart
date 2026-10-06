import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

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
  const steps = [
    'Хотите пригласить кого-то? Укажите, куда идёте и что планируете.',
    'Собираете компанию? Кратко опишите идею и кого ждёте.',
    'Выберите страну и регион, укажите дату и время.',
    'Когда кто-то присоединится, организатор получит уведомление.',
  ];
  const titles = [
    'Индивидуальная встреча',
    'Коллективная встреча',
    'Место и время',
    'Участники',
  ];
  const icons = [
    Icons.account_circle_outlined,
    Icons.groups_outlined,
    Icons.calendar_month_outlined,
    Icons.people_alt_outlined,
  ];
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ClrsLocalizations.codes)
      code: Map<String, dynamic>.from(
        jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map,
      ),
  };

  setUpAll(() async {
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'Lato': 'assets/fonts/Lato-Regular.ttf',
      'CormorantGaramond': 'assets/fonts/CormorantGaramond-Variable.ttf',
      'Caveat': 'assets/fonts/Caveat-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  Future<void> pumpGuide(
    WidgetTester tester,
    String code, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(360, 640);
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
        // A normal Android status bar and three-button navigation bar leave
        // less space than a frameless 360x640 preview.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 48),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 48),
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open-guide'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MeetingGuidePage()),
              ),
              child: const Text('Open guide'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-guide')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '$code initial layout');
  }

  Finder guideScroll() => find.descendant(
    of: find.byKey(const ValueKey('meeting-guide-scroll')),
    matching: find.byType(Scrollable),
  );

  for (final code in ClrsLocalizations.codes) {
    testWidgets('meeting guide $code is fully reachable at 360x640', (
      tester,
    ) async {
      await pumpGuide(tester, code);
      final scroll = guideScroll();
      // ListView builds cards as they enter the viewport; the loop below
      // checks that all four complete instructions are reachable.
      expect(find.byType(ClrsPanel), findsAtLeastNWidgets(1));

      for (var index = 0; index < steps.length; index++) {
        final key = steps[index];
        final text = find.text(catalogs[code]![key]);
        await tester.scrollUntilVisible(text, 180, scrollable: scroll);
        await tester.ensureVisible(text);
        await tester.pumpAndSettle();
        expect(
          text.hitTestable(),
          findsOneWidget,
          reason: '$code: each complete instruction must be reachable',
        );
        expect(
          tester.widget<Text>(text).style!.fontSize,
          greaterThanOrEqualTo(11),
          reason: 'Reference compact body font remains readable',
        );
        expect(
          tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
          isFalse,
        );
        expect(tester.widget<Text>(text).maxLines, isNull);
        expect(
          tester.widget<Text>(text).overflow,
          isNot(TextOverflow.ellipsis),
        );
        final panel = find.byKey(ValueKey('meeting-guide-step-${index + 1}'));
        final bounds = tester.getRect(panel);
        expect(bounds.left, 12);
        expect(
          bounds.right,
          closeTo(360 * 2 / 3, .01),
          reason: '$code: the right third stays clear of instruction panels',
        );
        expect(
          find.descendant(
            of: panel,
            matching: find.text(catalogs[code]![titles[index]]),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: panel, matching: find.byIcon(icons[index])),
          findsOneWidget,
        );
      }

      final done = find.widgetWithText(
        ElevatedButton,
        catalogs[code]!['Понятно'],
      );
      await tester.scrollUntilVisible(done, 180, scrollable: scroll);
      await tester.pumpAndSettle();
      expect(done.hitTestable(), findsOneWidget);
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(find.byType(MeetingGuidePage), findsNothing);
      expect(find.byKey(const ValueKey('open-guide')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$code Done navigation');
    });
  }

  testWidgets('meeting guide keeps full text and Done reachable at 200%', (
    tester,
  ) async {
    await pumpGuide(tester, 'ru', textScale: 2);
    final scroll = guideScroll();
    expect(
      tester.state<ScrollableState>(scroll).position.maxScrollExtent,
      greaterThan(0),
    );
    for (var index = 0; index < steps.length; index++) {
      final key = steps[index];
      final text = find.text(catalogs['ru']![key]);
      await tester.scrollUntilVisible(text, 180, scrollable: scroll);
      await tester.ensureVisible(text);
      await tester.pumpAndSettle();
      expect(text.hitTestable(), findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
        isFalse,
      );
      expect(tester.widget<Text>(text).maxLines, isNull);
      expect(tester.widget<Text>(text).overflow, isNot(TextOverflow.ellipsis));
      final panel = find.byKey(ValueKey('meeting-guide-step-${index + 1}'));
      expect(tester.getRect(panel).right, closeTo(240, .01));
      expect(tester.takeException(), isNull);
    }
    final footer = find.byType(ClrsValuesFooter);
    await tester.scrollUntilVisible(footer, 180, scrollable: scroll);
    await tester.ensureVisible(footer);
    await tester.pumpAndSettle();
    expect(footer.hitTestable(), findsOneWidget);
    final done = find.widgetWithText(ElevatedButton, 'Понятно');
    await tester.scrollUntilVisible(done, 180, scrollable: scroll);
    await tester.pumpAndSettle();
    expect(done.hitTestable(), findsOneWidget);
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(find.byType(MeetingGuidePage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
