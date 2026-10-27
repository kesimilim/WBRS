// ignore_for_file: non_constant_identifier_names

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/presentation/screens/test/white_group.dart';

class GreenPage extends StatefulWidget {
  const GreenPage({super.key});

  @override
  State<GreenPage> createState() => _GreenPageState();
}

class _GreenPageState extends State<GreenPage> {
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
    'веселы и жизнерадостны',
    'энергичны и деловиты',
    'часто не доводите начатое дело до конца',
    'склонны переоценивать себя',
    'способны быстро схватывать новое',
    'неустойчивы в интересах и склонностях',
    'легко переживаете неудачи и неприятности',
    'легко приспосабливаетесь к разным обстоятельствам',
    'с увлечением беретесь за любое новое дело',
    'быстро остываете, если дело перестает вас интересовать',
    'быстро включаетесь в новую работу и быстро переключаетесь с одной работы на другую',
    'тяготитесь однообразием будничной кропотливой работы',
    'общительны и отзывчивы, не чувствуете скованности с новыми для вас людьми',
    'выносливы и работоспособны',
    'обладаете громкой, быстрой, отчетливой речью, сопровождающейся жестами, выразительной мимикой',
    'сохраняете самообладание в неожиданной сложной обстановке',
    'обладаете всегда бодрым настроением',
    'быстро засыпаете и пробуждаетесь',
    'часто не собраны, проявляете поспешность в решениях',
    'склонны иногда скользить по поверхности, отвлекаться'
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
                  ListView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      itemCount: colors.length,
                      itemBuilder: (_, int index) {
                        return _questionBuilder(index);
                      }),
                  const SizedBox(
                    height: 30,
                  ),
                  ElevatedButton(
                      onPressed: () {
                        setState(() {
                          redGroup = counter;
                        });
                        nextScreenReplace(context, const WhitePage());
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
