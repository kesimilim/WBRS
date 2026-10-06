import 'package:wbrs/shared/translatable_text.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/message_tile.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/shared/meeting_form.dart' show parseMeetingDateTime;
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/service/chat_submission.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/meeting_membership_service.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/paged_firestore_history.dart';

import '../edit_meet/edit_meet.dart';

class UserInfo {
  final String name, age, city, imageUrl, group, uid;
  final Map userInfo;
  UserInfo(
    this.name,
    this.age,
    this.city,
    this.imageUrl,
    this.group,
    this.uid,
    this.userInfo,
  );
}

class ChatPage extends StatefulWidget {
  final String groupId, groupName;
  final List users;
  final bool isUserJoin;
  final MeetingMembershipService? membershipService;
  final ChatSubmissionService? submissions;
  const ChatPage({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.users,
    required this.isUserJoin,
    this.membershipService,
    this.submissions,
  });
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static double _leftColumnWidth(double availableWidth) =>
      availableWidth * 2 / 3;

  final _messageController = TextEditingController();
  final _messageScrollController = ScrollController();
  final _summaryScrollController = ScrollController();
  late final String? _ownerUid;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _chats;
  DocumentSnapshot<Map<String, dynamic>>? _meet;
  List<UserInfo> _users = [];
  List<String> _mutedUsers = [];
  bool _joined = false, _kicked = false, _admin = false;
  final _history = PagedFirestoreHistory(80);
  int _messageGeneration = 0;
  bool _loadingOlder = false, _olderError = false;
  Timer? _messageWaitTimer;
  bool _messageWaitExpired = false;
  bool _loading = true,
      _loadFailed = false,
      _sending = false,
      _changingMembership = false,
      _changingNotification = false;
  String _description = '';
  String _participantQuery = '';
  late final MeetingMembershipService _membership;
  MeetingMembershipRequest? _membershipRequest;
  String? _membershipNotice;
  bool _restoringMembership = true;
  late final ChatSubmissionService _submissions;
  ChatSubmission? _outgoing;
  bool _restoringMessage = true, _messageRestoreFailed = false;
  PendingWrite? get _pendingMessage => _outgoing?.write;

  bool get _active =>
      mounted &&
      _ownerUid != null &&
      firebaseAuth.currentUser?.uid == _ownerUid;
  DocumentReference<Map<String, dynamic>> get _meetRef =>
      firebaseFirestore.collection('meets').doc(widget.groupId);
  bool get _muted => _mutedUsers.contains(_ownerUid);

  @override
  void initState() {
    super.initState();
    _ownerUid = firebaseAuth.currentUser?.uid;
    _joined = widget.isUserJoin;
    _membership =
        widget.membershipService ??
        MeetingMembershipService(meetingId: widget.groupId);
    _restoreMembership();
    _submissions = widget.submissions ?? ChatSubmissionService();
    _restoreMessage();
    _setMessageStream();
    _loadMeeting();
  }

  Future<void> _restoreMessage() async {
    if (!_active) return;
    setState(() {
      _restoringMessage = true;
      _messageRestoreFailed = false;
    });
    try {
      final request = await _submissions.restore(widget.groupId, group: true);
      if (!_active) return;
      setState(() {
        _outgoing = request?.write.failed == true ? null : request;
        if (request != null) _messageController.text = request.text;
      });
    } catch (_) {
      if (_active) setState(() => _messageRestoreFailed = true);
    } finally {
      if (_active) setState(() => _restoringMessage = false);
    }
  }

  Future<void> _restoreMembership() async {
    try {
      final request = await _membership.restore();
      if (_active) setState(() => _membershipRequest = request);
    } catch (_) {
      if (_active) {
        setState(
          () => _membershipNotice =
              'Не удалось восстановить изменение участия. Повторите проверку.',
        );
      }
    } finally {
      if (_active) setState(() => _restoringMembership = false);
    }
  }

  @override
  void dispose() {
    _messageGeneration++;
    _messageWaitTimer?.cancel();
    _messageController.dispose();
    _messageScrollController.dispose();
    _summaryScrollController.dispose();
    super.dispose();
  }

  Query<Map<String, dynamic>> _messageQuery() {
    final source = _joined || _ownerUid == null
        ? _meetRef.collection('messages')
        : firebaseFirestore
              .collection('users')
              .doc(_ownerUid)
              .collection('removed_meets')
              .doc(widget.groupId)
              .collection('messages');
    return source.orderBy('time', descending: true);
  }

  void _setMessageStream() {
    final generation = ++_messageGeneration;
    _messageWaitTimer?.cancel();
    _messageWaitExpired = false;
    _history.reset();
    _loadingOlder = false;
    _olderError = false;
    // Load history on demand: an archived chat may contain years of messages.
    final timer = Timer(const Duration(seconds: 20), () {
      if (_active) setState(() => _messageWaitExpired = true);
    });
    _messageWaitTimer = timer;
    _chats = _messageQuery().limit(_history.pageSize + 1).snapshots().map((
      snapshot,
    ) {
      timer.cancel();
      if (generation == _messageGeneration) _history.receiveLive(snapshot);
      return snapshot;
    });
  }

  Future<void> _loadOlderMessages() async {
    final cursor = _history.cursor;
    if (!_active || _loadingOlder || !_history.hasMore || cursor == null)
      return;
    final generation = _messageGeneration;
    setState(() {
      _loadingOlder = true;
      _olderError = false;
    });
    try {
      final page = await _messageQuery()
          .startAfterDocument(cursor)
          .limit(_history.pageSize + 1)
          .get()
          .timeout(const Duration(seconds: 20));
      if (!_active || generation != _messageGeneration) return;
      setState(() => _history.appendOlder(page));
    } catch (_) {
      if (_active && generation == _messageGeneration) {
        setState(() => _olderError = true);
      }
    } finally {
      if (_active && generation == _messageGeneration) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  Future<void> _loadMeeting() async {
    if (!_active) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final meet = await _meetRef.get().timeout(const Duration(seconds: 15));
      if (!_active) return;
      final data = meet.data();
      if (!meet.exists || data == null) throw StateError('Встреча недоступна');
      final ids = (data['users'] as List? ?? const [])
          .whereType<String>()
          .toSet();
      final profiles = await Future.wait(
        ids.map((uid) => firebaseFirestore.collection('users').doc(uid).get()),
      ).timeout(const Duration(seconds: 15));
      if (!_active) return;
      final users = <UserInfo>[];
      for (final profile in profiles) {
        final user = profile.data();
        if (!profile.exists || user == null) continue;
        users.add(
          UserInfo(
            '${user['fullName'] ?? ''}',
            '${user['age'] ?? ''}',
            '${user['city'] ?? ''}',
            '${user['profilePicThumb'] ?? user['profilePic'] ?? ''}',
            '${user['группа'] ?? ''}',
            '${user['uid'] ?? profile.id}',
            user,
          ),
        );
      }
      users.sort((a, b) {
        if (a.uid == data['admin']) return -1;
        if (b.uid == data['admin']) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      final joined = ids.contains(_ownerUid);
      setState(() {
        _meet = meet;
        _description = '${data['description'] ?? ''}';
        _admin = data['admin'] == _ownerUid;
        _kicked = (data['kicked'] as List? ?? const []).contains(_ownerUid);
        _mutedUsers = (data['usersWithoutNotification'] as List? ?? const [])
            .whereType<String>()
            .toList();
        _users = users;
        if (_joined != joined) {
          _joined = joined;
          _setMessageStream();
        }
      });
    } catch (_) {
      if (_active) setState(() => _loadFailed = true);
    } finally {
      if (_active) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
    if (_active) showSnackbar(context, LrsTheme.danger, context.tr(message));
  }

  Widget _descriptionPanel({bool full = false}) => Container(
    padding: const EdgeInsets.all(12),
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0x6631241D),
      border: Border.all(color: const Color(0x77E7B092)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orangeAccent, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                context.tr('Описание встречи'),
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _description.isEmpty
            ? Text(
                context.tr('Описание отсутствует'),
                style: const TextStyle(color: LrsTheme.text, fontSize: 14),
              )
            : TranslatableText(
                _description,
                maxLines: full ? null : 3,
                overflow: full ? null : TextOverflow.ellipsis,
                style: const TextStyle(color: LrsTheme.text, fontSize: 14),
              ),
      ],
    ),
  );

  DateTime? get _meetingDate {
    final raw = _meet?.data()?['datetime'];
    return raw is Timestamp
        ? raw.toDate()
        : raw is DateTime
        ? raw
        : parseMeetingDateTime('$raw');
  }

  Widget _meetingSummary() {
    final data = _meet?.data() ?? const <String, dynamic>{};
    final location = [
      if (data['country'] != null) context.tr('${data['country']}'),
      data['region'],
    ].where((value) => value != null && '$value'.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
      child: ClrsPanel(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.calendar_today_outlined,
                  size: 20,
                  color: LrsTheme.peachLight,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_meetingDate != null)
                        Text(
                          context.l10n.dateTime(_meetingDate!),
                          style: const TextStyle(fontSize: 12),
                        ),
                      if (location.isNotEmpty)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.location_on_outlined, size: 12),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                location,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: LrsTheme.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 14),
            InkWell(
              onTap: _showDescription,
              child: Row(
                children: [
                  const Icon(Icons.article_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.tr('О встрече'),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDescription() async {
    if (!_active) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) => ClrsScaffold(
                  appBar: AppBar(title: Text(context.tr('Описание встречи'))),
                  body: LayoutBuilder(
                      builder: (context, constraints) => Align(
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                              key: const ValueKey('meeting-description-column'),
                              width: _leftColumnWidth(constraints.maxWidth),
                              height: constraints.maxHeight,
                              child: SingleChildScrollView(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                    const Padding(
                                        padding: EdgeInsets.symmetric(
                                            horizontal: 16),
                                        child: ClrsBrandHeader()),
                                    _descriptionPanel(full: true),
                                  ]))))),
                )));
  }

  Future<void> _showUsers() async {
    if (!_active) return;
    final actionStyle = OutlinedButton.styleFrom(
      foregroundColor: LrsTheme.text,
      backgroundColor: LrsTheme.actionGlass,
      minimumSize: const Size(48, 44),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      side: const BorderSide(color: LrsTheme.actionBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    );
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (sheetContext) => StatefulBuilder(
          builder: (sheetContext, updateSheet) => Stack(
            children: [
              Positioned.fill(
                child: Image.asset(
                  'assets/final_design/family_right.png',
                  fit: BoxFit.cover,
                ),
              ),
              Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(
                  backgroundColor: const Color(0xB331241D),
                  title: Text(context.tr('Участники встречи'), maxLines: 2),
                  toolbarHeight: math.max(
                    64,
                    MediaQuery.textScalerOf(sheetContext).scale(36),
                  ),
                ),
                bottomNavigationBar:
                    MediaQuery.viewInsetsOf(sheetContext).bottom == 0
                    ? const MyBottomNavigationBar()
                    : null,
                body: SafeArea(
                  top: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        key: const ValueKey('meeting-participants-column'),
                        width: _leftColumnWidth(constraints.maxWidth),
                        height: constraints.maxHeight,
                        child: CustomScrollView(
                          key: const ValueKey('meeting-participants'),
                          slivers: [
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16),
                                child: ClrsBrandHeader(),
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: ClrsPanel(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      TranslatableText(
                                        widget.groupName,
                                        showAction: false,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      Text(
                                        context.tr(
                                          '{count} участников',
                                          count: _users.length,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: TextField(
                                  onChanged: (value) => updateSheet(
                                    () => _participantQuery = value
                                        .trim()
                                        .toLowerCase(),
                                  ),
                                  decoration: InputDecoration(
                                    prefixIcon: const Icon(Icons.search),
                                    hintText: context.tr('Поиск по имени'),
                                  ),
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              sliver: SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final filtered = _users
                                        .where(
                                          (u) => u.name.toLowerCase().contains(
                                            _participantQuery,
                                          ),
                                        )
                                        .toList();
                                    final user = filtered[index];
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 10,
                                      ),
                                      child: ClrsPanel(
                                        padding: EdgeInsets.zero,
                                        child: InkWell(
                                          onTap: () => nextScreen(
                                            context,
                                            SomebodyProfile(
                                              uid: user.uid,
                                              photoUrl: user.imageUrl,
                                              name: user.name,
                                              userInfo: user.userInfo,
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                GroupAvatar(
                                                  url: user.imageUrl,
                                                  group: user.group,
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(user.name),
                                                      if (user.uid ==
                                                          _meet
                                                              ?.data()?['admin'])
                                                        Text(
                                                          context.tr(
                                                            'Организатор',
                                                          ),
                                                          style:
                                                              const TextStyle(
                                                                color: LrsTheme
                                                                    .peachLight,
                                                              ),
                                                        ),
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        [
                                                              user.age,
                                                              context.tr(
                                                                '${user.userInfo['country'] ?? ''}',
                                                              ),
                                                              '${user.userInfo['region'] ?? ''}',
                                                            ]
                                                            .where(
                                                              (value) => value
                                                                  .isNotEmpty,
                                                            )
                                                            .join(' · '),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                if (_admin &&
                                                    user.uid != _ownerUid)
                                                  IconButton(
                                                    tooltip: context.tr(
                                                      'Исключить участника',
                                                    ),
                                                    icon: const Icon(
                                                      Icons.delete,
                                                      color: Colors.redAccent,
                                                    ),
                                                    onPressed:
                                                        _changingMembership
                                                        ? null
                                                        : () async {
                                                            await _kickUser(
                                                              user.uid,
                                                            );
                                                            if (sheetContext
                                                                .mounted) {
                                                              updateSheet(
                                                                () {},
                                                              );
                                                            }
                                                          },
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                  childCount: _users
                                      .where(
                                        (u) => u.name.toLowerCase().contains(
                                          _participantQuery,
                                        ),
                                      )
                                      .length,
                                ),
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: OutlinedButton.icon(
                                  style: actionStyle,
                                  onPressed: () => Navigator.pop(sheetContext),
                                  icon: const Icon(Icons.chat_bubble_outline),
                                  label: Text(context.tr('Вернуться в чат')),
                                ),
                              ),
                            ),
                            if (_joined)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  child: OutlinedButton.icon(
                                    style: actionStyle,
                                    icon: const Icon(Icons.output_sharp),
                                    onPressed: _changingMembership
                                        ? null
                                        : () async {
                                            final left =
                                                await _changeMembership(
                                                  join: false,
                                                );
                                            if (left && sheetContext.mounted) {
                                              Navigator.pop(sheetContext);
                                            }
                                          },
                                    label: Text(context.tr('Выйти из встречи')),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _kickUser(String uid) async {
    if (!_active || !_admin || _changingMembership) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: LrsTheme.surface,
        content: Text(
          context.tr('Вы уверены, что хотите исключить этого пользователя?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.tr('Нет')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.tr('Да')),
          ),
        ],
      ),
    );
    if (confirmed != true || !_active) return;
    setState(() => _changingMembership = true);
    try {
      await _meetRef.update({
        'users': FieldValue.arrayRemove([uid]),
        'kicked': FieldValue.arrayUnion([uid]),
      });
      if (_active) {
        setState(() => _users.removeWhere((user) => user.uid == uid));
      }
    } catch (_) {
      _showError('Не удалось исключить участника. Проверьте соединение.');
    } finally {
      if (_active) setState(() => _changingMembership = false);
    }
  }

  Future<bool> _changeMembership({required bool join}) async {
    if (!_active ||
        _changingMembership ||
        _restoringMembership ||
        (join && _kicked)) {
      return false;
    }
    setState(() {
      _changingMembership = true;
      _membershipNotice = null;
    });
    try {
      _membershipRequest ??= await _membership.restore();
      if (!_active) return false;
      _membershipRequest ??= _membership.change(joined: join);
      final request = _membershipRequest!;
      final confirmed = await request.write.wait();
      if (!_active) return false;
      if (!confirmed) {
        setState(
          () => _membershipNotice =
              'Результат изменения участия пока неизвестен. Проверьте его перед повтором.',
        );
        return false;
      }
      _membership.acknowledge(request);
      _membershipRequest = null;
      // Refresh from the server, including concurrent removal or exclusion.
      await _loadMeeting();
      return _active && !_loadFailed && _joined == request.joined;
    } catch (_) {
      if (_membershipRequest?.write.failed ?? false) _membershipRequest = null;
      if (_active) {
        setState(
          () => _membershipNotice =
              'Не удалось изменить участие. Проверьте соединение.',
        );
      }
      return false;
    } finally {
      if (_active) setState(() => _changingMembership = false);
    }
  }

  Future<void> _switchNotification() async {
    if (!_active || _changingNotification) return;
    setState(() => _changingNotification = true);
    final wasMuted = _muted;
    try {
      await _meetRef.update({
        'usersWithoutNotification': wasMuted
            ? FieldValue.arrayRemove([_ownerUid])
            : FieldValue.arrayUnion([_ownerUid]),
      });
      if (!_active) return;
      setState(() {
        wasMuted ? _mutedUsers.remove(_ownerUid) : _mutedUsers.add(_ownerUid!);
      });
      if (!mounted) return;
      showSnackbar(
        context,
        Colors.black54,
        context.tr(wasMuted ? 'Уведомления включены' : 'Уведомления выключены'),
      );
    } catch (_) {
      _showError('Не удалось изменить уведомления. Проверьте соединение.');
    } finally {
      if (_active) setState(() => _changingNotification = false);
    }
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    backgroundAsset: 'assets/family_main.jpg',
    bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom == 0
        ? const MyBottomNavigationBar()
        : null,
    appBar: AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      toolbarHeight: MediaQuery.viewInsetsOf(context).bottom > 0 &&
          MediaQuery.sizeOf(context).height < 500
          ? 44 : 56 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
      title: const FittedBox(fit: BoxFit.scaleDown, child: ClrsLogo(size: 34)),
      actions: [
        IconButton(
          tooltip: context.tr(
            _muted ? 'Включить уведомления' : 'Выключить уведомления',
          ),
          onPressed: _changingNotification ? null : _switchNotification,
          icon: Icon(_muted ? Icons.notifications_off : Icons.notifications),
        ),
        Tooltip(
          message: context.tr('Список участников'),
          child: TextButton(
          key: const ValueKey('meeting-participants-action'),
          onPressed: _loading ? null : _showUsers,
          child: FittedBox(fit: BoxFit.scaleDown, child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.people_alt_outlined, color: LrsTheme.text),
              if (!_loading)
                Text(
                  context.l10n.number(_users.length),
                  style: const TextStyle(color: LrsTheme.text, fontSize: 11),
                ),
            ],
          )),
        ),
        ),
        if (_joined || (_admin && _meet != null))
          PopupMenuButton<String>(
            tooltip: context.tr('Встреча'),
            onSelected: (value) async {
              if (value == 'leave') {
                final left = await _changeMembership(join: false);
                if (left && context.mounted) Navigator.pop(context);
              }
              if (value == 'edit' && _meet != null && context.mounted) {
                nextScreenReplace(context, EditMeet(meet: _meet!));
              }
            },
            itemBuilder: (_) => [
              if (_joined)
                PopupMenuItem(
                  value: 'leave',
                  enabled: !_changingMembership,
                  child: Text(context.tr('Выйти из встречи')),
                ),
              if (_admin && _meet != null)
                PopupMenuItem(
                  value: 'edit',
                  child: Text(context.tr('Редактировать встречу')),
                ),
            ],
          ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _loadFailed
        ? _loadError()
        : SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  if (constraints.maxHeight >= 180 && MediaQuery.viewInsetsOf(this.context).bottom == 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 12, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IconButton(
                          onPressed: Navigator.of(context).canPop()
                              ? () => Navigator.pop(context)
                              : null,
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TranslatableText(
                                widget.groupName,
                                showAction: false,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 21),
                              ),
                              Text(
                                '${context.tr('{count} участников', count: _users.length)}${_meetingDate == null ? '' : ' · ${context.l10n.date(_meetingDate!)}'}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: LrsTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_membershipNotice != null || _membershipRequest != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .16,
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_membershipNotice != null)
                                Text(context.tr(_membershipNotice!)),
                              TextButton(
                                onPressed: _changingMembership
                                    ? null
                                    : () => _changeMembership(
                                        join:
                                            _membershipRequest?.joined ??
                                            _joined,
                                      ),
                                child: Text(context.tr('Проверить результат')),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (!_kicked && MediaQuery.viewInsetsOf(this.context).bottom == 0)
                    Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        key: const ValueKey('meeting-chat-column'),
                        width: _leftColumnWidth(constraints.maxWidth),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: math.min(
                              140,
                              constraints.maxHeight * .25,
                            ),
                          ),
                          child: Scrollbar(
                            controller: _summaryScrollController,
                            child: SingleChildScrollView(
                              key: const ValueKey('meeting-summary-scroll'),
                              controller: _summaryScrollController,
                              child: _meetingSummary(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Expanded(child: _chatMessages()),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.min(180, constraints.maxHeight *
                        (constraints.maxHeight < 180 ? .7 : .3)),
                    ),
                    child: SingleChildScrollView(
                      child: SafeArea(top: false, child: _composer()),
                    ),
                  ),
                ],
              ),
            ),
          ),
  );

  Widget _loadError() => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: ClrsPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.tr('Не удалось загрузить встречу. Проверьте подключение.'),
          ),
          TextButton(
            onPressed: _loadMeeting,
            child: Text(context.tr('Повторить')),
          ),
        ],
      ),
    ),
  );

  Widget _composer() => Container(
    key: const ValueKey('meeting-message-composer'),
    margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
    decoration: BoxDecoration(
      color: const Color(0x6631241D),
      border: Border.all(color: LrsTheme.actionBorder),
      borderRadius: BorderRadius.circular(18),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: _joined
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _messageController,
                      enabled:
                          !_sending &&
                          !_restoringMessage &&
                          !_messageRestoreFailed &&
                          _pendingMessage == null,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: context.tr('Отправить сообщение...'),
                        hintStyle: TextStyle(color: Colors.white, fontSize: 16),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  IconButton.filled(
                    key: const ValueKey('meeting-send-action'),
                    style: IconButton.styleFrom(
                      backgroundColor: LrsTheme.peach,
                      foregroundColor: LrsTheme.background,
                      disabledBackgroundColor: LrsTheme.actionDisabled,
                      shape: const CircleBorder(),
                    ),
                    tooltip: context.tr(
                      _pendingMessage == null && !_messageRestoreFailed
                          ? 'Отправить сообщение'
                          : 'Проверить отправку',
                    ),
                    onPressed: _sending || _restoringMessage
                        ? null
                        : _messageRestoreFailed
                        ? _restoreMessage
                        : _sendMessage,
                    icon: _sending || _restoringMessage
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _pendingMessage == null && !_messageRestoreFailed
                                ? Icons.send
                                : Icons.refresh,
                            color: LrsTheme.background,
                          ),
                  ),
                ],
              ),
              if (_messageRestoreFailed)
                Text(
                  context.tr(
                    'Не удалось восстановить отправку. Попробуйте ещё раз.',
                  ),
                ),
              if (_pendingMessage != null && !_sending)
                Text(
                  context.tr(
                    'Результат отправки пока неизвестен. Проверьте его перед повторной отправкой.',
                  ),
                  style: const TextStyle(color: LrsTheme.peachLight),
                ),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(
                  _kicked
                      ? 'Вы были исключены из встречи'
                      : 'Вы не являетесь участником встречи',
                ),
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              if (!_kicked)
                TextButton(
                  onPressed: _changingMembership
                      ? null
                      : () => _changeMembership(join: true),
                  child: Text(
                    context.tr('Присоединиться'),
                    style: TextStyle(color: LrsTheme.peachLight),
                  ),
                ),
            ],
          ),
  );

  Widget _chatMessages() => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
    stream: _chats,
    builder: (context, snapshot) {
      if (snapshot.hasError || (_messageWaitExpired && !snapshot.hasData)) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ClrsPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.tr(
                    'Не удалось загрузить сообщения. Проверьте подключение.',
                  ),
                ),
                TextButton(
                  onPressed: () => setState(_setMessageStream),
                  child: Text(context.tr('Повторить')),
                ),
              ],
            ),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final docs = _history.documents;
      if (docs.isEmpty) {
        return Center(child: Text(context.tr('Сообщений пока нет')));
      }
      final hasOlder = _history.hasMore;
      return ListView.builder(
        controller: _messageScrollController,
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 16),
        itemCount: docs.length + (hasOlder ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == docs.length) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_olderError)
                    Text(
                      context.tr(
                        'Не удалось загрузить сообщения. Проверьте подключение.',
                      ),
                    ),
                  TextButton(
                    onPressed: _loadingOlder ? null : _loadOlderMessages,
                    child: _loadingOlder
                        ? const CircularProgressIndicator(strokeWidth: 2)
                        : Text(
                            context.tr(
                              _olderError ? 'Повторить' : 'Загрузить ещё',
                            ),
                          ),
                  ),
                ],
              ),
            );
          }
          final data = docs[index].data();
          final sender = '${data['sender'] ?? ''}';
          UserInfo? profile;
          for (final user in _users) {
            if (user.uid == sender) {
              profile = user;
              break;
            }
          }
          return MessageTile(
            compactMeeting: true,
            key: ValueKey(docs[index].id),
            avatar: GroupAvatar(
              url: profile?.imageUrl ?? '',
              group: profile?.group ?? '',
              size: 44,
            ),
            name: '${data['name'] ?? profile?.name ?? ''}',
            sender: sender,
            chatId: widget.groupId,
            message: docs[index],
            sentByMe: _ownerUid == sender,
            isRead: true,
            isChat: false,
          );
        },
      );
    },
  );

  Future<void> _sendMessage() async {
    if (!_active ||
        !_joined ||
        _sending ||
        _restoringMessage ||
        _messageRestoreFailed)
      return;
    final text = _outgoing?.text ?? _messageController.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      _outgoing ??= _submissions.start(
        chatId: widget.groupId,
        text: text,
        group: true,
      );
      final operation = _outgoing!;
      final confirmed = await operation.write.wait();
      if (!_active || !confirmed) return;
      _messageController.clear();
      _submissions.acknowledge(widget.groupId, operation, group: true);
      _outgoing = null;
      if (_messageScrollController.hasClients)
        _messageScrollController.jumpTo(0);
    } catch (_) {
      if (!_active) return;
      if (_pendingMessage?.failed ?? true) _outgoing = null;
      _showError(
        'Не удалось отправить сообщение. Текст сохранён; попробуйте ещё раз.',
      );
    } finally {
      if (_active) setState(() => _sending = false);
    }
  }
}
