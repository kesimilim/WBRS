import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/edit_profile/timeweb_profile_edit_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_profile_edit_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

final _now = DateTime.utc(2026, 10, 2);
const _stamp = '2026-10-02T12:00:00.000001Z';
const _nextStamp = '2026-10-02T12:00:00.000002Z';
TimewebSession _session(String uid) => TimewebSession(
  uid: uid,
  emailVerified: true,
  accessToken: 'na1.$uid',
  refreshToken: 'nr1.$uid',
  accessExpiresAt: _now.add(const Duration(minutes: 15)),
  refreshExpiresAt: _now.add(const Duration(days: 14)),
);

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = _session('A');
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

http.StreamedResponse _reply(
  Object body, {
  int status = 200,
  Map<String, String>? headers,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers:
      headers ??
      {'content-type': 'application/json', 'cache-control': 'no-store'},
);
Map<String, dynamic> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid',
  'refreshToken': 'nr1.$uid',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
Map<String, dynamic> _profile(String uid) => {
  'fullName': ' Current $uid ',
  'age': 0,
  'rost': 0,
  'about': ' old\n ',
  'hobbi': null,
  'deti': null,
  'pol': null,
  'relationStatus': null,
  'country': '  Россия ',
  'countryCode': 'RU',
  'region': null,
  'city': ' Москва ',
  'languageCode': 'ru',
  'primaryGroup': '  БЕЛАЯ ',
  'secondaryGroup': null,
  'profileDetailsSaved': false,
  'isRegistrationEnd': false,
  'updatedAt': _stamp,
};
Map<String, dynamic> _full(
  String uid, {
  Map<String, dynamic>? profile,
  String stage = 'search',
  bool missing = false,
}) => {
  'uid': uid,
  'profileExists': !missing,
  'profile': missing ? null : profile ?? _profile(uid),
  'onboarding': missing ? 'registration' : stage,
  'profileAuthority': 'canonical-current-v1',
  'mediaReady': false,
};
Map<String, dynamic> _editable(String uid, Map<String, dynamic> profile) => {
  'uid': uid,
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
TimewebAuthClient _client(
  _Store store,
  _Wire wire, {
  bool enabled = true,
  Duration deadline = const Duration(seconds: 10),
}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
    currentReadsEnabled: enabled,
    runtimeWritesEnabled: enabled,
  ),
  secureStore: store,
  transport: wire,
  clock: () => _now,
  requestDeadline: deadline,
);
Matcher _error(TimewebAuthError reason) =>
    isA<TimewebAuthException>().having((e) => e.error, 'error', reason);
TimewebAppRuntime _runtime(
  _Store store,
  _Wire wire,
  Directory directory, {
  Future<void> Function()? clearLocal,
}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: store,
  deviceId: 'synthetic-device',
  expectedSourceSnapshot: 'a' * 64,
  clearLocal: clearLocal ?? () async {},
  transport: wire,
  clock: () => _now,
  currentOwnProfileEnabled: true,
  currentChatsEnabled: true,
  profileEditorEnabled: true,
  profileEditJournal: TimewebProfileEditJournal(
    directory: () async => directory,
  ),
);
Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(condition(), isTrue);
}

Future<void> _stopRuntime(
  WidgetTester tester,
  TimewebAppRuntime runtime,
) async {
  var settled = false;
  final original = runtime.stop().then((value) {
    settled = true;
    return value;
  });
  await _until(tester, () => settled);
  expect(await original, isTrue);
}

Future<void> _wait(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(finder, findsOneWidget);
}

Future<void> _openOwnFromDirectory(WidgetTester tester) async {
  final entry = find.byKey(const ValueKey('timeweb-people-own-profile'));
  await _wait(tester, entry);
  await _until(
    tester,
    () => tester.widget<ElevatedButton>(entry).onPressed != null,
  );
  await tester.pumpAndSettle();
  await tester.tap(entry);
}

void main() {
  test(
    'canonical GET preserves source bytes, nullable facts and all onboarding stages; default off',
    () async {
      expect(AppBackend.timewebOwnProfileEnabled, isFalse);
      final values = [
        _full('A'),
        _full('A', missing: true),
        _full(
          'A',
          profile: _profile('A')..['primaryGroup'] = null,
          stage: 'registration',
        ),
        _full(
          'A',
          profile: _profile('A')
            ..['primaryGroup'] = null
            ..['profileDetailsSaved'] = true,
          stage: 'test',
        ),
        _full(
          'A',
          profile: _profile('A')
            ..['primaryGroup'] = null
            ..['pol'] = 'м'
            ..['hobbi'] = 'h',
          stage: 'test',
        ),
        _full(
          'A',
          profile: _profile('A')
            ..['primaryGroup'] = null
            ..['pol'] = ' '
            ..['about'] = ' '
            ..['hobbi'] = ' ',
          stage: 'test',
        ),
        _full(
          'A',
          profile: _profile('A')
            ..['primaryGroup'] = null
            ..['isRegistrationEnd'] = true,
        ),
      ];
      var next = 0;
      final wire = _Wire((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/runtime/me/full-profile');
        expect(request.url.hasQuery, isFalse);
        expect(request.headers['Authorization'], 'Bearer na1.A');
        return _reply(values[next++]);
      });
      final client = _client(_Store(), wire);
      await client.restore();
      final first = await client.readCurrentOwnProfile();
      expect(first.profileAuthority, 'canonical-current-v1');
      expect(first.mediaReady, isFalse);
      expect(first.profile!.fullName, ' Current A ');
      expect(first.profile!.about, ' old\n ');
      expect(first.profile!.primaryGroup, '  БЕЛАЯ ');
      expect(first.profile!.deti, isNull);
      expect(first.profile!.age, 0);
      expect(first.profile!.rost, 0);
      expect((await client.readCurrentOwnProfile()).profileExists, isFalse);
      expect(
        (await client.readCurrentOwnProfile()).onboarding,
        TimewebOnboarding.registration,
      );
      expect(
        (await client.readCurrentOwnProfile()).onboarding,
        TimewebOnboarding.test,
      );
      expect(
        (await client.readCurrentOwnProfile()).onboarding,
        TimewebOnboarding.test,
      );
      expect(
        (await client.readCurrentOwnProfile()).onboarding,
        TimewebOnboarding.test,
      );
      expect(
        (await client.readCurrentOwnProfile()).onboarding,
        TimewebOnboarding.search,
      );
      expect(Firebase.apps, isEmpty);
      await client.close();
      expect(
        () => first.profile!.fullName,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
    },
  );

  test(
    'current route refuses disabled and exact malformed envelope/profile without broad maps',
    () async {
      final bad = <Map<String, dynamic>>[
        _full('B'),
        _full('A')..['profileExists'] = false,
        _full('A')..['mediaReady'] = true,
        _full('A')..['profileAuthority'] = 'immutable-reviewed-snapshot',
        _full('A')..['balance'] = 1,
        _full('A')..['onboarding'] = 'registration',
        _full('A', profile: _profile('A')..['uid'] = 'A'),
        _full('A', profile: _profile('A')..['age'] = 131),
        _full('A', profile: _profile('A')..['age'] = 1.5),
        _full('A', profile: _profile('A')..['rost'] = 301),
        _full('A', profile: _profile('A')..['deti'] = 'false'),
        _full('A', profile: _profile('A')..['fullName'] = 'x' * 1001),
        _full('A', profile: _profile('A')..['country'] = 'x' * 192),
        _full('A', profile: _profile('A')..['about'] = '\u0000'),
        _full('A', profile: _profile('A')..['updatedAt'] = 'yesterday'),
        _full('A', profile: _profile('A')..remove('languageCode')),
        _full(
          'A',
          profile: _profile('A')
            ..['primaryGroup'] = null
            ..['secondaryGroup'] = 'белая',
        ),
      ];
      var next = 0;
      final wire = _Wire((_) async => _reply(bad[next++]));
      final client = _client(_Store(), wire);
      await client.restore();
      for (final _ in bad) {
        await expectLater(
          client.readCurrentOwnProfile(),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
      await client.close();
      final blocked = _client(_Store(), wire, enabled: false);
      await blocked.restore();
      await expectLater(
        blocked.readCurrentOwnProfile(),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      expect(wire.calls, hasLength(bad.length));
      await blocked.close();
    },
  );

  test(
    'same epoch shares read; A/B immediately revokes nested DTO and aborts late A',
    () async {
      final late = Completer<http.StreamedResponse>();
      var reads = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') return _reply(_tokens('B'));
        if (request.url.path == '/v1/auth/logout') return _reply({'ok': true});
        reads++;
        return reads == 2
            ? late.future
            : _reply(
                _full(
                  request.headers['Authorization'] == 'Bearer na1.B'
                      ? 'B'
                      : 'A',
                ),
              );
      });
      final client = _client(_Store(), wire);
      await client.restore();
      final first = await client.readCurrentOwnProfile();
      final nested = first.profile!;
      final a = client.readCurrentOwnProfile();
      final same = client.readCurrentOwnProfile();
      expect(identical(a, same), isTrue);
      final failure = expectLater(
        a,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await client.login(
        email: 'B@example.invalid',
        password: 'password',
        deviceId: 'test-device',
      );
      await failure;
      expect(
        () => nested.about,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      final b = await client.readCurrentOwnProfile();
      expect(b.uid, 'B');
      expect(b.profile!.fullName, ' Current B ');
      late.complete(_reply(_full('A')));
      await Future<void>.delayed(Duration.zero);
      expect(b.profile!.fullName, ' Current B ');
      await client.logout();
      expect(
        () => b.profile!.fullName,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await client.close();
    },
  );

  test(
    'hard deadline aborts hanging read and rejects response over 64KiB/cache redirect',
    () async {
      final late = Completer<http.StreamedResponse>();
      final wire = _Wire((_) => late.future);
      final client = _client(
        _Store(),
        wire,
        deadline: const Duration(milliseconds: 10),
      );
      await client.restore();
      final read = client.readCurrentOwnProfile();
      await expectLater(read, throwsA(_error(TimewebAuthError.deadline)));
      final request = wire.calls.single as http.AbortableRequest;
      await request.abortTrigger;
      late.complete(_reply(_full('A')));
      await Future<void>.delayed(Duration.zero);
      await client.close();
      final invalid = [
        _reply({'body': 'x' * 65537}),
        _reply(
          _full('A'),
          headers: {
            'content-type': 'application/json',
            'cache-control': 'no-store, public',
          },
        ),
        _reply(_full('A'), status: 302),
      ];
      var next = 0;
      final other = _client(_Store(), _Wire((_) async => invalid[next++]));
      await other.restore();
      for (final _ in invalid) {
        await expectLater(
          other.readCurrentOwnProfile(),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
      await other.close();
    },
  );

  test(
    'facade owner intent revokes envelope and nested fields before client login/local clear',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'clrs-current-own-lease-',
      );
      Completer<void>? clearing;
      final wire = _Wire(
        (request) async => request.url.path == '/v1/auth/login'
            ? _reply(_tokens('B'))
            : _reply(_full('A')),
      );
      final runtime = _runtime(
        _Store(),
        wire,
        directory,
        clearLocal: () async {
          await clearing?.future;
        },
      );
      try {
        await runtime.start(remember: true);
        final retained = await runtime.readCurrentOwnProfile();
        final nested = retained.profile!;
        clearing = Completer<void>();
        final login = runtime.login(
          email: 'B@example.invalid',
          password: 'password',
        );
        expect(runtime.client.currentUid, 'A');
        expect(() => retained.uid, throwsA(isA<AppSessionException>()));
        expect(() => retained.onboarding, throwsA(isA<AppSessionException>()));
        expect(() => nested.fullName, throwsA(isA<AppSessionException>()));
        expect(() => nested.about, throwsA(isA<AppSessionException>()));
        clearing.complete();
        expect((await login).confirmed, isTrue);
        expect(runtime.session.currentUid, 'B');
      } finally {
        if (clearing != null && !clearing.isCompleted) clearing.complete();
        await runtime.stop();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'native gate directory opens own profile and chats; edit confirmation rereads current full profile',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-current-own-'),
      ))!;
      final store = _Store();
      var fullReads = 0, posts = 0;
      final data = _profile('A');
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/runtime/people') {
          return _reply({
            'kind': 'canonical-current',
            'ordering': 'last_online_at_desc_uid_binary_asc_null_last',
            'items': [],
            'nextCursor': null,
            'mediaReady': false,
          });
        }

        if (request.method == 'GET') {
          if (request.url.path == '/v1/runtime/me/full-profile') {
            fullReads++;
            return _reply(_full('A', profile: data));
          }
          expect(request.url.path, '/v1/runtime/me/profile');
          return _reply(_editable('A', data));
        }
        expect(request.url.path, '/v1/runtime/me/profile');
        posts++;
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(body['changes'], {
          'about': '  Updated current description with enough characters  ',
        });
        final operation = TimewebMutationRequest.editOwnProfile(
          operationId: body['operationId'],
          expectedUpdatedAt: body['expectedUpdatedAt'],
          changes: TimewebProfileChanges(about: body['changes']['about']),
        );
        data['about'] = body['changes']['about'];
        data['updatedAt'] = _nextStamp;
        return _reply({
          'operation': operation.operation,
          'operationId': operation.operationId,
          'requestHash': operation.requestHash,
          'state': 'committed',
          'replayed': false,
          'entityRevision': null,
          'result': {
            'uid': 'A',
            'profile': _editable('A', data)['profile'],
            'operationId': operation.operationId,
            'profileAuthority': 'canonical-current-v1',
          },
        });
      });
      final runtime = _runtime(store, wire, directory);
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebSessionGate(runtime: runtime),
          ),
        );
        await _openOwnFromDirectory(tester);
        await _wait(tester, find.byType(TimewebOwnProfilePage));
        await tester.pumpAndSettle();
        expect(find.text(' Current A '), findsOneWidget);
        expect(fullReads, 2);
        expect(
          find.byKey(const ValueKey('timeweb-open-chats')),
          findsOneWidget,
        );
        expect(find.text('В сети'), findsNothing);
        expect(find.text('Не в сети'), findsNothing);
        expect(find.text('Ваш баланс: '), findsNothing);
        expect(Firebase.apps, isEmpty);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await _wait(tester, find.byType(TimewebProfileEditPage));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-about')),
          '  Updated current description with enough characters  ',
        );
        await tester.runAsync(() async {
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('timeweb-profile-save')),
              )
              .onPressed!();
          for (var i = 0; i < 100 && posts == 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        });
        await _until(
          tester,
          () =>
              fullReads == 3 &&
              find.byType(TimewebProfileEditPage).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
        expect(fullReads, 3);
        expect(posts, 1);
        await tester.scrollUntilVisible(
          find.text(data['about']),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.text('  Updated current description with enough characters  '),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await _stopRuntime(tester, runtime);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'A/B closes current editor and late full profile; 360px and keyboard preserve layout',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-current-own-ab-'),
      ))!;
      final late = Completer<http.StreamedResponse>();
      final store = _Store();
      var readsA = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/runtime/people') {
          return _reply({
            'kind': 'canonical-current',
            'ordering': 'last_online_at_desc_uid_binary_asc_null_last',
            'items': [],
            'nextCursor': null,
            'mediaReady': false,
          });
        }

        if (request.url.path == '/v1/auth/login') return _reply(_tokens('B'));
        final uid = request.headers['Authorization'] == 'Bearer na1.B'
            ? 'B'
            : 'A';
        if (request.url.path == '/v1/runtime/me/profile') {
          return _reply(_editable(uid, _profile(uid)));
        }
        expect(request.url.path, '/v1/runtime/me/full-profile');
        if (uid == 'A' && ++readsA == 3) return late.future;
        return _reply(
          _full(
            uid,
            profile: _profile(uid)
              ..['fullName'] = ' Current $uid ${'long ' * 30}',
          ),
        );
      });
      final runtime = _runtime(store, wire, directory);
      await tester.binding.setSurfaceSize(const Size(360, 640));
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebSessionGate(runtime: runtime),
          ),
        );
        await _openOwnFromDirectory(tester);
        await _wait(tester, find.byType(TimewebOwnProfilePage));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await _wait(tester, find.byType(TimewebProfileEditPage));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-profile-name')),
          'private A edited text',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pump();
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.tap(find.byTooltip('Back'));
        await tester.pump(const Duration(milliseconds: 350));
        expect(readsA, 3);
        await tester.runAsync(
          () => runtime.login(email: 'B@example.invalid', password: 'password'),
        );
        await _openOwnFromDirectory(tester);
        await _wait(tester, find.textContaining('Current B'));
        await tester.pumpAndSettle();
        late.complete(_reply(_full('A')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Current B'), findsOneWidget);
        expect(find.textContaining('Current A'), findsNothing);
        expect(find.text('private A edited text'), findsNothing);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(
          find.byKey(const ValueKey('timeweb-open-profile-editor')),
        );
        await _wait(tester, find.byType(TimewebProfileEditPage));
        await tester.pumpAndSettle();
        expect(find.text(' Current B '), findsOneWidget);
        await tester.runAsync(
          () => runtime.login(email: 'B@example.invalid', password: 'password'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TimewebProfileEditPage), findsNothing);
        expect(find.text('private A edited text'), findsNothing);
        expect(tester.takeException(), isNull);
        expect(Firebase.apps, isEmpty);
      } finally {
        if (!late.isCompleted) late.complete(_reply(_full('A')));
        tester.view.resetViewInsets();
        await tester.binding.setSurfaceSize(null);
        await tester.pumpWidget(const SizedBox());
        await _stopRuntime(tester, runtime);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
