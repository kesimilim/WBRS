import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

Future<void> openTimewebNotification(
  BuildContext context,
  TimewebAppRuntime runtime,
  TimewebNotification notification, {
  bool refresh = true,
}) async {
  final lease = runtime.session.captureLease();
  notification.requireCurrent();
  final item = refresh
      ? await runtime.readNotification(notification.id)
      : notification;
  lease.requireCurrent();
  item.requireCurrent();
  if (!context.mounted) return;
  switch (item.targetKind) {
    case 'chat':
      final flow = await runtime.openExistingChat(item.targetId!);
      try {
        lease.requireCurrent();
        item.requireCurrent();
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _NotificationTarget(
              runtime: runtime,
              lease: lease,
              builder: () => TimewebChatPage(flow: flow, runtime: runtime),
            ),
          ),
        );
      } finally {
        flow.close();
      }
    case 'meeting':
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _NotificationTarget(
            runtime: runtime,
            lease: lease,
            builder: () => TimewebMeetingsPageView(
              runtime: runtime,
              meetingId: item.targetId,
            ),
          ),
        ),
      );
    default:
      throw const TimewebNotificationUnavailable();
  }
}

class TimewebNotificationsPage extends StatefulWidget {
  const TimewebNotificationsPage({
    super.key,
    required this.runtime,
    this.lease,
  });
  final TimewebAppRuntime runtime;
  final AppSessionLease? lease;
  @override
  State<TimewebNotificationsPage> createState() =>
      _TimewebNotificationsPageState();
}

class _TimewebNotificationsPageState extends State<TimewebNotificationsPage> {
  late final AppSessionLease _lease;
  StreamSubscription<AppSessionState>? _states;
  List<TimewebNotification> _items = [];
  TimewebNotificationCursor? _cursor;
  bool _busy = false, _opening = false, _invalid = false, _error = false;
  String _filter = 'Все';
  int _generation = 0;
  bool get _current => mounted && !_invalid && _lease.isCurrent;
  @override
  void initState() {
    super.initState();
    _lease = widget.lease ?? widget.runtime.session.captureLease();
    _states = widget.runtime.session.states.listen((_) {
      if (!_lease.isCurrent) _invalidate();
    });
    unawaited(_load());
  }

  void _invalidate() {
    if (!mounted || _invalid) return;
    _invalid = true;
    _generation++;
    _items = [];
    _cursor = null;
    setState(() {});
    final route = ModalRoute.of(context), navigator = Navigator.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route != null && !route.isFirst && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  Future<void> _load({bool older = false}) async {
    if (!_current || _busy || older && _cursor == null) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = false;
    });
    try {
      final page = await widget.runtime.readNotifications(
        cursor: older ? _cursor : null,
      );
      _lease.requireCurrent();
      page.requireCurrent();
      if (!_current || generation != _generation) return;
      final items = [if (older) ..._items, ...page.items];
      final ids = <String>{};
      if (items.any((v) => !ids.add(v.id))) {
        throw StateError('Repeated notification page.');
      }
      setState(() {
        _items = items.length > 300 ? items.sublist(items.length - 300) : items;
        _cursor = page.nextCursor;
      });
    } catch (_) {
      if (_current && generation == _generation) setState(() => _error = true);
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _open(TimewebNotification item) async {
    if (!_current || _opening || _busy) return;
    setState(() => _opening = true);
    try {
      await openTimewebNotification(context, widget.runtime, item);
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('Материал удалён или больше недоступен.')),
          ),
        );
      }
    } finally {
      if (_current) setState(() => _opening = false);
    }
  }

  bool _matches(TimewebNotification item) => switch (_filter) {
    'Сообщения' => item.type == 'chat.message.created.v1',
    'Встречи' =>
      item.type == 'meeting' || item.type == 'meeting.message.created.v1',
    'Ответы' => const ['post_comment', 'comment_reply'].contains(item.type),
    'Реакции' => const ['post_like', 'comment_like'].contains(item.type),
    _ => true,
  };
  String _label(TimewebNotification item) => switch (item.type) {
    'chat.message.created.v1' => 'Сообщения',
    'meeting.message.created.v1' || 'meeting' => 'Встречи',
    'gift' => 'Подарки',
    'post_comment' || 'comment_reply' => 'Ответы',
    'post_like' || 'comment_like' => 'Реакции',
    'post' => 'Лента',
    _ => 'Уведомления',
  };
  @override
  void dispose() {
    _invalid = true;
    _generation++;
    _items = [];
    _cursor = null;
    unawaited(_states?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    key: const ValueKey('timeweb-notifications-page'),
    backgroundAsset: 'assets/final_design/family_right.png',
    appBar: AppBar(
      title: const ClrsLogo(size: 34),
      actions: [
        IconButton(
          key: const ValueKey('timeweb-notifications-refresh'),
          tooltip: context.tr('Обновить'),
          onPressed: _current && !_busy && !_opening ? () => _load() : null,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: !_current
        ? Center(child: Text(context.tr('Сеанс завершён')))
        : LayoutBuilder(
            builder: (context, box) {
              final scale = MediaQuery.textScalerOf(context).scale(1);
              final width = scale > 1.4 || box.maxWidth < 340
                  ? box.maxWidth
                  : box.maxWidth * .75;
              return Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          context.tr('Уведомления'),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final filter in const [
                            'Все',
                            'Сообщения',
                            'Встречи',
                            'Ответы',
                            'Реакции',
                          ])
                            ChoiceChip(
                              label: Text(context.tr(filter)),
                              selected: _filter == filter,
                              backgroundColor: const Color(0x66302110),
                              selectedColor: const Color(0xB06A4631),
                              side: const BorderSide(color: Color(0x66E7B092)),
                              visualDensity: VisualDensity.compact,
                              labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              onSelected: _busy || _opening
                                  ? null
                                  : (_) => setState(() => _filter = filter),
                            ),
                        ],
                      ),
                      if (_busy || _opening)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(
                            key: ValueKey('timeweb-notifications-busy'),
                          ),
                        ),
                      if (_error)
                        ClrsPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.tr('Уведомления временно недоступны.'),
                              ),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _load(
                                        older:
                                            _cursor != null && _items.isEmpty,
                                      ),
                                child: Text(context.tr('Повторить')),
                              ),
                            ],
                          ),
                        ),
                      if (!_busy &&
                          !_error &&
                          _items.isEmpty &&
                          _cursor == null)
                        ClrsPanel(
                          child: Text(
                            context.tr('Здесь появятся важные уведомления'),
                          ),
                        ),
                      for (final item in _items.where(_matches))
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: ClrsPanel(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: InkWell(
                              key: ValueKey('timeweb-notification:${item.id}'),
                              onTap:
                                  _busy || _opening || item.targetKind == null
                                  ? null
                                  : () => _open(item),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        item.targetKind == 'meeting'
                                            ? Icons.event_outlined
                                            : item.targetKind == 'chat'
                                            ? Icons.chat_bubble_outline
                                            : Icons.notifications_outlined,
                                        size: 24,
                                        color: LrsTheme.peach,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(context.tr(_label(item))),
                                      ),
                                      if (item.read == false)
                                        const Icon(
                                          Icons.circle,
                                          size: 8,
                                          color: LrsTheme.peach,
                                        ),
                                    ],
                                  ),
                                  if (item.createdAt != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 5),
                                      child: Text(
                                        MaterialLocalizations.of(
                                          context,
                                        ).formatMediumDate(
                                          DateTime.parse(
                                            item.createdAt!,
                                          ).toLocal(),
                                        ),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: LrsTheme.muted,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (_cursor != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: TextButton(
                            key: const ValueKey('timeweb-notifications-more'),
                            onPressed: _busy || _opening
                                ? null
                                : () => _load(older: true),
                            child: Text(context.tr('Загрузить ещё')),
                          ),
                        ),
                      const ClrsValuesFooter(compact: true),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

// This route belongs to its original lease even if B becomes active before the
// first build. Remove only this route; never pop a newer login/account route.
class _NotificationTarget extends StatefulWidget {
  const _NotificationTarget({
    required this.runtime,
    required this.lease,
    required this.builder,
  });
  final TimewebAppRuntime runtime;
  final AppSessionLease lease;
  final Widget Function() builder;
  @override
  State<_NotificationTarget> createState() => _NotificationTargetState();
}

class _NotificationTargetState extends State<_NotificationTarget> {
  StreamSubscription<AppSessionState>? _states;
  @override
  void initState() {
    super.initState();
    _states = widget.runtime.session.states.listen((_) {
      if (!widget.lease.isCurrent && mounted) {
        setState(() {});
        final route = ModalRoute.of(context), navigator = Navigator.of(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && route != null && route.isActive && !route.isFirst) {
            navigator.removeRoute(route);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_states?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.lease.isCurrent ? widget.builder() : const SizedBox.shrink();
}
