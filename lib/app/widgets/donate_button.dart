import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class DonateButton extends StatelessWidget {
  final Widget child;
  final TimewebAppRuntime? runtime;
  const DonateButton({super.key, required this.child, this.runtime});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => show(context, runtime: runtime),
      child: child,
    );
  }

  static void show(BuildContext context, {TimewebAppRuntime? runtime}) {
    DonateButton(
      runtime: runtime,
      child: const SizedBox.shrink(),
    )._showDialog(context);
  }

  Future<void> _showDialog(BuildContext context) async {
    final controller = TextEditingController();
    String? errorText;

    await showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 320,
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: LrsTheme.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: LrsTheme.actionBorder, width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    ctx.tr('Поддержите проект ❤️'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: LrsTheme.text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ctx.tr('Ваша поддержка делает проект лучше'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: LrsTheme.muted),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: LrsTheme.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                    cursorColor: LrsTheme.peach,
                    onChanged: (_) {
                      if (errorText != null) {
                        setState(() => errorText = null);
                      }
                    },
                    decoration: InputDecoration(
                      hintText: ctx.tr('Любая сумма от души'),
                      hintStyle: const TextStyle(
                        color: LrsTheme.muted,
                        fontSize: 15,
                      ),
                      suffixText: '₽',
                      suffixStyle: const TextStyle(
                        color: LrsTheme.peachLight,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                      errorText: errorText,
                      errorStyle: const TextStyle(color: LrsTheme.danger),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(ctx.tr('Отмена')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: LrsTheme.actionGlass,
                            foregroundColor: LrsTheme.text,
                            side: const BorderSide(
                              color: LrsTheme.actionBorder,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                            minimumSize: const Size(0, 44),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(fontSize: 14),
                          ),
                          onPressed: () async {
                            final raw = controller.text.trim().replaceAll(
                              ',',
                              '.',
                            );
                            final amount = double.tryParse(raw);
                            if (!RegExp(
                                  r'^\d{1,6}(\.\d{1,2})?$',
                                ).hasMatch(raw) ||
                                amount == null ||
                                amount < 1 ||
                                amount > 100000) {
                              setState(
                                () => errorText =
                                    'Введите сумму цифрами, например 150 или 99.50',
                              );
                              return;
                            }
                            Navigator.pop(ctx);
                            await _openCheckout(
                              context,
                              (amount * 100).round(),
                            );
                          },
                          child: Text(
                            ctx.tr('Поддержать'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _openCheckout(BuildContext context, int amountMinor) async {
    try {
      final active = runtime;
      if (active == null) {
        if (!await launchUrl(
          Uri.parse(
            'https://qr.nspk.ru/BS2A002KUIKV3G1Q8JGRDS9N32P84DCB?type=01&bank=100000000008&crc=5D81',
          ),
          mode: LaunchMode.externalApplication,
        ))
          throw StateError('Support unavailable.');
        return;
      }
      final lease = active.session.captureLease();
      final checkout = await active.client.donationCheckout(amountMinor);
      lease.requireCurrent();
      if (!context.mounted) return;
      if (!await launchUrl(checkout, mode: LaunchMode.externalApplication))
        throw StateError('Checkout unavailable.');
      // The provider confirms payment. Returning to CLRS makes no success claim.
    } catch (_) {
      if (context.mounted)
        showSnackbar(
          context,
          LrsTheme.danger,
          context.tr('Не удалось открыть оплату. Попробуйте позже.'),
        );
    }
  }
}
