import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_personal_chat_flow.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/presentation/widgets/timeweb_profile_photos_view.dart';
import 'package:wbrs/shared/lrs_theme.dart';

const timewebPersonRoute = '/timeweb/person';

/// Public current fields and the current personal-chat operation only.
/// No presence badge, private source map, gallery or financial/admin action.
class TimewebPersonPage extends StatefulWidget {
  const TimewebPersonPage({
    super.key,
    required this.runtime,
    required this.uid,
  });
  final TimewebAppRuntime runtime;
  final String uid;
  @override
  State<TimewebPersonPage> createState() => _TimewebPersonPageState();
}

class _TimewebPersonPageState extends State<TimewebPersonPage> {
  StreamSubscription<AppSessionState>? _subscription;
  late final int _epoch;
  TimewebPublicPerson? _person;
  TimewebPersonalChatFlow? _chatAction;
  bool _chatPreparing = false, _chatBusy = false;
  String? _chatNotice;
  String? _target;
  int _generation = 0;
  bool _loading = false, _error = false, _missing = false, _invalidated = false;
  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _target = widget.uid;
    _subscription = widget.runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    unawaited(_reload());
    unawaited(_prepareChat());
  }

  bool get _current {
    final state = widget.runtime.session.state;
    if (!mounted ||
        _invalidated ||
        !state.authenticated ||
        state.epoch != _epoch) {
      return false;
    }
    try {
      _person?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) {
      return;
    }
    _invalidated = true;
    _generation++;
    _person = null;
    _chatAction?.close();
    _chatAction = null;
    _chatNotice = null;
    _target = null;
    _loading = _error = _missing = false;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _reload() async {
    if (!_current || _loading || _target == null) {
      return;
    }
    if (_chatAction != null &&
        !_chatBusy &&
        !_chatAction!.needsCheck &&
        _chatAction!.receipt == null) {
      _chatAction?.close();
      _chatAction = null;
    }
    if (_chatAction == null) unawaited(_prepareChat());
    final generation = ++_generation, uid = _target!;
    setState(() {
      _person = null;
      _loading = true;
      _error = _missing = false;
    });
    try {
      final person = await widget.runtime.readPerson(uid);
      if (!_current || generation != _generation) return;
      person.requireCurrent();
      setState(() => _person = person);
    } on TimewebPersonNotFound {
      if (_current && generation == _generation) {
        setState(() => _missing = true);
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() => _error = true);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _prepareChat() async {
    if (!_current ||
        !widget.runtime.personalChatEnabled ||
        _chatPreparing ||
        _chatAction != null ||
        _target == null) {
      return;
    }
    setState(() => _chatPreparing = true);
    try {
      final action = await widget.runtime.openPersonalChat(_target!);
      if (!_current) {
        action.close();
        return;
      }
      setState(() {
        _chatAction = action;
        if (action.needsCheck) {
          _chatNotice =
              'Результат открытия чата пока неизвестен. Проверьте результат.';
        }
      });
    } catch (_) {
      if (_current) setState(() => _chatNotice = 'Чат недоступен');
    } finally {
      if (mounted) setState(() => _chatPreparing = false);
    }
  }

  Future<void> _openChat() async {
    if (!_current || _chatBusy || _chatAction == null) return;
    final action = _chatAction!;
    if (!action.needsCheck &&
        action.receipt == null &&
        (_person == null || action.rejected)) {
      return;
    }
    setState(() {
      _chatBusy = true;
      _chatNotice = null;
    });
    try {
      final outcome = action.receipt != null || action.needsCheck
          ? await action.check()
          : await action.submit();
      if (!_current) return;
      if (outcome != TimewebPersonalChatOutcome.confirmed) {
        if (action.failure == TimewebMutationFailure.personUnavailable) {
          _person = null;
          _missing = true;
        }
        setState(
          () => _chatNotice =
              action.failure == TimewebMutationFailure.personUnavailable
              ? 'Профиль недоступен'
              : outcome == TimewebPersonalChatOutcome.unknown
              ? 'Результат открытия чата пока неизвестен. Проверьте результат.'
              : 'Чат недоступен',
        );
        return;
      }
      final receipt = action.receipt!;
      final flow = await widget.runtime.openPersonalConversation(receipt);
      if (!mounted || !_current) {
        flow.close();
        return;
      }
      // Existing native chat receives only the committed exact ID after its
      // fresh membership/messages GET. No Firebase route or imported-ID rewrite.
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/clrs/native/chat'),
          builder: (_) => TimewebChatPage(flow: flow),
        ),
      );
    } catch (_) {
      if (_current) {
        setState(
          () => _chatNotice = _chatAction?.needsCheck == true
              ? 'Результат открытия чата пока неизвестен. Проверьте результат.'
              : 'Чат недоступен',
        );
      }
    } finally {
      if (mounted) setState(() => _chatBusy = false);
    }
  }

  Widget _chatControls() {
    final action = _chatAction;
    final checking = _current && action?.needsCheck == true;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_chatPreparing || _chatBusy) const LinearProgressIndicator(),
          if (_chatNotice != null) Text(context.tr(_chatNotice!)),
          ElevatedButton.icon(
            key: const ValueKey('timeweb-person-open-chat'),
            onPressed:
                !_current ||
                    _chatBusy ||
                    _chatPreparing ||
                    action == null ||
                    (!checking && (action.rejected || _person == null))
                ? null
                : _openChat,
            icon: Icon(checking ? Icons.refresh : Icons.chat_bubble_outline),
            label: Text(
              context.tr(
                checking ? 'Проверить результат' : 'Отправить сообщение',
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    _person = null;
    _chatAction?.close();
    _chatAction = null;
    _chatNotice = null;
    _target = null;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  String _text(Object? value) =>
      value == null || value == '' ? context.tr('Не указано') : '$value';
  @override
  Widget build(BuildContext context) {
    final person = _current ? _person : null;
    return ClrsScaffold(
      key: const ValueKey('timeweb-public-profile'),
      appBar: AppBar(
        title: const ClrsLogo(size: 34),
        actions: [
          IconButton(
            key: const ValueKey('timeweb-person-refresh'),
            tooltip: context.tr('Обновить'),
            onPressed: _current && !_loading && !_chatBusy && !_chatPreparing
                ? _reload
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          const Align(
            alignment: Alignment.centerRight,
            child: ClrsMotto(size: 18),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (!_current) Text(context.tr('Сеанс завершён')),
          if (_missing || _error)
            ClrsPanel(
              child: Column(
                children: [
                  Text(
                    context.tr(
                      _missing
                          ? 'Профиль недоступен'
                          : 'Не удалось загрузить пользователей',
                    ),
                  ),
                  if (_error)
                    TextButton(
                      key: const ValueKey('timeweb-person-retry'),
                      onPressed: _reload,
                      child: Text(context.tr('Повторить')),
                    ),
                ],
              ),
            ),
          if (person == null && widget.runtime.personalChatEnabled && _current)
            _chatControls(),
          if (person != null) ...[
            TimewebProfilePhotosView(
              runtime: widget.runtime, targetUid: person.uid,
              primaryGroup: person.primaryGroup,
              portraitHeight: (MediaQuery.sizeOf(context).width * .62).clamp(190, 300),
            ),
            const SizedBox(height: 10),
            Text(
              _text(person.fullName),
              key: const ValueKey('timeweb-public-name'),
              style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
            ),
            if (widget.runtime.personalChatEnabled) _chatControls(),
            _section(
              'Обо мне',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final fact in <(String, Object?)>[
                    ('Возраст', person.age),
                    ('Рост', person.rost),
                    ('Пол', person.pol),
                    ('Статус', person.relationStatus),
                    (
                      'Дети',
                      person.deti == null
                          ? null
                          : context.tr(person.deti! ? 'Есть' : 'Нет'),
                    ),
                    ('Страна', person.country),
                    ('Регион', person.region),
                    ('Город', person.city),
                    ('Группа', person.primaryGroup),
                    ('Дополнительная группа', person.secondaryGroup),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tr(fact.$1),
                            style: const TextStyle(
                              fontSize: 11,
                              color: LrsTheme.peachLight,
                            ),
                          ),
                          Text(_text(fact.$2)),
                        ],
                      ),
                    ),
                  Text(
                    context.tr(
                      'Последнее посещение: {date}',
                      args: {'date': _text(person.lastOnlineAt)},
                    ),
                  ),
                ],
              ),
            ),
            _section('Интересы и увлечения', Text(_text(person.hobbi))),
            _section('О себе', Text(_text(person.about))),
            const ClrsValuesFooter(),
          ],
        ],
      ),
    );
  }

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Container(
      decoration: BoxDecoration(
        color: const Color(0xCC302110),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x66E7B092), width: .8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.tr(title),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}
