import 'package:flutter/material.dart';
import 'package:wbrs/shared/clrs_screen.dart';

class Rules extends StatelessWidget {
  const Rules({super.key});
  @override
  Widget build(BuildContext context) => const ClrsDocumentPage(
    title: 'Пользовательское соглашение',
    asset: 'assets/agreement.txt',
    localizedAssets: {'en': 'assets/legal/en/agreement.txt'},
  );
}
