import 'support/memory_submission_journal.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/presentation/screens/about_app/about_app.dart';
import 'package:wbrs/presentation/screens/feed/post_detail_page.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/comment_submission.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/meeting_location_fields.dart';

import 'support/layout_firebase_fakes.dart';

class _DocumentBundle extends CachingAssetBundle {
  int attempts = 0;
  bool fail = true;
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (key == 'qa-document') {
      attempts++;
      if (fail) throw FlutterError('temporary asset error');
      return List.filled(60, 'Проверяемый текст документа.').join('\n') +
          '\nКОНЕЦ ДОКУМЕНТА';
    }
    return rootBundle.loadString(key, cache: cache);
  }
}

class _Comments extends Fake implements SocialService {
  final controller =
      StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
  final db = LayoutFirestore();
  int subscriptions = 0;
  int sends = 0;
  int likes = 0;
  String? sentParent;
  String? sentText;
  Completer<void>? sendGate;
  Completer<void>? shareGate;
  Completer<void>? likeGate;
  bool current = true;
  @override
  bool get isCurrentSession => current;
  @override
  Future<bool> canModerateComments() async => false;
  int shares = 0;
  Object? sendError;
  Object? likeError;
  Object? streamError;
  final rows = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> comments(String postId) {
    subscriptions++;
    if (streamError != null) throw streamError!;
    return controller.stream;
  }

  void root({String name = 'Автор'}) {
    rows.add(LayoutSnapshot(db, 'posts/post/comments/root', {
      'authorName': name,
      'text': 'Корневой комментарий',
      'likeCount': 1000,
    }));
    rows.add(LayoutSnapshot(db, 'posts/post/comments/old-reply', {
      'authorName': 'Другой автор',
      'text': 'Ранее скрытый ответ',
      'parentId': 'root',
    }));
    emit();
  }

  void emit() => controller.add(LayoutQuerySnapshot(List.of(rows)));
  @override
  Future<void> addComment(
      {required String postId,
      required String text,
      String? parentId,
      List<XFile> images = const [],
      String? requestId}) async {
    sends++;
    sentParent = parentId;
    sentText = text;
    if (sendGate != null) await sendGate!.future;
    if (sendError != null) throw sendError!;
    rows.add(LayoutSnapshot(db, 'posts/post/comments/new-reply', {
      'authorName': 'Я',
      'text': text,
      'parentId': parentId,
    }));
    emit();
  }

  @override
  Future<void> toggleCommentLike(String postId, String commentId) async {
    likes++;
    await likeGate?.future;
    if (likeError != null) throw likeError!;
  }

  @override
  Future<void> shareComment(String postId, String commentId) async {
    shares++;
    await shareGate?.future;
  }

  Future<void> close() => controller.close();
}

class _Storage extends Fake implements FirebaseStorage {}

class _CommentDatabase extends LayoutFirestore {
  @override
  Future<T> runTransaction<T>(TransactionHandler<T> transactionHandler,
      {Duration timeout = const Duration(seconds: 30),
      int maxAttempts = 5}) async {
    final tx = _CommentTransaction(this);
    final result = await transactionHandler(tx);
    for (final operation in tx.operations) {
      operation();
    }
    commits++;
    return result;
  }
}

class _CommentTransaction extends Fake implements Transaction {
  _CommentTransaction(this.db);
  final _CommentDatabase db;
  final operations = <void Function()>[];
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
          DocumentReference<T> ref) async =>
      LayoutSnapshot(db, ref.path, db.documents[ref.path])
          as DocumentSnapshot<T>;
  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    operations.add(
        () => db.documents[ref.path] = Map<String, dynamic>.from(data as Map));
    return this;
  }

  @override
  Transaction update(DocumentReference ref, Map<String, dynamic> data) {
    operations.add(() => db.documents[ref.path]!.addAll(data));
    return this;
  }
}

class _CommentService extends SocialService {
  _CommentService(_CommentDatabase db, {String? Function()? uid})
      : super(
            firestore: db,
            storage: _Storage(),
            currentUid: uid ?? (() => 'writer'));
  int notificationAttempts = 0;
  Completer<void>? notificationGate;
  Object? notificationError;
  @override
  Future<void> addNotification(
      {required String userUid,
      required String type,
      required String title,
      required String body,
      String? entityId,
      String? notificationId,
      String? actorName,
      String? actorPhoto,
      String? rootCommentId}) async {
    notificationAttempts++;
    if (notificationGate != null) await notificationGate!.future;
    if (notificationError != null) throw notificationError!;
  }
}

Widget _app(Widget child, {double scale = 1, double keyboard = 0}) =>
    MaterialApp(
      theme: LrsTheme.theme,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: child!),
      home: child,
    );

int _sessionId = 0;
Finder _sendButton() => find.byWidgetPredicate((widget) =>
    widget is IconButton &&
    (widget.tooltip == 'Отправить комментарий' ||
        widget.tooltip == 'Проверить отправку'));

Future<void> _findReply(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.text('Ответить'), 150,
      scrollable: find
          .descendant(
              of: find.byType(ListView), matching: find.byType(Scrollable))
          .first);
  await tester.pumpAndSettle();
}

Future<void> _commentsPage(WidgetTester tester, _Comments service,
    {double scale = 1,
    double keyboard = 0,
    CommentSubmissionService? submissions}) async {
  final sessionUid = 'test-${_sessionId++}';
  await tester.pumpWidget(_app(
      PostDetailPage(
          postId: 'post',
          post: const {'authorName': 'CLRS', 'text': 'Публикация'},
          social: service,
          submissions: submissions ??
              CommentSubmissionService(
                  journal: MemorySubmissionJournal(),
                  social: service,
                  currentUid: () => sessionUid)),
      scale: scale,
      keyboard: keyboard));
  service.root();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');

  for (final throwsError in [false, true]) {
    testWidgets(
        'Mail fallback for ${throwsError ? 'PlatformException' : 'missing app'} can copy address',
        (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(launcher, (call) async {
        if (throwsError) throw PlatformException(code: 'missing-handler');
        return false;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(launcher, null));
      await tester.pumpWidget(_app(Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => openSupportEmail(context),
                  child: const Text('Связаться'))))));
      await tester.tap(find.text('Связаться'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('supp.lrs@ya.ru'), findsOneWidget);
      await tester.tap(find.text('Копировать адрес'));
      await tester.pumpAndSettle();
      expect(copied, 'supp.lrs@ya.ru');
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Document failure can retry and scroll to the end',
      (tester) async {
    final bundle = _DocumentBundle();
    await tester.pumpWidget(_app(DefaultAssetBundle(
        bundle: bundle,
        child:
            const ClrsDocumentPage(title: 'Документ', asset: 'qa-document'))));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить документ.'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить документ.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    bundle.fail = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(bundle.attempts, 3);
    expect(find.byType(SelectableText), findsOneWidget);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
        find
            .text('Настоящие люди · Общие ценности\nРеальные отношения')
            .hitTestable(),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Every legal asset loads as real selectable text',
      (tester) async {
    for (final asset in ['rules', 'agreement', 'policy', 'offer']) {
      final text = await tester
          .runAsync(() => rootBundle.loadString('assets/$asset.txt'));
      expect(text!.length, greaterThan(100));
      await tester.runAsync(() async {
        await tester.pumpWidget(
            _app(ClrsDocumentPage(title: asset, asset: 'assets/$asset.txt')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
          text);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'Unknown legacy country is safe; switching country clears incompatible region',
      (tester) async {
    final countries = (await tester.runAsync(GeoCatalog.load))!;
    GeoCountry? chosen;
    String? region;
    await tester.pumpWidget(_app(Scaffold(
        body: MeetingLocationFields(
            countryCode: 'legacy',
            region: 'старый город',
            onChanged: (country, selectedRegion) {
              chosen = country;
              region = selectedRegion;
            }))));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
    final countryField = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).first);
    countryField.onChanged!('RU');
    await tester.pumpAndSettle();
    final regionField = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).last);
    regionField.onChanged!(GeoCatalog.byCode(countries, 'RU')!.regions.first);
    await tester.pumpAndSettle();
    expect(region, isNotNull);
    countryField.onChanged!('US');
    await tester.pumpAndSettle();
    expect(chosen!.code, 'US');
    expect(region, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Separate comment thread excludes other roots and returns to the discussion',
      (tester) async {
    final social = _Comments();
    addTearDown(social.close);
    await _commentsPage(tester, social);
    social.rows.add(LayoutSnapshot(social.db, 'posts/post/comments/unrelated',
        {'authorName': 'Other', 'text': 'Unrelated root'}));
    social.emit();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Открыть ветку').first, 120,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Открыть ветку').first);
    await tester.pump();
    social.emit();
    await tester.pumpAndSettle();
    expect(find.text('Ветка комментариев'), findsOneWidget);
    expect(find.text('Корневой комментарий'), findsOneWidget);
    expect(find.text('Ранее скрытый ответ'), findsOneWidget);
    expect(find.text('Unrelated root'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Ветка комментариев'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Reply to collapsed thread becomes discoverable; rebuilds retain subscription',
      (tester) async {
    final social = _Comments();
    addTearDown(social.close);
    await _commentsPage(tester, social);
    expect(find.text('Ранее скрытый ответ'), findsNothing);
    await _findReply(tester);
    await tester.tap(find.text('Ответить').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Новый ответ');
    await tester.tap(find.byTooltip('Отправить комментарий'));
    await tester.pumpAndSettle();
    expect(social.sentParent, 'root');
    await tester.scrollUntilVisible(find.text('Новый ответ'), 120,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    expect(find.text('Новый ответ'), findsOneWidget);
    expect(find.text('Ранее скрытый ответ'), findsOneWidget);
    expect(find.text('Скрыть ответы'), findsOneWidget);
    expect(social.subscriptions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Failed send preserves text and parent and rapid taps send once',
      (tester) async {
    final social = _Comments()
      ..sendGate = Completer<void>()
      ..sendError = StateError('Нет сети');
    addTearDown(social.close);
    await _commentsPage(tester, social);
    await _findReply(tester);
    await tester.tap(find.text('Ответить').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Сохранить черновик');
    final send = tester.widget<IconButton>(_sendButton()).onPressed!;
    send();
    send();
    await tester.pump();
    expect(social.sends, 1);
    social.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Сохранить черновик');
    expect(find.text('Ответ для Автор'), findsOneWidget);
    expect(tester.widget<IconButton>(_sendButton()).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Completing send after navigation does not use a disposed controller',
      (tester) async {
    final social = _Comments()..sendGate = Completer<void>();
    addTearDown(social.close);
    await _commentsPage(tester, social);
    await tester.enterText(find.byType(TextField), 'Сообщение');
    await tester.tap(find.byTooltip('Отправить комментарий'));
    await tester.pump();
    await tester.pumpWidget(_app(const Scaffold(body: Text('Другой экран'))));
    social.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending comment share recovers without a duplicate write', (tester) async {
    final social = _Comments()..shareGate = Completer<void>();
    addTearDown(social.close);
    await _commentsPage(tester, social);
    await _findReply(tester);
    await tester.tap(find.text('Поделиться').first);
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
    expect(find.text('Комментарий добавлен на вашу страницу'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Comment stream and reaction failures are recoverable',
      (tester) async {
    final social = _Comments()..likeError = StateError('permission denied');
    addTearDown(social.close);
    await _commentsPage(tester, social);
    await _findReply(tester);
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pumpAndSettle();
    expect(find.text('Не удалось сохранить реакцию. Попробуйте ещё раз.'),
        findsOneWidget);
    social.controller.addError(StateError('offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    social.emit();
    await tester.pumpAndSettle();
    expect(find.text('Корневой комментарий'), findsOneWidget);
    expect(social.subscriptions, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending comment like checks the same toggle after timeout', (tester) async {
    final social = _Comments()..likeGate = Completer<void>();
    addTearDown(social.close);
    await _commentsPage(tester, social);
    await _findReply(tester);
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(social.likes, 1);
    expect(find.text('Проверить результат'), findsOneWidget);
    final button = find.ancestor(of: find.byIcon(Icons.favorite_border).first,
        matching: find.byWidgetPredicate((w) => w is TextButton)).first;
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    await tester.tap(find.text('Проверить результат'));
    await tester.pump();
    expect(social.likes, 1);
    social.likeGate!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pumpAndSettle();
    expect(social.likes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending comment like late failure remains retryable', (tester) async {
    final social = _Comments()..likeGate = Completer<void>();
    addTearDown(social.close);
    await _commentsPage(tester, social);
    await _findReply(tester);
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    social.likeGate!.completeError(StateError('denied'));
    await tester.pump();
    await tester.tap(find.text('Проверить результат'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось сохранить реакцию. Попробуйте ещё раз.'), findsOneWidget);
    expect(social.likes, 1);
    final button = find.ancestor(of: find.byIcon(Icons.favorite_border).first,
        matching: find.byWidgetPredicate((w) => w is TextButton)).first;
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending comment like ignores late failure after account change', (tester) async {
    final social = _Comments()..likeGate = Completer<void>();
    addTearDown(social.close);
    await _commentsPage(tester, social);
    await _findReply(tester);
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump();
    social.current = false;
    social.likeGate!.completeError(StateError('denied'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump();
    expect(social.likes, 1);
    expect(find.text('Не удалось сохранить реакцию. Попробуйте ещё раз.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending comment like tolerates disposal before completion', (tester) async {
    final social = _Comments()..likeGate = Completer<void>();
    addTearDown(social.close);
    await _commentsPage(tester, social);
    await _findReply(tester);
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump();
    await tester.pumpWidget(_app(const SizedBox()));
    social.likeGate!.complete();
    await tester.pumpAndSettle();
    expect(social.likes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Synchronous stream failure displays retry without a build crash',
      (tester) async {
    final social = _Comments()..streamError = StateError('session expired');
    addTearDown(social.close);
    await _commentsPage(tester, social);
    expect(find.text('Не удалось загрузить комментарии.'), findsOneWidget);
    social.streamError = null;
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    social.emit();
    await tester.pumpAndSettle();
    expect(find.text('Корневой комментарий'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Timed out comment survives navigation and checks the same request',
      (tester) async {
    final social = _Comments()..sendGate = Completer<void>();
    addTearDown(social.close);
    final service = CommentSubmissionService(
        journal: MemorySubmissionJournal(),
        social: social,
        currentUid: () => 'retained-comment-test');
    await _commentsPage(tester, social, submissions: service);
    await _findReply(tester);
    await tester.tap(find.text('Ответить').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Единственный ответ');
    await tester.tap(_sendButton());
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(social.sends, 1);
    expect(
        find.textContaining('Подтверждение ещё не получено'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(
        tester.widget<IconButton>(_sendButton()).tooltip, 'Проверить отправку');
    await tester.pumpWidget(_app(const Scaffold(body: Text('Другой экран'))));
    await tester.pumpWidget(_app(PostDetailPage(
        postId: 'post', post: const {}, social: social, submissions: service)));
    social.emit();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Единственный ответ');
    expect(find.text('Ответ для Автор'), findsOneWidget);
    await tester.tap(_sendButton());
    await tester.pump();
    expect(social.sends, 1);
    social.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(service.pending('post'), isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(find.text('Скрыть ответы'), findsOneWidget);
    expect(social.sends, 1);
    expect(tester.takeException(), isNull);
  });

  test('Pending comments are isolated by account and reject changed sessions',
      () async {
    final social = _Comments()..sendGate = Completer<void>();
    String? uid = 'pending-account-one';
    final first = CommentSubmissionService(
        journal: MemorySubmissionJournal(),
        social: social,
        currentUid: () => uid);
    final request = first.start(postId: 'post', text: 'Личный черновик');
    uid = 'pending-account-two';
    final second = CommentSubmissionService(
        journal: MemorySubmissionJournal(),
        social: social,
        currentUid: () => uid);
    expect(second.pending('post'), isNull);
    expect(
        () => first.start(postId: 'post', text: 'Ещё раз'), throwsStateError);
    social.sendGate!.complete();
    await expectLater(request.write.wait(), throwsStateError);
    expect(social.sends, 0);
    uid = 'pending-account-one';
    first.acknowledge('post', request);
    await social.close();
  });

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.3, 2.0]) {
      for (final landscape in [false, true]) {
        testWidgets(
            'Comments ${width.toInt()}dp text $scale ${landscape ? 'landscape keyboard' : 'portrait'} remain scrollable',
            (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize =
              landscape ? Size(844, width) : Size(width, 844);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final social = _Comments();
          addTearDown(social.close);
          await _commentsPage(tester, social,
              scale: scale, keyboard: landscape ? 100 : 0);
          await _findReply(tester);
          await tester.tap(find.text('Ответить').first);
          await tester.pumpAndSettle();
          await tester.enterText(
              find.byType(TextField), 'Очень длинный текст комментария ' * 8);
          await tester.pumpAndSettle();
          expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              'Очень длинный текст комментария ' * 8);
          await tester.ensureVisible(find.byTooltip('Отправить комментарий'));
          expect(find.byTooltip('Отправить комментарий').hitTestable(),
              findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  _CommentDatabase database() => _CommentDatabase()
    ..documents.addAll({
      'users/writer': {'fullName': 'Автор', 'profilePic': ''},
      'posts/post': {'authorUid': 'owner', 'commentCount': 4},
    });

  test('Deleted post cannot report a successfully saved comment', () async {
    final db = database()..documents.remove('posts/post');
    final service = _CommentService(db);
    await expectLater(
        service.addComment(postId: 'post', text: 'Ответ'), throwsStateError);
    expect(db.commits, 0);
    expect(
        db.documents.keys.where((key) => key.contains('/comments/')), isEmpty);
    expect(service.notificationAttempts, 0);
  });

  test(
      'Notification failure after commit does not turn saved comment into a send failure',
      () async {
    final db = database();
    final service = _CommentService(db)
      ..notificationError = StateError('permission denied');
    db.documents['posts/post/comments/root'] = {'authorUid': 'owner'};
    await service.addComment(postId: 'post', text: ' Ответ ', parentId: 'root');
    expect(db.commits, 1);
    final comments = db.documents.entries
        .where((entry) =>
            entry.key.contains('/comments/') &&
            entry.key != 'posts/post/comments/root')
        .toList();
    expect(comments, hasLength(1));
    expect(comments.single.value['text'], 'Ответ');
    expect(comments.single.value['parentId'], 'root');
    expect(db.documents['posts/post']!['commentCount'], 5);
    expect(service.notificationAttempts, 1);
  });

  testWidgets(
      'Slow post-commit notification has bounded wait without resubmitting comment',
      (tester) async {
    final db = database();
    final service = _CommentService(db)..notificationGate = Completer<void>();
    var completed = false;
    service
        .addComment(postId: 'post', text: 'Ответ')
        .then((_) => completed = true);
    await tester.pump();
    expect(db.commits, 1);
    expect(completed, isFalse);
    await tester.pump(const Duration(seconds: 11));
    expect(completed, isTrue);
    expect(db.commits, 1);
    service.notificationGate!.complete();
    await tester.pump();
  });

  test('Changed session rejects comment before any write', () async {
    final db = database();
    String? uid = 'writer';
    final service = _CommentService(db, uid: () => uid);
    uid = 'other';
    await expectLater(
        service.addComment(postId: 'post', text: 'Ответ'), throwsStateError);
    expect(db.commits, 0);
    expect(service.notificationAttempts, 0);
  });
}
