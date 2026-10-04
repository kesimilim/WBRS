import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/timeweb_auth_lifecycle.dart';
import 'lrs_theme.dart';

/// Original CLRS fields. No phone/account/profile cache supplies their values.
/// A new account requires an explicit sign-in after confirmed registration.
class TimewebRegistrationForm extends StatefulWidget {
  const TimewebRegistrationForm({
    super.key,
    required this.client,
    required this.onLogin,
  });
  final TimewebAuthLifecycleClient? client;
  final ValueChanged<String> onLogin;
  @override
  State<TimewebRegistrationForm> createState() =>
      _TimewebRegistrationFormState();
}

class _TimewebRegistrationFormState extends State<TimewebRegistrationForm> {
  final _form = GlobalKey<FormState>();
  final _nickname = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  TimewebLifecycleScope? _scope;
  TimewebLifecycleOperation? _operation;
  bool _busy = false,
      _unknown = false,
      _completed = false,
      _hidden = true,
      _stale = false;
  String? _notice;
  bool get _current =>
      mounted &&
      !_stale &&
      (_scope?.isCurrent ?? false) &&
      ModalRoute.of(context)?.isCurrent != false;
  bool get _locked => _busy || _operation != null || _completed || _stale;

  @override
  void initState() {
    super.initState();
    try {
      _scope = widget.client?.beginScope();
    } catch (_) {
      // A native configuration failure must not create a Firebase account.
    }
    if (_scope == null) _notice = 'Сервис пока недоступен. Попробуйте позднее.';
  }

  @override
  void dispose() {
    _stale = true;
    if (widget.client != null) unawaited(widget.client!.close());
    _nickname.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String _id() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _submit() async {
    if (_busy || _completed) return;
    if (!_current) {
      setState(() {
        _stale = true;
        _notice = 'Сеанс изменился. Откройте этот экран заново.';
      });
      return;
    }
    if (!_unknown && !(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final client = widget.client!;
      _operation ??= client.register(
        scope: _scope!,
        operationId: _id(),
        email: _email.text,
        nickname: _nickname.text,
        password: _password.text,
      );
      final result = _unknown
          ? await client.lookup(_operation!)
          : await client.submit(_operation!);
      if (!_current) return;
      setState(() {
        _unknown = result.state == TimewebLifecycleState.unknown;
        if (result.state == TimewebLifecycleState.completed) {
          _completed = true;
          _password.clear();
          _notice = 'Аккаунт создан. Войдите, чтобы заполнить анкету.';
        } else if (_unknown) {
          _notice =
              'Результат пока не подтверждён. Нажмите «Проверить регистрацию».';
        } else {
          _operation =
              null; // Only a definitive refusal authorizes a new attempt.
          _notice = result.state == TimewebLifecycleState.refused
              ? 'Этот email недоступен для регистрации. Войдите или используйте другой email.'
              : result.error == TimewebLifecycleError.rateLimited
              ? 'Слишком много попыток. Попробуйте позднее.'
              : result.error == TimewebLifecycleError.invalidRequest
              ? 'Проверьте введённые данные.'
              : 'Сервис пока недоступен. Попробуйте позднее.';
        }
      });
    } catch (_) {
      if (!_current) return;
      setState(() {
        _unknown = _operation != null;
        _notice = _unknown
            ? 'Результат пока не подтверждён. Нажмите «Проверить регистрацию».'
            : 'Проверьте введённые данные.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          if (!(_scope?.isCurrent ?? false)) {
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
        children: [
          Text(
            context.tr('Создайте профиль для серьёзных отношений'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const ValueKey('timeweb-nickname'),
            controller: _nickname,
            readOnly: _locked,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.nickname],
            decoration: InputDecoration(
              labelText: context.tr('Никнэйм'),
              prefixIcon: const Icon(Icons.person_outline, size: 21),
            ),
            validator: (value) => (value ?? '').trim().isEmpty
                ? context.tr('Имя не может быть пустым')
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('timeweb-email'),
            controller: _email,
            readOnly: _locked,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(
              labelText: context.tr('Email'),
              prefixIcon: const Icon(Icons.mail_outline, size: 21),
            ),
            validator: (value) =>
                RegExp(
                  r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                ).hasMatch((value ?? '').trim())
                ? null
                : context.tr('Введите корректный email'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('timeweb-password'),
            controller: _password,
            readOnly: _locked,
            obscureText: _hidden,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
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
            key: const ValueKey('timeweb-registration-submit'),
            onPressed: _busy || _completed || _scope == null || _stale
                ? null
                : _submit,
            child: Text(
              context.tr(
                _unknown ? 'Проверить регистрацию' : 'Зарегистрироваться',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                context.tr('Уже есть аккаунт?'),
                style: const TextStyle(fontSize: 13),
              ),
              TextButton(
                key: const ValueKey('timeweb-registration-login'),
                onPressed: _busy || _unknown || _stale
                    ? null
                    : () => widget.onLogin(_email.text),
                child: Text(context.tr('Войти')),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
