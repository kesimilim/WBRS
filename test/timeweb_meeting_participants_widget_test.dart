import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meeting_chat_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_chat_flow.dart';
import 'package:wbrs/service/timeweb_meeting_membership_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

const _meetingId = 'native-participants-test';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 80 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(ready(), isTrue);
}

void main() {
  testWidgets('meeting participants search returns to the same protected chat', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    final directory = Directory.systemTemp.createTempSync('native-participants-widget-');
    var rosterReads = 0;
    final wire = PeopleWire((request) async {
      if (request.url.path == '/v1/runtime/meetings/$_meetingId') {
        return peopleReply({
          'kind': 'canonical-current',
          'meeting': {
            'meetingId': _meetingId,
            'organizerUid': 'A',
            'invitedUid': null,
            'kind': 'group',
            'title': 'Знакомство в парке',
            'description': 'Прогулка',
            'countryCode': 'RU',
            'region': 'Москва',
            'startsAt': null,
            'localDatetime': '03.10.2026 19:15',
            'createdAt': peopleStamp,
            'updatedAt': peopleStamp,
            'revision': 0,
            'media': null,
            'mediaReady': false,
          },
          'mediaReady': false,
        });
      }
      if (request.url.path == '/v1/runtime/meetings/$_meetingId/messages') {
        return peopleReply({
          'kind': 'canonical-current',
          'meetingId': _meetingId,
          'chatRevision': 1,
          'ordering': 'sequence_desc',
          'items': [
            {
              'meetingId': _meetingId,
              'messageId': 'tw-meet-msg-${'a' * 64}',
              'sequence': 1,
              'senderUid': 'B',
              'text': 'Привет',
              'createdAt': peopleStamp,
            },
          ],
          'nextCursor': null,
          'mediaReady': false,
        });
      }
      if (request.url.path == '/v1/runtime/meetings/$_meetingId/participants') {
        rosterReads++;
        return peopleReply({
          'kind': 'canonical-current',
          'meetingId': _meetingId,
          'ordering': 'uid_binary_asc',
          'items': [
            {
              'uid': 'B',
              'fullName': 'Мария',
              'primaryGroup': null,
              'joinedAt': null,
              'membershipRevision': 1,
              'avatar': null,
              'mediaReady': false,
            },
          ],
          'nextCursor': null,
          'mediaReady': false,
        });
      }
      if (request.url.path == '/v1/runtime/people/B/photos') {
        return peopleReply(photoPage('B', []));
      }
      throw StateError('Unexpected synthetic route: ${request.url.path}');
    });
    final runtime = (await tester.runAsync(() async => TimewebAppRuntime(
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
      meetingChatJournal: TimewebMeetingChatJournal(directory: () async => directory),
      meetingMembershipJournal: TimewebMeetingMembershipJournal(directory: () async => directory),
    )))!;
    try {
      await tester.runAsync(() => runtime.start(remember: true));
      final meeting = (await tester.runAsync(() => runtime.readMeeting(_meetingId)))!;
      final flow = (await tester.runAsync(() => runtime.openMeetingConversation(_meetingId)))!;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('ru'),
        supportedLocales: ClrsLocalizations.supportedLocales,
        localizationsDelegates: ClrsLocalizations.delegates,
        theme: LrsTheme.theme,
        home: TimewebMeetingChatPageView(
          runtime: runtime,
          meeting: meeting,
          flow: flow,
          onParticipants: () {},
        ),
      ));
      await _until(tester, () => find.text('Привет').evaluate().isNotEmpty);
      await _until(tester, () => tester.widget<TextButton>(
        find.byKey(const ValueKey('native-meeting-chat-participants-link')),
      ).onPressed != null);
      await tester.tap(find.byKey(const ValueKey('native-meeting-chat-participants-link')));
      await tester.pump();
      await _until(tester, () => find.byKey(const ValueKey('native-meeting-participants-search')).evaluate().isNotEmpty);
      await _until(tester, () => find.text('Мария').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 350));
      expect(rosterReads, 1);
      await tester.enterText(find.byKey(const ValueKey('native-meeting-participants-search')), 'Нет такого');
      await tester.pump();
      expect(find.text('Мария'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('native-meeting-participants-search')), 'Мар');
      await tester.pump();
      expect(find.text('Мария'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('native-meeting-participants-return-chat')));
      await tester.tap(find.byKey(const ValueKey('native-meeting-participants-return-chat')));
      await _until(tester, () => find.byKey(const ValueKey('native-meeting-chat-composer')).evaluate().isNotEmpty);
      expect(find.text('Привет'), findsOneWidget);
      expect(flow.targetAvailable, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      var stopped = false;
      final stopping = runtime.stop().then((_) => stopped = true);
      await _until(tester, () => stopped);
      await stopping;
      directory.deleteSync(recursive: true);
      await tester.binding.setSurfaceSize(null);
    }
  });
}
