import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/author_request_submission.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';

Future<bool?> showAuthorRequestSheet(
        BuildContext context, SocialService social) =>
    showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: LrsTheme.surface,
        builder: (_) => AuthorRequestSheet(
            submissions: AuthorRequestSubmissionService(social: social)));

class AuthorRequestSheet extends StatefulWidget {
  const AuthorRequestSheet({super.key, required this.submissions});
  final AuthorRequestSubmissionService submissions;
  @override
  State<AuthorRequestSheet> createState() => _AuthorRequestSheetState();
}

class _AuthorRequestSheetState extends State<AuthorRequestSheet> {
  final _text = TextEditingController();
  final List<XFile> _images = [];
  AuthorRequestSubmission? _submission;
  bool _restoring = true, _sending = false;
  String? _notice;
  bool get _locked => _restoring || _sending || _submission != null;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final saved = await widget.submissions.restore();
      if (!mounted) return;
      if (saved != null) {
        _text.text = saved.text;
        _images
          ..clear()
          ..addAll(saved.images);
        _submission = saved.write.failed ? null : saved;
        _notice = saved.write.failed
            ? 'Не удалось отправить заявку. Попробуйте ещё раз.'
            : 'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
      }
    } catch (_) {
      _notice = 'Не удалось восстановить отправку. Попробуйте ещё раз.';
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    if (_images.length >= 10) return;
    try {
      final picked = await ImagePicker().pickMultiImage(
          imageQuality: 72, maxWidth: 1600, maxHeight: 1600);
      if (picked.isEmpty ||
          !mounted ||
          _locked ||
          !widget.submissions.isCurrentSession) {
        return;
      }
      final room = 10 - _images.length;
      setState(() => _images.addAll(picked.take(room)));
    } catch (_) {
      if (mounted) {
        setState(() =>
            _notice = 'Не удалось открыть изображение. Попробуйте ещё раз.');
      }
    }
  }

  Future<void> _send() async {
    if (_sending || _restoring || _text.text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _notice = null;
    });
    try {
      _submission ??=
          widget.submissions.start(text: _text.text.trim(), images: _images);
      final confirmed = await _submission!.write.wait();
      if (!mounted) return;
      if (!widget.submissions.isCurrentSession) {
        setState(() => _notice = 'Сеанс завершён. Войдите снова.');
        return;
      }
      if (confirmed) {
        widget.submissions.acknowledge(_submission!);
        Navigator.pop(context, true);
      } else {
        setState(() => _notice =
            'Подтверждение ещё не получено. Нажмите «Проверить отправку».');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _submission = null;
          _notice = 'Не удалось отправить заявку. Попробуйте ещё раз.';
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
      child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.tr('Хочу стать автором'),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                    controller: _text,
                    enabled: !_locked,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 10000,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                        labelText: context.tr('Предлагаемая публикация'))),
                if (_images.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < _images.length; i++)
                        SizedBox(
                          width: 88,
                          height: 88,
                          child: Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.file(File(_images[i].path),
                                    fit: BoxFit.cover,
                                    width: 88,
                                    height: 88,
                                    errorBuilder: (_, __, ___) => const Icon(
                                        Icons.broken_image_outlined)),
                              ),
                              Positioned(
                                top: 2,
                                right: 2,
                                child: GestureDetector(
                                  onTap: _locked
                                      ? null
                                      : () => setState(
                                          () => _images.removeAt(i)),
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.close,
                                        size: 14, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
                TextButton.icon(
                    onPressed: _locked ? null : _pickImage,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(context.tr('Добавить фото'))),
                if (_notice != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(context.tr(_notice!))),
                FilledButton(
                    onPressed:
                        _restoring || _sending || _text.text.trim().isEmpty
                            ? null
                            : _send,
                    style: FilledButton.styleFrom(
                        backgroundColor: LrsTheme.actionGlass,
                        foregroundColor: LrsTheme.text),
                    child: _restoring || _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(context.tr(_submission == null
                            ? 'Отправить заявку'
                            : 'Проверить отправку'))),
              ])));
}
