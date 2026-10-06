import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Allows tests and previews to inject a translator without touching Firebase.
class ContentTranslationScope extends InheritedWidget {
  const ContentTranslationScope(
      {super.key, required this.service, required super.child});
  final ContentTranslationService service;
  static ContentTranslationService of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ContentTranslationScope>()
          ?.service ??
      ContentTranslationService.instance;
  @override
  bool updateShouldNotify(ContentTranslationScope oldWidget) =>
      service != oldWidget.service;
}

/// User content is translated for display; copy/edit/send always retain originals.
/// Auto mode is used for profile/feed/meeting text, manual mode under messages.
class TranslatableText extends StatefulWidget {
  const TranslatableText(this.text,
      {super.key,
      this.style,
      this.maxLines,
      this.overflow,
      this.textAlign,
      this.autoTranslate = true,
      this.showAction = true,
      this.selectable = false,
      this.compactMeeting = false,
      this.compactFooter,
      this.sourceLanguage});
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final bool autoTranslate, showAction, selectable;
  final bool compactMeeting;
  final Widget? compactFooter;

  /// Stored language metadata avoids a paid detection request for same-language
  /// content. If absent, the translation service may detect it on demand.
  final String? sourceLanguage;
  @override
  State<TranslatableText> createState() => _TranslatableTextState();
}

class _TranslatableTextState extends State<TranslatableText> {
  ContentTranslationService? _service;
  String? _language;
  ContentTranslation? _translation;
  TranslationFailure? _failure;
  bool _busy = false, _showOriginal = true;
  bool _sessionInvalidated = false;
  String? _ownerUserId;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = ContentTranslationScope.of(context);
    final language = context.l10n.locale.languageCode;
    if (!identical(service, _service) || language != _language) {
      if (!identical(service, _service)) {
        _ownerUserId = service.sessionId;
        _sessionInvalidated = false;
      }
      _service?.removeListener(_sessionCleared);
      _service = service..addListener(_sessionCleared);
      _language = language;
      _reset();
    }
  }

  @override
  void didUpdateWidget(TranslatableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.autoTranslate != widget.autoTranslate ||
        oldWidget.sourceLanguage != widget.sourceLanguage) _reset();
  }

  bool get _alreadySelectedLanguage =>
      widget.sourceLanguage != null &&
      ClrsLocalizations.normalizeCode(widget.sourceLanguage) == _language;

  void _reset() {
    _request++;
    _translation = null;
    _failure = _sessionInvalidated ? TranslationFailure.sessionChanged : null;
    _busy = false;
    _showOriginal = true;
    // Schedule outside build; a changed locale/text invalidates the scheduled work.
    if (!_sessionInvalidated &&
        !_alreadySelectedLanguage &&
        widget.autoTranslate &&
        widget.text.trim().isNotEmpty) {
      final generation = _request;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _request) _translate();
      });
    }
  }

  void _sessionCleared() {
    if (!mounted) return;
    setState(() {
      _request++;
      _sessionInvalidated = true;
      _translation = null;
      _busy = false;
      _showOriginal = true;
      _failure = TranslationFailure.sessionChanged;
    });
  }

  Future<void> _translate() async {
    if (_busy || widget.text.trim().isEmpty || _alreadySelectedLanguage) return;
    if (_sessionInvalidated || _service!.sessionId != _ownerUserId) {
      _sessionCleared();
      return;
    }
    final generation = ++_request;
    final source = widget.text;
    final target = _language!;
    final service = _service!;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final literal = context.l10n.literalTranslation(source);
      final translated = literal == null
          ? await service.translate(source, target)
          : ContentTranslation(
              text: literal, sourceLanguage: 'ru', targetLanguage: target);
      if (!mounted ||
          generation != _request ||
          source != widget.text ||
          target != _language) return;
      setState(() {
        _translation = translated;
        _showOriginal = translated.alreadyTarget && translated.text == source;
      });
    } on ContentTranslationException catch (error) {
      if (mounted && generation == _request)
        setState(() => _failure = error.failure);
    } catch (_) {
      if (mounted && generation == _request)
        setState(() => _failure = TranslationFailure.unavailable);
    } finally {
      if (mounted && generation == _request) setState(() => _busy = false);
    }
  }

  String _error(BuildContext context) {
    switch (_failure) {
      case TranslationFailure.notConfigured:
        return context.tr('Переводчик ещё не подключён.');
      case TranslationFailure.tooLong:
        return context.tr('Слишком длинный текст для перевода.');
      case TranslationFailure.signedOut:
      case TranslationFailure.sessionChanged:
        return context.tr('Сеанс изменился. Откройте текст заново.');
      case TranslationFailure.rateLimited:
        return context.tr('Перевод временно недоступен. Попробуйте позже.');
      case TranslationFailure.unsupportedLanguage:
        return context.tr('Перевод для этого языка недоступен.');
      default:
        return context.tr('Не удалось перевести. Попробуйте ещё раз.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = !_showOriginal && _translation != null
        ? _translation!.text
        : widget.text;
    final alignment = widget.compactMeeting &&
        (widget.textAlign == TextAlign.end || widget.textAlign == TextAlign.right)
        ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final content = widget.selectable
        ? SelectableText(shown,
            style: widget.style,
            maxLines: widget.maxLines,
            textAlign: widget.textAlign)
        : Text(shown,
            style: widget.style,
            maxLines: widget.maxLines,
            overflow: widget.overflow,
            textAlign: widget.textAlign);
    final text = widget.compactMeeting
        ? Container(
            key: const ValueKey('compact-meeting-bubble'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0x8031241D),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [content, if (widget.compactFooter != null) widget.compactFooter!],
            ),
          )
        : content;
    final attribution = _translation?.googlePowered == true && !_showOriginal
        ? Semantics(
            label: 'Translated by Google',
            button: true,
            child: InkWell(
              onTap: () async {
                try {
                  await launchUrl(Uri.parse('https://translate.google.com'),
                      mode: LaunchMode.externalApplication);
                } catch (_) {
                  // Attribution remains visible if no external browser exists.
                }
              },
              child: Image.asset('assets/attribution/translated-by-google.png',
                  width: 122, height: 16, alignment: Alignment.centerLeft),
            ),
          )
        : null;
    if (!widget.showAction ||
        widget.text.trim().isEmpty ||
        _alreadySelectedLanguage ||
        (_translation?.alreadyTarget == true &&
            _translation?.text == widget.text)) {
      if (_failure == null && attribution == null) return text;
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: alignment,
          children: [
            text,
            if (_failure != null)
              Text(_error(context),
                  style: Theme.of(context).textTheme.bodySmall),
            if (attribution != null)
              Padding(
                  padding: const EdgeInsets.only(top: 2), child: attribution),
          ]);
    }
    final label = _busy
        ? context.tr('Перевод…')
        : _translation == null
            ? context.tr(_service?.usesOnDevice == true
                ? 'Перевести с Google'
                : 'Перевести')
            : _showOriginal
                ? context.tr('Показать перевод')
                : context.tr('Показать оригинал');
    final action = TextButton(
      onPressed: _busy ||
              _sessionInvalidated ||
              _failure == TranslationFailure.unsupportedLanguage
          ? null
          : () {
              if (_translation == null) {
                _translate();
              } else {
                setState(() => _showOriginal = !_showOriginal);
              }
            },
      style: TextButton.styleFrom(
          alignment: AlignmentDirectional.centerStart,
          minimumSize: widget.compactMeeting ? Size.zero : null,
          tapTargetSize: widget.compactMeeting ? MaterialTapTargetSize.shrinkWrap : null,
          visualDensity: widget.compactMeeting ? VisualDensity.compact : null,
          padding: widget.compactMeeting ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 0, vertical: 4)),
      child: Text(label,
          softWrap: true,
          style: TextStyle(
            fontSize: widget.compactMeeting ? 11 : null,
            height: widget.compactMeeting ? 1.1 : null,
            decoration: TextDecoration.underline)),
    );
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: alignment,
        children: [
          text,
          if (_failure != null)
            Text(_error(context), style: Theme.of(context).textTheme.bodySmall),
          if (_translation?.alreadyTarget == true)
            Text(context.tr('Текст уже на выбранном языке.'),
                style: Theme.of(context).textTheme.bodySmall),
          if (attribution == null)
            action
          else
            LayoutBuilder(builder: (context, constraints) {
              if (constraints.maxWidth < 200) {
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [action, attribution]);
              }
              return Row(children: [
                Expanded(child: action),
                const SizedBox(width: 8),
                attribution,
              ]);
            }),
        ]);
  }

  @override
  void dispose() {
    _request++;
    _service?.removeListener(_sessionCleared);
    super.dispose();
  }
}
