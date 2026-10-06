import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/presentation/screens/auth/register_screen/register_page.dart';
import 'package:wbrs/presentation/screens/auth/session_gate.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_auth_lifecycle.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/password_reset_sheet.dart';

const _challenge = '00000000-0000-4000-8000-000000000009';
const _token = 'Opaque_sealed-digest';
const _email = '  Mixed.Case@example.invalid  ';
const _password = '  preserved spaces  ';
final _now = DateTime.utc(2026, 10, 2);
http.StreamedResponse _reply(Map<String, Object> body, [int status = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: {
        'content-type': 'application/json',
        'cache-control': 'private, no-store',
      },
    );
Map<String, dynamic> _body(http.BaseRequest request) =>
    jsonDecode((request as http.Request).body);

class _Wire extends http.BaseClient {
  _Wire(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handler(request);
  }
}

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = TimewebSession(
    uid: 'A',
    emailVerified: true,
    accessToken: 'na1.A',
    refreshToken: 'nr1.A',
    accessExpiresAt: _now.add(const Duration(minutes: 15)),
    refreshExpiresAt: _now.add(const Duration(days: 14)),
  );
  @override
  Future<TimewebSession?> read() async => value;
  @override
  Future<void> write(TimewebSession value) async {
    this.value = value;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

Future<AppSession> _nativeSession() async {
  final transport = _Wire(
    (_) async => _reply({
      'uid': 'B',
      'emailVerified': true,
      'accessToken': 'na1.B',
      'refreshToken': 'nr1.B',
      'expiresIn': 900,
      'refreshExpiresIn': 1209600,
    }),
  );
  final client = TimewebAuthClient(
    configuration: TimewebAuthConfiguration(
      endpoint: Uri.parse('https://api.example.invalid'),
      enabled: true,
    ),
    secureStore: _Store(),
    transport: transport,
    clock: () => _now,
  );
  final session = AppSession.timeweb(client: client, clearLocal: () async {});
  await session.restore();
  return session;
}

TimewebAuthLifecycleClient _client(
  _Wire wire,
  AppSession session, {
  bool enabled = true,
}) => TimewebAuthLifecycleClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
  ),
  enabled: enabled,
  transport: wire,
  session: session,
);
Future<void> _tap(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('timeweb-email-submit'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _fields(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('timeweb-code')), '012345');
  await tester.enterText(
    find.byKey(const ValueKey('timeweb-password')),
    _password,
  );
  expect(
    tester
        .widget<TextField>(
          find.descendant(
            of: find.byKey(const ValueKey('timeweb-password')),
            matching: find.byType(TextField),
          ),
        )
        .obscureText,
    isTrue,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'existing reset sheet uses native code flow and explicit original lookup without Firebase fallback',
    (tester) async {
      expect(AppBackend.emailLifecycleBackend, 'firebase');
      expect(AppBackend.timewebEmailLifecycleEnabled, isFalse);
      expect(AppBackend.timewebRegistrationEnabled, isFalse);
      final session = (await tester.runAsync(_nativeSession))!;
      AppBackend.bindEmailLifecycleSession(session);
      final wire = _Wire((request) async {
        if (request.url.path.endsWith('/request')) {
          return _reply({
            'error': 'outcome_unknown',
            'operationToken': _token,
          }, 503);
        }
        if (request.url.path.endsWith('/complete')) {
          throw StateError('simulated lost entire ACK');
        }
        final body = _body(request);
        return body.containsKey('original')
            ? _reply({'status': 'completed', 'operationToken': _token})
            : _reply({
                'status': 'accepted',
                'challengeId': _challenge,
                'operationToken': _token,
              }, 202);
      });
      var firebaseSends = 0;
      final disabled = _client(wire, session, enabled: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: Scaffold(
            body: PasswordResetSheet(
              key: const ValueKey('off'),
              send: (_) async {
                firebaseSends++;
              },
              timewebLifecycle: disabled,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Сервис пока недоступен. Попробуйте позднее.'),
        findsOneWidget,
      );
      expect(wire.calls, isEmpty);
      final client = _client(wire, session);
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: Scaffold(
            body: PasswordResetSheet(
              key: const ValueKey('on'),
              send: (_) async {
                firebaseSends++;
              },
              timewebLifecycle: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('timeweb-email')),
        _email,
      );
      await _tap(tester);
      expect(find.text('Проверить результат'), findsOneWidget);
      expect(wire.calls.length, 1);
      expect(_body(wire.calls.first)['email'], _email);
      await _tap(tester);
      expect(wire.calls.length, 2);
      expect(_body(wire.calls.last), {'operationToken': _token});
      expect(find.byKey(const ValueKey('timeweb-code')), findsOneWidget);
      await _fields(tester);
      await _tap(tester);
      expect(
        find.text('Пароль изменён. Войдите с новым паролем.'),
        findsNothing,
      );
      expect(find.text('Проверить результат'), findsOneWidget);
      final original = _body(wire.calls.last);
      expect(original['password'], _password);
      expect(original['code'], '012345');
      await _tap(tester);
      expect(wire.calls.length, 4);
      expect(wire.calls.last.url.path, '/v1/auth/operations/lookup');
      expect(_body(wire.calls.last), {
        'purpose': 'password-reset.v1',
        'stage': 'complete',
        'original': original,
      });
      expect(
        find.text('Пароль изменён. Войдите с новым паролем.'),
        findsOneWidget,
      );
      expect(find.byType(SessionGate), findsNothing);
      expect(firebaseSends, 0);
      expect(
        wire.calls.every(
          (v) =>
              v.method == 'POST' &&
              !v.url.hasQuery &&
              !v.headers.containsKey('Authorization'),
        ),
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isNot(contains('registration_intent_v1')));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      await tester.runAsync(session.stop);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'registration confirms only account stage and drops late completion after actual native account change/navigation',
    (tester) async {
      final session = (await tester.runAsync(_nativeSession))!;
      AppBackend.bindEmailLifecycleSession(session);
      Completer<http.StreamedResponse>? late;
      var pending = false;
      final wire = _Wire((request) async {
        if (request.url.path.endsWith('/request')) {
          return _reply({
            'status': 'accepted',
            'challengeId': _challenge,
            'operationToken': _token,
          }, 202);
        }
        if (pending) {
          late = Completer<http.StreamedResponse>();
          return late!.future;
        }
        return _reply({'status': 'completed', 'operationToken': _token});
      });
      final client = _client(wire, session);
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: RegisterPage(
            key: const ValueKey('first'),
            consentConfirmed: true,
            timewebLifecycle: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('timeweb-email')),
        _email,
      );
      await _tap(tester);
      await _fields(tester);
      await _tap(tester);
      expect(wire.calls.map((v) => v.url.path), [
        '/v1/auth/register-email/request',
        '/v1/auth/register-email/complete',
      ]);
      expect(
        find.text(
          'Email подтверждён. Создание аккаунта завершено. Заполнение анкеты пока недоступно.',
        ),
        findsOneWidget,
      );
      expect(find.byType(SessionGate), findsNothing);
      expect(
        session.currentUid,
        'A',
      ); // Completion never adopts native/Firebase identity.
      pending = true;
      final next = _client(wire, session);
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: RegisterPage(
            key: const ValueKey('second'),
            consentConfirmed: true,
            timewebLifecycle: next,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('timeweb-email')),
        _email,
      );
      await _tap(tester);
      await _fields(tester);
      final submit = find.byKey(const ValueKey('timeweb-email-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      expect(late, isNotNull);
      await tester.runAsync(
        () => session.login(
          email: 'b@example.invalid',
          password: 'synthetic',
          deviceId: 'test-device',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Сеанс изменился. Откройте этот экран заново.'),
        findsOneWidget,
      );
      expect(tester.widget<ElevatedButton>(submit).onPressed, isNull);
      late!.complete(_reply({'status': 'completed', 'operationToken': _token}));
      await tester.pumpAndSettle();
      expect(find.textContaining('Создание аккаунта завершено'), findsNothing);
      expect(find.byType(SessionGate), findsNothing);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      await tester.runAsync(session.stop);
      expect(tester.takeException(), isNull);
    },
  );
}
