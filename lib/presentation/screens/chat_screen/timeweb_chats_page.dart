import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_chat_flow.dart';
import 'package:wbrs/service/timeweb_chat_events.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

const timewebChatsRoute = '/clrs/native/chats';
const _chatRoute = '/clrs/native/chat';

class TimewebChatsPage extends StatefulWidget {
  const TimewebChatsPage({
    super.key,
    required this.runtime,
    required this.initialPage,
  });
  final TimewebAppRuntime runtime;
  final TimewebCurrentReadPage initialPage;
  @override
  State<TimewebChatsPage> createState() => _TimewebChatsPageState();
}

class _TimewebChatsPageState extends State<TimewebChatsPage>
    with WidgetsBindingObserver {
  AppSessionLease? _lease;
  StreamSubscription<AppSessionState>? _subscription;
  TimewebChatEventPump? _events;
  List<TimewebCurrentChat> _chats = [];
  TimewebCurrentReadCursor? _next;
  bool _invalid = false, _working = false;
  String? _error;
  String _filter = 'Все', _search = '';
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      _lease = widget.runtime.session.captureLease();
      widget.initialPage.requireCurrent();
      _chats = widget.initialPage.chats;
      _next = widget.initialPage.nextCursor;
    } catch (_) {
      _invalid = true;
    }
    _subscription = widget.runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    _events = TimewebChatEventPump(
      isCurrent: () => _current,
      isVisible: () => ModalRoute.of(context)?.isCurrent == true,
      read: (after) async {
        _lease!.requireCurrent();
        final page = await widget.runtime.client.readCurrent(
          TimewebCurrentReadRequest.events(limit: 100, after: after),
        );
        _lease!.requireCurrent();
        return page;
      },
      apply: (events) async => events.isEmpty ? true : await _load(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current && _foreground) _events?.start();
    });
  }

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _current) {
      _events?.start();
    } else {
      _events?.pause();
    }
  }

  bool get _current => mounted && !_invalid && (_lease?.isCurrent ?? false);
  void _invalidate() {
    if (!mounted || _invalid) return;
    _events?.close();
    setState(() {
      _invalid = true;
      _chats = [];
      _next = null;
      _generation++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).popUntil(
          (route) =>
              route.settings.name != timewebChatsRoute &&
              route.settings.name != _chatRoute,
        );
      }
    });
  }

  Future<bool> _load({bool more = false}) async {
    if (!_current || _working || (more && _next == null)) return false;
    final generation = ++_generation;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final page = await widget.runtime.readChats(cursor: more ? _next : null);
      if (!_current || generation != _generation) return false;
      page.requireCurrent();
      final chats = <String, TimewebCurrentChat>{
        if (more)
          for (final chat in _chats) chat.chatId: chat,
        for (final chat in page.chats) chat.chatId: chat,
      }.values.toList();
      // Preserve the newest-to-oldest window. At its bound stop paging;
      // never skip rows by advancing a cursor past discarded old entries.
      final bounded = chats.length >= 300;
      if (chats.length > 300) chats.removeRange(300, chats.length);
      setState(() {
        _chats = chats;
        _next = bounded ? null : page.nextCursor;
      });
      return true;
    } catch (_) {
      if (_current) {
        setState(
          () => _error = 'Не удалось загрузить чаты. Проверьте подключение.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _open(TimewebCurrentChat chat) async {
    if (!_current || _working) return;
    _events?.pause();
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final flow = await widget.runtime.openChat(chat);
      if (!mounted || !_current || ModalRoute.of(context)?.isCurrent != true) {
        flow.close();
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: _chatRoute),
          builder: (_) => TimewebChatPage(flow: flow),
        ),
      );
    } catch (_) {
      if (_current) {
        setState(
          () => _error =
              'Не удалось открыть чат. Проверьте соединение и повторите попытку.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (_current) await _load();
    if (_current && _foreground) _events?.start();
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _events?.close();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var chats = <TimewebCurrentChat>[];
    if (_current) {
      try {
        chats = _chats
            .where(
              (chat) =>
                  (_filter == 'Архив' ? chat.archived : !chat.archived) &&
                  (_filter != 'Новые' ||
                      chat.lastSequence > chat.readThrough) &&
                  (chat.name ?? '').toLowerCase().contains(
                    _search.toLowerCase(),
                  ),
            )
            .toList();
      } catch (_) {
        chats = [];
      }
    }
    return ClrsScaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: context.tr('Обновить'),
            onPressed: _current && !_working ? _load : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_current
          ? Center(child: Text(context.tr('Сеанс завершён. Войдите снова.')))
          : SafeArea(
              top: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const ClrsBrandHeader(),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.tr('Чаты'),
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(
                              width: 120,
                              child: FittedBox(child: ClrsMotto(size: 17)),
                            ),
                          ],
                        ),
                        Text(
                          context.tr('Значимые разговоры с настоящими людьми'),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          onChanged: (text) => setState(() => _search = text),
                          decoration: InputDecoration(
                            hintText: context.tr('Поиск по имени'),
                            prefixIcon: const Icon(Icons.search),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 54,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      children: [
                        for (final label in [
                          'Все',
                          'Новые',
                          'Избранные',
                          'Архив',
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                backgroundColor: _filter == label
                                    ? LrsTheme.actionGlass
                                    : Colors.transparent,
                                foregroundColor: LrsTheme.text,
                                side: const BorderSide(
                                  color: LrsTheme.actionBorder,
                                ),
                              ),
                              onPressed: label == 'Избранные'
                                  ? null
                                  : () => setState(() => _filter = label),
                              child: Text(context.tr(label)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_working) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(context.tr(_error!)),
                    ),
                  Expanded(
                    child: chats.isEmpty
                        ? Center(
                            child: Text(
                              context.tr('Здесь нет подходящих чатов'),
                            ),
                          )
                        : ListView.builder(
                            key: const ValueKey('timeweb-chat-list'),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            itemCount: chats.length,
                            itemBuilder: (context, index) {
                              final chat = chats[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: ClrsPanel(
                                  padding: EdgeInsets.zero,
                                  child: ListTile(
                                    key: ValueKey(
                                      'timeweb-chat-${chat.chatId}',
                                    ),
                                    leading: Container(
                                      width: 46,
                                      height: 46,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: LrsTheme.peach,
                                          width: .8,
                                        ),
                                      ),
                                      child: const Icon(Icons.person_outline),
                                    ),
                                    title: Text(
                                      chat.name ?? context.tr('Чаты'),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: _working ? null : () => _open(chat),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  if (_next != null)
                    TextButton(
                      key: const ValueKey('timeweb-chat-load-more'),
                      onPressed: _working ? null : () => _load(more: true),
                      child: Text(context.tr('Загрузить ещё')),
                    ),
                ],
              ),
            ),
    );
  }
}

class TimewebChatPage extends StatefulWidget {
  const TimewebChatPage({super.key, required this.flow});
  final TimewebChatFlow flow;
  @override
  State<TimewebChatPage> createState() => _TimewebChatPageState();
}

class _TimewebChatPageState extends State<TimewebChatPage>
    with WidgetsBindingObserver {
  final _composer = TextEditingController();
  final _messageScroll = ScrollController();
  StreamSubscription<AppSessionState>? _subscription;
  TimewebChatEventPump? _events;
  bool _invalid = false, _sending = false, _reading = false;
  String? _notice;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _messageScroll.addListener(_onScroll);
    try {
      widget.flow.requireCurrent();
      _composer.text = widget.flow.pendingText ?? '';
      if (widget.flow.sendNeedsCheck) {
        _notice =
            'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
      }
    } catch (_) {
      _invalid = true;
    }
    _subscription = widget.flow.sessionStates.listen((_) {
      if (!_current) _invalidate();
    });
    _events = TimewebChatEventPump(
      isCurrent: () => _current,
      isVisible: () => ModalRoute.of(context)?.isCurrent == true,
      read: widget.flow.readEvents,
      apply: _applyEvents,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current) {
        unawaited(_markRead());
        if (_foreground) _events?.start();
      }
    });
  }

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _current) {
      _events?.start();
    } else {
      _events?.pause();
    }
  }

  void _onScroll() {
    if (_current && _messageScroll.offset < 24) unawaited(_markRead());
  }

  Future<bool> _applyEvents(List<TimewebCurrentEvent> events) async {
    if (!_current || _reading || _sending) return false;
    final messages = widget.flow.messages;
    final newest = messages.isEmpty ? 0 : messages.first.sequence;
    final changed = events.any(
      (event) =>
          event.chatId == widget.flow.chatId &&
          event.kind == TimewebCurrentEventKind.messageCreated &&
          event.sequence! > newest,
    );
    if (!changed) return true;
    setState(() => _reading = true);
    try {
      await widget.flow.loadUpdates().timeout(widget.flow.observationTimeout);
      if (!mounted || !_current || ModalRoute.of(context)?.isCurrent != true) {
        return false;
      }
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_current) unawaited(_markRead());
      });
      return true;
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  bool get _current {
    if (!mounted || _invalid) return false;
    try {
      widget.flow.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    if (!mounted || _invalid) return;
    _events?.close();
    setState(() {
      _invalid = true;
      _composer.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _markRead() async {
    if (!mounted ||
        !_current ||
        ModalRoute.of(context)?.isCurrent != true ||
        (_messageScroll.hasClients && _messageScroll.offset >= 24)) {
      return;
    }
    try {
      await widget.flow.markDisplayedRead().timeout(
        widget.flow.observationTimeout,
      );
    } catch (_) {}
    // Own read receipt is advisory to the composer and never marks peer-read.
  }

  Future<void> _load({
    bool older = false,
    bool afterConfirmedSend = false,
  }) async {
    if (!_current || _reading || (_sending && !afterConfirmedSend)) return;
    setState(() {
      _reading = true;
      _notice = null;
    });
    try {
      await (older ? widget.flow.loadOlder() : widget.flow.loadLatest())
          .timeout(widget.flow.observationTimeout);
      if (!mounted || !_current || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      setState(() {});
      if (!older) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_current) unawaited(_markRead());
        });
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _notice =
              'Не удалось загрузить сообщения. Проверьте подключение.',
        );
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _send() async {
    if (!_current || _sending || _reading) return;
    final check = widget.flow.sendNeedsCheck;
    if (!check && _composer.text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _notice = null;
    });
    try {
      final original = check
          ? widget.flow.checkSend()
          : widget.flow.send(_composer.text);
      final result = await original.timeout(widget.flow.observationTimeout);
      if (!mounted || !_current || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      if (result == TimewebChatWriteOutcome.unknown) {
        setState(
          () => _notice =
              'Подтверждение ещё не получено. Сообщение может быть отправлено. Нажмите «Проверить отправку».',
        );
      } else {
        widget.flow.acceptDisplayedSendResult();
        if (result == TimewebChatWriteOutcome.confirmed) {
          _composer.clear();
          await _load(afterConfirmedSend: true);
        } else {
          setState(
            () => _notice =
                'Не удалось отправить сообщение. Текст сохранён; попробуйте ещё раз.',
          );
        }
      }
    } on TimeoutException {
      if (_current) {
        setState(
          () => _notice =
              'Подтверждение ещё не получено. Сообщение может быть отправлено. Нажмите «Проверить отправку».',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = widget.flow.sendNeedsCheck
              ? 'Подтверждение ещё не получено. Сообщение может быть отправлено. Нажмите «Проверить отправку».'
              : 'Не удалось отправить сообщение. Текст сохранён; попробуйте ещё раз.',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events?.close();
    _messageScroll.dispose();
    widget.flow.close();
    unawaited(_subscription?.cancel());
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final pending = current && widget.flow.sendNeedsCheck;
    final messages = current ? widget.flow.messages : <TimewebCurrentMessage>[];
    return ClrsScaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          current ? widget.flow.name ?? context.tr('Чаты') : context.tr('Чаты'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('timeweb-chat-refresh'),
            tooltip: context.tr('Обновить'),
            onPressed: current && !_reading && !_sending ? _load : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !current
          ? Center(child: Text(context.tr('Сеанс завершён. Войдите снова.')))
          : SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 320;
                  return Column(
                    children: [
                      if (!compact)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 14),
                          child: ClrsBrandHeader(),
                        ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: SizedBox(
                          height: 36,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: TextButton.icon(
                              key: const ValueKey('timeweb-chat-gift'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                disabledForegroundColor: Colors.white,
                              ),
                              onPressed: null,
                              icon: const Icon(Icons.card_giftcard),
                              label: Text(
                                '${context.tr('Подарить подарок')} ❤️',
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_reading) const LinearProgressIndicator(),
                      Expanded(
                        child: messages.isEmpty
                            ? Center(
                                child: Text(context.tr('Сообщений пока нет')),
                              )
                            : ListView.builder(
                                controller: _messageScroll,
                                key: const ValueKey('timeweb-chat-messages'),
                                reverse: true,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                itemCount:
                                    messages.length +
                                    (widget.flow.hasOlder ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index == messages.length) {
                                    return TextButton(
                                      key: const ValueKey('timeweb-chat-older'),
                                      onPressed: _reading || _sending
                                          ? null
                                          : () => _load(older: true),
                                      child: Text(context.tr('Загрузить ещё')),
                                    );
                                  }
                                  final message = messages[index];
                                  final mine =
                                      message.senderUid == widget.flow.ownerUid;
                                  final date = message.createdAt == null
                                      ? null
                                      : DateTime.tryParse(message.createdAt!);
                                  return Align(
                                    alignment: mine
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    child: Container(
                                      key: ValueKey(
                                        'timeweb-message-${message.messageId}',
                                      ),
                                      constraints: BoxConstraints(
                                        maxWidth: constraints.maxWidth * .72,
                                      ),
                                      margin: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      padding: const EdgeInsets.all(11),
                                      decoration: BoxDecoration(
                                        color: mine
                                            ? LrsTheme.actionGlass
                                            : LrsTheme.surfaceGlass,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: LrsTheme.actionBorder,
                                          width: .8,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (message.quote?.text != null)
                                            Text(
                                              message.quote!.text!,
                                              style: const TextStyle(
                                                color: LrsTheme.muted,
                                                fontSize: 12,
                                              ),
                                            ),
                                          if (message.text != null)
                                            Text(message.text!)
                                          else
                                            const Icon(
                                              Icons.description_outlined,
                                            ),
                                          if (date != null)
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: Text(
                                                context.l10n.time(
                                                  date.toLocal(),
                                                ),
                                                style: const TextStyle(
                                                  color: LrsTheme.muted,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      if (_notice != null)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight * .2,
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            child: Text(context.tr(_notice!)),
                          ),
                        ),
                      Container(
                        color: LrsTheme.surfaceGlass,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: context.tr('Фото'),
                              onPressed: null,
                              icon: const Icon(Icons.attach_file),
                            ),
                            Expanded(
                              child: TextField(
                                key: const ValueKey('timeweb-chat-composer'),
                                controller: _composer,
                                readOnly: _sending || pending,
                                minLines: 1,
                                maxLines: compact ? 1 : 3,
                                maxLength: 4096,
                                decoration: InputDecoration(
                                  counterText: '',
                                  hintText: context.tr('Введите сообщение'),
                                ),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('timeweb-chat-send'),
                              tooltip: context.tr(
                                pending
                                    ? 'Проверить отправку'
                                    : 'Отправить сообщение',
                              ),
                              onPressed: _sending || _reading ? null : _send,
                              icon: _sending
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      pending ? Icons.refresh : Icons.send,
                                      color: LrsTheme.peach,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
    );
  }
}
