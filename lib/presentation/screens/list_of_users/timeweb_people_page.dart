import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'show/timeweb_person_page.dart';

const timewebPeopleRoute = '/timeweb/people';

/// One bounded current page. Cursors/filters remain in this native owner only;
/// empty sparse pages advance exclusively through the visible next-page action.
class TimewebPeoplePageView extends StatefulWidget {
  const TimewebPeoplePageView({
    super.key,
    required this.runtime,
    this.initialOwnProfile,
    this.onSelected,
  });
  final TimewebAppRuntime runtime;
  final TimewebCurrentOwnProfile? initialOwnProfile;
  final ValueChanged<TimewebPublicPerson>? onSelected;
  @override
  State<TimewebPeoplePageView> createState() => _TimewebPeoplePageViewState();
}

class _TimewebPeoplePageViewState extends State<TimewebPeoplePageView> {
  final _fieldsNavigator = GlobalKey<NavigatorState>();
  StreamSubscription<AppSessionState>? _subscription;
  late final int _epoch;
  TimewebCurrentOwnProfile? _ownProfile;
  TimewebPeoplePage? _page;
  TimewebPeopleFilters? _filters;
  List<GeoCountry>? _countries;
  String? _countryCode, _region, _pol;
  RangeValues _ages = const RangeValues(18, 100);
  bool _compatible = false, _showFilters = false;
  bool _loading = false, _opening = false, _error = false, _invalidated = false;
  int _generation = 0, _pageNumber = 1;

  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _ownProfile = widget.initialOwnProfile;
    _subscription = widget.runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    unawaited(_prepare());
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
      _ownProfile?.requireCurrent();
      _page?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get _busy => _loading || _opening;
  String? get _group {
    final group = _ownProfile?.profile?.primaryGroup?.trim().toLowerCase();
    return group != null && TimewebPeopleFilters.acceptsGroup(group)
        ? group
        : null;
  }

  void _invalidate() {
    if (!mounted || _invalidated) {
      return;
    }
    _invalidated = true;
    _generation++;
    _ownProfile = null;
    _page = null;
    _filters = null;
    _countries = null;
    _countryCode = _region = _pol = null;
    _loading = _opening = _compatible = _showFilters = _error = false;
    setState(() {});
    // Dropdown routes live only in our nested navigator, disposed by rebuild.
    // Remove our own outer route; never pop a newer B route above it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _prepare() async {
    final generation = _generation;
    try {
      final countries = await GeoCatalog.load();
      final own = _ownProfile ?? await widget.runtime.readCurrentOwnProfile();
      if (!_current || generation != _generation) return;
      own.requireCurrent();
      setState(() {
        _countries = countries;
        _ownProfile = own;
      });
      await _load();
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() => _error = true);
      }
    }
  }

  Future<void> _load({bool next = false}) async {
    if (!_current || _busy) return;
    final continuation = next ? _page?.nextCursor : null;
    if (next && continuation == null) return;
    final generation = ++_generation;
    final previousFilters = _filters;
    setState(() {
      _loading = true;
      _error = false;
      if (!next) {
        _page = null;
        _filters = null;
        _pageNumber = 1;
      }
    });
    try {
      final filters = next
          ? previousFilters!
          : await TimewebPeopleFilters.fromCatalog(
              minAge: _ages.start.round(),
              maxAge: _ages.end.round(),
              countryCode: _countryCode,
              region: _region,
              pol: _pol,
              compatibleGroup: _compatible ? _group : null,
            );
      if (!_current || generation != _generation) return;
      final page = await widget.runtime.readPeople(
        filters,
        cursor: continuation,
      );
      if (!_current || generation != _generation) return;
      page.requireCurrent();
      setState(() {
        _filters = filters;
        _page = page;
        if (next) {
          _pageNumber++;
        }
      });
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

  Future<void> _openPerson(TimewebPublicPerson person) async {
    if (!_current || _busy) {
      return;
    }
    person.requireCurrent();
    if (widget.onSelected != null) {
      if (person.uid != widget.runtime.session.state.identity?.uid) widget.onSelected!(person);
      return;
    }
    final uid = person.uid;
    setState(() => _opening = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebPersonRoute),
          builder: (_) => TimewebPersonPage(runtime: widget.runtime, uid: uid),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _openOwnProfile() async {
    if (!_current || _busy) return;
    setState(() => _opening = true);
    try {
      final profile = await widget.runtime.readCurrentOwnProfile();
      if (!mounted || !_current) return;
      profile.requireCurrent();
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: timewebOwnProfileRoute),
          builder: (_) => TimewebOwnProfilePage(
            runtime: widget.runtime,
            initialProfile: profile,
            onOpenPeople: () => Navigator.of(context).pop(),
          ),
        ),
      );
      if (_current) {
        final fresh = await widget.runtime.readCurrentOwnProfile();
        if (_current) {
          fresh.requireCurrent();
          setState(() => _ownProfile = fresh);
        }
      }
    } catch (_) {
      if (_current) {
        setState(() => _error = true);
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _openChats() async {
    if (!_current || _busy || !widget.runtime.chatsEnabled) return;
    setState(() => _opening = true);
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
        setState(() => _error = true);
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
    _page = null;
    _ownProfile = null;
    _filters = null;
    _countries = null;
    _countryCode = _region = _pol = null;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    key: const ValueKey('timeweb-people-directory'),
    appBar: AppBar(
      title: const ClrsLogo(size: 33),
      actions: [
        IconButton(
          key: const ValueKey('timeweb-people-refresh'),
          tooltip: context.tr('Обновить'),
          onPressed: _current && !_busy ? () => _load() : null,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          key: const ValueKey('timeweb-people-logout'),
          tooltip: context.tr('Выйти'),
          onPressed: _current
              ? () async {
                  await widget.runtime.session.logout();
                }
              : null,
          icon: const Icon(Icons.logout),
        ),
      ],
    ),
    body: !_current
        ? Center(child: Text(context.tr('Сеанс завершён')))
        : NavigatorPopHandler<void>(
            onPopWithResult: (_) => _fieldsNavigator.currentState?.pop(),
            child: Navigator(
              key: _fieldsNavigator,
              pages: [MaterialPage<void>(child: _body())],
              onDidRemovePage: (_) {},
            ),
          ),
  );

  Widget _body() => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      final columns = (box.maxWidth / (120 * scale)).floor().clamp(1, 4);
      final rows = _page?.items ?? const <TimewebPublicPerson>[];
      return CustomScrollView(
        key: const ValueKey('timeweb-people-scroll'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    context.tr(widget.onSelected == null ? 'Люди' : 'Выберите получателя'),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: ClrsMotto(size: 16),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (widget.onSelected == null) ElevatedButton.icon(
                        key: const ValueKey('timeweb-people-own-profile'),
                        onPressed: _busy ? null : _openOwnProfile,
                        icon: const Icon(Icons.person_outline),
                        label: Text(context.tr('Профиль')),
                      ),
                      if (widget.onSelected == null && widget.runtime.chatsEnabled)
                        ElevatedButton.icon(
                          key: const ValueKey('timeweb-people-chats'),
                          onPressed: _busy ? null : _openChats,
                          icon: const Icon(Icons.chat_bubble_outline),
                          label: Text(context.tr('Чаты')),
                        ),
                      if (widget.onSelected == null && widget.runtime.meetingsEnabled)
                        ElevatedButton.icon(key: const ValueKey('timeweb-people-meetings'),
                          onPressed: _busy ? null : () => Navigator.of(context).push<void>(
                            MaterialPageRoute(settings: const RouteSettings(name: timewebMeetingsRoute),
                              builder: (_) => TimewebMeetingsPageView(runtime: widget.runtime))),
                          icon: const Icon(Icons.groups_outlined), label: Text(context.tr('Встречи'))),
                      TextButton.icon(
                        key: const ValueKey('timeweb-people-filters'),
                        onPressed: _busy
                            ? null
                            : () =>
                                  setState(() => _showFilters = !_showFilters),
                        icon: const Icon(Icons.tune),
                        label: Text(context.tr('Фильтры поиска')),
                      ),
                    ],
                  ),
                  if (_showFilters && _countries != null)
                    _filterFields(context),
                  if (_loading || _opening || _countries == null && !_error)
                    const LinearProgressIndicator(),
                  if (_error)
                    ClrsPanel(
                      child: Column(
                        children: [
                          Text(
                            context.tr('Не удалось загрузить пользователей'),
                          ),
                          TextButton(
                            key: const ValueKey('timeweb-people-retry'),
                            onPressed: _busy
                                ? null
                                : () =>
                                      _countries == null ? _prepare() : _load(),
                            child: Text(context.tr('Повторить')),
                          ),
                        ],
                      ),
                    ),
                  if (!_loading &&
                      !_error &&
                      _page != null &&
                      rows.isEmpty &&
                      _page?.nextCursor == null)
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        context.tr('По выбранным параметрам пока никого нет'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                mainAxisExtent: 106 + 100 * scale,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, index) => _card(rows[index]),
                childCount: rows.length,
              ),
            ),
          ),
          if (_page != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Text(
                      context.tr(
                        'Страница {number} · до 30 профилей',
                        args: {'number': _pageNumber},
                      ),
                    ),
                    if (_page?.nextCursor != null)
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-people-next'),
                        onPressed: _busy ? null : () => _load(next: true),
                        icon: const Icon(Icons.chevron_right),
                        label: Text(context.tr('Загрузить ещё')),
                      ),
                  ],
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 20)),
        ],
      );
    },
  );

  Widget _filterFields(BuildContext fieldsContext) {
    final country = GeoCatalog.byCode(_countries!, _countryCode);
    return ClrsPanel(
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Text(
            '${context.tr('Возраст')}: ${_ages.start.round()} – ${_ages.end.round()}',
          ),
          RangeSlider(
            key: const ValueKey('timeweb-people-ages'),
            values: _ages,
            min: 18,
            max: 100,
            divisions: 82,
            labels: RangeLabels(
              '${_ages.start.round()}',
              '${_ages.end.round()}',
            ),
            onChanged: _busy ? null : (ages) => setState(() => _ages = ages),
          ),
          DropdownButtonFormField<String>(
            key: const ValueKey('timeweb-people-country'),
            value: _countryCode,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.tr('Страна')),
            items: [
              DropdownMenuItem(
                value: null,
                child: Text(context.tr('Все страны')),
              ),
              for (final country in _countries!)
                DropdownMenuItem(
                  value: country.code,
                  child: Text(
                    context.tr(country.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (code) => setState(() {
                    _countryCode = code;
                    _region = null;
                  }),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('timeweb-people-region-$_countryCode'),
            value: _region,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.tr('Регион')),
            items: [
              DropdownMenuItem(
                value: null,
                child: Text(context.tr('Все регионы')),
              ),
              for (final region in country?.regions ?? <String>[])
                DropdownMenuItem(
                  value: region,
                  child: Text(
                    region,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy || country == null
                ? null
                : (region) => setState(() => _region = region),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: const ValueKey('timeweb-people-gender'),
            value: _pol,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.tr('Пол')),
            items: [
              for (final entry in const [
                (null, 'Любой'),
                ('м', 'Мужской'),
                ('ж', 'Женский'),
              ])
                DropdownMenuItem(
                  value: entry.$1,
                  child: Text(context.tr(entry.$2)),
                ),
            ],
            onChanged: _busy ? null : (pol) => setState(() => _pol = pol),
          ),
          SwitchListTile(
            key: const ValueKey('timeweb-people-compatible'),
            contentPadding: EdgeInsets.zero,
            title: Text(context.tr('Тип личности подходит вам')),
            value: _compatible,
            onChanged: _busy || _group == null
                ? null
                : (value) => setState(() => _compatible = value),
          ),
          ElevatedButton(
            key: const ValueKey('timeweb-people-apply'),
            onPressed: _busy ? null : () => _load(),
            child: Text(context.tr('Применить')),
          ),
        ],
      ),
    );
  }

  Widget _card(TimewebPublicPerson person) => Container(
    key: ValueKey('timeweb-person-card-${person.uid}'),
    decoration: BoxDecoration(
      color: const Color(0xCC302110),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x66E7B092), width: .8),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _busy ? null : () => _openPerson(person),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            GroupAvatar(url: '', group: person.primaryGroup ?? '', size: 66),
            const SizedBox(height: 8),
            Text(
              [
                person.fullName == null || person.fullName!.isEmpty
                    ? context.tr('Не указано')
                    : person.fullName,
                person.age,
              ].where((v) => v != null).join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              [
                person.country,
                person.region,
                person.city,
              ].where((v) => v != null && v.isNotEmpty).join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: LrsTheme.peachLight),
            ),
            const Spacer(),
            Text(
              context.tr('Фото профиля'),
              style: const TextStyle(fontSize: 10, color: LrsTheme.muted),
            ),
          ],
        ),
      ),
    ),
  );
}
