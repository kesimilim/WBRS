import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class DonateButton extends StatelessWidget {
  final Widget child;
  const DonateButton({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showDialog(context),
      child: child,
    );
  }

  void _showDialog(BuildContext context) {
    final controller = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
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
                    style: const TextStyle(
                      fontSize: 13,
                      color: LrsTheme.muted,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
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
                            side: const BorderSide(color: LrsTheme.actionBorder),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                            minimumSize: const Size(0, 44),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(fontSize: 14),
                          ),
                          onPressed: () async {
                            final raw = controller.text.trim().replaceAll(',', '.');
                            final amount = double.tryParse(raw);
                            if (amount == null || amount <= 0) {
                              setState(() => errorText =
                              'Введите сумму цифрами, например 150 или 99.50');
                              return;
                            }
                            Navigator.pop(ctx);
                            await _openWebview(context, amount);
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
  }

  Future<void> _openWebview(BuildContext context, double amount) async {
    const isTestMode = bool.fromEnvironment('IS_TEST', defaultValue: false);
    const password1 = isTestMode ? 'vcb3Ig7r50VnSXG7uXgV' : 'Grebat-kopat3102-';

    final outSum = amount.toStringAsFixed(2);
    final signature = md5
        .convert(utf8.encode('WBRS:$outSum:0:$password1'))
        .toString();

    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(
          'https://auth.robokassa.ru/Merchant/Index.aspx?'
              'MerchantLogin=WBRS'
              '&OutSum=$outSum'
              '&InvId=0'
              '&Description=${Uri.encodeComponent("Добровольное пожертвование")}'
              '&SignatureValue=$signature'
              '${isTestMode ? "&IsTest=1" : ""}'));

    await nextScreen(context, Scaffold(body: WebViewWidget(controller: ctrl)));

    if (context.mounted) {
      showSnackbar(context, Colors.lightGreen, context.tr('Спасибо за поддержку!'));
    }
  }
}