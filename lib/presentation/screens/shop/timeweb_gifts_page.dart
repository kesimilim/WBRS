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

/// Current inventory and server-priced purchases; no payment/Firebase callback.
class TimewebGiftsPage extends StatefulWidget {
  const TimewebGiftsPage({super.key, required this.runtime});
  final TimewebAppRuntime runtime;
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
    _lease = widget.runtime.session.captureLease();
    _states = widget.runtime.session.states.listen((_) {
      if (_current || _invalid || !mounted) {
        return;
      }
      _invalid = true;
      _flow?.close();
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
        _chats = [if (more) ..._chats, ...page.chats];
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
  }

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
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: context.tr('Обновить'),
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy)
            const LinearProgressIndicator(key: ValueKey('timeweb-gifts-busy')),
          Expanded(
            child: ListView(
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
                ),
                Text(context.tr('Ближе, чем кажется.')),
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
                    context.tr('Сервис пока недоступен. Попробуйте позднее.'),
                  ),
                if (_error)
                  TextButton(
                    onPressed: _busy ? null : _refresh,
                    child: Text(context.tr('Повторить')),
                  ),
                if (data != null)
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: Text(context.tr('Выбрать подарки')),
                        selected: !_owned,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _owned = false),
                      ),
                      ChoiceChip(
                        label: Text(context.tr('Выбранные подарки')),
                        selected: _owned,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _owned = true),
                      ),
                    ],
                  ),
                if (_sending != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.tr('Выберите получателя'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  for (final chat in _chats)
                    ListTile(
                      title: Text(chat.name ?? context.tr('Не указано')),
                      trailing: const Icon(Icons.card_giftcard),
                      onTap: _locked
                          ? null
                          : () => _action(
                              TimewebGiftAction.send(
                                _sending!,
                                chat.chatId,
                                data!.owned(_sending!),
                              ),
                            ),
                    ),
                  if (_next != null)
                    TextButton(
                      onPressed: _locked
                          ? null
                          : () => _recipients(_sending!, more: true),
                      child: Text(context.tr('Загрузить ещё')),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _sending = null;
                            _chats = [];
                            _next = null;
                          }),
                    child: Text(context.tr('Отмена')),
                  ),
                ],
                if (items?.isEmpty == true && _owned)
                  Text(context.tr('У вас нет подарков')),
                if (items != null)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns =
                          constraints.maxWidth < 330 ||
                              MediaQuery.textScalerOf(context).scale(1) > 1.3
                          ? 2
                          : 3;
                      final width =
                          (constraints.maxWidth - (columns - 1) * 10) / columns;
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final gift in items)
                            SizedBox(
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
                                      textAlign: TextAlign.center,
                                    ),
                                    if (gift.priceAg != null)
                                      Text(
                                        '${gift.priceAg} Ag',
                                        style: const TextStyle(
                                          color: LrsTheme.peach,
                                        ),
                                      ),
                                    if (data!.owned(gift.id) > 0 ||
                                        data.received(gift.id) > 0)
                                      Text(
                                        '${context.tr('Количество')}: ${BigInt.from(data.owned(gift.id)) + BigInt.from(data.received(gift.id))}',
                                      ),
                                    TextButton(
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
                                                data.walletRevision,
                                              ),
                                            ),
                                      child: Text(context.tr('Купить')),
                                    ),
                                    if (data.owned(gift.id) > 0 &&
                                        widget.runtime.chatsEnabled)
                                      TextButton(
                                        key: ValueKey(
                                          'timeweb-gift-send-${gift.id}',
                                        ),
                                        onPressed: _locked
                                            ? null
                                            : () => _recipients(gift.id),
                                        child: Text(context.tr('Подарить')),
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
