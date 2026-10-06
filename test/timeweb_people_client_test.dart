import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_auth_client.dart';

import 'support/timeweb_people_fixtures.dart';

TimewebAuthClient _client(
  PeopleWire wire, {
  PeopleStore? store,
  bool enabled = true,
  Duration deadline = const Duration(seconds: 2),
  DateTime Function()? clock,
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
  requestDeadline: deadline,
);
Matcher _error(TimewebAuthError error) =>
    isA<TimewebAuthException>().having((e) => e.error, 'error', error);
Future<void> _tick(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'default-off and exact filter catalog bounds refuse before HTTP',
    () async {
      final wire = PeopleWire((_) async => peopleReply(directoryReply([])));
      final client = _client(wire, enabled: false);
      await client.restore();
      final filters = await TimewebPeopleFilters.fromCatalog();
      await expectLater(
        client.readPeople(filters),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      await expectLater(
        client.readPerson('B'),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      for (final args in [
        () => TimewebPeopleFilters.fromCatalog(limit: 31),
        () => TimewebPeopleFilters.fromCatalog(limit: 0),
        () => TimewebPeopleFilters.fromCatalog(minAge: 17),
        () => TimewebPeopleFilters.fromCatalog(maxAge: 101),
        () => TimewebPeopleFilters.fromCatalog(minAge: 80, maxAge: 30),
        () => TimewebPeopleFilters.fromCatalog(countryCode: 'ru'),
        () => TimewebPeopleFilters.fromCatalog(countryCode: ''),
        () => TimewebPeopleFilters.fromCatalog(region: 'Республика Адыгея'),
        () => TimewebPeopleFilters.fromCatalog(countryCode: 'RU', region: ''),
        () => TimewebPeopleFilters.fromCatalog(
          countryCode: 'RU',
          region: 'unknown',
        ),
        () => TimewebPeopleFilters.fromCatalog(pol: 'Ж'),
        () => TimewebPeopleFilters.fromCatalog(compatibleGroup: ' БЕЛАЯ '),
      ]) {
        await expectLater(args(), throwsArgumentError);
      }
      expect(wire.calls, isEmpty);
      await client.close();
    },
  );

  test(
    'exact native filtered paging accepts sparse continuation, nullable detail and original bytes',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/runtime/people/Z') {
          expect(request.url.hasQuery, isFalse);
          return peopleReply(
            personReply(
              publicPerson('Z', name: ' \n', age: null, details: true),
            ),
          );
        }
        if (request.url.queryParameters.containsKey('cursor')) {
          return peopleReply(
            directoryReply([publicPerson('Z', name: '', stamp: null)]),
          );
        }
        return pending.future;
      });
      final client = _client(wire);
      await client.restore();
      final filters = await TimewebPeopleFilters.fromCatalog(
        limit: 2,
        minAge: 21,
        maxAge: 40,
        countryCode: 'RU',
        region: 'Республика Адыгея',
        pol: 'ж',
        compatibleGroup: 'белая',
      );
      final a = client.readPeople(filters), b = client.readPeople(filters);
      await _tick(() => wire.calls.length == 1);
      pending.complete(
        peopleReply(directoryReply([], 'Encrypted_synthetic_next')),
      );
      final page = await a;
      expect(identical(page, await b), isTrue);
      expect(page.items, isEmpty);
      final call = wire.calls.single;
      expect(call.method, 'GET');
      expect(call.followRedirects, isFalse);
      expect(call.url.path, '/v1/runtime/people');
      expect(call.headers['Authorization'], 'Bearer na1.A.first');
      expect(call.url.queryParameters, {
        'limit': '2',
        'minAge': '21',
        'maxAge': '40',
        'countryCode': 'RU',
        'region': 'Республика Адыгея',
        'pol': 'ж',
        'compatibleGroup': 'белая',
      });
      expect(page.nextCursor.toString(), isNot(contains('synthetic')));
      final next = await client.readPeople(filters, cursor: page.nextCursor);
      expect(next.items.single.fullName, '');
      expect(next.items.single.lastOnlineAt, isNull);
      expect(next.items.single.avatar, isNull);
      expect(next.items.single.mediaReady, isFalse);
      expect(() => next.items.clear(), throwsUnsupportedError);
      final person = await client.readPerson('Z');
      expect(person.age, isNull);
      expect(person.deti, isNull);
      expect(person.fullName, ' \n');
      expect(person.about, '  Full\noriginal details  ');
      expect(person.hobbi, '');
      expect(person.hasDetails, isTrue);
      expect(person.toString(), isNot(contains('original')));
      await client.close();
      expect(
        () => person.about,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
    },
  );

  test(
    'cursor binds filters, limit, native owner and five-minute window; restart starts fresh',
    () async {
      var clock = peopleNow;
      final wire = PeopleWire(
        (_) async => peopleReply(directoryReply([], 'Encrypted_scanned_uid')),
      );
      final client = _client(wire, clock: () => clock);
      await client.restore();
      final filters = await TimewebPeopleFilters.fromCatalog();
      final cursor = (await client.readPeople(filters)).nextCursor!;
      for (final altered in [
        await TimewebPeopleFilters.fromCatalog(limit: 1),
        await TimewebPeopleFilters.fromCatalog(minAge: 19),
        await TimewebPeopleFilters.fromCatalog(pol: 'м'),
      ]) {
        await expectLater(
          client.readPeople(altered, cursor: cursor),
          throwsA(_error(TimewebAuthError.invalidRequest)),
        );
      }
      final restarted = _client(wire);
      await restarted.restore();
      await expectLater(
        restarted.readPeople(filters, cursor: cursor),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      clock = clock.add(const Duration(minutes: 5));
      await expectLater(
        client.readPeople(filters, cursor: cursor),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(wire.calls.length, 1);
      await restarted.readPeople(filters);
      expect(
        wire.calls.last.url.queryParameters.containsKey('cursor'),
        isFalse,
      );
      await client.close();
      await restarted.close();
    },
  );

  test(
    'HTTP/schema/order/private fields/media/budget fail closed without exposing error bodies',
    () async {
      final filters = await TimewebPeopleFilters.fromCatalog(limit: 2);
      final malformed = <Object>[
        directoryReply([publicPerson('A')]),
        directoryReply([publicPerson('Z'), publicPerson('B')]),
        directoryReply([publicPerson('B'), publicPerson('B')]),
        directoryReply([publicPerson('B')..['age'] = null]),
        directoryReply([publicPerson('B')..['fullName'] = 'bad\u0000text']),
        directoryReply([
          publicPerson('B')..['avatar'] = 'https://media.invalid/a',
        ]),
        directoryReply([
          publicPerson('B')..['email'] = 'private@example.invalid',
        ]),
        directoryReply([publicPerson('B')..['mediaReady'] = true]),
        directoryReply([
          publicPerson('B')..['lastOnlineAt'] = '2026-10-02T12:00:00Z',
        ]),
        directoryReply([publicPerson('B')..['age'] = 28.0]),
        directoryReply([publicPerson('B')..['fullName'] = 'x' * 65537]),
        directoryReply([])..['balance'] = 0,
        directoryReply([])..['ordering'] = 'source',
      ];
      var current = peopleReply(malformed.first);
      final wire = PeopleWire((_) async => current);
      final client = _client(wire);
      await client.restore();
      for (final body in malformed) {
        current = peopleReply(body);
        await expectLater(
          client.readPeople(filters),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
      for (final headers in [
        {'cache-control': 'public,no-store'},
        {'cache-control': 'private'},
        {'content-type': 'text/plain'},
        {'content-encoding': 'gzip'},
      ]) {
        current = peopleReply(directoryReply([]), headers: headers);
        await expectLater(
          client.readPeople(filters),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
      current = peopleReply(directoryReply([]), length: 65537);
      await expectLater(
        client.readPeople(filters),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      current = peopleReply(personReply(publicPerson('C', details: true)));
      await expectLater(
        client.readPerson('B'),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      current = peopleReply({'secret': 'private'}, status: 404);
      await expectLater(
        client.readPerson('B'),
        throwsA(isA<TimewebPersonNotFound>()),
      );
      current = peopleReply({'secret': 'private'}, status: 400);
      await expectLater(
        client.readPeople(filters),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      current = peopleReply({'secret': 'private'}, status: 503);
      await expectLater(
        client.readPerson('B'),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      await client.close();
    },
  );

  test(
    'current token refresh and A-to-B invalidate late list/detail and all retained DTOs',
    () async {
      final list = Completer<http.StreamedResponse>(),
          detail = Completer<http.StreamedResponse>();
      var defer = false, first = true;
      var expectedBearer = 'Bearer na1.A.rotated';
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          return peopleReply(peopleTokens('A'));
        }
        if (request.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        if (defer) {
          return request.url.path.endsWith('/C') ? detail.future : list.future;
        }
        if (first) {
          first = false;
          return peopleReply({}, status: 401);
        }
        expect(request.headers['Authorization'], expectedBearer);
        return peopleReply(directoryReply([publicPerson('Z')]));
      });
      final client = _client(wire);
      await client.restore();
      final filters = await TimewebPeopleFilters.fromCatalog();
      final old = await client.readPeople(filters);
      final row = old.items.single;
      expect(
        wire.calls.where((call) => call.url.path == '/v1/auth/refresh').length,
        1,
      );
      defer = true;
      final oldList = client.readPeople(filters),
          oldDetail = client.readPerson('C');
      final listCheck = expectLater(
        oldList,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      final detailCheck = expectLater(
        oldDetail,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _tick(() => wire.calls.length == 5);
      await client.login(
        email: 'B@example.invalid',
        password: 'synthetic',
        deviceId: 'test-device',
      );
      await listCheck;
      await detailCheck;
      expect(
        () => row.fullName,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      list.complete(
        peopleReply(directoryReply([publicPerson('Z', name: 'Late A')])),
      );
      detail.complete(
        peopleReply(
          personReply(publicPerson('C', name: 'Late A', details: true)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      defer = false;
      first = false;
      expectedBearer = 'Bearer na1.B.rotated';
      final current = await client.readPeople(filters);
      expect(current.items.single.uid, 'Z');
      expect(client.currentUid, 'B');
      await client.close();
      expect(client.currentUid, isNull);
    },
  );

  test(
    'one shared four-request transport budget and deadline abort current stream',
    () async {
      final held = List.generate(4, (_) => Completer<http.StreamedResponse>());
      final wire = PeopleWire(
        (request) =>
            held[int.parse(request.url.pathSegments.last.substring(1))].future,
      );
      final client = _client(wire);
      await client.restore();
      final reads = [for (var i = 0; i < 4; i++) client.readPerson('P$i')];
      final checks = [
        for (final read in reads)
          expectLater(read, throwsA(_error(TimewebAuthError.staleSession))),
      ];
      await _tick(() => wire.calls.length == 4);
      await expectLater(
        client.readCurrent(TimewebCurrentReadRequest.chats()),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      expect(wire.calls.length, 4);
      await client.close();
      for (var i = 0; i < 4; i++) {
        held[i].complete(
          peopleReply(personReply(publicPerson('P$i', details: true))),
        );
      }
      await Future.wait(checks);
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final streamWire = PeopleWire(
        (_) async => peopleReply({}, stream: stream.stream),
      );
      final timed = _client(
        streamWire,
        deadline: const Duration(milliseconds: 30),
      );
      await timed.restore();
      await expectLater(
        timed.readPerson('B'),
        throwsA(_error(TimewebAuthError.deadline)),
      );
      await _tick(() => cancelled);
      await stream.close();
      await timed.close();
    },
  );
}
