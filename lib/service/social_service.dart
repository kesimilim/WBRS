import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/service/admin_access.dart';
import 'package:wbrs/service/push_language_sync.dart';

class SocialService {
  SocialService(
      {FirebaseFirestore? firestore,
      FirebaseStorage? storage,
      String? Function()? currentUid,
      Future<bool> Function()? moderatorAccess,
      // Enable only after the server triggers and compatible rules are live.
      bool serverSocialNotices = serverSocialNoticesEnabled})
      : _db = firestore ?? firebaseFirestore,
        _storage = storage ?? FirebaseStorage.instance,
        _currentUid = currentUid ?? (() => firebaseAuth.currentUser?.uid),
        _moderatorAccess = moderatorAccess ?? _claimAdmin,
        _serverSocialNotices = serverSocialNotices {
    _ownerUid = _currentUid();
  }

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;
  final bool _serverSocialNotices;

  final String? Function() _currentUid;
  final Future<bool> Function() _moderatorAccess;
  static Future<bool> _claimAdmin() async {
    final user = firebaseAuth.currentUser;
    if (user == null) return false;
    if (await AdminAccess.current()) return true;
    try {
      final token = await user.getIdTokenResult(true);
      return firebaseAuth.currentUser?.uid == user.uid &&
          token.claims?['admin'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> canModerateComments() async {
    final uid = _uid;
    return await _moderatorAccess() && _uid == uid;
  }
  late final String? _ownerUid;
  bool get isCurrentSession => _ownerUid != null && _currentUid() == _ownerUid;
  String get _uid {
    final uid = _ownerUid;
    if (uid == null || _currentUid() != uid) {
      throw StateError('Сеанс завершён. Войдите снова');
    }
    return uid;
  }

  // Keep an unresolved toggle across screen/service instances. Repeating it
  // could otherwise remove the reaction whose first commit is still pending.
  static final _pendingLikes = <(String, String, String?), Future<void>>{};

  Future<void> _retainLike(String postId, String? commentId,
      Future<void> Function() write) {
    final String uid;
    try {
      uid = _uid;
    } catch (error, stack) {
      // Preserve the async method contract for callers after logout.
      return Future<void>.error(error, stack);
    }
    final key = (uid, postId, commentId);
    final pending = _pendingLikes[key];
    if (pending != null) return pending;
    final operation = Future<void>.sync(write);
    _pendingLikes[key] = operation;
    void release() {
      if (identical(_pendingLikes[key], operation)) _pendingLikes.remove(key);
    }
    operation.then<void>((_) => release(), onError: (Object _, StackTrace __) {
      release();
    });
    return operation;
  }

  static String _friendName(Map<String, dynamic> profile) {
    final nickname = profile['nickName']?.toString().trim() ?? '';
    return nickname.isNotEmpty
        ? nickname
        : profile['fullName']?.toString().trim() ?? '';
  }

  CollectionReference<Map<String, dynamic>> get posts =>
      _db.collection('posts');

  Query<Map<String, dynamic>> get _publishedPosts => posts
        .where('status', isEqualTo: 'published')
        .orderBy('createdAt', descending: true);

  Stream<QuerySnapshot<Map<String, dynamic>>> feed({int limit = 40}) =>
      _publishedPosts.limit(limit).snapshots();

  Future<QuerySnapshot<Map<String, dynamic>>> feedOlder(
      DocumentSnapshot<Map<String, dynamic>> after,
      {int limit = 40}) async {
    _uid;
    final page = await _publishedPosts
        .startAfterDocument(after)
        .limit(limit)
        .get();
    _uid;
    return page;
  }

  Future<bool> canPublish() async {
    final uid = _uid;
    if (await AdminAccess.current()) return _uid == uid;
    final grant = await _db.collection('author_grants').doc(uid).get();
    return _uid == uid && grant.data()?['status'] == 'approved';
  }

  Future<String?> uploadImage(XFile? image,
      {required String folder, String? requestId}) async {
    if (image == null) return null;
    final ref = _storage
        .ref()
        .child(folder)
        .child(_uid)
        .child('${requestId ?? DateTime.now().microsecondsSinceEpoch}.jpg');
    if (requestId != null) {
      try {
        await ref.getMetadata().timeout(const Duration(seconds: 15));
        _uid;
        return await ref.getDownloadURL().timeout(const Duration(seconds: 15));
      } on FirebaseException catch (error) {
        if (error.code != 'object-not-found') rethrow;
      }
    }
    final upload = ref.putFile(
        File(image.path), SettableMetadata(contentType: 'image/jpeg'));
    try {
      await upload.timeout(const Duration(seconds: 60));
    } catch (_) {
      await upload.cancel();
      rethrow;
    }
    final url = await ref.getDownloadURL().timeout(const Duration(seconds: 15));
    _uid;
    return url;
  }

  Future<void> createPost(
      {required String text, List<XFile> images = const [], String? requestId}) async {
    if (text.trim().isEmpty && images.isEmpty) {
      throw ArgumentError('Публикация не может быть пустой');
    }
    if (images.length > 10) {
      throw ArgumentError('Не больше 10 фотографий');
    }
    if (!await canPublish()) {
      throw StateError(
          'Публиковать посты могут администраторы и одобренные авторы');
    }
    final user = await _db.collection('users').doc(_uid).get();
    final data = user.data() ?? const <String, dynamic>{};
    final postRef = posts.doc(requestId);
    final uploadedUrls = <String>[];
    for (var i = 0; i < images.length; i++) {
      final url = await uploadImage(
        images[i],
        folder: 'feed_posts',
        requestId: '${postRef.id}_$i',
      );
      if (url != null) uploadedUrls.add(url);
    }
    await _db.runTransaction((tx) async {
      final existing = await tx.get(postRef);
      _uid;
      if (existing.exists) return;
      tx.set(postRef, {
        'authorUid': _uid,
        'authorName':
            data['fullName'] ?? firebaseAuth.currentUser?.displayName ?? '',
        'authorPhoto':
            data['profilePic'] ?? firebaseAuth.currentUser?.photoURL ?? '',
        'authorGroup': data['группа'] ?? '',
        'text': text.trim(),
        'images': uploadedUrls,
        'imageUrl': uploadedUrls.isEmpty ? '' : uploadedUrls.first,
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'published',
        'likeCount': 0,
        'commentCount': 0,
        'shareCount': 0,
        'nativeLanguage': data['language'] ?? 'ru',
      });
    });
  }

  Future<void> updatePost({
    required String postId,
    required String text,
    required List<String> keepImageUrls,
    List<XFile> newImages = const [],
  }) async {
    if (postId.isEmpty || postId.contains('/')) {
      throw ArgumentError('postId');
    }
    if (text.trim().isEmpty && keepImageUrls.isEmpty && newImages.isEmpty) {
      throw ArgumentError('Публикация не может быть пустой');
    }
    if (keepImageUrls.length + newImages.length > 10) {
      throw ArgumentError('Не больше 10 фотографий');
    }
    final isAdmin = await AdminAccess.current();
    if (!isAdmin && !await canPublish()) {
      throw StateError(
          'Редактировать посты могут администраторы и одобренные авторы');
    }
    final postRef = posts.doc(postId);
    final uploadedUrls = <String>[];
    for (var i = 0; i < newImages.length; i++) {
      final url = await uploadImage(
        newImages[i],
        folder: 'feed_posts',
        requestId:
        '${postId}_edit_${DateTime.now().microsecondsSinceEpoch}_$i',
      );
      if (url != null) uploadedUrls.add(url);
    }
    final allImages = [...keepImageUrls, ...uploadedUrls];
    await _db.runTransaction((tx) async {
      final post = await tx.get(postRef);
      _uid;
      if (!post.exists) throw StateError('Пост не найден');
      if (!isAdmin && post.data()?['authorUid']?.toString() != _uid) {
        throw StateError('Редактировать можно только свои публикации');
      }
      tx.update(postRef, {
        'text': text.trim(),
        'images': allImages,
        'imageUrl': allImages.isEmpty ? '' : allImages.first,
        'editedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> deletePost(String postId) async {
    if (postId.isEmpty || postId.contains('/')) {
      throw ArgumentError('postId');
    }
    final isAdmin = await AdminAccess.current();
    if (!isAdmin && !await canPublish()) {
      throw StateError(
          'Удалять посты могут администраторы и одобренные авторы');
    }
    await _db.runTransaction((tx) async {
      final post = await tx.get(posts.doc(postId));
      _uid;
      if (!post.exists) return;
      if (!isAdmin && post.data()?['authorUid']?.toString() != _uid) {
        throw StateError('Удалять можно только свои публикации');
      }
      tx.update(posts.doc(postId), {'status': 'deleted'});
    });
  }

  Future<void> deleteComment({
    required String postId,
    required String commentId,
  }) async {
    if (postId.isEmpty ||
        postId.contains('/') ||
        commentId.isEmpty ||
        commentId.contains('/')) {
      throw ArgumentError('Недопустимый комментарий');
    }
    final isAdmin = await AdminAccess.current();
    final commentRef = posts.doc(postId).collection('comments').doc(commentId);
    final postRef = posts.doc(postId);
    await _db.runTransaction((tx) async {
      final comment = await tx.get(commentRef);
      _uid;
      if (!comment.exists) return;
      final authorUid = comment.data()?['authorUid']?.toString();
      if (!isAdmin && authorUid != _uid) {
        throw StateError('Нет прав на удаление этого комментария');
      }
      tx.delete(commentRef);
      final post = await tx.get(postRef);
      if (post.exists) {
        final count = ((post.data()?['commentCount'] as num?) ?? 0).toInt();
        tx.update(postRef, {'commentCount': count > 0 ? count - 1 : 0});
      }
    });
  }

  Future<void> reportPost(String postId) async {
    final uid = _uid;
    if (postId.isEmpty || postId.contains('/')) throw ArgumentError('postId');
    final ref = _db.collection('moderation_reports').doc('post-$postId-$uid');
    try {
      await _db.runTransaction((tx) async {
        _uid;
        tx.set(ref, {
          'reporterUid': uid,
          'entityType': 'post',
          'entityId': postId,
          'createdAt': FieldValue.serverTimestamp(),
          'status': 'new'
        });
      });
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied' || _uid != uid) rethrow;
      final existing = await ref.get(const GetOptions(source: Source.server));
      _uid;
      final data = existing.data();
      if (!existing.exists || data?['reporterUid'] != uid ||
          data?['entityType'] != 'post' || data?['entityId'] != postId) {
        rethrow;
      }
    }
  }

  Future<void> reportComment(String postId, String commentId) async {
    final uid = _uid;
    if (postId.isEmpty || postId.contains('/') ||
        commentId.isEmpty || commentId.contains('/')) {
      throw ArgumentError('commentId');
    }
    final comment = posts.doc(postId).collection('comments').doc(commentId);
    final report = _db.collection('moderation_reports')
        .doc('comment-$postId-$commentId-$uid');
    try {
      await _db.runTransaction((tx) async {
        final source = await tx.get(comment);
        _uid;
        if (!source.exists) throw StateError('Комментарий недоступен');
        // Reading a missing report is denied by the strict rules. A first
        // report is a create; a repeat is rejected as a client update.
        tx.set(report, {
          'reporterUid': uid,
          'entityType': 'comment',
          'entityId': '$postId/$commentId',
          'createdAt': FieldValue.serverTimestamp(),
          'status': 'new',
        });
      });
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied' || _uid != uid) rethrow;
      // Confirm only this user's existing report before treating a denied
      // create as an idempotent retry. Other permission failures still fail.
      final existing = await report.get(const GetOptions(source: Source.server));
      _uid;
      final data = existing.data();
      if (!existing.exists || data?['reporterUid'] != uid ||
          data?['entityType'] != 'comment' ||
          data?['entityId'] != '$postId/$commentId') {
        rethrow;
      }
    }
  }

  Future<void> togglePostLike(String postId) => _retainLike(postId, null, () async {
    final postRef = posts.doc(postId);
    final likeRef = postRef.collection('likes').doc(_uid);
    final added = await _db.runTransaction<bool>((tx) async {
      final like = await tx.get(likeRef);
      final post = await tx.get(postRef);
      _uid;
      if (!post.exists) return false;
      final current = ((post.data()?['likeCount'] as num?) ?? 0).toInt();
      if (like.exists) {
        tx.delete(likeRef);
        tx.update(postRef, {'likeCount': current > 0 ? current - 1 : 0});
        return false;
      } else {
        tx.set(
            likeRef, {'uid': _uid, 'createdAt': FieldValue.serverTimestamp()});
        tx.update(postRef, {'likeCount': current + 1});
        return true;
      }
    });
    if (added) await _notifyReaction(postId);
  });

  Future<void> _notifyReaction(String postId, {String? commentId}) async {
    if (_serverSocialNotices) return;
    try {
      final source = commentId == null
          ? posts.doc(postId)
          : posts.doc(postId).collection('comments').doc(commentId);
      final data =
          (await source.get().timeout(const Duration(seconds: 10))).data();
      final target = data?['authorUid']?.toString();
      if (target == null || target.isEmpty || target == _uid) return;
      await addNotification(
        userUid: target,
        type: commentId == null ? 'post_like' : 'comment_like',
        title: 'Новая реакция',
        body: 'Новая реакция',
        entityId: postId,
        rootCommentId: commentId == null
            ? null
            : (data?['parentId']?.toString() ?? commentId),
        notificationId: 'reaction-$postId-${commentId ?? 'post'}-$_uid',
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      /* The confirmed reaction does not depend on notification delivery. */
    }
  }

  Future<bool> isPostLiked(String postId) async {
    return (await posts.doc(postId).collection('likes').doc(_uid).get()).exists;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> comments(String postId) {
    return posts
        .doc(postId)
        .collection('comments')
        .orderBy('createdAt')
        .snapshots();
  }

  Future<void> addComment({
    required String postId,
    required String text,
    String? parentId,
    List<XFile> images = const [],
    String? requestId,
  }) async {
    if (text.trim().isEmpty && images.isEmpty) return;
    final user = await _db.collection('users').doc(_uid).get();
    final userData = user.data() ?? const <String, dynamic>{};
    final postRef = posts.doc(postId);
    final commentRef = postRef.collection('comments').doc(requestId);
    final uploadedUrls = <String>[];
    for (var i = 0; i < images.length; i++) {
      final url = await uploadImage(
        images[i],
        folder: 'feed_comments',
        requestId: '${commentRef.id}_$i',
      );
      if (url != null) uploadedUrls.add(url);
    }
    final postOwner = await _db.runTransaction<String?>((tx) async {
      final post = await tx.get(postRef);
      final existing = await tx.get(commentRef);
      final parent = parentId == null
          ? null
          : await tx.get(postRef.collection('comments').doc(parentId));
      _uid;
      if (!post.exists)
        throw StateError('Публикация удалена. Комментарий не отправлен.');
      if (existing.exists)
        return existing.data()?['notificationRecipient']?.toString() ??
            post.data()?['authorUid']?.toString();
      if (parentId != null && parent?.exists != true)
        throw StateError('Комментарий удалён. Ответ не отправлен.');
      final parentData = parent?.data();
      final recipient =
          (parentId == null ? post.data() : parentData)?['authorUid']
              ?.toString();
      tx.set(commentRef, {
        'notificationRecipient': recipient,
        'authorUid': _uid,
        'authorName':
            userData['fullName'] ?? firebaseAuth.currentUser?.displayName ?? '',
        'authorPhoto':
            userData['profilePic'] ?? firebaseAuth.currentUser?.photoURL ?? '',
        'authorGroup': userData['группа'] ?? '',
        'text': text.trim(),
        'images': uploadedUrls,
        'imageUrl': uploadedUrls.isEmpty ? '' : uploadedUrls.first,
        'parentId': parentId,
        'createdAt': FieldValue.serverTimestamp(),
        'likeCount': 0,
      });
      final count = ((post.data()?['commentCount'] as num?) ?? 0).toInt();
      tx.update(postRef, {'commentCount': count + 1});
      return recipient;
    });

    // The comment is committed. A notification failure must not invite the
    // user to submit the same comment again or erase a successful result.
    if (_serverSocialNotices) return;
    try {
      if (postOwner != null && postOwner.isNotEmpty && postOwner != _uid) {
        await addNotification(
          userUid: postOwner,
          type: parentId == null ? 'post_comment' : 'comment_reply',
          title:
              parentId == null ? 'Новый комментарий' : 'Ответ на комментарий',
          body:
              '${userData['fullName'] ?? 'Пользователь'} прокомментировал(а) публикацию',
          entityId: postId,
          notificationId: 'comment-${commentRef.id}',
          actorName: userData['fullName']?.toString(),
          actorPhoto: userData['profilePic']?.toString(),
          rootCommentId: parentId,
        ).timeout(const Duration(seconds: 10));
      }
    } catch (_) {/* Notification delivery is independent of comment saving. */}
  }

  Future<void> toggleCommentLike(String postId, String commentId) =>
      _retainLike(postId, commentId, () async {
    final commentRef = posts.doc(postId).collection('comments').doc(commentId);
    final likeRef = commentRef.collection('likes').doc(_uid);
    final added = await _db.runTransaction<bool>((tx) async {
      final like = await tx.get(likeRef);
      final comment = await tx.get(commentRef);
      _uid;
      if (!comment.exists) return false;
      final count = ((comment.data()?['likeCount'] as num?) ?? 0).toInt();
      if (like.exists) {
        tx.delete(likeRef);
        tx.update(commentRef, {'likeCount': count > 0 ? count - 1 : 0});
        return false;
      } else {
        tx.set(
            likeRef, {'uid': _uid, 'createdAt': FieldValue.serverTimestamp()});
        tx.update(commentRef, {'likeCount': count + 1});
        return true;
      }
    });
    if (added) await _notifyReaction(postId, commentId: commentId);
  });

  Future<void> sharePost(String postId) async {
    final uid = _uid;
    final postRef = posts.doc(postId);
    final wallRef =
        _db.collection('users').doc(uid).collection('wall').doc(postId);
    await _db.runTransaction((tx) async {
      final original = await tx.get(postRef);
      final existing = await tx.get(wallRef);
      if (!original.exists ||
          existing.exists ||
          original.data()?['status'] != 'published') return;
      if (_uid != uid) throw StateError('Сеанс завершён');
      tx.set(wallRef,
          {'sharedPostId': postId, 'createdAt': FieldValue.serverTimestamp()});
      tx.update(postRef, {'shareCount': FieldValue.increment(1)});
    });
  }

  /// The recipient opens the current source post, not an untrusted chat copy.
  Future<Map<String, String>> shareableContent(String postId,
      {String? commentId}) async {
    if (postId.isEmpty || postId.contains('/') ||
        (commentId != null && (commentId.isEmpty || commentId.contains('/')))) {
      throw ArgumentError('Недопустимая публикация');
    }
    _uid;
    final post = await posts.doc(postId).get();
    _uid;
    final postData = post.data();
    if (postData == null || postData['status'] != 'published') {
      throw StateError('Публикация недоступна');
    }
    var data = postData;
    var threadRootId = '';
    if (commentId != null) {
      final comment =
          await posts.doc(postId).collection('comments').doc(commentId).get();
      _uid;
      if (!comment.exists) throw StateError('Комментарий недоступен');
      data = comment.data()!;
      final parent = data['parentId']?.toString() ?? '';
      threadRootId = parent.isEmpty ? commentId : parent;
    }
    return {
      'postId': postId,
      'commentId': commentId ?? '',
      'threadRootId': threadRootId,
      'kind': commentId == null ? 'post' : 'comment',
      'authorName': data['authorName']?.toString() ?? '',
      'text': data['text']?.toString() ?? '',
      'imageUrl': data['imageUrl']?.toString() ?? '',
    };
  }

  Future<void> shareComment(String postId, String commentId) async {
    if (postId.isEmpty || postId.contains('/') ||
        commentId.isEmpty || commentId.contains('/')) {
      throw ArgumentError('Недопустимый комментарий');
    }
    final uid = _uid;
    final post = posts.doc(postId);
    final comment = post.collection('comments').doc(commentId);
    final wall = _db.collection('users').doc(uid).collection('wall').doc(
        'comment_${postId.length}_${postId}_$commentId');
    await _db.runTransaction((tx) async {
      final sourcePost = await tx.get(post);
      final sourceComment = await tx.get(comment);
      final existing = await tx.get(wall);
      if (_uid != uid) throw StateError('Сеанс завершён');
      if (sourcePost.data()?['status'] != 'published' ||
          !sourceComment.exists) {
        throw StateError('Комментарий недоступен');
      }
      if (existing.exists) return;
      tx.set(wall, {
        'sharedPostId': postId,
        'sharedCommentId': commentId,
        'createdAt': FieldValue.serverTimestamp(),
      });
      tx.update(comment, {'shareCount': FieldValue.increment(1)});
    });
  }

  Future<void> removeCommentShare(String postId, String commentId) async {
    final uid = _uid;
    final wall = _db.collection('users').doc(uid).collection('wall').doc(
        'comment_${postId.length}_${postId}_$commentId');
    final comment = posts.doc(postId).collection('comments').doc(commentId);
    await _db.runTransaction((tx) async {
      final existing = await tx.get(wall);
      final source = await tx.get(comment);
      if (_uid != uid) throw StateError('Сеанс завершён');
      if (!existing.exists) return;
      tx.delete(wall);
      if (source.exists) {
        final count = (source.data()?['shareCount'] as num?)?.toInt() ?? 0;
        tx.update(comment, {'shareCount': count > 0 ? count - 1 : 0});
      }
    });
  }

  /// Removing a repost is idempotent; the original publication is untouched.
  Future<void> removeShare(String postId) async {
    final uid = _uid;
    final wall =
        _db.collection('users').doc(uid).collection('wall').doc(postId);
    final post = posts.doc(postId);
    await _db.runTransaction((tx) async {
      final existing = await tx.get(wall);
      final original = await tx.get(post);
      if (_uid != uid) throw StateError('Сеанс завершён');
      if (!existing.exists) return;
      tx.delete(wall);
      if (original.exists) {
        final count = (original.data()?['shareCount'] as num?)?.toInt() ?? 0;
        tx.update(post, {'shareCount': count > 0 ? count - 1 : 0});
      }
    });
  }

  Future<void> sendFriendRequest(String targetUid) async {
    final uid = _uid;
    if (targetUid == uid || targetUid.isEmpty) return;
    final meRef = _db.collection('users').doc(uid);
    final targetRef = _db.collection('users').doc(targetUid);
    final sentRef = meRef.collection('friend_requests_sent').doc(targetUid);
    final requestRef = targetRef.collection('friend_requests').doc(uid);
    final meData = await _db.runTransaction<Map<String, dynamic>?>((tx) async {
      final me = await tx.get(meRef);
      final target = await tx.get(targetRef);
      final alreadyFriend = await tx.get(meRef.collection('friends').doc(targetUid));
      final alreadySent = await tx.get(sentRef);
      final alreadyRequested = await tx.get(requestRef);
      final incoming = await tx.get(meRef.collection('friend_requests').doc(targetUid));
      if (_uid != uid) throw StateError('Сеанс завершён');
      if (!me.exists || !target.exists || target.data()?['status'] == 'deleted') {
        throw StateError('Профиль недоступен');
      }
      if (alreadyFriend.exists || alreadySent.exists || alreadyRequested.exists) {
        return null;
      }
      if (incoming.exists) throw StateError('Сначала ответьте на входящую заявку');
      final meData = me.data()!;
      final targetData = target.data()!;
      tx.set(requestRef, {
        'fromUid': uid,
        'fromName': _friendName(meData),
        'fromPhoto': meData['profilePicThumb'] ?? meData['profilePic'] ?? '',
        'группа': meData['группа'] ?? meData['group'] ?? '',
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'pending',
      });
      tx.set(sentRef, {
        'toUid': targetUid,
        'toName': _friendName(targetData),
        'toPhoto': targetData['profilePicThumb'] ?? targetData['profilePic'] ?? '',
        'группа': targetData['группа'] ?? targetData['group'] ?? '',
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'pending',
      });
      return meData;
    });
    if (meData == null) return;
    if (_uid != uid) return;
    if (_serverSocialNotices) return;
    try {
      await addNotification(
        userUid: targetUid,
        type: 'friend_request',
        title: 'Заявка в друзья',
        body:
            '${meData['fullName'] ?? 'Пользователь'} хочет добавить вас в друзья',
        entityId: uid,
        actorName: meData['fullName']?.toString(),
        actorPhoto: (meData['profilePicThumb'] ?? meData['profilePic'])?.toString(),
        notificationId: 'friend-request-$uid',
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> acceptFriendRequest(String requesterUid) async {
    final uid = _uid;
    final meDoc = await _db.collection('users').doc(uid).get();
    final otherDoc = await _db.collection('users').doc(requesterUid).get();
    final me = meDoc.data() ?? const <String, dynamic>{};
    final other = otherDoc.data() ?? const <String, dynamic>{};
    final accepted = await _db.runTransaction<bool>((batch) async {
      final requestRef = _db
          .collection('users')
          .doc(uid)
          .collection('friend_requests')
          .doc(requesterUid);
      final request = await batch.get(requestRef);
      final friendRef = _db.collection('users').doc(uid).collection('friends').doc(requesterUid);
      final existingFriend = await batch.get(friendRef);
      if (_uid != uid) throw StateError('Сеанс завершён');
      if (!request.exists && existingFriend.exists) return false;
      if (!request.exists || request.data()?['status'] != 'pending') {
        throw StateError('Заявка уже обработана или отозвана');
      }
      batch.set(
          friendRef,
          {
            'uid': requesterUid,
            'fullName': _friendName(other),
            'profilePic': other['profilePic'] ?? '',
            'profilePicThumb': other['profilePicThumb'] ?? other['profilePic'] ?? '',
            'группа': other['группа'] ?? other['group'] ?? '',
            'createdAt': FieldValue.serverTimestamp(),
            if (_serverSocialNotices) 'acceptedByUid': uid,
          });
      batch.set(
          _db
              .collection('users')
              .doc(requesterUid)
              .collection('friends')
              .doc(uid),
          {
            'uid': uid,
            'fullName': _friendName(me),
            'profilePic': me['profilePic'] ?? '',
            'profilePicThumb': me['profilePicThumb'] ?? me['profilePic'] ?? '',
            'группа': me['группа'] ?? me['group'] ?? '',
            'createdAt': FieldValue.serverTimestamp(),
            if (_serverSocialNotices) 'acceptedByUid': uid,
          });
      batch.delete(_db
          .collection('users')
          .doc(uid)
          .collection('friend_requests')
          .doc(requesterUid));
      batch.delete(_db
          .collection('users')
          .doc(requesterUid)
          .collection('friend_requests_sent')
          .doc(uid));
      return true;
    });
    if (!accepted || _uid != uid) return;
    if (_serverSocialNotices) return;
    try {
      await addNotification(
        userUid: requesterUid,
        type: 'friend_accepted',
        title: 'Заявка принята',
        body: '${me['fullName'] ?? 'Пользователь'} теперь у вас в друзьях',
        entityId: uid,
        actorName: me['fullName']?.toString(),
        actorPhoto: me['profilePic']?.toString(),
        notificationId: 'friend-accepted-$uid',
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> declineFriendRequest(String requesterUid) async {
    final uid = _uid;
    final batch = _db.batch();
    batch.delete(_db
        .collection('users')
        .doc(uid)
        .collection('friend_requests')
        .doc(requesterUid));
    batch.delete(_db
        .collection('users')
        .doc(requesterUid)
        .collection('friend_requests_sent')
        .doc(uid));
    if (_uid != uid) throw StateError('Сеанс завершён');
    await batch.commit();
  }

  Future<void> cancelFriendRequest(String targetUid) async {
    final uid = _uid;
    final batch = _db.batch();
    batch.delete(_db.collection('users').doc(uid)
        .collection('friend_requests_sent').doc(targetUid));
    batch.delete(_db.collection('users').doc(targetUid)
        .collection('friend_requests').doc(uid));
    if (_uid != uid) throw StateError('Сеанс завершён');
    await batch.commit();
  }

  Future<void> removeFriend(String friendUid) async {
    final uid = _uid;
    final batch = _db.batch();
    batch.delete(
        _db.collection('users').doc(uid).collection('friends').doc(friendUid));
    batch.delete(
        _db.collection('users').doc(friendUid).collection('friends').doc(uid));
    if (_uid != uid) throw StateError('Сеанс завершён');
    await batch.commit();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> friends() {
    return _db
        .collection('users')
        .doc(_uid)
        .collection('friends')
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> friendRequests() {
    return _db
        .collection('users')
        .doc(_uid)
        .collection('friend_requests')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> sentFriendRequests() {
    return _db.collection('users').doc(_uid)
        .collection('friend_requests_sent')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Future<void> requestRole(String role,
      {String? proposedText, List<XFile> proposedImages = const [], String? requestId}) async {
    if (role != 'author' && role != 'moderator') {
      throw ArgumentError.value(role, 'role');
    }
    final text = proposedText?.trim() ?? '';
    if (role == 'author' && (text.isEmpty || text.length > 10000)) {
      throw ArgumentError('A proposed publication is required');
    }
    final uid = _uid;
    final ref = _db.collection('${role}_requests').doc(uid);
    // Check the durable request before uploading again after a closed screen
    // or killed process. One active application is allowed per account.
    final prior = await ref.get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 15));
    _uid;
    if (prior.data()?['status'] == 'pending' ||
        prior.data()?['status'] == 'approved') return;
    final user = await _db.collection('users').doc(uid).get()
        .timeout(const Duration(seconds: 15));
    _uid;
    final data = user.data() ?? const <String, dynamic>{};
    final proposalId = requestId ?? DateTime.now().microsecondsSinceEpoch.toString();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(proposalId)) {
      throw ArgumentError('Invalid proposal identity');
    }
    final uploadedUrls = <String>[];
    if (role == 'author') {
      for (var i = 0; i < proposedImages.length; i++) {
        final url = await uploadImage(
          proposedImages[i],
          folder: 'author_applications',
          requestId: '${proposalId}_$i',
        );
        if (url != null) uploadedUrls.add(url);
      }
    }
    await _db.runTransaction((tx) async {
      final existing = await tx.get(ref);
      if (_uid != uid) throw StateError('Сеанс завершён');
      if (existing.data()?['status'] == 'pending' ||
          existing.data()?['status'] == 'approved') return;
      tx.set(ref, {
        'uid': uid,
        'fullName': data['fullName'] ?? '',
        'requestedRole': role,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        if (role == 'author') ...{
          'proposedText': text,
          'proposedImages': uploadedUrls,
          'proposedImageUrl': uploadedUrls.isEmpty ? '' : uploadedUrls.first,
          'proposalId': proposalId,
        },
      });
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> roleRequests(String role) {
    if (role != 'author' && role != 'moderator') {
      throw ArgumentError.value(role, 'role');
    }
    return _db
        .collection('${role}_requests')
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  Future<void> reviewRoleRequest(
      {required String role,
      required String applicantUid,
      required bool approve}) async {
    if (role != 'author' && role != 'moderator') {
      throw ArgumentError.value(role, 'role');
    }
    if (applicantUid.isEmpty || applicantUid.contains('/')) {
      throw ArgumentError.value(applicantUid, 'applicantUid');
    }
    final reviewerUid = _uid;
    if (!await AdminAccess.current() || _uid != reviewerUid) {
      throw StateError('Доступ запрещён');
    }
    final request = _db.collection('${role}_requests').doc(applicantUid);
    final grant = _db.collection('${role}_grants').doc(applicantUid);
    await _db.runTransaction((tx) async {
      final application = await tx.get(request);
      if (_uid != reviewerUid) throw StateError('Сеанс завершён');
      if (application.data()?['status'] != 'pending') {
        throw StateError('Заявка уже обработана');
      }
      tx.update(request, {
        'status': approve ? 'approved' : 'rejected',
        'reviewedBy': reviewerUid,
        'reviewedAt': FieldValue.serverTimestamp(),
      });
      if (approve) {
        tx.set(grant, {
          'uid': applicantUid,
          'status': 'approved',
          'approvedBy': reviewerUid,
          'approvedAt': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> notifications() {
    return _db
        .collection('users')
        .doc(_uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots();
  }

  Future<void> addNotification({
    required String userUid,
    required String type,
    required String title,
    required String body,
    String? entityId,
    String? notificationId,
    String? actorName,
    String? actorPhoto,
    String? rootCommentId,
  }) async {
    if (userUid.isEmpty) return;
    _uid;
    final collection =
        _db.collection('users').doc(userUid).collection('notifications');
    final data = <String, dynamic>{
      'type': type,
      'title': title,
      'body': body,
      'entityId': entityId ?? '',
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
      if (actorName != null) 'actorName': actorName,
      if (actorPhoto != null) 'actorPhoto': actorPhoto,
      if (rootCommentId != null) 'rootCommentId': rootCommentId,
    };
    if (notificationId == null) {
      await collection.add(data);
    } else {
      final ref = collection.doc(notificationId);
      await _db.runTransaction((tx) async {
        final existing = await tx.get(ref);
        _uid;
        if (!existing.exists) tx.set(ref, data);
      });
    }
  }

  Future<void> markNotificationRead(String notificationId) =>
      markNotificationsRead([notificationId]);

  /// One atomic batch for the visible page (at most 100 notifications).
  /// The caller retains this future on timeout; it must not enqueue new batches.
  Future<void> markNotificationsRead(Iterable<String> notificationIds) async {
    final uid = _uid;
    final ids = notificationIds.toSet();
    if (ids.length > 100 || ids.any((id) => id.isEmpty || id.contains('/'))) {
      throw ArgumentError('Недопустимый список уведомлений');
    }
    if (ids.isEmpty) return;
    final collection =
        _db.collection('users').doc(uid).collection('notifications');
    final batch = _db.batch();
    for (final id in ids) {
      batch.update(collection.doc(id), {'read': true});
    }
    // Same session and same path for the whole batch; never switch users midway.
    _uid;
    await batch.commit();
  }
}
