import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_auth_client.dart';

import 'support/timeweb_people_fixtures.dart';

Map<String, dynamic> _user(
  String uid, {
  String? email,
  String? name,
  int? age,
  String lifecycle = 'active',
  bool disabled = false,
}) => {
  'uid': uid,
  'email': email,
  'fullName': name,
  'age': age,
  'lifecycle': lifecycle,
  'disabled': disabled,
};
Map<String, dynamic> _page(List<Object?> rows, [String? cursor]) => {
  'kind': 'canonical-admin-users',
  'ordering': 'uid_binary_asc',
  'items': rows,
  'nextCursor': cursor,
};
TimewebAuthClient _client(
  PeopleWire wire, {
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
  secureStore: PeopleStore(),
  transport: wire,
  clock: clock ?? () => peopleNow,
  requestDeadline: deadline,
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
  test('default-off and bounded literal prefix fail before HTTP', () async {
    final wire = PeopleWire((_) async => peopleReply(_page([])));
    final client = _client(wire, enabled: false);
    await client.restore();
    await expectLater(
      client.readAdminUsers(TimewebAdminUsersRequest()),
      throwsA(_error(TimewebAuthError.disabled)),
    );
    for (final query in [
      'a',
      'a' * 101,
      '\u0000prefix',
      'bad\ntext',
      '\uD800',
    ]) {
      expect(() => TimewebAdminUsersRequest(query: query), throwsArgumentError);
    }
    for (final limit in [0, 31]) {
      expect(() => TimewebAdminUsersRequest(limit: limit), throwsArgumentError);
    }
    expect(TimewebAdminUsersRequest(query: '  %_  ').query, '%_');
    expect(TimewebAdminUsersRequest(query: '  ').query, '');
    expect(wire.calls, isEmpty);
    await client.close();
  });

  test(
    'deduplicated GET, sparse paging, original nullable types, actor row and redacted models',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final wire = PeopleWire((request) async {
        if (request.url.queryParameters.containsKey('cursor')) {
          return peopleReply(
            _page([
              _user(
                'A',
                email: 'straße-a@example.invalid',
                name: ' \n',
                age: null,
              ),
              _user(
                'B',
                email: 'straße-b@example.invalid',
                name: '',
                age: 0,
                lifecycle: 'deleted',
                disabled: true,
              ),
            ]),
          );
        }
        return pending.future;
      });
      final client = _client(wire);
      await client.restore();
      final request = TimewebAdminUsersRequest(query: '  Straße  ', limit: 2);
      final first = client.readAdminUsers(request),
          duplicate = client.readAdminUsers(request);
      await _until(() => wire.calls.length == 1);
      pending.complete(peopleReply(_page([], 'Encrypted_sparse_cursor')));
      final page = await first;
      expect(identical(page, await duplicate), isTrue);
      expect(page.items, isEmpty);
      expect(wire.calls.single.url.path, '/v1/runtime/admin/users');
      expect(wire.calls.single.url.queryParameters, {
        'limit': '2',
        'query': 'Straße',
      });
      expect(wire.calls.single.method, 'GET');
      expect(wire.calls.single.followRedirects, isFalse);
      expect(wire.calls.single.headers['Authorization'], 'Bearer na1.A.first');
      expect(wire.calls.single.headers['Cache-Control'], 'no-store');
      final next = await client.readAdminUsers(
        request,
        cursor: page.nextCursor,
      );
      expect(next.items.first.uid, 'A');
      expect(next.items.first.age, isNull);
      expect(next.items.first.fullName, ' \n');
      expect(next.items.last.fullName, '');
      expect(next.items.last.age, 0);
      expect(next.items.last.disabled, isTrue);
      expect(() => next.items.clear(), throwsUnsupportedError);
      for (final value in [request, page, page.nextCursor, next.items.first]) {
        expect('$value', isNot(contains('synthetic-admin')));
        expect('$value', isNot(contains('Straße')));
        expect('$value', isNot(contains('Encrypted_sparse')));
      }
      await client.close();
    },
  );

  test(
    'cursor binds exact prefix, limit, native owner and conservative 300s expiry',
    () async {
      var clock = peopleNow;
      final wire = PeopleWire(
        (_) async => peopleReply(_page([], 'Opaque_cursor')),
      );
      final client = _client(wire, clock: () => clock);
      await client.restore();
      final request = TimewebAdminUsersRequest(query: 'Na');
      final cursor = (await client.readAdminUsers(request)).nextCursor!;
      for (final changed in [
        TimewebAdminUsersRequest(query: 'na'),
        TimewebAdminUsersRequest(query: 'Na', limit: 1),
        TimewebAdminUsersRequest(),
      ]) {
        await expectLater(
          client.readAdminUsers(changed, cursor: cursor),
          throwsA(_error(TimewebAuthError.invalidRequest)),
        );
      }
      final other = _client(wire);
      await other.restore();
      await expectLater(
        other.readAdminUsers(request, cursor: cursor),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      clock = clock.add(const Duration(seconds: 300));
      await expectLater(
        client.readAdminUsers(request, cursor: cursor),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(wire.calls.length, 1);
      await client.close();
      await other.close();
    },
  );

  test(
    '403 is typed without refresh/logout; ordinary current profile remains usable',
    () async {
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/runtime/me/full-profile') {
          return peopleReply(peopleOwn('A'));
        }
        return peopleReply({'secret': 'must never be decoded'}, status: 403);
      });
      final client = _client(wire);
      await client.restore();
      await expectLater(
        client.readAdminUsers(TimewebAdminUsersRequest()),
        throwsA(isA<TimewebAdminAccessDenied>()),
      );
      expect(client.currentUid, 'A');
      expect(client.hasSession, isTrue);
      expect((await client.readCurrentOwnProfile()).uid, 'A');
      expect(wire.calls.where((r) => r.url.path.contains('/auth/')), isEmpty);
      await client.close();
    },
  );

  test(
    '401 refreshes once; repeated native 401 invalidates rather than becomes role denial',
    () async {
      var reads = 0, denyAgain = false;
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          return peopleReply(peopleTokens('A'));
        }
        reads++;
        if (reads == 1 || denyAgain) return peopleReply({}, status: 401);
        expect(request.headers['Authorization'], 'Bearer na1.A.rotated');
        return peopleReply(_page([]));
      });
      final client = _client(wire);
      await client.restore();
      await client.readAdminUsers(TimewebAdminUsersRequest());
      expect(reads, 2);
      expect(
        wire.calls.where((r) => r.url.path == '/v1/auth/refresh').length,
        1,
      );
      denyAgain = true;
      await expectLater(
        client.readAdminUsers(TimewebAdminUsersRequest()),
        throwsA(isA<TimewebAuthException>()),
      );
      expect(client.hasSession, isFalse);
      expect(reads, 4);
      await client.close();
    },
  );

  test(
    'exact DTO/order/types/HTTP privacy and 64KiB body bounds refuse safely',
    () async {
      var response = peopleReply(_page([]));
      final wire = PeopleWire((_) async => response);
      final client = _client(wire);
      await client.restore();
      final request = TimewebAdminUsersRequest(limit: 2);
      final invalid = [
        _page([_user('B'), _user('A')]),
        _page([_user('A'), _user('A')]),
        _page([_user('bad/uid')]),
        _page([_user('.')]),
        _page([_user('A')..['email'] = 'UPPER@example.invalid']),
        _page([_user('A')..['email'] = 'bad\n@example.invalid']),
        _page([_user('A')..['age'] = 28.0]),
        _page([_user('A')..['age'] = true]),
        _page([_user('A')..['disabled'] = 1]),
        _page([_user('A')..['lifecycle'] = 'enabled']),
        _page([_user('A')..['role'] = 'admin']),
        _page([_user('A')..['raw'] = {}]),
        _page([_user('A')..['fullName'] = 'x' * 1001]),
        _page([_user('A')..['fullName'] = 'bad\u0000name']),
        _page([_user('A'), _user('B'), _user('C')]),
        _page([])..['nextCursor'] = 'bad + cursor',
        _page([])..['ordering'] = 'source',
        _page([])..['kind'] = 'canonical-current',
      ];
      for (final body in invalid) {
        response = peopleReply(body);
        await expectLater(
          client.readAdminUsers(request),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
      for (final headers in [
        {'cache-control': 'public,no-store'},
        {'cache-control': 'private'},
        {'content-type': 'text/html'},
        {'content-encoding': 'gzip'},
      ]) {
        response = peopleReply(_page([]), headers: headers);
        await expectLater(
          client.readAdminUsers(request),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
      response = peopleReply(_page([]), length: 65537);
      await expectLater(
        client.readAdminUsers(request),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      response = peopleReply(
        _page([]),
        stream: Stream.value(List.filled(65537, 32)),
      );
      await expectLater(
        client.readAdminUsers(request),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      response = peopleReply(
        _page([]),
        stream: Stream.value(utf8.encode(jsonEncode(_page([])))),
        length: 1,
      );
      await expectLater(
        client.readAdminUsers(request),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      await client.close();
    },
  );

  test(
    'same shared four-transfer budget; deadline aborts and stop drains original header wait',
    () async {
      final pending = List.generate(
        4,
        (_) => Completer<http.StreamedResponse>(),
      );
      var index = 0;
      final wire = PeopleWire((_) => pending[index++].future);
      final client = _client(wire, deadline: const Duration(milliseconds: 40));
      await client.restore();
      final reads = List.generate(
        4,
        (i) => client.readAdminUsers(TimewebAdminUsersRequest(query: 'q$i')),
      );
      final expectations = reads
          .map(
            (r) => expectLater(r, throwsA(_error(TimewebAuthError.deadline))),
          )
          .toList();
      await _until(() => wire.calls.length == 4);
      await expectLater(
        client.readPeople(await TimewebPeopleFilters.fromCatalog()),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      expect(wire.calls.length, 4);
      await Future.wait(expectations);
      for (final request in wire.calls.cast<http.AbortableRequest>()) {
        await request.abortTrigger;
      }
      var stopped = false;
      final stop = client.stop().then((value) {
        stopped = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      for (final item in pending) {
        item.complete(peopleReply(_page([])));
      }
      expect((await stop).protectedStateSafe, isTrue);
      expect(stopped, isTrue);
    },
  );

  test(
    'late A read and retained DTO/cursor cannot publish after login B',
    () async {
      final late = Completer<http.StreamedResponse>();
      var defer = false;
      final wire = PeopleWire((request) async {
        if (request.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        if (defer) return late.future;
        return peopleReply(
          _page([_user('A', email: 'synthetic-a@example.invalid')], 'Opaque_A'),
        );
      });
      final client = _client(wire);
      await client.restore();
      final request = TimewebAdminUsersRequest();
      final before = await client.readAdminUsers(request),
          row = before.items.single,
          cursor = before.nextCursor!;
      defer = true;
      final old = client.readAdminUsers(TimewebAdminUsersRequest(query: 'AA'));
      final observed = expectLater(
        old,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await _until(() => wire.calls.length == 2);
      await client.login(
        email: 'synthetic-b@example.invalid',
        password: 'synthetic',
        deviceId: 'synthetic-device',
      );
      expect(client.currentUid, 'B');
      late.complete(
        peopleReply(_page([_user('A', email: 'late-a@example.invalid')])),
      );
      await observed;
      expect(
        () => before.items,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      expect(() => row.email, throwsA(_error(TimewebAuthError.staleSession)));
      await expectLater(
        client.readAdminUsers(request, cursor: cursor),
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await client.close();
    },
  );
}
