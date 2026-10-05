import 'package:wbrs/shared/translatable_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'post_detail_page.dart';

class ProfileWallPage extends StatelessWidget {
  const ProfileWallPage({super.key, required this.userUid, this.userName});
  final String userUid;
  final String? userName;

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    appBar: AppBar(title: Text(context.tr('Стена'))),
    body: ProfileWallSection(userUid: userUid),
  );
}

enum _WallTab { all, authored, shared }

class ProfileWallSection extends StatefulWidget {
  const ProfileWallSection({super.key, required this.userUid, this.embedded = false});
  final String userUid;
  final bool embedded;
  @override
  State<ProfileWallSection> createState() => _ProfileWallSectionState();
}

class _ProfileWallSectionState extends State<ProfileWallSection> {
  late Stream<QuerySnapshot<Map<String, dynamic>>> _wall = _load();
  late Stream<QuerySnapshot<Map<String, dynamic>>> _authored = _loadAuthored();
  late Stream<QuerySnapshot<Map<String, dynamic>>> _legacyAuthored =
  _loadLegacyAuthored();
  _WallTab _tab = _WallTab.all;

  Stream<QuerySnapshot<Map<String, dynamic>>> _load() => firebaseFirestore
      .collection('users')
      .doc(widget.userUid)
      .collection('wall')
      .orderBy('createdAt', descending: true)
      .snapshots();

  // Equality-only filters avoid a new composite index for profile walls.
  Stream<QuerySnapshot<Map<String, dynamic>>> _loadAuthored() => firebaseFirestore
      .collection('posts')
      .where('status', isEqualTo: 'published')
      .where('authorUid', isEqualTo: widget.userUid)
      .snapshots();

  // Older posts used authorId and had no status. Keep them read-only until
  // their reaction/comment data can be migrated without changing live records.
  Stream<QuerySnapshot<Map<String, dynamic>>> _loadLegacyAuthored() =>
      firebaseFirestore.collection('posts')
          .where('authorId', isEqualTo: widget.userUid).snapshots();

  @override
  void didUpdateWidget(covariant ProfileWallSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userUid != widget.userUid) {
      _wall = _load();
      _authored = _loadAuthored();
      _legacyAuthored = _loadLegacyAuthored();
    }
  }

  int _time(Map<String, dynamic> data) {
    final value = data['createdAt'];
    if (value is Timestamp) return value.millisecondsSinceEpoch;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    return 0;
  }

  Widget _tabBar() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(children: [
      _tabButton(_WallTab.all, context.tr('Все')),
      const SizedBox(width: 8),
      _tabButton(_WallTab.authored, context.tr('Мои публикации')),
      const SizedBox(width: 8),
      _tabButton(_WallTab.shared, context.tr('Репосты')),
    ]),
  );

  Widget _tabButton(_WallTab tab, String label) {
    final selected = _tab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = tab),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? LrsTheme.actionGlass : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: selected ? LrsTheme.peach : const Color(0x33E7B092)),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  color: selected ? LrsTheme.text : LrsTheme.muted,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
    stream: _wall,
    builder: (context, wallSnapshot) =>
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _authored,
          builder: (context, authoredSnapshot) =>
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _legacyAuthored,
                builder: (context, legacySnapshot) {
                  if (wallSnapshot.hasError || authoredSnapshot.hasError) {
                    return SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: ClrsPanel(
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Text(context.tr('Не удалось загрузить публикации.')),
                              TextButton(
                                  onPressed: () => setState(() {
                                    _wall = _load();
                                    _authored = _loadAuthored();
                                    _legacyAuthored = _loadLegacyAuthored();
                                  }),
                                  child: Text(context.tr('Повторить'))),
                            ])));
                  }
                  if (!wallSnapshot.hasData || !authoredSnapshot.hasData) {
                    return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()));
                  }
                  final authored = authoredSnapshot.data!.docs.where((doc) =>
                  doc.data()['status'] == 'published' &&
                      doc.data()['authorUid'] == widget.userUid).toList();
                  final legacy = (legacySnapshot.data?.docs ?? []).where((doc) =>
                  !doc.data().containsKey('status') &&
                      doc.data()['authorId'] == widget.userUid).toList();
                  final authoredIds = authored.map((doc) => doc.id).toSet();
                  authoredIds.addAll(legacy.map((doc) => doc.id));
                  var entries = <({String id, String postId, String? commentId,
                  bool authored, bool legacy, int time})>[
                    for (final doc in authored)
                      (id: 'post_${doc.id}', postId: doc.id, commentId: null,
                      authored: true, legacy: false, time: _time(doc.data())),
                    for (final doc in legacy)
                      (id: 'legacy_${doc.id}', postId: doc.id, commentId: null,
                      authored: true, legacy: true, time: _time(doc.data())),
                    for (final doc in wallSnapshot.data!.docs)
                      if (doc.data()['sharedCommentId'] != null ||
                          !authoredIds.contains(doc.data()['sharedPostId']?.toString() ?? doc.id))
                        (id: 'share_${doc.id}',
                        postId: doc.data()['sharedPostId']?.toString() ?? doc.id,
                        commentId: doc.data()['sharedCommentId']?.toString(),
                        authored: false, legacy: false, time: _time(doc.data())),
                  ]..sort((a, b) => b.time.compareTo(a.time));
                  if (_tab == _WallTab.authored) {
                    entries = entries.where((e) => e.authored).toList();
                  } else if (_tab == _WallTab.shared) {
                    entries = entries.where((e) => !e.authored).toList();
                  }
                  final list = ListView.separated(
                    shrinkWrap: widget.embedded,
                    physics: widget.embedded
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    padding: const EdgeInsets.all(16),
                    itemCount: entries.isEmpty ? 1 : entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      if (entries.isEmpty) {
                        return ClrsPanel(
                            child: Text(context.tr(_tab == _WallTab.authored
                                ? 'Здесь появятся ваши публикации.'
                                : _tab == _WallTab.shared
                                ? 'Здесь появятся публикации, которыми вы поделились.'
                                : 'Здесь появятся публикации, которыми вы поделились.')));
                      }
                      final entry = entries[index];
                      return _WallPost(
                          key: ValueKey(entry.id),
                          postId: entry.postId,
                          commentId: entry.commentId,
                          owner: !entry.authored &&
                              widget.userUid == firebaseAuth.currentUser?.uid,
                          authored: entry.authored,
                          legacy: entry.legacy);
                    },
                  );
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(children: [
                      _tabBar(),
                      widget.embedded
                          ? list
                          : Expanded(child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 0),
                          child: list)),
                    ]),
                  );
                },
              ),
        ),
  );
}

class _WallPost extends StatefulWidget {
  const _WallPost(
      {super.key, required this.postId, this.commentId, required this.owner,
      this.authored = false, this.legacy = false});
  final String postId;
  final String? commentId;
  final bool owner;
  final bool authored;
  final bool legacy;
  @override
  State<_WallPost> createState() => _WallPostState();
}

class _WallPostState extends State<_WallPost> {
  late final _post =
      firebaseFirestore.collection('posts').doc(widget.postId).snapshots();
  bool _removing = false;
  Future<void> _remove() async {
    if (_removing) return;
    setState(() => _removing = true);
    try {
      final social = SocialService();
      await (widget.commentId == null
              ? social.removeShare(widget.postId)
              : social.removeCommentShare(widget.postId, widget.commentId!))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context.tr(
                'Не удалось подтвердить удаление. Проверьте стену перед повтором.'))));
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  Widget _sharedComment(Map<String, dynamic> post) =>
      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: firebaseFirestore
            .collection('posts')
            .doc(widget.postId)
            .collection('comments')
            .doc(widget.commentId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Text(context.tr('Не удалось загрузить комментарии.'));
          }
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final comment = snapshot.data!.data();
          if (comment == null) {
            return Text(context.tr('Комментарий недоступен'));
          }
          final parent = comment['parentId']?.toString() ?? '';
          final root = parent.isEmpty ? widget.commentId! : parent;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(comment['authorName']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if ((comment['text']?.toString() ?? '').isNotEmpty)
              TranslatableText(comment['text'].toString()),
            if ((comment['imageUrl']?.toString() ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    imageUrl: comment['imageUrl'].toString(),
                    height: 180,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PostDetailPage(
                      postId: widget.postId,
                      post: post,
                      threadRootId: root))),
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: Text(context.tr('Открыть ветку')),
            ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _post,
        builder: (context, snapshot) {
          final post = snapshot.data?.data();
          final available = post != null &&
              (post['status'] == 'published' ||
                  (widget.legacy && !post.containsKey('status')));
          final image = widget.legacy && post?['images'] is List &&
                  (post!['images'] as List).isNotEmpty
              ? (post['images'] as List).first.toString()
              : post?['imageUrl']?.toString() ?? '';
          return ClrsPanel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                if (!widget.authored) Row(children: [
                  Expanded(
                      child: Text(context.tr(widget.commentId == null
                              ? 'Репост'
                              : 'Репост комментария'),
                          style: const TextStyle(
                              color: LrsTheme.peachLight, fontSize: 12))),
                  if (widget.owner)
                    IconButton(
                        tooltip: context.tr('Убрать со стены'),
                        onPressed: _removing ? null : _remove,
                        icon: _removing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.close, size: 20)),
                ]),
                if (snapshot.hasError)
                  Text(context.tr('Не удалось загрузить публикацию.'))
                else if (!snapshot.hasData)
                  const LinearProgressIndicator()
                else if (!available)
                  Text(context.tr('Публикация удалена или недоступна.'))
                else ...[
                  Row(children: [
                    GroupAvatar(
                        url: (post['authorPhoto'] ?? post['authorAvatar'])
                            ?.toString() ?? '',
                        group: post['authorGroup']?.toString() ?? '',
                        size: 36),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(post['authorName']?.toString() ?? '',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600))),
                  ]),
                  const SizedBox(height: 10),
                  if (widget.commentId != null)
                    _sharedComment(post),
                  if (widget.commentId == null &&
                      (post['text']?.toString() ?? '').isNotEmpty)
                    TranslatableText(post['text'].toString(),
                        showAction: false),
                  if (widget.commentId == null && image.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: CachedNetworkImage(
                                imageUrl: image,
                                errorWidget: (_, __, ___) =>
                                    const Icon(Icons.broken_image_outlined)))),
                  if (widget.legacy) Row(children: [
                    const Icon(Icons.favorite_border, size: 18),
                    Text(' ${post['likesCount'] ?? 0}  '),
                    const Icon(Icons.chat_bubble_outline, size: 18),
                    Text(' ${post['commentsCount'] ?? 0}'),
                  ]),
                  if (widget.commentId == null && !widget.legacy) TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => PostDetailPage(
                                  postId: widget.postId, post: post))),
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: Text(context.tr('Комментарии'))),
                ],
              ]));
        },
      );
}
