import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_users/timeweb_people_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meeting_chat_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meeting_archive_page.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_create_flow.dart';
import 'package:wbrs/service/timeweb_meeting_join_flow.dart';
import 'package:wbrs/service/timeweb_meeting_membership_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/meeting_form.dart';
import 'package:wbrs/shared/timeweb_bottom_navigation.dart';
import 'package:wbrs/shared/translatable_text.dart';

const timewebMeetingsRoute = '/timeweb/meetings';

AppBar _bar(
  BuildContext context,
  String title, {
  Widget? scopeControl,
  Widget? action,
  bool mainList = false,
}) => AppBar(
  automaticallyImplyLeading: !mainList,
  title: Row(
    children: [
      Expanded(child: ClrsLogo(size: mainList ? 44 : 34)),
      SizedBox(
        width: 112,
        height: 48,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 112,
            child: DefaultTextStyle.merge(
              maxLines: 3,
              softWrap: true,
              overflow: TextOverflow.visible,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ClrsMotto(size: 18),
                  const Icon(
                    Icons.favorite_border,
                    size: 12,
                    color: LrsTheme.peach,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  ),
  toolbarHeight:
      (mainList ? 72 : 78) *
      MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
  bottom: PreferredSize(
    preferredSize: Size.fromHeight(
      48 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Row(
          children: [
            if (scopeControl != null) scopeControl,
            Expanded(
              child: Text(
                context.tr(title),
                maxLines: scopeControl == null ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: mainList
                    ? Theme.of(context).textTheme.headlineSmall
                    : Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (action != null) action,
          ],
        ),
      ),
    ),
  ),
);

Widget _left(Widget child) => Align(
  alignment: Alignment.centerLeft,
  child: FractionallySizedBox(widthFactor: 2 / 3, child: child),
);

String _wallClock(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}.${two(date.month)}.${date.year.toString().padLeft(4, '0')} ${two(date.hour)}:${two(date.minute)}';
}

Widget _choice(
  BuildContext context,
  String label,
  String? value,
  Iterable<(String, String)> values,
  ValueChanged<String?>? changed, {
  bool compact = false,
}) {
  final choices = values.toList(growable: false);
  return DropdownButtonFormField<String>(
    key: ValueKey('$label/$value'),
    value: value,
    isExpanded: true,
    style: compact
        ? const TextStyle(
            fontFamily: 'Lato',
            fontSize: 12,
            height: 1,
            color: LrsTheme.text,
          )
        : null,
    itemHeight: compact ? null : kMinInteractiveDimension,
    iconSize: compact ? 16 : 24,
    decoration: compact
        ? InputDecoration(
            hintText: context.tr(label),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 3,
            ),
          )
        : InputDecoration(labelText: context.tr(label)),
    selectedItemBuilder: compact
        ? (_) => [
            for (final item in choices)
              Tooltip(
                message: '${context.tr(label)}: ${context.tr(item.$2)}',
                child: Text(
                  '${context.tr(label)}: ${context.tr(item.$2)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Lato',
                    fontSize: 10,
                    height: 1,
                    color: LrsTheme.text,
                  ),
                ),
              ),
          ]
        : null,
    items: [
      for (final item in choices)
        DropdownMenuItem(
          value: item.$1,
          child: Text(
            context.tr(item.$2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: changed,
  );
}

Widget _locations(
  BuildContext context,
  List<GeoCountry> countries,
  String? country,
  String? region,
  void Function(String?, String?) changed, {
  bool filter = false,
  bool enabled = true,
  bool compact = false,
}) => Row(
  children: [
    Expanded(
      child: _choice(
        context,
        'Страна',
        country,
        [
          if (filter) ('', 'Все страны'),
          for (final item in countries) (item.code, item.name),
        ],
        enabled ? (value) => changed(value == '' ? null : value, null) : null,
        compact: compact,
      ),
    ),
    const SizedBox(width: 8),
    Expanded(
      child: _choice(
        context,
        'Регион',
        region,
        [
          if (filter) ('', 'Все регионы'),
          for (final item
              in GeoCatalog.byCode(countries, country)?.regions ?? <String>[])
            (item, item),
        ],
        enabled && country != null
            ? (value) => changed(country, value == '' ? null : value)
            : null,
        compact: compact,
      ),
    ),
  ],
);

// These are decorative topic illustrations, never a participant-uploaded image.
// The native meeting read contract does not expose meeting media yet.
String? _meetingIllustration(TimewebMeeting meeting) {
  final topic = '${meeting.title ?? ''} ${meeting.description}'.toLowerCase();
  if (RegExp(r'бар|пив|крылыш|\bbar\b|\bpub\b|beer|wings').hasMatch(topic)) {
    return 'assets/final_design/meeting_bar.jpg';
  }
  if (RegExp(r'кофе|кофейн|кафе|coffee|cafe').hasMatch(topic)) {
    return 'assets/final_design/meeting_coffee.jpg';
  }
  if (RegExp(r'пикник|picnic').hasMatch(topic)) {
    return 'assets/final_design/meeting_picnic.jpg';
  }
  if (RegExp(r'парк|прогулк|\bpark\b|\bwalk').hasMatch(topic)) {
    return 'assets/final_design/meeting_park.jpg';
  }
  return null;
}

String _participantInitial(String? name) {
  final value = name?.trim() ?? '';
  return value.isEmpty ? '?' : value.characters.first.toUpperCase();
}

Widget _meetingCard(
  BuildContext context,
  TimewebMeeting meeting, {
  required ContentTranslationService translator,
  VoidCallback? tap,
  bool full = false,
}) {
  final title = (meeting.title?.trim().isNotEmpty ?? false)
      ? meeting.title!
      : context.tr('Встреча');
  final illustration = full ? null : _meetingIllustration(meeting);
  final facts = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        maxLines: full ? null : 2,
        overflow: full ? null : TextOverflow.ellipsis,
        style: full
            ? Theme.of(context).textTheme.titleLarge
            : const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      if (!full && meeting.description.isNotEmpty) ...[
        const SizedBox(height: 4),
        ContentTranslationScope(
          service: translator,
          child: TranslatableText(
            meeting.description,
            autoTranslate: false,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: LrsTheme.muted),
          ),
        ),
      ],
      const SizedBox(height: 8),
      Row(
        children: [
          const Icon(Icons.calendar_today_outlined, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              meeting.scheduleLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      const SizedBox(height: 5),
      Row(
        children: [
          const Icon(Icons.location_on_outlined, size: 17),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              meeting.geographyLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      if (full && meeting.description.isNotEmpty) ...[
        const Divider(color: Color(0x66E7B092)),
        Text(
          context.tr('О встрече'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 5),
        ContentTranslationScope(
          service: translator,
          child: TranslatableText(
            meeting.description,
            autoTranslate: false,
          ),
        ),
      ],
    ],
  );
  final panel = ClrsPanel(
    padding: const EdgeInsets.all(10),
    child: InkWell(
      key: ValueKey('native-meeting-${meeting.meetingId}'),
      onTap: tap,
      child: full
          ? facts
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: illustration == null
                      ? Container(
                          width: 88,
                          height: 126,
                          color: const Color(0xAD493526),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.event_outlined,
                            size: 36,
                            color: LrsTheme.peachLight,
                          ),
                        )
                      : Stack(
                          children: [
                            Image.asset(
                              illustration,
                              width: 88,
                              height: 126,
                              fit: BoxFit.cover,
                              excludeFromSemantics: true,
                            ),
                            const Positioned(
                              right: 5,
                              bottom: 5,
                              child: Icon(
                                Icons.auto_awesome_outlined,
                                size: 15,
                                color: LrsTheme.peachLight,
                              ),
                            ),
                          ],
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(child: facts),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
    ),
  );
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: full ? _left(panel) : panel,
  );
}

/// One current page, then an explicit next page. No imported meeting/media fallback.
class TimewebMeetingsPageView extends StatefulWidget {
  const TimewebMeetingsPageView({
    super.key,
    required this.runtime,
    this.meetingId,
    this.onMembershipChanged,
  });
  final TimewebAppRuntime runtime;
  final String? meetingId;
  final VoidCallback? onMembershipChanged;
  @override
  State<TimewebMeetingsPageView> createState() =>
      _TimewebMeetingsPageViewState();
}

class _TimewebMeetingsPageViewState extends State<TimewebMeetingsPageView> {
  final _fieldsNavigator = GlobalKey<NavigatorState>();
  late final TimewebAppRuntime _runtime = widget.runtime;
  late final int _epoch = _runtime.session.state.epoch;
  late final String? _owner = _runtime.session.state.identity?.uid;
  late final ContentTranslationService _translator;
  StreamSubscription<AppSessionState>? _subscription;
  List<GeoCountry>? _countries;
  String? _country, _region;
  String _scope = 'group';
  TimewebMeetingFilters? _filters;
  TimewebMeetingPage<TimewebMeeting>? _page;
  TimewebMeetingPage<TimewebMeetingParticipant>? _participants;
  TimewebMeeting? _meeting;
  TimewebMeetingJoinFlow? _joinFlow;
  TimewebMeetingMembershipFlow? _leaveFlow, _kickFlow;
  bool _changingMembership = false;
  String? _membershipNotice;
  bool _joining = false, _joinUnavailable = false;
  String? _joinNotice;
  String? _chatNotice, _archiveNotice;
  bool _loading = false, _error = false, _invalidated = false;
  int _generation = 0;

  bool get _actorCurrent {
    if (!mounted ||
        _invalidated ||
        !identical(widget.runtime, _runtime) ||
        !_runtime.session.state.authenticated ||
        _runtime.session.state.epoch != _epoch ||
        _runtime.session.state.identity?.uid != _owner) {
      return false;
    }
    return true;
  }

  bool get _current {
    if (!_actorCurrent) return false;
    try {
      _page?.requireCurrent();
      _meeting?.requireCurrent();
      _participants?.requireCurrent();
      _joinFlow?.requireCurrent();
      _leaveFlow?.requireCurrent();
      _kickFlow?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get _pendingLeave => _leaveFlow?.needsCheck == true;
  bool get _pendingKick => _kickFlow?.needsCheck == true;
  bool get _memberActionsLocked =>
      widget.meetingId != null &&
      (_leaveFlow == null ||
          _pendingLeave ||
          _pendingKick ||
          _changingMembership);
  bool get _organizer => _meeting != null && _meeting!.organizerUid == _owner;

  @override
  void initState() {
    super.initState();
    _translator = ContentTranslationService(
      endpoint: null,
      currentUserId: () => _actorCurrent ? '$_owner/$_epoch' : null,
      idToken: () async => null,
      enableOnDevice: true,
      enableRemoteFallback: false,
      maxCacheEntries: 30,
    );
    _subscription = _runtime.session.states.listen((_) {
      if (!_actorCurrent) _invalidate();
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant TimewebMeetingsPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.runtime, oldWidget.runtime) ||
        widget.meetingId != oldWidget.meetingId)
      _invalidate();
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _translator.clear();
    _generation++;
    _joinFlow?.close();
    _joinFlow = null;
    _leaveFlow?.close();
    _kickFlow?.close();
    _leaveFlow = _kickFlow = null;
    _changingMembership = false;
    _membershipNotice = null;
    _joining = false;
    _joinUnavailable = false;
    _joinNotice = null;
    _chatNotice = _archiveNotice = null;
    _page = null;
    _participants = null;
    _meeting = null;
    _filters = null;
    _countries = null;
    _country = _region = null;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst)
        Navigator.of(context).removeRoute(route);
    });
  }

  Future<void> _load({bool next = false, bool roster = false}) async {
    if (!_actorCurrent || _loading) return;
    if (!_current) {
      if (next || roster) return;
      _purgeMembershipReads();
    }
    final cursor = next
        ? (roster ? _participants?.nextCursor : _page?.nextCursor)
        : null;
    if (next && cursor == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = false;
      if (!next) {
        if (roster) {
          _participants = null;
        } else {
          _page = null;
          _meeting = null;
          _participants = null;
        }
      }
    });
    try {
      if (roster) {
        final page = await _runtime.readMeetingParticipants(
          widget.meetingId!,
          cursor: cursor,
        );
        if (!_current || generation != _generation) return;
        page.requireCurrent();
        setState(() => _participants = page);
      } else if (widget.meetingId != null) {
        // Restore the original leave before any protected member entry.
        if (_leaveFlow == null) {
          final flow = await _runtime.openMeetingLeave(widget.meetingId!);
          if (!_actorCurrent || generation != _generation) {
            flow.close();
            return;
          }
          flow.requireCurrent();
          setState(() => _leaveFlow = flow);
        }
        final meeting = await _runtime.readMeeting(widget.meetingId!);
        if (!_current || generation != _generation) return;
        meeting.requireCurrent();
        setState(() => _meeting = meeting);
        if (_organizer && _kickFlow == null) {
          final flow = await _runtime.openMeetingKick(widget.meetingId!);
          if (!_current || generation != _generation) {
            flow.close();
            return;
          }
          flow.requireCurrent();
          setState(() => _kickFlow = flow);
        }
        if (!_pendingLeave &&
            !_pendingKick &&
            _joinFlow == null &&
            !_joinUnavailable &&
            _runtime.meetingsEnabled) {
          final flow = await _runtime.openMeetingJoin(meeting.meetingId);
          if (!_current || generation != _generation) {
            flow.close();
            return;
          }
          flow.requireCurrent();
          setState(() => _joinFlow = flow);
        }
      } else {
        final countries = _countries ?? await GeoCatalog.load();
        if (!_current || generation != _generation) return;
        final filters = next
            ? _filters!
            : await TimewebMeetingFilters.fromCatalog(
                scope: _scope,
                countryCode: _country,
                region: _region,
              );
        if (!_current || generation != _generation) return;
        final page = await _runtime.readMeetings(filters, cursor: cursor);
        if (!_current || generation != _generation) return;
        page.requireCurrent();
        setState(() {
          _countries = countries;
          _filters = filters;
          _page = page;
        });
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() {
          _error = true;
          if (_meeting != null && _joinFlow == null) _joinUnavailable = true;
        });
      }
    } finally {
      if (mounted && generation == _generation)
        setState(() => _loading = false);
    }
  }

  Future<void> _open(String id) async {
    if (!_current || _loading) return;
    final page = TimewebNavigationScope.wrap(
      context,
      TimewebMeetingsPageView(
        runtime: _runtime,
        meetingId: id,
        onMembershipChanged: _purgeMembershipReads,
      ),
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: timewebMeetingsRoute),
        builder: (_) => page,
      ),
    );
  }

  Future<void> _join() async {
    final flow = _joinFlow;
    if (!_current ||
        _memberActionsLocked ||
        _loading ||
        _joining ||
        flow == null ||
        flow.rejected ||
        flow.receipt != null)
      return;
    setState(() {
      _joining = true;
      _joinNotice = null;
    });
    try {
      final outcome = flow.needsCheck
          ? await flow.check()
          : await flow.submit();
      if (!_current) return;
      flow.requireCurrent();
      if (outcome == TimewebMeetingJoinOutcome.confirmed) {
        final receipt = flow.receipt;
        if (receipt == null || receipt.meetingId != widget.meetingId)
          throw StateError('Missing join confirmation');
        receipt.requireCurrent();
        setState(
          () => _joinNotice = receipt.alreadyMember
              ? 'Вы уже участник этой встречи'
              : 'Вы присоединились к встрече',
        );
        // The flow returns confirmed only after durable original-intent ACK.
        await _load(roster: true);
      } else {
        setState(
          () => _joinNotice = outcome == TimewebMeetingJoinOutcome.rejected
              ? 'Присоединение отклонено.'
              : 'Подтверждение ещё не получено. Проверьте исходную операцию.',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _joinNotice = flow.needsCheck
              ? 'Не удалось подтвердить присоединение. Проверьте исходную операцию.'
              : 'Присоединение пока недоступно.',
        );
      }
    } finally {
      if (_current) setState(() => _joining = false);
    }
  }

  Future<void> _openConversation() async {
    final meeting = _meeting;
    if (!_current ||
        _memberActionsLocked ||
        _loading ||
        _joining ||
        meeting == null)
      return;
    setState(() {
      _loading = true;
      _chatNotice = null;
    });
    var participantsRequested = false, membershipChanged = false;
    try {
      final flow = await _runtime.openMeetingConversation(meeting.meetingId);
      if (!mounted || !_current || !identical(_meeting, meeting)) {
        flow.close();
        return;
      }
      try {
        final roster =
            _participants ??
            await _runtime.readMeetingParticipants(meeting.meetingId);
        if (!mounted || !_current || !identical(_meeting, meeting)) {
          flow.close();
          return;
        }
        roster.requireCurrent();
        flow.requireCurrent();
        final chat = TimewebNavigationScope.wrap(
          context,
          TimewebMeetingChatPageView(
            runtime: _runtime,
            meeting: meeting,
            flow: flow,
            participants: roster.items,
            onParticipants: () => participantsRequested = true,
            onMembershipChanged: () {
              if (_actorCurrent) {
                membershipChanged = true;
                _purgeMembershipReads();
              }
            },
          ),
        );
        await Navigator.of(
          context,
        ).push<void>(MaterialPageRoute(builder: (_) => chat));
      } finally {
        flow.close();
      }
    } catch (_) {
      if (_current) setState(() => _chatNotice = 'Обсуждение пока недоступно.');
    } finally {
      if (_actorCurrent) setState(() => _loading = false);
    }
    if (_actorCurrent) {
      // Back after UNKNOWN must reopen the disk original, not the idle pre-chat flow.
      _leaveFlow?.close();
      _leaveFlow = null;
      await _load();
      if (!membershipChanged &&
          _current &&
          !_memberActionsLocked &&
          participantsRequested)
        await _load(roster: true);
    }
  }

  Future<void> _openParticipants() async {
    final meeting = _meeting;
    if (!_current ||
        _memberActionsLocked ||
        _loading ||
        _joining ||
        meeting == null)
      return;
    meeting.requireCurrent();
    final page = TimewebNavigationScope.wrap(
      context,
      TimewebMeetingParticipantsPage(runtime: _runtime, meeting: meeting, allowManagement: true),
    );
    final manage = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => page));
    if (manage == true && _current && _organizer && !_memberActionsLocked) {
      await _load(roster: true);
    }
  }

  Future<void> _openArchive() async {
    final meeting = _meeting;
    if (!_current ||
        _memberActionsLocked ||
        _loading ||
        _joining ||
        meeting == null)
      return;
    setState(() {
      _loading = true;
      _archiveNotice = null;
    });
    try {
      final flow = await _runtime.openMeetingArchive(meeting.meetingId);
      if (!mounted || !_current || !identical(_meeting, meeting)) {
        flow.close();
        return;
      }
      try {
        flow.requireCurrent();
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => TimewebMeetingArchivePageView(
              runtime: _runtime,
              flow: flow,
              onUnavailable: () {
                if (!_actorCurrent) return;
                _purgeMembershipReads();
                setState(
                  () => _archiveNotice =
                      'Сохранённая история пока недоступна. Откройте её заново.',
                );
              },
            ),
          ),
        );
      } finally {
        flow.close();
      }
    } catch (_) {
      if (_actorCurrent)
        setState(() => _archiveNotice = 'Сохранённая история пока недоступна.');
    } finally {
      if (_actorCurrent) setState(() => _loading = false);
    }
    if (_actorCurrent) await _load();
  }

  void _purgeMembershipReads() {
    if (!_actorCurrent) return;
    widget.onMembershipChanged?.call();
    setState(() {
      _generation++;
      _page = null;
      _meeting = null;
      _participants = null;
      _joinFlow?.close();
      _joinFlow = null;
      _joinNotice = null;
      _joinUnavailable = false;
      _leaveFlow?.close();
      _kickFlow?.close();
      _leaveFlow = _kickFlow = null;
    });
  }

  Future<void> _checkLeave() async {
    final flow = _leaveFlow;
    if (!_actorCurrent ||
        _loading ||
        _changingMembership ||
        flow == null ||
        !flow.needsCheck)
      return;
    setState(() {
      _changingMembership = true;
      _membershipNotice = null;
    });
    try {
      final outcome = await flow.check();
      if (!_actorCurrent) return;
      flow.requireCurrent();
      if (outcome == TimewebMeetingMembershipOutcome.confirmed) {
        final receipt = flow.leaveReceipt;
        if (receipt == null || receipt.meetingId != widget.meetingId)
          throw StateError('Missing leave receipt');
        receipt.requireCurrent();
        _purgeMembershipReads();
        setState(() => _membershipNotice = 'Вы вышли из встречи.');
        await _load();
      } else {
        setState(
          () => _membershipNotice =
              outcome == TimewebMeetingMembershipOutcome.unknown
              ? 'Проверьте исходный выход из встречи.'
              : 'Выход из встречи отклонён.',
        );
        if (outcome == TimewebMeetingMembershipOutcome.rejected) {
          _purgeMembershipReads();
          await _load();
        }
      }
    } catch (_) {
      if (_actorCurrent)
        setState(
          () => _membershipNotice = 'Не удалось подтвердить исходный выход.',
        );
    } finally {
      if (_actorCurrent) setState(() => _changingMembership = false);
    }
  }

  Future<void> _kick([TimewebMeetingParticipant? person]) async {
    final flow = _kickFlow;
    if (!_current ||
        !_organizer ||
        _pendingLeave ||
        _loading ||
        _joining ||
        _changingMembership ||
        flow == null)
      return;
    String? target;
    if (!flow.needsCheck) {
      if (person == null || flow.rejected) return;
      person.requireCurrent();
      target = person.uid;
      if (target == _owner || target == _meeting!.organizerUid) return;
    }
    final id = flow.meetingId;
    setState(() {
      _changingMembership = true;
      _membershipNotice = null;
    });
    try {
      final outcome = flow.needsCheck
          ? await flow.check()
          : await flow.submit(targetUid: target);
      if (!_actorCurrent) return;
      flow.requireCurrent();
      if (outcome == TimewebMeetingMembershipOutcome.confirmed) {
        final receipt = flow.kickReceipt;
        if (receipt == null ||
            receipt.meetingId != id ||
            receipt.targetUid != flow.targetUid) {
          throw StateError('Missing original kick receipt');
        }
        receipt.requireCurrent();
        _purgeMembershipReads();
        setState(
          () => _membershipNotice =
              'Исключение подтверждено. Обновляем участников.',
        );
        await _load();
        if (_current) await _load(roster: true);
      } else {
        setState(
          () => _membershipNotice =
              outcome == TimewebMeetingMembershipOutcome.unknown
              ? 'Проверьте исходное исключение участника.'
              : 'Исключение участника отклонено.',
        );
        if (outcome == TimewebMeetingMembershipOutcome.rejected) {
          _purgeMembershipReads();
          await _load();
        }
      }
    } catch (_) {
      if (_actorCurrent)
        setState(
          () => _membershipNotice =
              'Не удалось подтвердить исключение участника.',
        );
    } finally {
      if (_actorCurrent) setState(() => _changingMembership = false);
    }
  }

  Future<void> _selectScope() async {
    if (!_current || _loading) return;
    final overlay = _fieldsNavigator.currentState?.overlay;
    if (overlay == null) return;
    final value = await showMenu<String>(
      context: overlay.context,
      useRootNavigator: false,
      position: const RelativeRect.fromLTRB(16, 0, 160, 0),
      initialValue: _scope,
      items: [
        for (final scope in const ['group', 'individual'])
          PopupMenuItem(
            value: scope,
            child: Text(
              context.tr(scope == 'group' ? 'Групповые' : 'Индивидуальные'),
            ),
          ),
      ],
    );
    if (!_current || _loading || value == null) return;
    setState(() => _scope = value);
    await _load();
  }

  @override
  void dispose() {
    _translator.dispose();
    _generation++;
    _joinFlow?.close();
    _joinFlow = null;
    _leaveFlow?.close();
    _kickFlow?.close();
    _leaveFlow = _kickFlow = null;
    _changingMembership = false;
    _membershipNotice = null;
    _joining = false;
    _joinUnavailable = false;
    _joinNotice = null;
    _chatNotice = _archiveNotice = null;
    _page = null;
    _meeting = null;
    _participants = null;
    _filters = null;
    _countries = null;
    _country = _region = null;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    backgroundAsset: 'assets/final_design/family_front.png',
    appBar: _bar(
      context,
      widget.meetingId == null ? 'Встречи' : 'О встрече',
      mainList: widget.meetingId == null,
      scopeControl: widget.meetingId == null
          ? IconButton(
              key: const ValueKey('native-meeting-scope'),
              tooltip: context.tr('Тип встречи'),
              onPressed: _current && !_loading ? _selectScope : null,
              icon: const Icon(Icons.menu),
            )
          : null,
      action: widget.meetingId == null
          ? OutlinedButton.icon(
              key: const ValueKey('native-meeting-create'),
              style: OutlinedButton.styleFrom(
                backgroundColor: LrsTheme.peach.withValues(alpha: .25),
                foregroundColor: LrsTheme.text,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                textStyle: const TextStyle(
                  fontFamily: 'Lato',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed:
                  !_current || !_runtime.meetingCreationEnabled || _loading
                  ? null
                  : () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => MeetingForm(nativeRuntime: _runtime),
                      ),
                    ),
              icon: const Icon(Icons.add, size: 18),
              label: Text(
                context.tr('Создать'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            )
          : null,
    ),
    body: !_current
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.tr(
                    _actorCurrent
                        ? 'Данные встречи недоступны'
                        : 'Сеанс завершён',
                  ),
                ),
                if (_actorCurrent)
                  TextButton(
                    key: const ValueKey('native-meetings-refresh'),
                    onPressed: _loading ? null : () => _load(),
                    child: Text(context.tr('Обновить')),
                  ),
              ],
            ),
          )
        : NavigatorPopHandler<void>(
            onPopWithResult: (_) => _fieldsNavigator.currentState?.pop(),
            child: Navigator(
              key: _fieldsNavigator,
              pages: [MaterialPage<void>(child: _body())],
              onDidRemovePage: (_) {},
            ),
          ),
  );
  Widget _body() => ListView(
    key: const ValueKey('native-meetings-scroll'),
    padding: const EdgeInsets.all(16),
    children: [
      if (widget.meetingId == null) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('native-meeting-help'),
            icon: const Icon(Icons.help_outline),
            label: Text(context.tr('Как создать встречу')),
            onPressed: () {
              final guide = TimewebNavigationScope.wrap(
                context,
                const MeetingGuidePage(
                  showLegacyNavigation: false,
                  nativeBottomNavigationBar: TimewebBottomNavigationBar(),
                ),
              );
              Navigator.of(
                context,
              ).push<void>(MaterialPageRoute(builder: (_) => guide));
            },
          ),
        ),
        SizedBox(
          height: (MediaQuery.sizeOf(context).height * .12).clamp(64, 112),
        ),
        if (_countries != null)
          _locations(
            context,
            _countries!,
            _country,
            _region,
            (country, region) {
              setState(() {
                _country = country;
                _region = region;
              });
              unawaited(_load());
            },
            filter: true,
            compact: true,
            enabled: !_loading,
          ),
        const SizedBox(height: 16),
        for (final meeting in _page?.items ?? <TimewebMeeting>[])
          _meetingCard(
            context,
            meeting,
            translator: _translator,
            tap: () {
              meeting.requireCurrent();
              unawaited(_open(meeting.meetingId));
            },
          ),
        if (_page?.items.isEmpty == true)
          Text(
            context.tr(
              _page?.nextCursor == null
                  ? 'По выбранным параметрам встреч пока нет'
                  : 'На этой странице нет доступных встреч',
            ),
          ),
        if (_page?.nextCursor != null)
          TextButton(
            key: const ValueKey('native-meetings-next'),
            onPressed: _loading ? null : () => _load(next: true),
            child: Text(context.tr('Следующая страница')),
          ),
      ] else if (_meeting != null) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('native-meeting-participants'),
            style: TextButton.styleFrom(
              foregroundColor: LrsTheme.peachLight,
              backgroundColor: Colors.transparent,
            ),
            onPressed: _memberActionsLocked || _loading || _joining
                ? null
                : _openParticipants,
            icon: const Icon(Icons.people_outline, size: 18),
            label: Text(context.tr('Участники встречи')),
          ),
        ),
        _meetingCard(context, _meeting!, translator: _translator, full: true),
        if (!_pendingLeave && !_organizer)
          _left(
            TextButton(
              key: const ValueKey('native-meeting-join'),
              onPressed:
                  _memberActionsLocked ||
                      _loading ||
                      _joining ||
                      _joinFlow == null ||
                      _joinFlow!.rejected ||
                      _joinFlow!.receipt != null
                  ? null
                  : _join,
              child: Text(
                context.tr(
                  _joinFlow?.receipt != null
                      ? (_joinFlow!.receipt!.alreadyMember
                            ? 'Вы уже участник'
                            : 'Вы участник')
                      : (_joinFlow?.needsCheck == true
                            ? 'Проверить присоединение'
                            : 'Присоединиться'),
                ),
              ),
            ),
          ),
        if (!_pendingLeave && _joinNotice != null)
          _left(ClrsPanel(child: Text(context.tr(_joinNotice!)))),
        if (_joinUnavailable)
          _left(Text(context.tr('Присоединение пока недоступно.'))),
        if (_joining) const Center(child: CircularProgressIndicator()),
        _left(
          TextButton(
            key: const ValueKey('native-meeting-discussion'),
            onPressed: _memberActionsLocked || _loading || _joining
                ? null
                : _openConversation,
            child: Text(context.tr('Обсуждение встречи')),
          ),
        ),
        if (_chatNotice != null) _left(Text(context.tr(_chatNotice!))),
        _left(
          TextButton(
            key: const ValueKey('native-meeting-archive'),
            onPressed: _memberActionsLocked || _loading || _joining
                ? null
                : _openArchive,
            child: Text(context.tr('Сохранённая история')),
          ),
        ),
        for (final person
            in _participants?.items ?? <TimewebMeetingParticipant>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _left(
              ClrsPanel(
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: const Color(0x856A4631),
                      child: Text(_participantInitial(person.fullName)),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            person.fullName ?? context.tr('Имя не указано'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (person.uid == _meeting!.organizerUid)
                            Text(
                              context.tr('Организатор'),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                        ],
                      ),
                    ),
                    if (_organizer)
                      IconButton(
                        key: ValueKey('native-meeting-kick-${person.uid}'),
                        tooltip: context.tr('Исключить участника'),
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed:
                            _memberActionsLocked ||
                                _loading ||
                                _joining ||
                                _kickFlow == null ||
                                _kickFlow!.rejected ||
                                person.uid == _owner
                            ? null
                            : () => _kick(person),
                      ),
                  ],
                ),
              ),
            ),
          ),
        if (_participants?.items.isEmpty == true)
          Text(
            context.tr(
              _participants?.nextCursor == null
                  ? 'Участников пока нет'
                  : 'На этой странице нет доступных участников',
            ),
          ),
        if (_participants?.nextCursor != null)
          TextButton(
            key: const ValueKey('native-participants-next'),
            onPressed: _memberActionsLocked || _loading || _joining
                ? null
                : () => _load(roster: true, next: true),
            child: Text(context.tr('Следующая страница')),
          ),
      ],
      if (_pendingLeave)
        _left(
          TextButton(
            key: const ValueKey('native-meeting-leave-check'),
            onPressed: _loading || _changingMembership ? null : _checkLeave,
            child: Text(context.tr('Проверить выход')),
          ),
        ),
      if (_pendingKick && _organizer)
        _left(
          TextButton(
            key: const ValueKey('native-meeting-kick-check'),
            onPressed: _loading || _changingMembership ? null : () => _kick(),
            child: Text(context.tr('Проверить исключение')),
          ),
        ),
      if (_membershipNotice != null)
        _left(Text(context.tr(_membershipNotice!))),
      if (_archiveNotice != null) _left(Text(context.tr(_archiveNotice!))),
      if (_changingMembership) const Center(child: CircularProgressIndicator()),
      if (_error)
        Text(context.tr('Не удалось загрузить данные. Обновите страницу.')),
      if (_loading) const Center(child: CircularProgressIndicator()),
      TextButton(
        key: const ValueKey('native-meetings-refresh'),
        onPressed:
            _pendingLeave ||
                _pendingKick ||
                _changingMembership ||
                _loading ||
                _joining
            ? null
            : () => _load(),
        child: Text(context.tr('Обновить')),
      ),
    ],
  );
}

/// Original durable intent is owned by the flow; widget errors never clear it.
class TimewebMeetingCreationView extends StatefulWidget {
  const TimewebMeetingCreationView({super.key, required this.runtime});
  final TimewebAppRuntime runtime;
  @override
  State<TimewebMeetingCreationView> createState() =>
      _TimewebMeetingCreationViewState();
}

class _TimewebMeetingCreationViewState
    extends State<TimewebMeetingCreationView> {
  final _fieldsNavigator = GlobalKey<NavigatorState>();
  final _name = TextEditingController(), _description = TextEditingController();
  late final TimewebAppRuntime _runtime = widget.runtime;
  late final int _epoch = _runtime.session.state.epoch;
  late final String? _owner = _runtime.session.state.identity?.uid;
  StreamSubscription<AppSessionState>? _subscription;
  TimewebMeetingCreateFlow? _flow;
  BuildContext? _formContext;
  List<GeoCountry>? _countries;
  String? _country, _region, _invitee, _inviteeName, _notice;
  String _type = 'групповая', _date = _wallClock(DateTime.now());
  bool _busy = true, _invalidated = false;
  bool get _current {
    if (!mounted ||
        _invalidated ||
        !identical(widget.runtime, _runtime) ||
        !_runtime.session.state.authenticated ||
        _runtime.session.state.epoch != _epoch ||
        _runtime.session.state.identity?.uid != _owner) {
      return false;
    }
    try {
      _flow?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get _locked =>
      _busy || _flow == null || _flow!.needsCheck || _flow!.rejected;
  @override
  void initState() {
    super.initState();
    _subscription = _runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final countries = await GeoCatalog.load();
      if (!_current) return;
      final flow = await _runtime.openMeetingCreation();
      if (!_current) {
        flow.close();
        return;
      }
      flow.requireCurrent();
      final pending = flow.pendingRequest?.fields;
      setState(() {
        _flow = flow;
        _countries = countries;
        _busy = false;
        if (pending != null) {
          _name.text = pending['name'] as String;
          _description.text = pending['description'] as String;
          _country = pending['countryCode'] as String;
          _region = pending['region'] as String;
          _date = pending['datetime'] as String;
          _type = pending['type'] as String;
          _invitee = pending['invitedUid'] as String?;
          _notice =
              'Проверьте результат исходной операции без повторной отправки.';
        }
      });
    } catch (_) {
      if (_current) {
        setState(() {
          _busy = false;
          _notice =
              'Не удалось восстановить создание встречи. Закройте форму и откройте снова.';
        });
      }
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _flow?.close();
    _flow = null;
    _countries = null;
    _formContext = null;
    _name.clear();
    _description.clear();
    _country = _region = _invitee = _inviteeName = _notice = null;
    _date = '';
    _type = 'групповая';
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst)
        Navigator.of(context).removeRoute(route);
    });
  }

  @override
  void didUpdateWidget(covariant TimewebMeetingCreationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.runtime, oldWidget.runtime)) _invalidate();
  }

  Future<void> _dateTime() async {
    final selected = parseMeetingDateTime(_date) ?? DateTime.now();
    final date = await showDatePicker(
      context: _formContext!,
      useRootNavigator: false,
      initialDate: selected,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!_current || date == null) return;
    final time = await showTimePicker(
      context: _formContext!,
      useRootNavigator: false,
      initialTime: TimeOfDay.fromDateTime(selected),
    );
    if (!_current || time == null) return;
    setState(
      () => _date = _wallClock(
        DateTime(date.year, date.month, date.day, time.hour, time.minute),
      ),
    );
  }

  Future<void> _pickInvitee() async {
    final person = await Navigator.of(_formContext!).push<TimewebPublicPerson>(
      MaterialPageRoute(
        builder: (pickerContext) => TimewebPeoplePageView(
          runtime: _runtime,
          onSelected: (person) {
            person.requireCurrent();
            Navigator.of(pickerContext).pop(person);
          },
        ),
      ),
    );
    if (!_current || person == null) return;
    person.requireCurrent();
    if (person.uid == _owner) return;
    setState(() {
      _invitee = person.uid;
      _inviteeName = person.fullName;
    });
  }

  Future<void> _submit() async {
    if (!_current || _busy || _flow == null || _flow!.rejected) return;
    final flow = _flow!;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final outcome = flow.needsCheck
          ? await flow.check()
          : await flow.submit(
              await TimewebMeetingCreateRequest.fromCatalog(
                name: _name.text,
                description: _description.text,
                countryCode: _country ?? '',
                region: _region ?? '',
                datetime: _date,
                type: _type,
                invitedUid: _type == 'индивидуальная' ? _invitee : null,
              ),
            );
      if (!mounted || !_current) return;
      flow.requireCurrent();
      if (outcome == TimewebMeetingCreateOutcome.confirmed) {
        final receipt = flow.receipt;
        if (receipt == null) throw StateError('Missing confirmation');
        receipt.requireCurrent();
        await Navigator.of(context).pushReplacement<void, void>(
          MaterialPageRoute(
            settings: const RouteSettings(name: timewebMeetingsRoute),
            builder: (_) => TimewebMeetingsPageView(
              runtime: _runtime,
              meetingId: receipt.meetingId,
            ),
          ),
        );
      } else {
        setState(
          () => _notice = outcome == TimewebMeetingCreateOutcome.rejected
              ? 'Создание встречи отклонено.'
              : 'Подтверждение ещё не получено. Проверьте исходную операцию.',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = flow.needsCheck
              ? 'Подтверждение ещё не получено. Проверьте исходную операцию.'
              : 'Проверьте название, страну, регион и получателя.',
        );
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _flow?.close();
    _flow = null;
    _countries = null;
    _formContext = null;
    _country = _region = _invitee = _inviteeName = _notice = null;
    _name.dispose();
    _description.dispose();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    backgroundAsset: 'assets/final_design/family_front.png',
    appBar: _bar(context, 'Создать встречу'),
    body: !_current
        ? Center(child: Text(context.tr('Сеанс завершён')))
        : NavigatorPopHandler<void>(
            onPopWithResult: (_) => _fieldsNavigator.currentState?.pop(),
            child: Navigator(
              key: _fieldsNavigator,
              pages: [
                MaterialPage<void>(
                  child: Builder(
                    builder: (context) {
                      _formContext = context;
                      return _body();
                    },
                  ),
                ),
              ],
              onDidRemovePage: (_) {},
            ),
          ),
  );
  Widget _body() => ListView(
    key: const ValueKey('native-meeting-form-scroll'),
    padding: const EdgeInsets.all(16),
    children: [
      AbsorbPointer(
        absorbing: _locked,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('native-meeting-name'),
              controller: _name,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: context.tr('Название встречи'),
              ),
            ),
            if (_countries != null)
              _locations(
                context,
                _countries!,
                _country,
                _region,
                (country, region) => setState(() {
                  _country = country;
                  _region = region;
                }),
              ),
            TextField(
              key: const ValueKey('native-meeting-description'),
              controller: _description,
              maxLength: 4096,
              minLines: 2,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: context.tr('Краткое описание встречи'),
              ),
            ),
            Text(_date),
            TextButton(
              onPressed: _dateTime,
              child: Text(context.tr('Выбрать дату и время')),
            ),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: InputDecoration(labelText: context.tr('Тип встречи')),
              isExpanded: true,
              items: [
                for (final type in const ['групповая', 'индивидуальная'])
                  DropdownMenuItem(
                    value: type,
                    child: Text(
                      context.tr(
                        type == 'групповая' ? 'Групповая' : 'Индивидуальная',
                      ),
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _type = value!),
            ),
            if (_type == 'индивидуальная')
              TextButton(
                key: const ValueKey('native-meeting-invitee'),
                onPressed: _pickInvitee,
                child: Text(
                  _invitee == null
                      ? context.tr('Выберите получателя')
                      : (_inviteeName ?? context.tr('Получатель выбран')),
                ),
              ),
          ],
        ),
      ),
      if (_notice != null) ClrsPanel(child: Text(context.tr(_notice!))),
      if (_busy) const Center(child: CircularProgressIndicator()),
      TextButton(
        key: const ValueKey('native-meeting-submit'),
        onPressed: _busy || _flow == null || _flow!.rejected ? null : _submit,
        child: Text(
          context.tr(
            _flow?.needsCheck == true
                ? 'Проверить исходную операцию'
                : 'Создать',
          ),
        ),
      ),
    ],
  );
}
