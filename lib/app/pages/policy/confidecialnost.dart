import 'package:flutter/material.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

class Politica extends StatelessWidget {
  const Politica({super.key});
  @override
  Widget build(BuildContext context) => ClrsDocumentPage(
    title: 'Политика конфиденциальности',
    asset: 'assets/policy.txt',
    localizedAssets: {
      for (final code in ClrsLocalizations.codes)
        if (code != 'ru') code: 'assets/legal/$code/policy.txt',
    },
    googleTranslatedLanguages: {
      for (final code in ClrsLocalizations.codes)
        if (code != 'ru' && code != 'en') code,
    },
  );
}
