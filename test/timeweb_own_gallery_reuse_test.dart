import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_gallery.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 160 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'own gallery More renews an expired cursor and keeps the next page reachable',
    (tester) async {
      var clock = peopleNow, pages = 0, originals = 0;
      final limits = <int>[];
      final wire = PeopleWire((request) async {
        if (request.url.path.endsWith('/photos')) {
          pages++;
          expect(
            request.url.queryParameters.containsKey('cursor'),
            isFalse,
            reason:
                'Expired cursor must not reach HTTP; recovery requests fresh metadata',
          );
          final limit = int.parse(request.url.queryParameters['limit']!);
          limits.add(limit);
          return peopleReply(
            photoPage('A', [
              for (var i = 0; i < limit; i++)
                photoDescriptor(
                  i,
                  reference: 'Opaque_generation_${pages}_photo_$i',
                ),
            ], limit == 6 ? null : 'Opaque_next_3'),
          );
        }
        if (request.url.path.endsWith('/content')) {
          originals++;
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
        clock: () => clock,
        currentOwnProfileEnabled: true,
      );
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: TimewebOwnProfileGallery(
                  runtime: runtime,
                  targetUid: 'A',
                  portraitBuilder: (photo) =>
                      SizedBox(height: 180, child: photo),
                  abovePhotos: const SizedBox(),
                  belowPhotos: const [],
                ),
              ),
            ),
          ),
        );
        bool ready() =>
            find
                .byKey(const ValueKey('timeweb-photo-primary'))
                .evaluate()
                .isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty;
        await _until(tester, ready);
        expect(originals, 3);
        clock = clock.add(const Duration(seconds: 61));
        final more = find.byKey(const ValueKey('timeweb-photo-more'));
        await tester.ensureVisible(more);
        await tester.pump();
        await tester.tap(more);
        await tester.pump();
        await _until(tester, () => pages == 2 && ready());
        expect(limits, [3, 6]);
        expect(originals, 9);
        expect(find.text('Фото недоступно'), findsNothing);
        expect(find.byKey(const ValueKey('timeweb-photo-more')), findsNothing);
        final last = find.byKey(const ValueKey('timeweb-photo-select-5'));
        final strip = find
            .descendant(
              of: find.byType(TimewebOwnProfileGallery),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(last, 100, scrollable: strip);
        await tester.pump();
        expect(last.hitTestable(), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var stopped = false;
        final stop = runtime.stop().then((_) => stopped = true);
        await _until(tester, () => stopped);
        await stop;
      }
    },
  );
  testWidgets(
    'own gallery pages all twenty photos and selects ready pixels while cold download is pending',
    (tester) async {
      var clock = peopleNow, pages = 0, originals = 0, thirdHeld = false;
      final limits = <int>[];
      final third = Completer<void>();
      final wire = PeopleWire((request) async {
        if (request.url.path.endsWith('/photos')) {
          pages++;
          final limit = int.parse(request.url.queryParameters['limit']!);
          limits.add(limit);
          final cursor = request.url.queryParameters['cursor'];
          final start = cursor == null ? 0 : int.parse(cursor.split('_').last);
          final end = (start + limit).clamp(0, 20);
          return peopleReply(
            photoPage('A', [
              for (var i = start; i < end; i++)
                photoDescriptor(i, reference: 'Opaque_pass_${pages}_photo_$i'),
            ], end == 20 ? null : 'Opaque_more_$end'),
          );
        }
        if (request.url.path.endsWith('/content')) {
          originals++;
          if (pages == 1 &&
              request.url.queryParameters['reference']!.endsWith('_2')) {
            thirdHeld = true;
            await third.future;
          }
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
        clock: () => clock,
        currentOwnProfileEnabled: true,
      );
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: TimewebOwnProfileGallery(
                  runtime: runtime,
                  targetUid: 'A',
                  portraitBuilder: (photo) =>
                      SizedBox(height: 180, child: photo),
                  abovePhotos: const SizedBox(),
                  belowPhotos: const [],
                ),
              ),
            ),
          ),
        );
        final primary = find.byKey(const ValueKey('timeweb-photo-primary'));
        bool ready() =>
            primary.evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty;
        await _until(tester, () => thirdHeld);
        expect(originals, 3);
        expect(limits, [3]);
        final initial = tester.widget<RawImage>(primary).image!;
        final second = find.byKey(const ValueKey('timeweb-photo-select-1'));
        expect(
          find.descendant(of: second, matching: find.byType(RawImage)),
          findsOneWidget,
        );
        await tester.tap(second);
        await tester.pump();
        await _until(
          tester,
          () => !tester.widget<RawImage>(primary).image!.isCloneOf(initial),
        );
        expect(
          find.byType(LinearProgressIndicator),
          findsOneWidget,
          reason:
              'The third download is still held while a ready original is selected',
        );
        expect(
          originals,
          3,
          reason: 'Ready selection must not start another GET',
        );
        third.complete();
        await _until(tester, ready);
        expect(
          find.byKey(const ValueKey('timeweb-photo-select-3')),
          findsNothing,
        );
        while (originals < 20) {
          final expected = (originals + 3).clamp(0, 20);
          final more = find.byKey(const ValueKey('timeweb-photo-more'));
          await tester.ensureVisible(more);
          await tester.pump();
          await tester.tap(more);
          await tester.pump();
          await _until(tester, () => originals == expected && ready());
        }
        expect(pages, 7);
        expect(limits, List.filled(7, 3));
        expect(find.byKey(const ValueKey('timeweb-photo-more')), findsNothing);
        final last = find.byKey(const ValueKey('timeweb-photo-select-19'));
        final stripScroll = find
            .descendant(
              of: find.byType(TimewebOwnProfileGallery),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(last, 200, scrollable: stripScroll);
        await tester.ensureVisible(last);
        await tester.pump();
        await tester.tap(last);
        await tester.pump();
        await _until(tester, ready);
        expect(originals, 20);
        final acceptedLast = tester.widget<RawImage>(primary).image!;
        clock = clock.add(const Duration(seconds: 61));
        await tester.tap(last);
        await tester.pump();
        await _until(tester, () => pages == 8 && originals == 40 && ready());
        expect(
          limits.last,
          20,
          reason: 'Fresh recovery includes the selected last ordinal',
        );
        expect(
          tester.widget<RawImage>(primary).image!.isCloneOf(acceptedLast),
          isFalse,
        );
        await tester.scrollUntilVisible(last, 200, scrollable: stripScroll);
        await tester.pump();
        final border =
            tester.widget<Container>(last).decoration! as BoxDecoration;
        expect(
          (border.border! as Border).top.color,
          LrsTheme.peach,
          reason: 'Expiry must preserve the selected twentieth photo',
        );
      } finally {
        if (!third.isCompleted) third.complete();
        await tester.pumpWidget(const SizedBox());
        var stopped = false;
        final stop = runtime.stop().then((_) => stopped = true);
        await _until(tester, () => stopped);
        await stop;
      }
    },
  );
  testWidgets(
    'own gallery reuses accepted recent originals but renews expired references',
    (tester) async {
      var clock = peopleNow, pages = 0, originals = 0;
      final wire = PeopleWire((request) async {
        if (request.url.path.endsWith('/photos')) {
          pages++;
          return peopleReply(
            photoPage('A', [
              for (var i = 0; i < 3; i++)
                photoDescriptor(i, reference: 'Opaque_page_${pages}_photo_$i'),
            ]),
          );
        }
        if (request.url.path.endsWith('/content')) {
          originals++;
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
        clock: () => clock,
        currentOwnProfileEnabled: true,
      );
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: TimewebOwnProfileGallery(
                  runtime: runtime,
                  targetUid: 'A',
                  portraitBuilder: (photo) =>
                      SizedBox(height: 180, child: photo),
                  abovePhotos: const SizedBox(),
                  belowPhotos: const [],
                ),
              ),
            ),
          ),
        );
        bool ready() =>
            find
                .byKey(const ValueKey('timeweb-photo-primary'))
                .evaluate()
                .isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty;
        await _until(tester, ready);
        expect(pages, 1);
        expect(originals, 3);
        final accepted = tester
            .widget<RawImage>(
              find.byKey(const ValueKey('timeweb-photo-primary')),
            )
            .image!;
        final selectedImages = <int, ui.Image>{0: accepted};
        for (final ordinal in [0, 1, 2, 1, 2]) {
          await tester.tap(
            find.byKey(ValueKey('timeweb-photo-select-$ordinal')),
          );
          await tester.pump();
          await _until(tester, ready);
          expect(
            originals,
            3,
            reason:
                'An accepted current portrait or recent thumbnail already owns its decoded original',
          );
          expect(find.text('Фото недоступно'), findsNothing);
          final current = tester
              .widget<RawImage>(
                find.byKey(const ValueKey('timeweb-photo-primary')),
              )
              .image!;
          final previous = selectedImages[ordinal];
          if (previous != null) {
            expect(
              current.isCloneOf(previous),
              isTrue,
              reason:
                  'Reuse decoded pixels as well as avoiding another download',
            );
          }
          selectedImages[ordinal] = current;
        }
        expect(
          accepted.debugDisposed,
          isTrue,
          reason:
              'Replaced portrait handles are released while independent cache handles remain valid',
        );

        // An evicted image still uses a real authorized GET, rather than growing
        // an unbounded cache or treating its low resolution thumbnail as original.
        await tester.tap(find.byKey(const ValueKey('timeweb-photo-select-0')));
        await tester.pump();
        await _until(tester, ready);
        expect(originals, 4);

        // Cached pixels do not extend the server's sixty-second reference lease.
        clock = clock.add(const Duration(seconds: 61));
        await tester.tap(find.byKey(const ValueKey('timeweb-photo-select-2')));
        await tester.pump();
        await _until(tester, () => pages == 2 && ready());
        expect(originals, 7);
        expect(
          tester
              .widget<RawImage>(
                find.byKey(const ValueKey('timeweb-photo-primary')),
              )
              .image!
              .isCloneOf(selectedImages[2]!),
          isFalse,
          reason: 'Fresh authorized metadata receives freshly verified pixels',
        );
        expect(find.text('Фото недоступно'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var stopped = false;
        final stop = runtime.stop().then((_) => stopped = true);
        await _until(tester, () => stopped);
        await stop;
      }
    },
  );
}
