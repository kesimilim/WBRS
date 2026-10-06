// ignore_for_file: use_build_context_synchronously

import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/presentation/screens/feed/post_detail_page.dart';
import 'package:wbrs/presentation/screens/shop/shop.dart';
import 'package:wbrs/service/chat_submission.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/translatable_text.dart';

class MessageTile extends StatefulWidget {
  final DocumentSnapshot message;
  final String sender;
  final String chatId;
  final String name;
  final bool sentByMe;
  final bool isRead;
  final Widget? avatar;
  final bool isChat;
  final bool compactMeeting;

  const MessageTile({
    super.key,
    required this.message,
    required this.chatId,
    required this.sender,
    required this.sentByMe,
    required this.isRead,
    required this.name,
    this.avatar,
    required this.isChat,
    this.compactMeeting = false,
  });

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {
  Offset? _tapPosition;
  bool isMessage = true, isReply = false, isTs = false, isGroup = false;
  Timestamp time = Timestamp.fromDate(DateTime.now());
  Map msg = {};
  final TextEditingController replyController = TextEditingController();

  Future<void> _openSharedContent(Map<String, dynamic> shared) async {
    final postId = shared['postId']?.toString() ?? '';
    final commentId = shared['commentId']?.toString() ?? '';
    if (postId.isEmpty || postId.contains('/') || commentId.contains('/')) return;
    try {
      final post = await firebaseFirestore.collection('posts').doc(postId).get();
      if (!mounted || post.data()?['status'] != 'published') {
        throw StateError('Публикация недоступна');
      }
      String? rootId;
      if (commentId.isNotEmpty) {
        final comment = await post.reference.collection('comments').doc(commentId).get();
        if (!mounted || !comment.exists) {
          throw StateError('Комментарий недоступен');
        }
        final parent = comment.data()?['parentId']?.toString() ?? '';
        rootId = parent.isEmpty ? commentId : parent;
      }
      if (!mounted) return;
      nextScreen(context, PostDetailPage(
        postId: postId,
        post: post.data()!,
        threadRootId: rootId,
      ));
    } catch (_) {
      if (mounted) {
        showSnackbar(context, LrsTheme.danger,
            context.tr('Публикация удалена или недоступна.'));
      }
    }
  }

  Widget _sharedContentCard(Map<String, dynamic> shared) {
    final comment = shared['kind'] == 'comment';
    final text = shared['text']?.toString() ?? '';
    final image = shared['imageUrl']?.toString() ?? '';
    final postId = shared['postId']?.toString() ?? '';
    return InkWell(
      onTap: postId.isEmpty || postId.contains('/')
          ? null
          : () => _openSharedContent(shared),
      child: Container(
        margin: const EdgeInsets.only(top: 7),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: const Color(0x66302110),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: LrsTheme.actionBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.tr(comment ? 'Комментарий' : 'Публикация'),
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: LrsTheme.peachLight)),
          if ((shared['authorName']?.toString() ?? '').isNotEmpty)
            Text(shared['authorName'].toString(),
                style: const TextStyle(color: LrsTheme.muted, fontSize: 12)),
          if (text.isNotEmpty)
            TranslatableText(text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white)),
          if (image.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                    imageUrl: image,
                    width: 135,
                    height: 85,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
              ),
            ),
        ]),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tapPosition = const Offset(0.0, 0.0);
  }

  @override
  void dispose() {
    replyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    msg = widget.message.data() as Map<String, dynamic>;
    final shared = msg['sharedContent'] is Map
        ? Map<String, dynamic>.from(msg['sharedContent'] as Map)
        : null;
    isMessage = msg.containsKey('message');
    final giftNoticeName = msg['giftNoticeName']?.toString();
    isReply = msg.containsKey('replyMessage');
    isGroup = !widget.isChat;
    isTs = msg.containsKey('ts');
    final timestamp = isTs ? msg['ts'] : msg['time'];
    time = timestamp is Timestamp ? timestamp : Timestamp.now();
    final currentUid = firebaseAuth.currentUser?.uid;
    final deletedFor = msg['deletedFor'];
    if (msg['deleteFor'] == currentUid ||
        (deletedFor is List && deletedFor.contains(currentUid))) {
      return const SizedBox.shrink();
    }
    Size size = MediaQuery.of(context).size;

    void storePosition(TapDownDetails details) {
      _tapPosition = details.globalPosition;
    }

    final FirebaseAuth auth = firebaseAuth;

    Future<void> deleteMessage(String messageId) async {
      final uid = auth.currentUser?.uid;
      if (uid == null) return;
      await widget.message.reference.update({
        'deletedFor': FieldValue.arrayUnion([uid]),
      });
    }

    Future<void> replyToMessage(Map message) async {
      final quote = <String, dynamic>{
        for (final key in ['message', 'name', 'sendBy', 'sender', 'sendByID'])
          if (message[key] != null) key: message[key].toString(),
      };
      await showDialog<void>(
          context: context,
          builder: (_) => _MessageReplySheet(
              chatId: widget.chatId,
              group: isGroup,
              messageId: widget.message.id,
              quote: quote));
    }

    Future<void> editMessage(String messageId) async {
      final user = auth.currentUser;
      if (user == null) return;
      final snapshot = await widget.message.reference.get();
      if (!mounted || auth.currentUser?.uid != user.uid) return;
      final data = snapshot.data() as Map<String, dynamic>?;
      if (data == null ||
          (data['sendByID'] ?? data['sender']) != user.uid ||
          data['message'] is! String) {
        return;
      }
      final controller = TextEditingController(text: data['message'] as String);
      final edited = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: LrsTheme.surface,
          title: Text(context.tr('Редактировать сообщение')),
          content: TextField(
            controller: controller,
            minLines: 2,
            maxLines: 8,
            style: const TextStyle(color: LrsTheme.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.tr('Отмена')),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(dialogContext, controller.text.trim());
                }
              },
              child: Text(context.tr('Сохранить')),
            ),
          ],
        ),
      );
      // The dialog route may animate out after the Future completes.
      if (edited != null &&
          edited != data['message'] &&
          auth.currentUser?.uid == user.uid) {
        await widget.message.reference.update({'message': edited});
      }
    }

    Future<void> copyMessage(String message) async {
      await Clipboard.setData(ClipboardData(text: message));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(context.tr('Сообщение скопировано в буфер обмена.'))),
      );
    }

    Future<void> deleteMessageForEveryone(String messageId) async {
      final uid = auth.currentUser?.uid;
      if (uid == null) return;
      final snapshot = await widget.message.reference.get();
      final data = snapshot.data() as Map<String, dynamic>?;
      if (data == null || (data['sendByID'] ?? data['sender']) != uid) return;
      final sentAt = data['ts'] ?? data['time'];
      if (sentAt is! Timestamp) return;
      final elapsed = DateTime.now().difference(sentAt.toDate());
      if (!elapsed.isNegative && elapsed <= const Duration(days: 2)) {
        if (auth.currentUser?.uid == uid) {
          await widget.message.reference.delete();
        }
      } else if (mounted) {
        showSnackbar(
          context,
          LrsTheme.surface,
          context.tr('Удалить для всех можно в течение 2 дней после отправки.'),
        );
      }
    }

    Future<void> showPopupMenu() async {
      final overlay = Overlay.of(context).context.findRenderObject();
      if (overlay == null) return;
      final action = await showMenu<String>(
        context: context,
        color: LrsTheme.surface,
        position: RelativeRect.fromRect(
          _tapPosition! & const Size(40, 40),
          Offset.zero & overlay.semanticBounds.size,
        ),
        items: [
          if (isMessage)
            PopupMenuItem(value: 'reply', child: Text(context.tr('Ответить'))),
          if (isMessage && widget.sentByMe)
            PopupMenuItem(
                value: 'edit', child: Text(context.tr('Редактировать'))),
          if (isMessage)
            PopupMenuItem(value: 'copy', child: Text(context.tr('Копировать'))),
          PopupMenuItem(
            value: 'delete_me',
            child: Text(context.tr('Удалить у меня')),
          ),
          if (widget.sentByMe)
            PopupMenuItem(
              value: 'delete_everyone',
              child: Text(context.tr('Удалить для всех')),
            ),
        ],
      );
      if (!mounted || action == null) return;
      try {
        switch (action) {
          case 'reply':
            await replyToMessage(msg);
            break;
          case 'edit':
            await editMessage(widget.message.id);
            break;
          case 'copy':
            await copyMessage(msg['message'].toString());
            break;
          case 'delete_me':
            await deleteMessage(widget.message.id);
            break;
          case 'delete_everyone':
            await deleteMessageForEveryone(widget.message.id);
            break;
        }
      } catch (_) {
        if (mounted) {
          showSnackbar(
            context,
            LrsTheme.danger,
            context.tr(
                'Операция не выполнена. Проверьте соединение и повторите попытку.'),
          );
        }
      }
    }

    final compactMeeting = widget.compactMeeting && isMessage && !isReply && shared == null &&
        (giftNoticeName == null || giftNoticeName.isEmpty);
    final compactText = compactMeeting;
    final messageStatus = Align(
                        alignment: Alignment.centerRight,
                        widthFactor: compactMeeting ? 1 : null,
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          children: [
                            if (widget.sentByMe)
                              FaIcon(
                                FontAwesomeIcons.check,
                                size: compactMeeting ? 10 : 15,
                                color: widget.isRead
                                    ? Colors.greenAccent
                                    : Colors.grey,
                              ),
                            Text(
                              context.l10n.time(time.toDate(),
                                  alwaysUse24HourFormat:
                                      MediaQuery.alwaysUse24HourFormatOf(
                                          context)),
                              style: TextStyle(
                                fontSize: compactMeeting ? 9 : 12,
                                height: compactMeeting ? 1.1 : null,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      );

    return GestureDetector(
      onTapDown: storePosition,
      onLongPress: () {
        showPopupMenu();
      },
      child: Container(
        padding: EdgeInsets.only(
          top: compactMeeting ? 2 : 4,
          bottom: compactMeeting ? 2 : 4,
          left: compactMeeting ? 10 : widget.sentByMe ? 0 : 15,
          right: compactMeeting ? 10 : widget.sentByMe ? 24 : 0,
        ),
        alignment:
            widget.sentByMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: compactMeeting ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            widget.sentByMe
                ? const SizedBox.shrink()
                : GestureDetector(
                    onTap: () async {
                      final userInfo = await firebaseFirestore
                          .collection('users')
                          .doc(widget.sender)
                          .get();

                      if (!mounted) return;
                      nextScreen(
                        context,
                        SomebodyProfile(
                          uid: widget.sender,
                          photoUrl: userInfo.get('profilePic'),
                          name: widget.name,
                          userInfo: userInfo.data() as Map,
                        ),
                      );
                    },
                    child: compactMeeting
                        ? SizedBox(width: 32, height: 32, child: FittedBox(fit: BoxFit.scaleDown, child: widget.avatar ?? const SizedBox.shrink()))
                        : widget.avatar ?? const SizedBox.shrink(),
                  ),
            const SizedBox(width: 5),
            Flexible(
                child: Container(
              constraints: BoxConstraints(
                  maxWidth: compactMeeting
                      ? size.width * 2 / 3 - (widget.sentByMe ? 0 : 47)
                      : size.width * (isReply ? 0.9 : 0.74)),
              margin: compactMeeting ? EdgeInsets.zero : widget.sentByMe
                  ? EdgeInsets.only(left: isReply ? 8 : 30)
                  : EdgeInsets.only(right: isReply ? 8 : 30),
              padding: compactMeeting ? EdgeInsets.zero : const EdgeInsets.only(
                top: 10,
                bottom: 10,
                left: 10,
                right: 10,
              ),
              decoration: compactMeeting ? null : BoxDecoration(
                borderRadius: widget.sentByMe
                    ? const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                        bottomLeft: Radius.circular(20),
                      )
                    : const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                        bottomRight: Radius.circular(20),
                      ),
                color: widget.sentByMe
                    ? const Color(0xE0442D24)
                    : const Color(0xE02B211D),
              ),
              child: Column(
                crossAxisAlignment: compactMeeting && widget.sentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Text(
                    compactMeeting ? widget.name : widget.name.toUpperCase(),
                    textAlign: TextAlign.start,
                    style: TextStyle(
                      fontSize: compactMeeting ? 11 : 12,
                      fontWeight: compactMeeting ? FontWeight.normal : FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  if (isReply)
                    Container(
                      margin: const EdgeInsets.only(top: 5),
                      padding: const EdgeInsets.only(left: 10),
                      decoration: const BoxDecoration(
                        border: Border(
                            left: BorderSide(color: Colors.white, width: 2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${msg['replyMessage'][isGroup ? 'name' : 'sendBy'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white),
                          ),
                          TranslatableText(
                            '${msg['replyMessage']['message'] ?? ''}',
                            autoTranslate: true,
                            showAction: false,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  SizedBox(height: compactMeeting ? 1 : 5),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: compactMeeting && widget.sentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      isMessage
                          ? shared != null
                              ? const SizedBox.shrink()
                              : giftNoticeName != null && giftNoticeName.isNotEmpty
                              ? Text(
                                  '${context.tr('Подарок {name} подарен!', args: {
                                        'name': context.tr(giftNoticeName)
                                      })} ❤️',
                                  textAlign: compactMeeting && widget.sentByMe ? TextAlign.end : TextAlign.start,
                                  style: const TextStyle(
                                      fontSize: 14, color: Colors.white))
                              : TranslatableText(
                                  '${widget.message['message'] ?? ''}',
                                  autoTranslate: false,
                                  showAction: true,
                                  compactMeeting: compactMeeting,
                                  compactFooter: compactText ? messageStatus : null,
                                  textAlign: compactMeeting && widget.sentByMe ? TextAlign.end : TextAlign.start,
                                  style: TextStyle(
                                    fontSize: compactMeeting ? 13 : 14,
                                    height: compactMeeting ? 1.15 : null,
                                    color: Colors.white,
                                  ),
                                )
                          : GestureDetector(
                              onTap: () {
                                if (widget.sentByMe) {
                                  nextScreenReplace(
                                    context,
                                    const ShopPage(tabIndex: 1),
                                  );
                                } else {
                                  nextScreenReplace(
                                    context,
                                    const ShopPage(tabIndex: 0),
                                  );
                                }
                              },
                              child: Column(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: AspectRatio(
                                      aspectRatio: 512 / 328,
                                      child: Image.asset(
                                        '${widget.message['image']}',
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            const Center(
                                                child: Icon(Icons
                                                    .card_giftcard_outlined)),
                                      ),
                                    ),
                                  ),
                                  Text(
                                    context
                                        .tr(widget.message['name'] as String),
                                    textAlign: TextAlign.start,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                      if (shared != null) _sharedContentCard(shared),
                      if (!compactText) messageStatus,
                    ],
                  ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }
}

class _MessageReplySheet extends StatefulWidget {
  const _MessageReplySheet(
      {required this.chatId,
      required this.messageId,
      required this.group,
      required this.quote});
  final String chatId, messageId;
  final bool group;
  final Map<String, dynamic> quote;
  @override
  State<_MessageReplySheet> createState() => _MessageReplySheetState();
}

class _MessageReplySheetState extends State<_MessageReplySheet> {
  final _controller = TextEditingController();
  late final ChatSubmissionService _service;
  ChatSubmission? _request;
  bool _restoring = true, _failedRestore = false, _sending = false;
  String? _notice;
  bool get _current => mounted && _service.isCurrentSession;
  @override
  void initState() {
    super.initState();
    _service = ChatSubmissionService();
    _restore();
  }

  Future<void> _restore() async {
    setState(() {
      _restoring = true;
      _failedRestore = false;
    });
    try {
      final request = await _service.restore(widget.chatId,
          group: widget.group, replyId: widget.messageId);
      if (!_current) return;
      setState(() {
        _request = request;
        if (request != null) {
          _controller.text = request.text;
          _notice =
              'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
        }
      });
    } catch (_) {
      if (_current)
        setState(() {
          _failedRestore = true;
          _notice = 'Не удалось восстановить отправку. Попробуйте ещё раз.';
        });
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _send() async {
    if (!_current || _sending || _restoring) return;
    if (_failedRestore) {
      await _restore();
      return;
    }
    if (_controller.text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _notice = null;
    });
    try {
      if (_request?.write.failed == true) _request = null;
      _request ??= _service.start(
          chatId: widget.chatId,
          text: _controller.text.trim(),
          group: widget.group,
          replyId: widget.messageId,
          reply: widget.quote);
      final confirmed = await _request!.write.wait();
      if (!_current) return;
      if (!confirmed) {
        setState(() => _notice =
            'Подтверждение ещё не получено. Сообщение может быть отправлено. Нажмите «Проверить отправку».');
        return;
      }
      _service.acknowledge(widget.chatId, _request!,
          group: widget.group, replyId: widget.messageId);
      Navigator.pop(context);
    } catch (_) {
      if (_current) setState(() => _notice = 'Не удалось отправить ответ.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          scrollable: true,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          title: Text(context.tr('Написать ответ')),
          content: SizedBox(
              width: math.min(560, MediaQuery.sizeOf(context).width - 56),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_restoring) const LinearProgressIndicator(),
                if ('${widget.quote['message'] ?? ''}'.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TranslatableText(
                        '${widget.quote['message']}',
                        autoTranslate: true,
                        showAction: false,
                        style: const TextStyle(color: LrsTheme.muted),
                      ),
                    ),
                  ),
                TextField(
                    controller: _controller,
                    minLines: 3,
                    maxLines: null,
                    readOnly: _restoring ||
                        _failedRestore ||
                        _sending ||
                        (_request != null && !_request!.write.failed),
                    decoration: InputDecoration(
                        labelText: context.tr('Напишите свой ответ'))),
                if (_notice != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(context.tr(_notice!))),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.tr('Закрыть'))),
            TextButton(
                onPressed: _restoring || _sending ? null : _send,
                child: Text(context.tr(_failedRestore
                    ? 'Повторить'
                    : _request != null
                        ? 'Проверить отправку'
                        : 'Ответить'))),
          ]);
}
