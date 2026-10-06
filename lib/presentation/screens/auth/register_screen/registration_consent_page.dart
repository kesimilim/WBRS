import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/auth/register_screen/register_page.dart';

/// The required acknowledgement immediately before creating an account.
class RegistrationConsentPage extends StatefulWidget {
  const RegistrationConsentPage({super.key, this.nativeRuntime});
  final TimewebAppRuntime? nativeRuntime;

  @override
  State<RegistrationConsentPage> createState() =>
      _RegistrationConsentPageState();
}

class _RegistrationConsentPageState extends State<RegistrationConsentPage> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    const cream = Color(0xFFFFF2E9);
    const peach = Color(0xFFE2A986);

    return Scaffold(
      backgroundColor: const Color(0xFF21170F),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/registration_consent_bg.jpg', fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x660D0908),
                  Color(0x180D0908),
                  Color(0x510D0908)
                ],
                stops: [0, .48, 1],
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: Column(
                          children: [
                            SizedBox(
                                height: constraints.maxHeight > 700 ? 38 : 16),
                            const _ConsentLogo(),
                            const SizedBox(height: 18),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 195),
                              child: Text(
                                context.tr('Знакомства для христиан'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: cream,
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                  height: 1.08,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 260),
                              child: Text(
                                context.tr(
                                    'Общие ценности — начало близких отношений'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: cream,
                                  fontSize: 15,
                                  height: 1.25,
                                ),
                              ),
                            ),
                            const SizedBox(height: 27),
                            Container(
                              width: double.infinity,
                              padding:
                                  const EdgeInsets.fromLTRB(18, 29, 18, 18),
                              decoration: BoxDecoration(
                                color: const Color(0xE62C1D16),
                                border:
                                    Border.all(color: const Color(0xC7C58A68)),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () => setState(
                                        () => _confirmed = !_confirmed),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Checkbox(
                                          key: const ValueKey(
                                              'registration-consent-checkbox'),
                                          value: _confirmed,
                                          onChanged: (value) => setState(() =>
                                              _confirmed = value ?? false),
                                          side: const BorderSide(
                                              color: peach, width: 1.5),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          activeColor: peach,
                                          checkColor: const Color(0xFF24160F),
                                        ),
                                        const SizedBox(width: 2),
                                        Expanded(
                                          child: Padding(
                                            padding:
                                                const EdgeInsets.only(top: 8),
                                            child: Text(
                                              context.tr(
                                                  'Я положительно отношусь и разделяю христианские ценности и не являюсь сторонником других религий'),
                                              style: const TextStyle(
                                                color: cream,
                                                fontSize: 17,
                                                height: 1.29,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(50, 8, 4, 19),
                                    child: Text(
                                      context.tr(
                                          'Для регистрации необходимо поставить галочку'),
                                      style: const TextStyle(
                                        color: Color(0xFFD0BDB1),
                                        fontSize: 13,
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    height: 49,
                                    child: ElevatedButton(
                                      key: const ValueKey(
                                          'registration-consent-continue'),
                                      onPressed: _confirmed
                                          ? () => Navigator.of(context)
                                                  .pushReplacement(
                                                MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      RegisterPage(
                                                    consentConfirmed: true,
                                                    nativeRuntime: widget.nativeRuntime,
                                                  ),
                                                ),
                                              )
                                          : null,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: peach,
                                        foregroundColor:
                                            const Color(0xFF27170F),
                                        disabledBackgroundColor:
                                            const Color(0xFF66564C),
                                        disabledForegroundColor:
                                            const Color(0xFFD2C1B6),
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                      ),
                                      child: Text(
                                        context.tr('Перейти к регистрации'),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(fontSize: 15),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pushReplacement(
                                      MaterialPageRoute<void>(
                                        builder: (_) => LoginPage(nativeRuntime: widget.nativeRuntime),
                                      ),
                                    ),
                                    child: Text(
                                      '${context.tr('Уже есть аккаунт?')} ${context.tr('Войти')}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: cream,
                                        fontSize: 14,
                                        decoration: TextDecoration.underline,
                                        decorationColor: cream,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 30),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsentLogo extends StatelessWidget {
  const _ConsentLogo();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 93,
        width: 180,
        child: Stack(
          alignment: Alignment.topCenter,
          children: const [
            Positioned(
              top: 0,
              child: Icon(Icons.add, color: Color(0xFFFFF2E9), size: 18),
            ),
            Positioned(
              top: 13,
              child: Text(
                'CLRS',
                style: TextStyle(
                  color: Color(0xFFFFF2E9),
                  fontFamily: 'CormorantGaramond',
                  fontSize: 55,
                  height: 1,
                ),
              ),
            ),
            Positioned(
              top: 72,
              child:
                  Icon(Icons.eco_outlined, color: Color(0xFFFFF2E9), size: 20),
            ),
          ],
        ),
      );
}
