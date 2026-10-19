import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/shared/clrs_background.dart';
import 'package:wbrs/shared/clrs_screen.dart';

void main() {
  testWidgets('ClrsBackgroundController changes images every 5 seconds seamlessly', (tester) async {
    final controller = ClrsBackgroundController.instance;
    controller.startTimer();

    final initialIndex = controller.currentIndex;
    final initialImage = controller.currentImage;

    await tester.pumpWidget(
      const MaterialApp(
        home: ClrsScaffold(
          body: Text('Screen A'),
        ),
      ),
    );

    expect(find.text('Screen A'), findsOneWidget);

    // Advance 5 seconds
    await tester.pump(const Duration(seconds: 5));
    expect(controller.currentIndex, isNot(equals(initialIndex)));
    expect(controller.currentImage, isNot(equals(initialImage)));

    final secondImage = controller.currentImage;

    // Navigate to Screen B
    await tester.pumpWidget(
      const MaterialApp(
        home: ClrsScaffold(
          body: Text('Screen B'),
        ),
      ),
    );

    expect(find.text('Screen B'), findsOneWidget);
    // Background index should be preserved across screen navigation
    expect(controller.currentImage, equals(secondImage));

    // Advance another 5 seconds
    await tester.pump(const Duration(seconds: 5));
    expect(controller.currentImage, isNot(equals(secondImage)));

    controller.stopTimer();
  });
}
