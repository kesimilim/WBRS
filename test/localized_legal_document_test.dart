import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/pages/policy/soglashenie.dart';
import 'package:wbrs/app/pages/policy/confidecialnost.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class _LegalBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      key == 'assets/agreement.txt' ||
          key == 'assets/policy.txt' ||
          key.startsWith('assets/legal/')
      ? SynchronousFuture(File(key).readAsStringSync())
      : rootBundle.loadString(key, cache: cache);
}

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
  final source = File('assets/agreement.txt').readAsStringSync();
  final translated = File('assets/legal/en/agreement.txt').readAsStringSync();
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ClrsLocalizations.codes)
      code: Map<String, dynamic>.from(
        jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map,
      ),
  };
  testWidgets(
    'privacy opens the complete supplied policy offline with large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DefaultAssetBundle(
          bundle: _LegalBundle(),
          child: MaterialApp(
            locale: const Locale('ru'),
            supportedLocales: ClrsLocalizations.supportedLocales,
            localizationsDelegates: [
              _CatalogDelegate(catalogs),
              ...ClrsLocalizations.delegates.skip(1),
            ],
            theme: LrsTheme.theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Politica(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data!;
      expect(text, File('assets/policy.txt').readAsStringSync());
      expect(
        text,
        startsWith('Политика в\u00a0отношении обработки персональных данных'),
      );
      expect(text, contains('12.3.'));
      expect(text, contains('366514852674'));
      expect(text, isNot(contains('пока недоступна')));
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'English agreement retains all paragraphs, clauses and literal details',
    () {
      // A changed source or translation needs a new full comparison, not only
      // a matching set of section numbers.
      expect(
        sha256
            .convert(File('assets/agreement.txt').readAsBytesSync())
            .toString(),
        '22b9d2614ab8602023f4d7854b72c08aee141253a05df07e3b2d3bea22b07127',
      );
      expect(
        sha256
            .convert(File('assets/legal/en/agreement.txt').readAsBytesSync())
            .toString(),
        'a268fc05364d9da6f991492cbbf12777d2e58da97c6251ed918b8f3ee6a31f7c',
      );
      List<String> clauses(String text) => RegExp(
        r'^([0-9]+(?:\.[0-9]+)*)\.? ',
        multiLine: true,
      ).allMatches(text).map((m) => m[1]!).toList();
      expect(clauses(translated), clauses(source));
      expect(clauses(translated).length, 80);
      expect(translated.split('\n').length, source.split('\n').length);
      for (final pattern in [
        r'https?://\S+',
        r'[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
        r'\b[0-9]{2,}\b',
      ]) {
        List<String> details(String text) =>
            RegExp(pattern).allMatches(text).map((m) => m[0]!).toList();
        expect(details(translated), details(source), reason: pattern);
      }
      expect(translated, startsWith('1. Subject of the Agreement\n'));
      expect(
        translated,
        endsWith('remains in force for an indefinite period.\n'),
      );
      expect(translated, contains('5.3.'));
      expect(translated, contains('7.8. Automatic renewal.'));
    },
  );
  test('English privacy policy preserves all clauses and literal details', () {
    final original = File('assets/policy.txt').readAsStringSync();
    final english = File('assets/legal/en/policy.txt').readAsStringSync();
    final clauses = RegExp(r'^([0-9]+(?:\.[0-9]+)*)\.? ', multiLine: true);
    expect(
      clauses.allMatches(english).map((m) => m[1]).toList(),
      clauses.allMatches(original).map((m) => m[1]).toList(),
    );
    expect(english.split('\n\n').length, original.split('\n\n').length);
    for (final pattern in [
      r'https?://\S+',
      r'[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
      r'\b[0-9]{2,}\b',
    ]) {
      List<String> details(String text) =>
          RegExp(pattern).allMatches(text).map((m) => m[0]!).toList()..sort();
      expect(details(english), details(original), reason: pattern);
    }
    expect(english, contains('12.3.'));
    expect(english, contains('Dmitry Yuryevich Pavlenko'));
  });
  for (final privacy in [false, true]) {
    final source = File(
      privacy ? 'assets/policy.txt' : 'assets/agreement.txt',
    ).readAsStringSync();
    final translated = File(
      privacy ? 'assets/legal/en/policy.txt' : 'assets/legal/en/agreement.txt',
    ).readAsStringSync();
    testWidgets(
      'open ${privacy ? "privacy policy" : "agreement"} reloads full bundled text after a language change',
      (tester) async {
        final code = ValueNotifier('ru');
        final bundle = _LegalBundle();
        addTearDown(code.dispose);
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ValueListenableBuilder<String>(
            valueListenable: code,
            builder: (_, value, __) => DefaultAssetBundle(
              bundle: bundle,
              child: MaterialApp(
                locale: Locale(value),
                supportedLocales: ClrsLocalizations.supportedLocales,
                localizationsDelegates: [
                  _CatalogDelegate(catalogs),
                  ...ClrsLocalizations.delegates.skip(1),
                ],
                theme: LrsTheme.theme,
                home: privacy ? const Politica() : const Rules(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          source,
        );
        code.value = 'en';
        await tester.pumpAndSettle();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          translated,
        );
        expect(
          find.text(privacy ? 'Privacy policy' : 'User agreement'),
          findsOneWidget,
        );
        code.value = 'de';
        await tester.pumpAndSettle();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          privacy
              ? File('assets/legal/de/policy.txt').readAsStringSync()
              : source,
        );
        expect(
          find.text(
            catalogs['de']!['Перевод документа на выбранный язык пока недоступен. Показан русский оригинал.']
                as String,
          ),
          privacy ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(ClrsDocumentPage), findsOneWidget);
      },
    );
  }
  test(
    'every policy translation matches the current source and preserves its details',
    () {
      final source = File('assets/policy.txt').readAsStringSync();
      final manifest =
          jsonDecode(
                File('assets/legal/policy_manifest.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(
        manifest['sourceSha256'],
        sha256.convert(utf8.encode(source)).toString(),
      );
      final documents = manifest['documents'] as Map<String, dynamic>;
      expect(documents.keys.toSet(), ClrsLocalizations.codes.toSet());
      final clauses = RegExp(r'^([0-9]+(?:\.[0-9]+)*)\.? ', multiLine: true);
      for (final code in ClrsLocalizations.codes) {
        final entry = documents[code] as Map<String, dynamic>;
        final text = File(entry['asset'] as String).readAsStringSync();
        expect(
          entry['sha256'],
          sha256.convert(utf8.encode(text)).toString(),
          reason: code,
        );
        expect(
          text.trim().split('\n\n').length,
          source.trim().split('\n\n').length,
          reason: code,
        );
        expect(
          clauses.allMatches(text).map((m) => m[1]).toList(),
          clauses.allMatches(source).map((m) => m[1]).toList(),
          reason: code,
        );
        for (final pattern in [
          r'https?://\S+',
          r'[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
          r'\b[0-9]{2,}\b',
        ]) {
          List<String> details(String value) =>
              RegExp(pattern).allMatches(value).map((m) => m[0]!).toList()
                ..sort();
          expect(details(text), details(source), reason: '$code $pattern');
        }
        expect(text, isNot(contains('[[900')), reason: code);
        if (code != 'ru') expect(text, isNot(source), reason: code);
        expect(
          File('pubspec.yaml').readAsStringSync(),
          contains('assets/legal/${code == 'ru' ? 'en' : code}/'),
        );
      }
    },
  );
  testWidgets(
    'all 23 policy languages open offline, toggle original, and reset on language change',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final language = ValueNotifier('en');
      addTearDown(language.dispose);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ValueListenableBuilder<String>(
          valueListenable: language,
          builder: (_, code, __) => DefaultAssetBundle(
            bundle: _LegalBundle(),
            child: MaterialApp(
              locale: ClrsLocalizations.localeFor(code),
              supportedLocales: ClrsLocalizations.supportedLocales,
              localizationsDelegates: [
                _CatalogDelegate(catalogs),
                ...ClrsLocalizations.delegates.skip(1),
              ],
              theme: LrsTheme.theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Politica(),
            ),
          ),
        ),
      );
      final russian = File('assets/policy.txt').readAsStringSync();
      for (final code in ClrsLocalizations.codes) {
        language.value = code;
        await tester.pumpAndSettle();
        final expected = code == 'ru'
            ? russian
            : File('assets/legal/$code/policy.txt').readAsStringSync();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          expected,
          reason: code,
        );
        expect(tester.takeException(), isNull, reason: code);
        if (code != 'ru' && code != 'en') {
          expect(
            find.text(catalogs[code]!['Автоматический перевод'] as String),
            findsOneWidget,
          );
          expect(find.bySemanticsLabel('Translated by Google'), findsOneWidget);
        }
        if (code == 'ru') continue;
        final originalButton = find.text(
          catalogs[code]!['Показать оригинал'] as String,
        );
        await tester.ensureVisible(originalButton);
        await tester.tap(originalButton);
        await tester.pumpAndSettle();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          russian,
          reason: code,
        );
        expect(find.bySemanticsLabel('Translated by Google'), findsNothing);
        final translationButton = find.text(
          catalogs[code]!['Показать перевод'] as String,
        );
        await tester.ensureVisible(translationButton);
        await tester.tap(translationButton);
        await tester.pumpAndSettle();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          expected,
          reason: code,
        );
        await tester.ensureVisible(originalButton);
        await tester.tap(originalButton);
        await tester.pumpAndSettle();
      }
      semantics.dispose();
    },
  );
}
