// Local disk and transactional boundaries; no production backend.
// ignore_for_file: subtype_of_sealed_class
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/service/comment_submission.dart';
import 'package:wbrs/service/post_submission.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/submission_journal.dart';
import 'support/layout_firebase_fakes.dart';

class _Storage extends Fake implements FirebaseStorage {}

class _Database extends LayoutFirestore {
  int missingReportReads = 0;
  int deniedReportUpdates = 0;
  bool denyReportCreates = false;

  @override
  Future<T> runTransaction<T>(TransactionHandler<T> handler,
      {Duration timeout = const Duration(seconds: 30),
      int maxAttempts = 5}) async {
    final tx = _Transaction(this);
    final value = await handler(tx);
    for (final operation in tx.operations) {
      operation();
    }
    commits++;
    return value;
  }
}

class _Transaction extends Fake implements Transaction {
  _Transaction(this.db);
  final _Database db;
  final operations = <void Function()>[];
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
          DocumentReference<T> ref) async {
    if (ref.path.startsWith('moderation_reports/') &&
        !db.documents.containsKey(ref.path)) {
      db.missingReportReads++;
      throw FirebaseException(
          plugin: 'cloud_firestore', code: 'permission-denied');
    }
    return LayoutSnapshot(db, ref.path, db.documents[ref.path])
        as DocumentSnapshot<T>;
  }
  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    operations.add(() {
      if (ref.path.startsWith('moderation_reports/')) {
        if (db.documents.containsKey(ref.path)) {
          db.deniedReportUpdates++;
          throw FirebaseException(
              plugin: 'cloud_firestore', code: 'permission-denied');
        }
        if (db.denyReportCreates) {
          throw FirebaseException(
              plugin: 'cloud_firestore', code: 'permission-denied');
        }
      }
      db.documents[ref.path] = Map<String, dynamic>.from(data as Map);
    });
    return this;
  }

  @override
  Transaction update(DocumentReference ref, Map<String, dynamic> data) {
    operations.add(() => db.documents[ref.path]!.addAll(data));
    return this;
  }

  @override
  Transaction delete(DocumentReference ref) {
    operations.add(() => db.documents.remove(ref.path));
    return this;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late _Database db;
  late SocialService social;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('clrs-social-recovery-');
    db = _Database();
    firebaseAuth = LayoutAuth();
    db.documents.addAll({
      'users/viewer': {
        'fullName': 'Local author',
        'role': 'author',
        'группа': 'красная'
      },
      'author_grants/viewer': {'status': 'approved'},
      'posts/example': {
        'authorUid': 'owner',
        'status': 'published',
        'commentCount': 0,
        'shareCount': 1
      },
    });
    social = SocialService(
        firestore: db, storage: _Storage(), currentUid: () => 'viewer');
  });
  tearDown(() async {
    await folder.delete(recursive: true);
    await db.close();
  });
  SubmissionJournal journal() =>
      SubmissionJournal(directory: () async => folder);

  test(
      'A new like produces one in-app notification and unlike preserves counts',
      () async {
    await social.togglePostLike('example');
    expect(db.documents['posts/example']!['likeCount'], 1);
    expect(
        db.documents['users/owner/notifications/reaction-example-post-viewer']
            ?['type'],
        'post_like');
    await social.togglePostLike('example');
    expect(db.documents['posts/example']!['likeCount'], 0);
    expect(
        db.documents.keys
            .where((key) => key.startsWith('users/owner/notifications/')),
        hasLength(1));
  });

  test('A reply notifies the parent author once after a repeated commit',
      () async {
    db.documents['posts/example/comments/root'] = {
      'authorUid': 'parent-author',
      'text': 'Parent'
    };
    await social.addComment(
        postId: 'example', text: 'Reply', parentId: 'root', requestId: 'reply');
    await social.addComment(
        postId: 'example', text: 'Reply', parentId: 'root', requestId: 'reply');
    expect(db.documents['posts/example']!['commentCount'], 1);
    final notice =
        db.documents['users/parent-author/notifications/comment-reply'];
    expect(notice?['type'], 'comment_reply');
    expect(notice?['rootCommentId'], 'root');
    expect(
        db.documents.keys
            .where((key) => key.startsWith('users/owner/notifications')),
        isEmpty);
  });

  test('A report retry preserves the original moderation status', () async {
    await social.reportPost('example');
    expect(db.missingReportReads, 0);
    db.documents['moderation_reports/post-example-viewer']!['status'] =
        'reviewed';
    await social.reportPost('example');
    expect(db.deniedReportUpdates, 1);
    expect(
        db.documents.keys.where((key) => key.startsWith('moderation_reports/')),
        hasLength(1));
    expect(db.documents['moderation_reports/post-example-viewer']!['status'],
        'reviewed');
  });

  test('A denied first post report is not mistaken for a retry', () async {
    db.denyReportCreates = true;
    await expectLater(social.reportPost('example'),
        throwsA(isA<FirebaseException>()));
    expect(db.missingReportReads, 0);
    expect(db.documents.containsKey('moderation_reports/post-example-viewer'),
        isFalse);
  });

  test('A comment report is queued once and keeps its review status', () async {
    db.documents['posts/example/comments/reply'] = {
      'authorUid': 'other', 'text': 'Comment to review',
    };
    await social.reportComment('example', 'reply');
    expect(db.missingReportReads, 0);
    final path = 'moderation_reports/comment-example-reply-viewer';
    expect(db.documents[path]?['entityType'], 'comment');
    expect(db.documents[path]?['entityId'], 'example/reply');
    db.documents[path]!['status'] = 'reviewed';
    await social.reportComment('example', 'reply');
    expect(db.deniedReportUpdates, 1);
    expect(db.documents[path]?['status'], 'reviewed');
    expect(db.documents.keys.where((key) => key.startsWith('moderation_reports/')),
        hasLength(1));
  });

  test('A denied first comment report is not mistaken for a retry', () async {
    db.documents['posts/example/comments/reply'] = {
      'authorUid': 'other', 'text': 'Comment to review',
    };
    db.denyReportCreates = true;
    await expectLater(social.reportComment('example', 'reply'),
        throwsA(isA<FirebaseException>()));
    expect(db.missingReportReads, 0);
    expect(db.documents.containsKey(
        'moderation_reports/comment-example-reply-viewer'), isFalse);
  });

  test('Only an administrator deletes a comment and its count once', () async {
    db.documents['posts/example']!['commentCount'] = 2;
    db.documents['posts/example/comments/reply'] = {
      'authorUid': 'other', 'text': 'Comment to remove',
    };
    await expectLater(
        social.deleteComment(postId: 'example', commentId: 'reply'),
        throwsStateError);    expect(db.documents['posts/example']!['commentCount'], 2);
    final admin = SocialService(
        firestore: db, storage: _Storage(), currentUid: () => 'viewer',
        moderatorAccess: () async => true);

    await admin.deleteComment(postId: 'example', commentId: 'reply');
    await admin.deleteComment(postId: 'example', commentId: 'reply');
    expect(db.documents.containsKey('posts/example/comments/reply'), isFalse);
    expect(db.documents['posts/example']!['commentCount'], 1);
  });

  test('Comment repost is idempotent and can be removed without deleting source',
      () async {
    db.documents['posts/example/comments/reply'] = {
      'authorUid': 'other',
      'text': 'A useful reply',
      'shareCount': 0,
    };
    await social.shareComment('example', 'reply');
    await social.shareComment('example', 'reply');
    final wallPath = 'users/viewer/wall/comment_7_example_reply';
    expect(db.documents[wallPath]?['sharedCommentId'], 'reply');
    expect(db.documents.keys.where((path) => path == wallPath), hasLength(1));
    // Local fake does not evaluate FieldValue.increment, so emulate its result.
    db.documents['posts/example/comments/reply']!['shareCount'] = 1;
    await social.removeCommentShare('example', 'reply');
    await social.removeCommentShare('example', 'reply');
    expect(db.documents.containsKey(wallPath), isFalse);
    expect(db.documents['posts/example/comments/reply']?['text'],
        'A useful reply');
  });

  test('Journal identity and photo survive new store and picker cache deletion',
      () async {
    final source = await File('${folder.path}/picker-photo')
        .writeAsBytes([1, 2, 3, 4], flush: true);
    final first = await journal().prepare(
        'viewer', 'comment/example', {'text': 'draft'}, [XFile(source.path)]);
    await source.delete();
    final saved = await journal().load('viewer', 'comment/example');
    expect(saved!['id'], first['id']);
    expect(
        await File(saved['imagePath'] as String).readAsBytes(), [1, 2, 3, 4]);
    expect(await journal().load('other', 'comment/example'), isNull);
    final replay = await journal()
        .prepare('viewer', 'comment/example', {'text': 'other'}, null);
    expect(replay['id'], first['id']);
    expect(replay['fields']['text'], 'draft');
  });

  test(
      'Rejected draft replacement copies persisted photo before replacing identity',
      () async {
    final photo = await File('${folder.path}/photo').writeAsBytes([7, 8, 9]);
    final first = await journal()
        .prepare('viewer', 'post', {'text': 'old'}, [XFile(photo.path)]);
    final firstPath = (first['imagePaths'] as List).first as String;
    final second = await journal().prepare(
        'viewer', 'post', {'text': 'new'}, [XFile(firstPath)],
        replaceRejected: true);
    expect(second['id'], isNot(first['id']));
    expect(await File(second['imagePath'] as String).readAsBytes(), [7, 8, 9]);
  });

  test(
      'Committed comment with unacknowledged journal recovers once after restart',
      () async {
    final saved = await journal().prepare('viewer', 'comment/example',
        {'text': 'One comment', 'parentId': null, 'replyName': null}, null);
    await social.addComment(
        postId: 'example',
        text: 'One comment',
        requestId: saved['id'] as String);
    // Simulate process death after commit, before local acknowledgement. No
    // in-memory CommentSubmission exists in this reconstructed service.
    final restarted = CommentSubmissionService(
        social: social, currentUid: () => 'viewer', journal: journal());
    final recovered = await restarted.restore('example');
    expect(recovered!.text, 'One comment');
    expect(await recovered.write.wait(), isTrue);
    restarted.acknowledge('example', recovered);
    expect(
        db.documents.keys.where((p) => p.startsWith('posts/example/comments/')),
        hasLength(1));
    expect(db.documents['posts/example']!['commentCount'], 1);
    expect(
        db.documents.keys
            .where((p) => p.startsWith('users/owner/notifications/')),
        hasLength(1));
    expect(await journal().load('viewer', 'comment/example'), isNull);
  });

  test(
      'Committed publication is reconciled from disk without overwriting reactions',
      () async {
    final saved =
        await journal().prepare('viewer', 'post', {'text': 'One post'}, null);
    await social.createPost(text: 'One post', requestId: saved['id'] as String);
    db.documents['posts/${saved['id']}']!['likeCount'] = 8;
    final restarted = PostSubmissionService(
        social: social, currentUid: () => 'viewer', journal: journal());
    final recovered = await restarted.restore();
    expect(await recovered!.write.wait(), isTrue);
    restarted.acknowledge(recovered);
    expect(db.documents['posts/${saved['id']}']!['likeCount'], 8);
    expect(
        db.documents.entries.where(
            (e) => e.key.startsWith('posts/') && e.value['text'] == 'One post'),
        hasLength(1));
    expect(await journal().load('viewer', 'post'), isNull);
  });

  test('Retry removing repost decrements once and preserves original',
      () async {
    db.documents['users/viewer/wall/example'] = {'sharedPostId': 'example'};
    await social.removeShare('example');
    await social.removeShare('example');
    expect(db.documents['posts/example']!['shareCount'], 0);
    expect(db.documents.containsKey('posts/example'), isTrue);
    expect(db.documents.containsKey('users/viewer/wall/example'), isFalse);
  });

  test('A deleted parent rejects reply before comment counter changes',
      () async {
    await expectLater(
        social.addComment(
            postId: 'example',
            text: 'reply',
            parentId: 'missing',
            requestId: 'stable-reply'),
        throwsStateError);
    expect(db.documents['posts/example']!['commentCount'], 0);
    expect(db.documents.containsKey('posts/example/comments/stable-reply'),
        isFalse);
  });
}
