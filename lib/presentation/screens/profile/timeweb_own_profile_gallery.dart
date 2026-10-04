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
/// Small thumbnails, one portrait and two recent originals live in route RAM.
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
  static const _initialPageSize = 3;
  late final TimewebAppRuntime _runtime;
  late final String _targetUid;
  StreamSubscription<AppSessionState>? _states;
  TimewebProfilePhotoReader? _reader;
  TimewebProfilePhotosCursor? _cursor;
  final _references = <TimewebProfilePhotoReference>[];
  final _thumbnails = <int, ui.Image>{};
  final _recentOriginals = <TimewebProfilePhotoReference, ui.Image>{};
  ui.Image? _portrait;
  TimewebProfilePhotoReference? _portraitReference;
  late final int _epoch;
  int _generation = 0, _selected = 0;
  int _pageLimit = _initialPageSize;
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
    for (final image in _recentOriginals.values) {
      image.dispose();
    }
    _recentOriginals.clear();
    _portraitReference = null;
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
    _pageLimit = _initialPageSize;
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

  bool _hasDecoded(TimewebProfilePhotoReference ref) =>
      _recentOriginals.containsKey(ref) ||
      identical(ref, _portraitReference) && _portrait != null;

  Future<ui.Image> _image(
    TimewebProfilePhotoReference ref,
    int generation,
    TimewebProfilePhotoReader reader,
  ) async {
    _check(generation, reader);
    ref.requireCurrent();
    if (identical(ref, _portraitReference) && _portrait != null) {
      return _portrait!.clone();
    }
    final recent = _recentOriginals.remove(ref);
    if (recent != null) {
      _recentOriginals[ref] = recent;
      return recent.clone();
    }
    final original = await reader.readOriginal(ref);
    _check(generation, reader);
    final decoded = await decodeProfilePhoto(
      original.bytes,
      original.contentType,
      () => _check(generation, reader),
    );
    try {
      _check(generation, reader);
      ref.requireCurrent();
      // References retain their own reader/actor/epoch and expiry guards.
      // Independent handles share decoded pixels, bounded to two 1024-side
      // originals (at most 8 MiB), and never survive fresh metadata or hiding.
      _recentOriginals[ref] = decoded.clone();
      while (_recentOriginals.length > 2) {
        _recentOriginals.remove(_recentOriginals.keys.first)!.dispose();
      }
      return decoded;
    } catch (_) {
      decoded.dispose();
      rethrow;
    }
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
      _portraitReference = null;
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
        _portraitReference = _references.first;
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
          _portraitReference = ref;
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
    final freshMinimum = more
        ? (_references.length + _pageLimit).clamp(_initialPageSize, 20)
        : _initialPageSize;
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
          if (!appendPage) {
            // Cold entry downloads only visible photos. A fresh recovery also
            // includes the selected ordinal, without resetting it to the first.
            _pageLimit = widget.showGallery
                ? (wantedOrdinal + 1).clamp(freshMinimum, 20)
                : 1;
          }
          final page = await reader.photos(
            limit: _pageLimit,
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
          final expiredPage =
              more &&
              stage == 'metadata' &&
              error is TimewebAuthException &&
              error.error == TimewebAuthError.invalidRequest;
          final recoverable = _ownCurrent && (_transient(error) || expiredPage);
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
    if (!_current || reader == null || _selecting) return;
    if (_loading) {
      if (!_hasDecoded(ref)) return;
      try {
        ref.requireCurrent();
      } catch (_) {
        return;
      }
    }
    final generation = _generation;
    setState(() => _selecting = true);
    ui.Image? image;
    try {
      image = await _image(ref, generation, reader);
      _check(generation, reader);
      _portrait?.dispose();
      _portrait = image;
      _portraitReference = ref;
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
                                if (!_current || _selecting) return;
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
