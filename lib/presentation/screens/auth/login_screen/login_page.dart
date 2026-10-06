import 'dart:async';

import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_lifecycle.dart';
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/shared/clrs_auth_shell.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/auth/session_gate.dart';
// ignore_for_file: use_build_context_synchronously

import 'package:wbrs/shared/password_reset_sheet.dart';

import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/auth/register_screen/registration_consent_page.dart';
import 'package:wbrs/service/auth_service.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.initialEmail, this.authService, this.nativeRuntime});
  final String? initialEmail;
  final AuthService? authService;
  final TimewebAppRuntime? nativeRuntime;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _isChecked = true;
  bool _rememberSelectionChanged = false;
  Future<void> _rememberSave = Future<void>.value();
  bool _isVisible = true;

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  late final AuthService authService;
  bool _authPending = false;
  late final bool _native;
  TimewebAppRuntime? _runtime;
  Future<AppSessionResult>? _nativeAttempt;
  int? _nativeEpoch;
  bool _nativeUnknown = false;
  bool get _nativeAvailable =>
      !_native ||
      (_runtime != null &&
          !_nativeUnknown &&
          _runtime!.session.state.phase != AppSessionPhase.stopped &&
          _runtime!.session.state.phase != AppSessionPhase.closed);
  String get _rememberKey => _native ? 'timeweb_remember_me' : 'remember_me';
  String get _emailKey => _native ? 'timeweb_email' : 'email';


  @override
  void initState() {
    super.initState();
    _native = widget.nativeRuntime != null || AppBackend.usesTimeweb;
    if (_native) {
      try {
        _runtime = widget.nativeRuntime ?? AppBackend.timewebRuntime;
      } catch (_) { /* A selected native route never falls back to Firebase. */ }
      _emailController.text = widget.initialEmail ?? '';
    } else {
      authService = widget.authService ?? AuthService();
      _authPending = authService.hasPendingAttempt;
      _emailController.text = widget.initialEmail ?? authService.pendingEmail ?? '';
    }
    _loadUserEmailPassword();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClrsAuthShell(
        busy: _isLoading,
        loginLayout: true,
        child: AutofillGroup(
            child: Form(
          key: _formKey,
          child: Column(children: [
            if (!_nativeAvailable)
              Text(context.tr('Сервис пока недоступен. Попробуйте позднее.')),
            TextFormField(
              controller: _emailController,
              readOnly: _authPending || _isLoading,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 36, minHeight: 34),
                  labelText: context.tr('Email'),
                  prefixIcon: const Icon(Icons.mail_outline, size: 18)),
              validator: (value) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                      .hasMatch((value ?? '').trim())
                  ? null
                  : context.tr('Введите корректный email'),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _passwordController,
              readOnly: _authPending || _isLoading,
              obscureText: _isVisible,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => login(),
              decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 36, minHeight: 34),
                  suffixIconConstraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                  labelText: context.tr('Пароль'),
                  prefixIcon: const Icon(Icons.lock_outline, size: 18),
                  suffixIcon: IconButton(
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact),
                      tooltip: context
                          .tr(_isVisible ? 'Показать пароль' : 'Скрыть пароль'),
                      onPressed: () => setState(() => _isVisible = !_isVisible),
                      icon: Icon(
                          _isVisible
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18))),
              validator: (value) => (value ?? '').length < 6
                  ? context.tr('Пароль должен содержать 6 символов')
                  : null,
            ),
            const SizedBox(height: 2),
            SizedBox(height: 34, child: Row(children: [
              Checkbox(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  value: _isChecked,
                  onChanged: _isLoading || _authPending
                      ? null
                      : (value) {
                          final remember = value ?? false;
                          setState(() {
                            _isChecked = remember;
                            _rememberSelectionChanged = true;
                          });
                          _rememberSave = _rememberSave
                              .then((_) => _handleRememberMe(remember));
                          _rememberSave.ignore();
                        }),
              Expanded(
                  child: Text(context.tr('Запомнить меня'),
                      style: const TextStyle(fontSize: 13))),
            ])),
            const SizedBox(height: 0),
            FractionallySizedBox(
                widthFactor: _authPending ? .77 : .48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0x3931241D),
                      foregroundColor: LrsTheme.text,
                      disabledBackgroundColor: LrsTheme.actionDisabled,
                      disabledForegroundColor: LrsTheme.muted,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      side: const BorderSide(color: LrsTheme.actionBorder),
                      shape: const StadiumBorder()),
                  onPressed: _isLoading || !_nativeAvailable ? null : login,
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                                child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                        context.tr(_authPending
                                            ? 'Проверить вход'
                                            : 'Вход'),
                                        maxLines: 1,
                                        textAlign: TextAlign.center))),
                            const SizedBox(width: 6),
                            const Icon(Icons.arrow_forward, size: 16),
                          ])),
                )),
            const SizedBox(height: 4),
            Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(context.tr('Нет аккаунта?'),
                      style: const TextStyle(fontSize: 13)),
                  TextButton(
                      style: TextButton.styleFrom(
                          minimumSize: const Size(0, 26),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(horizontal: 4)),
                      onPressed: _authPending || _isLoading || !_nativeAvailable
                          ? null
                          : () => nextScreen(
                              context, RegistrationConsentPage(nativeRuntime: _runtime)),
                      child: Text(context.tr('Регистрация'))),
                ]),
            TextButton(
              style: TextButton.styleFrom(
                  minimumSize: const Size(0, 26),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 4)),
              onPressed: _authPending || _isLoading || !_nativeAvailable
                  ? null
                  : () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      backgroundColor: LrsTheme.surfaceSoft,
                      builder: (_) => PasswordResetSheet(
                          timewebLifecycle: _native
                              ? _runtime!.createEmailLifecycleClient(TimewebLifecyclePurpose.passwordReset)
                              : null,
                          send: (email) => firebaseAuth.sendPasswordResetEmail(
                              email: email))),
              child: Text(context.tr('Забыли пароль?'),
                  style: const TextStyle(
                      fontSize: 12, decoration: TextDecoration.underline)),
            ),
          ]),
        )),
      );

  Future<void> login() async {
    if (_isLoading || !_nativeAvailable ||
        (!_authPending && !(_formKey.currentState?.validate() ?? false))) {
      return;
    }
    setState(() => _isLoading = true);
    try {
      await _rememberSave;
      await _handleRememberMe(_isChecked);
      if (!mounted || (_native && ModalRoute.of(context)?.isCurrent == false)) {
        return;
      }
      if (_native) {
        await _loginNative();
        return;
      }
      final code = await authService.loginWithUserNameAndPassword(
        _emailController.text,
        _passwordController.text,
      );
      if (!mounted) return;
      if (code == 'pending') {
        setState(() => _authPending = true);
        showSnackbar(
            context,
            LrsTheme.surface,
            context.tr(
                'Вход ещё выполняется. Нажмите «Проверить вход», чтобы дождаться этого же запроса.'));
      } else if (code == 'ok') {
        _authPending = false;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const SessionGate()),
          (_) => false,
        );
      } else {
        setState(() => _authPending = false);
        const friendly = {
          'user-not-found': 'Неверный email или пароль',
          'wrong-password': 'Неверный email или пароль',
          'invalid-credential': 'Неверный email или пароль',
          'invalid-email': 'Проверьте email',
          'user-disabled': 'Аккаунт заблокирован',
          'too-many-requests': 'Слишком много попыток. Попробуйте позднее',
          'network-request-failed': 'Нет соединения с сервером',
        };
        showSnackbar(
          context,
          LrsTheme.danger,
          context.tr(friendly[code] ?? 'Не удалось войти. Повторите попытку.'),
        );
      }
    } catch (_) {
      if (mounted) {
        showSnackbar(
          context,
          LrsTheme.danger,
          context.tr('Не удалось войти. Повторите попытку.'),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loginNative() async {
    final runtime = _runtime!;
    if (_nativeAttempt == null) {
      _nativeAttempt = runtime.login(
        email: _emailController.text,
        password: _passwordController.text,
      );
      _nativeEpoch = runtime.session.state.epoch;
    }
    AppSessionResult result;
    try {
      result = await _nativeAttempt!.timeout(runtime.session.waitTimeout);
    } on TimeoutException {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false ||
          runtime.session.state.epoch != _nativeEpoch) {
        return;
      }
      setState(() => _authPending = true);
      showSnackbar(context, LrsTheme.surface, context.tr(
          'Вход ещё выполняется. Нажмите «Проверить вход», чтобы дождаться этого же запроса.'));
      return;
    }
    if (!mounted ||
        ModalRoute.of(context)?.isCurrent == false ||
        runtime.session.state.epoch != _nativeEpoch) {
      return;
    }
    if (result.outcome == AppSessionOutcome.pending) {
      _nativeAttempt = result.settled;
      setState(() => _authPending = true);
      showSnackbar(
        context,
        LrsTheme.surface,
        context.tr(
          'Вход ещё выполняется. Нажмите «Проверить вход», чтобы дождаться этого же запроса.',
        ),
      );
      return;
    }
    _nativeAttempt = null;
    _authPending = false;
    if (result.confirmed && runtime.session.state.authenticated) {
      _passwordController.clear();
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => TimewebSessionGate(runtime: runtime)),
        (_) => false,
      );
      return;
    }
    if (result.outcome == AppSessionOutcome.remoteUnknown ||
        result.outcome == AppSessionOutcome.superseded) {
      // Login has no receipt endpoint. Never turn a lost ACK into another POST
      // or pretend that a local token read confirms the original remote result.
      _nativeUnknown = true;
      _passwordController.clear();
    }
    final message = switch (result.error) {
      AppSessionError.unauthorized => 'Неверный email или пароль',
      AppSessionError.invalidRequest => 'Проверьте введённые данные.',
      AppSessionError.network => 'Нет соединения с сервером',
      _ => 'Сервис пока недоступен. Попробуйте позднее.',
    };
    showSnackbar(context, LrsTheme.danger, context.tr(message));
  }

  Future<void> _handleRememberMe(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (_native) await _runtime!.setRemember(value);
    await prefs.setBool(_rememberKey, value);
    await prefs.remove('password');
    if (value) {
      await prefs.setString(_emailKey, _emailController.text.trim());
    } else {
      await prefs.remove(_emailKey);
    }
  }

  Future<void> _loadUserEmailPassword() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('password');
    if (!mounted) return;
    if (_rememberSelectionChanged) return;
    final remember = prefs.getBool(_rememberKey) ?? true;
    setState(() => _isChecked = remember);
    if (remember && _emailController.text.isEmpty) {
      _emailController.text = prefs.getString(_emailKey) ?? '';
    }
  }
}
