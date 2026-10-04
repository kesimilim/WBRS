import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:wbrs/presentation/widgets/timeweb_profile_photos_view.dart'
    show decodeProfilePhoto;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/group_badge.dart';
import 'package:wbrs/shared/lrs_theme.dart';

// Lazy lists can still mount many visible/cache rows at once. Keep only two
// avatar chains active, with at most 32 mounted owners waiting for admission.
class _AvatarReadAdmission {
  _AvatarReadAdmission._(this.check);
  static final _pending = <_AvatarReadAdmission>[];
  static int _active = 0;
  final void Function() check;
  final ready = Completer<void>();
  Timer? _timer;
  bool _started = false, _finished = false;

  static _AvatarReadAdmission acquire(
    void Function() check,
    Duration deadline,
  ) {
    final admission = _AvatarReadAdmission._(check);
    try {
      check();
      if (_active < 2) {
        admission._start();
      } else if (_pending.length < 32) {
        _pending.add(admission);
        admission._timer = Timer(deadline, admission.cancel);
      } else {
        admission.cancel();
      }
    } catch (_) {
      admission.cancel();
    }
    return admission;
  }

  void _start() {
    _timer?.cancel();
    _started = true;
    _active++;
    ready.complete();
  }

  void cancel() {
    // A running owner releases its lane in finally, after its read settles.
    if (_finished || _started) return;
    _finished = true;
    _timer?.cancel();
    _pending.remove(this);
    ready.completeError(const TimewebProfilePhotoUnavailable());
  }

  void release() {
    if (_finished) return;
    if (!_started) {
      cancel();
      return;
    }
    _finished = true;
    _active--;
    while (_active < 2 && _pending.isNotEmpty) {
      final next = _pending.removeAt(0);
      try {
        next.check();
        next._start();
      } catch (_) {
        next.cancel();
      }
    }
  }
}

/// The familiar thin group ring, with native bytes kept only by this view.
class TimewebChatAvatar extends StatefulWidget {
  const TimewebChatAvatar({
    super.key,
    required this.runtime,
    required this.uid,
    this.primaryGroup,
    this.readGroup = true,
    this.size = 46,
    this.photoIdentity,
  });
  final TimewebAppRuntime runtime;
  final String uid;
  final String? primaryGroup;
  final bool readGroup;
  final double size;
  // An explicit refresh or changed source person can invalidate one avatar.
  final Object? photoIdentity;
  @override
  State<TimewebChatAvatar> createState() => _TimewebChatAvatarState();
}

class _TimewebChatAvatarState extends State<TimewebChatAvatar> {
  late AppSessionLease _lease;
  StreamSubscription<AppSessionState>? _states;
  TimewebProfilePhotoReader? _reader;
  _AvatarReadAdmission? _admission;
  ui.Image? _image;
  String? _group;
  int _generation = 0;
  bool get _current => mounted && _lease.isCurrent;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _lease = widget.runtime.session.captureLease();
    _group = widget.primaryGroup;
    _states = widget.runtime.session.states.listen((_) {
      if (!_current) {
        _clear();
        if (mounted) setState(() {});
      }
    });
    unawaited(_load());
  }

  void _clear() {
    _generation++;
    _admission?.cancel();
    _admission = null;
    final reader = _reader;
    _reader = null;
    if (reader != null) unawaited(reader.close());
    _image?.dispose();
    _image = null;
    _group = null;
  }

  void _check(int generation) {
    _lease.requireCurrent();
    if (!mounted || generation != _generation) {
      throw const TimewebProfilePhotoUnavailable();
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    final admission = _AvatarReadAdmission.acquire(
      () => _check(generation),
      widget.runtime.client.requestDeadline,
    );
    _admission = admission;
    try {
      await admission.ready.future;
      _check(generation);
      final reader = widget.runtime.profilePhotosEnabled
          ? await widget.runtime.openProfilePhotos(widget.uid)
          : null;
      if (reader != null) {
        try {
          _check(generation);
        } catch (_) {
          await reader.close();
          rethrow;
        }
        _reader = reader;
      }
      if (widget.readGroup && widget.runtime.peopleEnabled) {
        try {
          await reader?.waitForReadCapacity();
          _check(generation);
          final person = await widget.runtime.readPerson(widget.uid);
          _check(generation);
          person.requireCurrent();
          setState(() => _group = person.primaryGroup);
        } catch (_) {
          // Photo authorization is independent of optional group information.
          _check(generation);
          reader?.requireCurrent();
        }
      }
      if (reader == null) return;
      _check(generation);
      final page = await reader.photos(limit: 1, waitForCapacity: true);
      _check(generation);
      page.requireCurrent();
      if (page.items.isEmpty) return;
      _check(generation);
      final original = await reader.readOriginal(
        page.items.first,
        waitForCapacity: true,
      );
      _check(generation);
      if (!mounted) return;
      final displayPixels =
          ((widget.size - 6) *
                  (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1))
              .ceil()
              .clamp(1, 1024);
      final decoded = await decodeProfilePhoto(
        original.bytes,
        original.contentType,
        () {
          _check(generation);
          reader.requireCurrent();
        },
        displayPixels: displayPixels,
      );
      try {
        _check(generation);
        reader.requireCurrent();
        setState(() => _image = decoded);
      } catch (_) {
        decoded.dispose();
        rethrow;
      }
    } catch (_) {
      // An unavailable photo/group stays unknown; never guess a URL or group.
    } finally {
      admission.release();
      if (identical(_admission, admission)) _admission = null;
    }
  }

  @override
  void didUpdateWidget(covariant TimewebChatAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid ||
        !identical(oldWidget.runtime, widget.runtime) ||
        oldWidget.photoIdentity != widget.photoIdentity) {
      _clear();
      unawaited(_states?.cancel());
      _bind();
    } else if (oldWidget.primaryGroup != widget.primaryGroup) {
      _group = widget.primaryGroup;
    }
  }

  @override
  void dispose() {
    _clear();
    unawaited(_states?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: CustomPaint(
      painter: GroupRingPainter(
        groupColors(_current ? _group ?? '' : ''),
        strokeWidth: 1.2,
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: ClipOval(
          child: _current && _image != null
              ? RawImage(image: _image, fit: BoxFit.cover)
              : const ColoredBox(
                  color: LrsTheme.surface,
                  child: Icon(Icons.person_outline, color: LrsTheme.peachLight),
                ),
        ),
      ),
    ),
  );
}
