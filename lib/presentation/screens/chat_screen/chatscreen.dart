import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/app/widgets/message_tile.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/presentation/screens/shop/shop.dart';
import 'package:wbrs/service/chat_submission.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/paged_firestore_history.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen(
      {super.key,
      required this.chatWithUsername,
      required this.photoUrl,
      required this.id,
      required this.chatId,
      this.submissions,
      this.writeTimeout = const Duration(seconds: 15)});
  final String chatWithUsername, photoUrl, id, chatId;
  final ChatSubmissionService? submissions;
  final Duration writeTimeout;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  final _reading = <String>{};
  late final String? _ownerUid;
  late final ChatSubmissionService _submissions;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _messages;
  Map<String, dynamic> _other = {};
  bool _loading = true,
      _deleted = false,
      _sending = false,
      _restoring = true,
      _restoreFailed = false,
      _notificationBusy = false,
      _notifications = true;
  String? _loadError, _notice;
  ChatSubmission? _submission;
  int _generation = 0;
  final _history = PagedFirestoreHistory(60);
  bool _loadingOlder = false, _olderError = false;
  Timer? _messageWaitTimer;
  bool _messageWaitExpired = false;
  bool get _current =>
      mounted &&
      _ownerUid != null &&
      firebaseAuth.currentUser?.uid == _ownerUid;
  bool get _locked =>
      _restoreFailed ||
      _restoring ||
      _sending ||
      (_submission != null && !_submission!.write.failed);
  DocumentReference<Map<String, dynamic>> get _room =>
      firebaseFirestore.collection('chats').doc(widget.chatId);

  @override
  void initState() {
    super.initState();
    _ownerUid = firebaseAuth.currentUser?.uid;
    _submissions = widget.submissions ?? ChatSubmissionService();
    _load();
    _restore();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (!_current) return;
    setState(() {
      _loading = true;
      _loadError = null;
      _history.reset();
      _loadingOlder = false;
      _olderError = false;
    });
    try {
      final snapshots = await Future.wait([
        firebaseFirestore.collection('users').doc(widget.id).get(),
        _room.get(),
      ]).timeout(const Duration(seconds: 20));
      if (!_current || generation != _generation) return;
      final other = snapshots[0].data();
      final room = snapshots[1].data();
      if (room == null ||
          (room['user1'] != _ownerUid && room['user2'] != _ownerUid)) {
        throw StateError('Чат недоступен');
      }
      setState(() {
        _other = other ?? {};
        _deleted = !snapshots[0].exists ||
            other == null ||
            other['deleted'] == true ||
            other['status'] == 'deleted' ||
            other['registrationStatus'] == 'deleted';
        _notifications = !(room['usersWOutNotifications'] as List? ?? const [])
            .contains(_ownerUid);
        _messages = _watchMessages();
        _loading = false;
      });
      if (!_deleted && _current) {
        // Presence is advisory and may fail independently of reading the chat.
        firebaseFirestore
            .collection('users')
            .doc(_ownerUid)
            .update({'chatWithId': widget.id}).catchError((_) {});
        if (room['lastMessageSendByID'] != _ownerUid) {
          _room.update({'unreadMessage': 0}).catchError((_) {});
        }
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() {
          _loading = false;
          _loadError =
              'Не удалось открыть чат. Проверьте соединение и повторите попытку.';
        });
      }
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _watchMessages() {
    _messageWaitTimer?.cancel();
    _messageWaitExpired = false;
    final timer = Timer(const Duration(seconds: 20), () {
      if (_current) setState(() => _messageWaitExpired = true);
    });
    _messageWaitTimer = timer;
    final generation = _generation;
    return _room
        .collection('chats')
        .orderBy('ts', descending: true)
        .limit(_history.pageSize + 1)
        .snapshots()
        .map((snapshot) {
      timer.cancel();
      if (generation == _generation) _history.receiveLive(snapshot);
      return snapshot;
    });
  }

  Future<void> _loadOlderMessages() async {
    final cursor = _history.cursor;
    if (!_current || _loadingOlder || !_history.hasMore || cursor == null)
      return;
    final generation = _generation;
    setState(() {
      _loadingOlder = true;
      _olderError = false;
    });
    try {
      final page = await _room
          .collection('chats')
          .orderBy('ts', descending: true)
          .startAfterDocument(cursor)
          .limit(_history.pageSize + 1)
          .get()
          .timeout(const Duration(seconds: 20));
      if (!_current || generation != _generation) return;
      setState(() => _history.appendOlder(page));
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() => _olderError = true);
      }
    } finally {
      if (_current && generation == _generation) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  Future<void> _restore() async {
    if (_current)
      setState(() {
        _restoring = true;
        _restoreFailed = false;
      });
    try {
      final saved = await _submissions.restore(widget.chatId);
      if (!_current) return;
      setState(() {
        _submission = saved;
        if (saved != null) {
          _composer.text = saved.text;
          _notice =
              'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
        }
      });
    } catch (_) {
      if (_current)
        setState(() {
          _restoreFailed = true;
          _notice = 'Не удалось восстановить отправку. Попробуйте ещё раз.';
        });
    } finally {
      if (_current) setState(() => _restoring = false);
    }
  }

  Future<void> _send() async {
    if (_restoreFailed) {
      await _restore();
      return;
    }
    if (!_current || _sending || _restoring || _composer.text.trim().isEmpty)
      return;
    setState(() {
      _sending = true;
      _notice = null;
    });
    try {
      if (_submission?.write.failed == true) _submission = null;
      _submission ??= _submissions.start(
          chatId: widget.chatId,
          recipientId: widget.id,
          text: _composer.text.trim());
      final confirmed =
          await _submission!.write.wait(timeout: widget.writeTimeout);
      if (!_current) return;
      if (!confirmed) {
        setState(() => _notice =
            'Подтверждение ещё не получено. Сообщение может быть отправлено. Нажмите «Проверить отправку».');
        return;
      }
      _submissions.acknowledge(widget.chatId, _submission!);
      setState(() {
        _submission = null;
        _composer.clear();
      });
      if (_scroll.hasClients)
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    } catch (_) {
      if (_current)
        setState(() => _notice =
            'Не удалось отправить сообщение. Текст сохранён — попробуйте ещё раз.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _markRead(DocumentSnapshot<Map<String, dynamic>> message) async {
    if (!_current || !_reading.add(message.id)) return;
    try {
      await message.reference.update({'isRead': true});
    } catch (_) {
      _reading.remove(message.id); // Allow a later snapshot to retry.
    }
  }

  Future<void> _toggleNotifications() async {
    if (!_current || _notificationBusy || _deleted) return;
    setState(() => _notificationBusy = true);
    final enable = !_notifications;
    try {
      await _room.update({
        'usersWOutNotifications': enable
            ? FieldValue.arrayRemove([_ownerUid])
            : FieldValue.arrayUnion([_ownerUid])
      });
      if (_current) setState(() => _notifications = enable);
    } catch (_) {
      if (_current)
        setState(() =>
            _notice = 'Не удалось изменить уведомления. Проверьте соединение.');
    } finally {
      if (mounted) setState(() => _notificationBusy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _messageWaitTimer?.cancel();
    // Never write on behalf of a new account after a logout/account switch.
    if (_ownerUid != null && firebaseAuth.currentUser?.uid == _ownerUid) {
      firebaseFirestore
          .collection('users')
          .doc(_ownerUid)
          .update({'chatWithId': ''}).catchError((_) {});
    }
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _center(String message, {VoidCallback? retry}) => Center(
      child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ClrsPanel(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(context.tr(message), textAlign: TextAlign.center),
            if (retry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: retry, child: Text(context.tr('Повторить')))
            ],
          ]))));

  Widget _messageList() => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _messages,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return _center(
              'Не удалось загрузить сообщения. Проверьте подключение.',
              retry: _load);
        if (!snapshot.hasData)
          return _messageWaitExpired
              ? _center(
                  'Не удалось загрузить сообщения. Проверьте подключение.',
                  retry: _load)
              : const Center(child: CircularProgressIndicator());
        final docs = _history.documents;
        if (docs.isEmpty) return _center('Сообщений пока нет');
        final hasOlder = _history.hasMore;
        return ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: docs.length + (hasOlder ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == docs.length) {
                return Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_olderError)
                    Text(context.tr(
                        'Не удалось загрузить сообщения. Проверьте подключение.')),
                  TextButton(
                      onPressed: _loadingOlder ? null : _loadOlderMessages,
                      child: _loadingOlder
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : Text(context.tr(
                              _olderError ? 'Повторить' : 'Загрузить ещё'))),
                ]));
              }
              final doc = docs[index];
              final data = doc.data();
              if (data['sendByID'] != _ownerUid && data['isRead'] != true)
                _markRead(doc);
              return MessageTile(
                  key: ValueKey(doc.id),
                  message: doc,
                  chatId: widget.chatId,
                  sender: '${data['sendByID'] ?? ''}',
                  name: '${data['sendBy'] ?? ''}',
                  sentByMe: data['sendByID'] == _ownerUid,
                  isRead: data['isRead'] == true,
                  isChat: true,
                  avatar: userImageWithCircle(
                      '${_other['profilePicThumb'] ?? _other['profilePic'] ?? ''}',
                      '${_other['группа'] ?? ''}',
                      _other['online'] == true,
                      40.0,
                      40.0));
            });
      });

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      backgroundAsset: 'assets/wallpaper/8.jpg',
      appBar: AppBar(
          title: Text(widget.chatWithUsername,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
                tooltip: context.tr(_notifications
                    ? 'Выключить уведомления'
                    : 'Включить уведомления'),
                onPressed:
                    _notificationBusy || _deleted ? null : _toggleNotifications,
                icon: Icon(_notifications
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined)),
            IconButton(
                tooltip: context.tr('Профиль'),
                onPressed: _loading || _deleted
                    ? null
                    : () => nextScreen(
                        context,
                        SomebodyProfile(
                            uid: widget.id,
                            photoUrl: widget.photoUrl,
                            name: widget.chatWithUsername,
                            userInfo: _other)),
                icon: const Icon(Icons.person_outline)),
          ]),
      body: !_current
          ? _center('Сеанс завершён. Войдите снова.')
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
                  ? _center(_loadError!, retry: _load)
                  : _deleted
                      ? _center(
                          'Аккаунт пользователя был удален. Чат больше недоступен.')
                      : SafeArea(
                          top: false,
                          child: Column(children: [
                            if (MediaQuery.sizeOf(context).height -
                                    MediaQuery.viewInsetsOf(context).bottom >
                                400)
                              Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child: Row(children: [
                                    Expanded(
                                        child: Text(
                                            _other['online'] == true
                                                ? context.tr('В сети')
                                                : _other['lastOnlineTS']
                                                        is Timestamp
                                                    ? context.tr(
                                                        'Последнее посещение: {date}',
                                                        args: {
                                                            'date': context.l10n
                                                                .dateTime((_other[
                                                                            'lastOnlineTS']
                                                                        as Timestamp)
                                                                    .toDate())
                                                          })
                                                    : context.tr('Не в сети'),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: LrsTheme.muted))),
                                  ])),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: TextButton.icon(
                                    style: TextButton.styleFrom(
                                        foregroundColor: Colors.white),
                                    onPressed: () => nextScreen(
                                      context,
                                      ShopPage(
                                        tabIndex: 1,
                                        preferredRecipientUid: widget.id,
                                        preferredChatId: widget.chatId,
                                      ),
                                    ),
                                    icon: const Icon(Icons.card_giftcard),
                                    label: Text(
                                      context.l10n.locale.languageCode == 'ru'
                                          ? 'Подарить Подарок ❤️'
                                          : '${context.tr('Подарить подарок')} ❤️',
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(child: _messageList()),
                            if (_notice != null)
                              ConstrainedBox(
                                  constraints: BoxConstraints(
                                      maxHeight:
                                          MediaQuery.sizeOf(context).height *
                                              .18),
                                  child: SingleChildScrollView(
                                      padding: const EdgeInsets.fromLTRB(
                                          12, 4, 12, 4),
                                      child: Text(context.tr(_notice!),
                                          style: const TextStyle(
                                              color: LrsTheme.peachLight)))),
                            if (_restoring) const LinearProgressIndicator(),
                            Container(
                                color: LrsTheme.surfaceGlass,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Expanded(
                                          child: TextField(
                                              controller: _composer,
                                              readOnly: _locked,
                                              minLines: 1,
                                              maxLines: MediaQuery.sizeOf(
                                                                  context)
                                                              .height -
                                                          MediaQuery
                                                                  .viewInsetsOf(
                                                                      context)
                                                              .bottom <
                                                      300
                                                  ? 1
                                                  : 3,
                                              style:
                                                  const TextStyle(fontSize: 16),
                                              decoration: InputDecoration(
                                                  hintText: context.tr(
                                                      'Введите сообщение')))),
                                      IconButton(
                                          tooltip: context.tr(_restoreFailed
                                              ? 'Повторить'
                                              : _submission != null
                                                  ? 'Проверить отправку'
                                                  : 'Отправить сообщение'),
                                          onPressed: _sending || _restoring
                                              ? null
                                              : _send,
                                          icon: _sending
                                              ? const SizedBox.square(
                                                  dimension: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2))
                                              : Icon(
                                                  _restoreFailed ||
                                                          _submission != null
                                                      ? Icons.refresh
                                                      : Icons.send,
                                                  color: LrsTheme.peach)),
                                    ])),
                          ])));
}
