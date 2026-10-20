import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/language_picker.dart';
import 'package:wbrs/localization/locale_controller.dart';
import 'package:wbrs/shared/lrs_theme.dart';

Set<String> placeholders(String text) => RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}')
    .allMatches(text)
    .map((match) => match.group(1)!)
    .toSet();
Iterable<String> forms(dynamic entry) =>
    entry is String ? [entry] : (entry as Map).values.cast<String>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ClrsLocalizations.codes)
      code: Map<String, dynamic>.from(
          jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map),
  };
  test('gift notices use catalog names while free text keeps real translation',
      () {
    final en = ClrsLocalizations(const Locale('en'), catalogs['en']!);
    expect(en.literalTranslation('Подарок «Диадема с рубинами» ❤️'),
        'Gift «Ruby tiara» ❤️');
    expect(en.literalTranslation('Подарок «Диадема с рубинами»'),
        'Gift «Ruby tiara»');
    expect(en.literalTranslation('Подарок «Неизвестный предмет» ❤️'), isNull);
    expect(en.literalTranslation('Хочу подарить тебе диадему'), isNull);
    final ru = ClrsLocalizations(const Locale('ru'), catalogs['ru']!);
    expect(ru.literalTranslation('Подарок «Диадема с рубинами» ❤️'),
        'Подарок «Диадема с рубинами» ❤️');
  });
  test('Exactly 23 catalogs have complete keys and matching placeholders', () {
    expect(ClrsLocalizations.codes.toSet(), {
      'en',
      'de',
      'es',
      'fr',
      'it',
      'pt',
      'el',
      'ru',
      'sr',
      'pl',
      'sl',
      'sk',
      'cs',
      'bg',
      'ro',
      'mk',
      'hu',
      'sv',
      'nb',
      'fi',
      'da',
      'nl',
      'is',
    });
    expect(
        Directory('assets/l10n')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.json'))
            .length,
        23);
    final source = catalogs['ru']!;
    expect(source, isNotEmpty);
    for (final language in catalogs.entries) {
      expect(language.value.keys.toSet(), source.keys.toSet(),
          reason: language.key);
      for (final message in source.entries) {
        final translations = forms(language.value[message.key]);
        final expected = forms(message.value).expand(placeholders).toSet();
        if (language.value[message.key] is Map) {
          expect(
              (language.value[message.key] as Map).containsKey('other'), isTrue,
              reason: '${language.key}: ${message.key}');
        }
        for (final translated in translations) {
          expect(translated.trim(), isNotEmpty,
              reason: '${language.key}: ${message.key}');
          expect(placeholders(translated), expected,
              reason: '${language.key}: ${message.key}');
          expect(translated, isNot(contains('TODO_TRANSLATE')));
        }
      }
    }
  });
  test('Plural rules distinguish Russian, English and Slovenian forms', () {
    const key = '{count} участников';
    final ru = ClrsLocalizations(const Locale('ru'), {
      key: {
        'one': '{count} участник',
        'few': '{count} участника',
        'many': '{count} участников',
        'other': '{count} участника',
      }
    });
    expect([1, 2, 5, 21, 22, 25].map((count) => ru.text(key, count: count)), [
      '1 участник',
      '2 участника',
      '5 участников',
      '21 участник',
      '22 участника',
      '25 участников'
    ]);
    final en = ClrsLocalizations(const Locale('en'), {
      key: {'one': '{count} participant', 'other': '{count} participants'}
    });
    expect(en.text(key, count: 1), '1 participant');
    expect(en.text(key, count: 2), '2 participants');
    final sl = ClrsLocalizations(const Locale('sl'), {
      key: {
        'one': '{count} udeleženec',
        'two': '{count} udeleženca',
        'few': '{count} udeleženci',
        'other': '{count} udeležencev',
      }
    });
    expect(sl.text(key, count: 2), '2 udeleženca');
  });
  test(
      'Actual duration catalogs select day forms without relative-time wording',
      () {
    const expected = {
      'ru': ['1 день', '2 дня', '5 дней', '21 день'],
      'en': ['1 day', '2 days', '5 days', '21 days'],
      'sl': ['1 dan', '2 dneva', '5 dni', '21 dni'],
      'ro': ['1 zi', '2 zile', '5 zile', '21 de zile'],
    };
    for (final entry in expected.entries) {
      final locale = ClrsLocalizations(Locale(entry.key), catalogs[entry.key]!);
      expect(
          [1, 2, 5, 21]
              .map((count) => locale.text('{count} дней', count: count)),
          entry.value);
    }
    for (final code in ClrsLocalizations.codes) {
      final locale =
          ClrsLocalizations(ClrsLocalizations.localeFor(code), catalogs[code]!);
      for (final count in [0, 1, 2, 3, 5, 11, 21, 100]) {
        expect(locale.text('{count} дней', count: count),
            isNot(contains('{count}')));
      }
    }
  });
  test(
      'Parameters are substituted once, with explicit validation and fallbacks',
      () {
    final localization = ClrsLocalizations(
        const Locale('de'), {'Привет, {name}!': 'Hallo, {name}!'},
        english: {'Ошибка': 'Error'},
        russian: {'Редкий ключ': 'Русский запасной текст'});
    expect(localization.text('Привет, {name}!', args: {'name': '{count}'}),
        'Hallo, {count}!');
    expect(() => localization.text('Привет, {name}!'), throwsArgumentError);
    expect(localization.text('Ошибка'), 'Error');
    expect(localization.text('Редкий ключ'), 'Русский запасной текст');
    expect(localization.text('Неизвестный ключ'), 'Неизвестный ключ');
  });
  test('Device locale, saved choice, Norwegian alias and unsupported fallback',
      () async {
    SharedPreferences.setMockInitialValues({});
    final controller = LocaleController();
    await controller.initialize(deviceLocale: const Locale('de', 'AT'));
    expect(controller.locale.languageCode, 'de');
    await controller.setLanguage('fr');
    final restored = LocaleController();
    await restored.initialize(deviceLocale: const Locale('ru'));
    expect(restored.locale.languageCode, 'fr');
    await Future.wait(
        [controller.setLanguage('es'), controller.setLanguage('nb')]);
    final last = LocaleController();
    await last.initialize(deviceLocale: const Locale('en'));
    expect(last.locale.languageCode, 'nb');
    expect(
        ClrsLocalizations.resolveLocale(const Locale('no')).languageCode, 'nb');
    expect(
        ClrsLocalizations.resolveLocale(const Locale('ja')).languageCode, 'en');
    await expectLater(
        controller.setLanguage('not-a-locale'), throwsArgumentError);
  });
  for (final code in ClrsLocalizations.codes) {
    test('$code loads, renders parameters and formats dates/numbers', () async {
      final locale =
          await ClrsLocalizations.load(ClrsLocalizations.localeFor(code));
      expect(locale.text('Сохранить'), catalogs[code]!['Сохранить']);
      expect(locale.date(DateTime(2026, 9, 21)), contains('2026'));
      expect(locale.shortDate(DateTime(2026, 9, 21)), isNotEmpty);
      expect(locale.time(DateTime(2026, 9, 21, 18, 30)), isNotEmpty);
      expect(locale.number(12345.67, decimalDigits: 2), isNotEmpty);
    });
  }
  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('All languages remain selectable at $size and 2x text',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = LocaleController();
      await controller.initialize(deviceLocale: const Locale('ru'));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final loaded = await tester
          .runAsync(() => ClrsLocalizations.load(const Locale('ru')));
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          locale: const Locale('ru'),
          supportedLocales: ClrsLocalizations.supportedLocales,
          localizationsDelegates: [
            _LoadedDelegate(loaded!),
            ...ClrsLocalizations.delegates.skip(1),
          ],
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!),
          home: Scaffold(body: LanguagePickerButton(controller: controller))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Русский'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Íslenska'), 300);
      await tester.tap(find.text('Íslenska'));
      await tester.pumpAndSettle();
      expect(controller.locale.languageCode, 'is');
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

// Asset IO is covered by the 23 load tests. Supplying the awaited catalog
// synchronously keeps widget layout tests independent of host IO timing.
class _LoadedDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _LoadedDelegate(this.value);
  final ClrsLocalizations value;
  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == value.locale.languageCode;
  @override
  Future<ClrsLocalizations> load(Locale locale) => SynchronousFuture(value);
  @override
  bool shouldReload(_LoadedDelegate old) => old.value != value;
}
