import 'package:wbrs/service/post_submission.dart';
import 'support/memory_submission_journal.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/feed/feed_page.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/layout_firebase_fakes.dart';

class _Feed extends Fake implements SocialService {
  final db = LayoutFirestore();
  final controller =
      StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
  bool publish = false;
  int subscriptions = 0;
  int lastLimit = 0;
  int fetchedDocuments = 0;
  int fetchedQueries = 0;
  Object? olderError;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> rows = [];
  Object? likeError, shareError;
  Completer<bool>? likedGate;
  Completer<void>? postGate;
  Completer<void>? shareGate;
  int shares = 0;
  Completer<void>? likeGate;
  int likes = 0;
  bool current = true;
  @override
  bool get isCurrentSession => current;
  @override
  Future<bool> canPublish() async => publish;
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> feed({int limit = 40}) {
    subscriptions++;
    lastLimit = limit;
    return controller.stream.map((snapshot) =>
        LayoutQuerySnapshot(snapshot.docs.take(limit).toList()));
  }

  void emit(List<String> ids) {
    rows = [
        for (final id in ids)
          LayoutSnapshot(db, 'posts/$id', {
            'authorName': 'Автор $id',
            'text': 'Пост $id',
            'likeCount': 1,
            'shareCount': 0
          }),
      ];
    controller.add(LayoutQuerySnapshot(rows));
  }
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> feedOlder(
      DocumentSnapshot<Map<String, dynamic>> after,
      {int limit = 40}) async {
    if (olderError != null) throw olderError!;
    final index = rows.indexWhere((doc) => doc.id == after.id);
    final selected = rows.skip(index + 1).take(limit).toList();
    fetchedQueries++;
    fetchedDocuments += selected.length;
    return LayoutQuerySnapshot(selected);
  }
  @override
  Future<bool> isPostLiked(String postId) =>
      likedGate?.future ?? Future.value(postId == 'А');
  @override
  Future<void> togglePostLike(String postId) async {
    likes++;
    await likeGate?.future;
    if (likeError != null) throw likeError!;
  }

  @override
  Future<void> sharePost(String postId) async {
    shares++;
    await shareGate?.future;
    if (shareError != null) throw shareError!;
  }

  @override
  Future<void> createPost({required String text, List<XFile> images = const [], String? requestId}) async {
    await postGate?.future;
  }
}

Finder card(String id) => find.ancestor(
    of: find.text('Пост $id'),
    matching: find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_PostCard'));
Finder iconIn(String id, IconData icon) =>
    find.descendant(of: card(id), matching: find.byIcon(icon));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  late _Feed social;
  setUp(() {
    social = _Feed();
    firebaseFirestore = social.db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = LayoutMessaging();
  });
  tearDown(() async {
    await social.controller.close();
    await social.db.close();
  });
  Future<void> page(WidgetTester tester,
      {bool small = false, bool emitInitial = true}) async {
    if (small) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 320);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(small ? 2 : 1)),
            child: child!),
        home: FeedPage(social: social, postSubmissions: PostSubmissionService(social: social, journal: MemorySubmissionJournal(), currentUid: () => 'feed-test'))));
    if (emitInitial) {
      social.emit(['А']);
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('New feed item keeps its own like state after insertion',
      (tester) async {
    await page(tester);
    expect(iconIn('А', Icons.favorite), findsOneWidget);
    social.emit(['Б', 'А']);
    await tester.pumpAndSettle();
    expect(iconIn('Б', Icons.favorite_border), findsOneWidget);
    expect(iconIn('Б', Icons.favorite), findsNothing);
    expect(social.subscriptions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Feed requests older posts only after Load more', (tester) async {
    await page(tester);
    final posts = [for (var n = 0; n < 45; n++) '$n'];
    social.emit(posts);
    await tester.pumpAndSettle();
    expect(social.lastLimit, 41);
    var list = tester.widget<ListView>(find.byType(ListView));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).childCount, 83);
    await tester.scrollUntilVisible(find.text('Загрузить ещё'), 400,
        scrollable: find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    await tester.tap(find.text('Загрузить ещё'));
    await tester.pumpAndSettle();
    expect(social.lastLimit, 41);
    expect(social.fetchedDocuments, 5);
    expect(social.fetchedQueries, 1);
    expect(social.subscriptions, 1);
    list = tester.widget<ListView>(find.byType(ListView));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).childCount, 91);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Failed older feed page retries without losing posts',
      (tester) async {
    await page(tester);
    social.emit([for (var n = 0; n < 45; n++) '$n']);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Загрузить ещё'), 400,
        scrollable: find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    social.olderError = StateError('offline');
    await tester.tap(find.text('Загрузить ещё'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить публикации.'), findsOneWidget);
    social.olderError = null;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).childCount, 91);
    expect(social.fetchedQueries, 1);
    expect(social.subscriptions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Silent feed load offers retry after timeout', (tester) async {
    await page(tester, emitInitial: false);
    await tester.pump(const Duration(seconds: 21));
    expect(find.textContaining('Лента временно недоступна'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    social.emit(['Б']);
    await tester.pumpAndSettle();
    expect(find.text('Пост Б'), findsOneWidget);
    expect(social.subscriptions, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Failed feed like rolls back and failed share reports a readable error',
      (tester) async {
    social.likeError = StateError('network');
    social.shareError = StateError('network');
    await page(tester);
    await tester.tap(iconIn('А', Icons.favorite));
    await tester.pumpAndSettle();
    expect(iconIn('А', Icons.favorite), findsOneWidget);
    expect(find.text('Не удалось сохранить реакцию. Попробуйте ещё раз.'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    // Finish the snackbar reverse animation before interacting underneath it.
    await tester.pumpAndSettle();
    final share = iconIn('А', Icons.share_outlined);
    await tester.ensureVisible(share);
    expect(share.hitTestable(), findsOneWidget);
    await tester.tap(share);
    await tester.pumpAndSettle();
    await tester.tap(find.text('На моей странице'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось поделиться публикацией. Попробуйте ещё раз.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending post share recovers without a duplicate write', (tester) async {
    social.shareGate = Completer<void>();
    await page(tester);
    final share = iconIn('А', Icons.share_outlined);
    await tester.ensureVisible(share);
    await tester.tap(share);
    await tester.pumpAndSettle();
    await tester.tap(find.text('На моей странице'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.text('Проверить отправку'), findsOneWidget);
    expect(social.shares, 1);
    await tester.tap(find.text('Проверить отправку'));
    await tester.pump();
    expect(social.shares, 1);
    social.shareGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Публикация добавлена на вашу страницу'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending post like checks the same toggle after timeout', (tester) async {
    social.likeGate = Completer<void>();
    await page(tester);
    await tester.tap(iconIn('А', Icons.favorite));
    await tester.tap(iconIn('А', Icons.favorite));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.text('Проверить результат'), findsOneWidget);
    expect(social.likes, 1);
    final button = find.ancestor(of: iconIn('А', Icons.favorite_border),
        matching: find.byWidgetPredicate((w) => w is TextButton)).first;
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    // Let the timeout snackbar clear before tapping the control beneath it.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(iconIn('А', Icons.favorite_border));
    await tester.pump();
    expect(social.likes, 1);
    expect(iconIn('А', Icons.favorite_border), findsOneWidget);
    social.likeGate!.complete();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(iconIn('А', Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(social.likes, 2);
    expect(iconIn('А', Icons.favorite), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending post like late failure rolls back once', (tester) async {
    social.likeGate = Completer<void>();
    await page(tester);
    await tester.tap(iconIn('А', Icons.favorite));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    social.likeGate!.completeError(StateError('denied'));
    await tester.pump();
    await tester.tap(find.text('Проверить результат'));
    await tester.pumpAndSettle();
    expect(iconIn('А', Icons.favorite), findsOneWidget);
    expect(social.likes, 1);
    expect(find.text('Не удалось сохранить реакцию. Попробуйте ещё раз.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending post like ignores late failure after account change', (tester) async {
    social.likeGate = Completer<void>();
    await page(tester);
    await tester.tap(iconIn('А', Icons.favorite));
    await tester.pump();
    social.current = false;
    social.likeGate!.completeError(StateError('denied'));
    await tester.pumpAndSettle();
    await tester.tap(iconIn('А', Icons.favorite_border));
    await tester.pump();
    expect(social.likes, 1);
    expect(find.text('Не удалось сохранить реакцию. Попробуйте ещё раз.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending post like tolerates disposal before completion', (tester) async {
    social.likeGate = Completer<void>();
    await page(tester);
    await tester.tap(iconIn('А', Icons.favorite));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    social.likeGate!.complete();
    await tester.pumpAndSettle();
    expect(social.likes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Late initial like read cannot undo a newer successful reaction',
      (tester) async {
    social.likedGate = Completer<bool>();
    await page(tester);
    await tester.tap(iconIn('А', Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(iconIn('А', Icons.favorite), findsOneWidget);
    social.likedGate!.complete(false);
    await tester.pumpAndSettle();
    expect(iconIn('А', Icons.favorite), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Feed error retry restores real stream content', (tester) async {
    await page(tester);
    social.controller.addError(StateError('offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    social.emit(['Б']);
    await tester.pumpAndSettle();
    expect(find.text('Пост Б'), findsOneWidget);
    expect(social.subscriptions, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Create post sheet fits landscape large text and ignores late failure after close',
      (tester) async {
    social.publish = true;
    social.postGate = Completer<void>();
    await page(tester, small: true);
    await tester.tap(find.byTooltip('Новая публикация'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Публикация');
    await tester.ensureVisible(find.text('Опубликовать'));
    await tester.tap(find.text('Опубликовать'));
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    social.postGate!.completeError(StateError('late failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
