import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_social_flow.dart';
import 'package:wbrs/presentation/screens/feed/timeweb_feed_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/timeweb_people_fixtures.dart';

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
  testWidgets(
    'two protected feed images, strict HTTP bounds, owner close and late A-to-B',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('post-images-'),
      ))!;
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
      );
      final media = 'tw-post-media-${'a' * 64}',
          media2 = 'tw-post-media-${'b' * 64}';
      var mode = 'normal';
      final late = Completer<http.StreamedResponse>();
      var held = false, refreshes = 0;
      final wire = PeopleWire((r) async {
        final uid = r.headers['authorization']?.split('.')[1] ?? 'A';
        if (r.url.path.endsWith('/auth/login')) {
          return peopleReply(peopleTokens('B'));
        }
        if (r.url.path.endsWith('/auth/refresh')) {
          refreshes++;
          return peopleReply(peopleTokens(uid));
        }
        if (r.url.path.endsWith('/me/full-profile')) {
          return peopleReply(peopleOwn(uid));
        }
        if (r.url.path.endsWith('/social/feed')) {
          return peopleReply({
            'kind': 'native-feed',
            'ordering': 'created_desc_id_desc_null_last',
            'items': [
              for (final pair in [
                ['post-z', media],
                ['post-y', media2],
              ])
                {
                  'id': pair[0],
                  'authorUid': uid,
                  'text': 'Actual native image',
                  'mediaId': pair[1],
                  'createdAt': peopleStamp,
                  'likeCount': 0,
                  'commentCount': 0,
                  'liked': false,
                },
            ],
            'nextCursor': null,
            'canPublish': false,
            'canModerate': false,
          });
        }
        expect(r.method, 'GET');
        expect(r.url.hasQuery, isFalse);
        expect(r.url.path, contains('/v1/runtime/posts/'));
        if (mode == 'hold') {
          held = true;
          return late.future;
        }
        if (mode == 'missing') {
          return peopleReply({'error': 'post_unavailable'}, status: 404);
        }
        return http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: mode == 'oversize'
              ? 5 * 1024 * 1024 + 1
              : bytes.length,
          headers: {
            'content-type': mode == 'mime' ? 'image/gif' : 'image/png',
            'cache-control': mode == 'cache'
                ? 'public,max-age=60'
                : 'private,no-store',
          },
        );
      });
      final app = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: PeopleStore(),
        transport: wire,
        deviceId: 'fixture',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        clock: () => peopleNow,
        currentOwnProfileEnabled: true,
        socialJournal: TimewebSocialJournal(directory: () async => folder),
      );
      await tester.runAsync(() => app.start(remember: true));
      tester.view.physicalSize = const Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        if (!late.isCompleted) {
          late.complete(
            http.StreamedResponse(
              Stream.value(bytes),
              200,
              contentLength: bytes.length,
              headers: {
                'content-type': 'image/png',
                'cache-control': 'private,no-store',
              },
            ),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        var done = false;
        final stop = app.stop().then((_) => done = true);
        await _until(tester, () => done);
        await stop;
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebFeedPage(runtime: app),
        ),
      );
      await _until(
        tester,
        () =>
            find
                .byKey(const ValueKey('timeweb-post-image-post-z'))
                .evaluate()
                .isNotEmpty &&
            find
                .byKey(const ValueKey('timeweb-post-image-post-y'))
                .evaluate()
                .isNotEmpty,
      );
      expect(find.text('Фотографии пока недоступны.'), findsNothing);
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
      final reader = (await tester.runAsync(
        () => app.openPostMedia('post-z', media),
      ))!;
      final result = (await tester.runAsync(() => reader.read()))!;
      expect(result.bytes, bytes);
      await tester.runAsync(() => reader.close());
      expect(() => result.bytes, throwsA(isA<TimewebAuthException>()));
      for (final bad in ['mime', 'oversize', 'cache', 'missing']) {
        mode = bad;
        final r = (await tester.runAsync(
          () => app.openPostMedia('post-z', media),
        ))!;
        Object? failure;
        await tester.runAsync(() async {
          try {
            await r.read();
          } catch (e) {
            failure = e;
          }
          await r.close();
        });
        expect(
          failure,
          bad == 'missing'
              ? isA<TimewebPostMediaUnavailable>()
              : isA<TimewebAuthException>(),
        );
      }
      expect(refreshes, 0);
      expect(app.session.state.identity!.uid, 'A');
      mode = 'hold';
      final pendingReader = (await tester.runAsync(
        () => app.openPostMedia('post-z', media),
      ))!;
      final flight = pendingReader.read();
      Object? lateError;
      unawaited(
        flight.then<void>(
          (_) {},
          onError: (Object e, StackTrace s) {
            lateError = e;
          },
        ),
      );
      await _until(tester, () => held);
      var loginDone = false;
      final login = app
          .login(email: 'b@example.invalid', password: 'fixture')
          .then((_) => loginDone = true);
      await _until(tester, () => loginDone);
      await login;
      late.complete(
        http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: bytes.length,
          headers: {
            'content-type': 'image/png',
            'cache-control': 'private,no-store',
          },
        ),
      );
      await _until(tester, () => lateError != null);
      expect(lateError, isA<TimewebAuthException>());
      await tester.pump();
      expect(
        find.byKey(const ValueKey('timeweb-post-image-post-z')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('timeweb-post-image-post-y')),
        findsNothing,
      );
      var drained = false;
      final drain = pendingReader.close().then((_) => drained = true);
      await _until(tester, () => drained);
      await drain;
      expect(tester.takeException(), isNull);
    },
  );
}
