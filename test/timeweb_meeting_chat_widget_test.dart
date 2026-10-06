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
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meeting_chat_page.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/on_device_content_translation.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_chat_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

const _id = 'native-meeting',
    _messageId = 'tw-meet-msg-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _original = 'Shall we meet in the park?', _local = '03.10.2026 19:15';
Map<String, Object?> _meeting() => {
  'meetingId': _id,
  'organizerUid': 'A',
  'invitedUid': null,
  'kind': 'group',
  'title': 'Знакомство в парке',
  'description': 'Давайте встретимся и познакомимся',
  'countryCode': 'RU',
  'region': 'Москва',
  'startsAt': null,
  'localDatetime': _local,
  'createdAt': peopleStamp,
  'updatedAt': peopleStamp,
  'revision': 0,
  'media': null,
  'mediaReady': false,
};
Map<String, Object> _message() => {
  'meetingId': _id,
  'messageId': _messageId,
  'sequence': 1,
  'senderUid': 'B',
  'text': _original,
  'createdAt': peopleStamp,
};
Map<String, Object?> _messages(List<Object> items, int revision) => {
  'kind': 'canonical-current',
  'meetingId': _id,
  'chatRevision': revision,
  'ordering': 'sequence_desc',
  'items': items,
  'nextCursor': null,
  'mediaReady': false,
};

class _DeviceSpy implements OnDeviceContentTranslator {
  final output = Completer<String>();
  final originals = <String>[];
  @override
  bool get available => true;
  @override
  bool supportsLanguage(String code) => true;
  @override
  Future<String> identifyLanguage(String text) async => 'en';
  @override
  Future<void> ensureModel(String code) async {}
  @override
  Future<String> translateText(String text, String source, String target) {
    expect(source, 'en');
    expect(target, 'ru');
    originals.add(text);
    return output.future;
  }
}

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
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
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
  testWidgets('member-only chat manual native translation, original UNKNOWN lookup ACK and target/epoch cleanup', (
    tester,
  ) async {
    expect(Firebase.apps, isEmpty);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    final directory = Directory.systemTemp.createTempSync('native-meeting-chat-widget-');
    final post = Completer<http.StreamedResponse>(), freshRead = Completer<http.StreamedResponse>();
    final device = _DeviceSpy();
    var posts = 0, checks = 0, reads = 0, tokenCalls = 0;
    Map<String, dynamic>? body;
    String? Function()? translationOwner;
    final wire = PeopleWire((request) async {
      if (request.url.path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      if (request.url.path == '/v1/runtime/meetings/$_id') {
        return peopleReply({'kind': 'canonical-current', 'meeting': _meeting(), 'mediaReady': false});
      }
      if (request.url.path == '/v1/runtime/meetings/$_id/participants') {
        return peopleReply({
          'kind': 'canonical-current',
          'meetingId': _id,
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
      if (request.url.path == '/v1/runtime/meetings/$_id/messages') {
        if (request.method == 'GET') {
          reads++;
          if (reads == 1) return peopleReply(_messages([_message()], 8));
          expect(checks, 1);
          expect(
            directory.listSync(recursive: true).whereType<File>(),
            isEmpty,
            reason: 'Durable original ACK precedes protected readback and rendering',
          );
          return freshRead.future;
        }
        posts++;
        expect(request.method, 'POST');
        body = jsonDecode(await request.finalize().bytesToString()) as Map<String, dynamic>;
        expect(body!.keys.toSet(), {'operationId', 'text'});
        expect(body!['text'], 'Original draft');
        expect(directory.listSync(recursive: true).whereType<File>(), hasLength(1));
        return post.future;
      }
      if (request.url.path.startsWith('/v1/runtime/operations/meeting.send-text.v1/')) {
        checks++;
        expect(request.method, 'GET');
        expect(request.url.path.split('/').last, body!['operationId']);
        expect(directory.listSync(recursive: true).whereType<File>(), hasLength(1));
        final messageId =
            'tw-meet-msg-${sha256.convert(utf8.encode('clrs-native-meeting-message-v1\u0000${jsonEncode([_id, 'A', body!['operationId']])}'))}';
        return peopleReply({
          'operation': 'meeting.send-text.v1',
          'operationId': body!['operationId'],
          'requestHash': request.url.queryParameters['requestHash'],
          'state': 'committed',
          'replayed': true,
          'result': {
            'meetingId': _id,
            'messageId': messageId,
            'sequence': 2,
            'senderUid': 'A',
            'text': body!['text'],
            'createdAt': peopleStamp,
            'chatRevision': 10,
          },
          'entityRevision': 10,
        }, status: 201);
      }
      fail('Unexpected native request');
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
      ),
    ))!;
    try {
      await tester.runAsync(() => runtime.start(remember: true));
      final meeting = (await tester.runAsync(() => runtime.readMeeting(_id)))!;
      final participants = (await tester.runAsync(() => runtime.readMeetingParticipants(_id)))!;
      final flow = (await tester.runAsync(() => runtime.openMeetingConversation(_id)))!;
      final roster = participants.items;
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: ClrsLocalizations.supportedLocales,
          localizationsDelegates: ClrsLocalizations.delegates,
          theme: LrsTheme.theme,
          home: RepaintBoundary(
            key: boundary,
            child: TimewebMeetingChatPageView(
              runtime: runtime,
              meeting: meeting,
              flow: flow,
              participants: roster,
              onParticipants: () {},
              translationFactory: (owner) {
                translationOwner = owner;
                return ContentTranslationService(
                  endpoint: null,
                  currentUserId: owner,
                  idToken: () async {
                    tokenCalls++;
                    return null;
                  },
                  enableOnDevice: true,
                  enableRemoteFallback: false,
                  onDeviceTranslator: device,
                  maxCacheEntries: 30,
                );
              },
            ),
          ),
        ),
      );
      await _until(tester, () => find.text('Знакомство в парке').evaluate().isNotEmpty);
      await tester.runAsync(
        () => precacheImage(const AssetImage('assets/final_design/family_back.png'), boundary.currentContext!),
      );
      await tester.pump();
      expect(find.text(_local), findsOneWidget);
      expect(find.text('Мария'), findsOneWidget);
      expect(find.text(_original), findsOneWidget);
      expect(device.originals, isEmpty);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-chat-attachment'))).onPressed, isNull);
      expect(
        tester.widget<IconButton>(find.byKey(const ValueKey('native-meeting-chat-notifications'))).onPressed,
        isNull,
      );
      expect(find.byKey(const ValueKey('native-meeting-chat-about')), findsOneWidget);
      expect(translationOwner!(), 'A/${runtime.session.state.epoch}');
      // One artifact inside this same focused case; no golden or production device claim.
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(
          pixelRatio: 1,
        );
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('../native-meeting-chat-360px.png').writeAsBytes(png!.buffer.asUint8List(), flush: true);
        } finally {
          image.dispose();
        }
      });
      await _tap(tester, 'native-meeting-translate-$_messageId');
      await _until(tester, () => device.originals.isNotEmpty);
      expect(device.originals, [_original]);
      expect(tokenCalls, 0);
      // Flutter counts graphemes; the wire contract bounds code points independently.
      final tooManyCodePoints = List.filled(1500, 'a\u0301\u0302').join();
      expect(tooManyCodePoints.runes.length, 4500);
      await tester.enterText(find.byKey(const ValueKey('native-meeting-chat-composer')), tooManyCodePoints);
      await _tap(tester, 'native-meeting-chat-send');
      await _until(
        tester,
        () => find.text('Не удалось отправить сообщение. Исходный текст сохранён.').evaluate().isNotEmpty,
      );
      expect(posts, 0);
      expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
      expect(find.text(_original), findsOneWidget);
      expect(flow.targetAvailable, isTrue);
      final rejectedComposer = tester.widget<TextField>(find.byKey(const ValueKey('native-meeting-chat-composer')));
      expect(rejectedComposer.enabled, isTrue);
      expect(rejectedComposer.controller!.text, tooManyCodePoints);
      await tester.enterText(find.byKey(const ValueKey('native-meeting-chat-composer')), 'Original draft');
      await _tap(tester, 'native-meeting-chat-send');
      await _until(tester, () => posts == 1);
      await _tap(tester, 'native-meeting-chat-send');
      expect(posts, 1);
      post.complete(peopleReply({'error': 'outcome_unknown'}, status: 503));
      final send = find.byKey(const ValueKey('native-meeting-chat-send'));
      await _until(tester, () => tester.widget<IconButton>(send).onPressed != null);
      await tester.pump();
      expect(tester.widget<IconButton>(send).tooltip, 'Проверить');
      final composer = tester.widget<TextField>(find.byKey(const ValueKey('native-meeting-chat-composer')));
      expect(composer.enabled, isFalse);
      expect(composer.controller!.text, 'Original draft');
      await _tap(tester, 'native-meeting-chat-send');
      await _until(tester, () => reads == 2);
      expect(posts, 1);
      expect(checks, 1);
      freshRead.complete(peopleReply({'error': 'meeting_unavailable'}, status: 404));
      await _until(tester, () => find.text('Обсуждение недоступно').evaluate().isNotEmpty);
      expect(find.text(_original), findsNothing);
      expect(find.text('Мария'), findsNothing);
      expect(find.text(_local), findsNothing);
      expect(find.text('Original draft'), findsNothing);
      expect(translationOwner!(), isNull);
      expect(runtime.session.state.authenticated, isTrue);
      expect(runtime.session.state.identity!.uid, 'A', reason: 'Target refusal must not log out a healthy actor');
      await tester.runAsync(
        () => runtime.session.login(email: 'b@example.invalid', password: 'synthetic', deviceId: 'synthetic-device'),
      );
      device.output.complete('Поздний перевод A');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      expect(find.text('Поздний перевод A'), findsNothing);
      expect(posts, 1);
      // The captured A props may reach initState only after an actor change.
      Future<void> staleFirstBuild(String key) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebMeetingChatPageView(
              key: ValueKey(key),
              runtime: runtime,
              meeting: meeting,
              flow: flow,
              participants: roster,
              onParticipants: () {},
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Обсуждение недоступно'), findsOneWidget);
        expect(find.text(_original), findsNothing);
        expect(find.text('Мария'), findsNothing);
        expect(find.text(_local), findsNothing);
        expect(tester.takeException(), isNull);
      }

      await staleFirstBuild('stale-A-first-build-under-B');
      await tester.runAsync(() => runtime.stop());
      await staleFirstBuild('stale-A-first-build-anonymous');

      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      if (!device.output.isCompleted) device.output.complete('late');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => runtime.stop());
      directory.deleteSync(recursive: true);
      await tester.binding.setSurfaceSize(null);
    }
  });
}
