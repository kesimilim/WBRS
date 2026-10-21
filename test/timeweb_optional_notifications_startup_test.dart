import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/locale_controller.dart';
import 'package:wbrs/main.dart' as application;
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/service/app_backend.dart';

class _DelayedFirebaseCore extends MockFirebaseApp {
  final completion = Completer<List<CoreInitializeResponse>>();
  int attempts = 0;

  @override
  Future<List<CoreInitializeResponse>> initializeCore() {
    attempts++;
    return completion.future;
  }
}

void main() {
  testWidgets(
    'Timeweb login stays usable when optional notifications hang',
    (tester) async {
      // This suite deliberately runs with the same native backend selection as
      // the APK. Secure credentials are empty; no live account or API is used.
      await tester.runAsync(() async {
        expect(AppBackend.usesTimeweb, isTrue);
        SharedPreferences.setMockInitialValues({'clrs_ui_language': 'ru'});
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        final core = _DelayedFirebaseCore();
        final local = Completer<bool>();
        final originalErrorHandler = FlutterError.onError;
        TestFirebaseCoreHostApi.setUp(core);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const store = MethodChannel('com.lrs/timeweb_token_store_v1');
        const notifications = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        messenger.setMockMethodCallHandler(store, (call) async {
          if (call.method == 'read') return null;
          if (call.method == 'clear') return true;
          throw StateError('Unexpected credential mutation: ${call.method}');
        });
        messenger.setMockMethodCallHandler(notifications, (call) async {
          if (call.method == 'initialize') return local.future;
          if (call.method == 'getNotificationAppLaunchDetails') {
            return {'notificationLaunchedApp': false};
          }
          return null;
        });
        addTearDown(() {
          FlutterError.onError = originalErrorHandler;
          TestFirebaseCoreHostApi.setUp(null);
          messenger.setMockMethodCallHandler(store, null);
          messenger.setMockMethodCallHandler(notifications, null);
        });
        {
          await LocaleController.instance.initialize();
          await ClrsLocalizations.load(const Locale('ru'));
          await AppBackend.initialize();
        }
        application.main();
        await tester.pumpAndSettle();
        FlutterError.onError = originalErrorHandler;
        expect(find.byType(LoginPage), findsOneWidget);
        expect(local.isCompleted, isFalse);
        expect(core.attempts, 0);
        await tester.enterText(
          find.byType(TextFormField).first,
          'qa@example.invalid',
        );
        expect(find.text('qa@example.invalid'), findsOneWidget);

        local.complete(true);
        await tester.pumpAndSettle();
        expect(core.attempts, 1);
        expect(core.completion.isCompleted, isFalse);
        expect(find.byType(LoginPage), findsOneWidget);
        await Future<void>.delayed(const Duration(seconds: 11));
        await tester.pumpAndSettle();
        expect(find.byType(LoginPage), findsOneWidget);
        expect(find.text('qa@example.invalid'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // A platform result arriving after its deadline and page disposal must not
        // resurrect push listeners or turn the next page into a startup failure.
        await tester.pumpWidget(const SizedBox());
        core.completion.completeError(PlatformException(code: 'unavailable'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    },
    skip: !AppBackend.usesTimeweb,
  );
}
