import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/timeweb_auth_lifecycle.dart';
import 'lrs_theme.dart';

/// Real native email lifecycle, using the existing auth form/theme. Ownership
/// of the dedicated client transfers to this screen: navigation/dispose closes
/// its runtime scope, never a protected auth session. No Firebase fallback.
class TimewebEmailLifecycleForm extends StatefulWidget {
  const TimewebEmailLifecycleForm({
    super.key,
    required this.client,
    required this.purpose,
  });
  final TimewebAuthLifecycleClient? client;
  final TimewebLifecyclePurpose purpose;
  @override
  State<TimewebEmailLifecycleForm> createState() =>
      _TimewebEmailLifecycleFormState();
}

class _TimewebEmailLifecycleFormState extends State<TimewebEmailLifecycleForm> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  TimewebLifecycleScope? _scope;
  TimewebLifecycleOperation? _request, _completion;
  String? _challenge, _notice;
  bool _busy = false, _unknown = false, _confirmed = false, _stale = false;
  bool _hidden = true;
  bool get _registration =>
      widget.purpose == TimewebLifecyclePurpose.registerEmail;

  @override
  void initState() {
    super.initState();
    try {
      _scope = widget.client?.beginScope();
    } catch (_) {
      /* Selected native branch fails closed. */
    }
    if (_scope == null) _notice = 'Сервис пока недоступен. Попробуйте позднее.';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scope != null &&
        !_stale &&
        ModalRoute.of(context)?.isCurrent == false) {
      _stale = true;
      _busy = false;
      _notice = 'Откройте этот экран заново, чтобы продолжить.';
      unawaited(widget.client!.close());
    }
  }

  @override
  void dispose() {
    _stale = true;
    if (widget.client != null) unawaited(widget.client!.close());
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _current =>
      mounted &&
      !_stale &&
      (_scope?.isCurrent ?? false) &&
      ModalRoute.of(context)?.isCurrent != false;
  String _id() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _submit() async {
    if (mounted && !_busy && !_current) {
      setState(() {
        _stale = true;
        _notice = 'Сеанс изменился. Откройте этот экран заново.';
      });
      return;
    }
    if (_busy ||
        _confirmed ||
        !_current ||
        (!_unknown && !(_form.currentState?.validate() ?? false))) {
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final client = widget.client!;
      final pending = _completion ?? _request;
      late final TimewebLifecycleResult result;
      if (_unknown && pending != null) {
        result = await client.lookup(pending);
      } else if (_challenge == null) {
        _request ??= client.request(
          scope: _scope!,
          purpose: widget.purpose,
          operationId: _id(),
          email: _email.text,
        ); // Keep original email bytes/case.
        result = await client.submit(_request!);
      } else {
        _completion ??= client.complete(
          scope: _scope!,
          purpose: widget.purpose,
          operationId: _id(),
          challengeId: _challenge!,
          code: _code.text,
          password: _password.text,
        ); // Never trim/store the password.
        result = await client.submit(_completion!);
      }
      if (!_current) return;
      final state = result.state;
      setState(() {
        _unknown = state == TimewebLifecycleState.unknown;
        if (state == TimewebLifecycleState.accepted) {
          _challenge = result.challengeId;
          _notice = _registration
              ? 'Если регистрация доступна для этого адреса, на почту придёт код подтверждения.'
              : 'Если для этого адреса есть аккаунт, на почту придёт код для сброса пароля.';
        } else if (state == TimewebLifecycleState.completed) {
          _confirmed = true;
          _password.clear();
          _code.clear();
          _notice = _registration
              ? 'Email подтверждён. Создание аккаунта завершено. Заполнение анкеты пока недоступно.'
              : 'Пароль изменён. Войдите с новым паролем.';
        } else if (_unknown) {
          _notice =
              'Результат пока не подтверждён. Нажмите «Проверить результат».';
        } else if (state == TimewebLifecycleState.refused) {
          _completion = null;
          _notice = 'Код не подтверждён. Проверьте код из письма.';
        } else {
          if (_challenge == null) {
            _request = null;
          } else {
            _completion = null;
          }
          _notice = result.error == TimewebLifecycleError.rateLimited
              ? 'Слишком много попыток. Попробуйте позднее.'
              : 'Сервис пока недоступен. Попробуйте позднее.';
        }
      });
    } on TimewebLifecycleException catch (error) {
      if (!_current) return;
      setState(() {
        // A bound, possibly started operation is never replaced on error.
        _unknown = (_completion ?? _request) != null;
        _notice =
            error.error == TimewebLifecycleError.invalidRequest && !_unknown
            ? 'Проверьте введённые данные.'
            : _unknown
            ? 'Результат пока не подтверждён. Нажмите «Проверить результат».'
            : 'Сервис пока недоступен. Попробуйте позднее.';
      });
    } catch (_) {
      if (!_current) return;
      setState(() {
        _unknown = (_completion ?? _request) != null;
        _notice = _unknown
            ? 'Результат пока не подтверждён. Нажмите «Проверить результат».'
            : 'Сервис пока недоступен. Попробуйте позднее.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          if (!_stale && !(_scope?.isCurrent ?? false)) {
            _stale = true;
            _notice = 'Сеанс изменился. Откройте этот экран заново.';
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AutofillGroup(
    child: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_registration) ...[
            Text(
              context.tr('Создайте профиль для серьёзных отношений'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 14),
          ],
          TextFormField(
            key: const ValueKey('timeweb-email'),
            controller: _email,
            readOnly: _request != null || _busy || _confirmed || _stale,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(
              labelText: context.tr('Email'),
              prefixIcon: const Icon(Icons.mail_outline, size: 21),
            ),
            validator: (value) =>
                RegExp(
                  r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                ).hasMatch(value?.trim() ?? '')
                ? null
                : context.tr('Введите корректный email'),
          ),
          if (_challenge != null && !_confirmed) ...[
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('timeweb-code'),
              controller: _code,
              readOnly: _completion != null || _busy || _stale,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: InputDecoration(
                labelText: context.tr('Код из письма'),
              ),
              validator: (value) => RegExp(r'^[0-9]{6}$').hasMatch(value ?? '')
                  ? null
                  : context.tr('Введите шестизначный код'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('timeweb-password'),
              controller: _password,
              readOnly: _completion != null || _busy || _stale,
              obscureText: _hidden,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: context.tr('Пароль'),
                prefixIcon: const Icon(Icons.lock_outline, size: 21),
                suffixIcon: IconButton(
                  tooltip: context.tr(
                    _hidden ? 'Показать пароль' : 'Скрыть пароль',
                  ),
                  onPressed: () => setState(() => _hidden = !_hidden),
                  icon: Icon(
                    _hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 21,
                  ),
                ),
              ),
              validator: (value) => (value ?? '').runes.length < 6
                  ? context.tr('Пароль должен содержать 6 символов')
                  : null,
            ),
          ],
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                context.tr(_notice!),
                style: const TextStyle(color: LrsTheme.peachLight),
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(),
            ),
          const SizedBox(height: 18),
          ElevatedButton(
            key: const ValueKey('timeweb-email-submit'),
            onPressed: _busy || _confirmed || _scope == null || _stale
                ? null
                : _submit,
            child: Text(
              context.tr(
                _unknown
                    ? 'Проверить результат'
                    : _challenge != null
                    ? _registration
                          ? 'Подтвердить email'
                          : 'Сбросить пароль'
                    : _registration
                    ? 'Получить код'
                    : 'Сбросить пароль',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
