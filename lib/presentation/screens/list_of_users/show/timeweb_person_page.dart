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
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_gallery.dart';
import 'package:wbrs/presentation/screens/shop/timeweb_gifts_page.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/shared/profile_composition.dart';
import 'package:wbrs/shared/translatable_text.dart';
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
  late final ContentTranslationService _translator;
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
    _translator = ContentTranslationService(
      endpoint: null,
      currentUserId: () => _current
          ? '${widget.runtime.session.state.identity?.uid}/$_epoch'
          : null,
      idToken: () async => null,
      enableOnDevice: true,
      enableRemoteFallback: false,
      maxCacheEntries: 20,
    );
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
    _translator.clear();
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

  Future<void> _openChat({bool gift = false}) async {
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
      if (gift) {
        if (!mounted || !_current) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => TimewebGiftsPage(
              runtime: widget.runtime,
              preferredChatId: receipt.chatId,
            ),
          ),
        );
        return;
      }
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
          builder: (_) => TimewebChatPage(flow: flow, runtime: widget.runtime),
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
    final available =
        _current &&
        !_chatBusy &&
        !_chatPreparing &&
        action != null &&
        (checking || (!action.rejected && _person != null));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_chatPreparing || _chatBusy) const LinearProgressIndicator(),
        if (_chatNotice != null) Text(context.tr(_chatNotice!)),
        Text(
          context.tr('Хорошие люди находят друг друга ♡'),
          style: const TextStyle(color: LrsTheme.peachLight),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (widget.runtime.giftsEnabled)
              OutlinedButton.icon(
                key: const ValueKey('timeweb-person-gift'),
                onPressed: available && !checking
                    ? () => _openChat(gift: true)
                    : null,
                icon: const Icon(Icons.card_giftcard_outlined, size: 18),
                label: Text(context.tr('Подарить Подарок ❤️')),
              ),
            OutlinedButton.icon(
              key: const ValueKey('timeweb-person-open-chat'),
              onPressed: available ? () => _openChat() : null,
              icon: Icon(
                checking ? Icons.refresh : Icons.chat_bubble_outline,
                size: 18,
              ),
              label: Text(
                context.tr(checking ? 'Проверить результат' : 'Написать'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  void dispose() {
    _generation++;
    _person = null;
    _translator.clear();
    _chatAction?.close();
    _chatAction = null;
    _chatNotice = null;
    _target = null;
    _translator.dispose();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final person = _current ? _person : null;
    final data = person == null
        ? <String, dynamic>{}
        : <String, dynamic>{
            'fullName': person.fullName,
            'age': person.age,
            'rost': person.rost,
            'pol': person.pol,
            'relationStatus': person.relationStatus,
            'deti': person.deti,
            'country': person.country,
            'region': person.region,
            'city': person.city,
            'группа': person.primaryGroup,
            'about': person.about,
            'hobbi': person.hobbi,
          };
    return ContentTranslationScope(
      service: _translator,
      child: ClrsScaffold(
        key: const ValueKey('timeweb-public-profile'),
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
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
        body: person == null
            ? ListView(
                padding: EdgeInsets.fromLTRB(
                  14,
                  MediaQuery.paddingOf(context).top + 70,
                  14,
                  24,
                ),
                children: [
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
                  if (widget.runtime.personalChatEnabled && _current)
                    _chatControls(),
                ],
              )
            : SingleChildScrollView(
                child: TimewebOwnProfileGallery(
                  runtime: widget.runtime,
                  targetUid: person.uid,
                  portraitBuilder: (photo) => ProfilePortrait(
                    key: const ValueKey('timeweb-public-name'),
                    photo: '',
                    photoContent: photo,
                    name: person.fullName ?? '',
                    age: person.age?.toString() ?? '',
                    group: person.primaryGroup ?? '',
                    gender: person.pol ?? '',
                    online: null,
                    location: profileLocation(data, context: context),
                    status: relationshipLabel(person.relationStatus),
                  ),
                  abovePhotos: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                    child: widget.runtime.personalChatEnabled
                        ? _chatControls()
                        : const SizedBox.shrink(),
                  ),
                  belowPhotos: [
                    ProfileSection(
                      title: context.tr('Обо мне'),
                      child: ProfileFacts(data: data),
                    ),
                    const ClrsValuesFooter(),
                  ],
                ),
              ),
      ),
    );
  }
}
