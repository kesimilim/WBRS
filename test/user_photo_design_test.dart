import 'dart:io';
import 'dart:ui' as ui;

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/localization/language_picker.dart';
import 'package:wbrs/presentation/screens/about_app/about_app.dart';
import 'package:wbrs/presentation/screens/profile/profile_page.dart';
import 'package:wbrs/presentation/screens/shop/shop.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/layout_firebase_fakes.dart';

const _captureKey = Key('photo-design-capture');

Finder _panelWith(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(ClrsPanel)).first;

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('/tmp/clrs-user-photo-design-proof');
      await folder.create(recursive: true);
      await File(
        '${folder.path}/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    for (final font in {
      'MaterialIcons': ['fonts/MaterialIcons-Regular.otf'],
      'Lato': ['assets/fonts/Lato-Regular.ttf', 'assets/fonts/Lato-Bold.ttf'],
      'CormorantGaramond': ['assets/fonts/CormorantGaramond-Variable.ttf'],
      'Caveat': ['assets/fonts/Caveat-Variable.ttf'],
    }.entries) {
      final loader = FontLoader(font.key);
      for (final path in font.value) {
        loader.addFont(rootBundle.load(path));
      }
      await loader.load();
    }
  });

  testWidgets(
    'photo 2/3/6 layouts and global bottom navigation match approved controls',
    (tester) async {
      final db = LayoutFirestore();
      firebaseFirestore = db;
      firebaseAuth = LayoutAuth();
      firebaseMessaging = LayoutMessaging();
      selectedIndex = 4;
      db.documents['users/viewer'] = {
        'fullName': 'Участник',
        'balance': 380,
        'isUnVisible': false,
        'gifts': <String, int>{},
        'notificationPreferences': {
          'messages': true,
          'meetings': true,
          'sound': false,
        },
      };
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> open(Widget page) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: _captureKey,
            child: MaterialApp(
              key: UniqueKey(),
              debugShowCheckedModeBanner: false,
              theme: LrsTheme.theme,
              home: page,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
      }

      try {
        await open(const About_App());
        final aboutFrame = tester.widget<ClrsScaffold>(
          find.byType(ClrsScaffold),
        );
        expect(aboutFrame.backgroundAsset, 'assets/family_main.jpg');
        expect(aboutFrame.backgroundScale, 1.42);
        final policyWidths = [
          'Политика конфиденциальности',
          'Пользовательское соглашение',
          'Публичная оферта',
          'Правила использования',
        ].map((text) => tester.getSize(_panelWith(text)).width).toList();
        for (final width in policyWidths) {
          expect(width, closeTo((360 - 28) * .64, .1));
        }
        final versionWidth = tester
            .getSize(_panelWith('Версия приложения'))
            .width;
        expect(versionWidth, greaterThan(policyWidths.first));
        expect(
          tester.getSize(_panelWith('Обратная связь')).width,
          versionWidth,
        );
        final language = find.byType(LanguagePickerButton);
        await tester.ensureVisible(language);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(_panelWith('Язык')).width,
          greaterThan(versionWidth),
        );
        expect(find.text('Русский'), findsOneWidget);
        expect(tester.widget<LanguagePickerButton>(language).showIcon, isFalse);
        // Capture the complete initial composition after returning to its top.
        await tester.drag(find.byType(ListView), const Offset(0, 700));
        await tester.pumpAndSettle();
        await _capture(tester, 'about-360');
        expect(find.textContaining('Поддержать'), findsNothing);
        expect(
          tester
              .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
              .items,
          hasLength(5),
        );
        expect(
          tester.getSize(find.byType(MyBottomNavigationBar)).height,
          lessThan(60),
        );
        expect(tester.takeException(), isNull);

        await open(const ProfileSettingsPage());
        expect(
          tester
              .widget<ClrsScaffold>(find.byType(ClrsScaffold))
              .backgroundScale,
          1,
        );
        for (final text in [
          'Личные данные',
          'Сменить пароль',
          'Конфиденциальность',
        ]) {
          expect(tester.getSize(_panelWith(text)).width, closeTo(328, .1));
        }
        expect(find.text('Аккаунт'), findsOneWidget);
        expect(find.text('Уведомления'), findsOneWidget);
        expect(find.text('Помощь'), findsOneWidget);
        expect(find.byType(SwitchListTile), findsNWidgets(3));
        expect(
          tester
              .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Сообщения'),
              )
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Встречи'),
              )
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Звук уведомлений'),
              )
              .value,
          isFalse,
        );
        expect(find.byType(LanguagePickerButton), findsNothing);
        expect(find.byType(ClrsValuesFooter), findsNothing);
        expect(find.text('Выйти из аккаунта'), findsOneWidget);
        await _capture(tester, 'settings-360');
        expect(tester.takeException(), isNull);
        // Language remains reachable through the reference's Help/About row.
        await tester.tap(find.text('О приложении'));
        await tester.pumpAndSettle();
        expect(find.byType(About_App), findsOneWidget);
        await tester.ensureVisible(find.byType(LanguagePickerButton));
        await tester.tap(find.text('Русский'));
        await tester.pumpAndSettle();
        expect(find.text('English'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await open(const ShopPage());
        expect(
          tester
              .widget<ClrsScaffold>(find.byType(ClrsScaffold))
              .backgroundScale,
          1,
        );
        final logo = tester.widget<Text>(
          find.byKey(const ValueKey('gift-store-logo')),
        );
        expect(logo.style!.fontFamily, 'Lato');
        expect(logo.style!.fontWeight, FontWeight.w900);
        expect(logo.style!.fontStyle, FontStyle.italic);
        expect(
          find.text('Дарите внимание.\nСоздавайте особенные моменты.'),
          findsOneWidget,
        );
        expect(find.textContaining('Поддержать'), findsNothing);
        await _capture(tester, 'gift-store-360');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await db.close();
      }
    },
  );
}
