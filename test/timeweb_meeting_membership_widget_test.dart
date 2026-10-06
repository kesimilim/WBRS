import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_chat_flow.dart';
import 'package:wbrs/service/timeweb_meeting_join_flow.dart';
import 'package:wbrs/service/timeweb_meeting_membership_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

const _leaveId = 'native-leave-meeting', _kickId = 'native-kick-meeting', _rejectId = 'native-rejected-leave';
Map<String, Object?> _meeting(String id, {int revision = 0}) => {
  'meetingId': id,
  'organizerUid': id == _kickId ? 'A' : 'C',
  'invitedUid': null,
  'kind': 'group',
  'title': id == _kickId ? 'Встреча организатора' : 'Встреча участника',
  'description': 'Текущее описание встречи',
  'countryCode': 'RU',
  'region': 'Москва',
  'startsAt': null,
  'localDatetime': '03.10.2026 19:15',
  'createdAt': peopleStamp,
  'updatedAt': peopleStamp,
  'revision': revision,
  'media': null,
  'mediaReady': false,
};
Map<String, Object?> _roster(String id) => {
  'kind': 'canonical-current',
  'meetingId': id,
  'ordering': 'uid_binary_asc',
  'items': [
    for (final uid in ['A', 'B', 'C'])
      {
        'uid': uid,
        'fullName': 'Участник $uid',
        'primaryGroup': null,
        'joinedAt': null,
        'membershipRevision': 1,
        'avatar': null,
        'mediaReady': false,
      },
  ],
  'nextCursor': null,
  'mediaReady': false,
};
Map<String, Object?> _messages([String id = _leaveId]) => {
  'kind': 'canonical-current',
  'meetingId': id,
  'chatRevision': 1,
  'ordering': 'sequence_desc',
  'items': [
    {
      'meetingId': id,
      'messageId': 'tw-meet-msg-${'b' * 64}',
      'sequence': 1,
      'senderUid': 'B',
      'text': id == _leaveId
          ? 'Private member text'
          : id == _rejectId
          ? 'Private rejected target text'
          : 'Private organizer text',
      'createdAt': peopleStamp,
    },
  ],
  'nextCursor': null,
  'mediaReady': false,
};
List<File> _originals(Directory directory) =>
    directory.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.json')).toList();
Map<String, Object?> _envelope(TimewebMutationRequest request, Map<String, Object?> result) => {
  'operation': request.operation,
  'operationId': request.operationId,
  'requestHash': request.requestHash,
  'state': 'committed',
  'replayed': true,
  'result': result,
  'entityRevision': 2,
};
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(ready(), isTrue);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pump();
  await tester.runAsync(() => tester.tap(target));
  await tester.pump(const Duration(milliseconds: 350));
}

Widget _page(TimewebAppRuntime runtime, String? id) => MaterialApp(
  key: ValueKey(id),
  locale: const Locale('ru'),
  supportedLocales: ClrsLocalizations.supportedLocales,
  localizationsDelegates: ClrsLocalizations.delegates,
  theme: LrsTheme.theme,
  home: TimewebMeetingsPageView(runtime: runtime, meetingId: id),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await TimewebMeetingCreateRequest.fromCatalog(
      name: 'synthetic',
      description: '',
      countryCode: 'RU',
      region: 'Москва',
      datetime: '03.10.2026 19:15',
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
  testWidgets('original leave restore/check ACK, organizer-bound kick, exact target lock and late A purge', (
    tester,
  ) async {
    expect(Firebase.apps, isEmpty);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    final directory = Directory.systemTemp.createTempSync('native-membership-widget-');
    final freshDetail = Completer<http.StreamedResponse>(), freshRoster = Completer<http.StreamedResponse>();
    TimewebMutationRequest? originalLeave, originalKick;
    var leavePosts = 0, leaveChecks = 0, kickPosts = 0, kickChecks = 0, messages = 0, kickRosters = 0;
    var afterLeaveRead = false, afterKickRoster = false;
    var lists = 0, rejectedPosts = 0, rejectedFreshReads = 0;
    final wire = PeopleWire((call) async {
      final path = call.url.path;
      if (path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      if (path == '/v1/runtime/meetings') {
        lists++;
        return peopleReply({
          'kind': 'canonical-current',
          'scope': 'group',
          'ordering': 'starts_at_asc_meeting_id_asc_null_first',
          'items': [_meeting(_leaveId, revision: lists)],
          'nextCursor': null,
          'mediaReady': false,
        });
      }
      if (path == '/v1/runtime/meetings/$_rejectId') {
        if (rejectedPosts == 1) {
          rejectedFreshReads++;
          expect(_originals(directory), isEmpty, reason: 'Declared ACK precedes target close and fresh public proof');
          return peopleReply({'error': 'not_found'}, status: 404);
        }
        return peopleReply({'kind': 'canonical-current', 'meeting': _meeting(_rejectId), 'mediaReady': false});
      }
      if (path == '/v1/runtime/meetings/$_leaveId') {
        if (leaveChecks == 1) {
          afterLeaveRead = true;
          expect(_originals(directory), isEmpty, reason: 'Disk ACK precedes adoption of fresh public metadata');
          return freshDetail.future;
        }
        return peopleReply({'kind': 'canonical-current', 'meeting': _meeting(_leaveId), 'mediaReady': false});
      }
      if (path == '/v1/runtime/meetings/$_kickId') {
        if (kickChecks == 1) expect(_originals(directory), isEmpty);
        return peopleReply({
          'kind': 'canonical-current',
          'meeting': _meeting(_kickId, revision: kickChecks),
          'mediaReady': false,
        });
      }
      if (path == '/v1/runtime/meetings/$_rejectId/participants') return peopleReply(_roster(_rejectId));
      if (path.endsWith('/participants')) {
        if (path.contains(_kickId)) {
          kickRosters++;
          if (kickChecks == 1) {
            afterKickRoster = true;
            expect(_originals(directory), isEmpty, reason: 'Original kick ACK precedes protected roster read');
            return freshRoster.future;
          }
          return peopleReply(_roster(_kickId));
        }
        return peopleReply(_roster(_leaveId));
      }
      if (path == '/v1/runtime/meetings/$_rejectId/messages') return peopleReply(_messages(_rejectId));
      if (path == '/v1/runtime/meetings/$_kickId/messages') {
        expect(call.method, 'GET');
        return peopleReply(_messages(_kickId));
      }
      if (path == '/v1/runtime/meetings/$_leaveId/messages') {
        messages++;
        expect(call.method, 'GET');
        expect(leaveChecks, 0, reason: 'No protected message GET before or after original leave lookup');
        return peopleReply(_messages());
      }
      if (path == '/v1/runtime/meetings/leave' || path == '/v1/runtime/meetings/kick') {
        final body = jsonDecode((call as http.Request).body) as Map<String, dynamic>;
        expect(_originals(directory), hasLength(1), reason: 'One disk original exists before POST');
        if (path.endsWith('/leave')) {
          if (body['meetingId'] == _rejectId) {
            rejectedPosts++;
            final original = TimewebMutationRequest.leaveMeeting(
              operationId: body['operationId'],
              meetingId: _rejectId,
            );
            return peopleReply({
              ..._envelope(original, {'error': 'meeting_unavailable'}),
              'replayed': false,
              'entityRevision': null,
            }, status: 409);
          }
          leavePosts++;
          expect(body.keys.toSet(), {'operationId', 'meetingId'});
          expect(body['meetingId'], _leaveId);
          originalLeave = TimewebMutationRequest.leaveMeeting(operationId: body['operationId'], meetingId: _leaveId);
        } else {
          kickPosts++;
          expect(body, {'operationId': body['operationId'], 'meetingId': _kickId, 'targetUid': 'B'});
          originalKick = TimewebMutationRequest.kickMeetingParticipant(
            operationId: body['operationId'],
            meetingId: _kickId,
            targetUid: 'B',
          );
        }
        throw StateError('Synthetic committed reply loss');
      }
      if (path.startsWith('/v1/runtime/operations/meeting.leave.v1/')) {
        leaveChecks++;
        expect(path.split('/').last, originalLeave!.operationId);
        expect(call.url.queryParameters, {'requestHash': originalLeave!.requestHash});
        expect(_originals(directory), hasLength(1));
        return peopleReply(
          _envelope(originalLeave!, {
            'meetingId': _leaveId,
            'left': true,
            'alreadyLeft': false,
            'membershipRevision': 2,
            'leftAt': peopleStamp,
          }),
        );
      }
      if (path.startsWith('/v1/runtime/operations/meeting.kick.v1/')) {
        kickChecks++;
        expect(path.split('/').last, originalKick!.operationId);
        expect(call.url.queryParameters, {'requestHash': originalKick!.requestHash});
        expect(_originals(directory), hasLength(1));
        return peopleReply(
          _envelope(originalKick!, {
            'meetingId': _kickId,
            'targetUid': 'B',
            'kicked': true,
            'alreadyKicked': false,
            'membershipRevision': 2,
            'kickedAt': peopleStamp,
            'leftAt': peopleStamp,
          }),
        );
      }
      fail('Unexpected native request: $path');
    });
    final runtime = (await tester.runAsync(
      () async => TimewebAppRuntime(
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
        meetingJoinJournal: TimewebMeetingJoinJournal(directory: () async => directory),
      ),
    ))!;
    try {
      await tester.runAsync(() => runtime.start(remember: true));
      final held = (await tester.runAsync(() => runtime.readMeeting(_leaveId)))!;
      await tester.pumpWidget(_page(runtime, null));
      await _until(
        tester,
        () => find.byKey(const ValueKey('native-meeting-native-leave-meeting')).evaluate().isNotEmpty,
      );
      await _tap(tester, 'native-meeting-native-leave-meeting');
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-discussion')).evaluate().isNotEmpty &&
            tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-discussion'))).onPressed != null,
      );
      await _tap(tester, 'native-meeting-participants');
      await _until(tester, () => find.text('Участник B').evaluate().isNotEmpty);
      expect(
        find.byKey(const ValueKey('native-meeting-kick-B')),
        findsNothing,
        reason: 'Non-organizer has no kick affordance',
      );
      await _tap(tester, 'native-meeting-discussion');
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-leave')).evaluate().isNotEmpty &&
            tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-leave'))).onPressed != null,
      );
      expect(find.text('Private member text'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('native-meeting-chat-composer')), 'Private unsent draft');
      await _tap(tester, 'native-meeting-leave');
      await _until(
        tester,
        () => leavePosts == 1 && find.text('Проверьте исходный выход из встречи.').evaluate().isNotEmpty,
      );
      expect(tester.widget<TextField>(find.byKey(const ValueKey('native-meeting-chat-composer'))).enabled, isFalse);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-chat-send'))).onPressed, isNull);
      expect(_originals(directory), hasLength(1));
      await _tap(tester, 'native-meeting-chat-back');
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-leave-check')).evaluate().isNotEmpty &&
            find.byKey(const ValueKey('native-meeting-chat-composer')).evaluate().isEmpty,
      );
      expect(messages, 1);
      expect(find.byKey(const ValueKey('native-meeting-chat-composer')), findsNothing);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-discussion'))).onPressed, isNull);
      await _tap(tester, 'native-meeting-leave-check');
      await _until(tester, () => afterLeaveRead);
      expect(leavePosts, 1);
      expect(leaveChecks, 1);
      expect(messages, 1);
      expect(() => held.title, throwsA(isA<TimewebMeetingNotFound>()));
      expect(find.text('Участник B'), findsNothing, reason: 'Cached roster is purged before fresh read');
      expect(find.byKey(const ValueKey('native-meeting-join')), findsNothing);
      expect(runtime.client.currentUid, 'A');
      freshDetail.complete(
        peopleReply({'kind': 'canonical-current', 'meeting': _meeting(_leaveId, revision: 1), 'mediaReady': false}),
      );
      await _until(
        tester,
        () =>
            find.text('Вы вышли из встречи.').evaluate().isNotEmpty &&
            find.byKey(const ValueKey('native-meeting-leave-check')).evaluate().isEmpty,
      );
      await tester.runAsync(() => tester.binding.handlePopRoute());
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-scope')).evaluate().isNotEmpty &&
            find.byKey(const ValueKey('native-meeting-native-leave-meeting')).evaluate().isEmpty,
      );
      expect(lists, 1, reason: 'Ancestor cache is purged; it does not silently retain the old page');
      expect(runtime.client.currentUid, 'A');
      await _tap(tester, 'native-meetings-refresh');
      await _until(
        tester,
        () => lists == 2 && find.byKey(const ValueKey('native-meeting-native-leave-meeting')).evaluate().isNotEmpty,
      );
      await tester.pumpWidget(_page(runtime, _rejectId));
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-discussion')).evaluate().isNotEmpty &&
            tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-discussion'))).onPressed != null,
      );
      await _tap(tester, 'native-meeting-discussion');
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-leave')).evaluate().isNotEmpty &&
            tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-leave'))).onPressed != null,
      );
      expect(find.text('Private rejected target text'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('native-meeting-chat-composer')), 'Rejected private draft');
      await _tap(tester, 'native-meeting-leave');
      await _until(
        tester,
        () =>
            rejectedPosts == 1 &&
            rejectedFreshReads == 1 &&
            find.byKey(const ValueKey('native-meeting-chat-composer')).evaluate().isEmpty,
      );
      expect(find.text('Private rejected target text'), findsNothing);
      expect(find.text('Участник B'), findsNothing);
      expect(find.byKey(const ValueKey('native-meeting-join')), findsNothing);
      expect(
        find.text('Вы вышли из встречи.'),
        findsNothing,
        reason: 'Declared refusal must never claim successful leave',
      );
      expect(_originals(directory), isEmpty);
      expect(runtime.client.currentUid, 'A');
      await tester.pumpWidget(_page(runtime, _kickId));
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-participants')).evaluate().isNotEmpty &&
            tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-participants'))).onPressed != null,
      );
      await _tap(tester, 'native-meeting-discussion');
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-leave')).evaluate().isNotEmpty &&
            tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-leave'))).onPressed != null,
      );
      expect(find.text('Private organizer text'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('native-meeting-chat-composer')), 'Organizer private draft');
      await _tap(tester, 'native-meeting-chat-participants');
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-kick-B')).evaluate().isNotEmpty &&
            find.byKey(const ValueKey('native-meeting-chat-composer')).evaluate().isEmpty,
      );
      expect(find.text('Private organizer text'), findsNothing);
      expect(
        find.byKey(const ValueKey('native-meeting-chat-send')),
        findsNothing,
        reason: 'Participants closes and purges the chat before roster controls appear',
      );
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-kick-A'))).onPressed, isNull);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-kick-C'))).onPressed, isNotNull);
      await _tap(tester, 'native-meeting-kick-B');
      await _until(
        tester,
        () => kickPosts == 1 && find.byKey(const ValueKey('native-meeting-kick-check')).evaluate().isNotEmpty,
      );
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-kick-C'))).onPressed, isNull);
      expect(find.text('Участник B'), findsOneWidget, reason: 'No optimistic removal before confirmation');
      await _tap(tester, 'native-meeting-kick-check');
      await _until(tester, () => afterKickRoster);
      expect(kickPosts, 1);
      expect(kickChecks, 1);
      expect(find.text('Private organizer text'), findsNothing);
      expect(find.byKey(const ValueKey('native-meeting-chat-composer')), findsNothing);
      expect(kickRosters, 3);
      expect(find.text('Участник B'), findsNothing);
      expect(find.text('Участник C'), findsNothing);
      expect(runtime.client.currentUid, 'A');
      await tester.runAsync(() => runtime.login(email: 'synthetic-b@example.invalid', password: 'synthetic'));
      await tester.pump();
      expect(runtime.client.currentUid, 'B');
      expect(find.text('Встреча организатора'), findsNothing);
      expect(find.byKey(const ValueKey('native-meeting-kick-check')), findsNothing);
      freshRoster.complete(peopleReply(_roster(_kickId)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Участник B'), findsNothing);
      expect(find.text('Участник C'), findsNothing);
      expect(_originals(directory), isEmpty);
      expect(leavePosts, 1);
      expect(kickPosts, 1);
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      if (!freshDetail.isCompleted) freshDetail.complete(peopleReply({}, status: 503));
      if (!freshRoster.isCompleted) freshRoster.complete(peopleReply({}, status: 503));
      await tester.pumpWidget(const SizedBox());
      var stopped = false;
      final stop = runtime.stop().then((value) {
        stopped = true;
        return value;
      });
      await _until(tester, () => stopped);
      await stop;
      await tester.binding.setSurfaceSize(null);
      directory.deleteSync(recursive: true);
    }
  });
}
