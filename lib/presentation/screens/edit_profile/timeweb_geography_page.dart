import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_geography_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/meeting_location_fields.dart';

const timewebGeographyRoute = '/timeweb/geography';

/// Standalone native seam over the approved local selectors. Its caller must
/// re-read the current own profile on confirmed return; no Firebase side effect.
class TimewebGeographyPage extends StatefulWidget {
  const TimewebGeographyPage({super.key, required this.flow});
  final TimewebGeographyFlow flow;
  @override
  State<TimewebGeographyPage> createState() => _TimewebGeographyPageState();
}

class _TimewebGeographyPageState extends State<TimewebGeographyPage> {
  final _fieldsNavigator = GlobalKey<NavigatorState>();
  final _formUpdates = ValueNotifier<int>(0);
  StreamSubscription<AppSessionState>? _subscription;
  String? _code, _region, _notice;
  bool _busy = false, _invalidated = false;
  void _update(VoidCallback action) {
    setState(action);
    _formUpdates.value++;
  }

  @override
  void initState() {
    super.initState();
    try {
      widget.flow.requireCurrent();
      _code = widget.flow.countryCode;
      _region = widget.flow.region;
      if (widget.flow.needsCheck) {
        _notice =
            'Результат пока не подтверждён. Нажмите «Проверить результат».';
      }
    } catch (_) {
      _invalidated = true;
    }
    _subscription = widget.flow.sessionStates.listen((_) {
      if (!_current) _invalidate();
    });
  }

  bool get _current {
    if (!mounted || _invalidated) return false;
    try {
      widget.flow.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _code = _region = _notice = null;
    _busy = false;
    widget.flow.close();
    _update(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      // Selectors push popups only in this page's nested Navigator. Removing
      // our own outer route disposes that navigator; no newer B route is popped.
      if (route != null && !route.isFirst) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _submit() async {
    if (!_current || _busy || widget.flow.requiresReload) return;
    final check = widget.flow.needsCheck;
    if (!check &&
        (_code == null ||
            _region == null ||
            !widget.flow.hasChanges(countryCode: _code!, region: _region!))) {
      return;
    }
    _update(() {
      _busy = true;
      _notice = null;
    });
    try {
      final original = check
          ? widget.flow.check()
          : widget.flow.save(countryCode: _code!, region: _region!);
      final result = await original.timeout(widget.flow.observationTimeout);
      if (!mounted || !_current || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      switch (result) {
        case TimewebGeographyOutcome.confirmed:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('Профиль сохранён'))),
          );
          Navigator.of(context).pop(true);
        case TimewebGeographyOutcome.rejected:
          _update(
            () =>
                _notice = 'Не удалось сохранить изменения. Попробуйте ещё раз.',
          );
        case TimewebGeographyOutcome.unknown:
          _update(
            () => _notice =
                'Результат пока не подтверждён. Нажмите «Проверить результат».',
          );
      }
    } catch (_) {
      if (_current) {
        _update(
          () => _notice = widget.flow.needsCheck
              ? 'Результат пока не подтверждён. Нажмите «Проверить результат».'
              : 'Не удалось сохранить изменения. Попробуйте ещё раз.',
        );
      }
    } finally {
      if (mounted) _update(() => _busy = false);
    }
  }

  @override
  void dispose() {
    widget.flow.close();
    _code = _region = _notice = null;
    unawaited(_subscription?.cancel());
    _formUpdates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClrsScaffold(
      key: const ValueKey('timeweb-geography'),
      appBar: AppBar(title: Text(context.tr('Редактировать профиль'))),
      body: NavigatorPopHandler<void>(
        onPopWithResult: (_) => _fieldsNavigator.currentState?.pop(),
        child: Navigator(
          key: _fieldsNavigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => AnimatedBuilder(
              animation: _formUpdates,
              builder: (_, __) => _form(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form() {
    final current = _current;
    final check = current && widget.flow.needsCheck;
    final reload = current && widget.flow.requiresReload;
    final controls = current && !_busy && !check && !reload;
    final changed =
        current &&
        _code != null &&
        _region != null &&
        widget.flow.hasChanges(countryCode: _code!, region: _region!);
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const Center(child: ClrsLogo(size: 34)),
        const SizedBox(height: 12),
        ClrsPanel(
          child: AbsorbPointer(
            key: const ValueKey('timeweb-geography-fields'),
            absorbing: !controls,
            child: Opacity(
              opacity: controls ? 1 : .55,
              child: MeetingLocationFields(
                key: ValueKey(
                  'timeweb-geography-${current ? 'current' : 'invalid'}',
                ),
                countryCode: current ? _code : null,
                region: current ? _region : null,
                onChanged: (country, region) {
                  if (_current &&
                      !_busy &&
                      !widget.flow.needsCheck &&
                      !widget.flow.requiresReload) {
                    _update(() {
                      _code = country?.code;
                      _region = region;
                    });
                  }
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (_busy) const LinearProgressIndicator(),
        if (!current) Text(context.tr('Сеанс завершён')),
        if (current && _notice != null) Text(context.tr(_notice!)),
        const SizedBox(height: 12),
        ElevatedButton(
          key: const ValueKey('timeweb-geography-save'),
          onPressed: current && !_busy && !reload && (check || changed)
              ? _submit
              : null,
          child: Text(context.tr(check ? 'Проверить результат' : 'Сохранить')),
        ),
        if (reload)
          TextButton(
            key: const ValueKey('timeweb-geography-reload'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.tr('Обновить')),
          ),
        const ClrsValuesFooter(),
      ],
    );
  }
}
