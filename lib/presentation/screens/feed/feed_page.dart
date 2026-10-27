import 'dart:async';

import 'package:wbrs/shared/translatable_text.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/service/post_submission.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/notifications_center/notifications_page.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/presentation/screens/feed/post_detail_page.dart';
import 'package:wbrs/presentation/screens/feed/post_editor_page.dart';
import 'package:wbrs/presentation/screens/feed/post_author_wall.dart';
import 'package:wbrs/presentation/screens/feed/share_to_chat_sheet.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/paged_firestore_history.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({super.key, this.social, this.postSubmissions});
  final SocialService? social;
  final PostSubmissionService? postSubmissions;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  late final SocialService _social;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _feed;
  bool _canPublish = false;
  final _history = PagedFirestoreHistory(40);
  int _pageGeneration = 0;
  bool _loadingOlder = false, _olderError = false;
  Timer? _feedWaitTimer;
  bool _feedWaitExpired = false;

  @override
  void initState() {
    super.initState();
    _social = widget.social ?? SocialService();
    _feed = _loadFeed();
    selectedIndex = 0;
    _loadRole();
  }

  Future<void> _loadRole() async {
    try {
      final allowed = await _social.canPublish().timeout(Duration(seconds: 15));
      if (mounted) setState(() => _canPublish = allowed);
    } catch (_) {
      if (mounted) setState(() => _canPublish = false);
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _loadFeed() {
    final generation = ++_pageGeneration;
    _history.reset();
    _loadingOlder = false;
    _olderError = false;
    _feedWaitTimer?.cancel();
    _feedWaitExpired = false;
    final timer = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() => _feedWaitExpired = true);
    });
    _feedWaitTimer = timer;
    try {
      return _social.feed(limit: _history.pageSize + 1).map((snapshot) {
        timer.cancel();
        if (generation == _pageGeneration) _history.receiveLive(snapshot);
        return snapshot;
      });
    } catch (error, stack) {
      timer.cancel();
      return Stream.error(error, stack);
    }
  }

  Future<void> _loadOlderPosts() async {
    final cursor = _history.cursor;
    if (_loadingOlder || !_history.hasMore || cursor == null) return;
    final generation = _pageGeneration;
    setState(() {
      _loadingOlder = true;
      _olderError = false;
    });
    try {
      final page = await _social
          .feedOlder(cursor, limit: _history.pageSize + 1)
          .timeout(const Duration(seconds: 20));
      if (!mounted || generation != _pageGeneration) return;
      setState(() => _history.appendOlder(page));
    } catch (_) {
      if (mounted && generation == _pageGeneration) {
        setState(() => _olderError = true);
      }
    } finally {
      if (mounted && generation == _pageGeneration) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  @override
  void dispose() {
    _feedWaitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
            child: Image.asset('assets/final_design/feed_family.png',
                fit: BoxFit.cover)),
        Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          drawer: MyDrawer(),
          bottomNavigationBar: MyBottomNavigationBar(),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: const ClrsLogo(size: 34),
            toolbarHeight: 56,
            actions: [
              IconButton(
                  tooltip: context.tr('Уведомления'),
                  icon: Icon(Icons.notifications_none),
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => NotificationsPage()))),
              if (_canPublish)
                IconButton(
                  tooltip: context.tr('Новая публикация'),
                  onPressed: _createPost,
                  icon: Icon(Icons.add_box_outlined),
                ),
            ],
          ),
          body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _feed,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData &&
                  !_feedWaitExpired) {
                return Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError ||
                  (_feedWaitExpired && !snapshot.hasData)) {
                return Center(
                  child: Container(
                    margin: EdgeInsets.all(24),
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Color(0xD0302110),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                        context.tr(
                            'Лента временно недоступна. Проверьте подключение и попробуйте позже.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: LrsTheme.text),
                      ),
                      TextButton(
                          onPressed: () => setState(() {
                                _feed = _loadFeed();
                              }),
                          child: Text(context.tr('Повторить')))
                    ]),
                  ),
                );
              }
              final docs = _history.documents;
              if (docs.isEmpty) return _emptyFeed();
              final hasOlder = _history.hasMore;
              return ListView.separated(
                padding: EdgeInsets.fromLTRB(
                    12, MediaQuery.paddingOf(context).top + 8, 12, 28),
                itemCount: docs.length + 1 + (hasOlder ? 1 : 0),
                separatorBuilder: (_, __) => SizedBox(height: 12),
                itemBuilder: (context, index) {
                  if (index == 0)
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(width: 150, child: ClrsMotto()),
                          SizedBox(
                              height:
                                  MediaQuery.textScalerOf(context).scale(1) >
                                          1.5
                                      ? 8
                                      : 12),
                          Text(context.tr('Лента'),
                              style: const TextStyle(
                                  fontFamily: 'CormorantGaramond',
                                  fontSize: 42,
                                  height: 1.1,
                                  fontWeight: FontWeight.w600)),
                        ]);
                  if (index > docs.length) {
                    return Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      if (_olderError)
                        Text(context.tr('Не удалось загрузить публикации.')),
                      TextButton(
                          onPressed: _loadingOlder ? null : _loadOlderPosts,
                          child: _loadingOlder
                              ? const CircularProgressIndicator(strokeWidth: 2)
                              : Text(context.tr(_olderError
                                  ? 'Повторить'
                                  : 'Загрузить ещё'))),
                    ]));
                  }
                  return _PostCard(
                    key: ValueKey(docs[index - 1].id),
                    postId: docs[index - 1].id,
                    data: docs[index - 1].data(),
                    social: _social,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _emptyFeed() {
    return Center(
      child: Container(
        margin: EdgeInsets.all(24),
        padding: EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Color(0xD0302110),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Color(0x77E7B092), width: .8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.home_outlined, color: LrsTheme.peach, size: 44),
            SizedBox(height: 12),
            Text(
              context.tr('Лента CLRS'),
              style: TextStyle(
                color: LrsTheme.text,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 8),
            Text(
              context.tr(
                  'Здесь будут публикации о семье, отношениях, вере, психологии, домах, детях и совместимости.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: LrsTheme.muted),
            ),
            if (_canPublish) ...[
              SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: LrsTheme.actionGlass,
                  foregroundColor: LrsTheme.text,
                  disabledBackgroundColor: LrsTheme.actionDisabled,
                  disabledForegroundColor: LrsTheme.muted,
                  side: const BorderSide(color: LrsTheme.actionBorder),
                ),
                onPressed: _createPost,
                icon: Icon(Icons.add),
                label: Text(context.tr('Создать первую публикацию')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _createPost() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PostEditorPage(
          social: _social,
          postSubmissions: widget.postSubmissions,
        ),
      ),
    );
    if (ok == true && mounted) {
      setState(() => _feed = _loadFeed());
    }
  }
}

class _CreatePostSheet extends StatefulWidget {
  const _CreatePostSheet({required this.submissions});
  final PostSubmissionService submissions;
  @override
  State<_CreatePostSheet> createState() => _CreatePostSheetState();
}

class _CreatePostSheetState extends State<_CreatePostSheet> {
  final _controller = TextEditingController();
  XFile? _image;
  bool _sending = false;
  bool _restoring = true;
  PostSubmission? _submission;
  String? _notice;
  bool get _locked => _restoring || _sending || _submission != null;
  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final saved = await widget.submissions.restore();
      if (!mounted) return;
      if (saved != null)
        setState(() {
          _submission = saved;
          _controller.text = saved.text;
          _image = saved.image;
          _notice =
              'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
        });
    } catch (_) {
      if (mounted)
        setState(() =>
            _notice = 'Не удалось восстановить отправку. Попробуйте ещё раз.');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final image = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 72,
          maxWidth: 1600,
          maxHeight: 1600);
      if (mounted && image != null && !_locked) setState(() => _image = image);
    } catch (_) {
      if (mounted)
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось открыть изображение. Попробуйте ещё раз.'));
    }
  }

  Future<void> _publish() async {
    if (_restoring ||
        _sending ||
        (_controller.text.trim().isEmpty && _image == null)) return;
    setState(() {
      _sending = true;
      _notice = null;
    });
    try {
      if (_submission?.write.failed == true) _submission = null;
      _submission ??=
          widget.submissions.start(text: _controller.text, image: _image);
      final confirmed = await _submission!.write.wait();
      if (!mounted) return;
      if (!widget.submissions.isCurrentSession) {
        setState(() => _notice =
            'Сеанс изменился. Проверьте отправку после входа в исходный аккаунт.');
      } else if (!confirmed) {
        setState(() => _notice =
            'Подтверждение ещё не получено. Нажмите «Проверить отправку».');
      } else {
        widget.submissions.acknowledge(_submission!);
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _submission = null;
          _notice = 'Не удалось опубликовать запись. Попробуйте ещё раз.';
        });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
          child: Padding(
        padding: EdgeInsets.fromLTRB(
            18, 18, 18, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.tr('Новая публикация'),
                  style: TextStyle(
                      color: LrsTheme.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
              SizedBox(height: 12),
              TextField(
                  controller: _controller,
                  readOnly: _locked,
                  maxLines: 6,
                  style: TextStyle(color: LrsTheme.text),
                  decoration: InputDecoration(
                      hintText: context.tr('Напишите о важном...'))),
              if (_image != null) ...[
                SizedBox(height: 10),
                Text(_image!.name, style: TextStyle(color: LrsTheme.peachLight))
              ],
              SizedBox(height: 10),
              if (_restoring) LinearProgressIndicator(),
              if (_notice != null)
                Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text(context.tr(_notice!))),
              Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                        onPressed: _locked ? null : _pickImage,
                        icon: Icon(Icons.image_outlined),
                        label: Text(context.tr('Фото'))),
                    FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: LrsTheme.actionGlass,
                            foregroundColor: LrsTheme.text,
                            disabledBackgroundColor: LrsTheme.actionDisabled,
                            disabledForegroundColor: LrsTheme.muted,
                            side:
                                const BorderSide(color: LrsTheme.actionBorder)),
                        onPressed: _sending ? null : _publish,
                        child: _sending
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: LrsTheme.text))
                            : Text(context.tr(_submission == null
                                ? 'Опубликовать'
                                : 'Проверить отправку'))),
                  ]),
            ]),
      ));
}

class _PostCard extends StatefulWidget {
  const _PostCard({
    super.key,
    required this.postId,
    required this.data,
    required this.social,
  });

  final String postId;
  final Map<String, dynamic> data;
  final SocialService social;

  @override
  State<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<_PostCard> {
  bool _liked = false;
  bool _liking = false;
  PendingWrite? _likeWrite;
  bool? _likePrevious;
  bool _sharing = false;
  PendingWrite? _shareWrite;
  bool _reporting = false;
  int _likeRevision = 0;

  @override
  void initState() {
    super.initState();
    _loadLiked();
  }

  Future<void> _loadLiked() async {
    final revision = _likeRevision;
    try {
      final liked = await widget.social.isPostLiked(widget.postId);
      if (mounted && revision == _likeRevision) setState(() => _liked = liked);
    } catch (_) {
      // Counts remain available from the post stream when this optional read fails.
    }
  }

  Future<void> _toggleLike() async {
    if (_liking || !widget.social.isCurrentSession) return;
    setState(() {
      _liking = true;
      if (_likeWrite == null) {
        _likeRevision++;
        _likePrevious = _liked;
        _liked = !_liked;
      }
    });
    try {
      _likeWrite ??= PendingWrite(() => widget.social.togglePostLike(widget.postId));
      final confirmed = await _likeWrite!.wait();
      if (!mounted || !widget.social.isCurrentSession) return;
      if (confirmed) {
        _likeWrite = null;
        _likePrevious = null;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.tr(
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.')),
          action: SnackBarAction(
              label: context.tr('Проверить результат'), onPressed: _toggleLike),
        ));
      }
    } catch (_) {
      final previous = _likePrevious;
      _likeWrite = null;
      _likePrevious = null;
      if (mounted && widget.social.isCurrentSession) {
        setState(() => _liked = previous ?? _liked);
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось сохранить реакцию. Попробуйте ещё раз.'));
      }
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  Future<void> _shareToWall() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      _shareWrite ??= PendingWrite(() => widget.social.sharePost(widget.postId));
      final confirmed = await _shareWrite!.wait();
      if (!mounted) return;
      if (confirmed) {
        _shareWrite = null;
        showSnackbar(context, LrsTheme.surface,
            context.tr('Публикация добавлена на вашу страницу'));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.tr(
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.')),
          action: SnackBarAction(
              label: context.tr('Проверить отправку'),
              onPressed: _shareToWall),
        ));
      }
    } catch (_) {
      _shareWrite = null;
      if (mounted) {
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось поделиться публикацией. Попробуйте ещё раз.'));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _showShareOptions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: LrsTheme.surface,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(context.tr('На моей странице')),
            onTap: () => Navigator.pop(context, 'wall'),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: Text(context.tr('Отправить в чат')),
            onTap: () => Navigator.pop(context, 'chat'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'wall') {
      await _shareToWall();
    } else if (action == 'chat') {
      await showShareToChatSheet(context,
          postId: widget.postId, social: widget.social);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final image = data['imageUrl']?.toString() ?? '';
    final authorPhoto = data['authorPhoto']?.toString() ?? '';
    final authorUid = postAuthorUid(data);
    final text = data['text']?.toString() ?? '';
    final sharedText = data['sharedText']?.toString() ?? '';
    final sharedImage = data['sharedImageUrl']?.toString() ?? '';
    final displayText = text.isNotEmpty ? text : sharedText;
    final displayImage = image.isNotEmpty ? image : sharedImage;

    return Container(
      decoration: BoxDecoration(
        color: Color(0xD0302110),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Color(0x77E7B092), width: .8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: authorUid.isEmpty
                        ? null
                        : () => openPostAuthorWall(context, data),
                    child: Row(children: [
                      GroupAvatar(
                          url: authorPhoto,
                          group: data['authorGroup']?.toString() ?? '',
                          size: 44),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data['authorName']?.toString() ?? 'CLRS',
                              style: TextStyle(
                                color: LrsTheme.text,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              data['createdAt'] is Timestamp
                                  ? context.l10n.dateTime(
                                      (data['createdAt'] as Timestamp).toDate())
                                  : context.tr('Публикация'),
                              style: TextStyle(
                                  color: LrsTheme.muted, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ]),
                  ),
                ),
                IconButton(
                  onPressed: () => _showPostMenu(context),
                  icon: Icon(Icons.more_horiz, color: LrsTheme.muted),
                ),
              ],
            ),
          ),
          if ((data['title']?.toString() ?? '').isNotEmpty)
            Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: TranslatableText(data['title'].toString(),
                    showAction: false,
                    style: const TextStyle(
                        fontFamily: 'CormorantGaramond',
                        fontSize: 25,
                        fontWeight: FontWeight.w600))),
          if (displayText.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: TranslatableText(displayText,
                  style: TextStyle(color: LrsTheme.text, height: 1.35)),
            ),
          if (displayImage.isNotEmpty)
            AspectRatio(
                aspectRatio: 1.85,
                child: CachedNetworkImage(
                  imageUrl: displayImage,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: LrsTheme.muted)),
                )),
          Divider(height: 1, color: Color(0x22FFFFFF)),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: _liking
                      ? null
                      : _toggleLike,
                  icon: Icon(
                    _liked ? Icons.favorite : Icons.favorite_border,
                    color: _liked ? LrsTheme.peach : LrsTheme.muted,
                  ),
                  label: Text('${data['likeCount'] ?? 0}'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => nextScreen(
                    context,
                    PostDetailPage(
                        postId: widget.postId,
                        post: data,
                        social: widget.social),
                  ),
                  icon: Icon(Icons.mode_comment_outlined),
                  label: Text('${data['commentCount'] ?? 0}'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: _sharing ? null : _showShareOptions,
                  icon: Icon(Icons.share_outlined),
                  label: Text('${data['shareCount'] ?? 0}'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showPostMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: LrsTheme.surface,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: Icon(Icons.flag_outlined, color: LrsTheme.peach),
          title: Text(context.tr('Пожаловаться'),
              style: TextStyle(color: LrsTheme.text)),
          subtitle: Text(
            context.tr('Жалоба попадёт в очередь модерации'),
            style: TextStyle(color: LrsTheme.muted),
          ),
          onTap: () async {
            if (_reporting) return;
            _reporting = true;
            try {
              await widget.social
                  .reportPost(widget.postId)
                  .timeout(const Duration(seconds: 15));
              if (context.mounted) Navigator.pop(context);
            } catch (_) {
              if (context.mounted)
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(context.tr(
                        'Не удалось отправить заявку. Попробуйте ещё раз.'))));
            } finally {
              _reporting = false;
            }
          },
        ),
      ),
    );
  }
}
