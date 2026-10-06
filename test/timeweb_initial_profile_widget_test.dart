import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/auth/writing_profile_page/timeweb_initial_profile_page.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/service/timeweb_photo_upload_flow.dart';
import 'package:wbrs/service/timeweb_temperament_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/timeweb_people_fixtures.dart';

final _bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);

class _Picker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => XFile.fromData(_bytes, name: 'synthetic.png', mimeType: 'image/png');
}

Object? _ordered(Object? value) => value is Map
    ? {for (final key in (value.keys.cast<String>().toList()..sort())) key: _ordered(value[key])}
    : value is List
    ? value.map(_ordered).toList()
    : value;
String _hash(Object value) => crypto.sha256.convert(utf8.encode(jsonEncode(_ordered(value)))).toString();
String _media(String uid, String id) =>
    'tw-profile-photo-${crypto.sha256.convert(utf8.encode('clrs-native-profile-photo-v1\u0000${jsonEncode([uid, id])}'))}';

class _Server {
  final receipts = <String, ({Map<String, Object?> reply, int status})>{};
  final metadata = <String, Map<String, dynamic>>{};
  final proofOwners = <String, String>{};
  final profiles = <String, Map<String, dynamic>>{};
  final ready = <String, int>{};
  int prepares = 0, puts = 0, commits = 0, finishes = 0, fullReads = 0;
  bool holdFinishLookup = false;
  final late = Completer<http.StreamedResponse>();
  String? finishId, finishHash;

  Map<String, dynamic> _profile(String uid) => profiles.putIfAbsent(
    uid,
    () => {
      for (final key in (peopleOwn(uid)['profile'] as Map<String, dynamic>).keys)
        key: key == 'profileDetailsSaved' || key == 'isRegistrationEnd'
            ? false
            : key == 'updatedAt'
            ? peopleStamp
            : null,
    },
  );
  void bump(String uid) {
    final profile = _profile(uid);
    profile['updatedAt'] = DateTime.parse(profile['updatedAt']).add(const Duration(microseconds: 1)).toIso8601String();
  }

  Map<String, Object?> _envelope(
    String op,
    String id,
    Map<String, dynamic> payload,
    Map<String, Object?> result, {
    bool replay = false,
  }) => {
    'operation': op,
    'operationId': id,
    'requestHash': _hash(payload),
    'state': 'committed',
    'replayed': replay,
    'result': result,
    'entityRevision': null,
  };
  Future<http.StreamedResponse> handle(http.BaseRequest request) async {
    final path = request.url.path;
    final uid = (request.headers['authorization'] ?? request.headers['Authorization'])?.split('.')[1] ?? 'A';
    if (request.method == 'PUT') {
      puts++;
      expect((request as http.Request).bodyBytes, _bytes);
      return peopleReply({}, status: 200);
    }
    if (path.endsWith('/auth/login')) {
      final body = jsonDecode((request as http.Request).body);
      return peopleReply(peopleTokens(body['email'].toString().startsWith('b') ? 'B' : 'A'));
    }
    if (path.endsWith('/me/full-profile')) {
      fullReads++;
      final profile = _profile(uid);
      return peopleReply({
        'uid': uid,
        'profileExists': true,
        'profile': profile,
        'onboarding': profile['profileDetailsSaved'] == true ? 'test' : 'registration',
        'profileAuthority': 'canonical-current-v1',
        'mediaReady': false,
      });
    }
    if (path.contains('/operations/')) {
      final pieces = path.split('/'), key = '${pieces[4]}/${pieces[5]}';
      final receipt = receipts[key];
      expect(receipt, isNotNull);
      expect(request.url.queryParameters['requestHash'], receipt!.reply['requestHash']);
      final reply = peopleReply({...receipt.reply, 'replayed': true}, status: receipt.status);
      if (pieces[4] == 'profile.finish-registration.v1' && holdFinishLookup) {
        return late.future;
      }
      return reply;
    }
    if (path.endsWith('/lease')) {
      final mid = path.split('/')[6], record = metadata[mid]!;
      expect(proofOwners[mid], uid);
      final sha = record['sha256'] as String;
      final lease = Uri.https('s3.twcstorage.ru', '/synthetic-bucket/clrs-native-profile/${mid.substring(17)}', {
        'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
        'X-Amz-Credential': 'SYNTHETICACCESS/20261002/ru-1/s3/aws4_request',
        'X-Amz-Date': '20261002T000000Z',
        'X-Amz-Expires': '60',
        'X-Amz-SignedHeaders':
            'content-length;content-type;host;if-none-match;x-amz-checksum-sha256;x-amz-content-sha256',
        'X-Amz-Signature': 'a' * 64,
      });
      return peopleReply({
        'mediaId': mid,
        'method': 'PUT',
        'url': lease.toString(),
        'headers': {
          'Content-Type': record['mimeType'],
          'Content-Length': '${record['byteSize']}',
          'If-None-Match': '*',
          'x-amz-content-sha256': sha,
          'x-amz-checksum-sha256': base64Encode([
            for (var i = 0; i < 64; i += 2) int.parse(sha.substring(i, i + 2), radix: 16),
          ]),
        },
        'expiresAt': '2026-10-02T00:01:00.000000Z',
        ...record,
      });
    }
    if (request.method == 'POST' &&
        (path.endsWith('/prepare') || path.endsWith('/commit') || path.endsWith('/registration'))) {
      final body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      final id = body.remove('operationId') as String;
      late final Map<String, Object?> result;
      late final String operation;
      var status = 200;
      if (path.endsWith('/prepare')) {
        prepares++;
        operation = 'profile.photo.prepare.v1';
        status = 201;
        final mid = _media(uid, id);
        metadata[mid] = body;
        proofOwners[mid] = uid;
        result = {'mediaId': mid, ...body, 'status': 'pending', 'profileAuthority': 'canonical-current-v1'};
      } else if (path.endsWith('/commit')) {
        commits++;
        operation = 'profile.photo.commit.v1';
        final ordinal = ready[uid] ?? 0;
        ready[uid] = ordinal + 1;
        bump(uid);
        result = {
          'mediaId': body['mediaId'],
          'ready': true,
          'ordinal': ordinal,
          'isPrimary': ordinal == 0,
          'updatedAt': _profile(uid)['updatedAt'],
          'profileAuthority': 'canonical-current-v1',
        };
      } else {
        finishes++;
        operation = 'profile.finish-registration.v1';
        expect(ready[uid], 3);
        expect(body['photos'], hasLength(3));
        expect(body['expectedUpdatedAt'], _profile(uid)['updatedAt']);
        _profile(uid).addAll(body['changes'] as Map<String, dynamic>);
        _profile(
          uid,
        ).addAll({'country': 'Россия', ...(body['geography'] as Map<String, dynamic>), 'profileDetailsSaved': true});
        bump(uid);
        finishId = id;
        finishHash = _hash(body);
        result = {
          'uid': uid,
          'profileDetailsSaved': true,
          'onboarding': 'test',
          'updatedAt': _profile(uid)['updatedAt'],
          'profileAuthority': 'canonical-current-v1',
        };
      }
      final envelope = _envelope(operation, id, body, result);
      receipts['$operation/$id'] = (reply: envelope, status: status);
      if (commits == 1 && path.endsWith('/commit') || path.endsWith('/registration')) {
        return peopleReply({'error': 'outcome_unknown'}, status: 503);
      }
      return peopleReply(envelope, status: status);
    }
    if (path.endsWith('/admin/users')) return peopleReply({'error': 'forbidden'}, status: 403);
    return peopleReply({'error': 'service_unavailable'}, status: 503);
  }
}

Future<void> _wait(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 120 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(condition(), isTrue);
}

Finder key(String value) => find.byKey(ValueKey(value));
Future<void> _tap(WidgetTester tester, String value) async {
  await tester.pump();
  await _wait(tester, () {
    if (key(value).evaluate().isEmpty) return false;
    final widget = tester.widget(key(value));
    return widget is! ButtonStyleButton || widget.onPressed != null;
  });
  await Scrollable.ensureVisible(tester.element(key(value)), alignment: .5);
  await tester.pump();
  await tester.tap(key(value));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _choose(WidgetTester tester, String field, String value) async {
  await _tap(tester, 'timeweb-initial-$field');
  await tester.pump(const Duration(milliseconds: 350));
  final option = find.text(value);
  if (option.evaluate().isEmpty) {
    await tester.scrollUntilVisible(option, 250, scrollable: find.byType(Scrollable).last, maxScrolls: 60);
  }
  await tester.tap(option.last);
  await tester.pump(const Duration(milliseconds: 350));
}

bool _enabled(WidgetTester tester, String value) => tester.widget<ElevatedButton>(key(value)).onPressed != null;

void main() {
  testWidgets(
    'native blank entry → three actual READY/original checks → unknown finish/recovery saved=true; late A never affects B',
    (tester) async {
      final folder = (await tester.runAsync(() => Directory.systemTemp.createTemp('native-initial-ui-')))!;
      final oldPicker = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = _Picker();
      final server = _Server(), wire = PeopleWire(server.handle);
      final app = TimewebAppRuntime(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://api.example.invalid'),
          enabled: true,
          currentReadsEnabled: true,
          runtimeWritesEnabled: true,
        ),
        secureStore: PeopleStore(),
        transport: wire,
        clock: () => peopleNow,
        deviceId: 'synthetic-device',
        expectedSourceSnapshot: 'a' * 64,
        clearLocal: () async {},
        currentOwnProfileEnabled: true,
        profileEditorEnabled: true,
        currentTemperamentEnabled: true,
        initialProfileJournal: TimewebInitialProfileJournal(directory: () async => folder),
        photoUploadJournal: TimewebPhotoUploadJournal(directory: () async => folder),
        temperamentJournal: TimewebTemperamentJournal(directory: () async => folder),
      );
      addTearDown(() async {
        ImagePickerPlatform.instance = oldPicker;
        if (!server.late.isCompleted) server.late.complete(peopleReply({'error': 'service_unavailable'}, status: 503));
        await tester.pumpWidget(const SizedBox.shrink());
        var stopped = false;
        final stopping = app.stop().then((_) => stopped = true);
        await _wait(tester, () => stopped);
        await stopping;
        await tester.runAsync(() => folder.delete(recursive: true));
      });
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      expect((await tester.runAsync(() => app.start(remember: true)))!.outcome, AppSessionOutcome.confirmed);
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: TimewebSessionGate(runtime: app),
        ),
      );
      await _wait(tester, () => key('timeweb-open-initial-profile').evaluate().isNotEmpty);
      expect(Firebase.apps, isEmpty);
      expect(key('timeweb-open-profile-editor'), findsNothing);
      await _tap(tester, 'timeweb-open-initial-profile');
      await _wait(
        tester,
        () => key('timeweb-initial-add-photo').evaluate().isNotEmpty && _enabled(tester, 'timeweb-initial-add-photo'),
      );
      expect(_enabled(tester, 'timeweb-initial-finish'), isFalse);
      await _tap(tester, 'timeweb-initial-add-photo');
      await _wait(tester, () => server.commits == 1 && find.byType(LinearProgressIndicator).evaluate().isEmpty);
      expect(server.finishes, 0);
      expect(_enabled(tester, 'timeweb-initial-finish'), isFalse);
      final original = server.receipts.keys.singleWhere((value) => value.startsWith('profile.photo.commit'));
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 400));
      await _wait(tester, () => key('timeweb-open-initial-profile').evaluate().isNotEmpty);
      await _tap(tester, 'timeweb-open-initial-profile');
      await _wait(
        tester,
        () =>
            key('timeweb-initial-check-photo').evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(server.prepares, 1);
      expect(server.puts, 1);
      await _tap(tester, 'timeweb-initial-check-photo');
      await _wait(
        tester,
        () => find.text('Фото: 1/3').evaluate().isNotEmpty && find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(server.receipts.containsKey(original), isTrue);
      expect(server.commits, 1);
      for (var count = 2; count <= 3; count++) {
        await _tap(tester, 'timeweb-initial-add-photo');
        await _wait(
          tester,
          () =>
              find.text('Фото: $count/3').evaluate().isNotEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
      }
      expect(server.prepares, 3);
      expect(server.puts, 3);
      expect(server.commits, 3);
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      for (final item in {
        'fullName': 'Анна A',
        'age': '30',
        'rost': '170',
        'about': 'Подробный рассказ о себе нового участника',
        'hobbi': 'Увлечения и интересы нового участника',
      }.entries) {
        await tester.ensureVisible(key('timeweb-initial-${item.key}'));
        await tester.enterText(key('timeweb-initial-${item.key}'), item.value);
      }
      FocusManager.instance.primaryFocus?.unfocus();
      tester.view.resetViewInsets();
      await tester.pump();
      await _choose(tester, 'country', 'Россия');
      await _choose(tester, 'region', 'Московская область');
      await _choose(tester, 'deti', 'Нет');
      await _choose(tester, 'pol', 'Женский');
      await _choose(tester, 'relationStatus', 'Свободен');
      expect(_enabled(tester, 'timeweb-initial-finish'), isTrue);
      await _tap(tester, 'timeweb-initial-finish');
      await _wait(tester, () => server.finishes == 1 && find.byType(LinearProgressIndicator).evaluate().isEmpty);
      expect(server._profile('A')['profileDetailsSaved'], isTrue);
      expect(key('timeweb-initial-fullName'), findsNothing);
      final readsBeforeCheck = server.fullReads;
      server.holdFinishLookup = true;
      await _tap(tester, 'timeweb-initial-finish');
      await _wait(
        tester,
        () => wire.calls.any((call) => call.url.path.endsWith('/profile.finish-registration.v1/${server.finishId}')),
      );
      expect(server.fullReads, readsBeforeCheck); // Pending finish is lookup only.
      final loginB = await tester.runAsync(() => app.login(email: 'b@example.invalid', password: 'synthetic-password'));
      expect(loginB!.outcome, AppSessionOutcome.confirmed);
      await _wait(tester, () => find.byType(TimewebInitialProfilePage).evaluate().isEmpty);
      expect(find.byType(TimewebInitialProfilePage), findsNothing);
      expect(find.text('Анна A'), findsNothing);
      final receipt = server.receipts['profile.finish-registration.v1/${server.finishId}']!;
      server.holdFinishLookup = false;
      server.late.complete(peopleReply({...receipt.reply, 'replayed': true}));
      await tester.pump();
      expect(app.session.state.identity!.uid, 'B');
      await tester.runAsync(() => app.login(email: 'a@example.invalid', password: 'synthetic-password'));
      await _wait(tester, () => key('timeweb-open-initial-profile').evaluate().isNotEmpty);
      await tester.pump();
      await _wait(tester, () => key('timeweb-open-initial-profile').evaluate().isNotEmpty);
      expect(key('timeweb-open-profile-editor'), findsNothing);
      await _tap(tester, 'timeweb-open-initial-profile');
      await _wait(
        tester,
        () => key('timeweb-initial-finish').evaluate().isNotEmpty && _enabled(tester, 'timeweb-initial-finish'),
      );
      expect(key('timeweb-initial-fullName'), findsNothing);
      expect(key('timeweb-initial-add-photo'), findsNothing);
      await _tap(tester, 'timeweb-initial-finish');
      await _wait(
        tester,
        () =>
            find.byType(TimewebInitialProfilePage).evaluate().isEmpty &&
            key('timeweb-open-temperament').evaluate().isNotEmpty,
      );
      expect(key('timeweb-open-initial-profile'), findsNothing);
      expect(server.finishes, 1);
      expect(server.puts, 3);
      expect(server.commits, 3);
      expect(server.finishHash, receipt.reply['requestHash']);
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
