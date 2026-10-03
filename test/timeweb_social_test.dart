import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_social_flow.dart';
import 'package:wbrs/presentation/screens/feed/timeweb_feed_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

String _hash(Object value) {
  Object? canonical(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: canonical(v[k])};
    }
    return v;
  }

  return sha256.convert(utf8.encode(jsonEncode(canonical(value)))).toString();
}

Future<void> _untilWidget(WidgetTester tester, bool Function() ready) async {
  await tester.pump();
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

void _socialWidgetCase() {
  testWidgets(
    'native feed: keyboard draft, lost ACK reopen/check, comments and late A-to-B',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('social-ui-'),
      ))!;
      final store = PeopleStore(), late = Completer<http.StreamedResponse>();
      var posts = 0,
          hold = false,
          held = false,
          ready = false,
          liked = false,
          hidden = false;
      Map<String, dynamic>? original, lateBody;
      final wire = PeopleWire((r) async {
        final uid = r.headers['authorization']?.split('.')[1] ?? 'A';
        final path = r.url.path;
        if (path.endsWith('/auth/login')) return peopleReply(peopleTokens('B'));
        if (path.endsWith('/me/full-profile')) {
          return peopleReply(peopleOwn(uid));
        }
        if (path.endsWith('/social/feed')) {
          final item = {
            ..._post('post-$uid', peopleStamp),
            'authorUid': uid,
            'text': ready && uid == 'A' ? 'Native draft' : 'Current $uid post',
            'commentCount': 1,
          };
          return peopleReply(_feed([item]));
        }
        if (path.endsWith('/comments')) {
          return peopleReply({
            'kind': 'native-comments',
            'postId': 'post-$uid',
            'ordering': 'created_asc_id_asc_null_first',
            'items': hidden
                ? <Object?>[]
                : [
                    {
                      'id': 'comment',
                      'authorUid': uid,
                      'text': 'Original comment',
                      'parentId': null,
                      'mediaId': null,
                      'createdAt': peopleStamp,
                      'liked': liked,
                    },
                  ],
            'nextCursor': null,
          });
        }
        if (path.contains('/social/operations/')) {
          ready = true;
          return peopleReply(
            _receipt(original!, 'A', replayed: true),
            status: 201,
          );
        }
        if (path.endsWith('/social/actions')) {
          posts++;
          final body =
              jsonDecode((r as http.Request).body) as Map<String, dynamic>;
          final kind = body['payload']['kind'];
          if (kind == 'publish') {
            if (hold) {
              lateBody = body;
              held = true;
              return late.future;
            }
            original = body;
            return peopleReply({'error': 'outcome_unknown'}, status: 503);
          }
          if (kind == 'react') liked = body['payload']['active'];
          if (kind == 'hide-comment') hidden = true;
          return peopleReply(_receipt(body, uid));
        }
        return peopleReply({'error': 'not_found'}, status: 404);
      });
      final app = _app(wire, store, folder);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(() async {
        if (!late.isCompleted && lateBody != null) {
          late.complete(peopleReply(_receipt(lateBody!, 'A'), status: 201));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        var done = false;
        final stop = app.stop().then((_) => done = true);
        await _untilWidget(tester, () => done);
        await stop;
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      await tester.runAsync(() => app.start(remember: true));
      Future<void> mount(String key) => tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: TimewebFeedPage(key: ValueKey(key), runtime: app),
        ),
      );
      await mount('first');
      await _untilWidget(
        tester,
        () =>
            find.text('Current A post').evaluate().isNotEmpty &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('timeweb-social-new-post')));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('timeweb-social-text')),
        300,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('timeweb-social-text')),
        'Native draft',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('timeweb-social-send')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('timeweb-social-send')));
      await _untilWidget(
        tester,
        () =>
            find
                .byKey(const ValueKey('timeweb-social-check'))
                .evaluate()
                .isNotEmpty &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      expect(posts, 1);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpWidget(const SizedBox.shrink());
      await mount('reopen');
      await _untilWidget(
        tester,
        () =>
            find
                .byKey(const ValueKey('timeweb-social-check'))
                .evaluate()
                .isNotEmpty &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      expect(posts, 1);
      await tester.ensureVisible(
        find.byKey(const ValueKey('timeweb-social-check')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('timeweb-social-check')));
      await _untilWidget(
        tester,
        () =>
            find.text('Native draft').evaluate().isNotEmpty &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      expect(posts, 1);
      final comments = find.byKey(
        const ValueKey('timeweb-social-comments-post-A'),
      );
      await tester.ensureVisible(comments);
      await tester.pump();
      await tester.tap(comments);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await _untilWidget(
        tester,
        () =>
            wire.calls.any(
              (r) => r.url.path.endsWith('/posts/post-A/comments'),
            ) &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('Original comment'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(find.text('Original comment'), findsOneWidget);
      final react = find.text('Реакции');
      await tester.ensureVisible(react);
      await tester.pump();
      await tester.tap(react);
      await _untilWidget(
        tester,
        () =>
            liked &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      await tester.tap(react);
      await _untilWidget(
        tester,
        () =>
            !liked &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      final hide = find.byTooltip('Удалить');
      await tester.ensureVisible(hide);
      await tester.pump();
      await tester.tap(hide);
      await _untilWidget(
        tester,
        () =>
            hidden &&
            find.text('Original comment').evaluate().isEmpty &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      await tester.pageBack();
      await tester.pump();
      await _untilWidget(
        tester,
        () =>
            find
                .byType(TimewebFeedPage, skipOffstage: false)
                .evaluate()
                .length ==
            1,
      );
      await _untilWidget(
        tester,
        () =>
            find
                .byKey(const ValueKey('timeweb-social-new-post'))
                .evaluate()
                .isNotEmpty &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      hold = true;
      await tester.tap(find.byKey(const ValueKey('timeweb-social-new-post')));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('timeweb-social-text')),
        300,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('timeweb-social-text')),
        'Late A original',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('timeweb-social-send')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('timeweb-social-send')));
      await _untilWidget(tester, () => held);
      await tester.runAsync(
        () => app.login(email: 'b@example.invalid', password: 'fixture'),
      );
      await mount('owner-B');
      await _untilWidget(
        tester,
        () =>
            find.text('Current B post').evaluate().isNotEmpty &&
            find
                .byKey(const ValueKey('timeweb-social-busy'))
                .evaluate()
                .isEmpty,
      );
      late.complete(peopleReply(_receipt(lateBody!, 'A'), status: 201));
      await tester.pump();
      expect(find.text('Late A original'), findsNothing);
      expect(find.text('Native draft'), findsNothing);
      final retained = (await tester.runAsync(
        () => Directory(
          '${folder.path}/clrs_native_social',
        ).list().where((v) => v.path.endsWith('.json')).toList(),
      ))!;
      expect(retained, hasLength(1));
      expect(
        jsonDecode(
          (await tester.runAsync(
            () => (retained.single as File).readAsString(),
          ))!,
        )['payload']['text'],
        'Late A original',
      );
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

String _created(String kind, String uid, String id) =>
    '${kind == 'publish' ? 'tw-post-' : 'tw-comment-'}${sha256.convert(utf8.encode('$kind\u0000$uid\u0000$id'))}';
Map<String, dynamic> _receipt(
  Map<String, dynamic> body,
  String uid, {
  bool replayed = false,
}) {
  final p = body['payload'] as Map<String, dynamic>, kind = p['kind'];
  return {
    'operation': 'social.$kind.v1',
    'operationId': body['operationId'],
    'requestHash': _hash(p),
    'state': 'committed',
    'replayed': replayed,
    'entityRevision': null,
    'result': switch (kind) {
      'publish' => {'postId': _created(kind, uid, body['operationId'])},
      'comment' => {
        'postId': p['postId'],
        'commentId': _created(kind, uid, body['operationId']),
      },
      'react' => {
        'postId': p['postId'],
        'commentId': p['commentId'],
        'active': p['active'],
      },
      'report' => {
        'postId': p['postId'],
        'commentId': p['commentId'],
        'reported': true,
      },
      'hide-comment' => {
        'postId': p['postId'],
        'commentId': p['commentId'],
        'hidden': true,
      },
      _ => throw StateError('Unexpected kind'),
    },
  };
}

Map<String, dynamic> _post(String id, String? at) => {
  'id': id,
  'authorUid': 'peer',
  'text': null,
  'mediaId': null,
  'createdAt': at,
  'likeCount': 0,
  'commentCount': 0,
  'liked': false,
};
Map<String, dynamic> _feed(List<Object?> items, [String? cursor]) => {
  'kind': 'native-feed',
  'ordering': 'created_desc_id_desc_null_last',
  'items': items,
  'nextCursor': cursor,
  'canPublish': true,
  'canModerate': true,
};
TimewebAppRuntime _app(
  PeopleWire wire,
  PeopleStore store,
  Directory folder, {
  DateTime Function()? clock,
}) => TimewebAppRuntime(
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
  clock: clock ?? () => peopleNow,
  currentOwnProfileEnabled: true,
  socialJournal: TimewebSocialJournal(directory: () async => folder),
);

void main() {
  _socialWidgetCase();
  test(
    'retained meeting IDs are GET-only; native send receipt still requires original derived ID',
    () async {
      final folder = await Directory.systemTemp.createTemp('retained-read-');
      const retained = 'Историческое-🙂';
      final row = {
        'meetingId': 'meeting',
        'messageId': retained,
        'sequence': 1,
        'senderUid': 'A',
        'text': 'Exact source',
        'createdAt': peopleStamp,
      };
      final wire = PeopleWire((r) async {
        if (r.method == 'GET') {
          return peopleReply({
            'kind': 'canonical-current',
            'meetingId': 'meeting',
            'chatRevision': 1,
            'ordering': 'sequence_desc',
            'items': [row],
            'nextCursor': null,
            'mediaReady': false,
          });
        }
        final body = jsonDecode((r as http.Request).body);
        return peopleReply({
          'operation': 'meeting.send-text.v1',
          'operationId': body['operationId'],
          'requestHash': _hash({'meetingId': 'meeting', 'text': body['text']}),
          'state': 'committed',
          'replayed': false,
          'entityRevision': 1,
          'result': {...row, 'chatRevision': 1},
        }, status: 201);
      });
      final app = _app(wire, PeopleStore(), folder);
      await app.start(remember: true);
      addTearDown(() async {
        await app.stop();
        await folder.delete(recursive: true);
      });
      expect(
        (await app.client.readMeetingMessages(
          'meeting',
        )).items.single.messageId,
        retained,
      );
      final ref = app.client.bindMutation(
        TimewebMutationRequest.sendMeetingText(
          operationId: '11111111-1111-4111-8111-111111111111',
          meetingId: 'meeting',
          text: 'Exact source',
        ),
        expectedOwnerUid: 'A',
      );
      final result = await app.client.mutate(ref);
      expect(result.state, TimewebMutationState.unknown);
      expect(result.canAcknowledge, isFalse);
    },
  );
  test(
    'exact five actions persist before POST, duplicate future, original receipt IDs and nullable targets',
    () async {
      final folder = await Directory.systemTemp.createTemp('social-five-');
      late TimewebAppRuntime app;
      final wire = PeopleWire((r) async {
        expect(r.method, 'POST');
        expect(r.url.path, '/v1/runtime/social/actions');
        final journals = await Directory(
          '${folder.path}/clrs_native_social',
        ).list().where((v) => v.path.endsWith('.json')).toList();
        expect(journals, hasLength(1));
        final body =
            jsonDecode((r as http.Request).body) as Map<String, dynamic>;
        final disk = jsonDecode(await (journals.single as File).readAsString());
        expect(disk['operationId'], body['operationId']);
        expect(disk['payload'], body['payload']);
        final kind = body['payload']['kind'];
        return peopleReply(
          _receipt(body, 'A'),
          status: kind == 'publish' || kind == 'comment' ? 201 : 200,
        );
      });
      app = _app(wire, PeopleStore(), folder);
      await app.start(remember: true);
      addTearDown(() async {
        await app.stop();
        await folder.delete(recursive: true);
      });
      final flow = await app.openSocial();
      final actions = [
        TimewebSocialAction.publish(' Original text \n'),
        TimewebSocialAction.comment('post', 'Comment', parentId: null),
        TimewebSocialAction.react('post', false, commentId: null),
        TimewebSocialAction.report('post', commentId: 'comment'),
        TimewebSocialAction.hideComment('post', 'comment'),
      ];
      for (final action in actions) {
        final original = flow.submit(action);
        expect(identical(original, flow.submit(action)), isTrue);
        expect(await original, TimewebSocialOutcome.confirmed);
        expect(flow.receipt!.kind, action.kind);
        expect(flow.needsCheck, isFalse);
      }
      expect(wire.calls, hasLength(5));
      flow.close();
    },
  );

  test(
    'lost ACK restart is original lookup only; absent and denied cannot ACK or send a new UUID',
    () async {
      final folder = await Directory.systemTemp.createTemp('social-restart-'),
          store = PeopleStore();
      Map<String, dynamic>? original;
      var status = 'missing';
      final wire = PeopleWire((r) async {
        if (r.method == 'POST') {
          original = jsonDecode((r as http.Request).body);
          throw TimeoutException('lost original ACK');
        }
        expect(
          r.url.path,
          '/v1/runtime/social/operations/social.publish.v1/${original!['operationId']}',
        );
        expect(
          r.url.queryParameters['requestHash'],
          _hash(original!['payload']),
        );
        if (status == 'missing') {
          return peopleReply({
            'operation': 'social.publish.v1',
            'operationId': original!['operationId'],
            'requestHash': _hash(original!['payload']),
            'state': 'not_found',
            'replayed': false,
            'result': null,
            'entityRevision': null,
          });
        }
        if (status == 'denied') {
          return peopleReply({'error': 'social_access_denied'}, status: 403);
        }
        return peopleReply(
          _receipt(original!, 'A', replayed: true),
          status: 201,
        );
      });
      final first = _app(wire, store, folder);
      await first.start(remember: true);
      var flow = await first.openSocial();
      expect(
        await flow.submit(TimewebSocialAction.publish('Original')),
        TimewebSocialOutcome.unknown,
      );
      flow.close();
      await first.stop();
      final restarted = _app(wire, store, folder);
      await restarted.start(remember: true);
      addTearDown(() async {
        await restarted.stop();
        await folder.delete(recursive: true);
      });
      flow = await restarted.openSocial();
      expect(flow.pendingAction!.payload['text'], 'Original');
      expect(await flow.check(), TimewebSocialOutcome.unknown);
      expect(
        () => flow.submit(TimewebSocialAction.publish('New')),
        throwsStateError,
      );
      status = 'denied';
      expect(await flow.check(), TimewebSocialOutcome.unknown);
      expect(flow.failure, TimewebMutationFailure.socialAccessDenied);
      expect(restarted.session.state.authenticated, isTrue);
      status = 'ready';
      expect(await flow.check(), TimewebSocialOutcome.confirmed);
      expect(wire.calls.where((r) => r.method == 'POST'), hasLength(1));
      flow.close();
    },
  );

  test(
    'current page scope, original expiry, sparse values, malformed bounds and target denial',
    () async {
      final folder = await Directory.systemTemp.createTemp('social-pages-');
      var now = peopleNow, mode = 'first';
      final wire = PeopleWire((r) async {
        if (mode == 'denied') {
          return peopleReply({'error': 'social_access_denied'}, status: 403);
        }
        if (mode == 'malformed') {
          return peopleReply(
            _feed([_post('same', peopleStamp), _post('same', peopleStamp)]),
          );
        }
        if (mode == 'oversize') {
          return peopleReply(
            _feed([for (var i = 0; i < 4; i++) _post('$i', null)]),
          );
        }
        if (r.url.path.endsWith('/comments')) {
          return peopleReply({
            'kind': 'native-comments',
            'postId': 'post',
            'ordering': 'created_asc_id_asc_null_first',
            'items': [
              {
                'id': 'comment',
                'authorUid': 'peer',
                'text': null,
                'parentId': null,
                'mediaId': null,
                'createdAt': null,
                'liked': true,
              },
            ],
            'nextCursor': null,
          });
        }
        return peopleReply(
          mode == 'first'
              ? _feed([_post('z', peopleStamp)], 'cursor_one')
              : _feed([_post('y', null)], 'cursor_two'),
        );
      });
      final app = _app(wire, PeopleStore(), folder, clock: () => now);
      await app.start(remember: true);
      addTearDown(() async {
        await app.stop();
        await folder.delete(recursive: true);
      });
      final page = await app.readSocialFeed(limit: 10, wallUid: 'owner');
      expect(page.items.single.text, isNull);
      expect(page.items.single.createdAt, peopleStamp);
      await expectLater(
        app.readSocialFeed(limit: 9, wallUid: 'owner', cursor: page.nextCursor),
        throwsA(isA<TimewebAuthException>()),
      );
      now = now.add(const Duration(seconds: 200));
      mode = 'second';
      final second = await app.readSocialFeed(
        limit: 10,
        wallUid: 'owner',
        cursor: page.nextCursor,
      );
      expect(second.items.single.createdAt, isNull);
      now = peopleNow.add(const Duration(seconds: 301));
      await expectLater(
        app.readSocialFeed(
          limit: 10,
          wallUid: 'owner',
          cursor: second.nextCursor,
        ),
        throwsA(isA<TimewebAuthException>()),
      );
      now = peopleNow;
      mode = 'malformed';
      await expectLater(
        app.readSocialFeed(),
        throwsA(isA<TimewebAuthException>()),
      );
      mode = 'oversize';
      await expectLater(
        app.readSocialFeed(),
        throwsA(isA<TimewebAuthException>()),
      );
      mode = 'first';
      expect((await app.readSocialComments('post')).items.single.liked, isTrue);
      mode = 'denied';
      await expectLater(
        app.readSocialComments('post'),
        throwsA(isA<TimewebSocialAccessDenied>()),
      );
      expect(app.session.state.authenticated, isTrue);
    },
  );

  test(
    'late A receipt cannot retire its journal or enter B; A restores original lookup',
    () async {
      final folder = await Directory.systemTemp.createTemp('social-owner-'),
          store = PeopleStore();
      final late = Completer<http.StreamedResponse>();
      Map<String, dynamic>? original;
      var posted = false;
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/auth/login')) {
          final email = jsonDecode((r as http.Request).body)['email'] as String;
          return peopleReply(peopleTokens(email.startsWith('b') ? 'B' : 'A'));
        }
        if (r.method == 'POST') {
          original = jsonDecode((r as http.Request).body);
          posted = true;
          return late.future;
        }
        return peopleReply(
          _receipt(original!, 'A', replayed: true),
          status: 201,
        );
      });
      final app = _app(wire, store, folder);
      await app.start(remember: true);
      addTearDown(() async {
        if (!late.isCompleted) {
          late.complete(peopleReply(_receipt(original!, 'A'), status: 201));
        }
        await app.stop();
        await folder.delete(recursive: true);
      });
      final old = await app.openSocial();
      final flight = old.submit(TimewebSocialAction.publish('A original'));
      final failure = expectLater(flight, throwsA(isA<TimewebAuthException>()));
      while (!posted) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await app.login(email: 'b@example.invalid', password: 'fixture');
      late.complete(peopleReply(_receipt(original!, 'A'), status: 201));
      await failure;
      expect(() => old.pendingAction, throwsA(isA<AppSessionException>()));
      final other = await app.openSocial();
      expect(other.needsCheck, isFalse);
      other.close();
      await app.login(email: 'a@example.invalid', password: 'fixture');
      final restored = await app.openSocial();
      expect(restored.pendingAction!.payload['text'], 'A original');
      expect(await restored.check(), TimewebSocialOutcome.confirmed);
      expect(
        wire.calls.where(
          (r) =>
              r.url.path == '/v1/runtime/social/actions' && r.method == 'POST',
        ),
        hasLength(1),
      );
      restored.close();
      old.close();
    },
  );
}
