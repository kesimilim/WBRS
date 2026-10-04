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

  void _clear() {
    _generation++;
    final reader = _reader;
    _reader = null;
    if (reader != null) unawaited(reader.close());
    _portrait?.dispose();
    _portrait = null;
    for (final image in _thumbnails.values) {
      image.dispose();
    }
    _thumbnails.clear();
    _references.clear();
    _cursor = null;
    _loading = false;
    _selecting = false;
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
    TimewebProfilePhotoReader reader,
  ) async {
    _check(generation, reader);
    if (_references.length + page.items.length > 20) {
      throw const TimewebProfilePhotoUnavailable();
    }
    _references.addAll(page.items);
    _cursor = page.nextCursor;
    if (!widget.showGallery && _references.isNotEmpty) {
      final decoded = await _image(_references.first, generation, reader);
      try {
        _check(generation, reader);
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
        if (_portrait == null) {
          _selected = ref.ordinal;
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

  Future<void> _load({bool more = false}) async {
    if (_loading || !_current) return;
    if (!more) _clear();
    final generation = _generation;
    setState(() {
      _loading = true;
      _unavailable = false;
    });
    try {
      final reader = more
          ? _reader
          : await widget.runtime.openProfilePhotos(widget.targetUid);
      if (reader == null) return;
      if (!_current || generation != _generation) {
        await reader.close();
        return;
      }
      _reader = reader;
      final page = await reader.photos(cursor: more ? _cursor : null);
      await _append(page, generation, reader);
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() {
          _clear();
          _unavailable = true;
        });
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
    } catch (_) {
      if (_current && generation == _generation) {
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
                                      ? const Center(
                                          child: CircularProgressIndicator(),
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
