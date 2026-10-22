import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_contacts_flow.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chat_avatar.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/timeweb_person_page.dart';

/// Private paged lists. Neither owner UID nor archived profile data is supplied
/// by the screen. An uncertain action remains receipt-only across reopening.
class TimewebContactsPageView extends StatefulWidget {
  const TimewebContactsPageView({
    super.key,
    required this.runtime,
    this.guests = false,
    this.targetUid,
    this.targetName,
  });
  final TimewebAppRuntime runtime;
  final bool guests;
  final String? targetUid, targetName;
  @override
  State<TimewebContactsPageView> createState() => _ContactsState();
}

class _ContactsState extends State<TimewebContactsPageView> {
  StreamSubscription<AppSessionState>? _states;
  late final int _epoch;
  late String _kind;
  TimewebContactsFlow? _flow;
  TimewebContactsPage? _page;
  TimewebContactReceipt? _relation;
  final _items = <TimewebContactItem>[];
  bool _loading = false, _busy = false, _failed = false;
  String? _notice;
  int _generation = 0;
  bool get _current =>
      mounted &&
      widget.runtime.session.state.authenticated &&
      widget.runtime.session.state.epoch == _epoch;

  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _kind = widget.guests ? 'guests' : 'friends';
    _states = widget.runtime.session.states.listen((_) {
      if (!_current && mounted) {
        _generation++;
        _items.clear();
        _page = null;
        _relation = null;
        _flow?.close();
        _flow = null;
        setState(() {});
      }
    });
    unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    if (!_current || _loading || _busy) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      if (!widget.guests && _flow?.needsCheck == false) {
        _flow?.close();
        _flow = null;
      }
      if (!widget.guests && _flow == null) {
        final flow = await widget.runtime.openContacts();
        if (!_current || generation != _generation) {
          flow.close();
          return;
        }
        _flow = flow;
      }
      if (widget.targetUid != null) {
        final relation = await widget.runtime.readRelationship(
          widget.targetUid!,
        );
        if (!_current || generation != _generation) return;
        _relation = relation;
      } else {
        final page = await widget.runtime.readContacts(
          _kind,
          after: more ? _page : null,
        );
        if (!_current || generation != _generation) return;
        if (!more) _items.clear();
        final old = _items.map((p) => p.uid).toSet();
        _items.addAll(page.items.where((p) => old.add(p.uid)));
        _page = page;
      }
    } catch (_) {
      if (_current && generation == _generation) _failed = true;
    } finally {
      if (mounted && generation == _generation)
        setState(() => _loading = false);
    }
  }

  Future<void> _act(String? action, String? uid, int revision) async {
    if (!_current || _busy || _flow == null) return;
    final flow = _flow!;
    if (action != null && flow.needsCheck) return;
    if (action == 'remove') {
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.tr('Удалить из друзей')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.tr('Отмена')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.tr('Удалить')),
            ),
          ],
        ),
      );
      if (approved != true || !_current) return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final result =
          await (action == null
                  ? flow.check()
                  : flow.submit(
                      TimewebContactAction(
                        kind: action,
                        targetUid: uid!,
                        expectedRevision: revision,
                      ),
                    ))
              .timeout(flow.observationTimeout);
      if (!_current) return;
      _notice = switch (result) {
        TimewebContactsOutcome.confirmed => null,
        TimewebContactsOutcome.rejected =>
          'Не удалось сохранить изменения. Попробуйте ещё раз.',
        TimewebContactsOutcome.unknown =>
          'Результат пока не подтверждён. Нажмите «Проверить результат».',
      };
    } catch (_) {
      if (_current)
        _notice =
            'Результат пока не подтверждён. Нажмите «Проверить результат».';
    } finally {
      if (_current) {
        setState(() => _busy = false);
        if (!flow.needsCheck) await _load();
      }
    }
  }

  Widget _actions(String uid, String status, int revision) {
    final enabled =
        _current && !_busy && !_loading && _flow != null && !_flow!.needsCheck;
    Widget action(String kind, String title, IconData icon) =>
        OutlinedButton.icon(
          key: ValueKey('contact-$kind-$uid'),
          onPressed: enabled ? () => _act(kind, uid, revision) : null,
          icon: Icon(icon, size: 17),
          label: Text(context.tr(title)),
        );
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        if (status == 'none')
          action('send', 'Добавить в друзья', Icons.person_add_alt_1_outlined),
        if (status == 'incoming') ...[
          action('accept', 'Принять', Icons.check),
          action('decline', 'Отклонить', Icons.close),
        ],
        if (status == 'outgoing')
          action('cancel', 'Отозвать заявку', Icons.close),
        if (status == 'friends')
          action('remove', 'Удалить из друзей', Icons.person_remove_outlined),
      ],
    );
  }

  Widget _row(TimewebContactItem item) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ClrsPanel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      TimewebPersonPage(runtime: widget.runtime, uid: item.uid),
                ),
              );
              if (_current) await _load();
            },
            child: Row(
              children: [
                TimewebChatAvatar(
                  runtime: widget.runtime,
                  uid: item.uid,
                  primaryGroup: item.group,
                  readGroup: false,
                  photoIdentity: (_epoch, item.uid),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.fullName.isEmpty
                            ? context.tr('Пользователь')
                            : item.fullName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (item.city?.isNotEmpty == true)
                        Text(
                          item.city!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: LrsTheme.muted),
                        ),
                      if (widget.guests && item.updatedAt != null)
                        Text(
                          MaterialLocalizations.of(context).formatShortDate(
                            DateTime.parse(item.updatedAt!).toLocal(),
                          ),
                          style: const TextStyle(color: LrsTheme.muted),
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          ),
          if (!widget.guests) _actions(item.uid, item.status, item.revision),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pending = _current && _flow?.needsCheck == true;
    final title = context.tr(widget.guests ? 'Гости' : 'Друзья');
    return ClrsScaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontFamily: 'Lato')),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: context.tr('Обновить'),
            onPressed: _current && !_loading && !_busy ? _load : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_current
          ? Center(child: Text(context.tr('Сеанс завершён. Войдите снова.')))
          : Column(
              children: [
                if (!widget.guests && widget.targetUid == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        for (final tab in const {
                          'friends': 'Друзья',
                          'incoming': 'Входящие',
                          'outgoing': 'Исходящие',
                        }.entries)
                          ChoiceChip(
                            key: ValueKey('contacts-tab-${tab.key}'),
                            selected: _kind == tab.key,
                            label: Text(context.tr(tab.value)),
                            onSelected: _loading || _busy
                                ? null
                                : (_) {
                                    if (_kind == tab.key) return;
                                    setState(() {
                                      _kind = tab.key;
                                      _items.clear();
                                      _page = null;
                                      _notice = null;
                                    });
                                    unawaited(_load());
                                  },
                          ),
                      ],
                    ),
                  ),
                if (_loading || _busy) const LinearProgressIndicator(),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                          sliver: SliverList.list(
                            children: [
                              const ClrsBrandHeader(),
                              if (_notice != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(context.tr(_notice!)),
                                ),
                              if (pending)
                                OutlinedButton.icon(
                                  key: const ValueKey('contacts-check'),
                                  onPressed: _busy
                                      ? null
                                      : () => _act(null, null, 0),
                                  icon: const Icon(Icons.refresh),
                                  label: Text(
                                    context.tr('Проверить результат'),
                                  ),
                                ),
                              if (_failed)
                                ClrsPanel(
                                  child: Column(
                                    children: [
                                      Text(
                                        context.tr(
                                          'Не удалось загрузить список.',
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: _loading || _busy
                                            ? null
                                            : () => _load(),
                                        child: Text(context.tr('Повторить')),
                                      ),
                                    ],
                                  ),
                                ),
                              if (widget.targetUid != null && _relation != null)
                                ClrsPanel(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.targetName ??
                                            context.tr('Пользователь'),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 12),
                                      _actions(
                                        _relation!.targetUid,
                                        _relation!.status,
                                        _relation!.revision,
                                      ),
                                    ],
                                  ),
                                ),
                              if (widget.targetUid == null &&
                                  _items.isEmpty &&
                                  !_loading &&
                                  !_failed)
                                ClrsPanel(
                                  child: Text(
                                    context.tr(
                                      widget.guests
                                          ? 'Пока на вашей странице не было гостей.'
                                          : _kind == 'incoming'
                                          ? 'Новых заявок нет'
                                          : _kind == 'outgoing'
                                          ? 'Отправленных заявок нет'
                                          : 'Список друзей пока пуст',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          sliver: SliverList.builder(
                            itemCount: _items.length,
                            itemBuilder: (_, i) => _row(_items[i]),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.all(14),
                          sliver: SliverList.list(
                            children: [
                              if (_page?.hasMore == true)
                                TextButton(
                                  key: const ValueKey('contacts-more'),
                                  onPressed: _loading || _busy
                                      ? null
                                      : () => _load(more: true),
                                  child: Text(context.tr('Загрузить ещё')),
                                ),
                              const ClrsValuesFooter(compact: true),
                            ],
                          ),
                        ),
                      ],
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
    _states?.cancel();
    _flow?.close();
    super.dispose();
  }
}
