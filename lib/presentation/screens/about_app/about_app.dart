import 'package:wbrs/localization/clrs_localizations.dart';
// ignore_for_file: camel_case_types
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wbrs/app/pages/policy/confidecialnost.dart';
import 'package:wbrs/app/pages/policy/offer.dart';
import 'package:wbrs/app/pages/policy/rules.dart';
import 'package:wbrs/app/pages/policy/soglashenie.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/localization/language_picker.dart';

class About_App extends StatelessWidget {
  const About_App({super.key});
  @override
  Widget build(BuildContext context) {
    Widget link(IconData icon, String text, Widget page) => Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: ClrsPanel(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => page)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                Icon(icon, size: 20, color: LrsTheme.peach),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr(text),
                    style: const TextStyle(fontSize: 12, height: 1.15),
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
    return ClrsScaffold(
      backgroundAsset: 'assets/family_main.jpg',
      backgroundScale: 1.42,
      appBar: AppBar(
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Icon(Icons.favorite_border, color: LrsTheme.peach),
          ),
        ],
      ),
      drawer: MyDrawer(),
      bottomNavigationBar: const MyBottomNavigationBar(),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = (constraints.maxWidth - 28).clamp(
            0.0,
            double.infinity,
          );
          final panelWidth = availableWidth * .64;
          final detailWidth = availableWidth * .86;
          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            children: [
              const ClrsLogo(size: 48),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 205,
                  child: Text(
                    context.tr(ClrsBrand.ruTagline),
                    style: const TextStyle(fontSize: 10, height: 1.4),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 125,
                  child: Column(
                    children: [
                      ClrsMotto(size: 19),
                      Icon(
                        Icons.favorite_border,
                        color: LrsTheme.peach,
                        size: 19,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr('О приложении'),
                style: const TextStyle(
                  fontFamily: 'CormorantGaramond',
                  fontWeight: FontWeight.w600,
                  fontSize: 28,
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: panelWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      link(
                        Icons.shield_outlined,
                        'Политика конфиденциальности',
                        Politica(),
                      ),
                      link(
                        Icons.description_outlined,
                        'Пользовательское соглашение',
                        Rules(),
                      ),
                      link(
                        Icons.handshake_outlined,
                        'Публичная оферта',
                        Offer(),
                      ),
                      link(
                        Icons.menu_book_outlined,
                        'Правила использования',
                        Rule(),
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: detailWidth,
                  child: Column(
                    children: [
                      ClrsPanel(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.info_outline,
                              size: 20,
                              color: LrsTheme.peach,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                context.tr('Версия приложения'),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const Text(
                              '1.0.25',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(width: 5),
                            const Icon(Icons.chevron_right, size: 20),
                          ],
                        ),
                      ),
                      const SizedBox(height: 5),
                      ClrsPanel(
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          dense: true,
                          minTileHeight: 40,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                          ),
                          leading: const Icon(
                            Icons.chat_bubble_outline,
                            size: 20,
                          ),
                          horizontalTitleGap: 8,
                          title: Text(
                            context.tr('Обратная связь'),
                            style: const TextStyle(
                              fontFamily: 'Lato',
                              fontSize: 12,
                            ),
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => openSupportEmail(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              ClrsPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.language, size: 20, color: LrsTheme.peach),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.tr('Язык'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const LanguagePickerButton(showIcon: false),
                  ],
                ),
              ),
              const ClrsValuesFooter(compact: true),
            ],
          );
        },
      ),
    );
  }
}

Future<void> openSupportEmail(BuildContext context) async {
  var opened = false;
  try {
    opened = await launchUrl(Uri(scheme: 'mailto', path: 'supp.lrs@ya.ru'));
  } catch (_) {
    // Some platforms throw instead of returning false when no handler exists.
  }
  if (opened || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.tr('Обратная связь')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr(
                'Почтовое приложение не открылось. Напишите нам по адресу:',
              ),
            ),
            SizedBox(height: 12),
            SelectableText('supp.lrs@ya.ru'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await Clipboard.setData(ClipboardData(text: 'supp.lrs@ya.ru'));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(content: Text(context.tr('Адрес скопирован'))),
                );
              }
            } catch (_) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      context.tr('Выделите и скопируйте адрес вручную.'),
                    ),
                  ),
                );
              }
            }
          },
          child: Text(context.tr('Копировать адрес')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(context.tr('Закрыть')),
        ),
      ],
    ),
  );
}
