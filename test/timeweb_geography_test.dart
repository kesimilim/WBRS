import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_geography_flow.dart';
import 'package:wbrs/service/timeweb_profile_edit_flow.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/presentation/screens/edit_profile/timeweb_geography_page.dart';
import 'package:wbrs/presentation/screens/edit_profile/timeweb_profile_edit_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/shared/meeting_location_fields.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

final _now = DateTime.utc(2026, 10, 2);
const _stamp = '2026-10-02T12:00:00.000001Z';
const _nextStamp = '2026-10-02T12:00:00.000002Z';
const _origin = 'https://api.example.invalid';
const _assignedGroup = 'красно-коричневая';

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
  Future<void> write(TimewebSession session) async {
    value = session;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

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

http.StreamedResponse _reply(Object body, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
Map<String, Object> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid',
  'refreshToken': 'nr1.$uid',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
Map<String, Object?> _full(String uid, {String stage = 'test'}) => {
  'uid': uid,
  'profileExists': true,
  'profile': {
    'fullName': stage == 'registration' ? null : 'Current $uid',
    'age': 28,
    'rost': null,
    'about': 'Original about',
    'hobbi': 'Original hobbies',
    'deti': null,
    'pol': 'Мужской',
    'relationStatus': null,
    'country': 'Австралия',
    'countryCode': 'AU',
    'region': 'New South Wales',
    'city': null,
    'languageCode': null,
    'primaryGroup': stage == 'search' ? _assignedGroup : null,
    'secondaryGroup': null,
    'profileDetailsSaved': stage != 'registration',
    'isRegistrationEnd': stage == 'search',
    'updatedAt': stage == 'search' ? _nextStamp : _stamp,
  },
  'onboarding': stage,
  'profileAuthority': 'canonical-current-v1',
  'mediaReady': false,
};
List<File> _files(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.json'))
    .toList();
Future<TimewebMutationRequest> _request(Map<String, dynamic> body) async =>
    TimewebMutationRequest.editOwnGeography(
      operationId: body['operationId'],
      expectedUpdatedAt: body['expectedUpdatedAt'],
      changes: await TimewebGeographyChanges.fromCatalog(
        countryCode: body['changes']['countryCode'],
        region: body['changes']['region'],
      ),
    );
Map<String, Object?> _receipt(
  TimewebMutationRequest request,
  Object result, {
  bool replayed = false,
}) => {
  'operation': request.operation,
  'operationId': request.operationId,
  'requestHash': request.requestHash,
  'state': 'committed',
  'replayed': replayed,
  'result': result,
  'entityRevision': null,
};
Map<String, Object?> _editable(Map<String, Object?> full) {
  final profile = full['profile'] as Map;
  return {
    'uid': 'A',
    'profileExists': true,
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
        key: profile[key],
    },
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
  };
}

Map<String, Object> _completed(String uid) => {
  'uid': uid,
  'country': 'Германия',
  'countryCode': 'DE',
  'region': 'Bayern',
  'updatedAt': _nextStamp,
  'profileAuthority': 'canonical-current-v1',
};
TimewebAuthClient _client(_Store store, _Wire wire) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse(_origin),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: store,
  transport: wire,
  clock: () => _now,
);
Future<TimewebGeographyFlow> _open(
  TimewebAuthClient client,
  AppSession session,
  TimewebGeographyJournal journal,
) async {
  final lease = session.captureLease();
  final snapshot = await client.readCurrentOwnProfile();
  return TimewebGeographyFlow.open(
    client: client,
    session: session,
    lease: lease,
    journal: journal,
    snapshot: snapshot.bindSessionGuard(lease.requireCurrent),
  );
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}

Future<void> _widgetUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  var settled = false;
  final original = runtime.stop().then((value) {
    settled = true;
    return value;
  });
  await _widgetUntil(tester, () => settled);
  expect(await original, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'exact pinned pair is durable before one POST; authoritative country and typed refusals',
    () async {
      final directory = await Directory.systemTemp.createTemp('clrs-geo-save-');
      final journal = TimewebGeographyJournal(directory: () async => directory);
      var posts = 0, stage = 'test';
      Object? refusal;
      var refusalStatus = 409;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') return _reply(_tokens('B'));
        if (request.method == 'GET') return _reply(_full('A', stage: stage));
        posts++;
        expect(request.url.path, '/v1/runtime/me/geography');
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(
          body.keys,
          unorderedEquals(['operationId', 'expectedUpdatedAt', 'changes']),
        );
        expect(body['changes'], {'countryCode': 'DE', 'region': 'Bayern'});
        final operation = await _request(body);
        final durable = jsonDecode(_files(directory).single.readAsStringSync());
        expect(durable['changes'], body['changes']);
        expect(durable['requestHash'], operation.requestHash);
        expect(durable['operationId'], operation.operationId);
        expect(durable['operation'], 'profile.edit-geography.v1');
        expect(durable.toString(), isNot(contains('na1.A')));
        return _reply(
          _receipt(operation, refusal ?? _completed('A')),
          status: refusal == null ? 200 : refusalStatus,
        );
      });
      final client = _client(_Store(), wire);
      final session = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      try {
        await session.restore();
        stage = 'registration';
        await expectLater(_open(client, session, journal), throwsStateError);
        stage = 'test';
        final flow = await _open(client, session, journal);
        expect(flow.countryCode, 'AU');
        expect(flow.region, 'New South Wales');
        for (final pair in [
          ['de', 'Bayern'],
          ['DE', 'bayern'],
          ['DE', ''],
          ['DE', ' Bayern'],
          ['ZZ', 'Bayern'],
        ]) {
          await expectLater(
            TimewebGeographyChanges.fromCatalog(
              countryCode: pair[0],
              region: pair[1],
            ),
            throwsArgumentError,
          );
        }
        final original = flow.save(countryCode: 'DE', region: 'Bayern');
        expect(
          identical(original, flow.save(countryCode: 'FR', region: 'Ain')),
          isTrue,
        );
        expect(await original, TimewebGeographyOutcome.confirmed);
        final receipt = flow.receipt!;
        expect(receipt.country, 'Германия');
        expect(receipt.region, 'Bayern');
        expect(receipt.updatedAt, _nextStamp);
        expect(_files(directory), isEmpty);
        expect(posts, 1);
        expect(
          () => flow.save(countryCode: 'FR', region: 'Ain'),
          throwsStateError,
        );
        flow.close();
        expect(() => receipt.country, throwsStateError);
        for (final error in [
          'profile_changed',
          'profile_not_ready',
          'profile_not_found',
        ]) {
          refusal = {
            'error': error,
            if (error == 'profile_changed') 'updatedAt': _nextStamp,
          };
          refusalStatus = error == 'profile_not_found' ? 404 : 409;
          final rejected = await _open(client, session, journal);
          expect(
            await rejected.save(countryCode: 'DE', region: 'Bayern'),
            TimewebGeographyOutcome.rejected,
          );
          expect(rejected.requiresReload, isTrue);
          expect(_files(directory), isEmpty);
          rejected.close();
        }
        expect(posts, 4);
      } finally {
        await session.stop();
        await journal.drain();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'lost ACK restarts exact pair lookup-only; not_found and malformed receipt never resend',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-geo-restart-',
      );
      final journal = TimewebGeographyJournal(directory: () async => directory);
      final store = _Store();
      TimewebMutationRequest? original;
      var posts = 0, lookups = 0, found = false, forged = false;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return _reply(_full('A', stage: 'search'));
        }
        if (request.method == 'POST') {
          posts++;
          original = await _request(jsonDecode((request as http.Request).body));
          throw const SocketException('Synthetic lost response');
        }
        lookups++;
        expect(
          request.url.path,
          '/v1/runtime/operations/profile.edit-geography.v1/${original!.operationId}',
        );
        expect(request.url.queryParameters, {
          'requestHash': original!.requestHash,
        });
        return _reply(
          found
              ? _receipt(original!, {
                  ..._completed('A'),
                  if (forged) 'country': 'Caller invented country',
                }, replayed: true)
              : {
                  'operation': original!.operation,
                  'operationId': original!.operationId,
                  'requestHash': original!.requestHash,
                  'state': 'not_found',
                  'replayed': false,
                  'result': null,
                  'entityRevision': null,
                },
        );
      });
      final client = _client(store, wire);
      final session = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      AppSession? restarted;
      try {
        await session.restore();
        final first = await _open(client, session, journal);
        expect(
          await first.save(countryCode: 'DE', region: 'Bayern'),
          TimewebGeographyOutcome.unknown,
        );
        final file = _files(directory).single,
            durable = _files(directory).single.readAsStringSync();
        first.close();
        await session.stop();
        await journal.drain();
        final nextClient = _client(store, wire);
        restarted = AppSession.timeweb(
          client: nextClient,
          clearLocal: () async {},
        );
        await restarted.restore();
        final recovered = await _open(nextClient, restarted, journal);
        expect(recovered.countryCode, 'DE');
        expect(recovered.region, 'Bayern');
        expect(recovered.needsCheck, isTrue);
        expect(
          () => recovered.save(countryCode: 'FR', region: 'Ain'),
          throwsStateError,
        );
        expect(await recovered.check(), TimewebGeographyOutcome.unknown);
        expect(file.readAsStringSync(), durable);
        found = true;
        forged = true;
        await expectLater(
          recovered.check(),
          throwsA(isA<TimewebAuthException>()),
        );
        expect(file.readAsStringSync(), durable);
        forged = false;
        expect(await recovered.check(), TimewebGeographyOutcome.confirmed);
        expect(posts, 1);
        expect(lookups, 3);
        expect(_files(directory), isEmpty);
        recovered.close();
        final damaged = jsonDecode(durable)..['requestHash'] = '0' * 64;
        for (final invalid in [
          jsonEncode(damaged),
          durable.replaceFirst('"version":1', '"version":1,"version":1'),
          'x' * 8193,
        ]) {
          await file.writeAsString(invalid, flush: true);
          await expectLater(
            _open(nextClient, restarted, journal),
            throwsFormatException,
          );
        }
        expect(posts, 1);
      } finally {
        await session.stop();
        await restarted?.stop();
        await journal.drain();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'A/B intent revokes late ACK before journal deletion; B cannot adopt A geography',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-geo-owner-',
      );
      final blocked = Completer<Directory>();
      var blockIO = false, waiting = false;
      final journal = TimewebGeographyJournal(
        directory: () async {
          if (blockIO) {
            waiting = true;
            return blocked.future;
          }
          return directory;
        },
      );
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') return _reply(_tokens('B'));
        if (request.method == 'GET') {
          return _reply(
            _full(
              request.headers['Authorization'] == 'Bearer na1.B' ? 'B' : 'A',
            ),
          );
        }
        final operation = await _request(
          jsonDecode((request as http.Request).body),
        );
        blockIO = true;
        return _reply(_receipt(operation, _completed('A')));
      });
      final client = _client(_Store(), wire);
      final session = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      try {
        await session.restore();
        final old = await _open(client, session, journal);
        final result = expectLater(
          old.save(countryCode: 'DE', region: 'Bayern'),
          throwsA(isA<AppSessionException>()),
        );
        await _until(() => waiting);
        final durable = _files(directory).single.readAsStringSync();
        final login = session.login(
          email: 'B@example.invalid',
          password: 'password',
          deviceId: 'synthetic-device',
        );
        expect(() => old.countryCode, throwsA(isA<AppSessionException>()));
        expect(() => old.region, throwsA(isA<AppSessionException>()));
        await login;
        blockIO = false;
        blocked.complete(directory);
        await result;
        expect(_files(directory).single.readAsStringSync(), durable);
        final b = await _open(client, session, journal);
        expect(b.countryCode, 'AU');
        expect(b.region, 'New South Wales');
        expect(b.needsCheck, isFalse);
        b.close();
        old.close();
      } finally {
        if (!blocked.isCompleted) blocked.complete(directory);
        await session.stop();
        await journal.drain();
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets(
    '360px native gate → own profile → editor → actual geo selectors → one receipt and fresh profile',
    (tester) async {
      expect(AppBackend.timewebProfileEditorEnabled, isFalse);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-geo-ui-'),
      ))!;
      var posts = 0, fullReads = 0, completed = false;
      final source = _full('A');
      final ack = Completer<http.StreamedResponse>();
      final wire = _Wire((request) async {
        if (request.method == 'GET') {
          if (request.url.path == '/v1/runtime/me/full-profile') {
            fullReads++;
            final body = {
              ...source,
              'profile': {
                ...source['profile'] as Map,
                if (completed) ...{
                  'country': 'Германия',
                  'countryCode': 'DE',
                  'region': 'Bayern',
                  'updatedAt': _nextStamp,
                },
              },
            };
            return _reply(body);
          }
          expect(request.url.path, '/v1/runtime/me/profile');
          return _reply(_editable(source));
        }
        posts++;
        final operation = await _request(
          jsonDecode((request as http.Request).body),
        );
        expect(operation.operation, 'profile.edit-geography.v1');
        expect(
          jsonDecode(_files(directory).single.readAsStringSync())['changes'],
          {'countryCode': 'DE', 'region': 'Bayern'},
        );
        return ack.future;
      });
      final runtime = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse(_origin),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: _Store(),
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        transport: wire,
        clock: () => _now,
        profileEditorEnabled: true,
        currentOwnProfileEnabled: true,
        geographyJournal: TimewebGeographyJournal(
          directory: () async => directory,
        ),
        profileEditJournal: TimewebProfileEditJournal(
          directory: () async => directory,
        ),
      );
      await tester.binding.setSurfaceSize(const Size(360, 640));
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebSessionGate(runtime: runtime),
          ),
        );
        await _widgetUntil(
          tester,
          () => find.byType(TimewebOwnProfilePage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await _widgetUntil(
          tester,
          () => find.byType(TimewebProfileEditPage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('timeweb-profile-location')),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(
          find.byKey(const ValueKey('timeweb-profile-location')),
        );
        await _widgetUntil(
          tester,
          () =>
              find.byType(TimewebGeographyPage).evaluate().isNotEmpty &&
              find.byType(DropdownButtonFormField<String>).evaluate().length ==
                  2,
        );
        await tester.pumpAndSettle();
        expect(find.byType(MeetingLocationFields), findsOneWidget);
        expect(
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('timeweb-geography-save')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Германия'),
          120,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text('Германия').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>).last,
              )
              .initialValue,
          isNull,
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bayern').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('timeweb-geography-save')));
        await _widgetUntil(tester, () => posts == 1);
        expect(
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('timeweb-geography-save')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<AbsorbPointer>(
                find.byKey(const ValueKey('timeweb-geography-fields')),
              )
              .absorbing,
          isTrue,
        );
        final body = jsonDecode(_files(directory).single.readAsStringSync());
        final operation = (await tester.runAsync(
          () => _request({
            'operationId': body['operationId'],
            'expectedUpdatedAt': body['expectedUpdatedAt'],
            'changes': body['changes'],
          }),
        ))!;
        completed = true;
        ack.complete(_reply(_receipt(operation, _completed('A'))));
        await _widgetUntil(
          tester,
          () =>
              fullReads == 3 &&
              find.byType(TimewebGeographyPage).evaluate().isEmpty &&
              find.byType(TimewebProfileEditPage).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
        expect(posts, 1);
        expect(fullReads, 3);
        await tester.scrollUntilVisible(
          find.text('Bayern'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Bayern'), findsOneWidget);
        expect(find.text('Германия'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Current A'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Current A'), findsOneWidget);
        expect(_files(directory), isEmpty);
        expect(Firebase.apps, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.binding.setSurfaceSize(null);
        await tester.pumpWidget(const SizedBox());
        await _stop(tester, runtime);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'A geo popup closes on B intent without popping a newer B route',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-geo-popup-owner-'),
      ))!;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') return _reply(_tokens('B'));
        if (request.method == 'GET') return _reply(_full('A'));
        fail('No geography write expected.');
      });
      final runtime = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse(_origin),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: _Store(),
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        transport: wire,
        clock: () => _now,
        profileEditorEnabled: true,
        currentOwnProfileEnabled: true,
        geographyJournal: TimewebGeographyJournal(
          directory: () async => directory,
        ),
        profileEditJournal: TimewebProfileEditJournal(
          directory: () async => directory,
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        final snapshot = (await tester.runAsync(
          runtime.readCurrentOwnProfile,
        ))!;
        final flow = (await tester.runAsync(
          () => runtime.openGeography(snapshot),
        ))!;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: LrsTheme.theme,
            home: const Scaffold(body: Text('A home')),
          ),
        );
        unawaited(
          navigator.currentState!.push<void>(
            MaterialPageRoute(builder: (_) => TimewebGeographyPage(flow: flow)),
          ),
        );
        await _widgetUntil(
          tester,
          () =>
              find.byType(DropdownButtonFormField<String>).evaluate().length ==
              2,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<String>).last);
        await tester.pumpAndSettle();
        expect(find.text('New South Wales'), findsAtLeastNWidgets(1));
        final login = runtime.session.login(
          email: 'B@example.invalid',
          password: 'password',
          deviceId: 'synthetic-device',
        );
        // No frame separates the B intent and its newer unrelated outer route.
        unawaited(
          navigator.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('B route stays')),
            ),
          ),
        );
        await _widgetUntil(
          tester,
          () =>
              runtime.session.currentUid == 'B' &&
              find.text('B route stays').evaluate().isNotEmpty,
        );
        expect((await login).confirmed, isTrue);
        await tester.pumpAndSettle();
        expect(find.text('B route stays'), findsOneWidget);
        expect(find.byType(TimewebGeographyPage), findsNothing);
        expect(find.text('New South Wales'), findsNothing);
        expect(flow.requireCurrent, throwsStateError);
        expect(Firebase.apps, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await _stop(tester, runtime);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
