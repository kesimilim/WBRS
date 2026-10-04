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

/// The familiar thin group ring, with native bytes kept only by this view.
class TimewebChatAvatar extends StatefulWidget {
  const TimewebChatAvatar({
    super.key,
    required this.runtime,
    required this.uid,
    this.primaryGroup,
    this.readGroup = true,
    this.size = 46,
  });
  final TimewebAppRuntime runtime;
  final String uid;
  final String? primaryGroup;
  final bool readGroup;
  final double size;
  @override
  State<TimewebChatAvatar> createState() => _TimewebChatAvatarState();
}

class _TimewebChatAvatarState extends State<TimewebChatAvatar> {
  late AppSessionLease _lease;
  StreamSubscription<AppSessionState>? _states;
  TimewebProfilePhotoReader? _reader;
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
    try {
      if (widget.readGroup && widget.runtime.peopleEnabled) {
        final person = await widget.runtime.readPerson(widget.uid);
        _check(generation);
        person.requireCurrent();
        setState(() => _group = person.primaryGroup);
      }
      if (!widget.runtime.profilePhotosEnabled) return;
      final reader = await widget.runtime.openProfilePhotos(widget.uid);
      try {
        _check(generation);
      } catch (_) {
        await reader.close();
        rethrow;
      }
      _reader = reader;
      final page = await reader.photos(limit: 1);
      _check(generation);
      page.requireCurrent();
      if (page.items.isEmpty) return;
      final original = await reader.readOriginal(page.items.first);
      _check(generation);
      final decoded = await decodeProfilePhoto(
        original.bytes,
        original.contentType,
        () {
          _check(generation);
          reader.requireCurrent();
        },
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
    }
  }

  @override
  void didUpdateWidget(covariant TimewebChatAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid ||
        !identical(oldWidget.runtime, widget.runtime)) {
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
