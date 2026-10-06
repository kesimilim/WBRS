import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';

const timewebAdminUsersRoute = '/timeweb/admin/users';

/// One current, server-authorized page. Private values and cursor stay in RAM;
/// changing the prefix clears the previous page before the explicit next read.
class TimewebAdminUsersPage extends StatefulWidget {
  const TimewebAdminUsersPage({
    super.key,
    required this.runtime,
    this.onAccessDenied,
  });
  final TimewebAppRuntime runtime;
  final VoidCallback? onAccessDenied;
  @override
  State<TimewebAdminUsersPage> createState() => _TimewebAdminUsersPageState();
}

class _TimewebAdminUsersPageState extends State<TimewebAdminUsersPage> {
  final _query = TextEditingController();
  StreamSubscription<AppSessionState>? _subscription;
  late final int _epoch;
  TimewebAdminUsersResult? _page;
  TimewebAdminUsersRequest? _request;
  TimewebAdminUsersCursor? _retryCursor;
  bool _loading = false, _error = false, _denied = false, _invalidated = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _subscription = widget.runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    unawaited(_load());
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
      _page?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _generation++;
    _page = null;
    _request = null;
    _retryCursor = null;
    _query.clear();
    _loading = false;
    _error = false;
    _denied = false;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  void _changed(String _) {
    if (!_current || _loading || _denied) return;
    setState(() {
      _generation++;
      _page = null;
      _request = null;
      _retryCursor = null;
      _error = false;
    });
  }

  Future<void> _load({bool next = false, bool retry = false}) async {
    if (!_current ||
        _loading ||
        _denied ||
        !TimewebAdminUsersRequest.acceptsQuery(_query.text)) {
      return;
    }
    final request = (next || retry)
        ? _request
        : TimewebAdminUsersRequest(query: _query.text);
    final cursor = next
        ? _page?.nextCursor
        : retry
        ? _retryCursor
        : null;
    if (request == null || next && cursor == null) return;
    final generation = ++_generation;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _loading = true;
      _error = false;
      _page = null;
      _request = request;
      _retryCursor = cursor;
    });
    try {
      final page = await widget.runtime.readAdminUsers(request, cursor: cursor);
      if (!_current || generation != _generation) return;
      page.requireCurrent();
      setState(() {
        _page = page;
        _retryCursor = null;
      });
    } on TimewebAdminAccessDenied {
      if (_current && generation == _generation) {
        setState(() {
          _denied = true;
          _page = null;
          _request = null;
          _retryCursor = null;
          _query.clear();
        });
        widget.onAccessDenied?.call();
      }
    } catch (_) {
      if (_current && generation == _generation) setState(() => _error = true);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _page = null;
    _request = null;
    _retryCursor = null;
    _query.dispose();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Widget _field(String label, String? value) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(
      '${context.tr(label)}: ${value ?? context.tr('Не указано')}',
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
    ),
  );

  Widget _user(TimewebAdminUser user) => Padding(
    key: ValueKey('timeweb-admin-user-${user.uid}'),
    padding: const EdgeInsets.only(bottom: 12),
    child: ClrsPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'UID: ${user.uid}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          _field('Имя', user.fullName),
          _field('Электронная почта', user.email),
          _field('Возраст', user.age?.toString()),
          _field(
            'Статус',
            context.tr(switch (user.lifecycle) {
              'active' => 'Активен',
              'blocked' => 'Аккаунт заблокирован',
              _ => 'Удаленный пользователь',
            }),
          ),
          if (user.disabled) Text(context.tr('Аккаунт заблокирован')),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final page = current ? _page : null;
    final enabled =
        current && !_loading && !_denied && widget.runtime.adminUsersEnabled;
    return ClrsScaffold(
      key: const ValueKey('timeweb-admin-users'),
      appBar: AppBar(
        title: const ClrsLogo(size: 34),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              sliver: SliverList.list(
                children: [
                  Text(
                    context.tr('Пользователи'),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('timeweb-admin-query'),
                    controller: _query,
                    enabled: enabled,
                    maxLength: 100,
                    onChanged: _changed,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => unawaited(_load()),
                    decoration: InputDecoration(
                      labelText: context.tr('Поиск'),
                      hintText: '${context.tr('Имя')} / ${context.tr('Email')}',
                      helperMaxLines: 2,
                      helperText: _query.text.trim().isEmpty
                          ? null
                          : context.tr(
                              '{current} / минимум {minimum} символов',
                              args: {
                                'current': _query.text.trim().runes.length,
                                'minimum': 2,
                              },
                            ),
                    ),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-admin-search'),
                        onPressed:
                            enabled &&
                                TimewebAdminUsersRequest.acceptsQuery(
                                  _query.text,
                                )
                            ? () => unawaited(_load())
                            : null,
                        icon: const Icon(Icons.search),
                        label: Text(context.tr('Поиск')),
                      ),
                      ElevatedButton.icon(
                        key: const ValueKey('timeweb-admin-refresh'),
                        onPressed:
                            enabled &&
                                TimewebAdminUsersRequest.acceptsQuery(
                                  _query.text,
                                )
                            ? () => unawaited(_load())
                            : null,
                        icon: const Icon(Icons.refresh),
                        label: Text(context.tr('Обновить')),
                      ),
                    ],
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (!current) Text(context.tr('Сеанс завершён')),
                  if (_denied)
                    ClrsPanel(child: Text(context.tr('Доступ запрещён'))),
                  if (_error)
                    ClrsPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tr('Не удалось загрузить пользователей'),
                          ),
                          TextButton(
                            key: const ValueKey('timeweb-admin-retry'),
                            onPressed: enabled
                                ? () => unawaited(_load(retry: true))
                                : null,
                            child: Text(context.tr('Повторить')),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (page != null &&
                      page.items.isEmpty &&
                      page.nextCursor == null)
                    ClrsPanel(
                      child: Text(
                        context.tr('По выбранным параметрам пока никого нет'),
                      ),
                    ),
                ],
              ),
            ),
            if (page != null)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: page.items.length,
                  itemBuilder: (_, index) => _user(page.items[index]),
                ),
              ),
            if (page?.nextCursor != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  child: ElevatedButton(
                    key: const ValueKey('timeweb-admin-next'),
                    onPressed: enabled
                        ? () => unawaited(_load(next: true))
                        : null,
                    child: Text(context.tr('Загрузить ещё')),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
