import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_chat_flow.dart';
import 'package:wbrs/service/timeweb_chat_events.dart';
import 'package:wbrs/shared/lrs_theme.dart';

final _now = DateTime.utc(2026, 10, 2);
const _stamp = '2026-10-02T12:00:00.000001Z';
const _origin = 'https://api.example.invalid';
TimewebSession _session(String uid) => TimewebSession(
  uid: uid,
  emailVerified: true,
  accessToken: 'na1.$uid',
  refreshToken: 'nr1.$uid',
  accessExpiresAt: _now.add(const Duration(minutes: 15)),
  refreshExpiresAt: _now.add(const Duration(days: 14)),
);

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = _session('A');
  @override
  Future<TimewebSession?> read() async => value;
  @override
  Future<void> write(TimewebSession session) async => value = session;
  @override
  Future<void> clear() async => value = null;
}

class _Wire extends http.BaseClient {
  _Wire(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handler(request);
  }
}

http.StreamedResponse _reply(Object body, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
Map<String, dynamic> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid',
  'refreshToken': 'nr1.$uid',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
Map<String, dynamic> _chats(String uid) => {
  'kind': 'canonical-current',
  'ordering': 'updated_at_desc_chat_id_asc_null_last',
  'items': [
    {
      'chatId': 'chat-1',
      'counterpartUid': uid == 'A' ? 'B' : 'A',
      'name': 'Peer of $uid',
      'avatar': null,
      'updatedAt': _stamp,
      'lastSequence': 4,
      'revision': 3,
      'readThrough': 1,
      'archived': false,
      'notifications': true,
    },
  ],
  'nextCursor': null,
};
Map<String, dynamic> _message(
  int sequence, {
  String? text = 'Current incoming',
  String sender = 'B',
}) => {
  'chatId': 'chat-1',
  'messageId': 'message-$sequence',
  'sequence': sequence,
  'senderUid': sender,
  'text': text,
  'quote': null,
  'createdAt': _stamp,
};
Map<String, dynamic> _messages(List<Object?> items, [int? before]) => {
  'kind': 'canonical-current',
  'chatId': 'chat-1',
  'chatRevision': 4,
  'ordering': 'sequence_desc',
  'items': items,
  'nextBeforeSequence': before,
};
TimewebMutationRequest _request(Map<String, dynamic> body) =>
    body.containsKey('text')
    ? TimewebMutationRequest.sendMessage(
        operationId: body['operationId'],
        chatId: 'chat-1',
        text: body['text'],
      )
    : TimewebMutationRequest.markRead(
        operationId: body['operationId'],
        chatId: 'chat-1',
        throughSequence: body['throughSequence'],
      );
Map<String, dynamic> _receipt(
  TimewebMutationRequest request,
  Object? result, {
  bool replayed = false,
  bool absent = false,
}) => {
  'operation': request.operation,
  'operationId': request.operationId,
  'requestHash': request.requestHash,
  'state': absent ? 'not_found' : 'committed',
  'replayed': replayed,
  'result': result,
  'entityRevision': absent ? null : 4,
};
Map<String, dynamic> _sent(TimewebMutationRequest request, String text) =>
    _message(5, text: text, sender: 'A')..addAll({
      'chatRevision': 4,
      'eventIds': [1, 2],
    });
List<File> _journals(Directory directory) => directory
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.json'))
    .toList();
TimewebAppRuntime _runtime(
  _Store store,
  _Wire wire,
  Directory directory, {
  TimewebChatJournal? journal,
}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse(_origin),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: store,
  deviceId: 'synthetic-device',
  expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {},
  transport: wire,
  clock: () => _now,
  currentChatsEnabled: true,
  chatJournal: journal ?? TimewebChatJournal(directory: () async => directory),
);
Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
  expect(ready(), isTrue);
}

Future<void> _stopRuntime(
  WidgetTester tester,
  TimewebAppRuntime runtime,
) async {
  var settled = false;
  final original = runtime.stop().then((value) {
    settled = true;
    return value;
  });
  await _waitFor(tester, () => settled);
  expect(await original, isTrue);
}

void main() {
  test(
    'event cursor keeps busy and failed updates; pause and stale A discard',
    () async {
      final directory = await Directory.systemTemp.createTemp('clrs-events-');
      final store = _Store();
      var eventReads = 0, busy = true, failApply = false, incoming = 4;
      Completer<http.StreamedResponse>? delayed;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/runtime/chats') return _reply(_chats('A'));
        if (request.url.path.endsWith('/messages')) {
          if (request.url.queryParameters.containsKey('beforeSequence')) {
            return _reply(_messages([_message(2)]));
          }
          return _reply(_messages([_message(incoming), _message(3)], 3));
        }
        expect(request.url.path, '/v1/runtime/events');
        eventReads++;
        if (delayed != null) return delayed.future;
        final checkpoint = request.url.queryParameters['afterEventId'];
        final id = checkpoint == null ? 11 : int.parse(checkpoint) + 1;
        return _reply({
          'kind': 'canonical-current',
          'ordering': 'event_id_asc',
          'items': [
            {
              'eventId': id,
              'kind': 'chat.message.created.v1',
              'chatId': 'chat-1',
              'messageId': 'message-$incoming',
              'sequence': incoming,
              'senderUid': 'B',
              'readerUid': null,
              'readThroughSequence': null,
              'chatRevision': 4,
              'createdAt': _stamp,
            },
          ],
          'nextAfterEventId': null,
        });
      });
      final runtime = _runtime(store, wire, directory);
      TimewebChatEventPump? pump;
      try {
        await runtime.start(remember: true);
        final flow = await runtime.openChat(
          (await runtime.readChats()).chats.single,
        );
        await flow.loadOlder();
        var applied = 0;
        pump = TimewebChatEventPump(
          interval: const Duration(days: 1),
          isCurrent: () => runtime.session.state.authenticated,
          isVisible: () => true,
          read: flow.readEvents,
          apply: (events) async {
            if (busy) return false;
            if (failApply) {
              throw const SocketException('Synthetic read failure');
            }
            applied++;
            await flow.loadUpdates();
            return true;
          },
        )..start(immediate: false);
        await pump.pollNow();
        expect(eventReads, 1);
        expect(applied, 0);
        busy = false;
        failApply = true;
        await pump.pollNow();
        expect(wire.calls.last.url.path, '/v1/runtime/events');
        expect(
          wire.calls.last.url.queryParameters.containsKey('afterEventId'),
          isFalse,
        );
        failApply = false;
        incoming = 5;
        await pump.pollNow();
        expect(applied, 1);
        expect(flow.messages.map((m) => m.sequence), [5, 4, 3, 2]);
        delayed = Completer<http.StreamedResponse>();
        final pending = pump.pollNow(), duplicate = pump.pollNow();
        expect(identical(pending, duplicate), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(wire.calls.last.url.queryParameters['afterEventId'], '11');
        pump.pause();
        delayed.complete(
          _reply({
            'kind': 'canonical-current',
            'ordering': 'event_id_asc',
            'items': [],
            'nextAfterEventId': null,
          }),
        );
        await pending;
        final pausedReads = eventReads;
        await pump.pollNow();
        expect(eventReads, pausedReads);
        delayed = null;
        pump.start(immediate: false);
        await pump.pollNow();
        expect(
          wire.calls
              .where((r) => r.url.path == '/v1/runtime/events')
              .last
              .url
              .queryParameters['afterEventId'],
          '11',
        );
        expect(applied, 2);
        delayed = Completer<http.StreamedResponse>();
        final oldA = pump.pollNow();
        await Future<void>.delayed(Duration.zero);
        await runtime.stop();
        delayed.complete(
          _reply({
            'kind': 'canonical-current',
            'ordering': 'event_id_asc',
            'items': [],
            'nextAfterEventId': null,
          }),
        );
        await oldA;
        expect(applied, 2);
        flow.close();
      } finally {
        pump?.close();
        await runtime.stop();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'durable send dedup and independent read; restart not-found stays lookup-only',
    () async {
      final directory = await Directory.systemTemp.createTemp('clrs-chat-');
      final store = _Store();
      TimewebMutationRequest? original;
      var sendPosts = 0, readPosts = 0, lookupConfirmed = false;
      const text = '  Original text with spaces\nSecond line  ';
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/runtime/chats') return _reply(_chats('A'));
        if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
          if (request.url.queryParameters.containsKey('beforeSequence')) {
            expect(request.url.queryParameters['beforeSequence'], '3');
            return _reply(_messages([_message(2, text: null)]));
          }
          return _reply(_messages([_message(4), _message(3)], 3));
        }
        if (request.method == 'POST') {
          final body =
              jsonDecode((request as http.Request).body)
                  as Map<String, dynamic>;
          final operation = _request(body);
          final durable = _journals(directory)
              .map((f) => jsonDecode(f.readAsStringSync()))
              .singleWhere((d) => d['operationId'] == body['operationId']);
          expect(durable['uid'], 'A');
          expect(durable['chatId'], 'chat-1');
          expect(durable['requestHash'], operation.requestHash);
          if (request.url.path.endsWith('/read')) {
            readPosts++;
            return _reply({}, status: 503);
          }
          sendPosts++;
          original = operation;
          expect(durable['payload']['text'], text);
          throw const SocketException('Synthetic lost ACK');
        }
        expect(
          request.url.path,
          '/v1/runtime/operations/${original!.operation}/${original!.operationId}',
        );
        expect(request.url.queryParameters, {
          'requestHash': original!.requestHash,
        });
        return _reply(
          _receipt(
            original!,
            lookupConfirmed ? _sent(original!, text) : null,
            replayed: lookupConfirmed,
            absent: !lookupConfirmed,
          ),
        );
      });
      final first = _runtime(store, wire, directory);
      try {
        expect(AppBackend.timewebChatsEnabled, isFalse);
        expect(first.profileEditorEnabled, isFalse);
        await first.start(remember: true);
        final flow = await first.openChat(
          (await first.readChats()).chats.single,
        );
        await flow.loadOlder();
        expect(flow.messages.map((m) => m.sequence), [4, 3, 2]);
        expect(flow.messages.last.text, isNull);
        expect(await flow.markDisplayedRead(), TimewebChatWriteOutcome.unknown);
        final initial = flow.send(text),
            duplicate = flow.send('ignored duplicate');
        expect(identical(initial, duplicate), isTrue);
        expect(await initial, TimewebChatWriteOutcome.unknown);
        expect(readPosts, 1);
        expect(sendPosts, 1); // Unknown own-read marker did not block text.
        final durable = _journals(directory)
            .singleWhere(
              (f) => f.readAsStringSync().contains('chat.send-text.v1'),
            )
            .readAsStringSync();
        expect(durable, isNot(contains('na1.A')));
        flow.close();
        await first.stop();
        final restarted = _runtime(store, wire, directory);
        await restarted.start(remember: true);
        final recovered = await restarted.openChat(
          (await restarted.readChats()).chats.single,
        );
        expect(recovered.pendingText, text);
        expect(() => recovered.send('replacement'), throwsStateError);
        expect(await recovered.checkSend(), TimewebChatWriteOutcome.unknown);
        expect(
          _journals(directory)
              .singleWhere(
                (f) => f.readAsStringSync().contains('chat.send-text.v1'),
              )
              .readAsStringSync(),
          durable,
        );
        expect(sendPosts, 1); // Not-found is not permission to repeat the POST.
        lookupConfirmed = true;
        expect(await recovered.checkSend(), TimewebChatWriteOutcome.confirmed);
        recovered.acceptDisplayedSendResult();
        expect(recovered.sendNeedsCheck, isFalse);
        expect(
          _journals(directory),
          hasLength(1),
        ); // Original read remains isolated.
        recovered.close();
        await restarted.stop();
        // Stop must drain actual disk IO and prevent a late A POST.
        final block = Completer<Directory>();
        var blockIO = false;
        final draining = _runtime(
          store,
          wire,
          directory,
          journal: TimewebChatJournal(
            directory: () async => blockIO ? block.future : directory,
          ),
        );
        await draining.start(remember: true);
        final oldFlow = await draining.openChat(
          (await draining.readChats()).chats.single,
        );
        blockIO = true;
        final oldSend = expectLater(
          oldFlow.send('Must never POST'),
          throwsA(isA<AppSessionException>()),
        );
        var stopped = false;
        final drain = draining.stop().then((safe) {
          stopped = true;
          return safe;
        });
        await Future<void>.delayed(Duration.zero);
        expect(stopped, isFalse);
        block.complete(directory);
        expect(await drain, isTrue);
        await oldSend;
        expect(sendPosts, 1);
        oldFlow.close();
      } finally {
        await first.stop();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'native gate opens current chat at 360px keyboard; ACK and late A isolation',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('clrs-chat-ui-'),
      ))!;
      final store = _Store();
      final lateAck = Completer<http.StreamedResponse>();
      Completer<http.StreamedResponse>? historyGate;
      TimewebMutationRequest? lateOperation, readOperation;
      var sendPosts = 0, readPosts = 0;
      var incomingEvent = false;
      String? sentText;
      final longQuote =
          'Full original quoted text with enough words to wrap on a narrow screen. ' *
          5;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/login') return _reply(_tokens('B'));
        final uid = request.headers['Authorization'] == 'Bearer na1.B'
            ? 'B'
            : 'A';
        if (request.method == 'GET') {
          if (request.url.path == '/v1/runtime/events') {
            return _reply({
              'kind': 'canonical-current',
              'ordering': 'event_id_asc',
              'items': incomingEvent
                  ? [
                      {
                        'eventId': 11,
                        'kind': 'chat.message.created.v1',
                        'chatId': 'chat-1',
                        'messageId': 'message-6',
                        'sequence': 6,
                        'senderUid': 'B',
                        'readerUid': null,
                        'readThroughSequence': null,
                        'chatRevision': 4,
                        'createdAt': _stamp,
                      },
                    ]
                  : [],
              'nextAfterEventId': null,
            });
          }
          if (request.url.path == '/v1/runtime/chats') {
            final page = _chats(uid);
            if (uid == 'A') {
              final cursor = request.url.queryParameters['cursor'];
              final start = cursor == null
                  ? 0
                  : int.parse(cursor.split('_').last);
              final first =
                  (page['items'] as List).single as Map<String, dynamic>;
              page['items'] = List.generate(50, (offset) {
                final number = start + offset;
                return {
                  ...first,
                  'chatId': number == 0
                      ? 'chat-1'
                      : 'paged-${number.toString().padLeft(4, '0')}',
                  'name': number == 0 ? 'Peer of A' : 'Older $number',
                };
              });
              page['nextCursor'] = 'page_${start + 50}';
            }
            return _reply(page);
          }
          if (request.url.path.startsWith('/v1/runtime/operations/')) {
            expect(
              request.url.path,
              '/v1/runtime/operations/${readOperation!.operation}/${readOperation!.operationId}',
            );
            return _reply(_receipt(readOperation!, null, absent: true));
          }
          expect(request.url.path, '/v1/runtime/chats/chat-1/messages');
          if (historyGate != null) return historyGate.future;
          return _reply(
            _messages([
              if (incomingEvent) _message(6, text: 'New incoming from Timeweb'),
              if (sentText != null && uid == 'A')
                _message(5, text: sentText, sender: 'A'),
              _message(4, sender: uid == 'A' ? 'B' : 'A')
                ..['quote'] = {
                  'messageId': 'quoted-2',
                  'sequence': 2,
                  'senderUid': 'A',
                  'text': longQuote,
                },
              _message(3, text: null),
            ], 3),
          );
        }
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        final operation = _request(body);
        if (request.url.path.endsWith('/read')) {
          readPosts++;
          readOperation = operation;
          return _reply({}, status: 503);
        }
        expect(request.url.path, '/v1/runtime/chats/chat-1/messages');
        sendPosts++;
        if (sendPosts == 1) {
          sentText = body['text'];
          return _reply(
            _receipt(operation, _sent(operation, sentText!)),
            status: 201,
          );
        }
        lateOperation = operation;
        return lateAck.future;
      });
      final runtime = _runtime(store, wire, directory);
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebSessionGate(runtime: runtime),
          ),
        );
        await _waitFor(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-open-chats'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(find.byKey(const ValueKey('timeweb-open-chats')));
        await tester.pumpAndSettle();
        expect(find.byType(TimewebChatsPage), findsOneWidget);
        expect(find.text('Peer of A'), findsOneWidget);
        // Six current pages reach the bounded newest-first window. No cursor
        // is advanced over discarded rows and the newest chat stays on top.
        for (var page = 0; page < 5; page++) {
          await tester.tap(
            find.byKey(const ValueKey('timeweb-chat-load-more')),
          );
          await _waitFor(
            tester,
            () =>
                tester
                    .widget<ListView>(
                      find.byKey(const ValueKey('timeweb-chat-list')),
                    )
                    .childrenDelegate
                    .estimatedChildCount ==
                (page + 2) * 50,
          );
          expect(
            find.text('Не удалось загрузить чаты. Проверьте подключение.'),
            findsNothing,
            reason:
                'page $page, wire cursor calls ${wire.calls.where((r) => r.url.queryParameters.containsKey('cursor')).map((r) => r.url.queryParameters['cursor']).toList()}',
          );
        }
        expect(
          tester
              .widget<ListView>(find.byKey(const ValueKey('timeweb-chat-list')))
              .childrenDelegate
              .estimatedChildCount,
          300,
        );
        expect(
          find.byKey(const ValueKey('timeweb-chat-load-more')),
          findsNothing,
        );
        expect(find.text('Peer of A'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('timeweb-chat-chat-1')));
        await _waitFor(
          tester,
          () => find.byType(TimewebChatPage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await _waitFor(tester, () => readPosts == 1);
        final composer = find.byKey(const ValueKey('timeweb-chat-composer'));
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.enterText(
          composer,
          '  Message with original spaces and a long line for narrow keyboard layout  ',
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final quote = tester.widget<Text>(find.text(longQuote));
        expect(quote.maxLines, isNull);
        expect(quote.overflow, isNull);
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('timeweb-chat-gift')),
              )
              .onPressed,
          isNull,
        );
        // A history read and send ACK must not race: keep the draft editable,
        // but disable send/check until that original current GET has settled.
        final controlledHistory = Completer<http.StreamedResponse>();
        historyGate = controlledHistory;
        await tester.tap(find.byTooltip('Обновить'));
        await tester.pump();
        final sendButton = find.byKey(const ValueKey('timeweb-chat-send'));
        expect(tester.widget<IconButton>(sendButton).onPressed, isNull);
        expect(tester.widget<TextField>(composer).readOnly, isFalse);
        const draft = '  Draft edited while history is still loading  ';
        await tester.enterText(composer, draft);
        expect(tester.widget<TextField>(composer).controller!.text, draft);
        expect(sendPosts, 0);
        historyGate = null;
        await tester.runAsync(() async {
          controlledHistory.complete(
            _reply(
              _messages([
                _message(4)
                  ..['quote'] = {
                    'messageId': 'quoted-2',
                    'sequence': 2,
                    'senderUid': 'A',
                    'text': longQuote,
                  },
                _message(3, text: null),
              ]),
            ),
          );
        });
        await _waitFor(
          tester,
          () => tester.widget<IconButton>(sendButton).onPressed != null,
        );
        expect(tester.widget<TextField>(composer).controller!.text, draft);
        await tester.runAsync(() async {
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('timeweb-chat-send')),
              )
              .onPressed!();
        });
        await _waitFor(
          tester,
          () => tester.widget<TextField>(composer).controller!.text.isEmpty,
        );
        expect(sendPosts, 1);
        expect(sentText, draft);
        expect(readPosts, 1);
        expect(find.text(sentText!), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Unknown read is lookup-only. Allow it to settle before the A/B case.
        await tester.pump();
        await tester.enterText(composer, 'Unconfirmed A message');
        incomingEvent = true;
        await tester.pump(const Duration(seconds: 9));
        await _waitFor(
          tester,
          () => find.text('New incoming from Timeweb').evaluate().isNotEmpty,
        );
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'Unconfirmed A message',
        );
        incomingEvent = false;
        await tester.runAsync(() async {
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('timeweb-chat-send')),
              )
              .onPressed!();
        });
        await _waitFor(tester, () => sendPosts == 2);
        // In the reverse ordering, a pending send owns the next latest GET.
        // Manual refresh/older cannot take the read slot away from its ACK.
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('timeweb-chat-refresh')),
              )
              .onPressed,
          isNull,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('timeweb-chat-older')),
          300,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('timeweb-chat-messages')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('timeweb-chat-older')),
              )
              .onPressed,
          isNull,
        );
        expect(
          _journals(
            directory,
          ).where((f) => f.readAsStringSync().contains('chat.send-text.v1')),
          hasLength(1),
        );
        await tester.runAsync(
          () => runtime.login(
            email: 'B@example.invalid',
            password: 'synthetic password',
          ),
        );
        tester.view.resetViewInsets();
        await _waitFor(
          tester,
          () =>
              find.byType(TimewebChatPage).evaluate().isEmpty &&
              find.byType(TimewebChatsPage).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.text('Unconfirmed A message'), findsNothing);
        await tester.runAsync(() async {
          lateAck.complete(
            _reply(
              _receipt(
                lateOperation!,
                _sent(lateOperation!, 'Unconfirmed A message'),
              ),
              status: 201,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pumpAndSettle();
        expect(
          _journals(
            directory,
          ).where((f) => f.readAsStringSync().contains('chat.send-text.v1')),
          hasLength(1),
        );
        await _waitFor(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-open-chats'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(find.byKey(const ValueKey('timeweb-open-chats')));
        await tester.pumpAndSettle();
        expect(find.text('Peer of B'), findsOneWidget);
        expect(find.text('Peer of A'), findsNothing);
        expect(sendPosts, 2);
        expect(Firebase.apps, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await _stopRuntime(tester, runtime);
      } finally {
        if (!lateAck.isCompleted) lateAck.complete(_reply({}, status: 503));
        await _stopRuntime(tester, runtime);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
