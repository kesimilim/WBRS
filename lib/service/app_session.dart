import 'dart:async';

import 'timeweb_auth_client.dart';

enum AppSessionBackend { firebase, timeweb }

enum AppSessionPhase {
  uninitialized,
  restoring,
  authenticating,
  authenticated,
  refreshing,
  signingOut,
  signedOut,
  unresolved,
  failed,
  stopped,
  closed,
}

enum AppSessionError {
  disabled,
  invalidRequest,
  notAuthenticated,
  unauthorized,
  unavailable,
  network,
  secureStore,
  localClear,
  staleSession,
  closed,
  unknown,
}

enum AppSessionAdmin { unknown, ordinary, administrator }

/// Identity only. A Firebase adapter maps a real User; it never creates one.
/// Native responses do not carry administrator authority, so it stays unknown.
final class AppSessionIdentity {
  AppSessionIdentity({
    required this.backend,
    required this.uid,
    required this.emailVerified,
    this.email,
    this.displayName,
    this.admin = AppSessionAdmin.unknown,
  }) {
    if (uid.isEmpty || uid.contains('\u0000')) {
      throw ArgumentError('Invalid session identity.');
    }
    if (backend == AppSessionBackend.timeweb &&
        admin != AppSessionAdmin.unknown) {
      throw ArgumentError('Native administrator authority is unavailable.');
    }
  }

  final AppSessionBackend backend;
  final String uid;
  final bool? emailVerified;
  final String? email;
  final String? displayName;
  final AppSessionAdmin admin;
  bool get isAdministrator => admin == AppSessionAdmin.administrator;

  @override
  String toString() => 'AppSessionIdentity(${backend.name}, <redacted>)';
}

final class AppSessionState {
  const AppSessionState._(
    this.backend,
    this.phase,
    this.epoch,
    this.identity,
    this.error,
  );
  final AppSessionBackend backend;
  final AppSessionPhase phase;
  final int epoch;
  final AppSessionIdentity? identity;
  final AppSessionError? error;
  bool get authenticated =>
      identity != null &&
      (phase == AppSessionPhase.authenticated ||
          phase == AppSessionPhase.refreshing);

  @override
  String toString() =>
      'AppSessionState(${backend.name}, ${phase.name}, $epoch)';
}

enum AppSessionOutcome { confirmed, pending, remoteUnknown, failed, superseded }

/// A deadline is pending, not cancellation. [settled] observes the original
/// operation; neither the facade nor its adapter automatically repeats login.
final class AppSessionResult {
  const AppSessionResult._(
    this.outcome, {
    this.error,
    this.logout,
    this.settled,
  });
  final AppSessionOutcome outcome;
  final AppSessionError? error;
  final AppSessionLogout? logout;
  final Future<AppSessionResult>? settled;
  bool get confirmed => outcome == AppSessionOutcome.confirmed;
}

enum AppSessionRemoteLogout { confirmed, rejected, unknown, localOnly }

final class AppSessionLogout {
  const AppSessionLogout({
    required this.remote,
    required this.localCleared,
    required this.allSessions,
  });
  final AppSessionRemoteLogout remote;
  final bool localCleared;
  final bool allSessions;
  bool get remoteConfirmed => remote == AppSessionRemoteLogout.confirmed;
}

/// A lifecycle stop is neither logout nor proof of remote auth confirmation.
final class AppSessionStop {
  const AppSessionStop({
    required this.protectedStateSafe,
    this.remoteOutcomeUnknown = false,
  });
  final bool protectedStateSafe;
  final bool remoteOutcomeUnknown;
}

final class AppSessionException implements Exception {
  const AppSessionException(this.error, {this.remoteOutcomeUnknown = false});
  final AppSessionError error;
  final bool remoteOutcomeUnknown;
  @override
  String toString() => 'AppSessionException(${error.name})';
}

/// Provider methods must await their actual operation, not return a legacy
/// "pending" string as success. The facade supplies a bounded UI wait while
/// keeping the original operation alive and serializing identity mutations.
abstract interface class AppSessionAdapter {
  AppSessionBackend get backend;
  AppSessionIdentity? get currentIdentity;
  Stream<AppSessionIdentity?> get identityChanges;
  Future<AppSessionIdentity?> restore();
  Future<AppSessionIdentity> login({
    required String email,
    required String password,
    required String deviceId,
  });
  Future<AppSessionIdentity> refresh();
  Future<AppSessionLogout> logout({required bool allSessions});

  /// Revoke runtime ownership now; await real auth/store work without starting
  /// credential clearing, signOut, logout or another authentication POST.
  Future<AppSessionStop> stop();

  /// Complete only after in-flight mutations cannot resurrect local identity.
  Future<bool> close();
}

/// A screen captures this before an await and checks it before rendering or
/// hydrating. Logout, A -> B -> A, close and outside-provider events invalidate
/// it, even if the final UID equals the original UID.
final class AppSessionLease {
  AppSessionLease._(
    this._owner,
    this.epoch,
    this.identity,
    this.whenInvalidated,
  );
  final AppSession _owner;
  final int epoch;
  final AppSessionIdentity identity;
  final Future<void> whenInvalidated;
  bool get isCurrent => _owner._isLeaseCurrent(this);
  void requireCurrent() {
    if (!isCurrent) {
      throw const AppSessionException(AppSessionError.staleSession);
    }
  }
}

/// Not wired into AppBackend or UI. Firebase remains the default and only the
/// explicitly selected adapter may determine identity. No cross-provider
/// fallback, preferences-based identity or financial/profile hydration occurs.
final class AppSession {
  AppSession({
    required AppSessionAdapter adapter,
    this.backend = AppSessionBackend.firebase,
    required Future<void> Function() clearLocal,
    this.waitTimeout = const Duration(seconds: 20),
  }) : _adapter = adapter,
       _clearLocal = clearLocal {
    if (adapter.backend != backend || waitTimeout <= Duration.zero) {
      throw ArgumentError('Session adapter does not match selected backend.');
    }
    _state = AppSessionState._(
      backend,
      AppSessionPhase.uninitialized,
      0,
      null,
      null,
    );
    _subscription = adapter.identityChanges.listen(
      _providerChanged,
      onError: (Object _) => _providerFailed(),
    );
  }

  factory AppSession.timeweb({
    required TimewebAuthClient client,
    required Future<void> Function() clearLocal,
    Duration waitTimeout = const Duration(seconds: 20),
  }) => AppSession(
    backend: AppSessionBackend.timeweb,
    adapter: TimewebAppSessionAdapter(client),
    clearLocal: clearLocal,
    waitTimeout: waitTimeout,
  );

  final AppSessionBackend backend;
  final Duration waitTimeout;
  final AppSessionAdapter _adapter;
  final Future<void> Function() _clearLocal;
  final _states = StreamController<AppSessionState>.broadcast();
  late final StreamSubscription<AppSessionIdentity?> _subscription;
  late AppSessionState _state;
  int _epoch = 0;
  int _controlled = 0;
  bool _closed = false;
  Completer<void> _invalidated = Completer<void>();
  final Set<void Function()> _readInvalidations = {};
  Future<void> _clearTail = Future<void>.value();
  Future<void> _mutationTail = Future<void>.value();
  Future<AppSessionResult>? _restoreFlight;
  Future<AppSessionResult>? _loginFlight;
  String? _loginIntent;
  Future<AppSessionResult>? _logoutFlight;
  bool? _logoutAll;
  Future<AppSessionResult>? _refreshFlight;
  Future<AppSessionResult>? _closeFlight;
  Future<AppSessionResult>? _stopFlight;

  /// Read this immediately on subscription; the stream broadcasts changes.
  AppSessionState get state {
    _checkProviderIdentity();
    return _state;
  }

  // Broadcast delivery is asynchronous. Drop a queued A state if B's intent
  // already advanced the epoch before a screen receives that event.
  Stream<AppSessionState> get states =>
      _states.stream.where((snapshot) => snapshot.epoch == _epoch);
  String? get currentUid => state.authenticated ? _state.identity!.uid : null;

  void _publish(
    AppSessionPhase phase, {
    AppSessionIdentity? identity,
    AppSessionError? error,
  }) {
    _state = AppSessionState._(backend, phase, _epoch, identity, error);
    if (!_states.isClosed) _states.add(_state);
  }

  int _newEpoch(AppSessionPhase phase) {
    final canceledReads = _readInvalidations.toList();
    _readInvalidations.clear();
    for (final cancel in canceledReads) {
      cancel();
    }
    if (!_invalidated.isCompleted) _invalidated.complete();
    _invalidated = Completer<void>();
    _epoch++;
    _restoreFlight = null;
    _refreshFlight = null;
    _publish(phase);
    return _epoch;
  }

  bool _current(int epoch) => !_closed && epoch == _epoch;
  bool _same(AppSessionIdentity? a, AppSessionIdentity? b) =>
      a?.uid == b?.uid && a?.backend == b?.backend;
  AppSessionIdentity? _providerIdentity() {
    try {
      final identity = _adapter.currentIdentity;
      if (identity != null && identity.backend != backend) {
        throw const AppSessionException(AppSessionError.unavailable);
      }
      return identity;
    } on AppSessionException {
      rethrow;
    } catch (_) {
      throw const AppSessionException(AppSessionError.unavailable);
    }
  }

  bool _matchesProvider(AppSessionIdentity? identity) {
    try {
      return _same(identity, _providerIdentity());
    } catch (_) {
      return false;
    }
  }

  void _checkProviderIdentity() {
    if (_closed || !_state.authenticated) return;
    try {
      if (!_same(_state.identity, _providerIdentity())) {
        _providerChanged(_providerIdentity());
      }
    } catch (_) {
      _providerFailed();
    }
  }

  Future<void> _clear() {
    final next = _clearTail.then((_) => _clearLocal());
    _clearTail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  void _providerFailed() {
    if (_closed || _controlled > 0) return;
    final epoch = _newEpoch(AppSessionPhase.failed);
    _clear().then(
      (_) {
        if (_current(epoch)) {
          _publish(AppSessionPhase.failed, error: AppSessionError.unavailable);
        }
      },
      onError: (Object _) {
        if (_current(epoch)) {
          _publish(AppSessionPhase.failed, error: AppSessionError.localClear);
        }
      },
    );
  }

  void _providerChanged(AppSessionIdentity? identity) {
    if (_closed || _controlled > 0) return;
    if (identity != null && identity.backend != backend) {
      _providerFailed();
      return;
    }
    if (identity == null &&
        _state.identity == null &&
        const {
          AppSessionPhase.signedOut,
          AppSessionPhase.unresolved,
          AppSessionPhase.failed,
        }.contains(_state.phase)) {
      return;
    }
    // Preserve each emitted null/account boundary, not only the final UID.
    if (_same(_state.identity, identity) && _state.authenticated) {
      _publish(AppSessionPhase.authenticated, identity: identity);
      return;
    }
    final epoch = _newEpoch(AppSessionPhase.restoring);
    _clear().then(
      (_) {
        if (!_current(epoch)) return;
        try {
          final actual = _providerIdentity();
          if (!_same(identity, actual)) {
            _providerChanged(actual);
            return;
          }
          _publish(
            actual == null
                ? AppSessionPhase.signedOut
                : AppSessionPhase.authenticated,
            identity: actual,
          );
        } catch (_) {
          _providerFailed();
        }
      },
      onError: (Object _) {
        if (_current(epoch)) {
          _publish(AppSessionPhase.failed, error: AppSessionError.localClear);
        }
      },
    );
  }

  AppSessionLease captureLease() {
    final current = state;
    if (!current.authenticated) {
      throw const AppSessionException(AppSessionError.notAuthenticated);
    }
    return AppSessionLease._(
      this,
      _epoch,
      current.identity!,
      _invalidated.future,
    );
  }

  bool _isLeaseCurrent(AppSessionLease lease) {
    final current = state;
    return identical(lease._owner, this) &&
        !_closed &&
        lease.epoch == _epoch &&
        current.authenticated &&
        _same(lease.identity, current.identity);
  }

  /// Use this boundary for provider reads. Native refresh/read failures can
  /// invalidate its tokens without a Firebase-style identity stream.
  Future<T> runAuthenticated<T>(
    Future<T> Function(AppSessionLease) action,
  ) async {
    final lease = captureLease();
    final result = Completer<T>();
    void cancel() {
      if (!result.isCompleted) {
        result.completeError(
          const AppSessionException(AppSessionError.staleSession),
        );
      }
    }

    _readInvalidations.add(cancel);
    // Keep observing the real operation after UI cancellation. Its late error
    // is consumed and its result cannot enter the new account. Remove the
    // invalidation listener on ordinary completion, so a long session does not
    // retain all its earlier completed media/profile results until logout.
    Future<T>.sync(() => action(lease)).then(
      (value) {
        if (result.isCompleted) return;
        try {
          lease.requireCurrent();
          result.complete(value);
        } catch (error, stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    try {
      return await result.future;
    } finally {
      _readInvalidations.remove(cancel);
      _checkProviderIdentity();
    }
  }

  Future<AppSessionResult> _bounded(Future<AppSessionResult> operation) =>
      operation.timeout(
        waitTimeout,
        onTimeout: () =>
            AppSessionResult._(AppSessionOutcome.pending, settled: operation),
      );

  Future<AppSessionResult> _mutate(
    int epoch,
    Future<AppSessionResult> Function() action,
  ) {
    // Suppress provider events from submission, including the microtask before
    // the queued action starts. A Firebase bootstrap event must not supersede
    // its own explicit restore.
    _controlled++;
    final operation = _mutationTail.then((_) async {
      try {
        if (!_current(epoch)) {
          return const AppSessionResult._(AppSessionOutcome.superseded);
        }
        return await action();
      } catch (error) {
        return _failed(epoch, error);
      } finally {
        _controlled--;
      }
    });
    _mutationTail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> _adopt(int epoch, AppSessionIdentity? identity) async {
    if (!_current(epoch)) return;
    if ((identity != null && identity.backend != backend) ||
        !_same(identity, _providerIdentity())) {
      throw const AppSessionException(AppSessionError.staleSession);
    }
    _publish(
      identity == null
          ? AppSessionPhase.signedOut
          : AppSessionPhase.authenticated,
      identity: identity,
    );
  }

  AppSessionResult _failed(
    int epoch,
    Object error, {
    AppSessionLogout? logout,
  }) {
    if (!_current(epoch)) {
      return const AppSessionResult._(AppSessionOutcome.superseded);
    }
    final mapped = error is AppSessionException
        ? error
        : const AppSessionException(AppSessionError.unknown);
    _publish(
      mapped.remoteOutcomeUnknown
          ? AppSessionPhase.unresolved
          : AppSessionPhase.failed,
      error: mapped.error,
    );
    return AppSessionResult._(
      mapped.remoteOutcomeUnknown
          ? AppSessionOutcome.remoteUnknown
          : AppSessionOutcome.failed,
      error: mapped.error,
      logout: logout,
    );
  }

  Future<AppSessionResult> restore() {
    if (_closed) {
      return Future.value(
        const AppSessionResult._(
          AppSessionOutcome.failed,
          error: AppSessionError.closed,
        ),
      );
    }
    final logout = _logoutFlight;
    if (_state.phase == AppSessionPhase.signingOut && logout != null) {
      return _bounded(logout);
    }
    final pending = _restoreFlight;
    if (pending != null) return _bounded(pending);
    final login = _loginFlight;
    if (login != null) return _bounded(login);
    if (_state.phase == AppSessionPhase.authenticated ||
        _state.phase == AppSessionPhase.signedOut) {
      return Future.value(
        const AppSessionResult._(AppSessionOutcome.confirmed),
      );
    }
    final epoch = _newEpoch(AppSessionPhase.restoring);
    late Future<AppSessionResult> operation;
    operation =
        _mutate(epoch, () async {
          await _clearOrThrow();
          if (!_current(epoch)) {
            return const AppSessionResult._(AppSessionOutcome.superseded);
          }
          final identity = await _adapter.restore();
          await _adopt(epoch, identity);
          return AppSessionResult._(
            _current(epoch)
                ? AppSessionOutcome.confirmed
                : AppSessionOutcome.superseded,
          );
        }).whenComplete(() {
          if (identical(_restoreFlight, operation)) _restoreFlight = null;
        });
    _restoreFlight = operation;
    return _bounded(operation);
  }

  Future<void> _clearOrThrow() async {
    try {
      await _clear();
    } catch (_) {
      throw const AppSessionException(AppSessionError.localClear);
    }
  }

  Future<AppSessionResult> login({
    required String email,
    required String password,
    required String deviceId,
  }) {
    if (_closed) {
      return Future.value(
        const AppSessionResult._(
          AppSessionOutcome.failed,
          error: AppSessionError.closed,
        ),
      );
    }
    final intent = '${email.trim().toLowerCase()}\u0000$deviceId';
    final pending = _loginFlight;
    if (pending != null && _loginIntent == intent) return _bounded(pending);
    final epoch = _newEpoch(AppSessionPhase.authenticating);
    late Future<AppSessionResult> operation;
    operation =
        _mutate(epoch, () async {
          await _clearOrThrow();
          if (!_current(epoch)) {
            return const AppSessionResult._(AppSessionOutcome.superseded);
          }
          final identity = await _adapter.login(
            email: email,
            password: password,
            deviceId: deviceId,
          );
          await _adopt(epoch, identity);
          return AppSessionResult._(
            _current(epoch)
                ? AppSessionOutcome.confirmed
                : AppSessionOutcome.superseded,
          );
        }).whenComplete(() {
          if (identical(_loginFlight, operation)) {
            _loginFlight = null;
            _loginIntent = null;
          }
        });
    _loginFlight = operation;
    _loginIntent = intent;
    return _bounded(operation);
  }

  Future<AppSessionResult> refresh() {
    if (_closed) {
      return Future.value(
        const AppSessionResult._(
          AppSessionOutcome.failed,
          error: AppSessionError.closed,
        ),
      );
    }
    final pending = _refreshFlight;
    if (pending != null) return _bounded(pending);
    final identity = state.identity;
    if (!state.authenticated || identity == null) {
      return Future.value(
        const AppSessionResult._(
          AppSessionOutcome.failed,
          error: AppSessionError.notAuthenticated,
        ),
      );
    }
    final epoch = _epoch;
    _publish(AppSessionPhase.refreshing, identity: identity);
    late Future<AppSessionResult> operation;
    operation =
        (() async {
          try {
            final refreshed = await _adapter.refresh();
            if (!_same(identity, refreshed)) {
              throw const AppSessionException(AppSessionError.staleSession);
            }
            await _adopt(epoch, refreshed);
            return AppSessionResult._(
              _current(epoch)
                  ? AppSessionOutcome.confirmed
                  : AppSessionOutcome.superseded,
            );
          } catch (error) {
            if (_current(epoch) &&
                _matchesProvider(identity) &&
                error is AppSessionException &&
                !error.remoteOutcomeUnknown) {
              _publish(
                AppSessionPhase.authenticated,
                identity: identity,
                error: error.error,
              );
              return AppSessionResult._(
                AppSessionOutcome.failed,
                error: error.error,
              );
            }
            if (_current(epoch)) {
              final next = _newEpoch(AppSessionPhase.unresolved);
              try {
                await _clearOrThrow();
              } catch (clearError) {
                return _failed(next, clearError);
              }
              return _failed(next, error);
            }
            return const AppSessionResult._(AppSessionOutcome.superseded);
          }
        })().whenComplete(() {
          if (identical(_refreshFlight, operation)) _refreshFlight = null;
        });
    _refreshFlight = operation;
    return _bounded(operation);
  }

  Future<AppSessionResult> logout({bool allSessions = false}) {
    if (_closed) {
      return Future.value(
        const AppSessionResult._(
          AppSessionOutcome.failed,
          error: AppSessionError.closed,
        ),
      );
    }
    final pending = _logoutFlight;
    if (_state.phase == AppSessionPhase.signingOut &&
        pending != null &&
        _logoutAll == allSessions) {
      return _bounded(pending);
    }
    final epoch = _newEpoch(AppSessionPhase.signingOut);
    final clearing = _clear().then((_) => true, onError: (Object _) => false);
    late Future<AppSessionResult> operation;
    operation =
        _mutate(epoch, () async {
          AppSessionLogout? result;
          Object? failure;
          try {
            result = await _adapter.logout(allSessions: allSessions);
          } catch (error) {
            failure = error;
          }
          try {
            if (!await clearing) {
              throw const AppSessionException(AppSessionError.localClear);
            }
          } catch (error) {
            return _failed(epoch, error, logout: result);
          }
          if (!_current(epoch)) {
            return const AppSessionResult._(AppSessionOutcome.superseded);
          }
          if (failure != null) return _failed(epoch, failure);
          if (_providerIdentity() != null || !result!.localCleared) {
            return _failed(
              epoch,
              const AppSessionException(AppSessionError.secureStore),
              logout: result,
            );
          }
          _publish(AppSessionPhase.signedOut);
          return AppSessionResult._(
            result.remote == AppSessionRemoteLogout.unknown
                ? AppSessionOutcome.remoteUnknown
                : AppSessionOutcome.confirmed,
            logout: result,
          );
        }).whenComplete(() {
          if (identical(_logoutFlight, operation)) {
            _logoutFlight = null;
            _logoutAll = null;
          }
        });
    _logoutFlight = operation;
    _logoutAll = allSessions;
    return _bounded(operation);
  }

  Future<AppSessionResult> close() {
    final pending = _closeFlight;
    if (pending != null) return _bounded(pending);
    _newEpoch(AppSessionPhase.closed);
    _closed = true;
    final operation = _mutationTail.then((_) async {
      bool cleared = false;
      var error = AppSessionError.secureStore;
      try {
        cleared = await _adapter.close();
      } catch (_) {
        /* Keep the local-clear attempt independent. */
      }
      try {
        await _clearOrThrow();
      } catch (_) {
        cleared = false;
        error = AppSessionError.localClear;
      }
      await _subscription.cancel();
      await _states.close();
      return AppSessionResult._(
        cleared ? AppSessionOutcome.confirmed : AppSessionOutcome.failed,
        error: cleared ? null : error,
      );
    });
    _closeFlight = operation;
    return _bounded(operation);
  }

  /// Normal remembered-session teardown. The owner is immediately inert; the
  /// adapter drains already started auth so successful rotation is persisted.
  /// No extra local clear or remote logout is initiated by this lifecycle path.
  Future<AppSessionResult> stop() {
    if (_closeFlight != null || _state.phase == AppSessionPhase.closed) {
      return Future.value(
        const AppSessionResult._(
          AppSessionOutcome.failed,
          error: AppSessionError.closed,
        ),
      );
    }
    final pending = _stopFlight;
    if (pending != null) return _bounded(pending);
    if (_closed) {
      return Future.value(
        const AppSessionResult._(
          AppSessionOutcome.failed,
          error: AppSessionError.closed,
        ),
      );
    }
    final refresh = _refreshFlight;
    _newEpoch(AppSessionPhase.stopped);
    _closed = true;
    final providerStop = Future<AppSessionStop>.sync(_adapter.stop);
    // Attach error observation immediately, even while another tail drains.
    final stopResult = providerStop.then<AppSessionStop>(
      (value) => value,
      onError: (Object _) => const AppSessionStop(protectedStateSafe: false),
    );
    final operation = (() async {
      await _mutationTail;
      if (refresh != null) await refresh;
      await _clearTail;
      final result = await stopResult;
      await _subscription.cancel();
      await _states.close();
      return AppSessionResult._(
        result.remoteOutcomeUnknown
            ? AppSessionOutcome.remoteUnknown
            : result.protectedStateSafe
            ? AppSessionOutcome.confirmed
            : AppSessionOutcome.failed,
        error: result.protectedStateSafe ? null : AppSessionError.secureStore,
      );
    })();
    _stopFlight = operation;
    // Explicit subsequent close remains destructive but waits this stop drain.
    _mutationTail = operation.then<void>((_) {}, onError: (Object _) {});
    return _bounded(operation);
  }
}

/// Uses the existing native transport/store, including its shared refresh,
/// unknown-POST handling and credential clearing. Never exposes bearer tokens.
final class TimewebAppSessionAdapter implements AppSessionAdapter {
  TimewebAppSessionAdapter(this._client);
  final TimewebAuthClient _client;
  final _changes = StreamController<AppSessionIdentity?>.broadcast();
  AppSessionIdentity? _identity;
  @override
  AppSessionBackend get backend => AppSessionBackend.timeweb;
  @override
  AppSessionIdentity? get currentIdentity {
    if (!_client.hasSession) return null;
    final uid = _client.currentUid;
    if (uid == null) return null;
    if (_identity?.uid == uid) return _identity;
    return AppSessionIdentity(backend: backend, uid: uid, emailVerified: null);
  }

  @override
  Stream<AppSessionIdentity?> get identityChanges => _changes.stream;
  AppSessionIdentity _accept(TimewebSession session) {
    _identity = AppSessionIdentity(
      backend: backend,
      uid: session.uid,
      emailVerified: session.emailVerified,
    );
    return _identity!;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(currentIdentity);
  }

  Future<T> _call<T>(
    Future<T> Function() action, {
    bool emitFailures = true,
  }) async {
    var failed = false;
    try {
      return await action();
    } on TimewebAuthException catch (error) {
      failed = true;
      throw AppSessionException(switch (error.error) {
        TimewebAuthError.disabled => AppSessionError.disabled,
        TimewebAuthError.invalidRequest => AppSessionError.invalidRequest,
        TimewebAuthError.notAuthenticated => AppSessionError.notAuthenticated,
        TimewebAuthError.unauthorized => AppSessionError.unauthorized,
        TimewebAuthError.network => AppSessionError.network,
        TimewebAuthError.secureStore => AppSessionError.secureStore,
        TimewebAuthError.staleSession => AppSessionError.staleSession,
        TimewebAuthError.closed => AppSessionError.closed,
        _ => AppSessionError.unavailable,
      }, remoteOutcomeUnknown: error is TimewebUnknownOutcome);
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      if (!failed || emitFailures) _emit();
    }
  }

  @override
  Future<AppSessionIdentity?> restore() => _call(() async {
    final session = await _client.restore();
    return session == null ? null : _accept(session);
  });
  @override
  Future<AppSessionIdentity> login({
    required String email,
    required String password,
    required String deviceId,
  }) => _call(
    () async => _accept(
      await _client.login(email: email, password: password, deviceId: deviceId),
    ),
  );
  @override
  Future<AppSessionIdentity> refresh() =>
      // The facade must classify the terminal refresh error before reconciling
      // a null identity. Otherwise its own null event makes that result look
      // superseded and hides an unknown refresh POST outcome.
      _call(() async => _accept(await _client.refresh()), emitFailures: false);
  @override
  Future<AppSessionLogout> logout({
    required bool allSessions,
  }) => _call(() async {
    final result = await _client.logout(allSessions: allSessions);
    if (result.superseded) {
      throw const AppSessionException(AppSessionError.staleSession);
    }
    return AppSessionLogout(
      remote: switch (result.outcome) {
        TimewebLogoutOutcome.confirmed => AppSessionRemoteLogout.confirmed,
        TimewebLogoutOutcome.accessRejected => AppSessionRemoteLogout.rejected,
        TimewebLogoutOutcome.remoteUnknown => AppSessionRemoteLogout.unknown,
        TimewebLogoutOutcome.localOnly => AppSessionRemoteLogout.localOnly,
      },
      localCleared: result.secureTokensCleared,
      allSessions: result.allSessions,
    );
  });
  @override
  Future<bool> close() async {
    final cleared = await _client.close();
    _identity = null;
    await _changes.close();
    return cleared;
  }

  @override
  Future<AppSessionStop> stop() async {
    final stopping = _client
        .stop(); // Runtime invalidation occurs before await.
    _identity = null;
    final result = await stopping;
    await _changes.close();
    return AppSessionStop(
      protectedStateSafe: result.protectedStateSafe,
      remoteOutcomeUnknown: result.remoteOutcomeUnknown,
    );
  }
}
