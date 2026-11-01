import 'package:flutter/material.dart';
import 'package:wbrs/shared/clrs_screen.dart';

class Politica extends StatelessWidget {
  const Politica({super.key});
  @override
  Widget build(BuildContext context) => const ClrsDocumentPage(
    title: 'Политика конфиденциальности',
    asset: 'assets/policy.txt',
    localizedAssets: {'en': 'assets/legal/en/policy.txt'},
  );
}
