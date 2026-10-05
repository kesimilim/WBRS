import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/post_submission.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'image_picker_grid.dart';

class PostEditorPage extends StatefulWidget {
  const PostEditorPage({
    super.key,
    this.social,
    this.postSubmissions,
    this.postId,
    this.initialText,
    this.initialImages = const [],
  });

  final SocialService? social;
  final PostSubmissionService? postSubmissions;
  final String? postId;
  final String? initialText;
  final List<String> initialImages;

  @override
  State<PostEditorPage> createState() => _PostEditorPageState();
}

class _PostEditorPageState extends State<PostEditorPage> {
  late final SocialService _social;
  late final PostSubmissionService _submissions;
  final _controller = TextEditingController();
  final _picker = ImagePicker();

  final List<String> _existingUrls = [];
  final List<XFile> _newFiles = [];
  bool _sending = false;
  bool _restoring = true;
  PostSubmission? _submission;
  String? _notice;
  PendingWrite? _editWrite;

  bool get _isEditing => widget.postId != null;
  bool get _locked => _restoring || _sending || _submission != null;

  @override
  void initState() {
    super.initState();
    _social = widget.social ?? SocialService();
    _submissions =
        widget.postSubmissions ?? PostSubmissionService(social: _social);
    _controller.text = widget.initialText ?? '';
    _existingUrls.addAll(widget.initialImages);
    if (_isEditing) {
      _restoring = false;
    } else {
      _restore();
    }
  }

  Future<void> _restore() async {
    try {
      final saved = await _submissions.restore();
      if (!mounted) return;
      if (saved != null) {
        _submission = saved;
        _controller.text = saved.text;
        _newFiles
          ..clear()
          ..addAll(saved.images);
        _notice =
        'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
      }
    } catch (_) {
      if (mounted) {
        _notice = 'Не удалось восстановить отправку. Попробуйте ещё раз.';
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    final total = _existingUrls.length + _newFiles.length;
    if (total >= 10) return;
    try {
      final picked = await _picker.pickMultiImage(
        imageQuality: 72,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (picked.isEmpty || !mounted || _locked) return;
      final room = 10 - total;
      setState(() {
        _newFiles.addAll(picked.take(room));
      });
    } catch (_) {
      if (mounted) {
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось открыть изображение. Попробуйте ещё раз.'));
      }
    }
  }

  Future<void> _submit() async {
    if (_locked) return;
    final text = _controller.text.trim();
    if (text.isEmpty && _existingUrls.isEmpty && _newFiles.isEmpty) return;
    setState(() {
      _sending = true;
      _notice = null;
    });
    try {
      if (_isEditing) {
        await _edit();
      } else {
        await _create();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _create() async {
    if (_submission?.write.failed == true) _submission = null;
    _submission ??= _submissions.start(
      text: _controller.text,
      images: _newFiles,
    );
    final confirmed = await _submission!.write.wait();
    if (!mounted) return;
    if (!_submissions.isCurrentSession) {
      setState(() => _notice =
      'Сеанс изменился. Проверьте отправку после входа в исходный аккаунт.');
      return;
    }
    if (!confirmed) {
      setState(() => _notice =
      'Подтверждение ещё не получено. Нажмите «Проверить отправку».');
      return;
    }
    _submissions.acknowledge(_submission!);
    Navigator.of(context).pop(true);
  }

  Future<void> _edit() async {
    _editWrite ??= PendingWrite(() => _social.updatePost(
      postId: widget.postId!,
      text: _controller.text,
      keepImageUrls: _existingUrls,
      newImages: _newFiles,
    ));
    try {
      final confirmed = await _editWrite!.wait();
      if (!mounted) return;
      if (!confirmed) {
        setState(() => _notice =
        'Подтверждение ещё не получено. Нажмите «Проверить отправку».');
        return;
      }
      Navigator.of(context).pop(true);
    } catch (_) {
      _editWrite = null;
      if (mounted) {
        setState(() =>
        _notice = 'Не удалось сохранить изменения. Попробуйте ещё раз.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClrsScaffold(
      appBar: AppBar(
        title:
        Text(context.tr(_isEditing ? 'Редактировать' : 'Новая публикация')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                readOnly: _locked,
                minLines: 5,
                maxLines: 12,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: LrsTheme.text),
                decoration: InputDecoration(
                  labelText: context.tr('Напишите о важном...'),
                  counterStyle: const TextStyle(color: LrsTheme.muted),
                ),
              ),
              const SizedBox(height: 12),
              ImagePickerGrid(
                existingUrls: _existingUrls,
                newFiles: _newFiles,
                onRemoveExisting: _locked
                    ? (_) {}
                    : (i) => setState(() => _existingUrls.removeAt(i)),
                onRemoveNew: _locked
                    ? (_) {}
                    : (i) => setState(() => _newFiles.removeAt(i)),
                onAddPressed: _pickImages,
              ),
              const SizedBox(height: 12),
              if (_restoring) const LinearProgressIndicator(),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(context.tr(_notice!)),
                ),
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: LrsTheme.actionGlass,
                  foregroundColor: LrsTheme.text,
                  disabledBackgroundColor: LrsTheme.actionDisabled,
                  disabledForegroundColor: LrsTheme.muted,
                  side: const BorderSide(color: LrsTheme.actionBorder),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _sending ? null : _submit,
                child: _sending
                    ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: LrsTheme.text))
                    : Text(context.tr(_isEditing
                    ? 'Сохранить'
                    : _submission == null
                    ? 'Опубликовать'
                    : 'Проверить отправку')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}