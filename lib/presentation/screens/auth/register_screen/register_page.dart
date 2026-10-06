import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/shared/clrs_auth_shell.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/app/pages/policy/soglashenie.dart';
import 'package:firebase_auth/firebase_auth.dart';

// ignore_for_file: use_build_context_synchronously

import 'package:wbrs/presentation/screens/auth/session_gate.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/auth/register_screen/registration_consent_page.dart';
import 'package:wbrs/app/pages/policy/confidecialnost.dart';
import 'package:wbrs/service/auth_service.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/timeweb_auth_lifecycle.dart';
import 'package:wbrs/shared/timeweb_email_lifecycle_form.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({
    super.key,
    this.authService,
    this.consentConfirmed = false,
    this.timewebLifecycle,
    this.nativeRuntime,
  });
  final AuthService? authService;
  final bool consentConfirmed;
  final TimewebAuthLifecycleClient? timewebLifecycle;
  final TimewebAppRuntime? nativeRuntime;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  bool _isLoading = false;
  bool _passwordHidden = true;
  final formKey = GlobalKey<FormState>();
  late final AuthService authService;
  bool _authPending = false;
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  late final bool _native;
  TimewebAuthLifecycleClient? _lifecycle;

  @override
  void initState() {
    super.initState();
    _native =
        widget.timewebLifecycle != null ||
        widget.nativeRuntime != null ||
        AppBackend.usesTimewebEmailLifecycle;
    if (widget.consentConfirmed) {
      if (_native) {
        try {
          _lifecycle =
              widget.timewebLifecycle ??
              widget.nativeRuntime?.createEmailLifecycleClient(
                TimewebLifecyclePurpose.registerEmail,
              ) ??
              AppBackend.createEmailLifecycleClient(
                TimewebLifecyclePurpose.registerEmail,
              );
        } catch (_) {
          /* Native configuration failure must not create a Firebase account. */
        }
      } else {
        authService = widget.authService ?? AuthService();
        _authPending = authService.hasPendingAttempt;
        _emailController.text = authService.pendingEmail ?? '';
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !widget.consentConfirmed
      ? RegistrationConsentPage(nativeRuntime: widget.nativeRuntime)
      : _native
      ? ClrsAuthShell(
          child: Column(
            children: [
              TimewebEmailLifecycleForm(
                client: _lifecycle,
                purpose: TimewebLifecyclePurpose.registerEmail,
              ),
              const SizedBox(height: 12),
              Text(
                context.tr('Документы приложения'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
              TextButton(
                onPressed: () => nextScreen(context, const Politica()),
                child: Text(
                  context.tr('Политика конфиденциальности'),
                  textAlign: TextAlign.center,
                ),
              ),
              TextButton(
                onPressed: () => nextScreen(context, const Rules()),
                child: Text(
                  context.tr('Пользовательское соглашение'),
                  textAlign: TextAlign.center,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.maybePop(context),
                child: Text(context.tr('Закрыть')),
              ),
            ],
          ),
        )
      : ClrsAuthShell(
          busy: _isLoading,
          child: AutofillGroup(
            child: Form(
              key: formKey,
              child: Column(
                children: [
                  Text(
                    context.tr('Создайте профиль для серьёзных отношений'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _nameController,
                    readOnly: _authPending || _isLoading,
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
                    controller: _emailController,
                    readOnly: _authPending || _isLoading,
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
                    controller: _passwordController,
                    readOnly: _authPending || _isLoading,
                    obscureText: _passwordHidden,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => register(),
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                      labelText: context.tr('Пароль'),
                      prefixIcon: const Icon(Icons.lock_outline, size: 21),
                      suffixIcon: IconButton(
                        tooltip: context.tr(
                          _passwordHidden ? 'Показать пароль' : 'Скрыть пароль',
                        ),
                        onPressed: () =>
                            setState(() => _passwordHidden = !_passwordHidden),
                        icon: Icon(
                          _passwordHidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 21,
                        ),
                      ),
                    ),
                    validator: (value) => (value ?? '').length < 6
                        ? context.tr('Пароль должен содержать 6 символов')
                        : null,
                  ),
                  const SizedBox(height: 18),
                  ElevatedButton(
                    onPressed: _isLoading ? null : register,
                    child: Text(
                      context.tr(
                        _authPending
                            ? 'Проверить регистрацию'
                            : 'Зарегистрироваться',
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.tr('Документы приложения'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                  TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => nextScreen(context, const Politica()),
                    child: Text(
                      context.tr('Политика конфиденциальности'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => nextScreen(context, const Rules()),
                    child: Text(
                      context.tr('Пользовательское соглашение'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        context.tr('Уже есть аккаунт?'),
                        style: const TextStyle(fontSize: 13),
                      ),
                      TextButton(
                        onPressed: _authPending || _isLoading
                            ? null
                            : () => nextScreenReplace(
                                context,
                                LoginPage(
                                  initialEmail: _emailController.text,
                                  nativeRuntime: widget.nativeRuntime,
                                ),
                              ),
                        child: Text(context.tr('Войти')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );

  Future<void> register() async {
    if (_native ||
        !widget.consentConfirmed ||
        _isLoading ||
        (!_authPending && !(formKey.currentState?.validate() ?? false))) {
      return;
    }
    setState(() => _isLoading = true);
    try {
      final confirmed = await authService.registerUserWithEmailAndPassword(
        _nameController.text,
        _emailController.text,
        _passwordController.text,
      );
      if (!mounted) return;
      if (!confirmed) {
        setState(() => _authPending = true);
        showSnackbar(
          context,
          LrsTheme.surface,
          context.tr(
            'Регистрация ещё выполняется. Нажмите «Проверить регистрацию», чтобы дождаться этого же запроса.',
          ),
        );
        return;
      }
      _authPending = false;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SessionGate()),
        (_) => false,
      );
    } on FirebaseAuthException catch (error) {
      if (mounted) setState(() => _authPending = false);
      const errors = {
        'email-already-in-use':
            'Этот email уже зарегистрирован. Войдите или восстановите пароль.',
        'weak-password': 'Пароль слишком простой.',
        'invalid-email': 'Проверьте email.',
        'network-request-failed': 'Нет соединения с сервером.',
      };
      if (mounted) {
        showSnackbar(
          context,
          LrsTheme.danger,
          context.tr(
            errors[error.code] ??
                'Не удалось зарегистрироваться. Повторите попытку.',
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _authPending = false);
      if (mounted) {
        showSnackbar(
          context,
          LrsTheme.danger,
          context.tr(
            'Не удалось завершить регистрацию. Попробуйте войти снова.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
