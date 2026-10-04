import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_gallery.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  String Function()? diagnostic,
}) async {
  for (var i = 0; i < 160 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue, reason: diagnostic?.call());
  expect(tester.takeException(), isNull);
}

void main() {
  for (final heldPastRetry in [false, true]) {
    testWidgets(
      heldPastRetry
          ? 'own gallery waits for actual capacity after four reads remain busy past 600ms'
          : 'own gallery recovers when four unrelated read slots release after 200ms',
      (tester) async {
        var held = 0, completed = 0, metadata = 0, original = 0;
        final release = Completer<void>();
        final wire = PeopleWire((request) async {
          expect(request.method, 'GET');
          if (request.url.path.endsWith('/me/notifications')) {
            held++;
            await release.future;
            return peopleReply({
              'kind': 'native-notifications',
              'items': <Object?>[],
              'nextCursor': null,
            });
          }
          if (request.url.path.endsWith('/photos')) {
            metadata++;
            return peopleReply(photoPage('A', [photoDescriptor(0)]));
          }
          if (request.url.path.endsWith('/content')) {
            original++;
            return photoContent();
          }
          return peopleReply({'error': 'unavailable'}, status: 404);
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
          deviceId: 'synthetic-device',
          expectedSourceSnapshot: 'a' * 64,
          clearLocal: () async {},
          clock: () => peopleNow,
          currentOwnProfileEnabled: true,
        );
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await _until(tester, () => completed == 4);
          await tester.pumpWidget(const SizedBox.shrink());
          var done = false;
          final stop = runtime.stop().then((_) => done = true);
          await _until(tester, () => done);
          await stop;
        });
        await tester.runAsync(() => runtime.start(remember: true));
        final unrelated = [
          for (var limit = 1; limit <= 4; limit++)
            runtime.readNotifications(limit: limit).then((_) => completed++),
        ];
        await _until(tester, () => held == 4);
        if (!heldPastRetry) {
          Timer(const Duration(milliseconds: 200), release.complete);
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: Scaffold(
              body: TimewebOwnProfileGallery(
                runtime: runtime,
                targetUid: 'A',
                portraitBuilder: (photo) =>
                    SizedBox(width: 200, height: 220, child: photo),
                abovePhotos: const SizedBox.shrink(),
                belowPhotos: const [],
              ),
            ),
          ),
        );
        if (heldPastRetry) {
          await tester.pump(const Duration(milliseconds: 600));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          expect(held, 4);
          expect(completed, 0);
          expect(metadata, 0);
          expect(original, 0);
          expect(
            find.text('Фото недоступно'),
            findsNothing,
            reason: 'The sole fresh retry must wait for a real slot release',
          );
          release.complete();
        }
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-photo-primary'))
              .evaluate()
              .isNotEmpty,
          diagnostic: () =>
              'unrelated held=$held completed=$completed; photo metadata=$metadata original=$original; unavailable=${find.text('Фото недоступно').evaluate().length}',
        );
        await Future.wait(unrelated);
        expect(completed, 4);
        expect(
          metadata,
          1,
          reason:
              'First capacity rejection does not send HTTP; second attempt uses one fresh GET',
        );
        expect(original, 1);
        expect(wire.calls.where((r) => r.method != 'GET'), isEmpty);
      },
    );
  }
}
