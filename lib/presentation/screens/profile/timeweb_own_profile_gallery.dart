import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/widgets/timeweb_profile_photos_view.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/profile_composition.dart';

/// CLRS portrait and thumbnail strip over the existing private photo reader.
/// Only small decoded thumbnails and one portrait live in this route's RAM.
class TimewebOwnProfileGallery extends StatefulWidget {
  const TimewebOwnProfileGallery({
    super.key,
    required this.runtime,
    required this.targetUid,
    required this.portraitBuilder,
    required this.abovePhotos,
    required this.belowPhotos,
    this.appendControl,
    this.showGallery = true,
    this.photoFit = BoxFit.contain,
  });
  final TimewebAppRuntime runtime;
  final String targetUid;
  final Widget Function(Widget photo) portraitBuilder;
  final Widget abovePhotos;
  final List<Widget> belowPhotos;
  final Widget? appendControl;
  final bool showGallery;
  final BoxFit photoFit;
  @override
  State<TimewebOwnProfileGallery> createState() => _GalleryState();
}

class _GalleryState extends State<TimewebOwnProfileGallery> {
  late final TimewebAppRuntime _runtime;
  late final String _targetUid;
  StreamSubscription<AppSessionState>? _states;
  TimewebProfilePhotoReader? _reader;
  TimewebProfilePhotosCursor? _cursor;
  final _references = <TimewebProfilePhotoReference>[];
  final _thumbnails = <int, ui.Image>{};
  ui.Image? _portrait;
  late final int _epoch;
  int _generation = 0, _selected = 0;
  bool _active = false,
      _loading = false,
      _selecting = false,
      _unavailable = false;

  bool get _current =>
      mounted &&
      _active &&
      identical(widget.runtime, _runtime) &&
      widget.targetUid == _targetUid &&
      widget.runtime.session.state.authenticated &&
      widget.runtime.session.state.epoch == _epoch;

  bool get _ownCurrent => _current && _runtime.session.currentUid == _targetUid;

  bool _transient(Object error) =>
      error is TimewebAuthException &&
      const {
        TimewebAuthError.network,
        TimewebAuthError.unavailable,
        TimewebAuthError.deadline,
      }.contains(error.error);

  void _logRead(String stage, Object error) {
    final reason = error is TimewebAuthException
        ? error.error.name
        : error is TimewebProfilePhotoUnavailable
        ? 'photo_unavailable'
        : error is AppSessionException
        ? error.error.name
        : 'unexpected';
    debugPrint('CLRS native gallery stage=$stage error=$reason');
  }

  @override
  void initState() {
    super.initState();
    _runtime = widget.runtime;
    _targetUid = widget.targetUid;
    _epoch = widget.runtime.session.state.epoch;
    _states = widget.runtime.session.states.listen((_) {
      if (!_current) {
        _clear();
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant TimewebOwnProfileGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.targetUid != widget.targetUid) {
      // A different target/runtime needs a new keyed instance, never old RAM.
      _active = false;
      _clear();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = ModalRoute.of(context)?.isCurrent ?? true;
    if (_active == active) return;
    _active = active;
    if (active) {
      unawaited(_load());
    } else {
      _clear();
    }
  }

  Future<void>? _clear({bool keepPortrait = false}) {
    _generation++;
    final reader = _reader;
    _reader = null;
    final draining = reader?.close();
    if (!keepPortrait || !_ownCurrent) {
      _portrait?.dispose();
      _portrait = null;
    }
    for (final image in _thumbnails.values) {
      image.dispose();
    }
    _thumbnails.clear();
    _references.clear();
    _cursor = null;
    _loading = false;
    _selecting = false;
    return draining;
  }

  void _check(int generation, TimewebProfilePhotoReader reader) {
    if (!_current || generation != _generation || !identical(reader, _reader)) {
      throw const TimewebProfilePhotoUnavailable();
    }
    reader.requireCurrent();
  }

  Future<ui.Image> _image(
    TimewebProfilePhotoReference ref,
    int generation,
    TimewebProfilePhotoReader reader,
  ) async {
    final original = await reader.readOriginal(ref);
    _check(generation, reader);
    return decodeProfilePhoto(
      original.bytes,
      original.contentType,
      () => _check(generation, reader),
    );
  }

  Future<void> _append(
    TimewebProfilePhotosPage page,
    int generation,
    TimewebProfilePhotoReader reader, {
    int? selectedOrdinal,
  }) async {
    _check(generation, reader);
    if (_references.length + page.items.length > 20) {
      throw const TimewebProfilePhotoUnavailable();
    }
    _references.addAll(page.items);
    _cursor = page.nextCursor;
    if (selectedOrdinal != null &&
        !page.items.any((ref) => ref.ordinal == _selected)) {
      // Fresh metadata no longer associates the displayed photo with owner.
      _portrait?.dispose();
      _portrait = null;
    }
    final portraitOrdinal = selectedOrdinal != null && page.items.isNotEmpty
        ? page.items.any((ref) => ref.ordinal == selectedOrdinal)
              ? selectedOrdinal
              : page.items.first.ordinal
        : null;
    if (!widget.showGallery && _references.isNotEmpty) {
      final decoded = await _image(_references.first, generation, reader);
      try {
        _check(generation, reader);
        _portrait?.dispose();
        _portrait = decoded;
      } catch (_) {
        decoded.dispose();
        rethrow;
      }
      return;
    }
    for (final ref in page.items) {
      ui.Image? decoded, thumbnail;
      ui.Picture? picture;
      try {
        decoded = await _image(ref, generation, reader);
        _check(generation, reader);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final size = Size(decoded.width.toDouble(), decoded.height.toDouble());
        final fitted = applyBoxFit(BoxFit.cover, size, const Size(72, 80));
        canvas.drawImageRect(
          decoded,
          Alignment.center.inscribe(fitted.source, Offset.zero & size),
          const Rect.fromLTWH(0, 0, 72, 80),
          Paint(),
        );
        picture = recorder.endRecording();
        thumbnail = await picture.toImage(72, 80);
        _check(generation, reader);
        _thumbnails[ref.ordinal] = thumbnail;
        thumbnail = null;
        if (_portrait == null || ref.ordinal == portraitOrdinal) {
          _selected = ref.ordinal;
          _portrait?.dispose();
          _portrait = decoded;
          decoded = null;
        }
        setState(() {});
      } finally {
        picture?.dispose();
        thumbnail?.dispose();
        decoded?.dispose();
      }
    }
  }

  Future<void> _load({
    bool more = false,
    int? selectedOrdinal,
    bool retryTransient = true,
  }) async {
    if (_loading || !_current) return;
    final wantedOrdinal = selectedOrdinal ?? _selected;
    final draining = more ? null : _clear(keepPortrait: _ownCurrent);
    var generation = _generation;
    setState(() {
      _loading = true;
      _unavailable = false;
    });
    try {
      await draining;
      // A transient read can lose the first or a later image. Recover once
      // from fresh metadata; never extend a reference or replay a write.
      for (var attempt = 0; attempt < 2; attempt++) {
        if (!_current || generation != _generation) return;
        var stage = 'metadata';
        try {
          final appendPage = more && attempt == 0;
          final reader = appendPage
              ? _reader
              : await widget.runtime.openProfilePhotos(widget.targetUid);
          if (reader == null) return;
          if (!_current || generation != _generation) {
            await reader.close();
            return;
          }
          _reader = reader;
          if (attempt == 1) {
            await reader.waitForReadCapacity();
            _check(generation, reader);
          }
          final page = await reader.photos(
            cursor: appendPage ? _cursor : null,
            waitForCapacity: attempt == 1,
          );
          stage = 'original';
          await _append(
            page,
            generation,
            reader,
            selectedOrdinal: appendPage ? null : wantedOrdinal,
          );
          return;
        } catch (error) {
          _logRead(stage, error);
          if (!_current || generation != _generation) return;
          final recoverable = _ownCurrent && _transient(error);
          final drained = _clear(keepPortrait: recoverable);
          generation = _generation;
          if (attempt == 0 && retryTransient && recoverable) {
            setState(() => _loading = true);
            await drained;
            if (!_ownCurrent || generation != _generation) return;
            continue;
          }
          setState(() => _unavailable = true);
          return;
        }
      }
    } finally {
      if (mounted && _current && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _select(TimewebProfilePhotoReference ref) async {
    final reader = _reader;
    if (!_current || reader == null || _selecting || _loading) return;
    final generation = _generation;
    setState(() => _selecting = true);
    ui.Image? image;
    try {
      image = await _image(ref, generation, reader);
      _check(generation, reader);
      _portrait?.dispose();
      _portrait = image;
      image = null;
      _selected = ref.ordinal;
    } catch (error) {
      _logRead('selection', error);
      if (_current && generation == _generation) {
        if (error is TimewebAuthException &&
                error.error == TimewebAuthError.invalidRequest ||
            _ownCurrent && _transient(error)) {
          // Selecting an expired reference requires a new metadata page and
          // its matching ordinal. Only one recovery read is attempted here.
          await _load(selectedOrdinal: ref.ordinal, retryTransient: false);
          return;
        }
        setState(() {
          _clear();
          _unavailable = true;
        });
      }
    } finally {
      image?.dispose();
      if (mounted && _current && generation == _generation) {
        setState(() => _selecting = false);
      }
    }
  }

  @override
  void dispose() {
    _active = false;
    _clear();
    unawaited(_states?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_current
      ? const SizedBox.shrink()
      : Column(
          children: [
            widget.portraitBuilder(
              _current && _portrait != null
                  ? RawImage(
                      key: const ValueKey('timeweb-photo-primary'),
                      image: _portrait,
                      fit: widget.photoFit,
                      alignment: Alignment.topCenter,
                    )
                  : const ColoredBox(
                      color: Color(0x4431241D),
                      child: Icon(
                        Icons.person_outline,
                        size: 90,
                        color: LrsTheme.peachLight,
                      ),
                    ),
            ),
            if (widget.showGallery)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    widget.abovePhotos,
                    ProfileSection(
                      key: const ValueKey('profile-photos-section'),
                      title: context.tr('Фотографии'),
                      child: Column(
                        children: [
                          if (_loading || _selecting)
                            const LinearProgressIndicator(),
                          if (!_loading &&
                              (_unavailable || _references.isEmpty))
                            Text(context.tr('Фото недоступно')),
                          if (_current && _references.isNotEmpty)
                            ProfilePhotoStrip(
                              urls: List<String>.filled(_references.length, ''),
                              onTap: (index) {
                                if (!_current || _loading || _selecting) return;
                                unawaited(_select(_references[index]));
                              },
                              photoBuilder: (context, index) {
                                final ref = _references[index],
                                    image = _thumbnails[ref.ordinal];
                                return Container(
                                  key: ValueKey(
                                    'timeweb-photo-select-${ref.ordinal}',
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: _selected == ref.ordinal
                                          ? LrsTheme.peach
                                          : Colors.transparent,
                                    ),
                                  ),
                                  child: image == null
                                      ? Center(
                                          child: _loading
                                              ? const CircularProgressIndicator()
                                              : const Icon(
                                                  Icons.photo_outlined,
                                                ),
                                        )
                                      : RawImage(
                                          image: image,
                                          fit: BoxFit.cover,
                                        ),
                                );
                              },
                            ),
                          if (_current && !_loading && _unavailable)
                            TextButton(
                              key: const ValueKey('timeweb-photo-reload'),
                              onPressed: _load,
                              child: Text(context.tr('Обновить')),
                            ),
                          if (_current && _cursor != null)
                            TextButton(
                              key: const ValueKey('timeweb-photo-more'),
                              onPressed: _loading
                                  ? null
                                  : () => _load(more: true),
                              child: Text(context.tr('Загрузить ещё')),
                            ),
                          if (widget.appendControl != null)
                            widget.appendControl!,
                        ],
                      ),
                    ),
                    ...widget.belowPhotos,
                  ],
                ),
              ),
          ],
        );
}
