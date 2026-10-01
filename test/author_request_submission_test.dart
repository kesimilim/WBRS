import 'dart:async';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/pages/admin/role_requests.dart';
import 'package:wbrs/presentation/screens/feed/author_request_sheet.dart';
import 'package:wbrs/service/author_request_submission.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/submission_journal.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/layout_firebase_fakes.dart';
import 'support/memory_submission_journal.dart';

class _Storage extends Fake implements FirebaseStorage {}

class _Social extends SocialService {
  _Social(LayoutFirestore db, String? Function() uid)
      : super(firestore: db, storage: _Storage(), currentUid: uid);
  int uploads = 0;
  @override
  Future<String?> uploadImage(XFile? image,
      {required String folder, String? requestId}) async {
    if (image == null) return null;
    uploads++;
    return 'https://example.test/$folder/$requestId.jpg';
  }
}

class _WaitingSocial extends Fake implements SocialService {
  final gate = Completer<void>();
  int sends = 0;
  String? text, id;
  List<String> imagePaths = const [];
  @override
  Future<void> requestRole(String role,
      {String? proposedText, List<XFile> proposedImages = const [], String? requestId}) async {
    sends++;
    text = proposedText;
    id = requestId;
    imagePaths = proposedImages.map((e) => e.path).toList();
    await gate.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => firebaseAuth = LayoutAuth());

  test(
      'Author application requires a proposal and stores its text and image once',
      () async {
    final db = LayoutFirestore()
      ..documents['users/author-test'] = {'fullName': 'Автор'};
    addTearDown(db.close);
    final social = _Social(db, () => 'author-test');
    await expectLater(social.requestRole('author'), throwsArgumentError);
    expect(db.documents['author_requests/author-test'], isNull);
    await social.requestRole('author',
        proposedText: '  Семейные традиции  ',
        proposedImages: [XFile('/test-photo.jpg')],
        requestId: 'proposal-1');
    final saved = db.documents['author_requests/author-test']!;
    expect(saved['proposedText'], 'Семейные традиции');
    expect(saved['proposedImageUrl'],
        contains('author_applications/proposal-1_0.jpg'));
    expect(saved['proposedImages'], isA<List>());
    expect((saved['proposedImages'] as List).first,
        contains('author_applications/proposal-1_0.jpg'));
    expect(saved['status'], 'pending');
    expect(saved['proposalId'], 'proposal-1');
    await social.requestRole('author',
        proposedText: 'Повторный текст',
        proposedImages: [XFile('/test-photo.jpg')],
        requestId: 'proposal-1');
    expect(social.uploads, 1);
    expect(db.documents['author_requests/author-test']!['proposedText'],
        'Семейные традиции');
    db.documents['author_requests/author-test']!['status'] = 'rejected';
    await social.requestRole('author',
        proposedText: 'Исправленная публикация', requestId: 'proposal-2');
    expect(db.documents['author_requests/author-test']!['proposedText'],
        'Исправленная публикация');
  });

  test('Moderator application remains independent of author proposal',
      () async {
    final db = LayoutFirestore()
      ..documents['users/mod-test'] = {'fullName': 'Модератор'};
    addTearDown(db.close);
    await _Social(db, () => 'mod-test').requestRole('moderator');
    expect(db.documents['moderator_requests/mod-test']!['requestedRole'],
        'moderator');
    expect(
        db.documents['moderator_requests/mod-test']!
            .containsKey('proposedText'),
        isFalse);
  });

  test(
      'Pending proposal survives reopening without a second send and stays account-bound',
      () async {
    final social = _WaitingSocial();
    final journal = MemorySubmissionJournal();
    String? uid = 'reopen-author';
    final service = AuthorRequestSubmissionService(
        social: social, journal: journal, currentUid: () => uid);
    final request = service.start(text: 'Предложение');
    expect(await request.write.wait(timeout: const Duration(milliseconds: 1)),
        isFalse);
    final reopened = AuthorRequestSubmissionService(
        social: social, journal: journal, currentUid: () => uid);
    expect(await reopened.restore(), same(request));
    expect(reopened.start(text: 'Другой текст'), same(request));
    expect(social.sends, 1);
    uid = 'other-author';
    expect(() => reopened.start(text: 'Чужая заявка'), throwsStateError);
    final other = AuthorRequestSubmissionService(
        social: social, journal: journal, currentUid: () => uid);
    expect(await other.restore(), isNull);
    social.gate.complete();
    await request.write.wait();
  });

  test(
      'Durable proposal copies the selected image and reuses its journal identity',
      () async {
    final dir = await Directory.systemTemp.createTemp('clrs-author-request-');
    addTearDown(() => dir.delete(recursive: true));
    final photo = File('${dir.path}/selected.jpg');
    await photo.writeAsBytes([1, 2, 3]);
    final journal = SubmissionJournal(directory: () async => dir);
    final saved = await journal.prepare('disk-author', 'author-request',
        {'text': 'Сохранённая публикация'}, [XFile(photo.path)]);
    await photo.delete();
    final social = _WaitingSocial();
    final service = AuthorRequestSubmissionService(
        social: social, journal: journal, currentUid: () => 'disk-author');
    final request = await service.restore();
    expect(await request!.write.wait(timeout: const Duration(milliseconds: 1)),
        isFalse);
    expect(social.id, saved['id']);
    expect(social.text, 'Сохранённая публикация');
    expect(social.imagePaths, hasLength(1));
    expect(await File(social.imagePaths.first).readAsBytes(), [1, 2, 3]);
    social.gate.complete();
    expect(await request.write.wait(), isTrue);
    service.acknowledge(request);
    expect(await journal.load('disk-author', 'author-request'), isNull);
  });

  test('Session switch during preparation cannot send an author request',
      () async {
    String? uid = 'switch-author';
    final social = _WaitingSocial();
    final service = AuthorRequestSubmissionService(
        social: social,
        journal: MemorySubmissionJournal(),
        currentUid: () => uid);
    final request = service.start(text: 'Не отправлять от другого аккаунта');
    uid = 'other';
    await expectLater(request.write.wait(), throwsStateError);
    expect(social.sends, 0);
  });

  testWidgets(
      'Author sheet waits once, recovers after timeout and returns success',
      (tester) async {
    final social = _WaitingSocial();
    final service = AuthorRequestSubmissionService(
        social: social,
        journal: MemorySubmissionJournal(),
        currentUid: () => 'widget-author');
    bool? result;
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await showModalBottomSheet<bool>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) =>
                              AuthorRequestSheet(submissions: service));
                    },
                    child: const Text('Открыть'))))));
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.enterText(find.byType(TextField), 'Текст для одобрения');
    await tester.pump();
    await tester.ensureVisible(find.text('Отправить заявку'));
    await tester.tap(find.text('Отправить заявку'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.text('Проверить отправку'), findsOneWidget);
    expect(social.sends, 1);
    await tester.tap(find.text('Проверить отправку'));
    await tester.pump();
    expect(social.sends, 1);
    social.gate.complete();
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Admin preview preserves the proposed text on a narrow screen',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final text =
        List.filled(20, 'Предложенный автором текст без обрезки.').join(' ');
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        home: Scaffold(
            body: SingleChildScrollView(
                child: RoleRequestPreview(data: {'proposedText': text})))));
    await tester.pump();
    expect(find.text('Предлагаемая публикация'), findsOneWidget);
    expect(find.text(text), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
