import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_social_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/presentation/widgets/timeweb_post_image.dart';

/// Native feed, author wall and comments use the same current actor runtime.
class TimewebFeedPage extends StatefulWidget {
  const TimewebFeedPage({
    super.key,
    required this.runtime,
    this.wallUid,
    this.post,
    this.canModerate = false,
    this.translationFactory,
  });
  final TimewebAppRuntime runtime;
  final String? wallUid;
  final TimewebSocialItem? post;
  final bool canModerate;
  final ContentTranslationService Function(String? Function())?
  translationFactory;
  @override
  State<TimewebFeedPage> createState() => _TimewebFeedPageState();
}

class _TimewebFeedPageState extends State<TimewebFeedPage> {
  final _draft = TextEditingController();
  late final ContentTranslationService _translator;
  final _translations = <String, ContentTranslation>{};
  final _originals = <String>{};
  bool _translating = false;
  String? _language;
  StreamSubscription<AppSessionState>? _states;
  late final int _epoch;
  late final String _owner;
  TimewebSocialFlow? _flow;
  List<TimewebSocialItem> _items = [];
  TimewebSocialCursor? _cursor;
  bool _loading = true, _working = false, _error = false, _denied = false;
  bool _publish = false,
      _moderate = false,
      _composing = false,
      _invalid = false;
  int _generation = 0, _translationGeneration = 0;
  String? _replyTo, _notice;
  bool get _comments => widget.post != null;
  bool get _current =>
      mounted &&
      !_invalid &&
      widget.runtime.session.state.authenticated &&
      widget.runtime.session.state.epoch == _epoch &&
      widget.runtime.session.state.identity?.uid == _owner;
  bool get _locked =>
      _loading || _working || _flow == null || _flow!.needsCheck || _denied;

  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _owner = widget.runtime.session.state.identity!.uid;
    String? translationOwner() => _current ? '$_owner/$_epoch' : null;
    _translator =
        widget.translationFactory?.call(translationOwner) ??
        ContentTranslationService(
          endpoint: null,
          currentUserId: translationOwner,
          idToken: () async => null,
          enableOnDevice: true,
          enableRemoteFallback: false,
          maxCacheEntries: 30,
        );
    _states = widget.runtime.session.states.listen((_) {
      if (!_current) {
        _invalid = true;
        _generation++;
        _flow?.close();
        _flow = null;
        _items = [];
        _cursor = null;
        _draft.clear();
        _replyTo = null;
        _notice = null;
        _translations.clear();
        _originals.clear();
        _translator.clear();
        if (mounted) {
          setState(() {});
          final route = ModalRoute.of(context),
              navigator = Navigator.of(context);
          if (route != null && !route.isFirst) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && route.isActive) navigator.removeRoute(route);
            });
          }
        }
      }
    });
    unawaited(_open());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final language = Localizations.localeOf(context).languageCode;
    if (_language != language) {
      if (_language != null) {
        _translationGeneration++;
      }
      _language = language;
      _translations.clear();
      _originals.clear();
      _translator.clear();
    }
  }

  Future<void> _translate(TimewebSocialItem item) async {
    if (!_current || _locked || _translating || item.text == null) return;
    final id = item.id;
    if (_translations.containsKey(id)) {
      setState(() {
        if (!_originals.remove(id)) _originals.add(id);
      });
      return;
    }
    final generation = _translationGeneration, language = _language!;
    setState(() => _translating = true);
    try {
      final value = await _translator.translate(item.text!, language);
      if (!_current ||
          generation != _translationGeneration ||
          language != _language) {
        return;
      }
      item.requireCurrent();
      setState(() {
        if (_translations.length >= 30) {
          final oldest = _translations.keys.first;
          _translations.remove(oldest);
          _originals.remove(oldest);
        }
        _translations[id] = value;
      });
    } catch (_) {
      if (_current && generation == _translationGeneration) {
        setState(() => _notice = 'Перевод временно недоступен. Попробуйте позже.');
      }
    } finally {
      if (_current) setState(() => _translating = false);
    }
  }

  Future<void> _open() async {
    if (!_current || _working) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = false;
      _denied = false;
    });
    try {
      _flow?.close();
      _flow = null;
      _translationGeneration++;
      _translations.clear();
      _originals.clear();
      _translator.clear();
      final flow = await widget.runtime.openSocial();
      if (!_current || generation != _generation) {
        flow.close();
        return;
      }
      _flow = flow;
      await _load(generation: generation);
    } on TimewebSocialAccessDenied {
      _deny();
    } catch (_) {
      if (_current && generation == _generation) setState(() => _error = true);
    } finally {
      if (_current && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _load({required int generation, bool older = false}) async {
    final page = _comments
        ? await widget.runtime.readSocialComments(
            widget.post!.id,
            cursor: older ? _cursor : null,
          )
        : await widget.runtime.readSocialFeed(
            wallUid: widget.wallUid,
            cursor: older ? _cursor : null,
          );
    if (!_current || generation != _generation) return;
    page.requireCurrent();
    setState(() {
      final next = older ? [..._items, ...page.items] : page.items.toList();
      // Rolling history remains bounded while the server's cursor can continue.
      _items = next.length > 90 ? next.sublist(next.length - 90) : next;
      _cursor = page.nextCursor;
      _publish = !_comments && page.canPublish;
      _moderate = _comments ? widget.canModerate : page.canModerate;
      _error = false;
    });
  }

  Future<void> _older() async {
    if (!_current || _loading || _working || _cursor == null) return;
    setState(() => _loading = true);
    try {
      await _load(generation: _generation, older: true);
    } on TimewebSocialAccessDenied {
      _deny();
    } catch (_) {
      if (_current) setState(() => _error = true);
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  void _deny() {
    if (!_current) return;
    setState(() {
      _items = [];
      _cursor = null;
      _denied = true;
      _translationGeneration++;
      _translations.clear();
      _originals.clear();
      _translator.clear();
      _publish = false;
      _moderate = false;
      _draft.clear();
      _replyTo = null;
    });
  }

  Future<void> _action([TimewebSocialAction? action]) async {
    final flow = _flow;
    if (!_current || _working || flow == null) return;
    setState(() {
      _working = true;
      _notice = null;
    });
    try {
      final result = await (action == null ? flow.check() : flow.submit(action))
          .timeout(flow.observationTimeout);
      if (!_current) return;
      flow.requireCurrent();
      if (result == TimewebSocialOutcome.confirmed) {
        flow.receipt!.requireCurrent();
        _draft.clear();
        _replyTo = null;
        _composing = false;
        await _load(generation: ++_generation);
      } else {
        setState(
          () => _notice =
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.',
        );
        if (flow.failure == TimewebMutationFailure.socialAccessDenied) _deny();
      }
    } on TimewebSocialAccessDenied {
      _deny();
    } catch (_) {
      if (_current) {
        setState(() {
          if (flow.needsCheck) {
            _notice =
                'Подтверждение ещё не получено. Проверьте результат без повторной отправки.';
          } else {
            _error = true;
            _notice = null;
          }
        });
      }
    } finally {
      if (_current) setState(() => _working = false);
    }
  }

  Future<void> _navigate(Widget page) async {
    if (!_current || _locked) return;
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => page));
    if (_current) {
      await _open();
    } // Restore any original written on a child page.
  }

  @override
  void dispose() {
    _invalid = true;
    _generation++;
    _flow?.close();
    _items = [];
    _cursor = null;
    unawaited(_states?.cancel());
    _draft.clear();
    _draft.dispose();
    _translations.clear();
    _originals.clear();
    _translator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return ClrsScaffold(
        body: Center(child: Text(context.tr('Сеанс завершён'))),
      );
    }
    final pending = _flow?.needsCheck ?? false;
    return ClrsScaffold(
      backgroundAsset: 'assets/final_design/feed_family.png',
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const ClrsLogo(size: 34),
        actions: [
          IconButton(
            tooltip: context.tr('Обновить'),
            onPressed: _loading || _working ? null : _open,
            icon: const Icon(Icons.refresh),
          ),
          if (_publish)
            IconButton(
              key: const ValueKey('timeweb-social-new-post'),
              tooltip: context.tr('Новая публикация'),
              onPressed: _locked
                  ? null
                  : () => setState(() => _composing = true),
              icon: const Icon(Icons.add_box_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_loading || _working)
            const LinearProgressIndicator(key: ValueKey('timeweb-social-busy')),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                const Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(width: 150, child: ClrsMotto()),
                ),
                Text(
                  context.tr(
                    _comments
                        ? 'Комментарии'
                        : widget.wallUid != null
                        ? 'Стена'
                        : 'Лента',
                  ),
                  style: const TextStyle(
                    fontFamily: 'CormorantGaramond',
                    fontSize: 42,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(context.tr(_notice!)),
                  ),
                if (pending)
                  _panel(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr(
                            'Предыдущая отправка ожидает подтверждения. Проверьте результат.',
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('timeweb-social-check'),
                          onPressed: _working ? null : () => _action(),
                          child: Text(context.tr('Проверить результат')),
                        ),
                      ],
                    ),
                  ),
                if (_denied)
                  _panel(
                    Text(
                      context.tr('Сервис пока недоступен. Попробуйте позднее.'),
                    ),
                  ),
                if (_error)
                  _panel(
                    Column(
                      children: [
                        Text(
                          context.tr(
                            'Лента временно недоступна. Проверьте подключение и попробуйте позже.',
                          ),
                        ),
                        TextButton(
                          onPressed: _loading || _working ? null : _open,
                          child: Text(context.tr('Повторить')),
                        ),
                      ],
                    ),
                  ),
                if (!_denied &&
                    !_error &&
                    !_loading &&
                    _items.isEmpty &&
                    _cursor == null)
                  _panel(
                    Text(
                      context.tr(
                        _comments
                            ? 'Пока нет комментариев. Начните обсуждение.'
                            : 'Здесь будут публикации о семье, отношениях, вере, психологии, домах, детях и совместимости.',
                      ),
                    ),
                  ),
                if (!_denied && _comments && widget.post != null)
                  _panel(Text(widget.post!.text ?? '')),
                for (final item in _items)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _card(item),
                  ),
                if (_cursor != null)
                  TextButton(
                    key: const ValueKey('timeweb-social-more'),
                    onPressed: _loading || _working ? null : _older,
                    child: Text(context.tr('Загрузить ещё')),
                  ),
                if (!_denied &&
                    !pending &&
                    (_comments || _composing && _publish))
                  _compose(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel(Widget child) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xCC302110),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x77E7B092), width: .8),
    ),
    child: child,
  );

  Widget _compose() => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_replyTo != null)
            Row(
              children: [
                Expanded(child: Text(context.tr('Ответить'))),
                IconButton(
                  onPressed: _locked
                      ? null
                      : () => setState(() => _replyTo = null),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          TextField(
            key: const ValueKey('timeweb-social-text'),
            controller: _draft,
            enabled: !_locked,
            minLines: 2,
            maxLines: 5,
            maxLength: 4000,
            decoration: InputDecoration(
              hintText: context.tr(_comments ? 'Комментарий' : 'Публикация'),
            ),
          ),
          FilledButton(
            key: const ValueKey('timeweb-social-send'),
            onPressed: _locked
                ? null
                : () {
                    if (_draft.text.trim().isEmpty) return;
                    try {
                      unawaited(
                        _action(
                          _comments
                              ? TimewebSocialAction.comment(
                                  widget.post!.id,
                                  _draft.text,
                                  parentId: _replyTo,
                                )
                              : TimewebSocialAction.publish(_draft.text),
                        ),
                      );
                    } on ArgumentError {
                      setState(
                        () => _notice =
                            'Не удалось сохранить изменения. Попробуйте ещё раз.',
                      );
                    }
                  },
            child: Text(
              context.tr(_comments ? 'Отправить комментарий' : 'Опубликовать'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _card(TimewebSocialItem item) {
    item.requireCurrent();
    final translated = _originals.contains(item.id)
        ? null
        : _translations[item.id];
    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SocialAuthor(
            runtime: widget.runtime,
            uid: item.authorUid,
            onTap: _locked
                ? null
                : () => _navigate(
                    TimewebFeedPage(
                      runtime: widget.runtime,
                      wallUid: item.authorUid,
                    ),
                  ),
          ),
          if (item.text != null && item.text!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(translated?.text ?? item.text!),
            ),
          if (item.text?.isNotEmpty == true)
            TextButton(
              onPressed: _locked || _translating
                  ? null
                  : () => _translate(item),
              child: Text(
                context.tr(
                  translated == null ? 'Перевести' : 'Показать оригинал',
                ),
              ),
            ),
          if (translated?.googlePowered == true)
            Image.asset(
              'assets/attribution/translated-by-google.png',
              height: 14,
            ),
          if (item.mediaId != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: TimewebPostImage(
                key:ValueKey('$_generation/${item.id}/${item.mediaId}'),
                runtime:widget.runtime,postId:item.id,mediaId:item.mediaId!),
            ),
          if (item.createdAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${item.createdAt!.substring(0, 16).replaceFirst('T', ' ')} UTC',
                style: const TextStyle(color: LrsTheme.muted, fontSize: 11),
              ),
            ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!_comments)
                TextButton.icon(
                  key: ValueKey('timeweb-social-like-${item.id}'),
                  onPressed: _locked
                      ? null
                      : () => _action(
                          TimewebSocialAction.react(item.id, !item.liked!),
                        ),
                  icon: Icon(
                    item.liked! ? Icons.favorite : Icons.favorite_border,
                  ),
                  label: Text('${item.likeCount}'),
                ),
              if (!_comments)
                TextButton.icon(
                  key: ValueKey('timeweb-social-comments-${item.id}'),
                  onPressed: _locked
                      ? null
                      : () => _navigate(
                          TimewebFeedPage(
                            runtime: widget.runtime,
                            post: item,
                            canModerate: _moderate,
                          ),
                        ),
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: Text('${item.commentCount}'),
                ),
              if (_comments)
                TextButton(
                  onPressed: _locked
                      ? null
                      : () => setState(() {
                          _replyTo = item.id;
                          _composing = true;
                        }),
                  child: Text(context.tr('Ответить')),
                ),
              if (_comments)
                TextButton.icon(
                  onPressed: _locked
                      ? null
                      : () => _action(
                          TimewebSocialAction.react(
                            widget.post!.id,
                            !item.liked!,
                            commentId: item.id,
                          ),
                        ),
                  icon: Icon(
                    item.liked! ? Icons.favorite : Icons.favorite_border,
                  ),
                  label: Text(context.tr('Реакции')),
                ),
              IconButton(
                tooltip: context.tr('Пожаловаться'),
                onPressed: _locked
                    ? null
                    : () => _action(
                        TimewebSocialAction.report(
                          _comments ? widget.post!.id : item.id,
                          commentId: _comments ? item.id : null,
                        ),
                      ),
                icon: const Icon(Icons.flag_outlined),
              ),
              if (_comments && _moderate)
                IconButton(
                  tooltip: context.tr('Удалить'),
                  onPressed: _locked
                      ? null
                      : () => _action(
                          TimewebSocialAction.hideComment(
                            widget.post!.id,
                            item.id,
                          ),
                        ),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SocialAuthor extends StatefulWidget {
  const _SocialAuthor({required this.runtime, required this.uid, this.onTap});
  final TimewebAppRuntime runtime;
  final String uid;
  final VoidCallback? onTap;
  @override
  State<_SocialAuthor> createState() => _SocialAuthorState();
}

class _SocialAuthorState extends State<_SocialAuthor> {
  late final Future<Object> _author;
  @override
  void initState() {
    super.initState();
    _author = widget.uid == widget.runtime.session.state.identity?.uid
        ? widget.runtime.readCurrentOwnProfile()
        : widget.runtime.readPerson(widget.uid);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Object>(
    future: _author,
    builder: (_, snapshot) {
      String? name, group;
      try {
        final author = snapshot.data;
        if (author is TimewebPublicPerson) {
          author.requireCurrent();
          name = author.fullName;
          group = author.primaryGroup;
        }
        if (author is TimewebCurrentOwnProfile) {
          author.requireCurrent();
          name = author.profile?.fullName;
          group = author.profile?.primaryGroup;
        }
      } catch (_) {}
      return InkWell(
        onTap: widget.onTap,
        child: Row(
          children: [
            GroupAvatar(size: 34, url: '', group: group ?? ''),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name?.trim().isNotEmpty == true
                    ? name!
                    : context.tr('Не указано'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    },
  );
}
