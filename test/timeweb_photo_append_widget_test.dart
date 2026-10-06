import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
// ImagePicker's existing platform test seam, resolved by the frozen lockfile.
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/service/timeweb_photo_upload_flow.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

class _Picker extends ImagePickerPlatform {
  int calls = 0;
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    calls++;
    return XFile.fromData(photoPng(), name: 'owned.png', mimeType: 'image/png');
  }
}

Object? _ordered(Object? value) => value is Map
    ? {
        for (final k in (value.keys.cast<String>().toList()..sort()))
          k: _ordered(value[k]),
      }
    : value is List
    ? value.map(_ordered).toList()
    : value;
String _hash(Object value) =>
    crypto.sha256.convert(utf8.encode(jsonEncode(_ordered(value)))).toString();

class _Server {
  int puts = 0, prepares = 0, commits = 0, ownReads = 0, galleryReads = 0;
  bool lostAck = true, hold = false, badAvailability = false;
  final late = Completer<http.StreamedResponse>();
  final receipts = <String, ({Map<String, Object?> data, int status})>{};
  String stamp = peopleStamp;
  String? commitId;
  Map<String, dynamic>? metadata;
  String? mediaId;

  Future<http.StreamedResponse> handle(http.BaseRequest request) async {
    final path = request.url.path;
    final uid =
        (request.headers['authorization'] ?? request.headers['Authorization'])
            ?.split('.')[1] ??
        'A';
    if (path.endsWith('/auth/login')) {
      final fields = jsonDecode((request as http.Request).body);
      return peopleReply(
        peopleTokens(fields['email'].toString().startsWith('b') ? 'B' : 'A'),
      );
    }
    if (path.endsWith('/me/full-profile')) {
      ownReads++;
      final own = peopleOwn(uid);
      (own['profile'] as Map<String, dynamic>)['updatedAt'] = uid == 'A'
          ? stamp
          : peopleStamp;
      return peopleReply(own);
    }
    if (path.endsWith('/upload-availability')) {
      expect(request.url.query, isEmpty);
      expect((request as http.Request).bodyBytes, isEmpty);
      if (uid == 'B') {
        return peopleReply({'error': 'photo_unavailable'}, status: 404);
      }
      return peopleReply({
        'canAppend': true,
        'photoCount': commits == 0 ? 3 : 4,
        'photoLimit': 20,
        'profileAuthority': 'canonical-current-v1',
        if (badAvailability) 'unexpected': true,
      });
    }
    if (path.endsWith('/photos') && request.method == 'GET') {
      galleryReads++;
      return peopleReply(
        photoPage(uid, [
          for (var i = 0; i < (uid == 'A' ? 3 + commits : 3); i++)
            photoDescriptor(i),
        ]),
      );
    }
    if (path.endsWith('/photos/content')) return photoContent();
    if (path.endsWith('/lease')) {
      final fields = metadata!, sha = fields['sha256'] as String;
      return peopleReply({
        'mediaId': mediaId,
        'method': 'PUT',
        'url': Uri.https(
          's3.twcstorage.ru',
          '/synthetic-bucket/clrs-native-profile/${mediaId!.substring(17)}',
          {
            'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
            'X-Amz-Credential': 'SYNTHETICACCESS/20261002/ru-1/s3/aws4_request',
            'X-Amz-Date': '20261002T000000Z',
            'X-Amz-Expires': '60',
            'X-Amz-SignedHeaders':
                'content-length;content-type;host;if-none-match;x-amz-checksum-sha256;x-amz-content-sha256',
            'X-Amz-Signature': 'a' * 64,
          },
        ).toString(),
        'headers': {
          'Content-Type': fields['mimeType'],
          'Content-Length': '${fields['byteSize']}',
          'If-None-Match': '*',
          'x-amz-content-sha256': sha,
          'x-amz-checksum-sha256': base64Encode([
            for (var i = 0; i < 64; i += 2)
              int.parse(sha.substring(i, i + 2), radix: 16),
          ]),
        },
        'expiresAt': '2026-10-02T00:01:00.000000Z',
        ...fields,
      });
    }
    if (request.method == 'PUT') {
      puts++;
      expect((request as http.Request).bodyBytes, photoPng());
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      return peopleReply({}, status: 200);
    }
    if (path.contains('/operations/')) {
      final pieces = path.split('/'), key = '${pieces[4]}/${pieces[5]}';
      final stored = receipts[key]!;
      expect(
        request.url.queryParameters['requestHash'],
        stored.data['requestHash'],
      );
      if (hold && pieces[4] == 'profile.photo.commit.v1') return late.future;
      return peopleReply({
        ...stored.data,
        'replayed': true,
      }, status: stored.status);
    }
    if (request.method == 'POST' &&
        (path.endsWith('/prepare') || path.endsWith('/commit'))) {
      final fields =
          jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      final id = fields.remove('operationId') as String;
      final preparing = path.endsWith('/prepare');
      final op = preparing
          ? 'profile.photo.prepare.v1'
          : 'profile.photo.commit.v1';
      final status = preparing ? 201 : 200;
      late final Map<String, Object?> result;
      if (preparing) {
        prepares++;
        metadata = fields;
        mediaId =
            'tw-profile-photo-${crypto.sha256.convert(utf8.encode('clrs-native-profile-photo-v1\u0000${jsonEncode([uid, id])}'))}';
        result = {
          'mediaId': mediaId,
          ...fields,
          'status': 'pending',
          'profileAuthority': 'canonical-current-v1',
        };
      } else {
        commits++;
        commitId = id;
        expect(uid, 'A');
        stamp = '2026-10-02T12:00:00.000002Z';
        result = {
          'mediaId': mediaId,
          'ready': true,
          'ordinal': 3,
          'isPrimary': false,
          'updatedAt': stamp,
          'profileAuthority': 'canonical-current-v1',
        };
      }
      final data = <String, Object?>{
        'operation': op,
        'operationId': id,
        'requestHash': _hash(fields),
        'state': 'committed',
        'replayed': false,
        'result': result,
        'entityRevision': null,
      };
      receipts['$op/$id'] = (data: data, status: status);
      if (!preparing && lostAck) {
        return peopleReply({'error': 'outcome_unknown'}, status: 503);
      }
      return peopleReply(data, status: status);
    }
    return peopleReply({'error': 'forbidden'}, status: 403);
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));
Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  await tester.pump();
  for (var i = 0; i < 120 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(ready(), isTrue);
}

Future<void> _tap(WidgetTester tester, String value) async {
  await _wait(
    tester,
    () =>
        _key(value).evaluate().isNotEmpty &&
        tester.widget<ButtonStyleButton>(_key(value)).onPressed != null,
  );
  await Scrollable.ensureVisible(tester.element(_key(value)), alignment: .5);
  await tester.pump();
  await tester.tap(_key(value));
  await tester.pump();
}

void main() {
  testWidgets(
    'finished native append: lost ACK, no reread/new pick; A→B/imported refusal; A original READY refresh',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('native-photo-append-'),
      ))!;
      final server = _Server(),
          wire = PeopleWire((request) => server.handle(request));
      var failNextJournal = false;
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
        profileEditorEnabled: true,
        photoUploadJournal: TimewebPhotoUploadJournal(
          directory: () async {
            if (failNextJournal) {
              failNextJournal = false;
              throw const FileSystemException('Fixture journal write refused.');
            }
            return folder;
          },
        ),
        initialProfileJournal: TimewebInitialProfileJournal(
          directory: () async => folder,
        ),
      );
      final picker = _Picker(), previousPicker = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = picker;
      addTearDown(() async {
        ImagePickerPlatform.instance = previousPicker;
        if (!server.late.isCompleted) {
          server.late.complete(
            peopleReply({'error': 'unavailable'}, status: 503),
          );
        }
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
      expect(
        (await tester.runAsync(() => app.start(remember: true)))!.confirmed,
        isTrue,
      );
      server.badAvailability = true;
      await tester.runAsync(
        () => expectLater(
          app.readPhotoUploadAvailability(),
          throwsA(isA<TimewebAuthException>()),
        ),
      );
      server.badAvailability = false;
      Future<void> showOwn() async {
        final snapshot = (await tester.runAsync(
          () => app.readCurrentOwnProfile(),
        ))!;
        await tester.pumpWidget(
          MaterialApp(
            theme: LrsTheme.theme,
            home: TimewebOwnProfilePage(
              key: ValueKey('own:${snapshot.uid}:${app.session.state.epoch}'),
              runtime: app,
              initialProfile: snapshot,
            ),
          ),
        );
      }

      await showOwn();
      await _wait(
        tester,
        () =>
            _key('timeweb-photo-append-add').evaluate().isNotEmpty &&
            _key('timeweb-photo-primary').evaluate().isNotEmpty,
      );
      final initialOwn = server.ownReads, initialGallery = server.galleryReads;
      failNextJournal = true;
      await _tap(tester, 'timeweb-photo-append-add');
      await _wait(
        tester,
        () =>
            picker.calls == 1 &&
            _key('timeweb-photo-append-busy').evaluate().isEmpty,
      );
      expect([server.prepares, server.puts, server.commits], [0, 0, 0]);
      expect(
        [server.ownReads, server.galleryReads],
        [initialOwn, initialGallery],
      );
      await _tap(tester, 'timeweb-photo-append-add');
      await _wait(
        tester,
        () =>
            _key('timeweb-photo-append-check').evaluate().isNotEmpty &&
            _key('timeweb-photo-append-busy').evaluate().isEmpty,
      );
      expect(
        [server.prepares, server.puts, server.commits, picker.calls],
        [1, 1, 1, 2],
      );
      expect(
        [server.ownReads, server.galleryReads],
        [initialOwn, initialGallery],
      );
      expect(_key('timeweb-photo-append-add'), findsNothing);
      server.hold = true;
      await _tap(tester, 'timeweb-photo-append-check');
      await _wait(
        tester,
        () => wire.calls.any(
          (r) => r.url.path.endsWith(
            '/profile.photo.commit.v1/${server.commitId}',
          ),
        ),
      );
      expect(
        (await tester.runAsync(
          () => app.login(
            email: 'b@example.invalid',
            password: 'synthetic-password',
          ),
        ))!.confirmed,
        isTrue,
      );
      await _wait(
        tester,
        () => _key('timeweb-photo-append-check').evaluate().isEmpty,
      );
      final stored =
          server.receipts['profile.photo.commit.v1/${server.commitId}']!;
      server.hold = false;
      server.late.complete(peopleReply({...stored.data, 'replayed': true}));
      await tester.pump();
      expect(app.session.state.identity!.uid, 'B');
      await showOwn();
      await _wait(
        tester,
        () =>
            _key('timeweb-open-profile-editor').evaluate().isNotEmpty &&
            _key('timeweb-photo-primary').evaluate().isNotEmpty &&
            _key('timeweb-photo-append-busy').evaluate().isEmpty,
      );
      expect(_key('timeweb-photo-append-add'), findsNothing);
      expect(_key('timeweb-photo-append-check'), findsNothing);
      expect(picker.calls, 2);
      expect(
        (await tester.runAsync(
          () => app.login(
            email: 'a@example.invalid',
            password: 'synthetic-password',
          ),
        ))!.confirmed,
        isTrue,
      );
      await showOwn();
      await _wait(
        tester,
        () => _key('timeweb-photo-append-check').evaluate().isNotEmpty,
      );
      final beforeOwn = server.ownReads, beforeGallery = server.galleryReads;
      await _tap(tester, 'timeweb-photo-append-check');
      await _wait(
        tester,
        () =>
            server.ownReads > beforeOwn &&
            server.galleryReads > beforeGallery &&
            _key('timeweb-photo-append-add').evaluate().isNotEmpty,
      );
      expect(
        [server.prepares, server.puts, server.commits, picker.calls],
        [1, 1, 1, 2],
      );
      expect(Firebase.apps, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
