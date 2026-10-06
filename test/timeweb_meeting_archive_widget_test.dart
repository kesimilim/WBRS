import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meeting_archive_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_join_flow.dart';
import 'package:wbrs/service/timeweb_meeting_membership_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

const _id = 'native-saved-meeting';
Map<String, Object?> _meeting() => {
  'meetingId': _id,
  'organizerUid': 'C',
  'invitedUid': null,
  'kind': 'group',
  'title': 'Встреча с сохранённой историей',
  'description': '',
  'countryCode': 'RU',
  'region': 'Москва',
  'startsAt': null,
  'localDatetime': '03.10.2026 19:15',
  'createdAt': peopleStamp,
  'updatedAt': peopleStamp,
  'revision': 1,
  'media': null,
  'mediaReady': false,
};
Map<String, Object?> _archive(TimewebMutationRequest original, int top, {String? cursor}) => {
  'kind': 'canonical-current',
  'meetingId': _id,
  'archiveWindow': {
    'throughSequence': 330,
    'capturedAt': peopleStamp,
    'operationId': original.operationId,
    'membershipRevision': 2,
  },
  'ordering': 'sequence_desc',
  'items': [
    for (var sequence = top; sequence > top - 30; sequence--)
      {
        'meetingId': _id,
        'messageId': 'tw-meet-msg-${sequence.toRadixString(16).padLeft(64, '0')}',
        'sequence': sequence,
        'senderUid': sequence.isEven ? 'A' : 'synthetic-sender',
        'text': 'Saved archive $sequence',
        'createdAt': peopleStamp,
      },
  ],
  'nextCursor': cursor,
  'mediaReady': false,
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

Widget _home(TimewebAppRuntime runtime, String owner) => MaterialApp(
  key: ValueKey(owner),
  locale: const Locale('ru'),
  supportedLocales: ClrsLocalizations.supportedLocales,
  localizationsDelegates: ClrsLocalizations.delegates,
  theme: LrsTheme.theme,
  home: TimewebMeetingsPageView(runtime: runtime, meetingId: _id),
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
  testWidgets('owner archive navigation waits original ACK, explicit rolling Older, late A purge and honest B404', (
    tester,
  ) async {
    expect(Firebase.apps, isEmpty);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    final directory = Directory.systemTemp.createTempSync('native-archive-widget-');
    final late = Completer<http.StreamedResponse>();
    TimewebMutationRequest? original;
    var leavePosts = 0, checks = 0, archives = 0, bArchives = 0;
    var lateRequested = false;
    final wire = PeopleWire((call) async {
      final path = call.url.path;
      if (path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      if (path == '/v1/runtime/meetings/$_id') {
        return peopleReply({'kind': 'canonical-current', 'meeting': _meeting(), 'mediaReady': false});
      }
      if (path == '/v1/runtime/meetings/leave') {
        leavePosts++;
        final body = jsonDecode((call as http.Request).body);
        original = TimewebMutationRequest.leaveMeeting(operationId: body['operationId'], meetingId: _id);
        throw StateError('Synthetic original reply loss');
      }
      if (path.startsWith('/v1/runtime/operations/meeting.leave.v1/')) {
        checks++;
        expect(path.split('/').last, original!.operationId);
        expect(call.url.queryParameters, {'requestHash': original!.requestHash});
        return peopleReply({
          'operation': original!.operation,
          'operationId': original!.operationId,
          'requestHash': original!.requestHash,
          'state': 'committed',
          'replayed': true,
          'result': {
            'meetingId': _id,
            'left': true,
            'alreadyLeft': false,
            'membershipRevision': 2,
            'leftAt': peopleStamp,
          },
          'entityRevision': 2,
        });
      }
      if (path == '/v1/runtime/meetings/$_id/archived-messages') {
        expect(call.method, 'GET');
        expect(call.url.queryParameters['limit'], '30');
        expect(call.url.queryParameters.keys, everyElement(isIn(['limit', 'cursor'])));
        expect(
          directory.listSync(recursive: true).whereType<File>(),
          isEmpty,
          reason: 'Original leave ACK must precede archive entry',
        );
        final token = call.headers['authorization'] ?? call.headers['Authorization'];
        if (token!.contains('na1.B.')) {
          bArchives++;
          return peopleReply({'error': 'archive_unavailable'}, status: 404);
        }
        expect(token, contains('na1.A.'));
        archives++;
        if (archives <= 11) {
          final top = 330 - (archives - 1) * 30;
          if (archives == 1) {
            expect(call.url.queryParameters.containsKey('cursor'), isFalse);
          } else {
            expect(call.url.queryParameters['cursor'], 'page-${archives - 1}');
          }
          return peopleReply(_archive(original!, top, cursor: archives < 11 ? 'page-$archives' : null));
        }
        if (archives == 12) {
          expect(call.url.queryParameters.containsKey('cursor'), isFalse, reason: 'Reopen starts a fresh owner window');
          return peopleReply(_archive(original!, 330, cursor: 'late-page'));
        }
        expect(archives, 13);
        expect(call.url.queryParameters['cursor'], 'late-page');
        lateRequested = true;
        return late.future;
      }
      fail('Archive UI must not request member chat, roster or perform writes: $path');
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
        meetingMembershipJournal: TimewebMeetingMembershipJournal(directory: () async => directory),
        meetingJoinJournal: TimewebMeetingJoinJournal(directory: () async => directory),
      ),
    ))!;
    try {
      await tester.runAsync(() => runtime.start(remember: true));
      final leave = (await tester.runAsync(() => runtime.openMeetingLeave(_id)))!;
      await tester.runAsync(() => leave.submit());
      leave.close();
      await tester.pumpWidget(_home(runtime, 'A'));
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-leave-check')).evaluate().isNotEmpty &&
            find.byKey(const ValueKey('native-meeting-archive')).evaluate().isNotEmpty,
      );
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-archive'))).onPressed, isNull);
      expect(archives, 0, reason: 'Archive is never a substitute for unresolved original Check');
      await _tap(tester, 'native-meeting-leave-check');
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-archive')).evaluate().isNotEmpty &&
            tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-archive'))).onPressed != null,
      );
      expect(leavePosts, 1);
      expect(checks, 1);
      await _tap(tester, 'native-meeting-archive');
      await _until(tester, () => find.byType(TimewebMeetingArchivePageView).evaluate().isNotEmpty);
      final flow = tester.widget<TimewebMeetingArchivePageView>(find.byType(TimewebMeetingArchivePageView)).flow;
      expect(flow.ownerUid, 'A');
      expect(flow.window.operationId, original!.operationId);
      expect(flow.messages.first.sequence, 330);
      expect(flow.messages.last.sequence, 301);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(CircleAvatar), findsNothing);
      expect(find.text('synthetic-sender'), findsNothing);
      for (var page = 2; page <= 11; page++) {
        await _tap(tester, 'native-archive-older');
        await _until(tester, () => archives == page && flow.messages.last.sequence == 331 - page * 30);
        expect(flow.messages.length, lessThanOrEqualTo(300));
      }
      expect(archives, 11);
      expect(flow.messages, hasLength(300));
      expect(flow.messages.first.sequence, 300);
      expect(flow.messages.last.sequence, 1);
      expect(flow.hasOlder, isFalse);
      expect(find.byKey(const ValueKey('native-archive-older')), findsNothing);
      await _tap(tester, 'native-archive-back');
      await _until(
        tester,
        () =>
            find.byType(TimewebMeetingArchivePageView).evaluate().isEmpty &&
            find.byKey(const ValueKey('native-meeting-archive')).evaluate().isNotEmpty &&
            tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-archive'))).onPressed != null,
      );
      expect(flow.targetAvailable, isFalse);
      expect(archives, 11);
      await _tap(tester, 'native-meeting-archive');
      await _until(tester, () => find.byType(TimewebMeetingArchivePageView).evaluate().isNotEmpty && archives == 12);
      final reopened = tester.widget<TimewebMeetingArchivePageView>(find.byType(TimewebMeetingArchivePageView)).flow;
      final held = reopened.messages.first;
      await _tap(tester, 'native-archive-older');
      await _until(tester, () => lateRequested);
      await tester.runAsync(() => runtime.login(email: 'synthetic-b@example.invalid', password: 'synthetic'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(runtime.client.currentUid, 'B');
      await _until(tester, () => find.byType(TimewebMeetingArchivePageView).evaluate().isEmpty);
      expect(find.byType(TimewebMeetingArchivePageView), findsNothing);
      expect(find.textContaining('Saved archive'), findsNothing);
      expect(() => held.text, throwsA(anyOf(isA<TimewebAuthException>(), isA<StateError>())));
      late.complete(peopleReply(_archive(original!, 300)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('Saved archive'), findsNothing);
      await tester.pumpWidget(_home(runtime, 'B'));
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('native-meeting-archive')).evaluate().isNotEmpty &&
            tester.widget<TextButton>(find.byKey(const ValueKey('native-meeting-archive'))).onPressed != null,
      );
      await _tap(tester, 'native-meeting-archive');
      await _until(tester, () => find.text('Сохранённая история пока недоступна.').evaluate().isNotEmpty);
      expect(bArchives, 1);
      expect(runtime.client.currentUid, 'B');
      expect(find.byType(TimewebMeetingArchivePageView), findsNothing);
      expect(find.text('Вы вышли из встречи.'), findsNothing);
      expect(find.textContaining('Saved archive'), findsNothing);
      expect(
        wire.calls.where((call) => call.url.path.endsWith('/messages') || call.url.path.endsWith('/participants')),
        isEmpty,
      );
      expect(wire.calls.where((call) => call.method == 'POST' && !call.url.path.contains('/auth/')), hasLength(1));
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      if (!late.isCompleted) late.complete(peopleReply({}, status: 503));
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
