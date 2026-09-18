import 'dart:convert';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wbrs/app/widgets/glass_button.dart';
import 'package:wbrs/app/widgets/widgets.dart';

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
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Center(
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  width: 320,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.orangeAccent.shade400.withOpacity(0.35),
                        Colors.orangeAccent.shade100.withOpacity(0.25),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.35),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.orangeAccent.shade400.withOpacity(0.25),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Поддержите проект ❤️',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ваша поддержка делает проект лучше',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withOpacity(0.75),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: errorText != null
                                    ? Colors.redAccent.withOpacity(0.7)
                                    : Colors.white.withOpacity(0.3),
                                width: errorText != null ? 1.5 : 1,
                              ),
                            ),
                            child: TextField(
                              controller: controller,
                              keyboardType:
                              const TextInputType.numberWithOptions(
                                  decimal: true),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                              cursorColor: Colors.white,
                              onChanged: (_) {
                                if (errorText != null) {
                                  setState(() => errorText = null);
                                }
                              },
                              decoration: InputDecoration(
                                hintText: 'Любая сумма от души',
                                hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.7),
                                  fontSize: 15,
                                ),
                                suffixText: '₽',
                                suffixStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (errorText != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          errorText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: GlassButton(
                              label: 'Отмена',
                              onTap: () => Navigator.pop(ctx),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GlassButton(
                              label: 'Поддержать',
                              isPrimary: true,
                              onTap: () async {
                                final raw = controller.text
                                    .trim()
                                    .replaceAll(',', '.');
                                final amount = double.tryParse(raw);
                                if (amount == null || amount <= 0) {
                                  setState(() => errorText =
                                  'Введите сумму цифрами, например 150 или 99.50');
                                  return;
                                }
                                Navigator.pop(ctx);
                                await _openWebview(context, amount);
                              },
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
      showSnackbar(context, Colors.lightGreen, 'Спасибо за поддержку!');
    }
  }
}