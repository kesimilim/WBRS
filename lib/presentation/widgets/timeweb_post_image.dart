import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';

/// Protected bytes fetched on screen; disposal retires the reader and image.
class TimewebPostImage extends StatefulWidget {
  const TimewebPostImage({
    super.key,
    required this.runtime,
    required this.postId,
    required this.mediaId,
  });
  final TimewebAppRuntime runtime;
  final String postId, mediaId;
  @override
  State<TimewebPostImage> createState() => _TimewebPostImageState();
}

class _TimewebPostImageState extends State<TimewebPostImage> {
  late final AppSessionLease _lease;
  StreamSubscription<AppSessionState>? _states;
  TimewebPostMediaReader? _reader;
  Uint8List? _bytes;
  MemoryImage? _image;
  bool _busy = true;
  bool get _current => mounted && _lease.isCurrent;
  @override
  void initState() {
    super.initState();
    _lease = widget.runtime.session.captureLease();
    _states = widget.runtime.session.states.listen((_) {
      if (!_current && mounted) {
        _clear();
        unawaited(_reader?.close() ?? Future.value());
        setState(() => _busy = false);
      }
    });
    unawaited(_load());
  }

  void _clear() {
    final image = _image;
    _image = null;
    if (image != null) {
      unawaited(image.evict());
    }
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
  }

  Future<void> _load() async {
    if (!_current) {
      return;
    }
    _clear();
    setState(() => _busy = true);
    try {
      final reader =
          _reader ??
          await widget.runtime.openPostMedia(widget.postId, widget.mediaId);
      if (!_current) {
        await reader.close();
        return;
      }
      _reader = reader;
      final result = await reader.read();
      if (!_current) {
        return;
      }
      result.requireCurrent();
      final bytes = result.bytes;
      setState(() {
        _bytes = bytes;
        _image = MemoryImage(bytes);
      });
    } catch (_) {
      if (_current) {
        _clear();
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _states?.cancel();
    _clear();
    unawaited(_reader?.close() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return const SizedBox.shrink();
    }
    if (_busy) {
      return const SizedBox(
        height: 48,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_image == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(context.tr('Фотографии пока недоступны.')),
          TextButton(onPressed: _load, child: Text(context.tr('Повторить'))),
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image(
        image: _image!,
        key: ValueKey('timeweb-post-image-${widget.postId}'),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) =>
            Text(context.tr('Фотографии пока недоступны.')),
      ),
    );
  }
}
