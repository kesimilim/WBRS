import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/shared/lrs_theme.dart';

/// Route callbacks belong to the same owner as the original native shell.
/// This binding neither creates a Home nor grants access to an unfinished user.
class TimewebNavigationBinding {
  TimewebNavigationBinding({
    required this.lease,
    required this.selectedIndex,
    required Set<int> availableIndices,
    required this.onSelect,
    this.showBar = true,
  }) : availableIndices = Set.unmodifiable(availableIndices);

  final AppSessionLease lease;
  final int selectedIndex;
  final Set<int> availableIndices;
  final Future<void> Function(BuildContext context, int index) onSelect;
  final bool showBar;

  TimewebNavigationBinding forRoute({int? selectedIndex}) =>
      TimewebNavigationBinding(
        lease: lease,
        selectedIndex: selectedIndex ?? this.selectedIndex,
        availableIndices: availableIndices,
        onSelect: onSelect,
      );
}

class TimewebNavigationScope extends InheritedWidget {
  const TimewebNavigationScope({
    super.key,
    required this.navigation,
    required super.child,
  });

  final TimewebNavigationBinding navigation;

  static TimewebNavigationBinding? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TimewebNavigationScope>()
      ?.navigation;

  /// Capture before push: a new Navigator route does not inherit page scopes.
  static Widget wrap(BuildContext context, Widget child, {int? selectedIndex}) {
    final navigation = maybeOf(context);
    return navigation == null
        ? child
        : TimewebNavigationScope(
            navigation: navigation.forRoute(selectedIndex: selectedIndex),
            child: child,
          );
  }

  @override
  bool updateShouldNotify(TimewebNavigationScope oldWidget) =>
      !identical(navigation, oldWidget.navigation);
}

/// Same five positions and glass treatment as CLRS MyBottomNavigationBar.
/// Only the owning shell can perform a transition; no Firebase/global fallback.
class TimewebBottomNavigationBar extends StatefulWidget {
  const TimewebBottomNavigationBar({super.key});

  @override
  State<TimewebBottomNavigationBar> createState() =>
      _TimewebBottomNavigationBarState();
}

class _TimewebBottomNavigationBarState
    extends State<TimewebBottomNavigationBar> {
  bool _navigating = false;

  Future<void> _select(TimewebNavigationBinding navigation, int index) async {
    if (_navigating ||
        !navigation.lease.isCurrent ||
        !navigation.availableIndices.contains(index) ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    setState(() => _navigating = true);
    try {
      navigation.lease.requireCurrent();
      await navigation.onSelect(context, index);
    } catch (_) {
      if (mounted && navigation.lease.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Не удалось открыть раздел. Проверьте подключение.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final navigation = TimewebNavigationScope.maybeOf(context);
    if (navigation == null ||
        !navigation.showBar ||
        !navigation.lease.isCurrent) {
      return const SizedBox.shrink();
    }
    const labels = ['Лента', 'Поиск', 'Чаты', 'Встречи', 'Профиль'];
    const icons = [
      Icons.home_outlined,
      Icons.search,
      Icons.chat_bubble_outline,
      Icons.event_outlined,
      Icons.person_outline,
    ];
    const activeIcons = [
      Icons.home,
      Icons.search,
      Icons.chat_bubble,
      Icons.event,
      Icons.person,
    ];
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xD92A1E12),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: const Color(0x66E7B092), width: .8),
        ),
        child: BottomNavigationBar(
          key: const ValueKey('timeweb-route-navigation'),
          currentIndex: navigation.selectedIndex.clamp(0, 4),
          onTap: _navigating
              ? null
              : (index) => unawaited(_select(navigation, index)),
          backgroundColor: Colors.transparent,
          selectedItemColor: LrsTheme.peach,
          unselectedItemColor: LrsTheme.muted,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          selectedFontSize: 11,
          unselectedFontSize: 11,
          items: [
            for (var i = 0; i < labels.length; i++)
              BottomNavigationBarItem(
                icon: Semantics(
                  enabled: navigation.availableIndices.contains(i),
                  child: Icon(
                    icons[i],
                    key: ValueKey('timeweb-route-tab-$i'),
                    color: navigation.availableIndices.contains(i)
                        ? null
                        : LrsTheme.muted.withValues(alpha: .45),
                  ),
                ),
                activeIcon: Icon(activeIcons[i]),
                label: context.tr(labels[i]),
              ),
          ],
        ),
      ),
    );
  }
}
