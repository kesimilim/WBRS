import 'dart:async';

import 'package:wbrs/presentation/screens/admin/timeweb_admin_users_page.dart';

import 'package:wbrs/presentation/screens/list_of_users/timeweb_people_page.dart';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/edit_profile/timeweb_profile_edit_page.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_profile_edit_flow.dart';
import 'package:wbrs/service/timeweb_temperament_flow.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/service/timeweb_geography_flow.dart';
import 'package:wbrs/presentation/screens/edit_profile/timeweb_geography_page.dart';
import 'package:wbrs/presentation/screens/test/timeweb_temperament_page.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_badge.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/presentation/widgets/timeweb_profile_photos_view.dart';
import 'package:wbrs/presentation/widgets/timeweb_photo_append_control.dart';
import 'package:wbrs/presentation/screens/auth/writing_profile_page/timeweb_initial_profile_page.dart';

const timewebOwnProfileRoute = '/timeweb/own-profile';

/// The approved CLRS profile composition over current native fields. No legacy
/// hydration, Firebase destinations, inferred presence or fake media gallery.
class TimewebOwnProfilePage extends StatefulWidget {
  const TimewebOwnProfilePage({
    super.key,
    required this.runtime,
    this.initialProfile,
    this.initialError = false,
    this.onOpenPeople,
  });
  final TimewebAppRuntime runtime;
  final TimewebCurrentOwnProfile? initialProfile;
  final bool initialError;
  final VoidCallback? onOpenPeople;
  @override
  State<TimewebOwnProfilePage> createState() => _TimewebOwnProfilePageState();
}

class _TimewebOwnProfilePageState extends State<TimewebOwnProfilePage> {
  StreamSubscription<AppSessionState>? _subscription;
  TimewebCurrentOwnProfile? _profile;
  TimewebProfileEditFlow? _editor;
  TimewebTemperamentFlow? _temperament;
  TimewebGeographyFlow? _geography;
  late final int _epoch;
  int _generation = 0;
  bool _loading = false, _opening = false, _error = false, _invalidated = false;
  String? _notice;
  bool _adminAllowed = false;
  bool _initialPending = false, _initialChecked = false;

  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _profile = widget.initialProfile;
    _error = widget.initialError;
    unawaited(_prepareInitialAndTemperament());
    unawaited(_probeAdmin());
    _subscription = widget.runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
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
      _profile?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _generation++;
    _profile = null;
    _editor?.close();
    _editor = null;
    _temperament?.close();
    _temperament = null;
    _geography?.close();
    _geography = null;
    _notice = null;
    _adminAllowed = false;
    _initialPending = false;
    _initialChecked = false;
    _loading = false;
    _opening = false;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _probeAdmin() async {
    if (!_current || !widget.runtime.adminUsersEnabled) return;
    final allowed = await widget.runtime.probeAdminUsersAccess();
    if (_current) setState(() => _adminAllowed = allowed);
  }

  Future<void> _openAdmin() async {
    if (!_current || !_adminAllowed || _loading || _opening) return;
    setState(() => _opening = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebAdminUsersRoute),
          builder: (_) => TimewebAdminUsersPage(
            runtime: widget.runtime,
            onAccessDenied: () {
              if (_current) setState(() => _adminAllowed = false);
            },
          ),
        ),
      );
    } finally {
      if (_current) setState(() => _opening = false);
    }
  }

  Future<void> _reload() async {
    if (!_current || _loading || _opening) return;
    final generation = ++_generation;
    setState(() {
      _profile = null;
      _temperament?.close();
      _temperament = null;
      _loading = true;
      _initialChecked = false;
      _error = false;
      _notice = null;
    });
    try {
      final profile = await widget.runtime.readCurrentOwnProfile();
      if (!_current || generation != _generation) return;
      profile.requireCurrent();
      setState(() => _profile = profile);
      await _prepareInitialAndTemperament();
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

  Future<void> _prepareInitialAndTemperament() async {
    if (!_current) return;
    if (!widget.runtime.profileEditorEnabled) { await _prepareTemperament(); return; }
    final generation = _generation;
    TimewebInitialProfileFlow? flow;
    try {
      // A lost finish ACK can already produce saved=true. This entry restores
      // only that original intent; fresh submission still requires flags 0/0.
      flow = await widget.runtime.openInitialProfile();
      if (!_current || generation != _generation) return;
      setState(() {
        _initialPending = flow!.pendingRequest != null && flow.needsCheck;
        _initialChecked = true;
      });
    } catch (_) {
      if (_current && generation == _generation) setState(() => _initialPending = false);
    } finally { flow?.close(); }
    if (_current && !_initialPending) await _prepareTemperament();
  }

  Future<void> _prepareTemperament() async {
    final snapshot = _profile;
    if (!_current ||
        !widget.runtime.temperamentEnabled ||
        snapshot == null ||
        snapshot.profile == null ||
        snapshot.onboarding == TimewebOnboarding.registration) {
      return;
    }
    final generation = _generation;
    try {
      // A committed lost ACK can already make the current profile 'search'.
      // Recovery still exposes the original journal as lookup-only.
      final flow = await widget.runtime.openTemperament(snapshot);
      if (!mounted ||
          !_current ||
          generation != _generation ||
          !identical(_profile, snapshot)) {
        flow.close();
        return;
      }
      flow.requireCurrent();
      setState(() => _temperament = flow);
    } on TimewebNoPendingTemperament {
      // A completed profile without a pending operation needs no recovery.
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() => _notice = 'Сервис пока недоступен. Попробуйте позднее.');
      }
    }
  }

  Future<void> _openTemperament() async {
    if (!_current || _loading || _opening) return;
    final flow = _temperament;
    if (flow == null) return;
    try {
      flow.requireCurrent();
    } catch (_) {
      return;
    }
    setState(() {
      _opening = true;
      _notice = null;
    });
    try {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebTemperamentRoute),
          builder: (_) => TimewebTemperamentPage(flow: flow),
        ),
      );
      _temperament = null;
      if (_current) {
        setState(() => _opening = false);
        await _reload();
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _initialRegistration() async {
    if (!_current || _loading || _opening || !widget.runtime.profileEditorEnabled) return;
    setState(() { _opening = true; _notice = null; });
    try {
      final snapshot = await widget.runtime.readCurrentOwnProfile();
      if (!_current || !mounted) return;
      snapshot.requireCurrent();
      final profile = snapshot.profile;
      final eligible = profile?.profileDetailsSaved == false && profile?.isRegistrationEnd == false &&
          snapshot.onboarding != TimewebOnboarding.search;
      if (!eligible && !_initialPending) return;
      await Navigator.of(context).push<bool>(MaterialPageRoute(
        settings: const RouteSettings(name: timewebInitialProfileRoute),
        builder: (_) => TimewebInitialProfilePage(runtime: widget.runtime, initialProfile: snapshot),
      ));
      if (_current) {
        setState(() => _opening = false);
        await _reload();
      }
    } catch (_) {
      if (_current) setState(() => _notice = 'Сервис пока недоступен. Попробуйте позднее.');
    } finally { if (mounted) setState(() => _opening = false); }
  }

  bool get _initialRequired {
    final profile = _profile?.profile;
    return profile?.profileDetailsSaved == false && profile?.isRegistrationEnd == false &&
        _profile?.onboarding != TimewebOnboarding.search;
  }

  Future<void> _edit() async {
    if (!_current ||
        !_initialChecked || _initialPending || _initialRequired ||
        _loading ||
        _opening ||
        !widget.runtime.profileEditorEnabled ||
        _profile?.profileExists != true) {
      return;
    }
    setState(() {
      _opening = true;
      _notice = null;
    });
    TimewebProfileEditFlow? flow;
    try {
      flow = await widget.runtime.openProfileEditor();
      if (!mounted || !_current) {
        flow.close();
        return;
      }
      flow.requireCurrent();
      _editor = flow;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => TimewebProfileEditPage(
            flow: flow!,
            onEditLocation: _editGeography,
          ),
        ),
      );
      _editor = null;
      // Editor owns its save receipt; display obtains a new canonical full read
      // after any return, including cancel and unknown save confirmation.
      if (_current) {
        setState(() => _opening = false);
        await _reload();
      }
    } catch (_) {
      flow?.close();
      if (_current) {
        setState(
          () => _notice = 'Не удалось открыть профиль. Попробуйте ещё раз.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  Future<bool?> _editGeography(BuildContext editorContext) async {
    if (!_current || !editorContext.mounted) {
      return null;
    }
    _editor?.requireCurrent();
    TimewebGeographyFlow? flow;
    try {
      // Geography has its own original operation and current CAS revision.
      // A confirmed change closes the old editor before its stale revision can
      // be used; the existing return path obtains a fresh complete profile.
      final snapshot = await widget.runtime.readCurrentOwnProfile();
      if (!_current || !editorContext.mounted) {
        return null;
      }
      snapshot.requireCurrent();
      flow = await widget.runtime.openGeography(snapshot);
      if (!_current || !editorContext.mounted) {
        return null;
      }
      flow.requireCurrent();
      _geography = flow;
      final result = await Navigator.of(editorContext).push<bool>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebGeographyRoute),
          builder: (_) => TimewebGeographyPage(flow: flow!),
        ),
      );
      return _current ? result : null;
    } finally {
      flow?.close();
      if (identical(_geography, flow)) _geography = null;
    }
  }

  Future<void> _openPeople() async {
    if (!_current ||
        _loading ||
        _opening ||
        !widget.runtime.peopleEnabled ||
        _profile?.onboarding != TimewebOnboarding.search) {
      return;
    }
    if (widget.onOpenPeople != null) {
      widget.onOpenPeople!();
      return;
    }
    setState(() => _opening = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebPeopleRoute),
          builder: (_) => TimewebPeoplePageView(
            runtime: widget.runtime,
            initialOwnProfile: _profile,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _openChats() async {
    if (!_current || _loading || _opening || !widget.runtime.chatsEnabled) {
      return;
    }
    setState(() {
      _opening = true;
      _notice = null;
    });
    try {
      final page = await widget.runtime.readChats();
      if (!mounted || !_current) return;
      page.requireCurrent();
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebChatsRoute),
          builder: (_) =>
              TimewebChatsPage(runtime: widget.runtime, initialPage: page),
        ),
      );
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = 'Не удалось загрузить чаты. Проверьте подключение.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _profile = null;
    _editor?.close();
    _editor = null;
    _temperament?.close();
    _temperament = null;
    _geography?.close();
    _geography = null;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  String _text(String? value) =>
      value == null || value.isEmpty ? context.tr('Не указано') : value;

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final snapshot = current ? _profile : null;
    final profile = snapshot?.profile;
    final stage = snapshot?.onboarding;
    final initialRequired = current && _initialRequired;
    TimewebTemperamentFlow? temperament;
    if (current) {
      try {
        _temperament?.requireCurrent();
        temperament = _temperament;
      } catch (_) {
        /* Never render a stale or closed questionnaire lease. */
      }
    }
    return ClrsScaffold(
      key: const ValueKey('timeweb-current-own-profile'),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const ClrsLogo(size: 34),
        actions: [
          IconButton(
            key: const ValueKey('timeweb-profile-refresh'),
            tooltip: context.tr('Обновить'),
            onPressed: current && !_loading && !_opening ? _reload : null,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            key: const ValueKey('timeweb-profile-logout'),
            tooltip: context.tr('Выйти'),
            onPressed: current
                ? () async {
                    if (!_current) return;
                    await widget.runtime.session.logout();
                  }
                : null,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _portrait(profile),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (current && widget.runtime.profileEditorEnabled &&
                        (_initialPending || initialRequired))
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-open-initial-profile'),
                        onPressed: _loading || _opening ? null : _initialRegistration,
                        icon: const Icon(Icons.assignment_outlined),
                        label: Text(context.tr(_initialPending ? 'Проверить результат' : 'Регистрация')),
                      ),
                    if (profile != null && widget.runtime.profileEditorEnabled &&
                        _initialChecked && !_initialPending && !initialRequired)
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-open-profile-editor'),
                        onPressed: current && !_loading && !_opening
                            ? _edit
                            : null,
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(context.tr('Редактировать профиль')),
                      ),
                    if (temperament != null)
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-open-temperament'),
                        onPressed: current && !_loading && !_opening
                            ? _openTemperament
                            : null,
                        icon: const Icon(Icons.assignment_outlined),
                        label: Text(
                          context.tr(
                            temperament.needsCheck
                                ? 'Проверить результат'
                                : 'Пройти тест',
                          ),
                        ),
                      ),
                    if (widget.runtime.peopleEnabled &&
                        stage == TimewebOnboarding.search)
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-open-people'),
                        onPressed: current && !_loading && !_opening
                            ? _openPeople
                            : null,
                        icon: const Icon(Icons.people_outline),
                        label: Text(context.tr('Люди')),
                      ),
                    if (_adminAllowed && widget.runtime.adminUsersEnabled)
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-open-admin-users'),
                        onPressed: current && !_loading && !_opening
                            ? _openAdmin
                            : null,
                        icon: const Icon(Icons.admin_panel_settings_outlined),
                        label: Text(context.tr('Панель для админа')),
                      ),
                    if (widget.runtime.chatsEnabled)
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-open-chats'),
                        onPressed: current && !_loading && !_opening
                            ? _openChats
                            : null,
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: Text(context.tr('Чаты')),
                      ),
                  ],
                ),
                if (_loading || _opening)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(context.tr(_notice!)),
                  ),
                if (!current)
                  _section('Профиль', Text(context.tr('Сеанс завершён'))),
                if (current && _error)
                  _section(
                    'Профиль',
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr(
                            'Не удалось загрузить профиль. Проверьте соединение и повторите попытку.',
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('timeweb-profile-retry'),
                          onPressed: _reload,
                          child: Text(context.tr('Повторить')),
                        ),
                      ],
                    ),
                  ),
                if (current && snapshot != null && profile == null)
                  _section(
                    'Профиль',
                    Text(
                      "${context.tr('Анкета не создана')}. "
                      "${context.tr('Сервис пока недоступен. Попробуйте позднее.')}",
                    ),
                  ),
                if (profile != null && stage != TimewebOnboarding.search)
                  _section(
                    'Профиль',
                    Text(
                      stage == TimewebOnboarding.test
                          ? widget.runtime.temperamentEnabled
                                ? context.tr(
                                    'Пройти тест для определения группы',
                                  )
                                : "${context.tr('Тест ещё не завершён')}. "
                                      "${context.tr('Сервис пока недоступен. Попробуйте позднее.')}"
                          : "${context.tr('Анкета заполнена частично')}. "
                                "${context.tr('Сервис пока недоступен. Попробуйте позднее.')}",
                    ),
                  ),
                if (profile != null) ...[
                  _section('Обо мне', _facts(profile)),
                  _section('Интересы и увлечения', Text(_text(profile.hobbi))),
                  _section('О себе', Text(_text(profile.about))),
                ],
                const ClrsValuesFooter(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _portrait(TimewebCurrentProfile? profile) => Container(
    decoration: const BoxDecoration(
      color: Color(0x4431241D),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Color(0xED1D160F)],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          ),
          const Align(
            alignment: Alignment.centerRight,
            child: ClrsMotto(size: 18),
          ),
          const SizedBox(height: 32),
          if (_profile != null && widget.runtime.profilePhotosEnabled)
            TimewebProfilePhotosView(
              runtime: widget.runtime, targetUid: _profile!.uid,
            )
          else const Center(
            child: Icon(
              Icons.person_outline,
              size: 90,
              color: LrsTheme.peachLight,
            ),
          ),
          if (_current && _initialChecked && !_initialPending &&
              profile?.profileDetailsSaved == true && profile?.isRegistrationEnd == true &&
              widget.runtime.profilePhotosEnabled)
            TimewebPhotoAppendControl(
              key: ValueKey('own-photo-append:${_profile!.uid}:$_epoch'),
              runtime: widget.runtime, snapshot: _profile!, onReady: _reload,
            ),
          const SizedBox(height: 16),
          if (_profile == null || !widget.runtime.profilePhotosEnabled) Center(
            child: Text(
              context.tr('Фото профиля'),
              style: const TextStyle(color: LrsTheme.muted),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            profile == null ? context.tr('Профиль') : _text(profile.fullName),
            key: const ValueKey('timeweb-own-profile-name'),
            style: const TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w700,
              color: LrsTheme.text,
            ),
          ),
          if (profile?.primaryGroup != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  GroupRing(group: profile!.primaryGroup!, size: 24),
                  const SizedBox(width: 7),
                  Expanded(child: Text(profile.primaryGroup!)),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: ClrsPanel(
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

  Widget _facts(TimewebCurrentProfile profile) {
    final values = <(String, String)>[
      ('Возраст', profile.age?.toString() ?? context.tr('Не указано')),
      ('Рост', profile.rost?.toString() ?? context.tr('Не указано')),
      ('Пол', _text(profile.pol)),
      ('Статус', _text(profile.relationStatus)),
      (
        'Дети',
        profile.deti == null
            ? context.tr('Не указано')
            : context.tr(profile.deti! ? 'Есть' : 'Нет'),
      ),
      ('Страна', _text(profile.country)),
      ('Код страны', _text(profile.countryCode)),
      ('Регион', _text(profile.region)),
      ('Город', _text(profile.city)),
      ('Язык', _text(profile.languageCode)),
      ('Группа', _text(profile.primaryGroup)),
      ('Дополнительная группа', _text(profile.secondaryGroup)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final value in values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr(value.$1),
                  style: const TextStyle(fontSize: 12, color: LrsTheme.muted),
                ),
                Text(value.$2),
              ],
            ),
          ),
      ],
    );
  }
}
