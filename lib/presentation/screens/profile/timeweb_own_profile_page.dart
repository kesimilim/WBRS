import 'dart:async';

import 'package:wbrs/presentation/screens/admin/timeweb_admin_users_page.dart';
import 'package:wbrs/presentation/screens/shop/timeweb_gifts_page.dart';
import 'package:wbrs/presentation/screens/settings/timeweb_account_page.dart';

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
import 'package:wbrs/shared/profile_composition.dart'
    show ProfilePortrait, ProfileSection, relationshipLabel;
import 'package:wbrs/core/utils/compatibility.dart';
import 'package:wbrs/presentation/screens/feed/timeweb_feed_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/presentation/screens/notifications_center/timeweb_notifications_page.dart';
import 'timeweb_own_profile_gallery.dart';
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
  TimewebGiftInventory? _gifts;
  bool _giftsError = false;

  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _profile = widget.initialProfile;
    _error = widget.initialError;
    unawaited(_prepareInitialAndTemperament());
    unawaited(_probeAdmin());
    unawaited(_loadGifts());
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
    _gifts = null;
    _giftsError = false;
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

  Future<void> _openSettings() async {
    if (!_current || _loading || _opening) return;
    setState(() => _opening = true);
    final lease = widget.runtime.session.captureLease();
    TimewebAccountAction? action;
    try {
      action = await Navigator.of(context).push<TimewebAccountAction>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebAccountRoute),
          builder: (_) => TimewebAccountPage(
            runtime: widget.runtime,
            lease: lease,
            canEditProfile:
                widget.runtime.profileEditorEnabled &&
                _profile?.profileExists == true &&
                _initialChecked &&
                !_initialPending &&
                !_initialRequired,
          ),
        ),
      );
    } finally {
      if (_current) setState(() => _opening = false);
    }
    if (_current && action == TimewebAccountAction.editProfile) await _edit();
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
    if (!widget.runtime.profileEditorEnabled) {
      await _prepareTemperament();
      return;
    }
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
      if (_current && generation == _generation)
        setState(() => _initialPending = false);
    } finally {
      flow?.close();
    }
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
    if (!_current ||
        _loading ||
        _opening ||
        !widget.runtime.profileEditorEnabled)
      return;
    setState(() {
      _opening = true;
      _notice = null;
    });
    try {
      final snapshot = await widget.runtime.readCurrentOwnProfile();
      if (!_current || !mounted) return;
      snapshot.requireCurrent();
      final profile = snapshot.profile;
      final eligible =
          profile?.profileDetailsSaved == false &&
          profile?.isRegistrationEnd == false &&
          snapshot.onboarding != TimewebOnboarding.search;
      if (!eligible && !_initialPending) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebInitialProfileRoute),
          builder: (_) => TimewebInitialProfilePage(
            runtime: widget.runtime,
            initialProfile: snapshot,
          ),
        ),
      );
      if (_current) {
        setState(() => _opening = false);
        await _reload();
      }
    } catch (_) {
      if (_current)
        setState(() => _notice = 'Сервис пока недоступен. Попробуйте позднее.');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  bool get _initialRequired {
    final profile = _profile?.profile;
    return profile?.profileDetailsSaved == false &&
        profile?.isRegistrationEnd == false &&
        _profile?.onboarding != TimewebOnboarding.search;
  }

  Future<void> _edit() async {
    if (!_current ||
        !_initialChecked ||
        _initialPending ||
        _initialRequired ||
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
      final photo = widget.runtime.profilePhotosEnabled
          ? TimewebOwnProfileGallery(
              runtime: widget.runtime,
              targetUid: _profile!.uid,
              showGallery: false,
              photoFit: BoxFit.cover,
              abovePhotos: const SizedBox.shrink(),
              belowPhotos: const [],
              portraitBuilder: (image) => ClipOval(
                child: SizedBox(width: 100, height: 100, child: image),
              ),
            )
          : null;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => TimewebProfileEditPage(
            flow: flow!,
            onEditLocation: _editGeography,
            photo: photo,
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

  Future<void> _openGifts() async {
    if (!_current || _loading || _opening || !widget.runtime.giftsEnabled) {
      return;
    }
    setState(() => _opening = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => TimewebGiftsPage(runtime: widget.runtime),
        ),
      );
    } finally {
      if (_current) {
        setState(() => _opening = false);
        unawaited(_loadGifts());
      }
    }
  }

  Future<void> _loadGifts() async {
    if (!_current || !widget.runtime.giftsEnabled) return;
    try {
      final gifts = await widget.runtime.readGifts();
      if (!_current) return;
      gifts.requireCurrent();
      setState(() {
        _gifts = gifts;
        _giftsError = false;
      });
    } catch (_) {
      if (_current) {
        setState(() {
          _gifts = null;
          _giftsError = true;
        });
      }
    }
  }

  Future<void> _openNativePage(Widget page) async {
    if (!_current || _loading || _opening) return;
    setState(() => _opening = true);
    try {
      await Navigator.of(
        context,
      ).push<void>(MaterialPageRoute(builder: (_) => page));
    } finally {
      if (_current) setState(() => _opening = false);
    }
  }

  Future<void> _openWall() async {
    if (!_current ||
        _loading ||
        _opening ||
        !widget.runtime.socialEnabled ||
        _profile == null) {
      return;
    }
    await _openNativePage(
      TimewebFeedPage(runtime: widget.runtime, wallUid: _profile!.uid),
    );
  }

  Future<void> _openNotifications() async {
    if (!_current ||
        _loading ||
        _opening ||
        !widget.runtime.ownProfileEnabled) {
      return;
    }
    final lease = widget.runtime.session.captureLease();
    await _openNativePage(
      TimewebNotificationsPage(runtime: widget.runtime, lease: lease),
    );
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
    final initialRequired = current && _initialRequired;
    final canEdit =
        current &&
        profile != null &&
        widget.runtime.profileEditorEnabled &&
        _initialChecked &&
        !_initialPending &&
        !initialRequired;
    final available = current && !_loading && !_opening;
    TimewebTemperamentFlow? temperament;
    if (current) {
      try {
        _temperament?.requireCurrent();
        temperament = _temperament;
      } catch (_) {
        /* A closed handle cannot render protected state. */
      }
    }

    final above = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _quickAction(Icons.visibility_outlined, 'Гости', null),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _quickAction(
                Icons.edit_outlined,
                'Редактировать',
                canEdit && available ? _edit : null,
                key: const ValueKey('timeweb-open-profile-editor'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _quickAction(
                Icons.people_outline,
                'Люди',
                available &&
                        widget.runtime.peopleEnabled &&
                        snapshot?.onboarding == TimewebOnboarding.search
                    ? _openPeople
                    : null,
                key: const ValueKey('timeweb-open-people'),
              ),
            ),
          ],
        ),
        if (canEdit)
          Align(
            child: TextButton(
              onPressed: available ? _edit : null,
              child: Text(context.tr('Изменить статус')),
            ),
          ),
        if (profile != null && _male(profile.pol))
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 16,
                  color: LrsTheme.peachLight,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    context.tr(
                      'Главное фото: костюм, форма или классическая рубашка.',
                    ),
                    style: const TextStyle(
                      color: LrsTheme.peachLight,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Onboarding and an unresolved original stay reachable, without turning
        // the profile into a second navigation hub or bypassing its photo gate.
        if (current &&
            widget.runtime.profileEditorEnabled &&
            (_initialPending || initialRequired))
          ProfileSection(
            title: context.tr('Профиль'),
            child: ElevatedButton.icon(
              key: const ValueKey('timeweb-open-initial-profile'),
              onPressed: available ? _initialRegistration : null,
              icon: const Icon(Icons.assignment_outlined),
              label: Text(
                context.tr(
                  _initialPending ? 'Проверить результат' : 'Регистрация',
                ),
              ),
            ),
          ),
        if (temperament != null)
          ProfileSection(
            title: context.tr('Профиль'),
            child: ElevatedButton.icon(
              key: const ValueKey('timeweb-open-temperament'),
              onPressed: available ? _openTemperament : null,
              icon: const Icon(Icons.assignment_outlined),
              label: Text(
                context.tr(
                  temperament.needsCheck
                      ? 'Проверить результат'
                      : 'Пройти тест',
                ),
              ),
            ),
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
          ProfileSection(
            title: context.tr('Профиль'),
            child: Text(context.tr('Сеанс завершён')),
          ),
        if (current && _error)
          ProfileSection(
            title: context.tr('Профиль'),
            child: Column(
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
          ProfileSection(
            title: context.tr('Профиль'),
            child: Text(context.tr('Анкета не создана')),
          ),
      ],
    );
    final below = <Widget>[
      if (profile != null) ...[
        ProfileSection(
          title: context.tr('Подарки'),
          action: widget.runtime.giftsEnabled
              ? TextButton(
                  key: const ValueKey('timeweb-open-gifts'),
                  onPressed: available ? _openGifts : null,
                  child: Text(context.tr('Магазин подарков')),
                )
              : null,
          child: _receivedGifts(),
        ),
        ProfileSection(
          title: context.tr('Обо мне'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _facts(profile),
              if (canEdit) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: ElevatedButton.icon(
                      key: const ValueKey('profile-bottom-edit'),
                      onPressed: available ? _edit : null,
                      icon: const Icon(Icons.edit_outlined),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LrsTheme.actionGlass,
                        foregroundColor: LrsTheme.text,
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                      ),
                      label: Text(context.tr('Редактировать профиль')),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (profile.primaryGroup != null)
          ProfileSection(
            title: context.tr('Вам подходят'),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final group in getListOfGroup(profile.primaryGroup!))
                  GroupBadge(group: group, size: 24, showLabel: true),
              ],
            ),
          ),
        if (_gifts != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              '${context.tr('Ваш баланс: ')}${context.l10n.number(_gifts!.balanceAg)}',
            ),
          ),
        if (widget.runtime.socialEnabled)
          ProfileSection(
            title: context.tr('Стена'),
            child: OutlinedButton.icon(
              key: const ValueKey('timeweb-open-wall'),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: Text(context.tr('Стена')),
              onPressed: available ? _openWall : null,
            ),
          ),
      ],
      const ClrsValuesFooter(),
    ];
    final append =
        canEdit &&
            profile.profileDetailsSaved == true &&
            profile.isRegistrationEnd == true &&
            widget.runtime.profilePhotosEnabled
        ? TimewebPhotoAppendControl(
            key: ValueKey('own-photo-append:${snapshot!.uid}:$_epoch'),
            runtime: widget.runtime,
            snapshot: snapshot,
            onReady: _reload,
          )
        : null;
    return ClrsScaffold(
      key: const ValueKey('timeweb-current-own-profile'),
      extendBodyBehindAppBar: true,
      drawer: _drawer(available),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const ClrsLogo(size: 34),
        actions: [
          IconButton(
            key: const ValueKey('timeweb-profile-refresh'),
            tooltip: context.tr('Обновить'),
            onPressed: available ? _reload : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (profile != null && widget.runtime.profilePhotosEnabled)
            TimewebOwnProfileGallery(
              key: ValueKey(
                'own-gallery:${snapshot!.uid}:${profile.updatedAt}:$_epoch',
              ),
              runtime: widget.runtime,
              targetUid: snapshot.uid,
              portraitBuilder: (photo) => _portrait(profile, photo),
              abovePhotos: above,
              belowPhotos: below,
              appendControl: append,
            )
          else ...[
            _portrait(
              profile,
              const ColoredBox(
                color: Color(0x4431241D),
                child: Icon(
                  Icons.person_outline,
                  size: 90,
                  color: LrsTheme.peachLight,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [above, ...below],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _drawer(bool available) => Drawer(
    backgroundColor: const Color(0xED302110),
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const ClrsBrandHeader(),
          if (widget.runtime.ownProfileEnabled)
            _menu(
              'Уведомления',
              Icons.notifications_outlined,
              available ? _openNotifications : null,
            ),
          _menu(
            'Настройки',
            Icons.settings_outlined,
            available ? _openSettings : null,
            key: const ValueKey('timeweb-profile-settings'),
          ),
          if (widget.runtime.chatsEnabled)
            _menu(
              'Чаты',
              Icons.chat_bubble_outline,
              available ? _openChats : null,
              key: const ValueKey('timeweb-open-chats'),
            ),
          if (widget.runtime.meetingsEnabled)
            _menu(
              'Встречи',
              Icons.groups_outlined,
              available
                  ? () => _openNativePage(
                      TimewebMeetingsPageView(runtime: widget.runtime),
                    )
                  : null,
            ),
          if (widget.runtime.giftsEnabled)
            _menu(
              'Магазин подарков',
              Icons.card_giftcard,
              available ? _openGifts : null,
            ),
          if (_adminAllowed && widget.runtime.adminUsersEnabled)
            _menu(
              'Панель для админа',
              Icons.admin_panel_settings_outlined,
              available ? _openAdmin : null,
              key: const ValueKey('timeweb-open-admin-users'),
            ),
          const Divider(),
          _menu(
            'Выйти',
            Icons.logout,
            available
                ? () async {
                    if (_current) await widget.runtime.session.logout();
                  }
                : null,
            key: const ValueKey('timeweb-profile-logout'),
          ),
        ],
      ),
    ),
  );

  Widget _menu(String label, IconData icon, VoidCallback? action, {Key? key}) =>
      ListTile(
        key: key,
        leading: Icon(icon),
        title: Text(context.tr(label)),
        onTap: action == null
            ? null
            : () {
                if (!_current) return;
                Navigator.of(context).pop();
                action();
              },
      );

  Widget _quickAction(
    IconData icon,
    String label,
    VoidCallback? action, {
    Key? key,
  }) => Semantics(
    button: true,
    enabled: action != null,
    label: context.tr(label),
    child: InkWell(
      key: key,
      onTap: action,
      borderRadius: BorderRadius.circular(14),
      child: ClrsPanel(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 54),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: action == null ? LrsTheme.muted : LrsTheme.peachLight,
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    context.tr(label),
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  bool _male(String? gender) {
    final value = (gender ?? '').trim().toLowerCase();
    return value.startsWith('м') || const {'male', 'man', 'm'}.contains(value);
  }

  String _location(TimewebCurrentProfile profile) => [
    if (profile.country?.isNotEmpty == true) context.tr(profile.country!),
    if (profile.region?.isNotEmpty == true) profile.region!,
  ].join(' · ');

  Widget _portrait(TimewebCurrentProfile? profile, Widget photo) =>
      ProfilePortrait(
        key: const ValueKey('timeweb-own-profile-name'),
        photo: '',
        photoContent: photo,
        name: profile == null ? context.tr('Профиль') : _text(profile.fullName),
        age: profile?.age?.toString() ?? '',
        group: profile?.primaryGroup ?? '',
        own: true,
        gender: profile?.pol ?? '',
        location: profile == null ? '' : _location(profile),
        online: null,
        status: relationshipLabel(profile?.relationStatus),
      );

  Widget _receivedGifts() {
    final gifts = _gifts;
    if (gifts == null) {
      return _giftsError
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.tr('Сервис пока недоступен. Попробуйте позднее.')),
                TextButton(
                  onPressed: _loadGifts,
                  child: Text(context.tr('Повторить')),
                ),
              ],
            )
          : const LinearProgressIndicator();
    }
    final catalog = {for (final item in gifts.catalog) item.id: item};
    final received = gifts.inventory
        .where(
          (item) =>
              item.receivedQuantity > 0 && catalog.containsKey(item.giftId),
        )
        .toList();
    if (received.isEmpty) {
      return Text(
        context.tr('Пока нет подарков'),
        style: const TextStyle(color: LrsTheme.muted),
      );
    }
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: received.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = received[index];
          return SizedBox(
            width: 88,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.asset(
                    catalog[item.giftId]!.assetPath,
                    fit: BoxFit.contain,
                  ),
                ),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x995E3C2A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(context.l10n.number(item.receivedQuantity)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _facts(TimewebCurrentProfile profile) {
    final values = <(IconData, String, String)>[
      (
        Icons.calendar_today_outlined,
        'Возраст',
        profile.age?.toString() ?? context.tr('Не указано'),
      ),
      (
        Icons.height,
        'Рост',
        profile.rost?.toString() ?? context.tr('Не указано'),
      ),
      (
        Icons.location_on_outlined,
        'Регион',
        _location(profile).isEmpty
            ? context.tr('Не указано')
            : _location(profile),
      ),
      (Icons.people_outline, 'Группа', _text(profile.primaryGroup)),
      (
        Icons.family_restroom_outlined,
        'Дети',
        profile.deti == null
            ? context.tr('Не указано')
            : context.tr(profile.deti! ? 'Есть' : 'Нет'),
      ),
      (Icons.favorite_border, 'Интересы и увлечения', _text(profile.hobbi)),
      (Icons.chat_bubble_outline, 'О себе', _text(profile.about)),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns =
            box.maxWidth >= 290 &&
                MediaQuery.textScalerOf(context).scale(14) <= 20
            ? 2
            : 1;
        final width = (box.maxWidth - (columns - 1) * 16) / columns;
        return Wrap(
          spacing: 16,
          runSpacing: 2,
          children: [
            for (final entry in values)
              SizedBox(
                width: width,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(entry.$1, size: 19),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.tr(entry.$2),
                              style: const TextStyle(
                                fontSize: 11,
                                color: LrsTheme.peachLight,
                              ),
                            ),
                            const SizedBox(height: 3),
                            entry.$2 == 'Группа' && profile.primaryGroup != null
                                ? GroupNameText(group: profile.primaryGroup!)
                                : Text(
                                    entry.$3,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.3,
                                    ),
                                  ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
