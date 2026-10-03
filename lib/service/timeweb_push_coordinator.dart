import 'dart:async';

import 'timeweb_app_runtime.dart';
import 'timeweb_auth_client.dart';
import 'timeweb_push_flow.dart';

/// FCM is infrastructure only. Every token read/event is attached to the
/// current native lease; logout clears RAM before a late platform reply arrives.
final class TimewebPushCoordinator {
  TimewebPushCoordinator({
    required this.runtime,
    required this.readToken,
    required this.tokenRefreshes,
  });
  final TimewebAppRuntime runtime;
  final Future<String?> Function() readToken;
  final Stream<String> tokenRefreshes;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  TimewebPushFlow? _flow;
  Future<void>? _active;
  String? _token, _settledKey;
  int? _epoch;
  bool _closed = false, _again = false;

  void start() {
    if (_closed || _subscriptions.isNotEmpty || !runtime.pushEnabled) return;
    _subscriptions.add(runtime.session.states.listen((_) => _sessionChanged()));
    _subscriptions.add(
      runtime.client.sessionRefreshes.listen((_) => _sessionChanged()),
    );
    _subscriptions.add(
      tokenRefreshes.listen((token) {
        if (_closed || !runtime.session.state.authenticated) return;
        _token = token;
        _schedule();
      }, onError: (Object _) {}),
    );
    _sessionChanged();
  }

  void _sessionChanged() {
    final state = runtime.session.state;
    if (_epoch != state.epoch || !state.authenticated) {
      _flow?.close();
      _flow = null;
      _token = null;
      _settledKey = null;
      _epoch = state.epoch;
    }
    if (state.authenticated) _schedule();
  }

  void _schedule() => unawaited(synchronize().catchError((Object _) {}));

  /// Resume/restart performs original receipt lookup if unresolved. No timer
  /// retries a POST, and not_found does not permit another operation UUID.
  Future<void> synchronize() {
    if (_closed) return Future.value();
    final previous = _active;
    if (previous != null) {
      _again = true;
      return previous;
    }
    final future = _run();
    _active = future;
    unawaited(
      future.then<void>(
        (_) => _settled(future),
        onError: (Object _, StackTrace __) => _settled(future),
      ),
    );
    return future;
  }

  void _settled(Future<void> future) {
    if (identical(_active, future)) _active = null;
    if (_again && !_closed) {
      _again = false;
      _schedule();
    }
  }

  Future<void> _run() async {
    if (!runtime.pushEnabled || !runtime.session.state.authenticated) return;
    final lease = runtime.session.captureLease();
    void current() {
      if (_closed) throw StateError('Native push is closed.');
      lease.requireCurrent();
    }

    current();
    var flow = _flow;
    if (flow == null) {
      flow = await runtime.openPush();
      try {
        current();
      } catch (_) {
        flow.close();
        rethrow;
      }
      _flow = flow;
    }
    if (flow.needsCheck) {
      final original = flow.pendingAction!;
      final result = await flow.check();
      current();
      if (result == TimewebPushOutcome.unknown) return;
      _settledKey = '${original.sessionId}:${original.tokenHash ?? 'revoke'}';
    }
    final token = _token ?? await readToken();
    current();
    if (token == null) return;
    _token = token;
    final sid = await runtime.client.preparePushSession();
    current();
    final action = TimewebPushAction.register(sessionId: sid, token: token);
    final key = '$sid:${action.tokenHash}';
    if (_settledKey == key) {
      action.discardToken();
      return;
    }
    final result = await flow.submit(action);
    current();
    if (result != TimewebPushOutcome.unknown) _settledKey = key;
  }

  void close() {
    _closed = true;
    _again = false;
    _token = null;
    _settledKey = null;
    _flow?.close();
    _flow = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }
}
