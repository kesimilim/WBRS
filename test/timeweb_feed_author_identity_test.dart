import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/feed/timeweb_feed_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_social_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
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
    'refreshed post keeps its actual author rather than old row state',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('feed-author-'),
      ))!;
      var author = 'first';
      final wire = PeopleWire((r) async {
        if (r.url.path == '/v1/runtime/social/feed') {
          return peopleReply({
            'kind': 'native-feed',
            'ordering': 'created_desc_id_desc_null_last',
            'items': [
              {
                'id': 'post-$author',
                'authorUid': author,
                'text': 'Post $author',
                'mediaId': null,
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
        if (r.url.path.startsWith('/v1/runtime/people/') &&
            !r.url.path.endsWith('/photos')) {
          final uid = r.url.pathSegments.last;
          return peopleReply(
            personReply(publicPerson(uid, name: 'Author $uid', details: true)),
          );
        }
        return peopleReply({'error': 'not_found'}, status: 404);
      });
      final runtime = TimewebAppRuntime(
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
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        var stopped = false;
        final stop = runtime.stop().then((_) => stopped = true);
        await _until(tester, () => stopped);
        await stop;
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebFeedPage(runtime: runtime),
        ),
      );
      await _until(
        tester,
        () => find.text('Author first').evaluate().isNotEmpty,
      );
      author = 'second';
      await tester.tap(find.byTooltip('Обновить'));
      await _until(
        tester,
        () => find.text('Post second').evaluate().isNotEmpty,
      );
      await _until(
        tester,
        () => find.text('Author second').evaluate().isNotEmpty,
      );
      expect(find.text('Author first'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
