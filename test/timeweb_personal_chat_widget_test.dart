import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/timeweb_person_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'timeweb_personal_chat_test.dart'
    show
        personalRuntime,
        personalEnvelope,
        personalResult,
        personalRequest,
        importedChatId,
        personalFiles;

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 120 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  await tester.pumpWidget(const SizedBox());
  var finished = false;
  final stop = runtime.stop().then((value) {
    finished = true;
    return value;
  });
  await _until(tester, () => finished);
  expect(await stop, isTrue);
}

Map<String, dynamic> _messages(List<Object?> items) => {
  'kind': 'canonical-current',
  'chatId': importedChatId,
  'chatRevision': 4,
  'ordering': 'sequence_desc',
  'items': items,
  'nextBeforeSequence': null,
};
Map<String, dynamic> _events() => {
  'kind': 'canonical-current',
  'ordering': 'event_id_asc',
  'items': [],
  'nextAfterEventId': null,
};

void main() {
  testWidgets(
    '360px actual native gate → directory → public profile → imported chat → send; 2x keyboard',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('personal-route-'),
      );
      var sent = false;
      final message = {
        'chatId': importedChatId,
        'messageId': 'new-message',
        'sequence': 1,
        'senderUid': 'A',
        'text': 'Native original text',
        'quote': null,
        'createdAt': peopleStamp,
      };
      final wire = PeopleWire((call) async {
        expect(call.headers['Authorization'], 'Bearer na1.A.first');
        final path = call.url.path;
        if (path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn('A'));
        }
        if (path == '/v1/runtime/people') {
          return peopleReply(
            directoryReply([publicPerson('B', name: 'Visible B')]),
          );
        }
        if (path == '/v1/runtime/people/B') {
          return peopleReply(
            personReply(publicPerson('B', name: 'Visible B', details: true)),
          );
        }
        if (path == '/v1/runtime/personal-chats') {
          final data = jsonDecode((call as http.Request).body);
          final request = personalRequest(data['operationId']);
          expect(data.keys, unorderedEquals(['operationId', 'targetUid']));
          expect(data['targetUid'], 'B');
          expect(personalFiles(root!), hasLength(1));
          return peopleReply(personalEnvelope(request, personalResult()));
        }
        if (path == '/v1/runtime/events') return peopleReply(_events());
        if (path == '/v1/runtime/chats/$importedChatId/messages') {
          if (call.method == 'GET') {
            return peopleReply(_messages(sent ? [message] : []));
          }
          final data = jsonDecode((call as http.Request).body);
          final request = TimewebMutationRequest.sendMessage(
            operationId: data['operationId'],
            chatId: importedChatId,
            text: data['text'],
          );
          expect(data['text'], 'Native original text');
          sent = true;
          return peopleReply(
            personalEnvelope(request, {
              ...message,
              'chatRevision': 4,
              'eventIds': [1, 2],
            }),
            status: 201,
          );
        }
        if (path == '/v1/runtime/chats/$importedChatId/read') {
          final data = jsonDecode((call as http.Request).body);
          final request = TimewebMutationRequest.markRead(
            operationId: data['operationId'],
            chatId: importedChatId,
            throughSequence: data['throughSequence'],
          );
          return peopleReply(
            personalEnvelope(request, {
              'chatId': importedChatId,
              'readThroughSequence': 1,
              'changed': false,
              'chatRevision': 4,
              'eventIds': [],
            }),
          );
        }
        fail('Unexpected native path $path');
      });
      final runtime = personalRuntime(wire, root!);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      var scale = 1.0;
      Widget app() => MaterialApp(
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
              .byKey(const ValueKey('timeweb-person-card-B'))
              .evaluate()
              .isNotEmpty,
        );
        await _tap(tester, find.byKey(const ValueKey('timeweb-person-card-B')));
        final button = find.byKey(const ValueKey('timeweb-person-open-chat'));
        await _until(
          tester,
          () =>
              button.evaluate().isNotEmpty &&
              tester.widget<ElevatedButton>(button).onPressed != null,
        );
        await _tap(tester, button);
        await _until(
          tester,
          () => find.byType(TimewebChatPage).evaluate().isNotEmpty,
        );
        expect(
          tester
              .widget<TimewebChatPage>(find.byType(TimewebChatPage))
              .flow
              .chatId,
          importedChatId,
        );
        expect(find.text('Сообщений пока нет'), findsOneWidget);
        scale = 2;
        await tester.pumpWidget(app());
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('timeweb-chat-composer')),
          'Native original text',
        );
        await tester.tap(find.byKey(const ValueKey('timeweb-chat-send')));
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-message-new-message'))
              .evaluate()
              .isNotEmpty,
        );
        expect(
          wire.calls.where(
            (call) => call.url.path == '/v1/runtime/personal-chats',
          ),
          hasLength(1),
        );
        expect(Firebase.apps, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        tester.view.resetViewInsets();
        await _stop(tester, runtime);
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'public profile unknown restart shows check → fresh original lookup → real chat; no new POST',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('personal-recover-'),
      );
      TimewebMutationRequest? original;
      final wire = PeopleWire((call) async {
        if (call.url.path == '/v1/runtime/people/B') {
          return peopleReply(personReply(publicPerson('B', details: true)));
        }
        if (call.url.path == '/v1/runtime/personal-chats') {
          original = personalRequest(
            jsonDecode((call as http.Request).body)['operationId'],
          );
          return peopleReply({'error': 'outcome_unknown'}, status: 503);
        }
        if (call.url.path.contains('/operations/')) {
          expect(call.method, 'GET');
          expect(call.url.path.endsWith(original!.operationId), isTrue);
          expect(call.url.queryParameters, {
            'requestHash': original!.requestHash,
          });
          return peopleReply(
            personalEnvelope(original!, personalResult(), replayed: true),
          );
        }
        if (call.url.path == '/v1/runtime/events') {
          return peopleReply(_events());
        }
        expect(call.url.path, '/v1/runtime/chats/$importedChatId/messages');
        return peopleReply(_messages([]));
      });
      final first = personalRuntime(wire, root!);
      Widget app(TimewebAppRuntime runtime) => MaterialApp(
        theme: LrsTheme.theme,
        home: TimewebPersonPage(runtime: runtime, uid: 'B'),
      );
      final button = find.byKey(const ValueKey('timeweb-person-open-chat'));
      try {
        await tester.runAsync(() => first.start(remember: true));
        await tester.pumpWidget(app(first));
        await _until(
          tester,
          () =>
              button.evaluate().isNotEmpty &&
              tester.widget<ElevatedButton>(button).onPressed != null,
        );
        await _tap(tester, button);
        await _until(
          tester,
          () =>
              find.text('Проверить результат').evaluate().isNotEmpty &&
              tester.widget<ElevatedButton>(button).onPressed != null,
        );
        expect(
          find.text(
            'Результат открытия чата пока неизвестен. Проверьте результат.',
          ),
          findsOneWidget,
        );
        await _stop(tester, first);
        final next = personalRuntime(wire, root);
        try {
          await tester.runAsync(() => next.start(remember: true));
          await tester.pumpWidget(app(next));
          await _until(
            tester,
            () =>
                find.text('Проверить результат').evaluate().isNotEmpty &&
                tester.widget<ElevatedButton>(button).onPressed != null,
          );
          await _tap(tester, button);
          await _until(
            tester,
            () => find.byType(TimewebChatPage).evaluate().isNotEmpty,
          );
          expect(
            wire.calls.where((call) => call.method == 'POST'),
            hasLength(1),
          );
          expect(personalFiles(root), isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await _stop(tester, next);
        }
      } finally {
        await _stop(tester, first);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'same profile repeat open freshly guards original receipt: green → 503 → green → hidden; one POST',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('personal-repeat-'),
      );
      var mode = 'green', lookups = 0, messages = 0;
      TimewebMutationRequest? original;
      final wire = PeopleWire((call) async {
        if (call.url.path == '/v1/runtime/people/B') {
          return peopleReply(
            personReply(publicPerson('B', name: 'Visible B', details: true)),
          );
        }
        if (call.url.path == '/v1/runtime/personal-chats') {
          original = personalRequest(
            jsonDecode((call as http.Request).body)['operationId'],
          );
          return peopleReply(personalEnvelope(original!, personalResult()));
        }
        if (call.url.path.contains('/operations/')) {
          lookups++;
          expect(call.method, 'GET');
          expect(
            call.url.path,
            '/v1/runtime/operations/chat.open-personal.v1/${original!.operationId}',
          );
          expect(call.url.queryParameters, {
            'requestHash': original!.requestHash,
          });
          if (mode == '503') {
            return peopleReply({'error': 'unavailable'}, status: 503);
          }
          if (mode == 'hidden') {
            return peopleReply({'error': 'person_unavailable'}, status: 404);
          }
          return peopleReply(
            personalEnvelope(original!, personalResult(), replayed: true),
          );
        }
        if (call.url.path == '/v1/runtime/events') {
          return peopleReply(_events());
        }
        expect(call.url.path, '/v1/runtime/chats/$importedChatId/messages');
        expect(mode, 'green');
        messages++;
        return peopleReply(_messages([]));
      });
      final runtime = personalRuntime(wire, root!);
      final navigator = GlobalKey<NavigatorState>();
      final button = find.byKey(const ValueKey('timeweb-person-open-chat'));
      Future<void> openAndBack() async {
        await _tap(tester, button);
        await _until(
          tester,
          () => find.byType(TimewebChatPage).evaluate().isNotEmpty,
        );
        expect(
          tester
              .widget<TimewebChatPage>(find.byType(TimewebChatPage))
              .flow
              .chatId,
          importedChatId,
        );
        navigator.currentState!.pop();
        await _until(
          tester,
          () =>
              find.byType(TimewebChatPage).evaluate().isEmpty &&
              button.evaluate().isNotEmpty &&
              tester.widget<ElevatedButton>(button).onPressed != null,
        );
      }

      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            navigatorKey: navigator,
            home: TimewebPersonPage(runtime: runtime, uid: 'B'),
          ),
        );
        await _until(
          tester,
          () =>
              button.evaluate().isNotEmpty &&
              tester.widget<ElevatedButton>(button).onPressed != null,
        );
        await openAndBack();
        expect(personalFiles(root), isEmpty);
        expect(lookups, 0);
        await openAndBack();
        expect(lookups, 1);
        expect(messages, 2);
        mode = '503';
        await _tap(tester, button);
        await _until(
          tester,
          () =>
              find.text('Проверить результат').evaluate().isNotEmpty &&
              tester.widget<ElevatedButton>(button).onPressed != null,
        );
        expect(find.byType(TimewebChatPage), findsNothing);
        expect(messages, 2);
        expect(lookups, 2);
        expect(
          find.text(
            'Результат открытия чата пока неизвестен. Проверьте результат.',
          ),
          findsOneWidget,
        );
        mode = 'green';
        await openAndBack();
        expect(lookups, 3);
        expect(messages, 3);
        mode = 'hidden';
        await _tap(tester, button);
        await _until(
          tester,
          () =>
              lookups == 4 &&
              find
                  .byKey(const ValueKey('timeweb-public-name'))
                  .evaluate()
                  .isEmpty,
        );
        expect(find.byType(TimewebChatPage), findsNothing);
        expect(find.text('Профиль недоступен'), findsWidgets);
        expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);
        expect(find.text('Проверить результат'), findsOneWidget);
        expect(messages, 3);
        expect(
          wire.calls.where((call) => call.url.path.startsWith('/v1/auth/')),
          isEmpty,
        );
        expect(personalFiles(root), isEmpty);
        expect(
          wire.calls.where(
            (call) => call.url.path == '/v1/runtime/personal-chats',
          ),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _stop(tester, runtime);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
