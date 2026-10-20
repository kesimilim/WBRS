import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_gift_flow.dart';
import 'package:wbrs/presentation/screens/shop/timeweb_gifts_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/timeweb_people_fixtures.dart';

const _id = 'assets/gifts/1.png';
String _hash(Object value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    value = {for (final k in keys) k: value[k]};
  }
  return sha256.convert(utf8.encode(jsonEncode(value))).toString();
}

Map<String, dynamic> _mine({
  int balance = 100,
  int revision = 2,
  int owned = 1,
  int received = 2,
}) => {
  'kind': 'native-gifts',
  'balanceAg': balance,
  'walletRevision': revision,
  'inventory': [
    {'giftId': _id, 'ownedQuantity': owned, 'receivedQuantity': received},
  ],
  'catalog': [
    {'id': _id, 'assetPath': _id, 'name': 'Любовь', 'priceAg': 44},
  ],
};
Map<String, dynamic> _receipt(
  Map<String, dynamic> body,
  String uid, {
  bool replayed = false,
  String? error,
}) {
  final p = body['payload'] as Map<String, dynamic>,
      buy = p['kind'] == 'buy',
      id = body['operationId'];
  final derived = 'tw-gift-${_hash([uid, id])}';
  return {
    'operation': 'gift.${p['kind']}.v1',
    'operationId': id,
    'requestHash': _hash(p),
    'state': 'committed',
    'replayed': replayed,
    'entityRevision': buy
        ? (error == null ? p['expectedWalletRevision'] + 1 : 8)
        : null,
    'result': error != null
        ? {'error': error}
        : buy
        ? {
            'giftId': p['giftId'],
            'entryId': derived,
            'balanceAg': 56,
            'walletRevision': p['expectedWalletRevision'] + 1,
          }
        : {
            'giftId': p['giftId'],
            'transferId': derived,
            'recipientUid': 'peer',
            'chatId': p['chatId'],
            'messageId': 'tw-${_hash([uid, id, 'gift-notice'])}',
            'sequence': 4,
          },
  };
}

TimewebAppRuntime _app(PeopleWire wire, PeopleStore store, Directory folder) =>
    TimewebAppRuntime(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse('https://api.example.invalid'),
        enabled: true,
        currentReadsEnabled: true,
        runtimeWritesEnabled: true,
      ),
      secureStore: store,
      transport: wire,
      deviceId: 'fixture',
      expectedSourceSnapshot: 'a' * 64,
      clearLocal: () async {},
      clock: () => peopleNow,
      currentOwnProfileEnabled: true,
      currentChatsEnabled: true,
      giftJournal: TimewebGiftJournal(directory: () async => folder),
    );
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  await tester.pump();
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

void main() {
  test(
    'exact original buy/send receipts, durable payload, committed failures and spoofed ID refusal',
    () async {
      final folder = await Directory.systemTemp.createTemp('gift-exact-');
      String? error;
      var spoof = false;
      final wire = PeopleWire((r) async {
        final files = await Directory(
          '${folder.path}/clrs_native_gift',
        ).list().where((v) => v.path.endsWith('.json')).toList();
        expect(files, hasLength(1));
        final body =
            jsonDecode((r as http.Request).body) as Map<String, dynamic>;
        final disk = jsonDecode(await (files.single as File).readAsString());
        expect(disk['operationId'], body['operationId']);
        expect(disk['payload'], body['payload']);
        final reply = _receipt(body, 'A', error: error);
        if (spoof) {
          reply['result']['entryId'] = 'tw-gift-${'0' * 64}';
        }
        return peopleReply(reply, status: error == null ? 201 : 409);
      });
      final app = _app(wire, PeopleStore(), folder);
      await app.start(remember: true);
      addTearDown(() async {
        await app.stop();
        await folder.delete(recursive: true);
      });
      final flow = await app.openGifts();
      final first = flow.submit(TimewebGiftAction.buy(_id, 2));
      expect(
        identical(first, flow.submit(TimewebGiftAction.buy(_id, 9))),
        isTrue,
      );
      expect(await first, TimewebGiftOutcome.confirmed);
      expect(flow.receipt!.balanceAg, 56);
      expect(
        await flow.submit(TimewebGiftAction.send(_id, 'chat', 1)),
        TimewebGiftOutcome.confirmed,
      );
      expect(flow.receipt!.chatId, 'chat');
      for (final label in [
        'balance_changed',
        'insufficient_silver',
        'inventory_changed',
        'gift_not_owned',
      ]) {
        error = label;
        final buy =
            label == 'balance_changed' || label == 'insufficient_silver';
        expect(
          await flow.submit(
            buy
                ? TimewebGiftAction.buy(_id, 2)
                : TimewebGiftAction.send(_id, 'chat', 1),
          ),
          TimewebGiftOutcome.rejected,
        );
        expect(flow.needsCheck, isFalse);
      }
      error = null;
      spoof = true;
      expect(
        await flow.submit(TimewebGiftAction.buy(_id, 2)),
        TimewebGiftOutcome.unknown,
      );
      expect(flow.needsCheck, isTrue);
      flow.close();
    },
  );
  test(
    'lost ACK restart lookup-only, missing/denied preserve UUID; late A cannot ACK B',
    () async {
      final folder = await Directory.systemTemp.createTemp('gift-resume-');
      Map<String, dynamic>? original;
      var mode = 'unknown', posts = 0;
      final late = Completer<http.StreamedResponse>();
      var held = false;
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/auth/login')) {
          return peopleReply(
            peopleTokens(
              (jsonDecode((r as http.Request).body)['email'] as String)
                      .startsWith('a')
                  ? 'A'
                  : 'B',
            ),
          );
        }
        if (r.method == 'POST') {
          posts++;
          original = jsonDecode((r as http.Request).body);
          if (mode == 'hold') {
            held = true;
            return late.future;
          }
          return peopleReply({'error': 'outcome_unknown'}, status: 503);
        }
        if (mode == 'missing') {
          return peopleReply({
            ..._receipt(original!, 'A', replayed: true),
            'state': 'not_found',
            'replayed': false,
            'result': null,
            'entityRevision': null,
          });
        }
        if (mode == 'denied') {
          return peopleReply({'error': 'gift_access_denied'}, status: 403);
        }
        return peopleReply(
          _receipt(original!, 'A', replayed: true),
          status: 201,
        );
      });
      final app = _app(wire, PeopleStore(), folder);
      await app.start(remember: true);
      addTearDown(() async {
        if (!late.isCompleted) {
          late.complete(peopleReply(_receipt(original!, 'A'), status: 201));
        }
        await app.stop();
        await folder.delete(recursive: true);
      });
      var flow = await app.openGifts();
      expect(
        await flow.submit(TimewebGiftAction.buy(_id, 2)),
        TimewebGiftOutcome.unknown,
      );
      flow.close();
      flow = await app.openGifts();
      mode = 'missing';
      expect(await flow.check(), TimewebGiftOutcome.unknown);
      mode = 'denied';
      expect(await flow.check(), TimewebGiftOutcome.unknown);
      expect(flow.failure, TimewebMutationFailure.giftAccessDenied);
      mode = 'confirmed';
      expect(await flow.check(), TimewebGiftOutcome.confirmed);
      expect(posts, 1);
      mode = 'hold';
      final pending = flow.submit(TimewebGiftAction.buy(_id, 3));
      final fail = expectLater(pending, throwsA(isA<TimewebAuthException>()));
      while (!held) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await app.login(email: 'b@example.invalid', password: 'fixture');
      late.complete(peopleReply(_receipt(original!, 'A'), status: 201));
      await fail;
      expect(() => flow.pendingAction, throwsA(isA<AppSessionException>()));
      final other = await app.openGifts();
      expect(other.needsCheck, isFalse);
      other.close();
      await app.login(email: 'a@example.invalid', password: 'fixture');
      final restored = await app.openGifts();
      expect(restored.pendingAction!.payload['expectedWalletRevision'], 3);
      mode = 'confirmed';
      expect(await restored.check(), TimewebGiftOutcome.confirmed);
      expect(posts, 2);
      restored.close();
      flow.close();
    },
  );
  test(
    'mine validates local catalog, nullable price, counts, bounds and healthy denial',
    () async {
      final folder = await Directory.systemTemp.createTemp('gift-wire-');
      Object data = _mine();
      var status = 200;
      final wire = PeopleWire((r) async => peopleReply(data, status: status));
      final app = _app(wire, PeopleStore(), folder);
      await app.start(remember: true);
      addTearDown(() async {
        await app.stop();
        await folder.delete(recursive: true);
      });
      final current = await app.readGifts();
      expect(current.balanceAg, 100);
      expect(current.owned(_id), 1);
      expect(current.received(_id), 2);
      data = {
        ..._mine(),
        'catalog': [
          {'id': _id, 'assetPath': _id, 'name': 'Любовь', 'priceAg': null},
        ],
      };
      expect((await app.readGifts()).catalog.single.priceAg, isNull);
      for (final bad in [
        {
          ..._mine(),
          'catalog': [
            {
              'id': _id,
              'assetPath': 'https://bad.invalid/image',
              'name': 'Любовь',
              'priceAg': 1,
            },
          ],
        },
        {
          ..._mine(),
          'inventory': [
            {'giftId': _id, 'ownedQuantity': -1, 'receivedQuantity': 0},
          ],
        },
        {
          ..._mine(),
          'catalog': [
            for (var i = 0; i < 65; i++)
              {'id': _id, 'assetPath': _id, 'name': 'Любовь', 'priceAg': 1},
          ],
        },
      ]) {
        data = bad;
        await expectLater(
          app.readGifts(),
          throwsA(isA<TimewebAuthException>()),
        );
      }
      status = 403;
      data = {'error': 'gift_access_denied'};
      await expectLater(
        app.readGifts(),
        throwsA(isA<TimewebGiftAccessDenied>()),
      );
      expect(app.session.state.identity!.uid, 'A');
      expect(
        wire.calls.where((r) => r.url.path.contains('/auth/refresh')),
        isEmpty,
      );
    },
  );
  testWidgets(
    'real native shop buys, selects current chat, sends, and restores unknown original',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gift-ui-'),
      ))!;
      var balance = 100, revision = 2, owned = 0, posts = 0;
      var unknown = false;
      Map<String, dynamic>? original;
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/gifts/mine')) {
          return peopleReply(
            _mine(
              balance: balance,
              revision: revision,
              owned: owned,
              received: 0,
            ),
          );
        }
        if (r.url.path.endsWith('/runtime/chats')) {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'updated_at_desc_chat_id_asc_null_last',
            'items': [
              {
                'chatId': 'chat',
                'counterpartUid': 'peer',
                'name': 'Current recipient',
                'avatar': null,
                'updatedAt': peopleStamp,
                'lastSequence': 3,
                'revision': 3,
                'readThrough': 0,
                'archived': false,
                'notifications': true,
              },
            ],
            'nextCursor': null,
          });
        }
        if (r.method == 'POST') {
          posts++;
          original = jsonDecode((r as http.Request).body);
          if (unknown) {
            return peopleReply({'error': 'outcome_unknown'}, status: 503);
          }
          if (original!['payload']['kind'] == 'buy') {
            balance = 56;
            revision++;
            owned++;
          } else {
            owned--;
          }
          return peopleReply(_receipt(original!, 'A'), status: 201);
        }
        return peopleReply(
          _receipt(original!, 'A', replayed: true),
          status: 201,
        );
      });
      final app = _app(wire, PeopleStore(), folder);
      await tester.runAsync(() => app.start(remember: true));
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        var done = false;
        final stop = app.stop().then((_) => done = true);
        await _until(tester, () => done);
        await stop;
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      Future<void> mount(String key) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: TimewebGiftsPage(key: ValueKey(key), runtime: app),
          ),
        );
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-gifts-busy'))
              .evaluate()
              .isEmpty,
        );
      }

      Future<void> tap(Key key) async {
        final f = find.byKey(key);
        await tester.scrollUntilVisible(
          f,
          300,
          scrollable: find.byType(Scrollable).hitTestable().first,
        );
        await tester.pump();
        await tester.tap(f);
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-gifts-busy'))
              .evaluate()
              .isEmpty,
        );
      }

      await mount('first');
      expect(find.byKey(const ValueKey('gift-store-logo')), findsOneWidget);
      await tap(const ValueKey('timeweb-gift-buy-assets/gifts/1.png'));
      expect(balance, 56);
      expect(owned, 1);
      await tester.ensureVisible(find.text('Выбранные подарки'));
      await tester.tap(find.text('Выбранные подарки'));
      await tester.pump();
      await tap(const ValueKey('timeweb-gift-send-assets/gifts/1.png'));
      final panel = find.byKey(
          const ValueKey('timeweb-gift-recipient-panel'));
      await _until(tester, () => panel.evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      final recipient = find.text('Current recipient');
      await tester.scrollUntilVisible(recipient, 150,
          scrollable: find.descendant(
              of: panel, matching: find.byType(Scrollable)).first);
      await tester.pump();
      await tester.tap(recipient);
      await tester.pump();
      final confirm = find.byKey(
          const ValueKey('timeweb-gift-recipient-confirm'));
      await tester.ensureVisible(confirm);
      await tester.pump();
      await tester.tap(confirm);
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('timeweb-gifts-busy')).evaluate().isEmpty,
      );
      expect(owned, 0);
      unknown = true;
      await tester.ensureVisible(find.text('Выбрать подарки'));
      await tester.tap(find.text('Выбрать подарки'));
      await tester.pump();
      await tap(const ValueKey('timeweb-gift-buy-assets/gifts/1.png'));
      expect(posts, 3);
      await tester.pumpWidget(const SizedBox.shrink());
      await mount('restart');
      await tap(const ValueKey('timeweb-gift-check'));
      expect(posts, 3);
      expect(find.byKey(const ValueKey('timeweb-gift-check')), findsNothing);
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
