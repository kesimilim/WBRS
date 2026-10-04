import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/notifications_center/timeweb_notifications_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_gallery.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  String Function()? diagnostic,
}) async {
  for (var i = 0; i < 180 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue, reason: diagnostic?.call());
  expect(tester.takeException(), isNull);
}

bool _photosReady() =>
    find.byKey(const ValueKey('timeweb-photo-primary')).evaluate().length ==
        1 &&
    [0, 1, 2].every(
      (ordinal) =>
          find
              .descendant(
                of: find.byKey(ValueKey('timeweb-photo-select-$ordinal')),
                matching: find.byType(RawImage),
              )
              .evaluate()
              .length ==
          1,
    );

void main() {
  for (final failMetadata in [true, false]) {
    testWidgets(
      'own gallery recovers one resumed ${failMetadata ? 'metadata' : 'second original'} failure, expires refs and clears A for B',
      (tester) async {
        var clock = peopleNow, photoLists = 0, originalReads = 0;
        var recovering = false, renewing = false, holdOriginal = false;
        var originalHeld = false;
        final recovery = Completer<void>(),
            renewal = Completer<void>(),
            lateOriginal = Completer<void>();
        final folder = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('native-gallery-resume-'),
        ))!;
        final wire = PeopleWire((request) async {
          final path = request.url.path;
          if (path.endsWith('/auth/login')) {
            return peopleReply(peopleTokens('B'));
          }
          if (path.endsWith('/me/full-profile')) {
            return peopleReply(peopleOwn('A'));
          }
          if (path.endsWith('/me/notifications')) {
            return peopleReply({
              'kind': 'native-notifications',
              'items': <Object?>[],
              'nextCursor': null,
            });
          }
          if (path.endsWith('/photos')) {
            photoLists++;
            if (failMetadata && photoLists == 2) {
              return peopleReply({'error': 'unavailable'}, status: 503);
            }
            if (photoLists == 3) {
              recovering = true;
              await recovery.future;
            }
            if (photoLists == 4) {
              renewing = true;
              await renewal.future;
            }
            return peopleReply(
              photoPage('A', [
                for (var ordinal = 0; ordinal < 3; ordinal++)
                  photoDescriptor(
                    ordinal,
                    reference: 'opaque_${photoLists}_$ordinal',
                  ),
              ]),
            );
          }
          if (path.endsWith('/content')) {
            originalReads++;
            if (!failMetadata && originalReads == 5) {
              return peopleReply({'error': 'unavailable'}, status: 503);
            }
            if (holdOriginal) {
              originalHeld = true;
              await lateOriginal.future;
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
          currentChatsEnabled: true,
          initialProfileJournal: TimewebInitialProfileJournal(
            directory: () async => folder,
          ),
        );
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          for (final gate in [recovery, renewal, lateOriginal]) {
            if (!gate.isCompleted) gate.complete();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          var done = false;
          final stopping = runtime.stop().then((_) => done = true);
          await _until(tester, () => done);
          await stopping;
          await tester.runAsync(() => folder.delete(recursive: true));
        });
        await tester.runAsync(() => runtime.start(remember: true));
        final own = (await tester.runAsync(runtime.readCurrentOwnProfile))!;
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebOwnProfilePage(runtime: runtime, initialProfile: own),
          ),
        );
        await _until(tester, _photosReady);
        print('gallery initial metadata=$photoLists originals=$originalReads');
        expect(photoLists, 1);
        expect(originalReads, 3);
        await tester.tap(find.byIcon(Icons.menu));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.scrollUntilVisible(
          find.text('Уведомления'),
          200,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('timeweb-profile-drawer-scroll')),
            matching: find.byType(Scrollable),
          ).first,
        );
        final notifications = find.ancestor(
          of: find.text('Уведомления'),
          matching: find.byType(InkWell),
        ).first;
        await Scrollable.ensureVisible(tester.element(notifications), alignment: .5);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(notifications);
        await _until(
          tester,
          () => find.byType(TimewebNotificationsPage).evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 350));
        clock = clock.add(const Duration(milliseconds: 11500));
        await tester.pump(const Duration(milliseconds: 11500));
        expect(
          find.byKey(const ValueKey('timeweb-photo-primary')),
          findsNothing,
        );
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await _until(tester, () => recovering);
        print(
          'gallery recovering metadata=$photoLists originals=$originalReads',
        );
        expect(
          find.byKey(const ValueKey('timeweb-photo-primary')),
          failMetadata ? findsNothing : findsOneWidget,
          reason: 'A later transient original must not erase accepted portrait',
        );
        recovery.complete();
        await _until(
          tester,
          () => photoLists == 3 && _photosReady(),
          diagnostic: () =>
              'metadata=$photoLists originals=$originalReads; primary=${find.byKey(const ValueKey('timeweb-photo-primary')).evaluate().length}',
        );
        expect(
          photoLists,
          3,
          reason: 'Exactly one fresh recovery metadata page',
        );
        expect(originalReads, failMetadata ? 6 : 8);
        print('gallery resumed metadata=$photoLists originals=$originalReads');

        // References stay limited to 60 seconds; an expired selection needs a
        // fresh metadata page, never an expired bearer/ref or persistent URL.
        clock = clock.add(const Duration(seconds: 61));
        final second = find.byKey(const ValueKey('timeweb-photo-select-1'));
        await Scrollable.ensureVisible(tester.element(second), alignment: .5);
        await tester.pump();
        expect(second.hitTestable(), findsOneWidget);
        await tester.tap(second);
        await tester.pump();
        await _until(tester, () => renewing);
        expect(
          find.byKey(const ValueKey('timeweb-photo-primary')),
          findsOneWidget,
          reason: 'Keep own bitmap while fetching a fresh 60-second reference',
        );
        renewal.complete();
        await _until(tester, () => photoLists == 4 && _photosReady());
        expect(photoLists, 4);
        expect(originalReads, failMetadata ? 9 : 11);
        print('gallery renewed metadata=$photoLists originals=$originalReads');

        holdOriginal = true;
        // The accepted recent selection now needs no GET. Exercise late
        // cancellation with the first original, evicted from the bounded RAM.
        final evicted = find.byKey(const ValueKey('timeweb-photo-select-0'));
        await tester.tap(evicted);
        await _until(tester, () => originalHeld);
        print('gallery late original held');
        var changed = false;
        final changing = runtime
            .login(email: 'b@example.invalid', password: 'synthetic-password')
            .then((_) => changed = true);
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('timeweb-photo-primary'))
              .evaluate()
              .isEmpty,
        );
        print('gallery old actor hidden before late release');
        lateOriginal.complete();
        await _until(tester, () => changed);
        await changing;
        await tester.pump();
        expect(runtime.session.currentUid, 'B');
        expect(
          find.byKey(const ValueKey('timeweb-photo-primary')),
          findsNothing,
        );
        expect(find.byType(TimewebOwnProfileGallery), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
