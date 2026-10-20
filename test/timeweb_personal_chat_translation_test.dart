import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/on_device_content_translation.dart';
import 'package:wbrs/service/timeweb_chat_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'timeweb_personal_chat_test.dart' show personalRuntime;

class _Translator implements OnDeviceContentTranslator {
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
  Future<String> translateText(String text, String source, String target) async {
    expect(source, 'en');
    expect(target, 'ru');
    originals.add(text);
    return 'Давай встретимся в парке завтра.';
  }
}

void main() {
  testWidgets('native personal message translates manually and retains original',
      (tester) async {
    const original = 'Let us meet in the park tomorrow.';
    final root = Directory.systemTemp.createTempSync('personal-translation-');
    final wire = PeopleWire((request) async {
      if (request.url.path.endsWith('/messages')) {
        return peopleReply({
          'kind': 'canonical-current',
          'chatId': 'chat',
          'chatRevision': 1,
          'ordering': 'sequence_desc',
          'items': [
            {
              'chatId': 'chat',
              'messageId': 'message',
              'sequence': 1,
              'senderUid': 'A',
              'text': original,
              'quote': null,
              'createdAt': peopleStamp,
            }
          ],
          'nextBeforeSequence': null,
        });
      }
      return peopleReply({'error': 'unavailable'}, status: 503);
    });
    final runtime = personalRuntime(wire, root);
    final device = _Translator();
    late ContentTranslationService service;
    try {
      await tester.runAsync(() => runtime.start(remember: true));
      final flow = (await tester.runAsync(() => TimewebChatFlow.openExisting(
            client: runtime.client,
            session: runtime.session,
            lease: runtime.session.captureLease(),
            journal: TimewebChatJournal(directory: () async => root),
            chatId: 'chat',
          )))!;
      await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        home: TimewebChatPage(
          flow: flow,
          translationFactory: (owner) => service = ContentTranslationService(
            endpoint: null,
            currentUserId: owner,
            idToken: () async => null,
            enableOnDevice: true,
            onDeviceTranslator: device,
          ),
        ),
      ));
      await tester.pump();
      expect(find.text(original), findsOneWidget);
      expect(device.originals, isEmpty);
      await tester.tap(find.text('Перевести с Google'));
      await tester.pumpAndSettle();
      expect(find.text('Давай встретимся в парке завтра.'), findsOneWidget);
      expect(device.originals, [original]);
      expect(flow.messages.single.text, original);
      expect(service.sessionId, 'A');
      await tester.tap(find.text('Показать оригинал'));
      await tester.pump();
      expect(find.text(original), findsOneWidget);
      // Rendering and translation must never send a translated message.
      expect(wire.calls.where((r) =>
          r.method == 'POST' && r.url.path.endsWith('/messages')), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      var stopped = false;
      final stop = runtime.stop().then((_) => stopped = true);
      for (var i = 0; i < 150 && !stopped; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      expect(stopped, isTrue);
      await stop;
      // The deliberately unavailable own-read request has a bounded observer.
      await tester.pump(const Duration(seconds: 13));
      root.deleteSync(recursive: true);
    }
  });
}
