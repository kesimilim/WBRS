import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_gift_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chat_avatar.dart';

/// Current inventory and server-priced purchases; no payment/Firebase callback.
class TimewebGiftsPage extends StatefulWidget {
  const TimewebGiftsPage({
    super.key,
    required this.runtime,
    this.tabIndex = 0,
    this.preferredChatId,
  });
  final TimewebAppRuntime runtime;
  final int tabIndex;
  final String? preferredChatId;
  @override
  State<TimewebGiftsPage> createState() => _TimewebGiftsPageState();
}

class _TimewebGiftsPageState extends State<TimewebGiftsPage> {
  late final AppSessionLease _lease;
  StreamSubscription<AppSessionState>? _states;
  TimewebGiftFlow? _flow;
  TimewebGiftInventory? _data;
  List<TimewebCurrentChat> _chats = [];
  TimewebCurrentReadCursor? _next;
  String? _sending, _notice;
  Route<void>? _recipientRoute;
  NavigatorState? _recipientNavigator;
  bool _busy = true,
      _error = false,
      _denied = false,
      _invalid = false,
      _owned = false;
  bool get _current => mounted && !_invalid && _lease.isCurrent;
  bool get _locked =>
      _busy ||
      _data == null ||
      _denied ||
      _error ||
      _flow == null ||
      _flow!.needsCheck;
  @override
  void initState() {
    super.initState();
    _owned = widget.tabIndex == 1;
    _lease = widget.runtime.session.captureLease();
    _states = widget.runtime.session.states.listen((_) {
      if (_current || _invalid || !mounted) {
        return;
      }
      _invalid = true;
      _flow?.close();
      _closeRecipients();
      setState(() {
        _data = null;
        _chats = [];
        _next = null;
        _sending = null;
        _notice = null;
        _busy = false;
      });
      final route = ModalRoute.of(context), nav = Navigator.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && route != null && route.isActive && !route.isFirst) {
          nav.removeRoute(route);
        }
      });
    });
    unawaited(_open());
  }

  @override
  void dispose() {
    _closeRecipients();
    _states?.cancel();
    _flow?.close();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final flow = await widget.runtime.openGifts();
      if (!_current) {
        flow.close();
        return;
      }
      _flow?.close();
      _flow = flow;
      await _load();
    } on TimewebGiftAccessDenied {
      _deny();
    } catch (_) {
      if (_current) {
        setState(() => _error = true);
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _load() async {
    final data = await widget.runtime.readGifts();
    if (!_current) {
      return;
    }
    data.requireCurrent();
    setState(() {
      _data = data;
      _denied = false;
      _error = false;
    });
  }

  void _deny() {
    if (_current) {
      setState(() {
        _data = null;
        _chats = [];
        _sending = null;
        _next = null;
        _denied = true;
      });
    }
  }

  Future<void> _refresh() async {
    if (!_current || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _load();
    } on TimewebGiftAccessDenied {
      _deny();
    } catch (_) {
      if (_current) {
        setState(() => _error = true);
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _action([TimewebGiftAction? action]) async {
    if (!_current || _busy || _flow == null) {
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final outcome =
          await (action == null ? _flow!.check() : _flow!.submit(action))
              .timeout(_flow!.observationTimeout);
      if (!_current) {
        return;
      }
      _flow!.requireCurrent();
      if (outcome == TimewebGiftOutcome.unknown) {
        setState(
          () => _notice =
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.',
        );
        if (_flow!.failure == TimewebMutationFailure.giftAccessDenied) {
          _deny();
        }
        return;
      }
      if (outcome == TimewebGiftOutcome.rejected) {
        setState(
          () => _notice =
              _flow!.failure == TimewebMutationFailure.insufficientSilver
              ? 'Недостаточно средств'
              : 'Не удалось сохранить изменения. Попробуйте ещё раз.',
        );
      } else {
        _flow!.receipt!.requireCurrent();
      }
      _sending = null;
      _chats = [];
      _next = null;
      await _load();
    } on TimewebGiftAccessDenied {
      _deny();
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = 'Не удалось сохранить изменения. Попробуйте ещё раз.',
        );
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _recipients(String id, {bool more = false}) async {
    if (!_current || _locked || more && _next == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final page = await widget.runtime.readChats(cursor: more ? _next : null);
      if (!_current) {
        return;
      }
      page.requireCurrent();
      setState(() {
        _sending = id;
        _chats =
            {
              for (final chat in [if (more) ..._chats, ...page.chats])
                chat.chatId: chat,
            }.values.toList()..sort((a, b) {
              final newest = (b.updatedAt ?? '').compareTo(a.updatedAt ?? '');
              return newest != 0 ? newest : a.chatId.compareTo(b.chatId);
            });
        if (_chats.length > 90) {
          _chats = _chats.sublist(_chats.length - 90);
        }
        _next = page.nextCursor;
      });
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = 'Не удалось загрузить данные. Проверьте подключение.',
        );
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
      }
    }
    if (!more && _current && _sending == id && !_error) {
      await _chooseRecipient();
    }
  }

  void _closeRecipients() {
    final route = _recipientRoute, navigator = _recipientNavigator;
    _recipientRoute = null;
    _recipientNavigator = null;
    if (route != null && route.isActive && navigator?.mounted == true) {
      navigator!.removeRoute(route);
    }
  }

  Future<void> _chooseRecipient() async {
    String search = '';
    String? selected;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        _recipientRoute = ModalRoute.of(dialogContext);
        _recipientNavigator = Navigator.of(dialogContext);
        return StatefulBuilder(
          builder: (context, refresh) {
            final data = _current ? _data : null;
            final pending = _current && (_flow?.needsCheck ?? false);
            final recipients = _current
                ? _chats
                      .where(
                        (chat) => (chat.name ?? '').toLowerCase().contains(
                          search.toLowerCase(),
                        ),
                      )
                      .toList()
                : <TimewebCurrentChat>[];
            final preferred = widget.preferredChatId;
            Future<void> send(String chatId) async {
              if (!_current || _locked || _sending == null || data == null) {
                return;
              }
              final action = TimewebGiftAction.send(
                _sending!,
                chatId,
                data.owned(_sending!),
              );
              final saving = _action(action);
              refresh(() {});
              await saving;
              if (!context.mounted) return;
              if (!_current || _sending == null) {
                Navigator.of(context).pop();
              } else {
                refresh(() {});
              }
            }

            final gift = data?.catalog
                .where((gift) => gift.id == _sending)
                .firstOrNull;
            return PopScope(
              canPop: !_busy,
              child: AnimatedPadding(
                padding:
                    MediaQuery.viewInsetsOf(context) +
                    const EdgeInsets.only(right: 12),
                duration: const Duration(milliseconds: 100),
                child: LayoutBuilder(
                  builder: (context, constraints) => Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      key: const ValueKey('timeweb-gift-recipient-panel'),
                      width: constraints.maxWidth * 2 / 3,
                      height: constraints.maxHeight,
                      child: Material(
                        color: const Color(0xE02F2017),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.horizontal(
                            right: Radius.circular(20),
                          ),
                          side: BorderSide(color: LrsTheme.actionBorder),
                        ),
                        child: SafeArea(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      context.tr('Кому подарить?'),
                                      style: const TextStyle(
                                        fontFamily: 'CormorantGaramond',
                                        fontSize: 27,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: context.tr('Закрыть'),
                                    onPressed: _busy
                                        ? null
                                        : () => Navigator.pop(context),
                                    icon: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                              if (gift != null)
                                Row(
                                  children: [
                                    Image.asset(
                                      gift.assetPath,
                                      width: 54,
                                      height: 54,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(context.tr(gift.name)),
                                    ),
                                  ],
                                ),
                              const SizedBox(height: 8),
                              Text(
                                context.tr('Выберите собеседника.'),
                                style: const TextStyle(color: LrsTheme.muted),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                key: const ValueKey(
                                  'timeweb-gift-recipient-search',
                                ),
                                enabled: !_busy && !pending,
                                onChanged: _busy || pending
                                    ? null
                                    : (value) => refresh(() {
                                        search = value;
                                        selected = null;
                                      }),
                                decoration: InputDecoration(
                                  hintText: context.tr('Поиск по имени'),
                                  prefixIcon: const Icon(Icons.search),
                                ),
                              ),
                              if (preferred != null)
                                TextButton(
                                  key: const ValueKey(
                                    'timeweb-gift-current-recipient',
                                  ),
                                  onPressed: !_locked
                                      ? () => send(preferred)
                                      : null,
                                  child: Text(
                                    context.tr('Подарить текущему собеседнику'),
                                  ),
                                ),
                              if (_busy) const LinearProgressIndicator(),
                              if (_notice != null) Text(context.tr(_notice!)),
                              if (pending)
                                TextButton(
                                  key: const ValueKey(
                                    'timeweb-gift-recipient-check',
                                  ),
                                  onPressed: _busy
                                      ? null
                                      : () async {
                                          final checking = _action();
                                          refresh(() {});
                                          await checking;
                                          if (!context.mounted) return;
                                          if (_sending == null || !_current) {
                                            Navigator.pop(context);
                                          } else {
                                            refresh(() {});
                                          }
                                        },
                                  child: Text(
                                    context.tr('Проверить результат'),
                                  ),
                                ),
                              for (final chat in recipients)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Material(
                                    color: selected == chat.chatId
                                        ? LrsTheme.actionGlass
                                        : Colors.transparent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      side: BorderSide(
                                        color: selected == chat.chatId
                                            ? LrsTheme.peach
                                            : LrsTheme.actionBorder,
                                      ),
                                    ),
                                    child: ListTile(
                                      key: ValueKey(
                                        'timeweb-gift-recipient-${chat.chatId}',
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                      leading: TimewebChatAvatar(
                                        runtime: widget.runtime,
                                        uid: chat.counterpartUid,
                                        size: 38,
                                      ),
                                      title: Text(
                                        chat.name ?? context.tr('Не указано'),
                                        style: const TextStyle(
                                          fontFamily: 'Lato',
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onTap: _locked
                                          ? null
                                          : () => refresh(
                                              () => selected = chat.chatId,
                                            ),
                                    ),
                                  ),
                                ),
                              if (_next != null)
                                TextButton(
                                  onPressed: _locked
                                      ? null
                                      : () async {
                                          final loading = _recipients(
                                            _sending!,
                                            more: true,
                                          );
                                          refresh(() {});
                                          await loading;
                                          if (context.mounted) refresh(() {});
                                        },
                                  child: Text(context.tr('Загрузить ещё')),
                                ),
                              const SizedBox(height: 10),
                              ElevatedButton.icon(
                                key: const ValueKey(
                                  'timeweb-gift-recipient-confirm',
                                ),
                                onPressed: _locked || selected == null
                                    ? null
                                    : () => send(selected!),
                                icon: const Icon(Icons.card_giftcard),
                                label: Text(
                                  context.tr('Подарить'),
                                  style: const TextStyle(fontFamily: 'Lato'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    _recipientRoute = null;
    _recipientNavigator = null;
    if (_current && !(_flow?.needsCheck ?? false)) {
      setState(() {
        _sending = null;
        _chats = [];
        _next = null;
      });
    }
  }

  static const _giftButtonStyle = ButtonStyle(
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
    ),
    padding: WidgetStatePropertyAll(EdgeInsets.all(7)),
    backgroundColor: WidgetStatePropertyAll(LrsTheme.peachDark),
  );

  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return ClrsScaffold(
        body: Center(child: Text(context.tr('Сеанс завершён'))),
      );
    }
    final pending = _flow?.needsCheck ?? false, data = _data;
    final items = data?.catalog
        .where(
          (v) => !_owned || data.owned(v.id) > 0 || data.received(v.id) > 0,
        )
        .toList();
    return ClrsScaffold(
      key: const ValueKey('timeweb-gifts'),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: Column(
            children: [
              if (_busy)
                const LinearProgressIndicator(
                  key: ValueKey('timeweb-gifts-busy'),
                ),
              Expanded(
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        const motto = Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClrsMotto(size: 16),
                            SizedBox(height: 3),
                            Icon(
                              Icons.favorite_border,
                              size: 18,
                              color: LrsTheme.peach,
                            ),
                          ],
                        );
                        if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
                          return const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _GiftStoreLogo(),
                              Align(
                                alignment: Alignment.centerRight,
                                child: SizedBox(width: 180, child: motto),
                              ),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Expanded(child: _GiftStoreLogo()),
                            SizedBox(
                              width: constraints.maxWidth * .48,
                              child: motto,
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 14),
                    Text(
                      context.tr('Магазин подарков'),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      context
                          .tr('Дарите внимание. Создавайте особенные моменты.')
                          .replaceFirst('. ', '.\n'),
                      style: const TextStyle(
                        color: LrsTheme.text,
                        fontSize: 15,
                        height: 1.25,
                      ),
                    ),
                    Text(
                      context.tr('Ближе, чем кажется.'),
                      style: const TextStyle(
                        color: LrsTheme.text,
                        fontSize: 15,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (data != null)
                      ClrsPanel(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: context.tr('Ваш баланс: ')),
                              TextSpan(
                                text: '${data.balanceAg} Ag',
                                style: const TextStyle(
                                  color: LrsTheme.peach,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_notice != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(context.tr(_notice!)),
                      ),
                    if (pending)
                      ClrsPanel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.tr(
                                'Предыдущая отправка ожидает подтверждения. Проверьте результат.',
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('timeweb-gift-check'),
                              onPressed: _busy ? null : () => _action(),
                              child: Text(context.tr('Проверить результат')),
                            ),
                          ],
                        ),
                      ),
                    if (_denied)
                      Text(
                        context.tr(
                          'Сервис пока недоступен. Попробуйте позднее.',
                        ),
                      ),
                    if (_error)
                      TextButton(
                        onPressed: _busy ? null : _refresh,
                        child: Text(context.tr('Повторить')),
                      ),
                    if (data != null)
                      Material(
                        color: const Color(0xB3211813),
                        child: Row(
                          children: [
                            for (final owned in [false, true])
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(
                                        color: _owned == owned
                                            ? LrsTheme.peach
                                            : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                  child: TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => setState(() => _owned = owned),
                                    child: Text(
                                      context.tr(
                                        owned
                                            ? 'Выбранные подарки'
                                            : 'Выбрать подарки',
                                      ),
                                      style: TextStyle(
                                        color: _owned == owned
                                            ? LrsTheme.text
                                            : LrsTheme.muted,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (items?.isEmpty == true && _owned)
                      Text(context.tr('У вас нет подарков')),
                    if (items != null)
                      LayoutBuilder(
                        builder: (context, constraints) {
                          // Dmitry's approved catalogue is always two columns;
                          // device width must not bring the old three back.
                          const columns = 2;
                          final width =
                              (constraints.maxWidth - (columns - 1) * 10) /
                              columns;
                          return Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final gift in items)
                                SizedBox(
                                  key: ValueKey('timeweb-gift-card-${gift.id}'),
                                  width: width,
                                  child: ClrsPanel(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      children: [
                                        Image.asset(
                                          gift.assetPath,
                                          height: 92,
                                          fit: BoxFit.contain,
                                        ),
                                        Text(
                                          context.tr(gift.name),
                                          textAlign: TextAlign.start,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            height: 1.1,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (!_owned && gift.priceAg != null)
                                          Text(
                                            '${gift.priceAg} Ag',
                                            style: const TextStyle(
                                              color: LrsTheme.peach,
                                            ),
                                          ),
                                        if (_owned &&
                                            (data!.owned(gift.id) > 0 ||
                                                data.received(gift.id) > 0))
                                          Text(
                                            '${context.tr('Количество')}: ${BigInt.from(data.owned(gift.id)) + BigInt.from(data.received(gift.id))}',
                                          ),
                                        if (!_owned)
                                          ElevatedButton(
                                            style: _giftButtonStyle,
                                            key: ValueKey(
                                              'timeweb-gift-buy-${gift.id}',
                                            ),
                                            onPressed:
                                                _locked ||
                                                    gift.priceAg == null ||
                                                    gift.priceAg == 0
                                                ? null
                                                : () => _action(
                                                    TimewebGiftAction.buy(
                                                      gift.id,
                                                      data!.walletRevision,
                                                    ),
                                                  ),
                                            child: Text(
                                              context.tr('Забрать'),
                                              maxLines: 1,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                        if (_owned &&
                                            data!.owned(gift.id) > 0 &&
                                            widget.runtime.chatsEnabled)
                                          ElevatedButton(
                                            style: _giftButtonStyle,
                                            key: ValueKey(
                                              'timeweb-gift-send-${gift.id}',
                                            ),
                                            onPressed: _locked
                                                ? null
                                                : () => _recipients(gift.id),
                                            child: Text(
                                              context.tr('Подарить'),
                                              maxLines: 1,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Static approved shop treatment copied without importing legacy ShopPage.
class _GiftStoreLogo extends StatelessWidget {
  const _GiftStoreLogo();
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CLRS',
              key: ValueKey('gift-store-logo'),
              style: TextStyle(
                fontFamily: 'Lato',
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                fontSize: 42,
                height: .95,
                color: Color(0xFFFFE4C8),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(top: 1, left: 2),
              child: Icon(Icons.favorite, size: 12, color: Color(0xFFFFA06C)),
            ),
          ],
        ),
      ),
      const SizedBox(height: 5),
      Text(
        ClrsBrand.fullName.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'Lato',
          fontSize: 7,
          color: Color(0xFFFFE4C8),
          letterSpacing: 1.05,
        ),
      ),
    ],
  );
}
