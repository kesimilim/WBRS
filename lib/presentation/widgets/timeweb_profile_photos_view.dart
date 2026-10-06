import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/group_badge.dart';

const _maxPhotoPixels = 16 * 1024 * 1024;
const _maxPhotoSide = 8192;

/// Container/header bounds run before the native decoder sees compressed data.
/// Unknown/truncated structures are unavailable, with no fallback MIME guess.
(int, int) profilePhotoDimensions(Uint8List bytes, String mime) {
  Never invalid() => throw const TimewebProfilePhotoUnavailable();
  if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) invalid();
  void need(int offset, int length) {
    if (offset < 0 || length < 0 || offset > bytes.length - length) invalid();
  }

  int le16(int n) {
    need(n, 2);
    return bytes[n] | bytes[n + 1] << 8;
  }

  int be16(int n) {
    need(n, 2);
    return bytes[n] << 8 | bytes[n + 1];
  }

  int le24(int n) {
    need(n, 3);
    return bytes[n] | bytes[n + 1] << 8 | bytes[n + 2] << 16;
  }

  int le32(int n) {
    need(n, 4);
    return bytes[n] |
        bytes[n + 1] << 8 |
        bytes[n + 2] << 16 |
        bytes[n + 3] << 24;
  }

  int be32(int n) {
    need(n, 4);
    return bytes[n] << 24 |
        bytes[n + 1] << 16 |
        bytes[n + 2] << 8 |
        bytes[n + 3];
  }

  bool matches(int n, List<int> value) {
    need(n, value.length);
    for (var i = 0; i < value.length; i++) {
      if (bytes[n + i] != value[i]) return false;
    }
    return true;
  }

  (int, int) bounded(int w, int h) {
    if (w < 1 ||
        h < 1 ||
        w > _maxPhotoSide ||
        h > _maxPhotoSide ||
        w * h > _maxPhotoPixels) {
      invalid();
    }
    return (w, h);
  }

  switch (mime) {
    case 'image/png':
      if (!matches(0, [137, 80, 78, 71, 13, 10, 26, 10]) ||
          be32(8) != 13 ||
          !matches(12, [73, 72, 68, 82])) {
        invalid();
      }
      final dimensions = bounded(be32(16), be32(20));
      var pos = 8, chunks = 0;
      var ended = false;
      while (pos < bytes.length) {
        if (++chunks > 65536) invalid();
        need(pos, 12);
        final length = be32(pos);
        need(pos, length + 12);
        // APNG's additional frame bounds are deliberately outside this reader.
        if (matches(pos + 4, [97, 99, 84, 76]) ||
            matches(pos + 4, [102, 99, 84, 76]) ||
            matches(pos + 4, [102, 100, 65, 84])) {
          invalid();
        }
        if (matches(pos + 4, [73, 69, 78, 68])) {
          if (length != 0 || pos + 12 != bytes.length) invalid();
          ended = true;
          break;
        }
        pos += length + 12;
      }
      if (!ended) invalid();
      return dimensions;
    case 'image/jpeg':
      if (!matches(0, [255, 216])) invalid();
      var pos = 2;
      for (var markers = 0; markers < 4096 && pos <= 1024 * 1024; markers++) {
        need(pos, 2);
        if (bytes[pos++] != 255) invalid();
        while (pos < bytes.length && bytes[pos] == 255) {
          pos++;
        }
        need(pos, 1);
        final marker = bytes[pos++];
        if (marker == 0 || marker == 217 || marker == 218) invalid();
        if (marker == 1 || marker >= 208 && marker <= 215) continue;
        final length = be16(pos);
        if (length < 2) invalid();
        need(pos, length);
        if (const {
          192,
          193,
          194,
          195,
          197,
          198,
          199,
          201,
          202,
          203,
          205,
          206,
          207,
        }.contains(marker)) {
          if (length < 8 || bytes[pos + 2] != 8) invalid();
          final components = bytes[pos + 7];
          if (components < 1 ||
              components > 4 ||
              length != 8 + 3 * components) {
            invalid();
          }
          return bounded(be16(pos + 5), be16(pos + 3));
        }
        pos += length;
      }
      invalid();
    case 'image/gif':
      if (!matches(0, [71, 73, 70, 56, 55, 97]) &&
          !matches(0, [71, 73, 70, 56, 57, 97])) {
        invalid();
      }
      need(0, 13);
      final dimensions = bounded(le16(6), le16(8));
      var pos = 13;
      if (bytes[10] & 128 != 0) pos += 3 * (1 << ((bytes[10] & 7) + 1));
      need(0, pos);
      void subBlocks() {
        while (true) {
          need(pos, 1);
          final length = bytes[pos++];
          if (length == 0) return;
          need(pos, length);
          pos += length;
        }
      }
      var frames = 0, blocks = 0;
      while (pos < bytes.length) {
        if (++blocks > 65536) invalid();
        final kind = bytes[pos++];
        if (kind == 59) {
          if (frames < 1 || pos != bytes.length) invalid();
          return dimensions;
        }
        if (kind == 33) {
          need(pos, 1);
          pos++;
          subBlocks();
          continue;
        }
        if (kind != 44 || ++frames > 512) invalid();
        need(pos, 9);
        final left = le16(pos),
            top = le16(pos + 2),
            w = le16(pos + 4),
            h = le16(pos + 6);
        bounded(w, h);
        if (left + w > dimensions.$1 || top + h > dimensions.$2) invalid();
        final packed = bytes[pos + 8];
        pos += 9;
        if (packed & 128 != 0) pos += 3 * (1 << ((packed & 7) + 1));
        need(pos, 1);
        if (bytes[pos] < 2 || bytes[pos] > 8) invalid();
        pos++;
        subBlocks();
      }
      invalid();
    case 'image/webp':
      if (!matches(0, [82, 73, 70, 70]) ||
          !matches(8, [87, 69, 66, 80]) ||
          le32(4) + 8 != bytes.length) {
        invalid();
      }
      (int, int)? canvas, image;
      var pos = 12, chunks = 0;
      while (pos < bytes.length) {
        if (++chunks > 65536) invalid();
        need(pos, 8);
        final length = le32(pos + 4), start = pos + 8;
        need(start, length + (length & 1));
        if (matches(pos, [65, 78, 73, 77]) || matches(pos, [65, 78, 77, 70])) {
          invalid();
        }
        if (matches(pos, [86, 80, 56, 88])) {
          if (canvas != null ||
              pos != 12 ||
              length != 10 ||
              bytes[start] & 2 != 0) {
            invalid();
          }
          canvas = bounded(le24(start + 4) + 1, le24(start + 7) + 1);
        } else if (matches(pos, [86, 80, 56, 32])) {
          if (image != null ||
              length < 10 ||
              bytes[start] & 1 != 0 ||
              !matches(start + 3, [157, 1, 42])) {
            invalid();
          }
          image = bounded(le16(start + 6) & 16383, le16(start + 8) & 16383);
        } else if (matches(pos, [86, 80, 56, 76])) {
          if (image != null || length < 5 || bytes[start] != 47) invalid();
          final bits = le32(start + 1);
          if (bits >> 29 != 0) invalid();
          image = bounded((bits & 16383) + 1, ((bits >> 14) & 16383) + 1);
        } else if (!matches(pos, [65, 76, 80, 72]) &&
            !matches(pos, [73, 67, 67, 80]) &&
            !matches(pos, [69, 88, 73, 70]) &&
            !matches(pos, [88, 77, 80, 32])) {
          invalid();
        }
        pos = start + length + (length & 1);
      }
      if (image == null || canvas != null && canvas != image) invalid();
      return image;
    default:
      invalid();
  }
}

/// Only one resized first frame is retained. Every intermediate native handle
/// is disposed even when the owner changes while the codec future is pending.
Future<ui.Image> decodeProfilePhoto(
  Uint8List bytes,
  String mime,
  void Function() requireCurrent,
) async {
  requireCurrent();
  final expected = profilePhotoDimensions(bytes, mime);
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    requireCurrent();
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    requireCurrent();
    final w = descriptor.width, h = descriptor.height;
    if ((w != expected.$1 || h != expected.$2) &&
            (w != expected.$2 || h != expected.$1) ||
        w < 1 ||
        h < 1 ||
        w > _maxPhotoSide ||
        h > _maxPhotoSide ||
        w * h > _maxPhotoPixels) {
      throw const TimewebProfilePhotoUnavailable();
    }
    final maxSide = w > h ? w : h;
    final targetW = maxSide <= 1024
        ? w
        : (w * 1024 / maxSide).round().clamp(1, 1024);
    final targetH = maxSide <= 1024
        ? h
        : (h * 1024 / maxSide).round().clamp(1, 1024);
    codec = await descriptor.instantiateCodec(
      targetWidth: targetW,
      targetHeight: targetH,
    );
    requireCurrent();
    final frame = await codec.getNextFrame();
    image = frame.image;
    requireCurrent();
    final retained = image;
    image = null;
    return retained;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The visible profile owns at most a primary and one selected gallery frame.
/// No ImageProvider, global ImageCache, disk, preferences, URL or auto-download.
class TimewebProfilePhotosView extends StatefulWidget {
  const TimewebProfilePhotosView({
    super.key,
    required this.runtime,
    required this.targetUid,
    this.primaryGroup,
    this.portraitHeight = 96,
  });
  final TimewebAppRuntime runtime;
  final String targetUid;
  final String? primaryGroup;
  final double portraitHeight;
  @override
  State<TimewebProfilePhotosView> createState() =>
      _TimewebProfilePhotosViewState();
}

class _TimewebProfilePhotosViewState extends State<TimewebProfilePhotosView> {
  StreamSubscription<AppSessionState>? _states;
  TimewebProfilePhotoReader? _reader;
  TimewebProfilePhotosCursor? _cursor;
  final _references = <TimewebProfilePhotoReference>[];
  ui.Image? _primary, _gallery;
  int? _selected;
  int _generation = 0, _selection = 0;
  int _epoch = -1;
  bool _routeActive = false,
      _loading = false,
      _galleryLoading = false,
      _unavailable = false;
  bool get _current =>
      mounted &&
      _routeActive &&
      widget.runtime.session.state.authenticated &&
      widget.runtime.session.state.epoch == _epoch;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  void _watch() {
    final epoch = widget.runtime.session.state.epoch;
    _epoch = epoch;
    _states = widget.runtime.session.states.listen((state) {
      if (!state.authenticated || state.epoch != epoch) {
        _clear();
        if (mounted) {
          setState(() {
            _unavailable = true;
          });
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeActive == active) return;
    _routeActive = active;
    if (!active) {
      _clear();
    } else {
      unawaited(_reload());
    }
  }

  @override
  void didUpdateWidget(covariant TimewebProfilePhotosView old) {
    super.didUpdateWidget(old);
    if (old.runtime != widget.runtime || old.targetUid != widget.targetUid) {
      _clear();
      unawaited(_states?.cancel());
      _watch();
      if (_routeActive) unawaited(_reload());
    }
  }

  void _clear() {
    _generation++;
    _selection++;
    final reader = _reader;
    _reader = null;
    if (reader != null) unawaited(reader.close());
    _references.clear();
    _cursor = null;
    _selected = null;
    _primary?.dispose();
    _primary = null;
    _gallery?.dispose();
    _gallery = null;
    _loading = false;
    _galleryLoading = false;
  }

  void _check(int generation, TimewebProfilePhotoReader reader) {
    if (!_current || generation != _generation || !identical(reader, _reader)) {
      throw const TimewebProfilePhotoUnavailable();
    }
    reader.requireCurrent();
  }

  Future<void> _reload() async {
    _clear();
    if (!_current || !widget.runtime.profilePhotosEnabled) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _unavailable = false;
    });
    TimewebProfilePhotoReader? reader;
    try {
      reader = await widget.runtime.openProfilePhotos(widget.targetUid);
      if (!_current || generation != _generation) {
        await reader.close();
        return;
      }
      _reader = reader;
      final page = await reader.photos();
      _check(generation, reader);
      _references.addAll(page.items);
      _cursor = page.nextCursor;
      if (_references.isNotEmpty) {
        final original = await reader.readOriginal(_references.first);
        _check(generation, reader);
        final decoded = await decodeProfilePhoto(
          original.bytes,
          original.contentType,
          () => _check(generation, reader!),
        );
        try {
          _check(generation, reader);
          _primary = decoded;
        } catch (_) {
          decoded.dispose();
          rethrow;
        }
      }
    } catch (_) {
      if (_current && generation == _generation) {
        _clear();
        _unavailable = true;
      }
      if (reader != null && !identical(reader, _reader)) {
        unawaited(reader.close());
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
        });
      } else if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _more() async {
    final reader = _reader, cursor = _cursor;
    if (reader == null || cursor == null || _loading || !_current) return;
    final generation = _generation;
    setState(() {
      _loading = true;
    });
    try {
      final page = await reader.photos(cursor: cursor);
      _check(generation, reader);
      if (_references.length + page.items.length > 50) {
        throw const TimewebProfilePhotoUnavailable();
      }
      _references.addAll(page.items);
      _cursor = page.nextCursor;
    } catch (_) {
      if (_current && generation == _generation) {
        _clear();
        _unavailable = true;
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
        });
      } else if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _select(TimewebProfilePhotoReference reference) async {
    final reader = _reader;
    if (!_current || reader == null || _galleryLoading) return;
    final generation = _generation, selection = ++_selection;
    _gallery?.dispose();
    _gallery = null;
    setState(() {
      _selected = reference.ordinal;
      _galleryLoading = true;
    });
    try {
      final original = await reader.readOriginal(reference);
      void check() {
        _check(generation, reader);
        if (selection != _selection) {
          throw const TimewebProfilePhotoUnavailable();
        }
      }

      check();
      final decoded = await decodeProfilePhoto(
        original.bytes,
        original.contentType,
        check,
      );
      try {
        check();
        _gallery = decoded;
      } catch (_) {
        decoded.dispose();
        rethrow;
      }
    } catch (_) {
      if (_current && generation == _generation && selection == _selection) {
        _clear();
        _unavailable = true;
      }
    } finally {
      if (mounted && generation == _generation && selection == _selection) {
        setState(() {
          _galleryLoading = false;
        });
      } else if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _clear();
    unawaited(_states?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: widget.portraitHeight,
        child: Center(
          child: SizedBox(
            width: 96,
            height: 96,
            child: CustomPaint(
              painter: GroupRingPainter(
                groupColors(_current ? widget.primaryGroup ?? '' : ''),
              ),
              child: Padding(
                padding: EdgeInsets.all(
                  _current && widget.primaryGroup != null ? 3 : 0,
                ),
                child: ClipOval(
                  child: _primary == null || !_current
                      ? const Icon(
                          Icons.person_outline,
                          size: 90,
                          color: LrsTheme.peachLight,
                        )
                      : RawImage(
                          key: const ValueKey('timeweb-photo-primary'),
                          image: _primary,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        context.tr('Фото профиля'),
        style: const TextStyle(color: LrsTheme.muted),
      ),
      if (_loading)
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      if (!_loading && (_unavailable || _references.isEmpty))
        Text(
          context.tr('Фото недоступно'),
          style: const TextStyle(color: LrsTheme.muted),
        ),
      if (!_loading && widget.runtime.profilePhotosEnabled && _current)
        TextButton(
          key: const ValueKey('timeweb-photo-reload'),
          onPressed: _reload,
          child: Text(context.tr('Обновить')),
        ),
      if (_references.length > 1 && _current) ...[
        Text(context.tr('Фотографии')),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final reference in _references.skip(1))
                TextButton(
                  key: ValueKey('timeweb-photo-select-${reference.ordinal}'),
                  onPressed: _galleryLoading ? null : () => _select(reference),
                  child: Text(
                    '${reference.ordinal + 1}',
                    style: TextStyle(
                      fontWeight: _selected == reference.ordinal
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
      if (_galleryLoading) const CircularProgressIndicator(strokeWidth: 2),
      if (_gallery != null && _current)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: AspectRatio(
            aspectRatio: _gallery!.width / _gallery!.height,
            child: RawImage(
              key: const ValueKey('timeweb-photo-gallery'),
              image: _gallery,
              fit: BoxFit.contain,
              alignment: Alignment.center,
            ),
          ),
        ),
      if (_cursor != null && _current)
        TextButton(
          key: const ValueKey('timeweb-photo-more'),
          onPressed: _loading ? null : _more,
          child: Text(context.tr('Загрузить ещё')),
        ),
    ],
  );
}
