// ignore_for_file: non_constant_identifier_names

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/widgets.dart';

import 'orange_group.dart';

class WhitePage extends StatefulWidget {
  const WhitePage({super.key});

  @override
  State<WhitePage> createState() => _WhitePageState();
}

class _WhitePageState extends State<WhitePage> {
  int counter = 0;

  final List<Color> colors = <Color>[
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
    Colors.grey,
  ];

  final List<String> questions = [
    'спокойны и хладнокровны',
    'последовательны и обстоятельны в делах',
    'осторожны и рассудительны',
    'умеете ждать',
    'молчаливы и не любите попусту болтать',
    'обладаете спокойной, равномерной речью, с остановками, без резко выраженных эмоций, жестикуляции и мимики',
    'сдержаны и терпеливы',
    'доводите начатое дело до конца',
    'не растрачиваете попусту сил',
    'придерживаетесь выработанного распорядка дня, жизни, системы в работе',
    'легко сдерживаете порывы',
    'маловосприимчивы к одобрению и порицанию',
    'незлобивы, проявляете снисходительное отношение к колкостям в свой адрес',
    'постоянны в своих отношениях и интересах',
    'медленно включаетесь в работу и медленно переключаетесь с одного дела на другое',
    'ровны в отношениях со всеми',
    'любите аккуратность и порядок во всем',
    'с трудом приспосабливаетесь к новой обстановке',
    'обладаете выдержкой',
    'несколько медлительны'
  ];

  @override
  Widget build(BuildContext context) {
    return ClrsScaffold(
        appBar: AppBar(
            title: Text(context.tr('Ответьте на вопросы'),
                maxLines: 2, style: const TextStyle(fontSize: 18)),
            toolbarHeight:
                MediaQuery.textScalerOf(context).scale(18) > 25 ? 96 : 72),
        body: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
              child: Column(
                children: [
                  SizedBox(
                    child: ListView.builder(
                        physics: const NeverScrollableScrollPhysics(),
                        shrinkWrap: true,
                        itemCount: colors.length,
                        itemBuilder: (_, int index) {
                          return _questionBuilder(index);
                        }),
                  ),
                  const SizedBox(
                    height: 30,
                  ),
                  ElevatedButton(
                      onPressed: () {
                        setState(() {
                          whiteGroup = counter;
                        });
                        nextScreenReplace(context, const OrangePage());
                      },
                      child: Text(context.tr('Дальше')))
                ],
              ),
            )));
  }

  Widget _questionBuilder(int index) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ClrsPanel(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
                child: Text(context.tr(questions[index]),
                    style:
                        const TextStyle(color: LrsTheme.text, fontSize: 14))),
            const SizedBox(width: 8),
            IconButton(
                tooltip: context.tr('Да'),
                onPressed: () => setState(() {
                      colors[index] = LrsTheme.peach;
                      counter++;
                    }),
                style: IconButton.styleFrom(
                    backgroundColor: colors[index] == LrsTheme.peach
                        ? LrsTheme.peach
                        : Colors.black26),
                icon: const Icon(Icons.add)),
            IconButton(
                tooltip: context.tr('Нет'),
                onPressed: () => setState(() {
                      colors[index] = Colors.red;
                    }),
                style: IconButton.styleFrom(
                    backgroundColor: colors[index] == Colors.red
                        ? Colors.red
                        : Colors.black26),
                icon: const Icon(Icons.remove)),
          ])));
}
