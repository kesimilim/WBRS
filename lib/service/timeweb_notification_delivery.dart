import 'dart:async';
import 'dart:convert';

import 'app_session.dart';
import 'timeweb_app_runtime.dart';
import 'timeweb_auth_client.dart';

/// FCM is transport only. Each foreground/tap resolves its own source record.
final class TimewebNotificationDelivery {
  TimewebNotificationDelivery({
    required this.runtime,
    required this.onForeground,
    required this.onTap,
    this.onClear,
  });
  final TimewebAppRuntime runtime;
  final Future<void> Function(TimewebNotification item, bool sound)
  onForeground;
  final Future<void> Function(TimewebNotification item) onTap;
  final void Function()? onClear;
  StreamSubscription<AppSessionState>? _states;
  _NativeDelivery? _pending;
  Future<void>? _flight;
  bool _closed = false;
  int? _activeEpoch;
  void start() {
    if (_closed || _states != null) return;
    _states = runtime.session.states.listen((state) {
      if (_activeEpoch != null &&
          (!state.authenticated || state.epoch != _activeEpoch)) {
        _pending = null;
        onClear?.call();
      }
      if (state.authenticated) unawaited(_drain());
    });
  }

  Future<void> receive(Map<String, dynamic> data, {required bool opened}) {
    if (_closed) return Future.value();
    final delivery = _NativeDelivery.parse(data, opened, runtime.session.state);
    if (delivery == null) return Future.value();
    if (!runtime.session.state.authenticated && !opened) return Future.value();
    _pending = delivery; // one bounded latest signal, never a durable message.
    return _drain();
  }

  Future<void> receiveLocal(String payload) {
    if (_closed ||
        payload.length > 1024 ||
        !payload.startsWith('native-notification:')) {
      return Future.value();
    }
    try {
      final value = jsonDecode(
        payload.substring('native-notification:'.length),
      );
      if (value is! Map<String, dynamic> ||
          value.length != 2 ||
          value['recipientUid'] is! String ||
          value['recipientUid'].runes.length > 191 ||
          value['notificationId'] is! String ||
          !RegExp(r'^e:[1-9][0-9]{0,18}$').hasMatch(value['notificationId']) ||
          int.tryParse(value['notificationId'].substring(2)) == null) {
        return Future.value();
      }
      _pending = _NativeDelivery(
        value['notificationId'],
        value['recipientUid'],
        null,
        null,
        false,
        true,
        runtime.session.state.authenticated
            ? runtime.session.state.epoch
            : null,
      );
      return _drain();
    } catch (_) {
      return Future.value();
    }
  }

  Future<void> _drain() {
    if (_closed || !runtime.session.state.authenticated) return Future.value();
    if (_flight != null) return _flight!;
    late Future<void> future;
    future =
        (() async {
          while (!_closed &&
              _pending != null &&
              runtime.session.state.authenticated) {
            final delivery = _pending!;
            _pending = null;
            final lease = runtime.session.captureLease();
            _activeEpoch = lease.epoch;
            if (delivery.uid != lease.identity.uid ||
                delivery.epoch != null && delivery.epoch != lease.epoch) {
              continue;
            }
            try {
              final item = await runtime.readNotification(delivery.id);
              lease.requireCurrent();
              item.requireCurrent();
              if (_closed ||
                  delivery.kind != null &&
                      (item.targetKind != delivery.kind ||
                          item.targetId != delivery.target)) {
                continue;
              }
              if (delivery.opened) {
                await onTap(item);
              } else {
                final preferences = await runtime.readPreferences();
                lease.requireCurrent();
                item.requireCurrent();
                preferences.requireCurrent();
                if (_closed ||
                    (delivery.kind == 'chat'
                        ? !preferences.messages
                        : !preferences.meetings)) {
                  continue;
                }
                await onForeground(item, preferences.sound && delivery.sound);
              }
              lease.requireCurrent();
            } catch (_) {
              // No unproven target fallback, auth retry loop or persisted payload.
            }
          }
        })().whenComplete(() {
          if (identical(_flight, future)) _flight = null;
        });
    _flight = future;
    return future;
  }

  void close() {
    _closed = true;
    _pending = null;
    unawaited(_states?.cancel());
    _states = null;
  }
}

final class _NativeDelivery {
  _NativeDelivery(
    this.id,
    this.uid,
    this.kind,
    this.target,
    this.sound,
    this.opened,
    this.epoch,
  );
  final String id, uid;
  final String? kind, target;
  final bool sound, opened;
  final int? epoch;
  static _NativeDelivery? parse(
    Map<String, dynamic> data,
    bool opened,
    AppSessionState state,
  ) {
    final kind = data['kind'],
        key = kind == 'native-chat'
            ? 'chatId'
            : kind == 'native-meeting'
            ? 'meetingId'
            : null;
    if (key == null ||
        data.length != 6 ||
        !data.keys.toSet().containsAll({
          'kind',
          'recipientUid',
          'messageId',
          'notificationId',
          key,
          'soundEnabled',
        })) {
      return null;
    }
    bool id(Object? v) =>
        v is String &&
        v.isNotEmpty &&
        v.runes.length <= 191 &&
        v != '.' &&
        v != '..' &&
        !v.contains('/') &&
        utf8.decode(utf8.encode(v)) == v &&
        !v.runes.any((r) => r < 32 || r == 127 || r >= 0xd800 && r <= 0xdfff);
    final notification = data['notificationId'];
    if (!id(data['recipientUid']) ||
        !id(data[key]) ||
        !id(data['messageId']) ||
        notification is! String ||
        !RegExp(r'^e:[1-9][0-9]{0,18}$').hasMatch(notification) ||
        int.tryParse(notification.substring(2)) == null ||
        !const ['true', 'false'].contains(data['soundEnabled'])) {
      return null;
    }
    return _NativeDelivery(
      notification,
      data['recipientUid'],
      key == 'chatId' ? 'chat' : 'meeting',
      data[key],
      data['soundEnabled'] == 'true',
      opened,
      state.authenticated ? state.epoch : null,
    );
  }
}
