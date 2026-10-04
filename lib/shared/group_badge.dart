import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wbrs/core/utils/account_destination.dart'
    show savedAccountGroup;
import 'package:wbrs/localization/clrs_localizations.dart';

/// Colors come from the saved test result, never from its translation.
List<Color> groupColors(String group) {
  final actual = savedAccountGroup({'группа': group});
  if (actual == null) return const [];
  return actual
      .split('-')
      .map((part) => GroupBadge.colors[part])
      .whereType<Color>()
      .toList(growable: false);
}

class GroupRing extends StatelessWidget {
  const GroupRing({super.key, required this.group, this.size = 22});
  final String group;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = groupColors(group);
    if (colors.isEmpty) return const SizedBox.shrink();
    return SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: GroupRingPainter(colors)));
  }
}

/// Flutter's zero angle points right and positive angles run clockwise.
/// The second color therefore occupies exactly the lower-right quadrant.
class GroupRingPainter extends CustomPainter {
  const GroupRingPainter(this.colors, {this.strokeWidth = 2});
  final List<Color> colors;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawArc(
        rect,
        math.pi / 2,
        colors.length > 1 ? math.pi * 1.5 : math.pi * 2,
        false,
        paint..color = colors.first);
    if (colors.length > 1) {
      canvas.drawArc(rect, 0, math.pi / 2, false, paint..color = colors[1]);
    }
  }

  @override
  bool shouldRepaint(covariant GroupRingPainter oldDelegate) {
    if (oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.colors.length != colors.length) return true;
    for (var i = 0; i < colors.length; i++) {
      if (oldDelegate.colors[i] != colors[i]) return true;
    }
    return false;
  }
}

class GroupBadge extends StatelessWidget {
  const GroupBadge(
      {super.key, required this.group, this.size = 22, this.showLabel = false});
  final String group;
  final double size;
  final bool showLabel;
  static const colors = <String, Color>{
    'красно': Color(0xFFD75247),
    'сине': Color(0xFF3E7FD8),
    'бело': Color(0xFFF2EEE7),
    'коричнево': Color(0xFF9A6A43),
    'красная': Color(0xFFD75247),
    'синяя': Color(0xFF3E7FD8),
    'белая': Color(0xFFF2EEE7),
    'коричневая': Color(0xFF9A6A43),
  };

  @override
  Widget build(BuildContext context) {
    final actual = savedAccountGroup({'группа': group});
    if (actual == null) return const SizedBox.shrink();
    return Semantics(
        label:
            context.tr('Группа: {group}', args: {'group': context.tr(actual)}),
        child: ExcludeSemantics(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
          GroupRing(group: actual, size: size),
          if (showLabel) ...[
            const SizedBox(width: 7),
            Flexible(
              child: GroupNameText(group: actual, fontSize: size * .6),
            ),
          ],
        ])));
  }
}

/// A translated compound is split at its catalog separator, not by Russian
/// words. Saved group order determines which segment receives each color.
class GroupNameText extends StatelessWidget {
  const GroupNameText(
      {super.key, required this.group, this.fontSize = 13, this.prefixKey});
  final String group;
  final double fontSize;
  final String? prefixKey;

  @override
  Widget build(BuildContext context) {
    final actual = savedAccountGroup({'группа': group});
    if (actual == null) {
      return Text(group, style: TextStyle(fontSize: fontSize));
    }
    final palette = groupColors(actual);
    final translated = context.tr(actual);
    final base = TextStyle(
        color: DefaultTextStyle.of(context).style.color ?? Colors.white,
        fontSize: fontSize,
        fontWeight: FontWeight.w600);
    String before = '', after = '';
    if (prefixKey != null) {
      const marker = '\uFFFC';
      final template = context.tr(prefixKey!, args: {'group': marker});
      final index = template.indexOf(marker);
      if (index >= 0) {
        before = template.substring(0, index);
        after = template.substring(index + marker.length);
      }
    }
    final spans = <InlineSpan>[
      if (before.isNotEmpty) TextSpan(text: before, style: base)
    ];
    final separator =
        palette.length > 1 ? RegExp(r'[-–]').firstMatch(translated) : null;
    if (separator == null) {
      spans.add(TextSpan(
          text: translated, style: base.copyWith(color: palette.first)));
    } else {
      spans.add(TextSpan(
          text: translated.substring(0, separator.start),
          style: base.copyWith(color: palette.first)));
      spans.add(TextSpan(
          text: translated.substring(separator.start, separator.end),
          style: base));
      spans.add(TextSpan(
          text: translated.substring(separator.end),
          style: base.copyWith(color: palette[1])));
    }
    if (after.isNotEmpty) spans.add(TextSpan(text: after, style: base));
    return Text.rich(TextSpan(children: spans));
  }
}

class GroupCaption extends StatelessWidget {
  const GroupCaption(
      {super.key, required this.group, required this.own, this.gender = ''});
  final String group;
  final bool own;
  final String gender;

  @override
  Widget build(BuildContext context) {
    final actual = savedAccountGroup({'группа': group});
    if (actual == null) return const SizedBox.shrink();
    final normalizedGender = gender.trim().toLowerCase();
    final male = normalizedGender.startsWith('м') ||
        const {'m', 'male', 'man'}.contains(normalizedGender);
    final female = normalizedGender.startsWith('ж') ||
        const {'f', 'female', 'woman'}.contains(normalizedGender);
    final prefix = own
        ? 'Моя группа — {group}'
        : male
            ? 'Его группа — {group}'
            : female
                ? 'Её группа — {group}'
                : 'Группа: {group}';
    return GroupNameText(group: actual, prefixKey: prefix);
  }
}
