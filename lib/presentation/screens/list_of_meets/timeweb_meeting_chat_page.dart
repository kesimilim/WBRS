import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chat_avatar.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_chat_flow.dart' show TimewebChatWriteOutcome;
import 'package:wbrs/service/timeweb_meeting_chat_flow.dart';
import 'package:wbrs/service/timeweb_meeting_membership_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/timeweb_bottom_navigation.dart';

/// The caller opens a fresh member-authorized flow before adopting this route.
class TimewebMeetingChatPageView extends StatefulWidget {
  const TimewebMeetingChatPageView({
    super.key,
    required this.runtime,
    required this.meeting,
    required this.flow,
    required this.onParticipants,
    this.participants = const [],
    this.translationFactory,
    this.onMembershipChanged,
  });
  final TimewebAppRuntime runtime;
  final TimewebMeeting meeting;
  final TimewebMeetingChatFlow flow;
  final VoidCallback onParticipants;
  final VoidCallback? onMembershipChanged;
  final List<TimewebMeetingParticipant> participants;
  final ContentTranslationService Function(String? Function())? translationFactory;
  @override
  State<TimewebMeetingChatPageView> createState() => _TimewebMeetingChatPageViewState();
}

class _TimewebMeetingChatPageViewState extends State<TimewebMeetingChatPageView> {
  final _composer = TextEditingController();
  late final _runtime = widget.runtime;
  late final _flow = widget.flow;
  AppSessionLease? _lease;
  late final ContentTranslationService _translator;
  StreamSubscription<AppSessionState>? _subscription;
  TimewebMeetingMembershipFlow? _leaveFlow;
  bool _leaving = false;
  final _translations = <String, ContentTranslation>{};
  final _originals = <String>{};
  final _names = <String, String>{};
  String? _notice, _language;
  bool _closed = false, _reading = false, _writing = false, _translating = false, _descriptionOpen = false;
  int _generation = 0;

  bool get _actorCurrent =>
      mounted &&
      !_closed &&
      _lease?.isCurrent == true &&
      identical(widget.runtime, _runtime) &&
      identical(widget.flow, _flow);
  bool get _current {
    if (!_actorCurrent) return false;
    try {
      _flow.requireCurrent();
      widget.meeting.requireCurrent();
      return _flow.ownerUid == _lease!.identity.uid && _flow.meetingId == widget.meeting.meetingId;
    } catch (_) {
      return false;
    }
  }

  bool get _memberLocked => _leaveFlow == null || _leaving || _leaveFlow!.needsCheck;

  String? _translationOwner() => _current ? '${_lease!.identity.uid}/${_lease!.epoch}' : null;
  @override
  void initState() {
    super.initState();
    // This service must exist even if the route's actor changed before first build.
    _translator =
        widget.translationFactory?.call(_translationOwner) ??
        ContentTranslationService(
          endpoint: null,
          currentUserId: _translationOwner,
          idToken: () async => null,
          enableOnDevice: true,
          enableRemoteFallback: false,
          maxCacheEntries: 30,
        );
    try {
      final lease = _runtime.session.captureLease();
      _lease = lease;
      _flow.requireCurrent();
      widget.meeting.requireCurrent();
      if (_flow.ownerUid != lease.identity.uid || _flow.meetingId != widget.meeting.meetingId) {
        throw StateError('Current meeting conversation is unavailable.');
      }
      for (final person in widget.participants.take(30)) {
        person.requireCurrent();
        final name = person.fullName;
        if (name != null && name.trim().isNotEmpty) _names[person.uid] = name;
      }
      _composer.text = _flow.pendingText ?? '';
      _subscription = _flow.sessionStates.listen((_) {
        if (!_current) _deny();
      });
      unawaited(_restoreLeave());
    } catch (_) {
      _deny();
    }
  }

  @override
  void didUpdateWidget(covariant TimewebMeetingChatPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.runtime, oldWidget.runtime) ||
        !identical(widget.flow, oldWidget.flow) ||
        !identical(widget.meeting, oldWidget.meeting)) {
      _deny();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final language = Localizations.localeOf(context).languageCode;
    if (_language != language) {
      _language = language;
      _generation++;
      _translations.clear();
      _originals.clear();
      _translator.clear();
    }
  }

  Future<void> _restoreLeave() async {
    if (!_current) return;
    try {
      final leave = await _runtime.openMeetingLeave(_flow.meetingId);
      if (!_current) {
        leave.close();
        return;
      }
      leave.requireCurrent();
      setState(() => _leaveFlow = leave);
    } catch (_) {
      if (_current) setState(() => _notice = 'Не удалось проверить исходный выход. Обновите встречу.');
    }
  }

  Future<void> _leave() async {
    final leave = _leaveFlow;
    if (!_current || _leaving || _reading || _writing || _flow.sendNeedsCheck || leave == null || leave.rejected) {
      return;
    }
    final id = leave.meetingId;
    setState(() {
      _leaving = true;
      _notice = null;
    });
    try {
      final outcome = leave.needsCheck ? await leave.check() : await leave.submit();
      // ACK revokes held target DTOs; only the actor lease remains valid here.
      if (!_actorCurrent) return;
      leave.requireCurrent();
      if (outcome == TimewebMeetingMembershipOutcome.confirmed) {
        final receipt = leave.leaveReceipt;
        if (receipt == null || receipt.meetingId != id) throw StateError('Missing original leave receipt.');
        receipt.requireCurrent();
        widget.onMembershipChanged?.call();
        _deny();
      } else if (outcome == TimewebMeetingMembershipOutcome.rejected) {
        // A declared visibility/profile failure grants no cached member access.
        widget.onMembershipChanged?.call();
        _deny();
      } else {
        setState(() => _notice = 'Проверьте исходный выход из встречи.');
      }
    } catch (_) {
      if (_actorCurrent) setState(() => _notice = 'Не удалось подтвердить выход из встречи.');
    } finally {
      if (_actorCurrent) setState(() => _leaving = false);
    }
  }

  void _deny() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _flow.close();
    _leaveFlow?.close();
    _leaveFlow = null;
    _leaving = false;
    _composer.clear();
    _translations.clear();
    _originals.clear();
    _names.clear();
    _notice = null;
    _translator.clear();
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) Navigator.of(context).removeRoute(route);
    });
  }

  Future<void> _load({bool older = false}) async {
    if (!_current || _memberLocked || _reading || _writing) return;
    setState(() {
      _reading = true;
      _notice = null;
    });
    try {
      await (older ? _flow.loadOlder() : _flow.loadLatest());
      if (!_current) {
        _deny();
        return;
      }
      setState(() {
        _generation++;
        _translations.clear();
        _originals.clear();
        _translator.clear();
      });
    } catch (_) {
      _deny();
    } finally {
      if (_current) setState(() => _reading = false);
    }
  }

  Future<void> _send() async {
    if (!_current ||
        _memberLocked ||
        _writing ||
        _reading ||
        (!_flow.sendNeedsCheck && _composer.text.trim().isEmpty)) {
      return;
    }
    setState(() {
      _writing = true;
      _notice = null;
    });
    var protectedRead = false;
    try {
      final outcome = await (_flow.sendNeedsCheck ? _flow.checkSend() : _flow.send(_composer.text));
      if (!_current) {
        _deny();
        return;
      }
      if (outcome == TimewebChatWriteOutcome.unknown) {
        setState(() => _notice = 'Подтверждение ещё не получено. Проверьте исходную отправку.');
      } else {
        _flow.acceptDisplayedSendResult();
        if (outcome == TimewebChatWriteOutcome.confirmed) {
          _composer.clear();
          // Matching original receipt was durably acknowledged before this GET.
          protectedRead = true;
          await _flow.loadUpdates();
          if (!_current) {
            _deny();
            return;
          }
          setState(() {});
        } else {
          setState(() => _notice = 'Сообщение не отправлено. Исходный текст сохранён.');
        }
      }
    } catch (_) {
      if (!_current) {
        _deny();
        return;
      }
      if (protectedRead) {
        _deny();
        return;
      }
      setState(
        () => _notice = _flow.sendNeedsCheck
            ? 'Проверьте исходную отправку.'
            : 'Не удалось отправить сообщение. Исходный текст сохранён.',
      );
    } finally {
      if (_current) setState(() => _writing = false);
    }
  }

  Future<void> _translate(TimewebMeetingMessage message) async {
    if (!_current || _memberLocked || _translating || _reading || _writing) return;
    final id = message.messageId;
    if (_translations.containsKey(id)) {
      setState(() {
        if (!_originals.remove(id)) _originals.add(id);
      });
      return;
    }
    final generation = _generation, original = message.text, language = _language!;
    setState(() {
      _translating = true;
      _notice = null;
    });
    try {
      final translated = await _translator.translate(original, language);
      if (!_current || _memberLocked || generation != _generation || language != _language) return;
      message.requireCurrent();
      setState(() {
        if (_translations.length >= 30) {
          final oldest = _translations.keys.first;
          _translations.remove(oldest);
          _originals.remove(oldest);
        }
        _translations[id] = translated;
      });
    } catch (_) {
      if (_current && generation == _generation) setState(() => _notice = 'Перевод недоступен. Показан оригинал.');
    } finally {
      if (_current) setState(() => _translating = false);
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _flow.close();
    _leaveFlow?.close();
    _leaveFlow = null;
    _names.clear();
    _translations.clear();
    _originals.clear();
    unawaited(_subscription?.cancel());
    _translator.dispose();
    _composer.dispose();
    super.dispose();
  }

  Widget _left(Widget child) => Align(
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(widthFactor: 2 / 3, child: child),
  );
  Future<void> _participants() async {
    if (!_current || _memberLocked) return;
    final page = TimewebNavigationScope.wrap(
      context,
      TimewebMeetingParticipantsPage(
        runtime: _runtime,
        meeting: widget.meeting,
        flow: _flow,
      ),
    );
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));
  }

  Widget _avatar(String name) => Container(
    width: 32,
    height: 32,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: const Color(0x40614635),
      border: Border.all(color: LrsTheme.peach, width: 1.3),
    ),
    child: Text(name.trim().characters.first, style: const TextStyle(fontSize: 13)),
  );
  Widget _message(TimewebMeetingMessage message) {
    final mine = message.senderUid == _lease!.identity.uid, id = message.messageId;
    final name = _names[message.senderUid] ?? context.tr('Участник');
    final translated = _originals.contains(id) ? null : _translations[id];
    final stamp = DateTime.parse(message.createdAt).toLocal();
    final clock = '${stamp.hour.toString().padLeft(2, '0')}:${stamp.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: 2 / 3,
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(left: mine ? 0 : 38, right: mine ? 38 : 0),
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!mine) ...[_avatar(name), const SizedBox(width: 6)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: mine ? const Color(0xCC68452F) : const Color(0xC72D1F16),
                            border: Border.all(color: const Color(0x66E7B092), width: .8),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(translated?.text ?? message.text),
                        ),
                        LayoutBuilder(
                          builder: (context, constraints) => Row(
                            children: [
                              Expanded(
                                child: TextButton(
                                  key: ValueKey('native-meeting-translate-$id'),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                                    minimumSize: const Size(0, 32),
                                    alignment: Alignment.centerLeft,
                                  ),
                                  onPressed: _memberLocked || _reading || _writing || _translating
                                      ? null
                                      : () => _translate(message),
                                  child: Text(
                                    context.tr(translated == null ? 'Перевести' : 'Показать оригинал'),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (constraints.maxWidth >= 150 * MediaQuery.textScalerOf(context).scale(1))
                                Text(clock, style: Theme.of(context).textTheme.labelSmall),
                            ],
                          ),
                        ),
                        if (translated?.googlePowered == true)
                          Image.asset('assets/attribution/translated-by-google.png', height: 14),
                      ],
                    ),
                  ),
                  if (mine) ...[const SizedBox(width: 6), _avatar(name)],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metadata() => _left(
    ClrsPanel(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_today_outlined, size: 16),
              const SizedBox(width: 6),
              Expanded(child: Text(widget.meeting.scheduleLabel)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.location_on_outlined, size: 18),
              const SizedBox(width: 4),
              Expanded(child: Text(widget.meeting.geographyLabel)),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const ValueKey('native-meeting-chat-about'),
                  onPressed: () => setState(() => _descriptionOpen = !_descriptionOpen),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    alignment: Alignment.centerLeft,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(context.tr('О встрече'))),
                      Icon(_descriptionOpen ? Icons.expand_less : Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('native-meeting-leave'),
                tooltip: context.tr(_leaveFlow?.needsCheck == true ? 'Проверить выход' : 'Покинуть встречу'),
                onPressed:
                    _leaveFlow == null ||
                        _leaving ||
                        _reading ||
                        _writing ||
                        _flow.sendNeedsCheck ||
                        _leaveFlow!.rejected
                    ? null
                    : _leave,
                icon: Icon(_leaveFlow?.needsCheck == true ? Icons.refresh : Icons.exit_to_app),
              ),
            ],
          ),
          if (_descriptionOpen)
            Text(widget.meeting.description.isEmpty ? context.tr('Описание не указано') : widget.meeting.description),
        ],
      ),
    ),
  );
  Widget _input() => Container(
    width: double.infinity,
    decoration: const BoxDecoration(
      color: Color(0xAD302110),
      border: Border(top: BorderSide(color: Color(0x66E7B092), width: .8)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              key: const ValueKey('native-meeting-chat-attachment'),
              onPressed: null,
              tooltip: context.tr('Вложения недоступны'),
              icon: const Icon(Icons.attach_file),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('native-meeting-chat-composer'),
                controller: _composer,
                enabled: !_memberLocked && !_writing && !_reading && !_flow.sendNeedsCheck,
                maxLength: 4096,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: context.tr('Сообщение'),
                  counterText: '',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('native-meeting-chat-send'),
              tooltip: context.tr(_flow.sendNeedsCheck ? 'Проверить' : 'Отправить'),
              style: IconButton.styleFrom(
                backgroundColor: LrsTheme.peach,
                disabledBackgroundColor: const Color(0x55E7B092),
                foregroundColor: LrsTheme.surface,
                shape: const CircleBorder(),
              ),
              onPressed:
                  _memberLocked || _reading || _writing || (!_flow.sendNeedsCheck && _composer.text.trim().isEmpty)
                  ? null
                  : _send,
              icon: Icon(_flow.sendNeedsCheck ? Icons.refresh : Icons.arrow_upward),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => ClrsScaffold(
    backgroundAsset: 'assets/family_main.jpg',
    backgroundScale: 1.42,
    bottomNavigationBar: TimewebNavigationScope.maybeOf(context)?.showBar == true
        ? const TimewebBottomNavigationBar()
        : null,
    appBar: AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: 72 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
      title: const Align(alignment: Alignment.centerLeft, child: ClrsLogo(size: 34)),
      actions: [
        IconButton(
          key: const ValueKey('native-meeting-chat-participants'),
          tooltip: context.tr('Участники встречи'),
          onPressed: _current && !_memberLocked ? _participants : null,
          icon: const Icon(Icons.people_outline),
        ),
        IconButton(
          key: const ValueKey('native-meeting-chat-notifications'),
          onPressed: null,
          tooltip: context.tr('Уведомления недоступны'),
          icon: const Icon(Icons.notifications_none),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: !_current
        ? Center(child: Text(context.tr('Обсуждение недоступно')))
        : Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IconButton(
                          key: const ValueKey('native-meeting-chat-back'),
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 10, bottom: 10),
                            child: Text(
                              (widget.meeting.title?.trim().isNotEmpty ?? false) ? widget.meeting.title! : context.tr('Встреча'),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('native-meeting-chat-participants-link'),
                        style: TextButton.styleFrom(foregroundColor: LrsTheme.peachLight),
                        onPressed: _current && !_memberLocked ? _participants : null,
                        icon: const Icon(Icons.people_outline, size: 18),
                        label: Text(context.tr('Участники встречи')),
                      ),
                    ),
                    _metadata(),
                    const SizedBox(height: 28),
                    if (_flow.hasOlder)
                      TextButton(
                        key: const ValueKey('native-meeting-chat-older'),
                        onPressed: _memberLocked || _reading || _writing ? null : () => _load(older: true),
                        child: Text(context.tr('Ранее')),
                      ),
                    for (final message in _flow.messages.reversed) _message(message),
                    if (_flow.messages.isEmpty) _left(Text(context.tr('Сообщений пока нет'))),
                    TextButton(
                      key: const ValueKey('native-meeting-chat-refresh'),
                      onPressed: _memberLocked || _reading || _writing ? null : _load,
                      child: Text(context.tr('Обновить')),
                    ),
                    if (_notice != null) ClrsPanel(child: Text(context.tr(_notice!))),
                    if (_reading || _writing || _translating || _leaving)
                      const Center(child: CircularProgressIndicator()),
                  ],
                ),
              ),
              _input(),
            ],
          ),
  );
}

class _ParticipantDisplay {
  const _ParticipantDisplay(this.uid, this.name, this.primaryGroup, this.organizer);
  final String uid;
  final String? name, primaryGroup;
  final bool organizer;
}

/// The read-only roster keeps its own route and never closes the chat flow.
/// Snapshotting only display fields avoids retaining protected DTOs across builds.
class TimewebMeetingParticipantsPage extends StatefulWidget {
  const TimewebMeetingParticipantsPage({
    super.key,
    required this.runtime,
    required this.meeting,
    this.flow,
  });
  final TimewebAppRuntime runtime;
  final TimewebMeeting meeting;
  final TimewebMeetingChatFlow? flow;

  @override
  State<TimewebMeetingParticipantsPage> createState() => _TimewebMeetingParticipantsPageState();
}

class _TimewebMeetingParticipantsPageState extends State<TimewebMeetingParticipantsPage> {
  final _search = TextEditingController();
  final _people = <_ParticipantDisplay>[];
  AppSessionLease? _lease;
  StreamSubscription<AppSessionState>? _subscription;
  TimewebMeetingCursor? _cursor;
  bool _loading = false, _error = false;
  int _generation = 0;

  bool get _current {
    if (!mounted || _lease?.isCurrent != true) return false;
    try {
      widget.meeting.requireCurrent();
      final flow = widget.flow;
      if (flow == null) return true;
      flow.requireCurrent();
      return flow.ownerUid == _lease!.identity.uid && flow.meetingId == widget.meeting.meetingId;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    try {
      _lease = widget.runtime.session.captureLease();
      widget.meeting.requireCurrent();
    } catch (_) {
      return;
    }
    _subscription = widget.runtime.session.states.listen((_) {
      if (_current) return;
      _generation++;
      _people.clear();
      _cursor = null;
      if (!mounted) return;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route != null && route.isActive && !route.isFirst) Navigator.of(context).removeRoute(route);
      });
    });
    _search.addListener(() { if (mounted && _current) setState(() {}); });
    unawaited(_load());
  }

  Future<void> _load({bool next = false}) async {
    if (!_current || _loading || (next && _cursor == null)) return;
    final generation = ++_generation;
    final cursor = next ? _cursor : null;
    setState(() { _loading = true; _error = false; });
    try {
      final page = await widget.runtime.readMeetingParticipants(widget.meeting.meetingId, cursor: cursor);
      if (!_current || generation != _generation) return;
      page.requireCurrent();
      final people = <_ParticipantDisplay>[
        for (final person in page.items)
          _ParticipantDisplay(
            person.uid,
            person.fullName?.trim(),
            person.primaryGroup,
            person.uid == widget.meeting.organizerUid,
          ),
      ];
      final nextCursor = page.nextCursor;
      if (!_current || generation != _generation) return;
      setState(() {
        if (!next) _people.clear();
        _people.addAll(people);
        _cursor = nextCursor;
      });
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() {
          _error = true;
          _people.clear();
          _cursor = null;
        });
      }
    } finally {
      if (_current && generation == _generation) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _people.clear();
    _cursor = null;
    unawaited(_subscription?.cancel());
    _search.dispose();
    super.dispose();
  }

  Widget _left(Widget child) => Align(
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(widthFactor: 2 / 3, child: child),
  );

  @override
  Widget build(BuildContext context) {
    final fromChat = widget.flow != null;
    final query = _search.text.trim().toLowerCase();
    final people = _current
        ? _people.where((person) => query.isEmpty || (person.name ?? '').toLowerCase().contains(query)).toList()
        : <_ParticipantDisplay>[];
    return ClrsScaffold(
      backgroundAsset: 'assets/final_design/family_front.png',
      bottomNavigationBar: TimewebNavigationScope.maybeOf(context)?.showBar == true
          ? const TimewebBottomNavigationBar()
          : null,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 80,
        title: const Align(alignment: Alignment.centerLeft, child: ClrsLogo(size: 34)),
        actions: [
          IconButton(
            key: const ValueKey('native-meeting-participants-back'),
            tooltip: context.tr(fromChat ? 'Вернуться в чат' : 'О встрече'),
            onPressed: _current ? () => Navigator.of(context).maybePop() : null,
            icon: const Icon(Icons.arrow_back),
          ),
        ],
      ),
      body: !_current
          ? Center(child: Text(context.tr('Обсуждение недоступно')))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              children: [
                _left(ClrsPanel(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.tr('Участники встречи'), style: Theme.of(context).textTheme.headlineSmall),
                    if (widget.meeting.title?.trim().isNotEmpty == true)
                      Text(widget.meeting.title!, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ))),
                const SizedBox(height: 12),
                _left(ClrsPanel(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  child: TextField(
                    key: const ValueKey('native-meeting-participants-search'),
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: context.tr('Поиск по имени'),
                      prefixIcon: const Icon(Icons.search),
                      border: InputBorder.none,
                    ),
                  ),
                )),
                const SizedBox(height: 12),
                for (final person in people)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _left(ClrsPanel(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(children: [
                        TimewebChatAvatar(
                          runtime: widget.runtime,
                          uid: person.uid,
                          primaryGroup: person.primaryGroup,
                          readGroup: false,
                          size: 42,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (person.name?.isNotEmpty == true)
                              Text(person.name!, maxLines: 2, overflow: TextOverflow.ellipsis),
                            if (person.organizer)
                              Text(context.tr('Организатор'), style: Theme.of(context).textTheme.labelSmall),
                          ],
                        )),
                      ]),
                    )),
                  ),
                if (people.isEmpty && !_loading && !_error)
                  _left(ClrsPanel(child: Text(query.isEmpty
                      ? context.tr('Участников: {count}').replaceAll('{count}', '0')
                      : context.tr('По выбранным параметрам пока никого нет')))),
                if (_error)
                  _left(ClrsPanel(child: Column(children: [
                    Text(context.tr('Не удалось загрузить список.')),
                    TextButton(onPressed: _loading ? null : _load, child: Text(context.tr('Повторить'))),
                  ]))),
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (_cursor != null && !_loading)
                  _left(TextButton(
                    key: const ValueKey('native-meeting-participants-next'),
                    onPressed: () => _load(next: true),
                    child: Text(context.tr('Следующая страница')),
                  )),
                const SizedBox(height: 16),
                _left(ClrsPanel(
                  child: TextButton.icon(
                    key: ValueKey(fromChat
                        ? 'native-meeting-participants-return-chat'
                        : 'native-meeting-participants-return-detail'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text(context.tr(fromChat ? 'Вернуться в чат' : 'О встрече')),
                  ),
                )),
              ],
            ),
    );
  }
}
