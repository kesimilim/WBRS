import 'package:wbrs/core/utils/temperament.dart';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/app/helper/global.dart';

import '../../../app/widgets/widgets.dart';
import '../auth/session_gate.dart';

import 'package:wbrs/shared/lrs_theme.dart';

class FirstGroupRed extends StatefulWidget {
  const FirstGroupRed({
    super.key,
    this.onNativeSubmit,
    this.nativeInitialAnswers,
    this.nativeControlsEnabled = true,
    this.nativeSubmitEnabled = true,
    this.nativeSubmitLabel,
    this.nativeNotice,
    this.nativeFooter,
  });
  final Future<void> Function(List<bool> canonicalAnswers)? onNativeSubmit;
  final List<bool>? nativeInitialAnswers;
  final bool nativeControlsEnabled, nativeSubmitEnabled;
  final String? nativeSubmitLabel, nativeNotice;
  final Widget? nativeFooter;


  @override
  State<FirstGroupRed> createState() => _FirstGroupRedState();
}

class _FirstGroupRedState extends State<FirstGroupRed> {
  final List<Color> colors = List.generate(80, (index) => Colors.grey);

  final List<String> brownQuestions = [
    'неусидчивы, суетливы',
    'невыдержанны, вспыльчивы',
    'нетерпеливы',
    'резки и прямолинейны в отношениях с людьми',
    'решительны и инициативны',
    'упрямы',
    'находчивы в споре',
    'работаете рывками',
    'склонны к риску',
    'злопамятны',
    'обладаете быстрой, страстной, со сбивчивыми интонациями речью',
    'неуравновешенны и склонны к горячности',
    'агрессивный забияка',
    'нетерпимы к недостаткам',
    'обладаете выразительной мимикой',
    'способны быстро действовать и решать',
    'неустанно стремитесь к новому',
    'обладаете резкими порывистыми движениями',
    'настойчивы в достижении поставленной цели',
    'склонны к резким сменам настроения',
  ];

  final List<String> redQuestions = [
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
    'склонны иногда скользить по поверхности, отвлекаться',
  ];

  final List<String> blueQuestions = [
    'стеснительны и застенчивы',
    'теряетесь в новой обстановке',
    'затрудняетесь установить контакт с незнакомыми людьми',
    'не верите в свои силы',
    'легко переносите одиночество',
    'чувствуете подавленность и растерянность при неудачах',
    'склонны уходить в себя',
    'быстро утомляетесь',
    'обладаете тихой речью',
    ' невольно приспосабливаетесь к характеру собеседника',
    'впечатлительны до слезливости',
    'чрезвычайно восприимчивы к одобрению и порицанию',
    'предъявляете высокие требования к себе и окружающим',
    'склонны к подозрительности, мнительности',
    'болезненно чувствительны и легко ранимы',
    'чрезмерно обидчивы',
    'скрытны и необщительны, не делитесь ни с кем своими мыслями',
    'малоактивны и робки',
    'уступчивы, покорны',
    'стремитесь вызвать сочувствие и помощь у окружающих',
  ];

  final List<String> whiteQuestions = [
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
    'несколько медлительны',
  ];

  List<List<String>> allQuestions = [];
  List<int> groupCounter = [0, 0, 0, 0];

  int counter = 0;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    final saved = widget.nativeInitialAnswers;
    if (widget.onNativeSubmit != null && saved != null) {
      if (saved.length != 80) {
        throw ArgumentError('Invalid questionnaire answers.');
      }
      for (var index = 0; index < 80; index++) {
        final groupIndex = (index ~/ 10) % 4;
        final canonicalIndex =
            groupIndex * 20 + index % 10 + (index >= 40 ? 10 : 0);
        if (saved[canonicalIndex]) {
          colors[index] = LrsTheme.peach;
          groupCounter[groupIndex]++;
        }
      }
    }
  }

  List<bool> get _canonicalAnswers {
    final answers = List<bool>.filled(80, false);
    for (var index = 0; index < 80; index++) {
      final groupIndex = (index ~/ 10) % 4;
      answers[groupIndex * 20 + index % 10 + (index >= 40 ? 10 : 0)] =
          colors[index] == LrsTheme.peach;
    }
    return List.unmodifiable(answers);
  }

  @override
  Widget build(BuildContext context) {
    allQuestions = [
      brownQuestions,
      redQuestions,
      blueQuestions,
      whiteQuestions,
    ];

    return ClrsScaffold(
        backgroundAsset: 'assets/final_design/family_back.png',
        appBar: AppBar(
            title: Text(context.tr('Ответьте на вопросы'),
                maxLines: 2, style: const TextStyle(fontSize: 18)),
            toolbarHeight:
                MediaQuery.textScalerOf(context).scale(18) > 25 ? 96 : 72),
        body: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 30),
            child: Column(
              children: [
                const Align(
                    alignment: Alignment.centerLeft, child: ClrsBrandHeader()),
                Text(
                  context.tr(
                      'Поставьте + там, где похоже на вас.\n\nЧем честнее вы ответите, тем точнее мы подберем для вас подходящих людей.\n\nНет плохих и хороших ответов. Нам важно знать, какой вы. Нам важны именно вы.'),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    height: 1.4,
                  ),
                ),
                SizedBox(
                  child: ListView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    itemCount: colors.length,
                    itemBuilder: (_, int index) {
                      return _questionBuilder(index);
                    },
                  ),
                ),
                const SizedBox(height: 20),
                const Row(children: [
                  Expanded(child: Divider(color: LrsTheme.peach)),
                  Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('✝',
                          style:
                              TextStyle(color: LrsTheme.peach, fontSize: 24))),
                  Expanded(child: Divider(color: LrsTheme.peach))
                ]),
                const SizedBox(height: 12),
                Text(
                    context.tr('Отмечено: {count} из {minimum}', args: {
                      'count': context.l10n.number(
                          groupCounter.fold<int>(0, (sum, item) => sum + item)),
                      'minimum': context.l10n.number(20)
                    }),
                    style: const TextStyle(
                        color: LrsTheme.peachLight, fontSize: 16)),
                const SizedBox(height: 12),
                if (widget.onNativeSubmit != null && widget.nativeNotice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(context.tr(widget.nativeNotice!), textAlign: TextAlign.center),
                  ),
                if (groupCounter.fold<int>(0, (sum, item) => sum + item) >= 20)
                  ElevatedButton(
                    key: const ValueKey('questionnaire-submit'),
                    onPressed: _saving || !widget.nativeSubmitEnabled
                        ? null
                        : () async {
                            if (groupCounter.fold<int>(
                                  0,
                                  (sum, score) => sum + score,
                                ) <
                                20) {
                              return;
                            }
                            if (_saving || !widget.nativeSubmitEnabled) return;
                            final native = widget.onNativeSubmit;
                            if (native != null) {
                              setState(() => _saving = true);
                              try {
                                await native(_canonicalAnswers);
                              } finally {
                                if (mounted) setState(() => _saving = false);
                              }
                              return;
                            }
                            final user = firebaseAuth.currentUser;
                            if (user == null) return;
                            setState(() => _saving = true);
                            try {
                              final result = classifyTemperament(
                                groupCounter,
                              );
                              final ref = firebaseFirestore
                                  .collection('users')
                                  .doc(user.uid);
                              await ref.update({
                                'isRegistrationEnd': true,
                                'группа': result,
                              });
                              final data = await ref.get();
                              if (!mounted ||
                                  firebaseAuth.currentUser?.uid != user.uid) {
                                return;
                              }
                              group = result;
                              testIsComlpete = true;
                              globalBalance =
                                  (data.data()?['balance'] as num?)?.toInt() ??
                                      0;
                              final registrationNotice =
                                  data.data()?['registrationNoticePending'] ==
                                      true;
                              await showDialog<void>(
                                context: context,
                                barrierDismissible: false,
                                builder: (dialogContext) => AlertDialog(
                                  scrollable: true,
                                  alignment: Alignment.topCenter,
                                  backgroundColor: const Color(0xF0443D4D),
                                  title: Text(
                                    context.tr(registrationNotice
                                        ? 'Успешная Регистрация'
                                        : 'Тест завершён'),
                                  ),
                                  content: Text(
                                    context.tr('Ваша группа: {group}', args: {
                                          'group': context.tr(result)
                                        }) +
                                        (registrationNotice
                                            ? '\n${context.tr('При регистрации начислено 27 серебра. Текущий баланс: {balance} Ag.', args: {
                                                    'balance': context.l10n
                                                        .number(globalBalance)
                                                  })}'
                                            : ''),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext),
                                      child: Text(context.tr('ОК')),
                                    ),
                                  ],
                                ),
                              );
                              if (registrationNotice) {
                                await ref.update({
                                  'registrationNoticePending': false,
                                });
                              }
                              if (!mounted ||
                                  firebaseAuth.currentUser?.uid != user.uid) {
                                return;
                              }
                              selectedIndex = 4;
                              nextScreenReplace(
                                context,
                                const SessionGate(showProfileAfterTest: true),
                              );
                            } catch (_) {
                              if (mounted) {
                                showSnackbar(
                                  context,
                                  LrsTheme.danger,
                                  context.tr(
                                      'Не удалось сохранить результат. Проверьте соединение и повторите попытку.'),
                                );
                              }
                            } finally {
                              if (mounted) setState(() => _saving = false);
                            }
                          },
                    child: Text(context.tr(widget.nativeSubmitLabel ?? 'Завершить тест')),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      context.tr(
                          'Выберите минимум 20 утверждений, чтобы завершить тест'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: LrsTheme.muted),
                    ),
                  ),
                if (widget.onNativeSubmit != null && widget.nativeFooter != null)
                  widget.nativeFooter!,
              ],
            ),
          ),
        ));
  }

  Widget _questionBuilder(int index) {
    final groupIndex = index >= 40 ? index ~/ 10 - 4 : index ~/ 10;
    final question = index >= 40
        ? allQuestions[groupIndex][index % 10 + 10]
        : allQuestions[groupIndex][index % 10];
    final selected = colors[index] == LrsTheme.peach;
    return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ClrsPanel(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Expanded(
                  child: Text(context.tr(question),
                      style:
                          const TextStyle(color: LrsTheme.text, fontSize: 14))),
              const SizedBox(width: 8),
              Semantics(
                  selected: selected,
                  child: IconButton(
                      key: ValueKey('question-$index'),
                      tooltip: context.tr(selected ? 'Снять выбор' : 'Выбрать'),
                      style: IconButton.styleFrom(
                          backgroundColor:
                              selected ? LrsTheme.peach : Colors.black26,
                          foregroundColor: selected
                              ? LrsTheme.surface
                              : LrsTheme.peachLight),
                      onPressed: _saving || !widget.nativeControlsEnabled
                          ? null
                          : () {
                              setState(() {
                                if (colors[index] == LrsTheme.peach) {
                                  colors[index] = Colors.grey;
                                  groupCounter[groupIndex]--;
                                } else {
                                  colors[index] = LrsTheme.peach;
                                  groupCounter[groupIndex]++;
                                }
                              });
                            },
                      icon: Icon(selected ? Icons.check : Icons.add,
                          semanticLabel: context
                              .tr(selected ? 'Снять выбор' : 'Выбрать')))),
            ])));
  }
}
