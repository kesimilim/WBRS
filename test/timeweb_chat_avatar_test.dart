import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chat_avatar.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
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
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
  expect(tester.takeException(), isNull);
}

Future<void> _stop(WidgetTester tester, TimewebAppRuntime runtime) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var done = false;
  final stop = runtime.stop().then((_) => done = true);
  await _until(tester, () => done);
  await stop;
}

Widget _avatars(
  TimewebAppRuntime runtime,
  int count, {
  bool readGroup = false,
}) => MaterialApp(
  home: Scaffold(
    body: Wrap(
      children: [
        for (var i = 0; i < count; i++)
          TimewebChatAvatar(
            key: ValueKey('avatar-$i'),
            runtime: runtime,
            uid: 'P$i',
            readGroup: readGroup,
          ),
      ],
    ),
  ),
);

String _target(http.BaseRequest request) => request.url.pathSegments[3];

Map<String, dynamic> _chats({String name = 'Peer', int revision = 1}) => {
  'kind': 'canonical-current',
  'ordering': 'updated_at_desc_chat_id_asc_null_last',
  'items': [
    {
      'chatId': 'chat-1',
      'counterpartUid': 'P0',
      'name': name,
      'avatar': null,
      'updatedAt': peopleStamp,
      'lastSequence': 1,
      'revision': revision,
      'readThrough': 0,
      'archived': false,
      'notifications': true,
    },
  ],
  'nextCursor': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'six mounted avatars wait behind four real reads; one released slot drains all without GET replay',
    (tester) async {
      final releases = List.generate(4, (_) => Completer<void>());
      final originalGate = Completer<void>();
      var held = 0, completed = 0, metadata = 0, originals = 0;
      final wire = PeopleWire((request) async {
        if (request.url.path.endsWith('/notifications')) {
          final index = held++;
          await releases[index].future;
          return peopleReply({
            'kind': 'native-notifications',
            'items': [],
            'nextCursor': null,
          });
        }
        if (request.url.path.endsWith('/photos')) {
          metadata++;
          return peopleReply(photoPage(_target(request), [photoDescriptor(0)]));
        }
        originals++;
        await originalGate.future;
        return photoContent();
      });
      final runtime = _runtime(wire);
      addTearDown(() async {
        for (final release in releases) {
          if (!release.isCompleted) release.complete();
        }
        if (!originalGate.isCompleted) originalGate.complete();
        await _until(tester, () => completed == 4);
        await _stop(tester, runtime);
      });
      await tester.runAsync(() => runtime.start(remember: true));
      final holders = [
        for (var i = 1; i <= 4; i++)
          runtime.readNotifications(limit: i).then((_) => completed++),
      ];
      await _until(tester, () => held == 4);
      await tester.pumpWidget(_avatars(runtime, 6));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      expect(metadata, 0);
      releases.first.complete();
      await _until(tester, () => originals == 1);
      expect(metadata, lessThanOrEqualTo(2));
      expect(
        originals,
        1,
        reason:
            'Only one original can occupy the single released transport slot',
      );
      expect(find.byType(RawImage), findsNothing);
      originalGate.complete();
      await _until(tester, () => find.byType(RawImage).evaluate().length == 6);
      expect(metadata, 6);
      expect(originals, 6);
      expect(wire.calls.where((r) => r.method != 'GET'), isEmpty);
      for (final release in releases.skip(1)) {
        release.complete();
      }
      await _until(tester, () => completed == 4);
      await Future.wait(holders);
    },
  );

  testWidgets(
    'failed optional group lookup leaves independently authorized photo available',
    (tester) async {
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/content')) return photoContent();
        if (r.url.path.endsWith('/photos')) {
          return peopleReply(photoPage('P0', [photoDescriptor(0)]));
        }
        return peopleReply({'error': 'unavailable'}, status: 503);
      });
      final runtime = _runtime(wire);
      addTearDown(() => _stop(tester, runtime));
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(_avatars(runtime, 1, readGroup: true));
      await _until(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
      expect(wire.calls.map((r) => r.url.path), [
        '/v1/runtime/people/P0/photos',
        '/v1/runtime/people/P0/photos/content',
        '/v1/runtime/people/P0',
      ]);
      await _stop(tester, runtime);
    },
  );

  for (final boundary in ['B-login', 'stop']) {
    testWidgets('$boundary cancels queued owner and refuses late original', (
      tester,
    ) async {
      final late = Completer<http.StreamedResponse>();
      var originals = 0;
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/login')) {
          return peopleReply(peopleTokens('B'));
        }
        if (r.url.path.endsWith('/content')) {
          originals++;
          return late.future;
        }
        return peopleReply(photoPage(_target(r), [photoDescriptor(0)]));
      });
      final runtime = _runtime(wire);
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(_avatars(runtime, 3));
      await _until(tester, () => originals == 2);
      if (boundary == 'B-login') {
        await tester.runAsync(
          () => runtime.login(
            email: 'b@example.invalid',
            password: 'synthetic-password',
          ),
        );
        expect(runtime.client.currentUid, 'B');
      } else {
        var stopped = false;
        final stop = runtime.stop().then((_) => stopped = true);
        await _until(tester, () => !runtime.session.state.authenticated);
        late.complete(photoContent());
        await _until(tester, () => stopped);
        await stop;
      }
      if (!late.isCompleted) late.complete(photoContent());
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(wire.calls.where((r) => r.url.path.contains('/P2/')), isEmpty);
      await _stop(tester, runtime);
    });
  }

  testWidgets(
    'two active chains and bounded32 pending owners expire without starting queued HTTP',
    (tester) async {
      final gate = Completer<void>();
      var metadata = 0;
      final wire = PeopleWire((r) async {
        metadata++;
        await gate.future;
        return peopleReply(photoPage(_target(r), []));
      });
      final runtime = _runtime(wire);
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(_avatars(runtime, 40));
      await _until(tester, () => metadata == 2);
      await tester.pump(
        runtime.client.requestDeadline + const Duration(milliseconds: 1),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      gate.complete();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      expect(
        metadata,
        2,
        reason: 'Expired or rejected mounted owners must start zero HTTP',
      );
      await _stop(tester, runtime);
    },
  );

  testWidgets(
    'two active chains admit at most32 queued owners after real release',
    (tester) async {
      final gate = Completer<void>();
      var metadata = 0;
      final wire = PeopleWire((r) async {
        metadata++;
        if (metadata <= 2) await gate.future;
        return peopleReply(photoPage(_target(r), []));
      });
      final runtime = _runtime(wire);
      addTearDown(() => _stop(tester, runtime));
      await tester.runAsync(() => runtime.start(remember: true));
      await tester.pumpWidget(_avatars(runtime, 40));
      await _until(tester, () => metadata == 2);
      gate.complete();
      await _until(tester, () => metadata == 34);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      expect(
        metadata,
        34,
        reason:
            'Overflow owners may not create an unbounded delayed request queue',
      );
    },
  );

  testWidgets(
    'chat polling preserves unchanged avatar; explicit refresh and changed person reload fresh metadata',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var metadata = 0, original = 0, chats = 0;
      var changedName = false;
      final wire = PeopleWire((r) async {
        if (r.url.path.endsWith('/chats')) {
          chats++;
          return peopleReply(
            _chats(
              name: changedName ? 'Changed peer' : 'Peer',
              revision: chats,
            ),
          );
        }
        if (r.url.path.endsWith('/events')) {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'event_id_asc',
            'items': r.url.queryParameters.containsKey('afterEventId')
                ? []
                : [
                    {
                      'eventId': 1,
                      'kind': 'chat.message.created.v1',
                      'chatId': 'chat-1',
                      'messageId': 'message-1',
                      'sequence': 1,
                      'senderUid': 'P0',
                      'readerUid': null,
                      'readThroughSequence': null,
                      'chatRevision': 2,
                      'createdAt': peopleStamp,
                    },
                  ],
            'nextAfterEventId': null,
          });
        }
        if (r.url.path.endsWith('/content')) {
          original++;
          return photoContent();
        }
        if (r.url.path.endsWith('/photos')) {
          metadata++;
          return peopleReply(photoPage('P0', [photoDescriptor(0)]));
        }
        return peopleReply(personReply(publicPerson('P0', details: true)));
      });
      final runtime = _runtime(wire);
      await tester.runAsync(() => runtime.start(remember: true));
      final initial = await tester.runAsync(() => runtime.readChats());
      addTearDown(() => _stop(tester, runtime));
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebChatsPage(runtime: runtime, initialPage: initial!),
        ),
      );
      final images = find.descendant(
        of: find.byType(TimewebChatAvatar),
        matching: find.byType(RawImage),
      );
      await _until(tester, () => chats == 2 && images.evaluate().isNotEmpty);
      expect(
        metadata,
        1,
        reason:
            'A current chat event changes chat revision, not its source photo',
      );
      expect(original, 1);
      final first = tester.widget<RawImage>(images).image!;
      await tester.tap(find.byTooltip('Обновить'));
      await _until(tester, () => original == 2 && images.evaluate().isNotEmpty);
      expect(metadata, 2);
      expect(first.debugDisposed, isTrue);
      changedName = true;
      await tester.tap(find.byTooltip('Обновить'));
      await _until(tester, () => original == 3 && images.evaluate().isNotEmpty);
      expect(metadata, 3);
      await _stop(tester, runtime);
    },
  );

  testWidgets(
    'cover decoder fills short side at display DPR and preserves default full view dimensions',
    (tester) async {
      await tester.runAsync(() async {
        for (final dimensions in [(900, 300), (300, 900)]) {
          final recorder = ui.PictureRecorder();
          ui.Canvas(
            recorder,
          ).drawColor(const Color(0xffabcdef), ui.BlendMode.src);
          final picture = recorder.endRecording();
          final source = await picture.toImage(dimensions.$1, dimensions.$2);
          final bytes = (await source.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List();
          source.dispose();
          picture.dispose();
          final small = await decodeProfilePhoto(
            bytes,
            'image/png',
            () {},
            displayPixels: 120,
          );
          final normal = await decodeProfilePhoto(bytes, 'image/png', () {});
          expect((
            small.width,
            small.height,
          ), dimensions.$1 > dimensions.$2 ? (360, 120) : (120, 360));
          expect((normal.width, normal.height), dimensions);
          small.dispose();
          normal.dispose();
        }
      });
    },
  );
}
