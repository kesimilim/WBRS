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
        r'[A-Za-z0-9.]+@[A-Za-z0-9.]+',
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
      r'[A-Za-z0-9.]+@[A-Za-z0-9.]+',
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
          source,
        );
        expect(
          find.text(
            catalogs['de']!['Перевод документа на выбранный язык пока недоступен. Показан русский оригинал.']
                as String,
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(ClrsDocumentPage), findsOneWidget);
      },
    );
  }
}
