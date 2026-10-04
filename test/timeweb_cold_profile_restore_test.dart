import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 160 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'cold B restore retries one transient own read; late A retry cannot enter B',
    (tester) async {
      final store = PeopleStore()..value = peopleSession('B');
      final reads = <String, int>{};
      var hold = false, held = false, denied = false;
      final late = Completer<void>();
      final wire = PeopleWire((request) async {
        final path = request.url.path;
        final uid = request.headers['authorization']?.split('.')[1] ?? 'B';
        if (path.endsWith('/auth/login')) {
          final body = jsonDecode((request as http.Request).body);
          return peopleReply(
            peopleTokens(body['email'].toString().startsWith('a') ? 'A' : 'B'),
          );
        }
        expect(request.method, 'GET');
        if (path.endsWith('/me/full-profile')) {
          reads.update(uid, (count) => count + 1, ifAbsent: () => 1);
          if (denied) {
            return peopleReply({'error': 'profile_unavailable'}, status: 404);
          }
          if (reads[uid] == 1) {
            return peopleReply({'error': 'unavailable'}, status: 503);
          }
          if (uid == 'A' && hold) {
            held = true;
            await late.future;
          }
          return peopleReply(peopleOwn(uid, stage: 'test'));
        }
        if (path.endsWith('/photos')) {
          return peopleReply(photoPage(uid, [photoDescriptor(0)]));
        }
        if (path.endsWith('/content')) return photoContent();
        return peopleReply({'error': 'unavailable'}, status: 404);
      });
      final runtime = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: store,
        transport: wire,
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        clock: () => peopleNow,
        currentOwnProfileEnabled: true,
      );
      addTearDown(() async {
        if (!late.isCompleted) late.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        var done = false;
        final stop = runtime.stop().then((_) => done = true);
        await _until(tester, () => done);
        await stop;
      });
      await tester.runAsync(() => runtime.start(remember: true));
      expect(runtime.session.currentUid, 'B');
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebSessionGate(runtime: runtime),
        ),
      );
      await _until(
        tester,
        () => find.textContaining('Own B').evaluate().isNotEmpty,
      );
      expect(
        reads['B'],
        2,
        reason: 'Only one new GET after the transient first cold read',
      );
      expect(find.byKey(const ValueKey('timeweb-profile-retry')), findsNothing);
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-primary'))
            .evaluate()
            .isNotEmpty,
      );

      hold = true;
      var aSignedIn = false;
      final loginA = runtime
          .login(email: 'a@example.invalid', password: 'synthetic-password')
          .then((_) => aSignedIn = true);
      await _until(tester, () => held);
      await loginA;
      expect(aSignedIn, isTrue);
      expect(reads['A'], 2);
      var changed = false;
      final login = runtime
          .login(email: 'b@example.invalid', password: 'synthetic-password')
          .then((_) => changed = true);
      await _until(
        tester,
        () => find.textContaining('Own A').evaluate().isEmpty,
      );
      late.complete();
      await _until(
        tester,
        () => changed && find.textContaining('Own B').evaluate().isNotEmpty,
      );
      await login;
      expect(reads['B'], 3);
      expect(
        reads['A'],
        2,
        reason: 'The old owner must not start another read',
      );
      expect(find.textContaining('Own A'), findsNothing);
      denied = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebSessionGate(
            key: const ValueKey('target-denied'),
            runtime: runtime,
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-profile-retry'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        reads['B'],
        4,
        reason: 'Target404 is definitive for this read, never retried',
      );
      expect(runtime.session.currentUid, 'B');
      expect(find.textContaining('Own B'), findsNothing);
      expect(
        wire.calls.where((call) => call.method == 'POST').length,
        2,
        reason:
            'Only the explicit A/B login; retry is GET-only, never refresh/login',
      );
    },
  );
}
