import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/admin/timeweb_admin_users_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

Map<String, dynamic> _page(List<Object?> rows, [String? cursor]) => {
  'kind': 'canonical-admin-users',
  'ordering': 'uid_binary_asc',
  'items': rows,
  'nextCursor': cursor,
};
Map<String, dynamic> _user(String uid, String name, String email) => {
  'uid': uid,
  'fullName': name,
  'email': email,
  'age': null,
  'lifecycle': 'active',
  'disabled': false,
};
TimewebAppRuntime _runtime(PeopleWire wire) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: PeopleStore(),
  deviceId: 'synthetic-device',
  expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {},
  transport: wire,
  clock: () => peopleNow,
  currentOwnProfileEnabled: true,
);
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  await tester.pumpWidget(const SizedBox());
  var done = false;
  final stop = runtime.stop().then((value) {
    done = true;
    return value;
  });
  await _until(tester, () => done);
  expect(await stop, isTrue);
  await tester.binding.setSurfaceSize(null);
}

Finder _entry() => find.byKey(const ValueKey('timeweb-open-admin-users'));

void main() {
  testWidgets(
    '360px admin role probe, explicit sparse paging/prefix search and revoke without logout; 2x layout',
    (tester) async {
      var probes = 0, reads = 0;
      final wire = PeopleWire((request) async {
        expect(request.headers['Authorization'], 'Bearer na1.A.first');
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn('A'));
        }
        expect(request.url.path, '/v1/runtime/admin/users');
        if (request.url.queryParameters['limit'] == '1') {
          probes++;
          return peopleReply(
            _page([
              _user(
                'A',
                'Never render probe',
                'synthetic-probe@example.invalid',
              ),
            ]),
          );
        }
        expect(request.url.queryParameters['limit'], '30');
        reads++;
        if (reads == 1) return peopleReply(_page([], 'Opaque_sparse'));
        if (reads == 2) {
          expect(request.url.queryParameters['cursor'], 'Opaque_sparse');
          return peopleReply(
            _page([
              _user(
                'C',
                'Original synthetic name',
                'synthetic-person@example.invalid',
              ),
            ]),
          );
        }
        if (reads == 3) {
          expect(request.url.queryParameters, {'limit': '30', 'query': 'Syn'});
          return peopleReply(
            _page([
              _user(
                'Z',
                'Synthetic search',
                'synthetic-search@example.invalid',
              ),
            ], 'Opaque_search'),
          );
        }
        expect(request.url.queryParameters, {
          'limit': '30',
          'query': 'Syn',
          'cursor': 'Opaque_search',
        });
        return peopleReply({'privateError': 'never render'}, status: 403);
      });
      final runtime = _runtime(wire), navigator = GlobalKey<NavigatorState>();
      var scale = 1.0;
      late TimewebCurrentOwnProfile own;
      Widget app() => MaterialApp(
        navigatorKey: navigator,
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: TimewebOwnProfilePage(runtime: runtime, initialProfile: own),
      );
      try {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        await tester.runAsync(() async {
          await runtime.start(remember: true);
          own = await runtime.readCurrentOwnProfile();
        });
        await tester.pumpWidget(app());
        await _until(tester, () => _entry().evaluate().isNotEmpty);
        expect(probes, 1);
        expect(find.text('Never render probe'), findsNothing);
        await _tap(tester, _entry());
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-admin-next'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.byType(TimewebAdminUsersPage), findsOneWidget);
        expect(reads, 1);
        expect(
          find.text('По выбранным параметрам пока никого нет'),
          findsNothing,
        );
        await tester.pump(const Duration(seconds: 1));
        expect(reads, 1);
        await _tap(tester, find.byKey(const ValueKey('timeweb-admin-next')));
        await _until(
          tester,
          () => find.text('Имя: Original synthetic name').evaluate().isNotEmpty,
        );
        expect(reads, 2);
        expect(
          find.text('Электронная почта: synthetic-person@example.invalid'),
          findsOneWidget,
        );
        expect(find.text('Возраст: Не указано'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-admin-query')),
          'S',
        );
        await tester.pump();
        expect(find.textContaining('Original synthetic name'), findsNothing);
        expect(
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('timeweb-admin-search')),
              )
              .onPressed,
          isNull,
        );
        expect(reads, 2);
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-admin-query')),
          'Syn',
        );
        await _tap(tester, find.byKey(const ValueKey('timeweb-admin-search')));
        await _until(
          tester,
          () => find.text('Имя: Synthetic search').evaluate().isNotEmpty,
        );
        expect(reads, 3);
        scale = 2;
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const ValueKey('timeweb-admin-next')));
        await _until(
          tester,
          () => find.text('Доступ запрещён').evaluate().isNotEmpty,
        );
        expect(
          find.textContaining('Synthetic search', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.textContaining('synthetic-search', skipOffstage: false),
          findsNothing,
        );
        expect(runtime.session.currentUid, 'A');
        expect(runtime.session.state.authenticated, isTrue);
        expect(tester.takeException(), isNull);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(_entry(), findsNothing);
        expect(
          await tester.runAsync(() => runtime.probeAdminUsersAccess()),
          isFalse,
        );
        expect(probes, 1);
        expect(Firebase.apps, isEmpty);
      } finally {
        await _stop(tester, runtime);
      }
    },
  );

  testWidgets(
    '360px nonadmin stays in ordinary profile; only one bounded probe across remounts',
    (tester) async {
      var probes = 0;
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn('A'));
        }
        expect(request.url.path, '/v1/runtime/admin/users');
        expect(request.url.queryParameters, {'limit': '1'});
        probes++;
        return peopleReply({'secret': 'role denied'}, status: 403);
      });
      final runtime = _runtime(wire);
      try {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        late TimewebCurrentOwnProfile own;
        await tester.runAsync(() async {
          await runtime.start(remember: true);
          own = await runtime.readCurrentOwnProfile();
        });
        Widget app(String key) => MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebOwnProfilePage(
            key: ValueKey(key),
            runtime: runtime,
            initialProfile: own,
          ),
        );
        await tester.pumpWidget(app('first'));
        await _until(tester, () => probes == 1);
        await tester.pumpAndSettle();
        expect(_entry(), findsNothing);
        expect(find.text('Own A'), findsOneWidget);
        await tester.pumpWidget(app('second'));
        await tester.pumpAndSettle();
        expect(_entry(), findsNothing);
        expect(probes, 1);
        expect(runtime.session.state.authenticated, isTrue);
        expect(
          await tester.runAsync(() => runtime.readCurrentOwnProfile()),
          isNotNull,
        );
        expect(tester.takeException(), isNull);
        expect(Firebase.apps, isEmpty);
      } finally {
        await _stop(tester, runtime);
      }
    },
  );

  testWidgets(
    'A→B active admin page clears A query/email and late response; removes only old route',
    (tester) async {
      final late = Completer<http.StreamedResponse>();
      var reads = 0;
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        final b = request.headers['Authorization'] == 'Bearer na1.B.rotated';
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn(b ? 'B' : 'A'));
        }
        expect(request.url.path, '/v1/runtime/admin/users');
        if (request.url.queryParameters['limit'] == '1') {
          return peopleReply(_page([]), status: b ? 403 : 200);
        }
        reads++;
        if (reads == 1) {
          return peopleReply(
            _page([
              _user(
                'A',
                'Private A name',
                'synthetic-private-a@example.invalid',
              ),
            ]),
          );
        }
        return late.future;
      });
      final runtime = _runtime(wire), navigator = GlobalKey<NavigatorState>();
      try {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        late TimewebCurrentOwnProfile own;
        await tester.runAsync(() async {
          await runtime.start(remember: true);
          own = await runtime.readCurrentOwnProfile();
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: LrsTheme.theme,
            home: TimewebOwnProfilePage(runtime: runtime, initialProfile: own),
          ),
        );
        await _until(tester, () => _entry().evaluate().isNotEmpty);
        await _tap(tester, _entry());
        await _until(
          tester,
          () => find.text('Имя: Private A name').evaluate().isNotEmpty,
        );
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-admin-query')),
          'private-A-prefix',
        );
        await _tap(tester, find.byKey(const ValueKey('timeweb-admin-search')));
        await _until(tester, () => reads == 2);
        await tester.runAsync(
          () => runtime.login(
            email: 'synthetic-b@example.invalid',
            password: 'synthetic',
          ),
        );
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('B destination')),
          ),
        );
        await tester.pumpAndSettle();
        late.complete(
          peopleReply(
            _page([_user('A', 'Late private A', 'late-a@example.invalid')]),
          ),
        );
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pumpAndSettle();
        expect(find.text('B destination'), findsOneWidget);
        expect(
          find.byType(TimewebAdminUsersPage, skipOffstage: false),
          findsNothing,
        );
        expect(
          find.textContaining('Private A', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.textContaining('private-a@', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.textContaining('Late private A', skipOffstage: false),
          findsNothing,
        );
        expect(_entry(), findsNothing);
        expect(
          await tester.runAsync(() => runtime.probeAdminUsersAccess()),
          isFalse,
        );
        expect(runtime.session.currentUid, 'B');
        expect(tester.takeException(), isNull);
      } finally {
        if (!late.isCompleted) late.complete(peopleReply(_page([])));
        await _stop(tester, runtime);
      }
    },
  );

  testWidgets(
    'late successful A role probe cannot render admin entry for nonadmin B',
    (tester) async {
      final late = Completer<http.StreamedResponse>();
      var probesA = 0, probesB = 0;
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        final b = request.headers['Authorization'] == 'Bearer na1.B.rotated';
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn(b ? 'B' : 'A'));
        }
        expect(request.url.queryParameters, {'limit': '1'});
        if (b) {
          probesB++;
          return peopleReply({}, status: 403);
        }
        probesA++;
        return late.future;
      });
      final runtime = _runtime(wire);
      try {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        late TimewebCurrentOwnProfile own;
        await tester.runAsync(() async {
          await runtime.start(remember: true);
          own = await runtime.readCurrentOwnProfile();
        });
        Widget app(String uid) => MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebOwnProfilePage(
            key: ValueKey(uid),
            runtime: runtime,
            initialProfile: own,
          ),
        );
        await tester.pumpWidget(app('A'));
        await _until(tester, () => probesA == 1);
        expect(_entry(), findsNothing);
        await tester.runAsync(() async {
          await runtime.login(
            email: 'synthetic-b@example.invalid',
            password: 'synthetic',
          );
          own = await runtime.readCurrentOwnProfile();
        });
        await tester.pumpWidget(app('B'));
        await _until(tester, () => probesB == 1);
        late.complete(peopleReply(_page([])));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pumpAndSettle();
        expect(_entry(), findsNothing);
        expect(find.text('Own B'), findsOneWidget);
        expect(runtime.session.currentUid, 'B');
        expect(
          await tester.runAsync(() => runtime.probeAdminUsersAccess()),
          isFalse,
        );
        expect(probesB, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!late.isCompleted) late.complete(peopleReply(_page([])));
        await _stop(tester, runtime);
      }
    },
  );
}
