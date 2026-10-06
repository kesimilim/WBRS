import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/timeweb_person_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

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
  currentChatsEnabled: true,
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

Future<void> _visibleTap(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  await tester.pumpWidget(const SizedBox());
  var settled = false;
  final stop = runtime.stop().then((value) {
    settled = true;
    return value;
  });
  await _until(tester, () => settled);
  expect(await stop, isTrue);
}

void main() {
  testWidgets(
    '360px native gate → sparse directory → person → own profile/chats; real exact filters and 2x layout',
    (tester) async {
      var directoryCalls = 0;
      final wire = PeopleWire((request) async {
        expect(request.headers['Authorization'], 'Bearer na1.A.first');
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn('A'));
        }
        if (request.url.path == '/v1/runtime/people') {
          directoryCalls++;
          if (request.url.queryParameters.containsKey('countryCode')) {
            expect(request.url.queryParameters, {
              'limit': '30',
              'minAge': '18',
              'maxAge': '100',
              'countryCode': 'AU',
              'region': 'Australian Capital Territory',
              'pol': 'ж',
              'compatibleGroup': 'белая',
            });
            return peopleReply(directoryReply([]));
          }
          if (request.url.queryParameters['cursor'] ==
              'Encrypted_sparse_next') {
            return peopleReply(
              directoryReply([publicPerson('C', name: 'Visible person')]),
            );
          }
          return peopleReply(directoryReply([], 'Encrypted_sparse_next'));
        }
        if (request.url.path == '/v1/runtime/people/C') {
          return peopleReply(
            personReply(
              publicPerson('C', name: 'Visible person', details: true),
            ),
          );
        }
        if (request.url.path == '/v1/runtime/chats') {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'updated_at_desc_chat_id_asc_null_last',
            'items': [],
            'nextCursor': null,
          });
        }
        if (request.url.path == '/v1/runtime/events') {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'event_id_asc',
            'items': [],
            'nextAfterEventId': null,
          });
        }
        fail('Unexpected native request ${request.url.path}');
      });
      final runtime = _runtime(wire), navigator = GlobalKey<NavigatorState>();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      var scale = 1.0;
      Widget app() => MaterialApp(
        navigatorKey: navigator,
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: TimewebSessionGate(runtime: runtime),
      );
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(app());
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-people-next'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(directoryCalls, 1);
        expect(find.byType(TimewebOwnProfilePage), findsNothing);
        expect(
          find.text('По выбранным параметрам пока никого нет'),
          findsNothing,
        );
        expect(
          tester
              .widget<ElevatedButton>(
                find.byKey(const ValueKey('timeweb-people-next')),
              )
              .onPressed,
          isNotNull,
        );
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-next')),
        );
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-person-card-C'))
              .evaluate()
              .isNotEmpty,
        );
        expect(directoryCalls, 2);
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-person-card-C')),
        );
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-public-name'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.byType(TimewebPersonPage), findsOneWidget);
        expect(find.text('Visible person'), findsOneWidget);
        expect(find.text('В сети'), findsNothing);
        expect(find.text('Не в сети'), findsNothing);
        expect(find.text('Нет'), findsNothing);
        expect(find.textContaining('Не указано'), findsWidgets);
        expect(
          find.byKey(const ValueKey('timeweb-person-open-chat')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text('  Full\noriginal details  '),
          220,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('  Full\noriginal details  '), findsOneWidget);
        expect(find.text('Подарки'), findsNothing);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-own-profile')),
        );
        await _until(
          tester,
          () => find.byType(TimewebOwnProfilePage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.text('Own A'), findsOneWidget);
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-open-people')),
        );
        await _until(
          tester,
          () => find.byType(TimewebOwnProfilePage).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-chats')),
        );
        await _until(
          tester,
          () => find.byType(TimewebChatsPage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        scale = 2;
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-filters')),
        );
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-country')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Австралия').last);
        await tester.pumpAndSettle();
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-region-AU')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Australian Capital Territory').last);
        await tester.pumpAndSettle();
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-gender')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Женский').last);
        await tester.pumpAndSettle();
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-compatible')),
        );
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-people-apply')),
        );
        await _until(
          tester,
          () =>
              directoryCalls == 3 &&
              find
                  .text('По выбранным параметрам пока никого нет')
                  .evaluate()
                  .isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(
          find.text('По выбранным параметрам пока никого нет'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('timeweb-people-next')), findsNothing);
        expect(tester.takeException(), isNull);
        expect(Firebase.apps, isEmpty);
        expect(wire.calls.every((call) => call.method == 'GET'), isTrue);
      } finally {
        await _stop(tester, runtime);
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets(
    'A/B pending directory and detail clear A; own route cleanup never pops newer B destination',
    (tester) async {
      final lateDirectory = Completer<http.StreamedResponse>(),
          latePerson = Completer<http.StreamedResponse>();
      var defer = false;
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        final b = request.headers['Authorization'] == 'Bearer na1.B.rotated';
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn(b ? 'B' : 'A'));
        }
        if (request.url.path == '/v1/runtime/people/C') {
          return latePerson.future;
        }
        if (request.url.path == '/v1/runtime/people') {
          if (defer && !b) {
            return lateDirectory.future;
          }
          return peopleReply(
            directoryReply([
              publicPerson('C', name: b ? 'B public row' : 'A public row'),
            ]),
          );
        }
        fail('Unexpected native request ${request.url.path}');
      });
      final runtime = _runtime(wire), navigator = GlobalKey<NavigatorState>();
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: LrsTheme.theme,
            home: TimewebSessionGate(runtime: runtime),
          ),
        );
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-person-card-C'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
        final card = find.descendant(
          of: find.byKey(const ValueKey('timeweb-person-card-C')),
          matching: find.byType(InkWell),
        );
        await _until(tester, () => tester.widget<InkWell>(card).onTap != null);
        defer = true;
        final filters = await TimewebPeopleFilters.fromCatalog();
        final pending = runtime.readPeople(filters);
        final observed = pending.then<void>((_) {
          fail('Old A directory became public');
        }, onError: (Object _) {});
        await _visibleTap(
          tester,
          find.byKey(const ValueKey('timeweb-person-card-C')),
        );
        await _until(
          tester,
          () => find.byType(TimewebPersonPage).evaluate().isNotEmpty,
        );
        await tester.runAsync(
          () =>
              runtime.login(email: 'B@example.invalid', password: 'synthetic'),
        );
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('B destination')),
          ),
        );
        await _until(
          tester,
          () => find
              .textContaining('B public row', skipOffstage: false)
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.text('B destination'), findsOneWidget);
        lateDirectory.complete(
          peopleReply(
            directoryReply([publicPerson('C', name: 'Late private A')]),
          ),
        );
        latePerson.complete(
          peopleReply(
            personReply(
              publicPerson('C', name: 'Late private A', details: true),
            ),
          ),
        );
        await tester.runAsync(() => observed);
        await tester.pumpAndSettle();
        expect(find.text('B destination'), findsOneWidget);
        expect(
          find.byType(TimewebPersonPage, skipOffstage: false),
          findsNothing,
        );
        expect(
          find.textContaining('A public', skipOffstage: false),
          findsNothing,
        );
        expect(
          find.textContaining('Late private A', skipOffstage: false),
          findsNothing,
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await _until(
          tester,
          () => find.textContaining('B public row').evaluate().isNotEmpty,
        );
        expect(runtime.session.currentUid, 'B');
        expect(tester.takeException(), isNull);
        expect(Firebase.apps, isEmpty);
      } finally {
        if (!lateDirectory.isCompleted) {
          lateDirectory.complete(peopleReply(directoryReply([])));
        }
        if (!latePerson.isCompleted) {
          latePerson.complete(peopleReply({}, status: 404));
        }
        await _stop(tester, runtime);
      }
    },
  );
}
