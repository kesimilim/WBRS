import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_auth_client.dart';

import 'support/timeweb_people_fixtures.dart';
import 'support/timeweb_profile_photos_fixtures.dart';

TimewebAuthClient _client(
  PeopleWire wire, {
  bool enabled = true,
  PeopleStore? store,
  DateTime Function()? clock,
  Duration? mediaDeadline,
}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
    currentReadsEnabled: enabled,
    runtimeWritesEnabled: enabled,
  ),
  secureStore: store ?? PeopleStore(),
  transport: wire,
  clock: clock ?? () => peopleNow,
  requestDeadline: const Duration(seconds: 2),
  mediaRequestDeadline: mediaDeadline ?? const Duration(seconds: 2),
);
Matcher _error(TimewebAuthError error) =>
    isA<TimewebAuthException>().having((e) => e.error, 'error', error);
Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('existing gates and exact target fail before any transfer', () async {
    final wire = PeopleWire((_) async => peopleReply(photoPage('A', [])));
    final disabled = _client(wire, enabled: false);
    await disabled.restore();
    expect(
      () => disabled.openProfilePhotos('A'),
      throwsA(_error(TimewebAuthError.disabled)),
    );
    final client = _client(wire);
    await client.restore();
    for (final target in [
      '',
      '.',
      '..',
      'A/B',
      'A%2FB',
      'A\\B',
      'A\n',
      '\uD800',
    ]) {
      expect(
        () => client.openProfilePhotos(target),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
    }
    expect(wire.calls, isEmpty);
    await disabled.close();
    await client.close();
  });

  test(
    'real wire exact DTO, scoped coalescing, explicit gallery paging and copied bytes',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final wire = PeopleWire((request) async {
        if (request.url.path.endsWith('/content')) return photoContent();
        if (request.url.queryParameters.containsKey('cursor')) {
          return peopleReply(photoPage('B', [photoDescriptor(2)]));
        }
        return pending.future;
      });
      final client = _client(wire);
      await client.restore();
      final reader = client.openProfilePhotos('B');
      final first = reader.photos(), duplicate = reader.photos();
      await _until(() => wire.calls.length == 1);
      pending.complete(
        peopleReply(
          photoPage('B', [
            photoDescriptor(0),
            photoDescriptor(1),
          ], 'Opaque_next'),
        ),
      );
      final page = await first;
      expect(identical(page, await duplicate), isTrue);
      expect(wire.calls.single.url.path, '/v1/runtime/people/B/photos');
      expect(wire.calls.single.url.queryParameters, {'limit': '30'});
      expect(wire.calls.single.followRedirects, isFalse);
      expect(wire.calls.single.headers['Authorization'], 'Bearer na1.A.first');
      expect(wire.calls.single.headers['Cache-Control'], 'no-store');
      expect(() => page.items.clear(), throwsUnsupportedError);
      final original = await reader.readOriginal(page.items.first);
      expect(wire.calls.last.url.queryParameters, {
        'reference': 'Opaque_photo_0',
      });
      expect(original.bytes, photoPng());
      final mutated = original.bytes;
      mutated[0] = 0;
      expect(original.bytes[0], 137);
      final next = await reader.photos(cursor: page.nextCursor);
      expect(next.items.single.ordinal, 2);
      expect(next.items.single.isPrimary, isFalse);
      for (final item in [
        reader,
        page,
        page.items.first,
        page.nextCursor,
        original,
      ]) {
        expect('$item', isNot(contains('Opaque_photo')));
        expect('$item', isNot(contains('Opaque_next')));
      }
      await reader.close();
      expect(
        () => original.bytes,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await client.close();
    },
  );

  test(
    'references/cursors bind reader, target, limit and sixty-second lifetime',
    () async {
      var now = peopleNow;
      final wire = PeopleWire(
        (request) async => peopleReply(
          photoPage(request.url.path.contains('/B/') ? 'B' : 'A', [
            photoDescriptor(0),
          ], 'Opaque_next'),
        ),
      );
      final client = _client(wire, clock: () => now);
      await client.restore();
      final a = client.openProfilePhotos('A'),
          b = client.openProfilePhotos('B');
      final page = await a.photos();
      for (final call in [
        b.readOriginal(page.items.first),
        b.photos(cursor: page.nextCursor),
        a.photos(limit: 1, cursor: page.nextCursor),
      ]) {
        await expectLater(
          call,
          throwsA(_error(TimewebAuthError.invalidRequest)),
        );
      }
      now = now.add(const Duration(seconds: 60));
      await expectLater(
        a.readOriginal(page.items.first),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      await expectLater(
        a.photos(cursor: page.nextCursor),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(wire.calls.length, 1);
      await client.close();
    },
  );

  test(
    'strict page shape, exact ordinal, bound and no private/URL fields',
    () async {
      final corrupt = <Map<String, dynamic>>[
        {...photoPage('B', []), 'raw': {}},
        photoPage('other', []),
        photoPage('B', [
          {...photoDescriptor(0), 'url': 'https://example.invalid/secret'},
        ]),
        photoPage('B', [
          {...photoDescriptor(0), 'isPrimary': 1},
        ]),
        photoPage('B', [photoDescriptor(1)]),
        photoPage('B', [photoDescriptor(0, size: 0)]),
        photoPage('B', [photoDescriptor(0, size: 8 * 1024 * 1024 + 1)]),
        photoPage('B', [photoDescriptor(0, mime: 'application/octet-stream')]),
        photoPage('B', [
          photoDescriptor(0, reference: 'https://example.invalid'),
        ]),
        photoPage('B', [], 'Empty_sparse_cursor'),
        photoPage('B', List.generate(31, photoDescriptor)),
      ];
      for (final body in corrupt) {
        final wire = PeopleWire((_) async => peopleReply(body));
        final client = _client(wire);
        await client.restore();
        await expectLater(
          client.openProfilePhotos('B').photos(),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        expect(client.currentUid, 'A');
        await client.close();
      }
    },
  );

  test(
    'JSON64KiB and binary8MiB exact lengths, MIME, no-store and no redirects',
    () async {
      final cases = <http.StreamedResponse Function()>[
        () => http.StreamedResponse(
          Stream.value(photoPng()),
          200,
          headers: {'content-type': 'image/png', 'cache-control': 'no-store'},
        ),
        () => photoContent(length: photoPng().length + 1),
        () =>
            photoContent(bytes: [...photoPng(), 0], length: photoPng().length),
        () => photoContent(bytes: [1], length: photoPng().length),
        () => photoContent(headers: {'content-type': 'image/jpeg'}),
        () => photoContent(headers: {'cache-control': 'public,no-store'}),
        () => photoContent(headers: {'content-encoding': 'gzip'}),
        () => photoContent(headers: {'content-range': 'bytes 0-1/99'}),
        () => photoContent(
          headers: {'location': 'https://example.invalid/secret'},
        ),
        () => photoContent(status: 302),
      ];
      for (final response in cases) {
        final wire = PeopleWire(
          (r) async => r.url.path.endsWith('/content')
              ? response()
              : peopleReply(photoPage('B', [photoDescriptor(0)])),
        );
        final client = _client(wire);
        await client.restore();
        final reader = client.openProfilePhotos('B'),
            page = await reader.photos();
        await expectLater(
          reader.readOriginal(page.items.first),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        expect(client.currentUid, 'A');
        await client.close();
      }
      final wire = PeopleWire(
        (_) async =>
            peopleReply({}, stream: Stream.value(List.filled(65537, 32))),
      );
      final client = _client(wire);
      await client.restore();
      await expectLater(
        client.openProfilePhotos('B').photos(),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      await client.close();
    },
  );

  test(
    'closed404 does not decode body, refresh or clear healthy credentials',
    () async {
      final store = PeopleStore();
      final wire = PeopleWire(
        (_) async => http.StreamedResponse(const Stream.empty(), 404),
      );
      final client = _client(wire, store: store);
      await client.restore();
      await expectLater(
        client.openProfilePhotos('B').photos(),
        throwsA(isA<TimewebProfilePhotoUnavailable>()),
      );
      expect(wire.calls.length, 1);
      expect(store.value?.uid, 'A');
      expect(client.currentUid, 'A');
      await client.close();
    },
  );

  test(
    '401 uses existing refresh once; healthy target404 after refresh stays signed in',
    () async {
      var reads = 0;
      final wire = PeopleWire((r) async {
        if (r.url.path == '/v1/auth/refresh') {
          return peopleReply(peopleTokens('A'));
        }
        reads++;
        return http.StreamedResponse(
          const Stream.empty(),
          reads == 1 ? 401 : 404,
        );
      });
      final client = _client(wire);
      await client.restore();
      await expectLater(
        client.openProfilePhotos('B').photos(),
        throwsA(isA<TimewebProfilePhotoUnavailable>()),
      );
      expect(wire.calls.map((r) => r.url.path), [
        '/v1/runtime/people/B/photos',
        '/v1/auth/refresh',
        '/v1/runtime/people/B/photos',
      ]);
      expect(wire.calls.last.headers['Authorization'], 'Bearer na1.A.rotated');
      expect(client.currentUid, 'A');
      await client.close();
    },
  );

  test(
    'four global transfers include existing reads; close waits actual cancellation before releasing slot',
    () async {
      final cancelDone = Completer<void>();
      var cancelling = 0;
      final streams = List.generate(
        4,
        (_) => StreamController<List<int>>(
          onCancel: () {
            cancelling++;
            return cancelDone.future;
          },
        ),
      );
      var next = 0;
      final wire = PeopleWire(
        (_) async => peopleReply({}, stream: streams[next++].stream),
      );
      final client = _client(wire);
      await client.restore();
      final readers = List.generate(4, (i) => client.openProfilePhotos('B$i'));
      final calls = readers.map((r) => r.photos()).toList();
      final failures = calls
          .map(
            (f) =>
                expectLater(f, throwsA(_error(TimewebAuthError.staleSession))),
          )
          .toList();
      await _until(() => wire.calls.length == 4);
      await expectLater(
        client.readAdminUsers(TimewebAdminUsersRequest()),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      var drained = false;
      final drain = readers.first.close().then((_) {
        drained = true;
      });
      await _until(() => cancelling == 1);
      expect(drained, isFalse);
      await expectLater(
        client.openProfilePhotos('C').photos(),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      for (final reader in readers.skip(1)) {
        unawaited(reader.close());
      }
      await _until(() => cancelling == 4);
      cancelDone.complete();
      await drain;
      await Future.wait(failures);
      await client.close();
    },
  );

  test(
    'late send after reader close is drained, and A data cannot survive real B login',
    () async {
      final late = Completer<http.StreamedResponse>();
      final store = PeopleStore();
      var lateMode = false;
      final wire = PeopleWire((r) async {
        if (r.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        if (lateMode) return late.future;
        return peopleReply(photoPage('C', [photoDescriptor(0)]));
      });
      final client = _client(wire, store: store);
      await client.restore();
      final owner = client.openProfilePhotos('C'), page = await owner.photos();
      lateMode = true;
      final pending = owner.readOriginal(page.items.first);
      final rejection = expectLater(
        pending,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _until(() => wire.calls.length == 2);
      var drained = false;
      final drain = owner.close().then((_) {
        drained = true;
      });
      await rejection;
      expect(drained, isFalse);
      late.complete(photoContent());
      await drain;
      await client.login(
        email: 'b@example.invalid',
        password: 'synthetic-password',
        deviceId: 'synthetic-device',
      );
      expect(client.currentUid, 'B');
      expect(() => page.items, throwsA(_error(TimewebAuthError.staleSession)));
      await client.close();
    },
  );
}
