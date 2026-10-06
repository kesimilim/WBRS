import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/auth/session_gate.dart';
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_android_secure_token_store.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_auth_lifecycle.dart';
import 'package:wbrs/shared/lrs_theme.dart';

final _now = DateTime.utc(2026, 10, 2);
final _pin = 'a' * 64;
const _email = ' Mixed.Case@example.invalid ';
const _password = '  preserved password  ';

class _Platform {
  String? protectedPayload;
  int writes = 0;
  bool clearFails = false;
  Completer<void>? writeBarrier;
  Future<Object?> invoke(String method, Map<String, Object?>? arguments) async {
    switch (method) {
      case 'read':
        return protectedPayload;
      case 'write':
        await writeBarrier?.future;
        writes++;
        protectedPayload = arguments!['payload'] as String;
        return {'operationId': '00000000-0000-4000-8000-000000000001'};
      case 'confirm':
        return true;
      case 'clear':
        if (clearFails) return false;
        protectedPayload = null;
        return true;
      default:
        throw StateError('Unexpected protected-store method.');
    }
  }
}

class _Wire extends http.BaseClient {
  _Wire(this.handle);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handle(request);
  }
}

http.StreamedResponse _reply(Object body) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  200,
  headers: {'content-type': 'application/json', 'cache-control': 'no-store'},
);
Map<String, Object> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid',
  'refreshToken': 'nr1.$uid',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
Map<String, Object?> _fullProfile(String uid, {bool missing = false}) {
  final profile = <String, Object?>{
    'uid': uid,
    'status': 'active',
    'registrationStatus': null,
    'deleted': false,
    'isRegistrationEnd': true,
    'profileDetailsSaved': true,
    'группа': 'белая',
    'group': 'белая',
    'fullName': 'Synthetic snapshot',
    'country': null,
    'countryCode': null,
    'region': null,
    'city': null,
    'languageGroup': null,
    'countrySegment': null,
    'pol': null,
    'about': null,
    'hobbi': null,
    'rost': null,
    'relationStatus': null,
    'age': 28,
    'deti': null,
    'online': null,
    'isUnVisible': null,
    'isUnvisible': null,
    'notificationPreferences': null,
    'lastOnlineTS': null,
    'unvisibleEnd': null,
    'profilePic': null,
    'profilePicThumb': null,
  };
  return {
    'uid': uid,
    'profile': missing ? null : profile,
    'onboarding': missing ? 'registration' : 'search',
    'profileExists': !missing,
    'sourceSnapshot': _pin,
    'profileDocumentHash': missing ? null : 'b' * 64,
    'profileAuthority': 'immutable-reviewed-snapshot',
    'accountAuthority': 'active-local-account',
    'mediaReady': false,
    'readOnly': true,
    'unavailableFields': <String>[],
  };
}

TimewebAppRuntime _runtime(
  _Platform platform,
  _Wire wire, {
  Duration waitTimeout = const Duration(seconds: 20),
}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
  ),
  secureStore: TimewebAndroidSecureTokenStore(invoke: platform.invoke),
  deviceId: 'clrs-android-${'0' * 32}',
  expectedSourceSnapshot: _pin,
  clearLocal: () async {},
  transport: wire,
  clock: () => _now,
  waitTimeout: waitTimeout,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'native owner restores only protected remembered credentials; false and unknown clear fail closed',
    () async {
      expect(AppBackend.backendMode, 'firebase');
      expect(AppBackend.timewebAuthEnabled, isFalse);
      expect(Firebase.apps, isEmpty);
      final preferences = await SharedPreferences.getInstance();
      final id = await TimewebAppRuntime.loadDeviceId(preferences);
      expect(await TimewebAppRuntime.loadDeviceId(preferences), id);
      final platform = _Platform();
      final wire = _Wire((_) async => _reply(_tokens('A')));
      final first = _runtime(platform, wire);
      expect((await first.start(remember: true)).confirmed, isTrue);
      expect(first.session.currentUid, isNull);
      expect(
        (await first.login(email: _email, password: _password)).confirmed,
        isTrue,
      );
      expect(first.session.currentUid, 'A');
      expect(platform.writes, 1);
      expect(platform.protectedPayload, isNotNull);
      expect(jsonDecode((wire.calls.single as http.Request).body), {
        'email': _email,
        'password': _password,
        'deviceId': 'clrs-android-${'0' * 32}',
      });
      expect(await first.stop(), isTrue);
      final restarted = _runtime(platform, wire);
      expect((await restarted.start(remember: true)).confirmed, isTrue);
      expect(restarted.session.currentUid, 'A');
      expect(wire.calls, hasLength(1));
      await restarted.setRemember(false);
      expect(platform.protectedPayload, isNull);
      expect(restarted.session.currentUid, 'A');
      expect(await restarted.stop(), isTrue);

      final temporary = _runtime(platform, wire);
      await temporary.start(remember: false);
      expect(temporary.session.currentUid, isNull);
      await temporary.login(email: _email, password: _password);
      expect(temporary.session.currentUid, 'A');
      expect(platform.protectedPayload, isNull);
      expect(platform.writes, 1);
      await temporary.stop();
      final unrememberedRestart = _runtime(platform, wire);
      await unrememberedRestart.start(remember: false);
      expect(unrememberedRestart.session.currentUid, isNull);
      await unrememberedRestart.stop();
      platform.writeBarrier = Completer<void>();
      final draining = _runtime(
        platform,
        wire,
        waitTimeout: const Duration(milliseconds: 5),
      );
      await draining.start(remember: true);
      final pendingLogin = await draining.login(
        email: _email,
        password: _password,
      );
      expect(pendingLogin.outcome, AppSessionOutcome.pending);
      var stopped = false;
      final drain = draining.stop().then((value) {
        stopped = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(stopped, isFalse);
      expect(draining.session.currentUid, isNull);
      platform.writeBarrier!.complete();
      expect(await drain, isTrue);
      platform.writeBarrier = null;
      expect(platform.protectedPayload, isNotNull);
      platform.clearFails = true;
      final unsafe = _runtime(platform, wire);
      await expectLater(unsafe.start(remember: false), throwsStateError);
      expect(unsafe.session.currentUid, isNull);
      expect(unsafe.session.state.phase, AppSessionPhase.stopped);
      expect(await unsafe.stop(), isFalse);
      final stoppedEmail = unsafe.createEmailLifecycleClient(
        TimewebLifecyclePurpose.passwordReset,
      );
      expect(stoppedEmail.enabled, isFalse);
      await stoppedEmail.close();
      expect(wire.calls, hasLength(3));
      expect(preferences.getKeys(), {'timeweb_device_id'});
      expect(Firebase.apps, isEmpty);
    },
  );

  testWidgets(
    'existing login waits on one native attempt, reads full typed gate, and cannot render late A after B',
    (tester) async {
      final platform = _Platform();
      final loginAck = Completer<http.StreamedResponse>();
      final lateProfile = Completer<http.StreamedResponse>();
      var loginCalls = 0;
      var profileCalls = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') {
          loginCalls++;
          return loginCalls == 1 ? loginAck.future : _reply(_tokens('B'));
        }
        expect(request.url.path, '/v1/me/full-profile');
        profileCalls++;
        if (profileCalls == 3) return lateProfile.future;
        return _reply(
          _fullProfile(
            profileCalls <= 2 ? 'A' : 'B',
            missing: profileCalls > 2,
          ),
        );
      });
      final runtime = _runtime(
        platform,
        wire,
        waitTimeout: const Duration(milliseconds: 30),
      );
      await tester.runAsync(() => runtime.start(remember: true));
      // No Firebase app/plugin/identity is installed; accidental AuthService or
      // Firebase SessionGate access fails this real screen test immediately.
      expect(Firebase.apps, isEmpty);
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: LoginPage(nativeRuntime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), _email);
      await tester.enterText(fields.at(1), _password);
      await tester.runAsync(() async {
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Вход'))
            .onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(find.text('Проверить вход'), findsOneWidget);
      expect(loginCalls, 1);
      await tester.runAsync(() async {
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Проверить вход'),
            )
            .onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(loginCalls, 1);
      expect(find.text('Проверить вход'), findsOneWidget);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Проверить вход'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(() async {
        loginAck.complete(_reply(_tokens('A')));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(runtime.session.currentUid, 'A');
      // A check that timed out stays bounded; after ACK, a new explicit check
      // observes that same completed Future without another authentication POST.
      await tester.runAsync(() async {
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Проверить вход'),
            )
            .onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(loginCalls, 1);
      expect(profileCalls, 1);
      expect(find.byType(TimewebSessionGate), findsOneWidget);
      expect(find.byType(SessionGate), findsNothing);
      expect(find.byKey(const ValueKey('timeweb-gate-search')), findsOneWidget);
      expect(
        find.text('Сервис пока недоступен. Попробуйте позднее.'),
        findsOneWidget,
      );
      final retained = (await tester.runAsync(runtime.readGateProfile));
      // The third request is pending. A new B login revokes its facade lease
      // before old HTTP returns; the gate re-reads only B's pinned full DTO.
      final staleRead = runtime.readGateProfile();
      final staleCheck = expectLater(
        staleRead,
        throwsA(isA<AppSessionException>()),
      );
      await tester.pump();
      await tester.runAsync(
        () => runtime.login(email: 'B@example.invalid', password: _password),
      );
      await tester.pump();
      await tester.runAsync(() async {
        lateProfile.complete(_reply(_fullProfile('A')));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(runtime.session.currentUid, 'B');
      expect(
        find.byKey(const ValueKey('timeweb-gate-registration')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('timeweb-gate-search')), findsNothing);
      expect(find.byType(SessionGate), findsNothing);
      await staleCheck;
      expect(() => retained!.source, throwsA(isA<AppSessionException>()));
      expect(Firebase.apps, isEmpty);
      await tester.runAsync(runtime.stop);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.text('Сервис пока недоступен. Попробуйте позднее.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Повторить'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Вернуться ко входу'),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
