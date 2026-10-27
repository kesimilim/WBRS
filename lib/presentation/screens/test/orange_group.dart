// ignore_for_file: unrelated_type_equality_checks, non_constant_identifier_names
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/profile/profile_page.dart';
import 'package:wbrs/app/widgets/widgets.dart';

class OrangePage extends StatefulWidget {
  const OrangePage({super.key});

  @override
  State<OrangePage> createState() => _OrangePageState();
}

class _OrangePageState extends State<OrangePage> {
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
    'стремитесь вызвать сочувствие и помощь у окружающих'
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
                        int max = 0;
                        int max2 = 0;
                        setState(() {
                          blueGroup = counter;

                          if (brownGroup > max) {
                            max = brownGroup;
                          }

                          if (redGroup > max) {
                            max = redGroup;
                          }

                          if (whiteGroup > max) {
                            max = whiteGroup;
                          }

                          if (blueGroup > max) {
                            max = blueGroup;
                          }

                          if (brownGroup > max2 && brownGroup != max) {
                            max2 = brownGroup;
                          }

                          if (redGroup > max2 && redGroup != max) {
                            max2 = redGroup;
                          }

                          if (whiteGroup > max2 && whiteGroup != max) {
                            max2 = whiteGroup;
                          }

                          if (blueGroup > max2 && blueGroup != max) {
                            max2 = blueGroup;
                          }

                          if (max == brownGroup) {
                            if (max2 > 0) {
                              if (max2 == redGroup) {
                                group = 'коричнево-красная';
                              }
                              if (max2 == blueGroup) {
                                group = 'коричнево-синяя';
                              }
                              if (max2 == whiteGroup) {
                                group = 'коричнево-белая';
                              }
                            } else {
                              group = 'коричневая';
                            }
                          }

                          if (max == redGroup) {
                            if (max2 > 0) {
                              if (max2 == brownGroup) {
                                group = 'красно-коричневая';
                              }
                              if (max2 == blueGroup) {
                                group = 'красно-синяя';
                              }
                              if (max2 == whiteGroup) {
                                group = 'красно-белая';
                              }
                            } else {
                              group = 'красная';
                            }
                          }

                          if (max == blueGroup) {
                            if (max2 > 0) {
                              if (max2 == redGroup) {
                                group = 'сине-красная';
                              }
                              if (max2 == brownGroup) {
                                group = 'сине-коричневая';
                              }
                              if (max2 == whiteGroup) {
                                group = 'сине-белая';
                              }
                            } else {
                              group = 'синяя';
                            }
                          }

                          if (max == whiteGroup) {
                            if (max2 > 0) {
                              if (max2 == redGroup) {
                                group = 'бело-красная';
                              }
                              if (max2 == blueGroup) {
                                group = 'бело-синяя';
                              }
                              if (max2 == brownGroup) {
                                group = 'бело-коричневая';
                              }
                            } else {
                              group = 'белая';
                            }
                          }
                          firebaseFirestore
                              .collection('users')
                              .doc(firebaseAuth.currentUser!.uid)
                              .update(
                                  {'isRegistrationEnd': true, 'группа': group});
                          setState(() {
                            selectedIndex = 0;
                          });
                          nextScreenReplace(
                              context,
                              ProfilePage(
                                group: group,
                                email: FirebaseAuth.instance.currentUser!.email
                                    .toString(),
                                userName: FirebaseAuth
                                    .instance.currentUser!.displayName
                                    .toString(),
                                about: globalAbout.toString(),
                                age: globalAge.toString(),
                                deti: globalDeti,
                                rost: globalRost.toString(),
                                city: globalCity.toString(),
                                hobbi: globalHobbi.toString(),
                                pol: globalPol.toString(),
                              ));
                          showSnackbar(
                              context,
                              LrsTheme.peach,
                              context.tr('Успешно! Ваша группа: {group}',
                                  args: {'group': context.tr(group)}));
                        });
                      },
                      child: Text(context.tr('Завершить')))
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
