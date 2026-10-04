import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/service/timeweb_photo_upload_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(condition(), isTrue);
}

Future<List<int>> _pixels(GlobalKey boundaryKey, Rect region) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final data = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    return [
      for (var y = region.top.toInt(); y < region.bottom.toInt(); y++)
        ...data.sublist(
          (y * image.width + region.left.toInt()) * 4,
          (y * image.width + region.right.toInt()) * 4,
        ),
    ];
  } finally {
    image.dispose();
  }
}

void main() {
  testWidgets(
    'own profile keeps the original hero and hides scrolled photo action beneath CLRS',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      final directory = Directory.systemTemp.createTempSync('own-scroll-');
      final wire = PeopleWire((request) async {
        final path = request.url.path;
        if (path.endsWith('/me/full-profile')) {
          return peopleReply(peopleOwn('A'));
        }
        if (path.endsWith('/upload-availability')) {
          return peopleReply({
            'canAppend': true,
            'photoCount': 3,
            'photoLimit': 20,
            'profileAuthority': 'canonical-current-v1',
          });
        }
        if (path.endsWith('/photos/content')) return photoContent();
        if (path.endsWith('/photos')) {
          return peopleReply(
            photoPage('A', [
              photoDescriptor(0),
              photoDescriptor(1),
              photoDescriptor(2),
            ]),
          );
        }
        return peopleReply({'error': 'unavailable'}, status: 503);
      });
      final runtime = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: PeopleStore(),
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        transport: wire,
        clock: () => peopleNow,
        currentOwnProfileEnabled: true,
        profileEditorEnabled: true,
        initialProfileJournal: TimewebInitialProfileJournal(
          directory: () async => directory,
        ),
        photoUploadJournal: TimewebPhotoUploadJournal(
          directory: () async => directory,
        ),
      );
      try {
        await tester.runAsync(() => runtime.start(remember: true));
        final profile = await tester.runAsync(runtime.readCurrentOwnProfile);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: RepaintBoundary(
              key: boundaryKey,
              child: TimewebOwnProfilePage(
                runtime: runtime,
                initialProfile: profile,
              ),
            ),
          ),
        );
        final photo = find.byKey(const ValueKey('timeweb-photo-primary'));
        final button = find.byKey(const ValueKey('timeweb-photo-append-add'));
        await _until(
          tester,
          () =>
              photo.evaluate().isNotEmpty &&
              button.evaluate().isNotEmpty &&
              tester.widget<ElevatedButton>(button).onPressed != null,
        );
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/final_design/family_right.png'),
            boundaryKey.currentContext!,
          ),
        );
        await tester.pumpAndSettle();
        // The original portrait begins behind the transparent brand header.
        expect(tester.getTopLeft(photo).dy, 0);
        final initialHero = await tester.runAsync(
          () => _pixels(boundaryKey, const Rect.fromLTRB(0, 0, 360, 120)),
        );
        await Scrollable.ensureVisible(tester.element(button), alignment: .5);
        await tester.pumpAndSettle();
        final scroll = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(TimewebOwnProfilePage),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        scroll.jumpTo(scroll.pixels + tester.getCenter(button).dy - 160);
        await tester.pumpAndSettle();
        expect(button.hitTestable(), findsOneWidget);
        final unobstructedHeader = await tester.runAsync(
          () => _pixels(boundaryKey, const Rect.fromLTRB(0, 24, 360, 80)),
        );
        // Put the actual enabled action at the same height as the CLRS logo.
        scroll.jumpTo(scroll.pixels + tester.getCenter(button).dy - 40);
        await tester.pumpAndSettle();
        expect(tester.getCenter(button).dy, closeTo(40, .01));
        expect(button.hitTestable(), findsNothing);
        final headerWithActionUnderneath = await tester.runAsync(
          () => _pixels(boundaryKey, const Rect.fromLTRB(0, 24, 360, 80)),
        );
        expect(headerWithActionUnderneath, unobstructedHeader);
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(photo).dy, 0);
        expect(
          await tester.runAsync(
            () => _pixels(boundaryKey, const Rect.fromLTRB(0, 0, 360, 120)),
          ),
          initialHero,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var stopped = false;
        final original = runtime.stop().then((value) {
          stopped = true;
          return value;
        });
        await _until(tester, () => stopped);
        expect(await original, isTrue);
        directory.deleteSync(recursive: true);
      }
    },
  );
}
