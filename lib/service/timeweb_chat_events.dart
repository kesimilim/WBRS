import 'dart:async';

import 'timeweb_auth_client.dart';

/// One visible account's bounded event cursor. Events invalidate current
/// reads; they never become optimistic messages or a second write transport.
final class TimewebChatEventPump {
  TimewebChatEventPump({
    required this.read,
    required this.apply,
    required this.isCurrent,
    required this.isVisible,
    this.interval = const Duration(seconds: 8),
    this.catchupInterval = const Duration(seconds: 1),
  });

  final Future<TimewebCurrentReadPage> Function(TimewebCurrentReadCursor?) read;
  final Future<bool> Function(List<TimewebCurrentEvent>) apply;
  final bool Function() isCurrent, isVisible;
  final Duration interval, catchupInterval;
  Timer? _timer;
  Future<void>? _flight;
  TimewebCurrentReadCursor? _checkpoint;
  bool _active = false, _closed = false, _more = false;
  int _generation = 0, _failures = 0;

  void start({bool immediate = true}) {
    if (_closed) return;
    _active = true;
    _schedule(immediate ? Duration.zero : interval);
  }

  void pause() {
    _active = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void close() {
    pause();
    _closed = true;
    _checkpoint = null;
  }

  bool get _current => !_closed && isCurrent();
  bool get _canRead => _active && _current && isVisible();

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_active || _closed) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(pollNow());
    });
  }

  /// Coalesces concurrent foreground ticks. A skipped/busy consumer retains
  /// the original checkpoint, so an event arriving during send is not lost.
  Future<void> pollNow() {
    if (_flight != null) return _flight!;
    if (!_current) {
      close();
      return Future.value();
    }
    if (!_canRead) {
      _schedule(interval);
      return Future.value();
    }
    _timer?.cancel();
    final generation = _generation;
    final future = (() async {
      try {
        final page = await read(_checkpoint);
        if (!_canRead || generation != _generation) return;
        page.requireCurrent();
        if (!await apply(page.events)) return;
        if (!_canRead || generation != _generation) return;
        page.requireCurrent();
        _checkpoint = page.eventCheckpoint;
        _more = page.nextCursor != null;
        _failures = 0;
      } catch (_) {
        if (_current && generation == _generation) {
          _failures = (_failures + 1).clamp(0, 3);
        }
      }
    })();
    _flight = future;
    unawaited(
      future.then<void>((_) {
        if (identical(_flight, future)) _flight = null;
        if (!_current) {
          close();
        } else {
          final delay = _failures > 0
              ? Duration(
                  seconds: (interval.inSeconds * (1 << _failures)).clamp(1, 60),
                )
              : (_more ? catchupInterval : interval);
          _schedule(delay);
        }
      }),
    );
    return future;
  }
}
