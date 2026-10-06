import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../lib/service/timeweb_auth_client.dart';

final _now = DateTime.utc(2026, 10, 1);
final _pin = 'a' * 64;
final _digest = 'b' * 64;

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = _session('A');
  int writes = 0, clears = 0;
  @override
  Future<TimewebSession?> read() async => value;
  @override
  Future<void> write(TimewebSession next) async {
    writes++;
    value = next;
  }

  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }
}

class _Wire extends http.BaseClient {
  _Wire(this.action);
  final Future<http.StreamedResponse> Function(http.BaseRequest) action;
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return action(request);
  }
}

TimewebSession _session(String uid) => TimewebSession(
  uid: uid,
  emailVerified: true,
  accessToken: 'na1.synthetic.first',
  refreshToken: 'nr1.synthetic.first',
  accessExpiresAt: _now.add(const Duration(minutes: 15)),
  refreshExpiresAt: _now.add(const Duration(days: 14)),
);
Map<String, dynamic> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.synthetic.rotated',
  'refreshToken': 'nr1.synthetic.rotated',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
TimewebAuthClient _client(_Store store, _Wire wire, {bool enabled = true}) =>
    TimewebAuthClient(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse('https://clrs-api.example.invalid'),
        enabled: enabled,
      ),
      secureStore: store,
      transport: wire,
      clock: () => _now,
      requestDeadline: const Duration(seconds: 1),
    );
http.StreamedResponse _reply(Object value, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(value))),
      status,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
      },
    );
Map<String, dynamic> _profile(String uid) => {
  'uid': uid,
  'status': 'active',
  'registrationStatus': null,
  'deleted': false,
  'isRegistrationEnd': false,
  'profileDetailsSaved': null,
  'группа': ' БЕЛАЯ ',
  'group': ' БЕЛАЯ ',
  'fullName': 'Synthetic profile',
  'country': null,
  'countryCode': null,
  'region': null,
  'city': null,
  'languageGroup': null,
  'countrySegment': null,
  'pol': null,
  'about': null,
  'hobbi': null,
  'rost': null,
  'relationStatus': null,
  'age': 32.5,
  'deti': null,
  'online': null,
  'isUnVisible': null,
  'isUnvisible': null,
  'notificationPreferences': {
    'messages': true,
    'meetings': false,
    'sound': null,
  },
  'lastOnlineTS': '2026-09-30T12:00:00.123456789Z',
  'unvisibleEnd': null,
  'profilePic': {
    'kind': 'legacy_storage',
    'status': 'quarantined',
    'reference': 'opaque_media_1',
  },
  'profilePicThumb': {
    'kind': 'unavailable',
    'reason': 'unmapped_external_media',
  },
};
Map<String, dynamic> _envelope(String uid, {bool missing = false}) => {
  'uid': uid,
  'profile': missing ? null : _profile(uid),
  'onboarding': missing ? 'registration' : 'search',
  'profileExists': !missing,
  'sourceSnapshot': _pin,
  'profileDocumentHash': missing ? null : _digest,
  'profileAuthority': 'immutable-reviewed-snapshot',
  'accountAuthority': 'active-local-account',
  'mediaReady': false,
  'readOnly': true,
  'unavailableFields': <String>[],
};
Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
Matcher _error(TimewebAuthError error) => isA<TimewebAuthException>()
    .having(
      (value) => value.operation,
      'operation',
      TimewebAuthOperation.profile,
    )
    .having((value) => value.error, 'safe error', error);
Future<TimewebFullOwnProfile> _read(TimewebAuthClient client) =>
    client.readFullOwnProfile(expectedSourceSnapshot: _pin);

void main() {
  test(
    'fixed full route is uncached, typed, source pinned and header-only; old route remains',
    () async {
      final store = _Store();
      var fullReads = 0;
      final wire = _Wire((request) async {
        expect(request.method, 'GET');
        expect(request.url.query, isEmpty);
        expect(request.url.fragment, isEmpty);
        expect(request.followRedirects, isFalse);
        expect((request as http.Request).body, isEmpty);
        expect(request.headers['Authorization'], 'Bearer na1.synthetic.first');
        if (request.url.path == '/v1/me/profile')
          return _reply({
            'profile': {'uid': 'A', 'fullName': 'Old minimal'},
          });
        expect(request.url.path, '/v1/me/full-profile');
        final body = _envelope('A');
        final profile = body['profile'] as Map<String, dynamic>;
        profile['fullName'] = 'Synthetic ${++fullReads}';
        profile['country'] = null;
        body['unavailableFields'] = ['country'];
        return _reply(body);
      });
      final client = _client(store, wire);
      await client.restore();
      final first = await _read(client), second = await _read(client);
      expect(first.uid, 'A');
      expect(first.sourceSnapshot, _pin);
      expect(first.profileDocumentHash, _digest);
      expect(first.profileExists, isTrue);
      expect(first.onboarding, TimewebOnboarding.search);
      expect(first.profileAuthority, 'immutable-reviewed-snapshot');
      expect(first.accountAuthority, 'active-local-account');
      expect(first.readOnly, isTrue);
      expect(first.mediaReady, isFalse);
      expect(first.profile!.fullName, 'Synthetic 1');
      expect(second.profile!.fullName, 'Synthetic 2');
      expect(first.profile!.legacyGroup, ' БЕЛАЯ ');
      expect(first.profile!.group, ' БЕЛАЯ ');
      expect(first.profile!.age, 32.5);
      expect(first.profile!.online, isNull);
      expect(first.profile!.country, isNull);
      expect(
        first.profile!.lastOnlineTimestamp,
        '2026-09-30T12:00:00.123456789Z',
      );
      expect(first.profile!.notificationPreferences!.messages, isTrue);
      expect(first.profile!.notificationPreferences!.meetings, isFalse);
      expect(first.profile!.notificationPreferences!.sound, isNull);
      expect(
        first.profile!.profilePic!.kind,
        TimewebOwnProfileMediaKind.quarantined,
      );
      expect(first.profile!.profilePic!.opaqueReference, 'opaque_media_1');
      expect(
        first.profile!.profilePicThumb!.kind,
        TimewebOwnProfileMediaKind.unavailable,
      );
      expect(
        first.profile!.profilePicThumb!.unavailableReason,
        'unmapped_external_media',
      );
      expect(first.unavailableFields, ['country']);
      expect(() => first.unavailableFields.add('age'), throwsUnsupportedError);
      for (final value in [
        first,
        first.profile,
        first.profile!.profilePic,
        first.profile!.notificationPreferences,
      ]) {
        expect(value.toString(), isNot(contains('Synthetic')));
        expect(value.toString(), isNot(contains('opaque_media_1')));
      }
      expect((await client.readOwnProfile())['fullName'], 'Old minimal');
      expect(wire.calls.length, 3);
      expect(store.writes, 0);
      expect(store.clears, 0);
    },
  );

  test(
    'missing, partial, saved details and group alias keep truthful onboarding',
    () async {
      final bodies = [_envelope('A', missing: true)];
      final partial = _envelope('A');
      final data = partial['profile'] as Map<String, dynamic>;
      data['группа'] = null;
      data['group'] = 'белая';
      partial['onboarding'] = 'registration';
      bodies.add(_clone(partial));
      data['profileDetailsSaved'] = true;
      partial['onboarding'] = 'test';
      bodies.add(_clone(partial));
      data['profileDetailsSaved'] = false;
      data['pol'] = ' ';
      data['about'] = 'about';
      data['hobbi'] = 'interest';
      bodies.add(
        _clone(partial),
      ); // Existing fallback accepts nonempty, untrimmed pol and source num age.
      final wire = _Wire((_) async => _reply(bodies.removeAt(0)));
      final client = _client(_Store(), wire);
      await client.restore();
      final missing = await _read(client);
      expect(missing.profile, isNull);
      expect(missing.profileExists, isFalse);
      expect(missing.onboarding, TimewebOnboarding.registration);
      expect(missing.profileDocumentHash, isNull);
      expect((await _read(client)).onboarding, TimewebOnboarding.registration);
      expect((await _read(client)).onboarding, TimewebOnboarding.test);
      expect((await _read(client)).onboarding, TimewebOnboarding.test);
    },
  );

  test(
    'real sixteen legacy completion groups do not force old profiles to register',
    () async {
      const groups = [
        'коричнево-красная',
        'коричнево-синяя',
        'коричневая',
        'коричнево-белая',
        'бело-коричневая',
        'бело-красная',
        'бело-синяя',
        'белая',
        'сине-белая',
        'красно-синяя',
        'красно-белая',
        'красная',
        'красно-коричневая',
        'синяя',
        'сине-коричневая',
        'сине-красная',
      ];
      var index = 0;
      final wire = _Wire((_) async {
        final body = _envelope('A');
        final data = body['profile'] as Map;
        data['группа'] = ' ${groups[index++].toUpperCase()} ';
        data['group'] = data['группа'];
        data['fullName'] = null;
        data['age'] = null;
        return _reply(body);
      });
      final client = _client(_Store(), wire);
      await client.restore();
      for (final ignored in groups) {
        expect((await _read(client)).onboarding, TimewebOnboarding.search);
      }
    },
  );

  test(
    '404 and 503 never become missing profile, registration, retry or logout',
    () async {
      for (final status in [404, 503]) {
        final store = _Store(),
            wire = _Wire(
              (_) async =>
                  _reply({'private': 'must never decode'}, status: status),
            );
        final client = _client(store, wire);
        await client.restore();
        await expectLater(
          _read(client),
          throwsA(_error(TimewebAuthError.unavailable)),
        );
        expect(wire.calls.length, 1);
        expect(client.currentUid, 'A');
        expect(store.writes, 0);
        expect(store.clears, 0);
      }
    },
  );

  test(
    'strict shape denies source, owner, lifecycle, extra private fields and false completion',
    () async {
      final changes = <void Function(Map<String, dynamic>)>[
        (b) => b['sourceSnapshot'] = 'c' * 64,
        (b) => b['sourceSnapshot'] = 'A' * 64,
        (b) => b['profileDocumentHash'] = 'bad',
        (b) => b['uid'] = 'B',
        (b) => (b['profile'] as Map)['uid'] = 'B',
        (b) => b['profileAuthority'] = 'live',
        (b) => b['accountAuthority'] = 'profile-role',
        (b) => b['mediaReady'] = true,
        (b) => b['readOnly'] = false,
        (b) => b['onboarding'] = 'registration',
        (b) => b['profileExists'] = false,
        (b) => b['profile'] = null,
        (b) => b['email'] = 'private@example.invalid',
        (b) => (b['profile'] as Map)['balance'] = 100,
        (b) => (b['profile'] as Map)['admin'] = true,
        (b) => (b['profile'] as Map)['status'] = 'deleted',
        (b) => (b['profile'] as Map)['registrationStatus'] = 'blocked',
        (b) => (b['profile'] as Map)['deleted'] = true,
        (b) => (b['profile'] as Map)['isRegistrationEnd'] = 'true',
        (b) => (b['profile'] as Map)['age'] = '32',
        (b) => (b['profile'] as Map)['age'] = 151,
        (b) => (b['profile'] as Map)['profilePic'] =
            'https://firebasestorage.googleapis.com/o/x?token=private',
        (b) => (b['profile'] as Map)['profilePic'] = {
          'kind': 'bundled_gift',
          'asset': 'assets/gifts/test.png',
        },
        (b) => (b['profile'] as Map)['profilePic'] = {
          'kind': 'legacy_storage',
          'status': 'quarantined',
          'reference': 'https://private.invalid',
        },
        (b) => (b['profile'] as Map)['profilePic'] = {
          'kind': 'unavailable',
          'reason': 'private-token',
        },
        (b) => (b['profile'] as Map)['notificationPreferences'] = {
          'messages': true,
          'meetings': false,
          'sound': null,
          'admin': true,
        },
        (b) => b['unavailableFields'] = ['status'],
        (b) => b['unavailableFields'] = ['country', 'country'],
        (b) => b['unavailableFields'] = ['fullName'],
        (b) => (b['profile'] as Map)['lastOnlineTS'] = '2026-02-31T12:00:00Z',
        (b) =>
            (b['profile'] as Map)['lastOnlineTS'] = '2026-10-01T12:00:00+03:00',
        (b) => (b['profile'] as Map).remove('country'),
        (b) => (b['profile'] as Map)['fullName'] = '\ud800',
      ];
      for (final change in changes) {
        final body = _envelope('A');
        change(body);
        final store = _Store(), wire = _Wire((_) async => _reply(body));
        final client = _client(store, wire);
        await client.restore();
        await expectLater(
          _read(client),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        expect(client.currentUid, 'A');
        expect(store.writes, 0);
        expect(store.clears, 0);
      }
    },
  );

  test(
    'server Unicode character bounds accept non-BMP text without relaxing limits',
    () async {
      final body = _envelope('A');
      (body['profile'] as Map)['fullName'] = '😀' * 1000;
      final wire = _Wire((_) async => _reply(body));
      final client = _client(_Store(), wire);
      await client.restore();
      expect((await _read(client)).profile!.fullName!.runes.length, 1000);
      (body['profile'] as Map)['fullName'] = '😀' * 1001;
      await expectLater(
        _read(client),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
    },
  );

  test(
    'exact 256KiB body passes; one extra byte is cancelled without changing session',
    () async {
      final encoded = utf8.encode(jsonEncode(_envelope('A')));
      var extra = 0, cancellations = 0;
      final store = _Store();
      final wire = _Wire((_) async {
        final stream = StreamController<List<int>>();
        stream.onCancel = () => cancellations++;
        stream.add([
          ...encoded,
          ...List<int>.filled(262144 - encoded.length + extra, 32),
        ]);
        stream.close();
        return http.StreamedResponse(
          stream.stream,
          200,
          headers: {
            'content-type': 'application/json',
            'cache-control': 'no-store',
          },
        );
      });
      final client = _client(store, wire);
      await client.restore();
      expect((await _read(client)).profileExists, isTrue);
      extra = 1;
      await expectLater(
        _read(client),
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cancellations, 2);
      expect(client.currentUid, 'A');
      expect(store.writes, 0);
      expect(store.clears, 0);
    },
  );

  test(
    'A to B and A to A login invalidate late responses and retained nested DTOs',
    () async {
      for (final nextUid in ['B', 'A']) {
        final late = Completer<http.StreamedResponse>();
        var profileCalls = 0;
        final store = _Store();
        final wire = _Wire((request) async {
          if (request.url.path == '/v1/auth/login')
            return _reply(_tokens(nextUid));
          if (++profileCalls == 1) return _reply(_envelope('A'));
          return late.future;
        });
        final client = _client(store, wire);
        await client.restore();
        final old = await _read(client), profile = old.profile!;
        final media = profile.profilePic!,
            prefs = profile.notificationPreferences!;
        final pending = _read(client);
        final rejected = expectLater(
          pending,
          throwsA(_error(TimewebAuthError.staleSession)),
        );
        await Future<void>.delayed(Duration.zero);
        await client.login(
          email: 'synthetic@example.invalid',
          password: 'synthetic',
          deviceId: 'test-device',
        );
        late.complete(_reply(_envelope('A')));
        await rejected;
        for (final access in <void Function()>[
          old.requireCurrent,
          () => old.uid,
          () => old.onboarding,
          () => old.profile,
          () => old.sourceSnapshot,
          () => old.unavailableFields,
          profile.requireCurrent,
          () => profile.fullName,
          () => profile.notificationPreferences,
          () => profile.profilePic,
          () => media.opaqueReference,
          () => media.kind,
          () => prefs.messages,
        ]) {
          expect(access, throwsA(_error(TimewebAuthError.staleSession)));
        }
        expect(client.currentUid, nextUid);
        expect(store.value!.uid, nextUid);
      }
    },
  );

  test(
    'parallel full reads share one 401 rotation and retry the fixed GET once',
    () async {
      final rotation = Completer<http.StreamedResponse>();
      final store = _Store();
      var rotations = 0;
      final wire = _Wire((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          rotations++;
          return rotation.future;
        }
        expect(request.url.path, '/v1/me/full-profile');
        expect(request.url.query, isEmpty);
        return request.headers['Authorization'] == 'Bearer na1.synthetic.first'
            ? _reply({}, status: 401)
            : _reply(_envelope('A'));
      });
      final client = _client(store, wire);
      await client.restore();
      final first = _read(client), second = _read(client);
      for (var i = 0; i < 30 && rotations == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(rotations, 1);
      rotation.complete(_reply(_tokens('A')));
      final values = await Future.wait([first, second]);
      expect(
        values.every((v) => v.onboarding == TimewebOnboarding.search),
        isTrue,
      );
      expect(rotations, 1);
      expect(wire.calls.length, 5);
      expect(store.writes, 1);
    },
  );

  test(
    'default off, missing session and invalid local pin never issue a GET',
    () async {
      final store = _Store(), wire = _Wire((_) async => _reply(_envelope('A')));
      final disabled = _client(store, wire, enabled: false);
      await expectLater(
        _read(disabled),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      final client = _client(store, wire);
      await expectLater(
        _read(client),
        throwsA(_error(TimewebAuthError.notAuthenticated)),
      );
      await client.restore();
      await expectLater(
        client.readFullOwnProfile(expectedSourceSnapshot: 'invalid'),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(wire.calls, isEmpty);
      expect(store.writes, 0);
      expect(store.clears, 0);
    },
  );
}
