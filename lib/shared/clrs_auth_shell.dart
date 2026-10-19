import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/language_picker.dart';
import 'clrs_screen.dart';
import 'clrs_brand.dart';
import 'lrs_theme.dart';

/// Latest approved login reference: 2026-09-21 23:43:40. Forms remain scrollable
/// at large type and above the keyboard; the photograph contains no UI text.
class ClrsAuthShell extends StatelessWidget {
  const ClrsAuthShell(
      {super.key,
      required this.child,
      this.busy = false,
      this.loginLayout = false});
  final Widget child;
  final bool busy;
  final bool loginLayout;

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      body: SafeArea(child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxHeight < 525 ||
            MediaQuery.textScalerOf(context).scale(16) > 24;
        if (loginLayout) {
          final loginCompact = compact ||
              (constraints.maxWidth <= 340 && constraints.maxHeight < 600);
          return _buildApprovedLogin(context, constraints, loginCompact);
        }
        return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Center(
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: 470,
                        minHeight: math.max(0, constraints.maxHeight)),
                    child: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: compact ? 20 : 34, vertical: 8),
                        child: Column(children: [
                          const Align(
                              alignment: Alignment.centerRight,
                              child: LanguagePickerButton(compact: true)),
                          ClrsLogo(size: compact ? 48 : 66, centered: true),
                          const SizedBox(height: 16),
                          ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 270),
                              child: Text(
                                  context
                                      .tr(
                                          'Христианские отношения для серьёзных людей и крепкой семьи')
                                      .toUpperCase(),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      letterSpacing: 2,
                                      height: 1.6,
                                      color: LrsTheme.text))),
                          if (!compact)
                            Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(
                                          width: 108,
                                          child: ClrsMotto(size: 22)),
                                      const Spacer(),
                                      Flexible(
                                          child: Text(
                                              context
                                                  .tr(
                                                      'Вера\nОтношения\nСемья\nБудущее')
                                                  .toUpperCase(),
                                              textAlign: TextAlign.right,
                                              style: const TextStyle(
                                                  fontSize: 8,
                                                  letterSpacing: 1.5,
                                                  height: 1.8,
                                                  color: LrsTheme.peachLight))),
                                    ])),
                          SizedBox(
                              height: compact
                                  ? 18
                                  : math.max(42, constraints.maxHeight * .16)),
                          if (busy) const LinearProgressIndicator(),
                          child,
                          const ClrsValuesFooter(),
                        ])))));
      })));

  Widget _buildApprovedLogin(
      BuildContext context, BoxConstraints constraints, bool compact) {
    final horizontalInset = (constraints.maxWidth * .11).clamp(24.0, 40.0);
    final narrow = constraints.maxWidth <= 340;
    return SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Center(
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: 470,
                    minHeight: math.max(0, constraints.maxHeight)),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Padding(
                          padding: EdgeInsets.fromLTRB(
                              horizontalInset, 8, horizontalInset, 0),
                          child: Column(children: [
                            SizedBox(
                                width: double.infinity,
                                child: Stack(
                                    alignment: Alignment.topCenter,
                                    children: [
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(top: 4),
                                          child: ClrsLogo(
                                              size: compact ? 48 : 50,
                                              centered: true,
                                              subtitleSans: true)),
                                      const Positioned(
                                          top: 0,
                                          right: 0,
                                          child: LanguagePickerButton(
                                              compact: true)),
                                    ])),
                            SizedBox(height: compact ? 10 : 7),
                            ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 180),
                                child: Text(
                                    context
                                        .tr(
                                            'Христианские отношения для серьёзных людей и крепкой семьи')
                                        .replaceFirst(' и крепкой семьи',
                                            '\nи крепкой семьи')
                                        .toUpperCase(),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        fontSize: 8,
                                        letterSpacing: 1.6,
                                        height: 1.5,
                                        color: LrsTheme.text))),
                            if (!compact)
                              Transform.translate(
                                  offset: const Offset(0, -16),
                                  child: SizedBox(
                                      width: math.min(
                                          constraints.maxWidth -
                                              (narrow ? 56 : 44),
                                          430),
                                      child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Transform.translate(
                                                offset: Offset(
                                                    narrow ? -12 : -24, 8),
                                                child: const SizedBox(
                                                    width: 84,
                                                    child: _LoginMotto())),
                                            const Spacer(),
                                            Transform.translate(
                                                offset:
                                                    Offset(narrow ? 0 : 10, 0),
                                                child: Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 12),
                                                    child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .end,
                                                        children: [
                                                          Text(
                                                              context
                                                                  .tr(
                                                                      'Вера\nОтношения\nСемья\nБудущее')
                                                                  .toUpperCase(),
                                                              textAlign:
                                                                  TextAlign
                                                                      .right,
                                                              style: const TextStyle(
                                                                  fontSize: 8.5,
                                                                  letterSpacing:
                                                                      1.8,
                                                                  height: 1.65,
                                                                  color: LrsTheme
                                                                      .peachLight)),
                                                          const SizedBox(
                                                              height: 4),
                                                          Container(
                                                              width: 22,
                                                              height: 1,
                                                              color: LrsTheme
                                                                  .peachLight),
                                                        ]))),
                                          ]))),
                            SizedBox(
                                height: compact
                                    ? 20
                                    : math.max(
                                        56, constraints.maxHeight * .18)),
                            if (busy) const LinearProgressIndicator(),
                            child,
                          ])),
                      const Padding(
                          padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                          child: _LoginValuesFooter()),
                    ]))));
  }
}

class _LoginMotto extends StatelessWidget {
  const _LoginMotto();

  @override
  Widget build(BuildContext context) => Column(children: [
        const ClrsMotto(size: 18),
        const SizedBox(height: 1),
        const Icon(Icons.favorite_border, color: LrsTheme.peach, size: 15),
      ]);
}

class _LoginValuesFooter extends StatelessWidget {
  const _LoginValuesFooter();

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(children: [
        Row(children: [
          const Expanded(child: Divider(color: LrsTheme.peach, height: 12)),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('†',
                  style: TextStyle(
                      color: LrsTheme.peach,
                      fontSize: 27,
                      height: 1,
                      fontFamily: 'CormorantGaramond'))),
          const Expanded(child: Divider(color: LrsTheme.peach, height: 12)),
        ]),
        const SizedBox(height: 8),
        Text(
            context
                .tr('Настоящие люди · Общие ценности\nРеальные отношения')
                .replaceAll('\n', ' · ')
                .toUpperCase(),
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: LrsTheme.peachLight,
                fontSize: 7,
                letterSpacing: 1,
                height: 1.4)),
      ]));
}
