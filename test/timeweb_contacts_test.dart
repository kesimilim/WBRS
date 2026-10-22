import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_contacts_flow.dart';
import 'package:wbrs/presentation/screens/contacts/timeweb_contacts_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'support/timeweb_people_fixtures.dart';

Map<String, dynamic> item(
  String uid, {
  String status = 'friends',
  int revision = 1,
}) => {
  'uid': uid,
  'fullName': 'Анна с очень длинным именем для маленького экрана',
  'city': 'Санкт-Петербург',
  'age': 28,
  'primaryGroup': 'белая',
  'status': status,
  'revision': revision,
  'updatedAt': peopleStamp,
};
Map<String, dynamic> page(
  String kind,
  List<Map<String, dynamic>> items, {
  String? cursor,
}) => {
  'kind': 'native-contacts',
  'list': kind,
  'items': items,
  'nextCursor': cursor,
};
TimewebMutationRequest request(Map<String, dynamic> body) =>
    TimewebMutationRequest.contactAction(
      operationId: body['operationId'],
      action: TimewebContactAction.fromPayload(body['payload']),
    );
Map<String, dynamic> receipt(
  Map<String, dynamic> body, {
  bool found = true,
  bool replayed = false,
  bool unavailable = false,
}) {
  final op = request(body), p = body['payload'];
  return {
    'operation': op.operation,
    'operationId': op.operationId,
    'requestHash': op.requestHash,
    'state': found ? 'committed' : 'not_found',
    'replayed': found && replayed,
    'entityRevision': found && !unavailable ? p['expectedRevision'] + 1 : null,
    'result': !found
        ? null
        : unavailable
        ? {'error': 'contact_unavailable'}
        : {
            'kind': 'native-relationship',
            'targetUid': p['targetUid'],
            'status': const {
              'send': 'outgoing',
              'accept': 'friends',
              'decline': 'none',
              'remove': 'none',
              'cancel': 'none',
            }[p['kind']],
            'revision': p['expectedRevision'] + 1,
          },
  };
}

TimewebAppRuntime runtime(
  PeopleWire wire,
  Directory folder, {
  PeopleStore? store,
}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: store ?? PeopleStore(),
  transport: wire,
  deviceId: 'fixture',
  expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {},
  clock: () => peopleNow,
  currentOwnProfileEnabled: true,
  contactsJournal: TimewebContactsJournal(directory: () async => folder),
  visitsJournal: TimewebContactsJournal(
    directory: () async => folder,
    visitsOnly: true,
  ),
);

Future<void> until(WidgetTester t, bool Function() condition) async {
  for (var i = 0; i < 150 && !condition(); i++) {
    await t.pump(const Duration(milliseconds: 16));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(condition(), isTrue);
}

final captureKey = GlobalKey();
Future<void> capture(WidgetTester t, String name) async {
  const directory = String.fromEnvironment('CLRS_CONTACTS_CAPTURE');
  if (directory.isEmpty) return;
  await t.pump(const Duration(milliseconds: 100));
  final boundary =
      captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(bytes);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in <String, List<String>>{
      'Lato': ['assets/fonts/Lato-Regular.ttf', 'assets/fonts/Lato-Bold.ttf'],
      'CormorantGaramond': ['assets/fonts/CormorantGaramond-Variable.ttf'],
      'Caveat': ['assets/fonts/Caveat-Variable.ttf'],
      'MaterialIcons': ['fonts/MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(font.key);
      for (final path in font.value) {
        loader.addFont(rootBundle.load(path));
      }
      await loader.load();
    }
  });
  test(
    'lost response survives reopening, not-found cannot resend, matching receipt retires action',
    () async {
      final folder = await Directory.systemTemp.createTemp('clrs-contacts-');
      late Map<String, dynamic> original;
      var posts = 0, found = false;
      final wire = PeopleWire((r) async {
        if (r.method == 'POST') {
          posts++;
          original = jsonDecode((r as http.Request).body);
          expect(r.url.path, '/v1/runtime/contacts/actions');
          return peopleReply({'error': 'outcome_unknown'}, status: 503);
        }
        expect(
          r.url.path,
          '/v1/runtime/contacts/operations/contacts.change.v1/${original['operationId']}',
        );
        return peopleReply(receipt(original, found: found, replayed: true));
      });
      final app = runtime(wire, folder);
      await app.start(remember: true);
      addTearDown(() async {
        await app.stop();
        await folder.delete(recursive: true);
      });
      var flow = await app.openContacts();
      expect(
        await flow.submit(
          TimewebContactAction(
            kind: 'send',
            targetUid: 'B',
            expectedRevision: 0,
          ),
        ),
        TimewebContactsOutcome.unknown,
      );
      flow.close();
      flow = await app.openContacts();
      expect(flow.needsCheck, isTrue);
      expect(await flow.check(), TimewebContactsOutcome.unknown);
      expect(
        () => flow.submit(
          TimewebContactAction(
            kind: 'send',
            targetUid: 'C',
            expectedRevision: 0,
          ),
        ),
        throwsStateError,
      );
      found = true;
      expect(await flow.check(), TimewebContactsOutcome.confirmed);
      expect(flow.needsCheck, isFalse);
      expect(flow.receipt!.status, 'outgoing');
      expect(posts, 1);
      flow.close();
    },
  );
  test(
    'unavailable target has a committed rejection and does not block later actions',
    () async {
      final folder = await Directory.systemTemp.createTemp('clrs-contacts-');
      final app = runtime(
        PeopleWire(
          (r) async => peopleReply(
            receipt(jsonDecode((r as http.Request).body), unavailable: true),
            status: 404,
          ),
        ),
        folder,
      );
      await app.start(remember: true);
      addTearDown(() async {
        await app.stop();
        await folder.delete(recursive: true);
      });
      final flow = await app.openContacts();
      expect(
        await flow.submit(
          TimewebContactAction(
            kind: 'send',
            targetUid: 'B',
            expectedRevision: 0,
          ),
        ),
        TimewebContactsOutcome.rejected,
      );
      expect(flow.needsCheck, isFalse);
      expect(flow.failure, TimewebMutationFailure.personUnavailable);
      flow.close();
    },
  );
  test(
    'cursor belongs to its kind and stale result is invalid after logout',
    () async {
      final folder = await Directory.systemTemp.createTemp('clrs-contacts-');
      final app = runtime(
        PeopleWire((r) async {
          if (r.url.path.endsWith('/auth/logout'))
            return peopleReply({'revoked': true});
          return peopleReply(
            page('guests', [
              item('B', status: 'guest', revision: 0),
            ], cursor: 'opaque'),
          );
        }),
        folder,
      );
      await app.start(remember: true);
      addTearDown(() async {
        await app.stop();
        await folder.delete(recursive: true);
      });
      final first = await app.readContacts('guests');
      expect(first.items.single.uid, 'B');
      await expectLater(
        app.readContacts('friends', after: first),
        throwsArgumentError,
      );
      await app.session.logout();
      expect(() => first.items, throwsA(anything));
    },
  );
  testWidgets(
    'friends tabs and guests render in 320px, lazy rows, retry clears error',
    (t) async {
      final folder = (await t.runAsync(
        () => Directory.systemTemp.createTemp('clrs-contacts-widget-'),
      ))!;
      var fail = true, gets = 0;
      final wire = PeopleWire((r) async {
        if (r.url.path == '/v1/runtime/contacts') {
          gets++;
          if (fail)
            return peopleReply({'error': 'service_unavailable'}, status: 503);
          final kind = r.url.queryParameters['kind']!;
          return peopleReply(
            page(
              kind,
              List.generate(
                20,
                (i) => item(
                  'person$i',
                  status: kind == 'guests' ? 'guest' : kind,
                  revision: kind == 'guests' ? 0 : 1,
                ),
              ),
            ),
          );
        }
        return peopleReply({'error': 'not_found'}, status: 404);
      });
      final app = runtime(wire, folder);
      await t.runAsync(() => app.start(remember: true));
      t.view.physicalSize = const Size(320, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RepaintBoundary(key: captureKey, child: child!),
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: LrsTheme.theme,
          home: TimewebContactsPageView(runtime: app),
        ),
      );
      await until(t, () => find.text('Повторить').evaluate().isNotEmpty);
      fail = false;
      await t.tap(find.text('Повторить'));
      await until(
        t,
        () => find
            .byKey(const ValueKey('contact-remove-person0'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('contact-remove-person19')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const ValueKey('contacts-tab-incoming')));
      await until(
        t,
        () => find
            .byKey(const ValueKey('contact-accept-person0'))
            .evaluate()
            .isNotEmpty,
      );
      await capture(t, 'contacts-incoming-320');
      expect(gets, 3);
      expect(t.takeException(), isNull);
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RepaintBoundary(key: captureKey, child: child!),
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: LrsTheme.theme,
          home: TimewebContactsPageView(
            key: const ValueKey('guests'),
            runtime: app,
            guests: true,
          ),
        ),
      );
      await until(
        t,
        () =>
            find.text('Гости').evaluate().isNotEmpty &&
            gets == 4 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find
                .text('Анна с очень длинным именем для маленького экрана')
                .evaluate()
                .isNotEmpty,
      );
      await t.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('contact-remove-person0')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
      await capture(t, 'contacts-guests-320');
      await t.pumpWidget(const SizedBox.shrink());
      var stopped = false;
      final stopping = app.stop().then((_) => stopped = true);
      await until(t, () => stopped);
      await stopping;
      await t.pump(const Duration(seconds: 1));
      await t.runAsync(() => folder.delete(recursive: true));
    },
  );
}
