import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/home/timeweb_home_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/presentation/screens/list_of_users/timeweb_people_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/service/timeweb_photo_upload_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/timeweb_people_fixtures.dart';

const _emptyChats = {
  'kind': 'canonical-current',
  'ordering': 'updated_at_desc_chat_id_asc_null_last',
  'items': <Object?>[],
  'nextCursor': null,
};

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  await tester.pump();
  for (var i = 0; i < 120 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _tab(WidgetTester tester, String name) async {
  await _until(
    tester,
    () => find.byKey(const ValueKey('timeweb-home-loading')).evaluate().isEmpty,
  );
  await tester.tap(find.byKey(ValueKey('timeweb-home-tab-$name')));
  await tester.pump();
}

void main() {
  testWidgets(
    'native gate owns all four home tabs; late A tab read cannot enter B',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('native-home-'),
      ))!;
      final late = Completer<http.StreamedResponse>();
      var holdAChats = false, held = false;
      final ownReads = <String, int>{};
      final directoryReads = <String, int>{};
      final wire = PeopleWire((request) async {
        final path = request.url.path;
        final uid = request.headers['authorization']?.split('.')[1] ?? 'A';
        if (path.endsWith('/auth/login')) {
          final data = jsonDecode((request as http.Request).body);
          return peopleReply(
            peopleTokens(data['email'].toString().startsWith('b') ? 'B' : 'A'),
          );
        }
        expect(request.method, 'GET');
        if (path.endsWith('/me/full-profile')) {
          ownReads.update(uid, (count) => count + 1, ifAbsent: () => 1);
          return peopleReply(peopleOwn(uid));
        }
        if (path == '/v1/runtime/people') {
          directoryReads.update(uid, (count) => count + 1, ifAbsent: () => 1);
          return peopleReply(
            directoryReply([publicPerson('peer-$uid', name: 'Person $uid')]),
          );
        }
        if (path == '/v1/runtime/chats') {
          if (uid == 'A' && holdAChats) {
            held = true;
            return late.future;
          }
          return peopleReply(_emptyChats);
        }
        if (path == '/v1/runtime/events') {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'event_id_asc',
            'items': <Object?>[],
            'nextAfterEventId': null,
          });
        }
        if (path == '/v1/runtime/meetings') {
          return peopleReply({
            'kind': 'canonical-current',
            'ordering': 'starts_at_asc_meeting_id_asc_null_first',
            'scope': 'group',
            'items': <Object?>[],
            'nextCursor': null,
            'mediaReady': false,
          });
        }
        if (path.endsWith('/upload-availability') || path.endsWith('/photos')) {
          return peopleReply({'error': 'photo_unavailable'}, status: 404);
        }
        return peopleReply({'error': 'forbidden'}, status: 403);
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
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        clock: () => peopleNow,
        currentOwnProfileEnabled: true,
        currentChatsEnabled: true,
        profileEditorEnabled: true,
        photoUploadJournal: TimewebPhotoUploadJournal(
          directory: () async => folder,
        ),
        initialProfileJournal: TimewebInitialProfileJournal(
          directory: () async => folder,
        ),
      );
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        if (!late.isCompleted) late.complete(peopleReply(_emptyChats));
        await tester.pumpWidget(const SizedBox.shrink());
        var stopped = false;
        final stopping = app.stop().then((_) => stopped = true);
        await _until(tester, () => stopped);
        await stopping;
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      expect(
        (await tester.runAsync(() => app.start(remember: true)))!.confirmed,
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: TimewebSessionGate(runtime: app),
        ),
      );
      await _until(tester, () => find.textContaining('Person A').evaluate().isNotEmpty);
      expect(find.byType(TimewebHomePage), findsOneWidget);
      final navigation = tester.widget<BottomNavigationBar>(
        find.byKey(const ValueKey('timeweb-home-navigation')),
      );
      expect(navigation.items.map((item) => item.label), [
        'Поиск',
        'Чаты',
        'Встречи',
        'Профиль',
      ]);
      expect(
        find.byKey(const ValueKey('timeweb-people-own-profile')),
        findsNothing,
      );
      await _tab(tester, 'chats');
      await _until(
        tester,
        () => find.byType(TimewebChatsPage).evaluate().isNotEmpty,
      );
      expect(find.byType(TimewebPeoplePageView), findsNothing);
      await _tab(tester, 'meetings');
      await _until(
        tester,
        () =>
            find.byType(TimewebMeetingsPageView).evaluate().isNotEmpty &&
            wire.calls.any(
              (request) => request.url.path == '/v1/runtime/meetings',
            ),
      );
      expect(find.byType(TimewebChatsPage), findsNothing);
      await _tab(tester, 'profile');
      await _until(tester, () => find.text('Own A').evaluate().isNotEmpty);
      await _until(tester, () => find.byKey(const ValueKey('timeweb-open-profile-editor')).evaluate().isNotEmpty);
      await _until(tester, () => find.byKey(const ValueKey('timeweb-photo-append-busy')).evaluate().isEmpty);
      expect(find.byType(TimewebOwnProfilePage), findsOneWidget);
      final before = ownReads['A']!;
      await _tab(tester, 'people');
      await _until(tester, () => find.textContaining('Person A').evaluate().isNotEmpty);
      expect(ownReads['A'], greaterThan(before));
      expect(directoryReads['A'], 2);
      holdAChats = true;
      await _tab(tester, 'chats');
      await _until(tester, () => held);
      expect(
        (await tester.runAsync(
          () => app.login(
            email: 'b@example.invalid',
            password: 'synthetic-password',
          ),
        ))!.confirmed,
        isTrue,
      );
      await _until(tester, () => find.textContaining('Person B').evaluate().isNotEmpty);
      late.complete(peopleReply(_emptyChats));
      await tester.pump();
      expect(find.byType(TimewebHomePage), findsOneWidget);
      expect(find.byType(TimewebChatsPage), findsNothing);
      expect(find.textContaining('Person A'), findsNothing);
      expect(find.text('Own A'), findsNothing);
      expect(app.session.state.identity!.uid, 'B');
      await _tab(tester, 'profile');
      await _until(tester, () => find.text('Own B').evaluate().isNotEmpty);
      await _until(tester, () => find.byKey(const ValueKey('timeweb-open-profile-editor')).evaluate().isNotEmpty);
      await _until(tester, () => find.byKey(const ValueKey('timeweb-photo-append-busy')).evaluate().isEmpty);
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
