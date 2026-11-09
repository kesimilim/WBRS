part of 'post_editor_page.dart';

/// The shared editor design with native, owner-bound Timeweb operations.
class _TimewebPostEditorState extends State<PostEditorPage> {
  final _text = TextEditingController();
  final _files = <XFile>[];
  final _media = <String>[];
  late final AppSessionLease _lease;
  StreamSubscription<AppSessionState>? _states;
  TimewebSocialFlow? _flow;
  TimewebPreparedPhotoReceipt? _prepared;
  TimewebProfilePhotoSource? _source;
  bool _busy = false, _restoring = true, _reloadRequired = false;
  String? _notice;
  DateTime? _scheduledAt;

  Future<void> _pickScheduleTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return;
    setState(() {
      _scheduledAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }
  TimewebAppRuntime get _runtime => widget.runtime!;
  bool get _current => mounted && _lease.isCurrent;
  bool get _pending => _flow?.needsCheck ?? false;
  bool get _locked =>
      !_current || _busy || _restoring || _pending || _reloadRequired;

  @override
  void initState() {
    super.initState();
    _lease = _runtime.session.captureLease();
    _text.text = widget.post?.text ?? '';
    _media.addAll(widget.post?.mediaIds ?? const []);
    _states = _runtime.session.states.listen((_) {
      if (!_current && mounted) {
        _source?.close();
        _files.clear();
        _media.clear();
        _text.clear();
        _flow?.close();
        setState(() {});
      }
    });
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final flow = await _runtime.openSocial();
      if (!_current) {
        flow.close();
        return;
      }
      _flow = flow;
      final pending = flow.pendingAction;
      if (pending != null) {
        final value = pending.payload;
        if (value['kind'] == 'publish' || value['kind'] == 'update-post') {
          _text.text = value['text'];
          _media
            ..clear()
            ..addAll(List<String>.from(value['mediaIds'] ?? const []));
        }
        _notice =
            'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
      }
    } catch (_) {
      if (_current) {
        _notice = 'Не удалось восстановить отправку. Попробуйте ещё раз.';
      }
    } finally {
      if (_current) setState(() => _restoring = false);
    }
  }

  Future<void> _pick() async {
    if (_locked || _media.length + _files.length >= 10) return;
    final room = 10 - _media.length - _files.length;
    try {
      final files = await ImagePicker().pickMultiImage(
        imageQuality: 72,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (_current && !_locked) setState(() => _files.addAll(files.take(room)));
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = 'Не удалось открыть изображение. Попробуйте ещё раз.',
        );
      }
    }
  }

  Future<bool> _accept(TimewebSocialOutcome outcome) async {
    if (!_current) return false;
    if (outcome == TimewebSocialOutcome.unknown) {
      setState(
        () => _notice =
            'Подтверждение ещё не получено. Проверьте результат без повторной отправки.',
      );
      return false;
    }
    if (outcome == TimewebSocialOutcome.rejected &&
        _flow!.failure == TimewebMutationFailure.photoVerificationFailed) {
      _source?.close();
      _source = null;
      setState(
        () => _notice =
            'Фотография пока не подтверждена сервером. Повторите загрузку.',
      );
      return false;
    }
    if (outcome == TimewebSocialOutcome.rejected) {
      setState(() {
        _reloadRequired = true;
        _notice = _flow!.failure == TimewebMutationFailure.conflict
            ? 'Публикация уже изменена. Откройте её заново, чтобы сохранить актуальную версию.'
            : 'Нет доступа к этому действию. Вернитесь в ленту и обновите её.';
      });
      return false;
    }
    final receipt = _flow!.receipt!;
    receipt.requireCurrent();
    if (receipt.kind == 'prepare-media') {
      _prepared = receipt.preparedMedia;
      if (_source == null) {
        _prepared = null;
        setState(
          () => _notice =
              'Выберите фотографию ещё раз, чтобы продолжить загрузку.',
        );
        return false;
      }
    } else if (receipt.kind == 'commit-media') {
      if (!_media.contains(receipt.mediaId)) _media.add(receipt.mediaId!);
      _source?.close();
      _source = null;
      _prepared = null;
      if (_files.isNotEmpty) _files.removeAt(0);
    } else {
      Navigator.of(context).pop(true);
      return false;
    }
    return true;
  }

  Future<void> _send({bool deleting = false}) async {
    if (!_current || _busy || _restoring || _reloadRequired || _flow == null) {
      return;
    }
    if (!_pending &&
        !deleting &&
        _text.text.trim().isEmpty &&
        _media.isEmpty &&
        _files.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      if (_pending && !await _accept(await _flow!.check())) return;
      while (_files.isNotEmpty && !deleting) {
        if (!_current) return;
        setState(
          () => _notice =
              'Загрузка фотографии ${_media.length + 1} из ${_media.length + _files.length}',
        );
        if (_source == null) {
          final file = _files.first;
          if (await file.length() > 5242880) {
            throw const FormatException('Photo too large.');
          }
          final bytes = await file.readAsBytes();
          try {
            if (!_current) return;
            final mime = bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216
                ? 'image/jpeg'
                : bytes.length >= 8 && bytes[0] == 137 && bytes[1] == 80
                ? 'image/png'
                : bytes.length >= 12 &&
                      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
                      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP'
                ? 'image/webp'
                : null;
            if (mime == null) throw const FormatException('Unsupported photo.');
            _source = TimewebProfilePhotoSource.fromBytes(
              bytes,
              mimeType: mime,
            );
          } finally {
            bytes.fillRange(0, bytes.length, 0);
          }
        }
        if (_prepared == null &&
            !await _accept(
              await _flow!.submit(
                TimewebSocialAction.prepareMedia(_source!.metadata),
              ),
            )) {
          return;
        }
        if (!_current) return;
        final upload = await _runtime.client.leaseProfilePhotoUpload(
          _prepared!,
        );
        try {
          await _runtime.client.putProfilePhoto(upload, _source!);
        } finally {
          // PUT consumes and clears its source, including failed attempts.
          _source?.close();
          _source = null;
        }
        if (!_current) return;
        // PUT alone is not success: Timeweb verifies bytes, MIME and ownership.
        if (!await _accept(
          await _flow!.submit(TimewebSocialAction.commitMedia(_prepared!)),
        )) {
          return;
        }
      }
      if (!_current) return;
      final action = deleting
          ? TimewebSocialAction.deletePost(widget.post!)
          : widget.post == null
          ? TimewebSocialAction.publish(
              _text.text,
              mediaIds: _media,
              scheduledAt: _scheduledAt,
            )
          : TimewebSocialAction.updatePost(widget.post!, _text.text, _media);
      await _accept(await _flow!.submit(action));
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = _scheduledAt != null
              ? 'Публикация по расписанию временно недоступна на сервере. Попробуйте опубликовать без расписания.'
              : (_pending
                  ? 'Подтверждение ещё не получено. Проверьте результат без повторной отправки.'
                  : 'Не удалось сохранить изменения. Попробуйте ещё раз.'),
        );
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_locked) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('Удалить публикацию?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.tr('Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.tr('Удалить')),
          ),
        ],
      ),
    );
    if (confirmed == true && _current) await _send(deleting: true);
  }

  @override
  void dispose() {
    _states?.cancel();
    _flow?.close();
    final source = _source;
    if (source != null) {
      unawaited(_runtime.client.cancelProfilePhotoUpload(source));
      source.close();
    }
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    return ClrsScaffold(
      appBar: AppBar(
        title: Text(
          context.tr(
            widget.post == null ? 'Новая публикация' : 'Редактировать',
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('timeweb-social-text'),
                controller: _text,
                readOnly: _locked,
                minLines: 5,
                maxLines: 12,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: context.tr('Напишите о важном...'),
                ),
              ),
              if (widget.post != null)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mid in _media)
                      SizedBox(
                        width: 88,
                        height: 100,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: !widget.post!.mediaIds.contains(mid)
                                  ? const Icon(Icons.check_circle_outline)
                                  : TimewebPostImage(
                                      runtime: _runtime,
                                      postId: widget.post!.id,
                                      mediaId: mid,
                                      compact: true,
                                    ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: IconButton(
                                tooltip: context.tr('Удалить'),
                                onPressed: _locked
                                    ? null
                                    : () => setState(() => _media.remove(mid)),
                                icon: const Icon(Icons.close),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              ImagePickerGrid(
                existingUrls: const [],
                maxImages: 10 - _media.length,
                newFiles: _files,
                onRemoveExisting: (_) {},
                onRemoveNew: (index) {
                  if (!_locked) {
                    setState(() {
                      if (index == 0) {
                        _source?.close();
                        _source = null;
                        _prepared = null;
                      }
                      _files.removeAt(index);
                    });
                  }
                },
                onAddPressed: _pick,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _locked ? null : _pickScheduleTime,
                      icon: const Icon(Icons.access_time),
                      label: Text(
                        _scheduledAt == null
                            ? context.tr('Время публикации')
                            : '${context.tr('Запланировано на:')} ${_scheduledAt.toString().substring(0, 16)}',
                      ),
                    ),
                  ),
                  if (_scheduledAt != null)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _scheduledAt = null),
                    ),
                ],
              ),
              if (_restoring || _busy)
                const LinearProgressIndicator(
                  key: ValueKey('timeweb-social-busy'),
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(context.tr(_notice!)),
                ),
              FilledButton(
                key: ValueKey(
                  _pending ? 'timeweb-social-check' : 'timeweb-social-send',
                ),
                onPressed:
                    _busy || _restoring || _reloadRequired || _flow == null
                    ? null
                    : () => _send(),
                child: Text(
                  context.tr(
                    _pending
                        ? 'Проверить отправку'
                        : widget.post == null
                        ? 'Опубликовать'
                        : 'Сохранить',
                  ),
                ),
              ),
              if (widget.post != null)
                OutlinedButton(
                  onPressed: _locked ? null : _delete,
                  child: Text(context.tr('Удалить публикацию')),
                ),
              if (_flow == null && !_restoring)
                TextButton(
                  onPressed: _restore,
                  child: Text(context.tr('Повторить')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
