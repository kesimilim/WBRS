import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_archive_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';

/// A fresh owner archive window grants history reading, never member actions.
class TimewebMeetingArchivePageView extends StatefulWidget {
  const TimewebMeetingArchivePageView({
    super.key,
    required this.runtime,
    required this.flow,
    this.onUnavailable,
    this.translationFactory,
  });
  final TimewebAppRuntime runtime;
  final TimewebMeetingArchiveFlow flow;
  final VoidCallback? onUnavailable;
  final ContentTranslationService Function(String? Function())? translationFactory;
  @override
  State<TimewebMeetingArchivePageView> createState() => _TimewebMeetingArchivePageViewState();
}

class _TimewebMeetingArchivePageViewState extends State<TimewebMeetingArchivePageView> {
  late final _runtime = widget.runtime;
  late final _flow = widget.flow;
  AppSessionLease? _lease;
  late final ContentTranslationService _translator;
  StreamSubscription<AppSessionState>? _subscription;
  final _translations = <String, ContentTranslation>{};
  final _originals = <String>{};
  bool _closed = false, _reading = false, _translating = false;
  String? _language, _notice;
  int _generation = 0;
  bool get _current {
    if (!mounted ||
        _closed ||
        _lease?.isCurrent != true ||
        !identical(widget.runtime, _runtime) ||
        !identical(widget.flow, _flow)) {
      return false;
    }
    try {
      _flow.requireCurrent();
      return _flow.ownerUid == _lease!.identity.uid;
    } catch (_) {
      return false;
    }
  }

  String? _translationOwner() =>
      _current ? '${_lease!.identity.uid}/${_lease!.epoch}/archive/${_flow.meetingId}' : null;
  @override
  void initState() {
    super.initState();
    _translator =
        widget.translationFactory?.call(_translationOwner) ??
        ContentTranslationService(
          endpoint: null,
          currentUserId: _translationOwner,
          idToken: () async => null,
          enableOnDevice: true,
          enableRemoteFallback: false,
          maxCacheEntries: 30,
        );
    try {
      _lease = _runtime.session.captureLease();
      _flow.requireCurrent();
      if (_flow.ownerUid != _lease!.identity.uid) throw StateError('Current owner archive unavailable');
      _subscription = _flow.sessionStates.listen((_) {
        if (!_current) _deny();
      });
    } catch (_) {
      _deny();
    }
  }

  @override
  void didUpdateWidget(covariant TimewebMeetingArchivePageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.runtime, oldWidget.runtime) || !identical(widget.flow, oldWidget.flow)) _deny();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final language = Localizations.localeOf(context).languageCode;
    if (_language != language) {
      _language = language;
      _generation++;
      _translations.clear();
      _originals.clear();
      _translator.clear();
    }
  }

  void _deny({bool notify = false}) {
    if (_closed) return;
    _closed = true;
    _generation++;
    _flow.close();
    _translations.clear();
    _originals.clear();
    _translator.clear();
    _notice = null;
    if (notify && _lease?.isCurrent == true) widget.onUnavailable?.call();
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) Navigator.of(context).removeRoute(route);
    });
  }

  Future<void> _older() async {
    if (!_current || _reading || _translating || !_flow.hasOlder) return;
    setState(() {
      _reading = true;
      _notice = null;
    });
    try {
      await _flow.loadOlder();
      if (!_current) {
        _deny(notify: true);
        return;
      }
      setState(() {
        _generation++;
        _translations.clear();
        _originals.clear();
        _translator.clear();
      });
    } catch (_) {
      _deny(notify: true);
    } finally {
      if (_current) setState(() => _reading = false);
    }
  }

  Future<void> _translate(TimewebMeetingMessage message) async {
    if (!_current || _reading || _translating) return;
    final id = message.messageId;
    if (_translations.containsKey(id)) {
      setState(() {
        if (!_originals.remove(id)) _originals.add(id);
      });
      return;
    }
    final generation = _generation, language = _language!, original = message.text;
    setState(() {
      _translating = true;
      _notice = null;
    });
    try {
      final result = await _translator.translate(original, language);
      if (!_current || generation != _generation || language != _language) return;
      message.requireCurrent();
      setState(() {
        if (_translations.length >= 30) {
          final first = _translations.keys.first;
          _translations.remove(first);
          _originals.remove(first);
        }
        _translations[id] = result;
      });
    } catch (_) {
      if (_current && generation == _generation) setState(() => _notice = 'Перевод недоступен. Показан оригинал.');
    } finally {
      if (_current) setState(() => _translating = false);
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _flow.close();
    _translations.clear();
    _originals.clear();
    unawaited(_subscription?.cancel());
    _translator.dispose();
    super.dispose();
  }

  String _clock(String stamp) {
    final date = DateTime.parse(stamp).toLocal();
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _message(TimewebMeetingMessage message) {
    final own = message.senderUid == _lease!.identity.uid, id = message.messageId;
    final translated = _translations[id];
    final showTranslation = translated != null && !_originals.contains(id);
    return Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: 2 / 3,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.tr(own ? 'Вы' : 'Участник'), style: Theme.of(context).textTheme.labelMedium),
              ClrsPanel(
                child: Text(
                  showTranslation ? translated.text : message.text,
                  key: ValueKey('native-archive-message-$id'),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      key: ValueKey('native-archive-translate-$id'),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                      onPressed: _reading || _translating ? null : () => _translate(message),
                      child: Text(
                        context.tr(showTranslation ? 'Показать оригинал' : 'Перевести'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Text(_clock(message.createdAt), style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    backgroundAsset: 'assets/final_design/family_back.png',
    appBar: AppBar(title: const ClrsLogo(size: 34), automaticallyImplyLeading: false),
    body: !_current
        ? Center(child: Text(context.tr('Сохранённая история недоступна')))
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('native-archive-back'),
                      onPressed: () {
                        _deny();
                      },
                      icon: const Icon(Icons.arrow_back),
                    ),
                    Expanded(
                      child: Text(context.tr('Сохранённая история'), style: Theme.of(context).textTheme.titleLarge),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('native-archive-scroll'),
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(context.tr('Сообщения, сохранённые на момент выхода из встречи.')),
                    if (_flow.hasOlder)
                      TextButton(
                        key: const ValueKey('native-archive-older'),
                        onPressed: _reading || _translating ? null : _older,
                        child: Text(context.tr('Ранее')),
                      ),
                    if (_flow.messages.isEmpty) Text(context.tr('В сохранённой истории нет сообщений')),
                    for (final message in _flow.messages.reversed) _message(message),
                    if (!_flow.hasOlder && _flow.messages.isNotEmpty) Text(context.tr('Начало сохранённой истории')),
                    if (_notice != null) Text(context.tr(_notice!)),
                    if (_reading || _translating) const Center(child: CircularProgressIndicator()),
                  ],
                ),
              ),
            ],
          ),
  );
}
