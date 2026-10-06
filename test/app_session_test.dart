import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

import '../lib/service/app_session.dart';
import '../lib/service/timeweb_auth_client.dart';

AppSessionIdentity identity(
  String uid, [
  AppSessionBackend backend = AppSessionBackend.firebase,
]) => AppSessionIdentity(backend: backend, uid: uid, emailVerified: true);

final class FakeAdapter implements AppSessionAdapter {
  FakeAdapter({this.backend = AppSessionBackend.firebase});
  @override
  final AppSessionBackend backend;
  @override
  AppSessionIdentity? currentIdentity;
  final changes = StreamController<AppSessionIdentity?>.broadcast(sync: true);
  final calls = <String>[];
  final logins = <Completer<AppSessionIdentity>>[];
  Completer<AppSessionIdentity?>? restoring;
  Completer<AppSessionIdentity>? refreshing;
  AppSessionLogout logoutResult = const AppSessionLogout(
    remote: AppSessionRemoteLogout.confirmed,
    localCleared: true,
    allSessions: false,
  );
  Object? logoutError;
  @override
  Stream<AppSessionIdentity?> get identityChanges => changes.stream;
  void external(AppSessionIdentity? value) {
    currentIdentity = value;
    changes.add(value);
  }

  @override
  Future<AppSessionIdentity?> restore() async {
    calls.add('restore');
    return currentIdentity = restoring == null
        ? currentIdentity
        : await restoring!.future;
  }

  @override
  Future<AppSessionIdentity> login({
    required String email,
    required String password,
    required String deviceId,
  }) async {
    calls.add('login:$email');
    final pending = Completer<AppSessionIdentity>();
    logins.add(pending);
    final value = await pending.future;
    external(value);
    return value;
  }

  @override
  Future<AppSessionIdentity> refresh() async {
    calls.add('refresh');
    final value = await refreshing!.future;
    external(value);
    return value;
  }

  @override
  Future<AppSessionLogout> logout({required bool allSessions}) async {
    calls.add('logout');
    if (logoutError != null) throw logoutError!;
    external(null);
    return AppSessionLogout(
      remote: logoutResult.remote,
      localCleared: logoutResult.localCleared,
      allSessions: allSessions,
    );
  }

  @override
  Future<bool> close() async {
    calls.add('close');
    currentIdentity = null;
    await changes.close();
    return true;
  }

  @override
  Future<AppSessionStop> stop() async {
    calls.add('stop');
    await changes.close();
    return const AppSessionStop(protectedStateSafe: true);
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

Future<AppSessionResult> login(AppSession facade, String uid) => facade.login(
  email: '$uid@example.invalid',
  password: 'synthetic',
  deviceId: 'test',
);

final class Store implements TimewebSecureTokenStore {
  TimewebSession? value;
  bool failClear = false;
  bool failWrite = false;
  bool failRead = false;
  int clears = 0;
  Completer<void>? writing;
  Completer<void>? writeEntered;
  @override
  Future<void> clear() async {
    clears++;
    if (failClear) throw StateError('secure store unavailable');
    value = null;
  }

  @override
  Future<TimewebSession?> read() async {
    if (failRead) throw StateError('protected store unreadable');
    return value;
  }

  @override
  Future<void> write(TimewebSession session) async {
    if (writeEntered != null && !writeEntered!.isCompleted) {
      writeEntered!.complete();
    }
    if (writing != null) await writing!.future;
    if (failWrite) throw StateError('protected store write unavailable');
    value = session;
  }
}

final class Wire extends http.BaseClient {
  Wire(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

http.StreamedResponse reply(Object data, [int status = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(data))),
      status,
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );

Map<String, Object> tokens([String suffix = 'old']) => {
  'uid': 'A',
  'emailVerified': true,
  'accessToken': 'na1.A.$suffix',
  'refreshToken': 'nr1.A.$suffix',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};

TimewebAuthClient native(Store store, Wire wire, {bool reads = false}) =>
    TimewebAuthClient(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse('https://clrs-api.example.invalid'),
        enabled: true,
        currentReadsEnabled: reads,
      ),
      secureStore: store,
      transport: wire,
    );

Future<AppSessionResult> settled(AppSessionResult value) async =>
    value.settled == null ? value : await value.settled!;

void main() {
  test(
    'destructive close invalidates cached stop retention before and after clear',
    () async {
      final store = Store();
      final wire = Wire((_) async => reply(tokens()));
      final client = native(store, wire);
      await client.login(
        email: 'A@example.invalid',
        password: 'synthetic',
        deviceId: 'test',
      );
      expect((await client.stop()).protectedStateSafe, true);
      expect(store.value, isNotNull);
      final closing = client.close();
      expect((await client.stop()).protectedStateSafe, false);
      expect(await closing, true);
      expect(store.value, isNull);
      expect((await client.stop()).protectedStateSafe, false);

      final facadeStore = Store();
      final facade = AppSession.timeweb(
        client: native(facadeStore, wire),
        clearLocal: () async {},
      );
      expect((await login(facade, 'A')).confirmed, true);
      expect((await facade.stop()).confirmed, true);
      expect(facadeStore.value, isNotNull);
      final facadeClosing = facade.close();
      expect((await facade.stop()).error, AppSessionError.closed);
      expect(facade.state.phase, AppSessionPhase.closed);
      expect((await facadeClosing).confirmed, true);
      expect(facadeStore.value, isNull);
      expect((await facade.stop()).error, AppSessionError.closed);
      expect(facade.currentUid, isNull);
    },
  );

  test(
    'stop preserves remembered tokens, invalidates DTO and cancels actual GET before replacement restore',
    () async {
      final store = Store();
      final paths = <String>[];
      final listening = Completer<void>();
      final cancelled = Completer<void>();
      final stream = StreamController<List<int>>(
        onListen: listening.complete,
        onCancel: cancelled.complete,
      );
      var reads = 0;
      final wire = Wire((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/v1/auth/login') return reply(tokens());
        if (++reads == 1) {
          return reply({
            'kind': 'canonical-current',
            'ordering': 'updated_at_desc_chat_id_asc_null_last',
            'items': [],
            'nextCursor': null,
          });
        }
        return http.StreamedResponse(
          stream.stream,
          200,
          headers: {
            'content-type': 'application/json',
            'cache-control': 'no-store',
          },
        );
      });
      final client = native(store, wire, reads: true);
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      await login(facade, 'A');
      final protected = store.value;
      final lease = facade.captureLease();
      final page = await client.readCurrent(TimewebCurrentReadRequest.chats());
      final hanging = client.readCurrent(TimewebCurrentReadRequest.chats());
      final rejected = expectLater(
        hanging,
        throwsA(isA<TimewebAuthException>()),
      );
      await listening.future;
      final stopping = facade.stop();
      expect(facade.state.phase, AppSessionPhase.stopped);
      expect(facade.currentUid, isNull);
      expect(client.currentUid, isNull);
      expect(lease.isCurrent, false);
      expect(() => page.chats, throwsA(isA<TimewebAuthException>()));
      await cancelled.future;
      await rejected;
      final result = await stopping;
      expect(result.confirmed, true);
      expect(result.logout, isNull);
      expect(store.value, same(protected));
      expect(store.clears, 1);
      expect((await facade.restore()).error, AppSessionError.closed);
      expect((await facade.stop()).confirmed, true);
      expect(facade.state.phase, AppSessionPhase.stopped);
      final replacement = native(store, wire);
      expect((await replacement.restore())!.uid, 'A');
      expect(paths.where((path) => path.startsWith('/v1/auth/')), [
        '/v1/auth/login',
      ]);
      expect((await replacement.stop()).protectedStateSafe, true);
      await stream.close();
    },
  );

  test(
    'stop during a started login waits actual protected write without adopting late identity',
    () async {
      final store = Store()
        ..writing = Completer<void>()
        ..writeEntered = Completer<void>();
      var posts = 0;
      final wire = Wire((_) async {
        posts++;
        return reply(tokens());
      });
      final client = native(store, wire);
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
        waitTimeout: const Duration(milliseconds: 8),
      );
      final signingIn = login(facade, 'A');
      await store.writeEntered!.future;
      final stopping = await facade.stop();
      expect(stopping.outcome, AppSessionOutcome.pending);
      expect(client.hasSession, false);
      expect(facade.currentUid, isNull);
      expect(store.value, isNull);
      expect(store.clears, 1);
      store.writing!.complete();
      expect(
        (await settled(await signingIn)).outcome,
        AppSessionOutcome.superseded,
      );
      expect((await settled(stopping)).confirmed, true);
      expect(facade.currentUid, isNull);
      expect(store.value!.uid, 'A');
      final replacement = native(store, wire);
      expect((await replacement.restore())!.uid, 'A');
      expect(posts, 1);
      await replacement.stop();
    },
  );

  test(
    'stop drains successful refresh rotation and keeps unknown refresh fail-closed without replay',
    () async {
      for (final unknown in [false, true]) {
        final store = Store();
        final started = Completer<void>();
        final response = Completer<http.StreamedResponse>();
        var refreshes = 0;
        final wire = Wire((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            refreshes++;
            started.complete();
            return response.future;
          }
          return reply(tokens());
        });
        final client = native(store, wire);
        final facade = AppSession.timeweb(
          client: client,
          clearLocal: () async {},
          waitTimeout: const Duration(milliseconds: 8),
        );
        await login(facade, 'A');
        final refreshing = facade.refresh();
        await started.future;
        final stopping = await facade.stop();
        expect(stopping.outcome, AppSessionOutcome.pending);
        expect(facade.currentUid, isNull);
        expect(client.currentUid, isNull);
        response.complete(
          unknown
              ? reply({'error': 'unavailable'}, 503)
              : reply(tokens('rotated')),
        );
        expect(
          (await settled(await refreshing)).outcome,
          AppSessionOutcome.superseded,
        );
        final result = await settled(stopping);
        expect(
          result.outcome,
          unknown
              ? AppSessionOutcome.remoteUnknown
              : AppSessionOutcome.confirmed,
        );
        expect(result.logout, isNull);
        expect(refreshes, 1);
        final replacement = native(store, wire);
        final restored = await replacement.restore();
        if (unknown) {
          expect(store.value, isNull);
          expect(restored, isNull);
          expect(
            store.clears,
            2,
          ); // Existing auth invalidation, not lifecycle stop.
        } else {
          expect(restored!.refreshToken, 'nr1.A.rotated');
          expect(store.clears, 1);
        }
        expect(refreshes, 1);
        await replacement.stop();
      }
    },
  );

  test(
    'unreadable protected store cannot produce successful stop or replacement identity',
    () async {
      final store = Store()..failRead = true;
      final now = DateTime.now();
      store.value = TimewebSession(
        uid: 'A',
        emailVerified: true,
        accessToken: 'na1.A.synthetic',
        refreshToken: 'nr1.A.synthetic',
        accessExpiresAt: now.add(const Duration(minutes: 15)),
        refreshExpiresAt: now.add(const Duration(days: 14)),
      );
      var posts = 0;
      final wire = Wire((_) async {
        posts++;
        return reply(tokens());
      });
      final client = native(store, wire);
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      expect((await facade.restore()).error, AppSessionError.secureStore);
      final result = await facade.stop();
      expect(result.outcome, AppSessionOutcome.failed);
      expect(result.error, AppSessionError.secureStore);
      expect(facade.currentUid, isNull);
      expect(store.clears, 0);
      expect(store.value, isNotNull);
      final replacement = native(store, wire);
      await expectLater(
        replacement.restore(),
        throwsA(isA<TimewebAuthException>()),
      );
      expect(replacement.hasSession, false);
      expect(posts, 0);
      expect((await replacement.stop()).protectedStateSafe, false);
    },
  );

  test(
    'logout cancels a hanging screen read now and consumes its later error',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      await facade.restore();
      final original = Completer<String>();
      final read = facade.runAuthenticated((_) => original.future);
      final rejected = expectLater(read, throwsA(isA<AppSessionException>()));
      final logout = facade.logout();
      await rejected;
      expect(original.isCompleted, false);
      expect((await logout).confirmed, true);
      original.completeError(StateError('late original transport error'));
      await tick();
      await facade.close();
    },
  );

  test(
    'real native unknown refresh keeps unknown result despite its null identity event',
    () async {
      final store = Store();
      final wire = Wire((request) async {
        if (request.url.path.endsWith('/refresh')) {
          return reply({'error': 'unavailable'}, 503);
        }
        return reply({
          'uid': 'A',
          'emailVerified': true,
          'accessToken': 'na1.A.synthetic',
          'refreshToken': 'nr1.A.synthetic',
          'expiresIn': 900,
          'refreshExpiresIn': 1209600,
        });
      });
      final client = TimewebAuthClient(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://clrs-api.example.invalid'),
          enabled: true,
        ),
        secureStore: store,
        transport: wire,
      );
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      await login(facade, 'A');
      final lease = facade.captureLease();
      final result = await facade.refresh();
      expect(result.outcome, AppSessionOutcome.remoteUnknown);
      expect(facade.currentUid, isNull);
      expect(lease.isCurrent, false);
      await tick();
      expect(facade.state.phase, AppSessionPhase.unresolved);
      expect(store.value, isNull);
      await facade.close();
    },
  );

  test(
    'provider bootstrap event does not supersede explicit restore',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      final restored = facade.restore();
      adapter.external(identity('A'));
      expect((await restored).confirmed, true);
      expect(facade.currentUid, 'A');
      expect(adapter.calls, ['restore']);
      await facade.close();
    },
  );

  test(
    'repeat login taps and startup restore share the actual login',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      final one = login(facade, 'A');
      await tick();
      final two = login(facade, 'A');
      final restoring = facade.restore();
      expect(adapter.calls, ['login:A@example.invalid']);
      adapter.logins.single.complete(identity('A'));
      expect((await one).confirmed, true);
      expect((await two).confirmed, true);
      expect((await restoring).confirmed, true);
      expect(adapter.calls, ['login:A@example.invalid']);
      await facade.close();
    },
  );

  test(
    'native confirmed remote logout with failed secure clear blocks next login',
    () async {
      final store = Store();
      var loginCalls = 0;
      final wire = Wire((request) async {
        if (request.url.path.endsWith('/logout')) {
          return reply({'loggedOut': true});
        }
        loginCalls++;
        return reply({
          'uid': 'A',
          'emailVerified': true,
          'accessToken': 'na1.A.synthetic',
          'refreshToken': 'nr1.A.synthetic',
          'expiresIn': 900,
          'refreshExpiresIn': 1209600,
        });
      });
      final client = TimewebAuthClient(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://clrs-api.example.invalid'),
          enabled: true,
        ),
        secureStore: store,
        transport: wire,
      );
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      expect((await login(facade, 'A')).confirmed, true);
      final lease = facade.captureLease();
      store.failClear = true;
      final logout = await facade.logout();
      expect(logout.outcome, AppSessionOutcome.failed);
      expect(logout.error, AppSessionError.secureStore);
      expect(logout.logout!.remoteConfirmed, true);
      expect(logout.logout!.localCleared, false);
      expect(facade.currentUid, isNull);
      expect(lease.isCurrent, false);
      expect((await login(facade, 'B')).error, AppSessionError.secureStore);
      expect(loginCalls, 1);
      store.failClear = false;
      await facade.close();
    },
  );

  test(
    'unknown refresh invalidates identity instead of reusing old credentials',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      adapter.refreshing = Completer<AppSessionIdentity>();
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      await facade.restore();
      final lease = facade.captureLease();
      final refreshing = facade.refresh();
      adapter.refreshing!.completeError(
        const AppSessionException(
          AppSessionError.network,
          remoteOutcomeUnknown: true,
        ),
      );
      final result = await refreshing;
      expect(result.outcome, AppSessionOutcome.remoteUnknown);
      expect(facade.state.phase, AppSessionPhase.unresolved);
      expect(facade.currentUid, isNull);
      expect(lease.isCurrent, false);
      expect(adapter.calls.where((call) => call == 'refresh'), hasLength(1));
      await facade.close();
    },
  );

  test(
    'Firebase is the default; mismatched provider cannot become fallback',
    () async {
      final firebase = FakeAdapter()..currentIdentity = identity('A');
      final facade = AppSession(adapter: firebase, clearLocal: () async {});
      expect(facade.backend, AppSessionBackend.firebase);
      expect((await facade.restore()).confirmed, true);
      expect(facade.currentUid, 'A');
      expect(
        () => AppSession(
          adapter: FakeAdapter(backend: AppSessionBackend.timeweb),
          clearLocal: () async {},
        ),
        throwsArgumentError,
      );
      expect(
        () => AppSessionIdentity(
          backend: AppSessionBackend.timeweb,
          uid: 'A',
          emailVerified: true,
          admin: AppSessionAdmin.administrator,
        ),
        throwsArgumentError,
      );
      await facade.close();
    },
  );

  test(
    'local clear completes before restore or login adopts identity',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final pending = Completer<void>();
      var clearCount = 0;
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {
          clearCount++;
          if (clearCount == 1) await pending.future;
        },
      );
      final restored = facade.restore();
      await tick();
      expect(adapter.calls, isEmpty);
      expect(facade.currentUid, isNull);
      pending.complete();
      expect((await restored).confirmed, true);
      expect(facade.currentUid, 'A');
      await facade.close();
    },
  );

  test(
    'deadline reports pending; original login settles without a second POST',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {},
        waitTimeout: const Duration(milliseconds: 8),
      );
      final pending = await login(facade, 'A');
      expect(pending.outcome, AppSessionOutcome.pending);
      expect(facade.state.phase, AppSessionPhase.authenticating);
      expect(facade.currentUid, isNull);
      expect(adapter.calls, ['login:A@example.invalid']);
      adapter.logins.single.complete(identity('A'));
      expect((await pending.settled!).confirmed, true);
      expect(adapter.calls, ['login:A@example.invalid']);
      expect(facade.currentUid, 'A');
      await facade.close();
    },
  );

  test(
    'started A then B is serialized; late A never becomes visible for B',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      final visible = <String?>[];
      final subscription = facade.states.listen(
        (state) => visible.add(state.identity?.uid),
      );
      final a = login(facade, 'A');
      await tick();
      final b = login(facade, 'B');
      expect(facade.currentUid, isNull);
      expect(adapter.logins, hasLength(1));
      adapter.logins[0].complete(identity('A'));
      expect((await a).outcome, AppSessionOutcome.superseded);
      await tick();
      expect(adapter.logins, hasLength(2));
      expect(visible.whereType<String>(), isEmpty);
      adapter.logins[1].complete(identity('B'));
      expect((await b).confirmed, true);
      expect(facade.currentUid, 'B');
      await subscription.cancel();
      await facade.close();
    },
  );

  test(
    'external A -> null -> A invalidates held lease and old screen result',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      await facade.restore();
      final lease = facade.captureLease();
      final oldRead = Completer<String>();
      final read = facade.runAuthenticated((_) => oldRead.future);
      final rejected = expectLater(read, throwsA(isA<AppSessionException>()));
      adapter.external(null);
      adapter.external(identity('A'));
      await lease.whenInvalidated;
      await tick();
      expect(facade.currentUid, 'A');
      expect(lease.isCurrent, false);
      oldRead.complete('old portrait');
      await rejected;
      await facade.close();
    },
  );

  test(
    'overlapping clears cannot erase B after its identity is adopted',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final clears = <Completer<void>>[];
      var delay = false;
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {
          if (delay) {
            final pending = Completer<void>();
            clears.add(pending);
            await pending.future;
          }
        },
      );
      await facade.restore();
      delay = true;
      adapter.external(identity('B'));
      await tick();
      final b = login(facade, 'B');
      await tick();
      expect(clears, hasLength(1));
      expect(adapter.logins, isEmpty);
      clears[0].complete();
      await tick();
      expect(clears, hasLength(2));
      expect(adapter.logins, isEmpty);
      clears[1].complete();
      await tick();
      adapter.logins.single.complete(identity('B'));
      expect((await b).confirmed, true);
      expect(facade.currentUid, 'B');
      delay = false;
      await facade.close();
    },
  );

  test('refresh is shared; same identity lease survives rotation', () async {
    final adapter = FakeAdapter()..currentIdentity = identity('A');
    adapter.refreshing = Completer<AppSessionIdentity>();
    final facade = AppSession(adapter: adapter, clearLocal: () async {});
    await facade.restore();
    final lease = facade.captureLease();
    final one = facade.refresh();
    final two = facade.refresh();
    expect(adapter.calls.where((call) => call == 'refresh'), hasLength(1));
    adapter.refreshing!.complete(identity('A'));
    expect((await one).confirmed, true);
    expect((await two).confirmed, true);
    expect(lease.isCurrent, true);
    await facade.close();
  });

  test(
    'logout drops UID at submission and waits behind pending login',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      final signingIn = login(facade, 'A');
      await tick();
      final signingOut = facade.logout(allSessions: true);
      expect(facade.currentUid, isNull);
      expect(facade.state.phase, AppSessionPhase.signingOut);
      expect(adapter.calls, ['login:A@example.invalid']);
      adapter.logins.single.complete(identity('A'));
      expect((await signingIn).outcome, AppSessionOutcome.superseded);
      final result = await signingOut;
      expect(result.confirmed, true);
      expect(result.logout!.allSessions, true);
      expect(result.logout!.remoteConfirmed, true);
      expect(facade.currentUid, isNull);
      expect(adapter.currentIdentity, isNull);
      await facade.close();
    },
  );

  test(
    'unknown logout remains signed out locally and does not claim server confirmation',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      adapter.logoutResult = const AppSessionLogout(
        remote: AppSessionRemoteLogout.unknown,
        localCleared: true,
        allSessions: false,
      );
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      await facade.restore();
      final result = await facade.logout();
      expect(result.outcome, AppSessionOutcome.remoteUnknown);
      expect(result.logout!.remoteConfirmed, false);
      expect(facade.state.phase, AppSessionPhase.signedOut);
      expect(facade.currentUid, isNull);
      await facade.close();
    },
  );

  test(
    'failed local clear is fail-closed and raw error is never exposed',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      var fail = true;
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {
          if (fail) throw StateError('private profile detail');
        },
      );
      final result = await facade.restore();
      expect(result.error, AppSessionError.localClear);
      expect(facade.currentUid, isNull);
      expect(adapter.calls, isEmpty);
      expect(facade.state.toString(), isNot(contains('private')));
      fail = false;
      await facade.close();
    },
  );

  test(
    'close invalidates pending login now, waits actual mutation, and clears afterward',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {},
        waitTimeout: const Duration(milliseconds: 8),
      );
      final signingIn = login(facade, 'A');
      await tick();
      final close = await facade.close();
      expect(close.outcome, AppSessionOutcome.pending);
      expect(facade.state.phase, AppSessionPhase.closed);
      expect(facade.currentUid, isNull);
      adapter.logins.single.complete(identity('A'));
      final loginResult = await signingIn;
      if (loginResult.settled != null) await loginResult.settled;
      expect((await close.settled!).confirmed, true);
      expect(adapter.calls.last, 'close');
      expect(adapter.currentIdentity, isNull);
      expect((await facade.restore()).error, AppSessionError.closed);
      expect((await facade.stop()).error, AppSessionError.closed);
      expect(facade.state.phase, AppSessionPhase.closed);
    },
  );

  test(
    'real native adapter maps token response, rejects unknown POST, and stays non-admin',
    () async {
      final store = Store();
      var valid = true;
      final wire = Wire((request) async {
        if (!valid) return reply({'bad': true});
        return reply({
          'uid': 'A',
          'emailVerified': true,
          'accessToken': 'na1.A.synthetic',
          'refreshToken': 'nr1.A.synthetic',
          'expiresIn': 900,
          'refreshExpiresIn': 1209600,
        });
      });
      final client = TimewebAuthClient(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://clrs-api.example.invalid'),
          enabled: true,
        ),
        secureStore: store,
        transport: wire,
      );
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      expect((await login(facade, 'A')).confirmed, true);
      expect(facade.currentUid, 'A');
      expect(facade.state.identity!.isAdministrator, false);
      expect(facade.state.identity!.admin, AppSessionAdmin.unknown);
      valid = false;
      final result = await login(facade, 'B');
      expect(result.outcome, AppSessionOutcome.remoteUnknown);
      expect(facade.state.phase, AppSessionPhase.unresolved);
      expect(facade.currentUid, isNull);
      expect(store.value, isNull);
      await tick();
      expect(facade.state.phase, AppSessionPhase.unresolved);
      await facade.close();
    },
  );
}
