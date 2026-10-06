import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_join_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(ready(), isTrue);
}

Future<void> _tap(WidgetTester tester) async {
  final join = find.byKey(const ValueKey('native-meeting-join'));
  await Scrollable.ensureVisible(tester.element(join), alignment: .5);
  await tester.pump();
  await tester.runAsync(() => tester.tap(join));
  await tester.pump();
}

Map<String, Object?> _meeting() => {
  'meetingId': 'native-meeting',
  'organizerUid': 'A',
  'invitedUid': null,
  'kind': 'group',
  'title': 'Current meeting',
  'description': '',
  'countryCode': 'RU',
  'region': 'Москва',
  'startsAt': null,
  'localDatetime': '03.10.2026 19:15',
  'createdAt': peopleStamp,
  'updatedAt': peopleStamp,
  'revision': 0,
  'media': null,
  'mediaReady': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Keep the approved catalog Future outside a widget's temporary fake zone.
    await TimewebMeetingCreateRequest.fromCatalog(
      name: 'synthetic',
      description: '',
      countryCode: 'RU',
      region: 'Москва',
      datetime: '03.10.2026 19:15',
      type: 'групповая',
    );
  });
  testWidgets('single join POST unknown, original check ACK before roster, disabled duplicate and late A to B clear', (
    tester,
  ) async {
    expect(Firebase.apps, isEmpty);
    final directory = Directory.systemTemp.createTempSync('native-join-widget-');
    final post = Completer<http.StreamedResponse>(), roster = Completer<http.StreamedResponse>();
    var posts = 0, checks = 0, rosterReads = 0;
    Map<String, dynamic>? body;
    final wire = PeopleWire((request) async {
      if (request.url.path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      if (request.url.path == '/v1/runtime/meetings/native-meeting') {
        return peopleReply({'kind': 'canonical-current', 'meeting': _meeting(), 'mediaReady': false});
      }
      if (request.url.path == '/v1/runtime/meetings/join') {
        posts++;
        expect(request.method, 'POST');
        body = jsonDecode(await request.finalize().bytesToString()) as Map<String, dynamic>;
        expect(body!.keys.toSet(), {'operationId', 'meetingId'});
        expect(body!['meetingId'], 'native-meeting');
        expect(
          directory.listSync(recursive: true).whereType<File>(),
          hasLength(1),
          reason: 'Durable original intent exists before POST',
        );
        return post.future;
      }
      if (request.url.path.startsWith('/v1/runtime/operations/meeting.join.v1/')) {
        checks++;
        expect(request.method, 'GET');
        expect(request.url.path.split('/').last, body!['operationId']);
        expect(directory.listSync(recursive: true).whereType<File>(), hasLength(1));
        return peopleReply({
          'operation': 'meeting.join.v1',
          'operationId': body!['operationId'],
          'requestHash': request.url.queryParameters['requestHash'],
          'state': 'committed',
          'replayed': true,
          'result': {'meetingId': 'native-meeting', 'joined': true, 'alreadyMember': true, 'membershipRevision': 4},
          'entityRevision': 4,
        });
      }
      if (request.url.path == '/v1/runtime/meetings/native-meeting/participants') {
        rosterReads++;
        expect(checks, 1);
        expect(
          directory.listSync(recursive: true).whereType<File>(),
          isEmpty,
          reason: 'ACK must finish before any automatic roster refresh',
        );
        return roster.future;
      }
      fail('Unexpected native request');
    });
    final runtime = TimewebAppRuntime(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse('https://api.example.invalid'),
        enabled: true,
        currentReadsEnabled: true,
        runtimeWritesEnabled: true,
      ),
      secureStore: PeopleStore(),
      transport: wire,
      clock: () => peopleNow,
      deviceId: 'synthetic-device',
      expectedSourceSnapshot: 'a' * 64,
      clearLocal: () async {},
      currentOwnProfileEnabled: true,
      meetingJoinJournal: TimewebMeetingJoinJournal(directory: () async => directory),
    );
    try {
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebMeetingsPageView(runtime: runtime, meetingId: 'native-meeting'),
        ),
      );
      final join = find.byKey(const ValueKey('native-meeting-join'));
      await _until(tester, () => join.evaluate().isNotEmpty && tester.widget<TextButton>(join).onPressed != null);
      await _tap(tester);
      await _until(tester, () => posts == 1);
      expect(tester.widget<TextButton>(join).onPressed, isNull);
      await _tap(tester);
      expect(posts, 1);
      expect(rosterReads, 0);
      post.complete(peopleReply({'error': 'outcome_unknown'}, status: 503));
      await _until(
        tester,
        () =>
            find.text('Проверить присоединение').evaluate().isNotEmpty &&
            tester.widget<TextButton>(join).onPressed != null,
      );
      expect(posts, 1);
      expect(checks, 0);
      await _tap(tester);
      await _until(tester, () => rosterReads == 1);
      await tester.pump();
      expect(posts, 1);
      expect(checks, 1);
      expect(find.text('Вы уже участник'), findsOneWidget);
      expect(tester.widget<TextButton>(join).onPressed, isNull);
      var logged = false;
      final login = runtime.login(email: 'B@example.invalid', password: 'synthetic').then((value) {
        logged = true;
        return value;
      });
      await _until(tester, () => find.text('Вы уже участник').evaluate().isEmpty);
      roster.complete(
        peopleReply({
          'kind': 'canonical-current',
          'ordering': 'uid_binary_asc',
          'meetingId': 'native-meeting',
          'items': [
            {
              'uid': 'A',
              'fullName': 'Late A participant',
              'primaryGroup': null,
              'joinedAt': peopleStamp,
              'membershipRevision': 4,
              'avatar': null,
              'mediaReady': false,
            },
          ],
          'nextCursor': null,
          'mediaReady': false,
        }),
      );
      await _until(tester, () => logged);
      await login;
      expect(find.text('Late A participant'), findsNothing);
      expect(find.text('Current meeting'), findsNothing);
      expect(find.byKey(const ValueKey('native-meeting-join')), findsNothing);
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      if (!post.isCompleted) post.complete(peopleReply({'error': 'outcome_unknown'}, status: 503));
      if (!roster.isCompleted) roster.complete(peopleReply({'error': 'unavailable'}, status: 503));
      await tester.pumpWidget(const SizedBox());
      var stopped = false;
      final stopping = runtime.stop().then((value) {
        stopped = true;
        return value;
      });
      await _until(tester, () => stopped);
      expect(await stopping, isTrue);
      directory.deleteSync(recursive: true);
    }
  });
}
