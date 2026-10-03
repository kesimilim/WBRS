import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/edit_profile/timeweb_profile_edit_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/presentation/screens/settings/timeweb_account_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/service/timeweb_profile_edit_flow.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/timeweb_email_lifecycle_form.dart';
import 'support/timeweb_people_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  await tester.pump();
  for (var i = 0; i < 120 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 500));
  final scroll = find.ancestor(of: target, matching: find.byType(Scrollable));
  for (var i = 0; i < 8 && target.hitTestable().evaluate().isEmpty; i++) {
    expect(scroll, findsWidgets);
    final dy = tester.getCenter(target).dy;
    await tester.drag(scroll.last, Offset(0, dy < 0 ? 300 : -300));
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Back').hitTestable().last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'native account routes, actual editor/documents, 360px/2x, logout and late owner',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('native-account-'),
      ))!;
      final lateLogin = Completer<http.StreamedResponse>();
      var editorReads = 0, held = false;
      final wire = PeopleWire((r) async {
        final uid = r.headers['authorization']?.split('.')[1] ?? 'A';
        if (r.url.path.endsWith('/auth/login')) {
          held = true;
          return lateLogin.future;
        }
        if (r.url.path.endsWith('/auth/logout')) {
          return peopleReply({'revoked': true});
        }
        if (r.url.path.endsWith('/me/full-profile')) {
          return peopleReply(peopleOwn(uid));
        }
        if (r.url.path == '/v1/runtime/me/profile') {
          editorReads++;
          final source = peopleOwn(uid)['profile'] as Map<String, dynamic>;
          return peopleReply({
            'uid': uid,
            'profileExists': true,
            'profileAuthority': 'canonical-current-v1',
            'editableFields': [
              'fullName',
              'age',
              'rost',
              'about',
              'hobbi',
              'deti',
              'pol',
              'relationStatus',
            ],
            'profile': {
              for (final key in [
                'fullName',
                'age',
                'rost',
                'about',
                'hobbi',
                'deti',
                'pol',
                'relationStatus',
                'profileDetailsSaved',
                'isRegistrationEnd',
                'updatedAt',
              ])
                key: source[key],
            },
          });
        }
        return peopleReply({'error': 'photo_unavailable'}, status: 404);
      });
      final app = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: PeopleStore(),
        transport: wire,
        deviceId: 'fixture',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        clock: () => peopleNow,
        currentOwnProfileEnabled: true,
        profileEditorEnabled: true,
        initialProfileJournal: TimewebInitialProfileJournal(
          directory: () async => folder,
        ),
        profileEditJournal: TimewebProfileEditJournal(
          directory: () async => folder,
        ),
      );
      await tester.runAsync(() => app.start(remember: true));
      final own = (await tester.runAsync(app.readCurrentOwnProfile))!;
      final navigator = GlobalKey<NavigatorState>();
      final scale = ValueNotifier(1.0);
      tester.view.physicalSize = const Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        if (!lateLogin.isCompleted) {
          lateLogin.complete(peopleReply(peopleTokens('B')));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        var done = false;
        final stop = app.stop().then((_) => done = true);
        await _until(tester, () => done);
        await stop;
        scale.dispose();
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      Widget host(TimewebCurrentOwnProfile profile) =>
          ValueListenableBuilder<double>(
            valueListenable: scale,
            builder: (_, value, __) => MaterialApp(
              navigatorKey: navigator,
              theme: LrsTheme.theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(value)),
                child: child!,
              ),
              home: TimewebOwnProfilePage(
                runtime: app,
                initialProfile: profile,
              ),
            ),
          );
      await tester.pumpWidget(host(own));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-open-profile-editor'))
            .evaluate()
            .isNotEmpty,
      );
      await _tap(tester, 'timeweb-profile-settings');
      expect(find.byType(TimewebAccountPage), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('timeweb-settings-personal')))
            .width,
        inInclusiveRange(230, 260),
      );
      scale.value = 2;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _tap(tester, 'timeweb-settings-about');
      expect(
        find.byKey(const ValueKey('timeweb-about-scroll')),
        findsOneWidget,
      );
      await _tap(tester, 'timeweb-about-offer');
      expect(find.byType(ClrsDocumentPage), findsOneWidget);
      await _back(tester);
      await _back(tester);
      await _tap(tester, 'timeweb-settings-help');
      expect(
        find.byKey(const ValueKey('timeweb-help-support')),
        findsOneWidget,
      );
      await _back(tester);
      await _tap(tester, 'timeweb-settings-password');
      expect(find.byType(TimewebEmailLifecycleForm), findsOneWidget);
      expect(
        tester
            .widget<ElevatedButton>(
              find.byKey(const ValueKey('timeweb-email-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.text('Сервис пока недоступен. Попробуйте позднее.'),
        findsOneWidget,
      );
      await _back(tester);
      await _tap(tester, 'timeweb-settings-personal');
      await _until(
        tester,
        () => find.byType(TimewebProfileEditPage).evaluate().isNotEmpty,
      );
      expect(editorReads, 1);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('timeweb-profile-name')),
            )
            .controller!
            .text,
        'Own A',
      );
      expect(Firebase.apps, isEmpty);
      await _back(tester);
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-open-profile-editor'))
            .evaluate()
            .isNotEmpty,
      );
      await _tap(tester, 'timeweb-profile-settings');
      final login = app.session.login(
        email: 'b@example.invalid',
        password: 'synthetic',
        deviceId: 'fixture',
      );
      // A's cleanup may run after this newer route is installed. It removes only
      // its own route; it must not walk/pop this healthy B destination.
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('New B route')),
          ),
        ),
      );
      await _until(tester, () => held);
      expect(find.text('New B route'), findsOneWidget);
      lateLogin.complete(peopleReply(peopleTokens('B')));
      var loggedIn = false;
      final settled = login.then((_) => loggedIn = true);
      await _until(tester, () => loggedIn);
      await settled;
      await _until(
        tester,
        () => find.byType(TimewebAccountPage).evaluate().isEmpty,
      );
      expect(find.byType(TimewebEmailLifecycleForm), findsNothing);
      expect(find.text('New B route'), findsOneWidget);
      expect(app.session.state.identity?.uid, 'B');
      expect(tester.takeException(), isNull);
      final ownB = (await tester.runAsync(app.readCurrentOwnProfile))!;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host(ownB));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-open-profile-editor'))
            .evaluate()
            .isNotEmpty,
      );
      await _tap(tester, 'timeweb-profile-settings');
      await _tap(tester, 'timeweb-settings-logout');
      await _until(tester, () => !app.session.state.authenticated);
      expect(find.byType(TimewebAccountPage), findsNothing);
      expect(
        wire.calls.where((r) => r.url.path.contains('/lifecycle')).isEmpty,
        isTrue,
      );
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
