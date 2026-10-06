import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_temperament_flow.dart';

import 'red_group.dart';

const timewebTemperamentRoute = '/timeweb/temperament';

/// Uses the existing 80-question design and wording with a native-only submit
/// branch. The original Firebase completion path remains the default elsewhere.
class TimewebTemperamentPage extends StatefulWidget {
  const TimewebTemperamentPage({super.key, required this.flow});
  final TimewebTemperamentFlow flow;
  @override
  State<TimewebTemperamentPage> createState() => _TimewebTemperamentPageState();
}

class _TimewebTemperamentPageState extends State<TimewebTemperamentPage> {
  StreamSubscription<AppSessionState>? _subscription;
  bool _invalidated = false, _busy = false;
  String? _notice;
  @override
  void initState() {
    super.initState();
    try {
      widget.flow.requireCurrent();
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
    _notice = null;
    _busy = false;
    widget.flow.close();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _submit(List<bool> answers) async {
    if (!_current || _busy || widget.flow.requiresReload) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final original = widget.flow.needsCheck
          ? widget.flow.check()
          : widget.flow.submit(answers);
      final outcome = await original.timeout(widget.flow.observationTimeout);
      if (!mounted || !_current || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      switch (outcome) {
        case TimewebTemperamentOutcome.confirmed:
          // Receipt supplies the group. The parent obtains a fresh current full
          // profile on return; no Firebase SessionGate or local group hydration.
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(context.tr('Тест завершён'))));
          Navigator.of(context).pop(true);
        case TimewebTemperamentOutcome.rejected:
          setState(
            () => _notice =
                'Не удалось сохранить результат. Проверьте соединение и повторите попытку.',
          );
        case TimewebTemperamentOutcome.unknown:
          setState(
            () => _notice =
                'Результат пока не подтверждён. Нажмите «Проверить результат».',
          );
      }
    } on TimeoutException {
      if (_current) {
        setState(
          () => _notice =
              'Результат пока не подтверждён. Нажмите «Проверить результат».',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = widget.flow.needsCheck
              ? 'Результат пока не подтверждён. Нажмите «Проверить результат».'
              : 'Не удалось сохранить результат. Проверьте соединение и повторите попытку.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    widget.flow.close();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final pending = current && widget.flow.needsCheck;
    final reload = current && widget.flow.requiresReload;
    return FirstGroupRed(
      key: ValueKey('timeweb-temperament-${current ? 'current' : 'invalid'}'),
      onNativeSubmit: _submit,
      nativeInitialAnswers: current
          ? widget.flow.initialAnswers
          : List.filled(80, false),
      nativeControlsEnabled: current && !_busy && !pending && !reload,
      nativeSubmitEnabled: current && !_busy && !reload,
      nativeSubmitLabel: pending ? 'Проверить результат' : 'Завершить тест',
      nativeNotice: current ? _notice : 'Сеанс завершён',
      nativeFooter: Column(
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          if (reload)
            TextButton(
              key: const ValueKey('timeweb-temperament-reload'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.tr('Обновить')),
            ),
        ],
      ),
    );
  }
}
