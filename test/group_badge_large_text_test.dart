import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/core/utils/compatibility.dart';
import 'package:wbrs/shared/group_badge.dart';
import 'package:wbrs/shared/lrs_theme.dart';

void main() {
  testWidgets('profile group labels retain full text and colors at 1x and 2x', (
    tester,
  ) async {
    final groups = getListOfGroup('коричнево-красная');
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 306.4,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final group in groups)
                        GroupBadge(
                          key: ValueKey(group),
                          group: group,
                          size: 24,
                          showLabel: true,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final group in groups) {
        final badge = find.byKey(ValueKey(group));
        final text = find.descendant(
          of: badge,
          matching: find.byType(RichText),
        );
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.text.toPlainText(), group);
        expect(paragraph.didExceedMaxLines, isFalse);
        final label = tester.widget<Text>(
          find.descendant(of: badge, matching: find.byType(Text)),
        );
        final pieces = (label.textSpan! as TextSpan).children!.cast<TextSpan>();
        final palette = groupColors(group);
        expect(pieces.first.style!.color, palette.first);
        expect(pieces.last.style!.color, palette.last);
        final ring = find.descendant(
          of: badge,
          matching: find.byType(GroupRing),
        );
        expect(tester.getSize(ring), const Size(24, 24));
        expect(tester.getSize(badge).width, lessThanOrEqualTo(306.4));
        final paragraphBounds = tester.getRect(text);
        final badgeBounds = tester.getRect(badge);
        expect(
          paragraphBounds.right,
          lessThanOrEqualTo(badgeBounds.right + .01),
        );
        if (scale == 1) {
          final natural = TextPainter(
            text: paragraph.text,
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.linear(1),
          )..layout();
          expect(
            tester.getSize(badge).width,
            closeTo(24 + 7 + natural.width, .05),
          );
          natural.dispose();
        }
      }
      if (scale == 2) {
        final longest = find.byKey(const ValueKey('коричнево-красная'));
        expect(tester.getSize(longest).height, greaterThan(24));
      }
    }
  });
}
