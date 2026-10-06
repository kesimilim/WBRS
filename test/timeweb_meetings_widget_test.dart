import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_create_flow.dart';
import 'package:wbrs/shared/meeting_form.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

const _local = '03.10.2026 19:15';
Map<String, Object?> _meeting(String id, {String date = _local}) => {
  'meetingId': id,
  'organizerUid': 'A',
  'invitedUid': null,
  'kind': 'group',
  'title': 'Native meeting',
  'description': 'Описание текущей встречи',
  'countryCode': 'RU',
  'region': 'Москва',
  'startsAt': null,
  'createdAt': peopleStamp,
  'updatedAt': peopleStamp,
  'revision': 0,
  'localDatetime': date,
  'media': null,
  'mediaReady': false,
};
Map<String, Object?> _page(List<Object?> items, [String? cursor]) => {
  'kind': 'canonical-current',
  'ordering': 'starts_at_asc_meeting_id_asc_null_first',
  'scope': 'group',
  'items': items,
  'nextCursor': cursor,
  'mediaReady': false,
};
Map<String, Object?> _roster(List<Object?> items, [String? cursor]) => {
  'kind': 'canonical-current',
  'ordering': 'uid_binary_asc',
  'meetingId': 'm',
  'items': items,
  'nextCursor': cursor,
  'mediaReady': false,
};
TimewebAppRuntime _runtime(PeopleWire wire, {TimewebMeetingCreateJournal? journal}) => TimewebAppRuntime(
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
  meetingCreateJournal: journal,
);
Future<void> _until(WidgetTester tester, bool Function() ready, {String Function()? reason}) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(ready(), isTrue, reason: reason?.call());
}

Future<void> _tap(WidgetTester tester, String key, String scrollKey) async {
  final finder = find.byKey(ValueKey(key));
  final scroll = find.descendant(of: find.byKey(ValueKey(scrollKey)), matching: find.byType(Scrollable)).first;
  if (finder.evaluate().isEmpty) await tester.scrollUntilVisible(finder, 150, scrollable: scroll);
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pump();
  // Real pointer handler owns durable File IO; do not trap it in the fake timer zone.
  await tester.runAsync(() => tester.tap(finder));
  await tester.pump(const Duration(milliseconds: 350));
}

Widget _app(Widget child, {double scale = 1}) => RepaintBoundary(
  key: const ValueKey('native-meetings-render'),
  child: MaterialApp(
    theme: LrsTheme.theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  ),
);

Future<void> _capture(WidgetTester tester, String filename) async {
  final directory = Platform.environment['CLRS_NATIVE_UI_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('native-meetings-render')));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$directory/$filename').writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
    } finally {
      image.dispose();
    }
  });
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  await tester.pumpWidget(const SizedBox());
  var settled = false;
  final future = runtime.stop().then((value) {
    settled = true;
    return value;
  });
  await _until(tester, () => settled);
  expect(await future, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // The memoized approved catalog Future belongs to a live zone shared by
    // both widget cases, rather than the first case's disposed fake clock.
    await TimewebMeetingCreateRequest.fromCatalog(
      name: 'synthetic',
      description: '',
      countryCode: 'RU',
      region: 'Москва',
      datetime: _local,
      type: 'групповая',
    );
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
  testWidgets('360px 2x native sparse list, exact local date, roster and late A to B clear', (tester) async {
    final lateRoster = Completer<http.StreamedResponse>();
    var rosterCalls = 0;
    final wire = PeopleWire((request) async {
      if (request.url.path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      if (request.url.path == '/v1/runtime/meetings') {
        expect(
          request.url.queryParameters,
          request.url.queryParameters.containsKey('cursor')
              ? {'scope': 'group', 'limit': '30', 'cursor': 'Sparse_next'}
              : {'scope': 'group', 'limit': '30'},
        );
        return peopleReply(
          request.url.queryParameters.containsKey('cursor') ? _page([_meeting('m')]) : _page([], 'Sparse_next'),
        );
      }
      if (request.url.path == '/v1/runtime/meetings/m') {
        return peopleReply({'kind': 'canonical-current', 'meeting': _meeting('m'), 'mediaReady': false});
      }
      if (request.url.path == '/v1/runtime/meetings/m/participants') {
        rosterCalls++;
        if (request.url.queryParameters.containsKey('cursor')) return lateRoster.future;
        return peopleReply(
          _roster([
            {
              'uid': 'A',
              'fullName': null,
              'primaryGroup': null,
              'joinedAt': peopleStamp,
              'membershipRevision': 0,
              'avatar': null,
              'mediaReady': false,
            },
          ], 'Roster_next'),
        );
      }
      fail('Unexpected native request');
    });
    final runtime = _runtime(wire);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    try {
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(_app(TimewebMeetingsPageView(runtime: runtime), scale: 2));
      await _until(tester, () => find.byKey(const ValueKey('native-meetings-next')).evaluate().isNotEmpty);
      expect(find.text('По выбранным параметрам встреч пока нет'), findsNothing);
      expect(find.text('На этой странице нет доступных встреч'), findsOneWidget);
      await _tap(tester, 'native-meetings-next', 'native-meetings-scroll');
      await _until(tester, () => find.byKey(const ValueKey('native-meeting-m')).evaluate().isNotEmpty);
      await tester.pumpWidget(_app(TimewebMeetingsPageView(runtime: runtime)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Описание текущей встречи'), findsOneWidget);
      await _capture(tester, 'native-meetings-360px-1x.png');
      await _tap(tester, 'native-meeting-help', 'native-meetings-scroll');
      await _until(tester, () => find.byType(MeetingGuidePage).evaluate().isNotEmpty);
      final guide = find.descendant(of: find.byType(MeetingGuidePage), matching: find.byType(ClrsScaffold));
      expect(tester.widget<ClrsScaffold>(guide).bottomNavigationBar, isNull);
      expect(Firebase.apps, isEmpty);
      Navigator.of(tester.element(find.byType(MeetingGuidePage))).pop();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(_app(TimewebMeetingsPageView(runtime: runtime), scale: 2));
      await tester.pump(const Duration(milliseconds: 100));
      await _tap(tester, 'native-meeting-m', 'native-meetings-scroll');
      expect(
        wire.calls.any((request) => request.url.path == '/v1/runtime/meetings/m'),
        isTrue,
        reason: 'Card must start native detail read',
      );
      await _until(tester, () => find.byKey(const ValueKey('native-meeting-participants')).evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_local), findsOneWidget);
      expect(find.text('Присоединиться'), findsNothing);
      expect(find.text('Чат'), findsNothing);
      await _tap(tester, 'native-meeting-participants', 'native-meetings-scroll');
      await _until(tester, () => find.text('Имя не указано').evaluate().isNotEmpty);
      await _tap(tester, 'native-participants-next', 'native-meetings-scroll');
      await _until(tester, () => rosterCalls == 2);
      var logged = false;
      final login = runtime.login(email: 'B@example.invalid', password: 'synthetic').then((value) {
        logged = true;
        return value;
      });
      await _until(tester, () => find.text('Native meeting').evaluate().isEmpty);
      lateRoster.complete(
        peopleReply(
          _roster([
            {
              'uid': 'A',
              'fullName': 'Late A',
              'primaryGroup': null,
              'joinedAt': peopleStamp,
              'membershipRevision': 0,
              'avatar': null,
              'mediaReady': false,
            },
          ]),
        ),
      );
      await _until(tester, () => logged);
      await login;
      expect(find.text('Late A'), findsNothing);
      expect(find.text('Имя не указано'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      if (!lateRoster.isCompleted) lateRoster.complete(peopleReply(_roster([])));
      await _stop(tester, runtime);
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets(
    'native form before Firebase init: no legacy edit, unknown checks original once then ACK before native navigation',
    (tester) async {
      expect(Firebase.apps, isEmpty);
      final directory = Directory.systemTemp.createTempSync('native-meeting-widget-');
      final journal = TimewebMeetingCreateJournal(directory: () async => directory);
      Map<String, dynamic>? posted;
      var posts = 0, checks = 0;
      String? createdId;
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/runtime/meetings' && request.method == 'POST') {
          posts++;
          posted = jsonDecode(await request.finalize().bytesToString()) as Map<String, dynamic>;
          expect(posted!.keys.toSet(), {
            'operationId',
            'name',
            'description',
            'countryCode',
            'region',
            'datetime',
            'type',
          });
          expect(posted!['name'], '  Native creation  ');
          expect(posted!['description'], '');
          createdId =
              'tw-meeting-${sha256.convert(utf8.encode('clrs-native-meeting-v1\u0000${jsonEncode(['A', posted!['operationId']])}'))}';
          return peopleReply({'error': 'outcome_unknown'}, status: 503);
        }
        if (request.url.path.startsWith('/v1/runtime/operations/meeting.create.v1/')) {
          checks++;
          expect(request.method, 'GET');
          expect(request.url.path.split('/').last, posted!['operationId']);
          return peopleReply({
            'operation': 'meeting.create.v1',
            'operationId': posted!['operationId'],
            'requestHash': request.url.queryParameters['requestHash'],
            'state': 'committed',
            'replayed': true,
            'result': {
              'meetingId': createdId,
              'created': true,
              'meetingRevision': 0,
              'localDatetime': posted!['datetime'],
            },
            'entityRevision': 0,
          }, status: 201);
        }
        if (request.url.path == '/v1/runtime/meetings/$createdId') {
          expect(checks, 1);
          expect(
            directory.listSync(recursive: true).whereType<File>(),
            isEmpty,
            reason: 'Durable original intent must be acknowledged before navigation',
          );
          return peopleReply({
            'kind': 'canonical-current',
            'meeting': _meeting(createdId!, date: posted!['datetime'] as String),
            'mediaReady': false,
          });
        }
        fail('Unexpected native request');
      });
      final runtime = _runtime(wire, journal: journal);
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(_app(MeetingForm(nativeRuntime: runtime, meetingId: 'unsupported')));
        expect(find.text('Изменение встречи пока недоступно'), findsOneWidget);
        expect(wire.calls, isEmpty);
        await tester.pumpWidget(_app(MeetingForm(key: const ValueKey('create'), nativeRuntime: runtime)));
        await _until(tester, () => find.byKey(const ValueKey('Страна/null')).evaluate().isNotEmpty);
        await tester.enterText(find.byKey(const ValueKey('native-meeting-name')), '  Native creation  ');
        tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('Страна/null'))).onChanged!('RU');
        await tester.pump();
        tester.widget<DropdownButtonFormField<String>>(find.byKey(const ValueKey('Регион/null'))).onChanged!('Москва');
        // Direct dropdown callbacks bypass the real menu's focus change.
        FocusManager.instance.primaryFocus?.unfocus();
        tester.testTextInput.hide();
        await tester.pump(const Duration(milliseconds: 400));
        await _tap(tester, 'native-meeting-submit', 'native-meeting-form-scroll');
        await _until(
          tester,
          () =>
              posts == 1 &&
              find.text('Проверить исходную операцию').evaluate().isNotEmpty &&
              tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-submit'))).onPressed != null,
          reason: () =>
              'posts=$posts; notices=${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()}',
        );
        expect(posts, 1);
        expect(find.byType(TimewebMeetingsPageView), findsNothing);
        await _tap(tester, 'native-meeting-submit', 'native-meeting-form-scroll');
        await _until(tester, () => find.byType(TimewebMeetingsPageView).evaluate().isNotEmpty);
        await _until(tester, () => find.text('Native meeting').evaluate().isNotEmpty);
        expect(posts, 1);
        expect(checks, 1);
        expect(Firebase.apps, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await _stop(tester, runtime);
        directory.deleteSync(recursive: true);
      }
    },
  );
}
