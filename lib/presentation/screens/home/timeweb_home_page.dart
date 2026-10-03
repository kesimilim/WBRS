import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/presentation/screens/list_of_users/timeweb_people_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/presentation/screens/notifications_center/timeweb_notifications_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';

enum _Section { feed, people, chats, meetings, profile }

/// Current native destinations share this one runtime. Hidden sections are
/// mounted only when selected; leaving disposes their RAM and retains journals.
class TimewebHomePage extends StatefulWidget {
  const TimewebHomePage({
    super.key,
    required this.runtime,
    required this.initialOwnProfile,
    this.nativeFeedBuilder,
  });
  final TimewebAppRuntime runtime;
  final TimewebCurrentOwnProfile initialOwnProfile;

  /// Reserved for a reviewed native feed service. No default/legacy feed route.
  final Widget Function(TimewebAppRuntime runtime)? nativeFeedBuilder;

  @override
  State<TimewebHomePage> createState() => _TimewebHomePageState();
}

class _TimewebHomePageState extends State<TimewebHomePage> {
  StreamSubscription<AppSessionState>? _states;
  late final TimewebAppRuntime _runtime;
  late final int _epoch;
  String? _ownerUid;
  _Section _selected = _Section.people;
  Widget? _page;
  bool _busy = false, _invalidated = false;
  int _generation = 0;

  List<_Section> get _sections => [
    if (widget.nativeFeedBuilder != null) _Section.feed,
    _Section.people,
    if (widget.runtime.chatsEnabled) _Section.chats,
    if (widget.runtime.meetingsEnabled) _Section.meetings,
    _Section.profile,
  ];

  bool get _current {
    if (!mounted ||
        _invalidated ||
        !identical(widget.runtime, _runtime) ||
        !widget.runtime.session.state.authenticated ||
        widget.runtime.session.state.identity?.uid != _ownerUid ||
        widget.runtime.session.state.epoch != _epoch) {
      return false;
    }
    try {
      widget.initialOwnProfile.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _runtime = widget.runtime;
    _epoch = widget.runtime.session.state.epoch;
    try {
      widget.initialOwnProfile.requireCurrent();
      _ownerUid = widget.initialOwnProfile.uid;
    } catch (_) {
      _invalidated = true;
    }
    if (!_invalidated && widget.nativeFeedBuilder != null) {
      _selected = _Section.feed;
      _page = widget.nativeFeedBuilder!(widget.runtime);
    } else {
      _page = TimewebPeoplePageView(
        runtime: widget.runtime,
        initialOwnProfile: widget.initialOwnProfile,
        showSectionLinks: false,
      );
    }
    _states = widget.runtime.session.states.listen((_) {
      if (!_current) {
        _invalidated = true;
        _generation++;
        if (mounted) {
          setState(() {
            _page = null;
            _busy = false;
          });
        }
      }
    });
  }

  Future<void> _select(_Section section) async {
    if (!_current ||
        _busy ||
        section == _selected ||
        !_sections.contains(section)) {
      return;
    }
    final generation = ++_generation;
    setState(() => _busy = true);
    try {
      Widget page;
      switch (section) {
        case _Section.feed:
          page = widget.nativeFeedBuilder!(widget.runtime);
        case _Section.people:
          final own = await widget.runtime.readCurrentOwnProfile();
          if (!_current || generation != _generation) return;
          own.requireCurrent();
          page = TimewebPeoplePageView(
            runtime: widget.runtime,
            initialOwnProfile: own,
            showSectionLinks: false,
          );
        case _Section.chats:
          final chats = await widget.runtime.readChats();
          if (!_current || generation != _generation) return;
          chats.requireCurrent();
          page = TimewebChatsPage(runtime: widget.runtime, initialPage: chats);
        case _Section.meetings:
          page = TimewebMeetingsPageView(runtime: widget.runtime);
        case _Section.profile:
          final own = await widget.runtime.readCurrentOwnProfile();
          if (!_current || generation != _generation) return;
          own.requireCurrent();
          page = TimewebOwnProfilePage(
            runtime: widget.runtime,
            initialProfile: own,
            onOpenPeople: () => unawaited(_select(_Section.people)),
          );
      }
      if (!_current || generation != _generation) return;
      setState(() {
        _selected = section;
        _page = page;
      });
    } catch (_) {
      if (mounted && _current && generation == _generation) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Не удалось открыть раздел. Проверьте подключение.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _notifications() async {
    if (!_current || _busy) return;
    final lease = widget.runtime.session.captureLease();
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TimewebNotificationsPage(runtime: widget.runtime, lease: lease)));
    if (lease.isCurrent && mounted) setState(() {});
  }

  @override
  void dispose() {
    _invalidated = true;
    _generation++;
    _page = null;
    unawaited(_states?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return ClrsScaffold(
        body: Center(child: Text(context.tr('Сеанс завершён'))),
      );
    }
    final sections = _sections;
    return Scaffold(
      key: const ValueKey('timeweb-native-home'),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: _busy,
              child: KeyedSubtree(
                key: ValueKey('native-home:$_epoch:${_selected.name}'),
                child: _page!,
              ),
            ),
          ),
          Positioned(top: 0, left: 0, right: 0, child: SafeArea(bottom: false,
            child: Align(alignment: Alignment.topCenter, child: IconButton(
              key: const ValueKey('timeweb-home-notifications'), tooltip: context.tr('Уведомления'),
              onPressed: _busy ? null : () => unawaited(_notifications()),
              style: IconButton.styleFrom(backgroundColor: const Color(0xAD302110), foregroundColor: LrsTheme.peach),
              icon: const Icon(Icons.notifications_none))))),
          if (_busy)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                key: ValueKey('timeweb-home-loading'),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xD92A1E12),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: const Color(0x66E7B092), width: .8),
          ),
          child: BottomNavigationBar(
            key: const ValueKey('timeweb-home-navigation'),
            currentIndex: sections
                .indexOf(_selected)
                .clamp(0, sections.length - 1),
            onTap: _busy
                ? null
                : (index) => unawaited(_select(sections[index])),
            backgroundColor: Colors.transparent,
            selectedItemColor: LrsTheme.peach,
            unselectedItemColor: LrsTheme.muted,
            type: BottomNavigationBarType.fixed,
            elevation: 0,
            selectedFontSize: 11,
            unselectedFontSize: 11,
            items: [
              for (final section in sections)
                BottomNavigationBarItem(
                  icon: Icon(switch (section) {
                    _Section.feed => Icons.home_outlined,
                    _Section.people => Icons.search,
                    _Section.chats => Icons.chat_bubble_outline,
                    _Section.meetings => Icons.event_outlined,
                    _Section.profile => Icons.person_outline,
                  }, key: ValueKey('timeweb-home-tab-${section.name}')),
                  label: context.tr(switch (section) {
                    _Section.feed => 'Лента',
                    _Section.people => 'Поиск',
                    _Section.chats => 'Чаты',
                    _Section.meetings => 'Встречи',
                    _Section.profile => 'Профиль',
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
