import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/locale_controller.dart';
import 'package:wbrs/presentation/screens/settings/timeweb_account_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/timeweb_people_fixtures.dart';

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

Future<void> _ready(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key, String scroll) async {
  final target = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    target,
    140,
    scrollable: find.descendant(
      of: find.byKey(ValueKey(scroll)),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _ready(tester);
}

void main() {
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ClrsLocalizations.codes)
      code: Map<String, dynamic>.from(
        jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map,
      ),
  };
  testWidgets('native settings language remains in About and survives logout', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await LocaleController.instance.initialize(
      deviceLocale: const Locale('ru'),
    );
    final wire = PeopleWire(
      (request) async => request.url.path.endsWith('/auth/logout')
          ? peopleReply({'revoked': true})
          : peopleReply({'error': 'unavailable'}, status: 404),
    );
    final app = TimewebAppRuntime(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse('https://api.example.invalid'),
        enabled: true,
        currentReadsEnabled: true,
      ),
      secureStore: PeopleStore(),
      transport: wire,
      deviceId: 'fixture',
      expectedSourceSnapshot: 'a' * 64,
      clearLocal: () async {},
      clock: () => peopleNow,
    );
    await tester.runAsync(() => app.start(remember: true));
    final lease = app.session.captureLease();
    final navigator = GlobalKey<NavigatorState>();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var stopped = false;
      final stop = app.stop().then((_) => stopped = true);
      for (var i = 0; i < 20 && !stopped; i++) {
        await _ready(tester);
      }
      expect(stopped, isTrue);
      await stop;
    });
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: LocaleController.instance,
        builder: (_, __) => MaterialApp(
          navigatorKey: navigator,
          theme: LrsTheme.theme,
          locale: LocaleController.instance.locale,
          supportedLocales: ClrsLocalizations.supportedLocales,
          localizationsDelegates: [
            _CatalogDelegate(catalogs),
            ...ClrsLocalizations.delegates.skip(1),
          ],
          home: const Scaffold(body: Text('Root')),
        ),
      ),
    );
    await _ready(tester);
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => TimewebAccountPage(runtime: app, lease: lease),
        ),
      ),
    );
    await _ready(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('timeweb-settings-language')),
      140,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('timeweb-settings-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    // The compact picker inside the panel owns the tap target.
    await tester.tap(find.text('Русский').hitTestable());
    await _ready(tester);
    await tester.tap(find.text('English').hitTestable());
    await _ready(tester);
    expect(LocaleController.instance.locale.languageCode, 'en');
    expect(find.text('Settings'), findsOneWidget);
    await _tap(tester, 'timeweb-settings-about', 'timeweb-settings-scroll');
    expect(find.byKey(const ValueKey('timeweb-about-scroll')), findsOneWidget);
    await _tap(tester, 'timeweb-about-agreement', 'timeweb-about-scroll');
    expect(find.text('User agreement'), findsOneWidget);
    for (
      var i = 0;
      i < 20 && find.byType(SelectableText).evaluate().isEmpty;
      i++
    ) {
      await _ready(tester);
    }
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      File('assets/legal/en/agreement.txt').readAsStringSync(),
    );
    navigator.currentState!.pop();
    await _ready(tester);
    await tester.scrollUntilVisible(
      find.text('English'),
      140,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('timeweb-about-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('English').hitTestable(), findsOneWidget);
    navigator.currentState!.pop();
    await _ready(tester);
    await _tap(tester, 'timeweb-settings-logout', 'timeweb-settings-scroll');
    for (
      var i = 0;
      i < 20 && app.session.state.phase != AppSessionPhase.signedOut;
      i++
    ) {
      await _ready(tester);
    }
    expect(app.session.state.authenticated, isFalse);
    expect(app.session.state.phase, AppSessionPhase.signedOut);
    expect(find.byType(TimewebAccountPage), findsNothing);
    expect(LocaleController.instance.locale.languageCode, 'en');
    expect(Firebase.apps, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
