import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_photo_upload_flow.dart';

/// Own-profile action; a current server refusal leaves the gallery read-only.
class TimewebPhotoAppendControl extends StatefulWidget {
  const TimewebPhotoAppendControl({
    super.key,
    required this.runtime,
    required this.snapshot,
    required this.onReady,
  });
  final TimewebAppRuntime runtime;
  final TimewebCurrentOwnProfile snapshot;
  final Future<void> Function() onReady;
  @override
  State<TimewebPhotoAppendControl> createState() =>
      _TimewebPhotoAppendControlState();
}

class _TimewebPhotoAppendControlState extends State<TimewebPhotoAppendControl> {
  TimewebPhotoUploadFlow? _flow;
  StreamSubscription<AppSessionState>? _states;
  late final int _epoch;
  bool _busy = true, _allowed = false, _retry = false, _invalidated = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _states = widget.runtime.session.states.listen((_) {
      if (!_current) {
        _invalidated = true;
        _allowed = false;
        _notice = null;
        unawaited(_flow?.close() ?? Future<void>.value());
        _flow = null;
        if (mounted) setState(() => _busy = false);
      }
    });
    unawaited(_open());
  }

  bool get _current {
    if (!mounted ||
        _invalidated ||
        !widget.runtime.session.state.authenticated ||
        widget.runtime.session.state.epoch != _epoch) {
      return false;
    }
    try {
      widget.snapshot.requireCurrent();
      _flow?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _availability() async {
    final availability = await widget.runtime.readPhotoUploadAvailability();
    if (!_current) return;
    availability.requireCurrent();
    _allowed = availability.canAppend;
    _retry = false;
  }

  Future<void> _open() async {
    try {
      final previous = _flow;
      _flow = null;
      await previous?.close();
      if (!_current) return;
      final flow = await widget.runtime.openPhotoUpload();
      if (!_current) {
        await flow.close();
        return;
      }
      _flow = flow;
      // A persisted original is checkable even if availability is now refused.
      if (flow.metadata == null) await _availability();
    } on TimewebProfilePhotoUnavailable {
      if (_current) {
        _allowed = false;
        _retry = false;
      }
    } catch (_) {
      if (_current) {
        _retry = true;
        _notice = 'Сервис пока недоступен. Попробуйте позднее.';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<TimewebProfilePhotoSource?> _choose() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (!_current || file == null) return null;
    if (await file.length() > 5242880) {
      throw const FormatException('Photo is too large.');
    }
    final buffer = Uint8List(5242881);
    var length = 0;
    try {
      await for (final bytes in file.openRead()) {
        if (!_current || length + bytes.length > 5242880) {
          throw const FormatException('Photo changed.');
        }
        buffer.setRange(length, length + bytes.length, bytes);
        length += bytes.length;
      }
      if (!_current) return null;
      final mime =
          length >= 8 &&
              buffer[0] == 137 &&
              buffer[1] == 80 &&
              buffer[2] == 78 &&
              buffer[3] == 71
          ? 'image/png'
          : length >= 3 &&
                buffer[0] == 255 &&
                buffer[1] == 216 &&
                buffer[2] == 255
          ? 'image/jpeg'
          : length >= 12 &&
                String.fromCharCodes(buffer.sublist(0, 4)) == 'RIFF' &&
                String.fromCharCodes(buffer.sublist(8, 12)) == 'WEBP'
          ? 'image/webp'
          : null;
      if (mime == null) {
        throw const FormatException('Photo format is unsupported.');
      }
      return TimewebProfilePhotoSource.fromBytes(
        Uint8List.sublistView(buffer, 0, length),
        mimeType: mime,
      );
    } finally {
      buffer.fillRange(0, buffer.length, 0);
    }
  }

  Future<void> _run({bool check = false}) async {
    final flow = _flow;
    if (!_current || _busy || flow == null) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    TimewebProfilePhotoSource? source;
    try {
      TimewebPhotoUploadOutcome outcome;
      if (check || flow.needsCheck) {
        outcome = await flow.check().timeout(flow.observationTimeout);
      } else {
        if (flow.metadata == null) {
          await _availability(); // Fresh server eligibility before each new pick.
          if (!_current || !_allowed) return;
        }
        if (!flow.sourceAttached) {
          source = await _choose();
          if (!_current || source == null) return;
          if (flow.metadata == null) {
            final preparing = flow.prepare(source);
            source = null; // The existing flow now owns and purges its bytes.
            outcome = await preparing.timeout(flow.observationTimeout);
            if (!_current) return;
            if (outcome != TimewebPhotoUploadOutcome.prepared) {
              await _finish(outcome);
              return;
            }
          } else {
            flow.reattach(source); // Exact original metadata; no new operation.
            source = null;
          }
        }
        if (!_current) return;
        outcome = await flow.uploadAndCommit().timeout(flow.observationTimeout);
      }
      if (_current) await _finish(outcome);
    } on TimewebProfilePhotoUnavailable {
      if (_current) {
        _allowed = false;
        _notice = 'Сервис пока недоступен. Попробуйте позднее.';
      }
    } catch (_) {
      if (_current) {
        _notice = flow.needsCheck
            ? 'Результат пока не подтверждён. Нажмите «Проверить результат».'
            : 'Не удалось сохранить выбранную фотографию. Повторите попытку.';
        if (!flow.needsCheck && flow.metadata == null) {
          // A failed journal save can leave bytes attached without an intent.
          // Reopen first: any persisted original is restored before another pick.
          await _open();
        }
      }
    } finally {
      source?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish(TimewebPhotoUploadOutcome outcome) async {
    if (outcome == TimewebPhotoUploadOutcome.ready) {
      _flow!.readyReceipt!.requireCurrent(); // Journal ACK already completed.
      await widget.onReady(); // Fresh own fields/gallery only after READY.
      if (_current) await _open();
    } else if (outcome == TimewebPhotoUploadOutcome.rejected) {
      final rejected = _flow!;
      _flow = null;
      await rejected.close();
      if (!_current) return;
      _notice = 'Не удалось сохранить выбранную фотографию. Повторите попытку.';
      _retry = true;
    } else if (outcome == TimewebPhotoUploadOutcome.unknown) {
      _notice = 'Результат пока не подтверждён. Нажмите «Проверить результат».';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final flow = _flow,
        pending = flow?.needsCheck == true,
        original = flow?.metadata != null;
    if (!_busy && !_allowed && !original && !_retry && _notice == null) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(context.tr(_notice!)),
          ),
        if (_busy)
          const LinearProgressIndicator(
            key: ValueKey('timeweb-photo-append-busy'),
          ),
        if (_retry)
          TextButton(
            key: const ValueKey('timeweb-photo-append-retry'),
            onPressed: _busy
                ? null
                : () {
                    setState(() => _busy = true);
                    unawaited(_open());
                  },
            child: Text(context.tr('Обновить')),
          ),
        if (flow != null && (original || _allowed))
          ElevatedButton.icon(
            key: ValueKey(
              pending
                  ? 'timeweb-photo-append-check'
                  : 'timeweb-photo-append-add',
            ),
            onPressed: _busy ? null : () => _run(check: pending),
            icon: Icon(
              pending ? Icons.refresh : Icons.add_photo_alternate_outlined,
            ),
            label: Text(
              context.tr(
                pending
                    ? 'Проверить результат'
                    : original
                    ? 'Продолжить'
                    : 'Добавить фото',
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _invalidated = true;
    unawaited(_flow?.close() ?? Future<void>.value());
    unawaited(_states?.cancel());
    super.dispose();
  }
}
