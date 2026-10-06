import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/list_of_users/show/timeweb_person_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/presentation/widgets/timeweb_profile_photos_view.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

TimewebAppRuntime _runtime(PeopleWire wire) => TimewebAppRuntime(
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
  currentChatsEnabled: true,
);
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  await tester.pumpWidget(const SizedBox());
  var settled = false;
  final stop = runtime.stop().then((v) {
    settled = true;
    return v;
  });
  await _until(tester, () => settled);
  expect(await stop, isTrue);
}

Widget _view(TimewebAppRuntime runtime, String target, {Key? key}) =>
    MaterialApp(
      theme: LrsTheme.theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: TimewebProfilePhotosView(
            key: key,
            runtime: runtime,
            targetUid: target,
          ),
        ),
      ),
    );
Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'PNG/JPEG/GIF/static WebP magic and bounded frame dimensions, unknown/animated refusals',
    () {
      expect(profilePhotoDimensions(photoPng(), 'image/png'), (1, 1));
      final jpeg = Uint8List.fromList([
        255,
        216,
        255,
        192,
        0,
        11,
        8,
        0,
        1,
        0,
        1,
        1,
        1,
        17,
        0,
      ]);
      expect(profilePhotoDimensions(jpeg, 'image/jpeg'), (1, 1));
      final gif = Uint8List.fromList([
        71,
        73,
        70,
        56,
        57,
        97,
        1,
        0,
        1,
        0,
        0,
        0,
        0,
        44,
        0,
        0,
        0,
        0,
        1,
        0,
        1,
        0,
        0,
        2,
        2,
        68,
        1,
        0,
        59,
      ]);
      expect(profilePhotoDimensions(gif, 'image/gif'), (1, 1));
      final webp = Uint8List.fromList([
        82,
        73,
        70,
        70,
        18,
        0,
        0,
        0,
        87,
        69,
        66,
        80,
        86,
        80,
        56,
        76,
        5,
        0,
        0,
        0,
        47,
        0,
        0,
        0,
        0,
        0,
      ]);
      expect(profilePhotoDimensions(webp, 'image/webp'), (1, 1));
      final largePng = photoPng();
      largePng.setRange(16, 20, [0, 0, 32, 1]);
      final outsideGif = Uint8List.fromList(gif);
      outsideGif[19] = 2;
      final animatedWebp = Uint8List.fromList([
        82,
        73,
        70,
        70,
        22,
        0,
        0,
        0,
        87,
        69,
        66,
        80,
        86,
        80,
        56,
        88,
        10,
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      for (final item in <(Uint8List, String)>[
        (largePng, 'image/png'),
        (outsideGif, 'image/gif'),
        (animatedWebp, 'image/webp'),
        (photoPng(), 'image/jpeg'),
        (Uint8List.fromList([1, 2, 3]), 'image/webp'),
        (photoPng(), 'image/avif'),
        (photoPng().sublist(0, 30), 'image/png'),
      ]) {
        expect(
          () => profilePhotoDimensions(item.$1, item.$2),
          throwsA(isA<TimewebProfilePhotoUnavailable>()),
        );
      }
    },
  );

  testWidgets(
    'actual first frame decoder checks ownership at every await and disposes stale image',
    (tester) async {
      var calls = 0;
      ui.Image? first;
      await tester.runAsync(() async {
        first = await decodeProfilePhoto(photoPng(), 'image/png', () {
          calls++;
        });
      });
      expect(first!.width, 1);
      expect(first!.height, 1);
      expect(calls, 5);
      first!.dispose();
      for (final staleAt in [2, 3, 4, 5]) {
        var phase = 0;
        await tester.runAsync(() async {
          await expectLater(
            decodeProfilePhoto(photoPng(), 'image/png', () {
              if (++phase == staleAt) {
                throw const TimewebProfilePhotoUnavailable();
              }
            }),
            throwsA(isA<TimewebProfilePhotoUnavailable>()),
          );
        });
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'main only automatic, one explicit gallery, explicit descriptor load-more; no global cache',
    (tester) async {
      var originals = 0, pages = 0;
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/content')) {
          originals++;
          return photoContent();
        }
        pages++;
        return peopleReply(
          r.url.queryParameters.containsKey('cursor')
              ? photoPage('B', [photoDescriptor(2)])
              : photoPage('B', [
                  photoDescriptor(0),
                  photoDescriptor(1),
                ], 'Opaque_next'),
        );
      });
      final runtime = _runtime(wire);
      await tester.runAsync(() => runtime.start(remember: true));
      final before = PaintingBinding.instance.imageCache.currentSize;
      await tester.pumpWidget(_view(runtime, 'B'));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-primary'))
            .evaluate()
            .isNotEmpty,
      );
      expect(originals, 1);
      expect(pages, 1);
      expect(find.byType(Image), findsNothing);
      expect(
        tester
            .widget<RawImage>(
              find.byKey(const ValueKey('timeweb-photo-primary')),
            )
            .fit,
        BoxFit.cover,
      );
      await _tap(tester, 'timeweb-photo-select-1');
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-gallery'))
            .evaluate()
            .isNotEmpty,
      );
      expect(originals, 2);
      expect(find.byType(RawImage), findsNWidgets(2));
      expect(
        tester
            .widget<RawImage>(
              find.byKey(const ValueKey('timeweb-photo-gallery')),
            )
            .fit,
        BoxFit.contain,
      );
      await _tap(tester, 'timeweb-photo-more');
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-select-2'))
            .evaluate()
            .isNotEmpty,
      );
      expect(pages, 2);
      expect(originals, 2);
      await _tap(tester, 'timeweb-photo-select-2');
      await _until(
        tester,
        () =>
            originals == 3 &&
            find
                .byKey(const ValueKey('timeweb-photo-gallery'))
                .evaluate()
                .isNotEmpty,
      );
      expect(find.byType(RawImage), findsNWidgets(2));
      expect(PaintingBinding.instance.imageCache.currentSize, before);
      expect(tester.takeException(), isNull);
      await _stop(tester, runtime);
    },
  );

  testWidgets(
    'current target change aborts pending image and never paints old result',
    (tester) async {
      final late = Completer<http.StreamedResponse>();
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/content')) {
          return r.url.path.contains('/B/') ? late.future : photoContent();
        }
        final uid = r.url.path.contains('/B/') ? 'B' : 'C';
        return peopleReply(photoPage(uid, [photoDescriptor(0)]));
      });
      final runtime = _runtime(wire);
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(
        _view(runtime, 'B', key: const ValueKey('owner')),
      );
      await _until(
        tester,
        () => wire.calls.any(
          (r) => r.url.path == '/v1/runtime/people/B/photos/content',
        ),
      );
      await tester.pumpWidget(
        _view(runtime, 'C', key: const ValueKey('owner')),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-primary'))
            .evaluate()
            .isNotEmpty,
      );
      final image = tester
          .widget<RawImage>(find.byKey(const ValueKey('timeweb-photo-primary')))
          .image;
      late.complete(photoContent());
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      expect(
        identical(
          tester
              .widget<RawImage>(
                find.byKey(const ValueKey('timeweb-photo-primary')),
              )
              .image,
          image,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await _stop(tester, runtime);
    },
  );

  testWidgets(
    'route cover/dispose releases images; resume obtains new fresh descriptors',
    (tester) async {
      var pages = 0;
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/content')) return photoContent();
        pages++;
        return peopleReply(photoPage('B', [photoDescriptor(0)]));
      });
      final runtime = _runtime(wire);
      await tester.runAsync(() => runtime.start(remember: true));
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            body: TimewebProfilePhotosView(runtime: runtime, targetUid: 'B'),
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-primary'))
            .evaluate()
            .isNotEmpty,
      );
      final old = tester
          .widget<RawImage>(find.byKey(const ValueKey('timeweb-photo-primary')))
          .image!;
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covered')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RawImage, skipOffstage: false), findsNothing);
      expect(old.debugDisposed, isTrue);
      nav.currentState!.pop();
      // Do not pump an indeterminate loader through its genuine ten-second
      // transport deadline while the native codec needs real event-loop time.
      await tester.pump(const Duration(milliseconds: 350));
      expect(pages, 2, reason: 'Resume must begin a new descriptor read');
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-primary'))
            .evaluate()
            .isNotEmpty,
      );
      expect(pages, 2);
      await _stop(tester, runtime);
    },
  );

  testWidgets(
    'real A-to-B auth boundary clears rendered A image before B and healthy404 keeps B',
    (tester) async {
      var refused = false;
      final wire = PeopleWire((r) async {
        if (r.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        if (refused) return http.StreamedResponse(const Stream.empty(), 404);
        if (r.url.path.endsWith('/content')) return photoContent();
        return peopleReply(photoPage('C', [photoDescriptor(0)]));
      });
      final runtime = _runtime(wire);
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(_view(runtime, 'C'));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-primary'))
            .evaluate()
            .isNotEmpty,
      );
      final old = tester
          .widget<RawImage>(find.byKey(const ValueKey('timeweb-photo-primary')))
          .image!;
      await tester.runAsync(
        () => runtime.login(
          email: 'b@example.invalid',
          password: 'synthetic-password',
        ),
      );
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(old.debugDisposed, isTrue);
      refused = true;
      await tester.pumpWidget(
        _view(runtime, 'C', key: const ValueKey('B-view')),
      );
      await _until(
        tester,
        () => find.text('Фото недоступно').evaluate().isNotEmpty,
      );
      expect(runtime.session.state.authenticated, isTrue);
      expect(runtime.client.currentUid, 'B');
      expect(tester.takeException(), isNull);
      await _stop(tester, runtime);
    },
  );

  testWidgets(
    'own and public pages really use native photos; sparse profile/media claims stay honest',
    (tester) async {
      final wire = PeopleWire((r) async {
        if (r.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn('A'));
        }
        if (r.url.path == '/v1/runtime/admin/users') {
          return http.StreamedResponse(const Stream.empty(), 403);
        }
        if (r.url.path == '/v1/runtime/people/B') {
          return peopleReply(personReply(publicPerson('B', details: true)));
        }
        if (r.url.path.endsWith('/content')) return photoContent();
        if (r.url.path.endsWith('/photos')) {
          return peopleReply(
            photoPage(r.url.path.contains('/A/') ? 'A' : 'B', [
              photoDescriptor(0),
            ]),
          );
        }
        throw StateError('Unexpected synthetic route');
      });
      final runtime = _runtime(wire);
      await tester.runAsync(() => runtime.start(remember: true));
      final profile = await tester.runAsync(
        () => runtime.readCurrentOwnProfile(),
      );
      expect(profile!.mediaReady, isFalse);
      expect(profile.profile!.rost, isNull);
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebOwnProfilePage(
            runtime: runtime,
            initialProfile: profile,
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-primary'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        wire.calls.any(
          (r) => r.url.path == '/v1/runtime/people/A/photos/content',
        ),
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebPersonPage(runtime: runtime, uid: 'B'),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('timeweb-photo-primary'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        wire.calls.any(
          (r) => r.url.path == '/v1/runtime/people/B/photos/content',
        ),
        isTrue,
      );
      expect(find.text('Own A'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(TimewebProfilePhotosView),
          matching: find.byType(Image),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _stop(tester, runtime);
    },
  );
}
