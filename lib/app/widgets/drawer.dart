import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/app/pages/admin/panel.dart';
import 'package:wbrs/app/widgets/donate_button.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/presentation/screens/about_app/about_app.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/feed/feed_page.dart';
import 'package:wbrs/presentation/screens/feed/author_request_sheet.dart';
import 'package:wbrs/presentation/screens/friends/friends_page.dart';
import 'package:wbrs/presentation/screens/home/home_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/presentation/screens/list_of_users/profiles_list.dart';
import 'package:wbrs/presentation/screens/list_of_visiters/visiters.dart';
import 'package:wbrs/presentation/screens/notifications_center/notifications_page.dart';
import 'package:wbrs/presentation/screens/profile/profile_page.dart';
import 'package:wbrs/presentation/screens/shop/shop.dart';
import 'package:wbrs/presentation/screens/test/red_group.dart';
import 'package:wbrs/service/auth_service.dart';
import 'package:wbrs/service/admin_access.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/invisibility_state.dart';
import 'package:wbrs/service/invisibility_toggle_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class MyDrawer extends StatefulWidget {
  const MyDrawer({super.key});

  @override
  State<MyDrawer> createState() => _MyDrawerState();
}

class _MyDrawerState extends State<MyDrawer> {
  final AuthService _auth = AuthService();
  late final SocialService _social = SocialService();
  Map<String, dynamic> _data = {};
  bool _loading = true;
  bool _loadError = false;
  bool _savingVisibility = false;
  bool _isAdmin = false;
  Set<String> _requestedRoles = {};
  final _roleWrites = <String, PendingWrite>{};
  final _sendingRoles = <String>{};
  String? _dataUid;
  int _loadGeneration = 0;
  late final StreamSubscription<User?> _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = firebaseAuth.authStateChanges().listen((user) {
      if (mounted && user?.uid != _dataUid) _loadUser();
    });
    _loadUser();
  }

  @override
  void dispose() {
    _loadGeneration++;
    _authSubscription.cancel();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final generation = ++_loadGeneration;
    final current = firebaseAuth.currentUser;
    setState(() {
      _dataUid = current?.uid;
      _data = {};
      _isAdmin = false;
      _requestedRoles = {};
      _loading = current != null;
      _loadError = false;
    });
    if (current == null) {
      return;
    }
    try {
      final admin = await AdminAccess.current();
      final doc = await firebaseFirestore
          .collection('users')
          .doc(current.uid)
          .get()
          .timeout(Duration(seconds: 15));
      if (!mounted ||
          generation != _loadGeneration ||
          firebaseAuth.currentUser?.uid != current.uid) {
        return;
      }
      setState(() {
        _data = doc.data() ?? <String, dynamic>{};
        _isAdmin = admin;
        globalAge = _data['age']?.toString() ?? '';
        globalAbout = _data['about']?.toString() ?? '';
        globalCity = (_data['region'] ?? _data['city'] ?? '').toString();
        globalHobbi = _data['hobbi']?.toString() ?? '';
        globalRost = _data['rost']?.toString() ?? '';
        globalDeti = _data['deti'] == true;
        globalBalance = ((_data['balance'] as num?) ?? 0).toInt();
        group = _data['группа']?.toString() ?? '';
        _loading = false;
        _loadError = false;
      });
      unawaited(_loadRequestStatuses(current.uid, generation));
    } catch (_) {
      if (mounted &&
          generation == _loadGeneration &&
          firebaseAuth.currentUser?.uid == current.uid) {
        setState(() {
          _loading = false;
          _loadError = true;
        });
      }
    }
  }

  Future<void> _loadRequestStatuses(String uid, int generation) async {
    final statuses = <String>{};
    for (final role in const ['author', 'moderator']) {
      try {
        final doc = await firebaseFirestore
            .collection('${role}_requests')
            .doc(uid)
            .get()
            .timeout(const Duration(seconds: 10));
        if (doc.data()?['status'] == 'pending' ||
            doc.data()?['status'] == 'approved') statuses.add(role);
      } catch (_) {
        // Profile navigation remains available if the optional request read fails.
      }
    }
    if (mounted && generation == _loadGeneration &&
        firebaseAuth.currentUser?.uid == uid) {
      setState(() => _requestedRoles = {..._requestedRoles, ...statuses});
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = firebaseAuth.currentUser;
    final name = _data['fullName']?.toString() ?? current?.displayName ?? '';
    final photo = _data['profilePicThumb']?.toString() ??
        _data['profilePic']?.toString() ??
        current?.photoURL ??
        '';
    final online = _data['online'] == true;
    final invisible = isInvisibleActive(_data);
    final invisibleUntil = invisiblePeriodEnd(_data);
    final relationStatus =
        _data['relationStatus']?.toString() ?? 'Статус не указан';

    return Drawer(
      backgroundColor: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
              child: Image.asset('assets/final_design/family_right.png',
                  fit: BoxFit.cover)),
          Container(color: const Color(0xBB302110)),
          SafeArea(
            child: current == null || current.uid != _dataUid
                ? Center(
                    child: Text(context.tr('Сеанс завершён. Войдите снова.')))
                : ListView(
                    padding: EdgeInsets.fromLTRB(12, 12, 12, 24),
                    children: [
                      const ClrsLogo(size: 48),
                      if (_loading) const LinearProgressIndicator(),
                      if (_loadError)
                        TextButton.icon(
                            onPressed: _loadUser,
                            icon: const Icon(Icons.refresh),
                            label: Text(context.tr('Повторить'))),
                      const SizedBox(height: 12),
                      const ClrsMotto(),
                      const SizedBox(height: 14),
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: _goToProfile,
                        child: Container(
                          padding: EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Color(0x8031241D),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Color(0x44E7B092)),
                          ),
                          child: Column(
                            children: [
                              GroupAvatar(url: photo, group: group, size: 68),
                              SizedBox(height: 10),
                              Text(
                                name,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: LrsTheme.text,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                              SizedBox(height: 5),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 8,
                                runSpacing: 5,
                                children: [
                                  _statusChip(
                                    online ? 'в сети' : 'не в сети',
                                    online ? LrsTheme.success : LrsTheme.muted,
                                  ),
                                  _statusChip(
                                    invisible ? 'невидимка' : 'видимый',
                                    invisible
                                        ? LrsTheme.peach
                                        : LrsTheme.peachLight,
                                  ),
                                  _statusChip(
                                      relationStatus, LrsTheme.peachDark),
                                ],
                              ),
                              if (group.isNotEmpty) ...[
                                SizedBox(height: 7),
                                Text(
                                  context.tr('Группа: {group}',
                                      args: {'group': context.tr(group)}),
                                  style: TextStyle(
                                      color: LrsTheme.muted, fontSize: 11),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: 10),
                      if (invisibleUntil != null &&
                          invisibleUntil.isAfter(DateTime.now()))
                        ClrsPanel(
                            padding: EdgeInsets.zero,
                            child: SwitchListTile.adaptive(
                              title: Text(context.tr('Режим невидимки')),
                              subtitle: Text(context.tr(invisible
                                  ? 'Активен'
                                  : 'Не активен')),
                              value: invisible,
                              activeColor: LrsTheme.peach,
                              onChanged: _savingVisibility
                                  ? null
                                  : _toggleInvisibility,
                            )),
                      _tile(Icons.home_outlined, 'Лента', () {
                        selectedIndex = 0;
                        nextScreenReplace(context, FeedPage());
                      }),
                      _tile(Icons.quiz_outlined, 'Пройти тест', () {
                        nextScreen(context, FirstGroupRed());
                      }),
                      DonateButton(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: ClrsPanel(
                            padding: EdgeInsets.zero,
                            child: Material(
                              color: Colors.transparent,
                              child: ListTile(
                                dense: true,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16)),
                                leading: const Icon(Icons.favorite_border,
                                    color: LrsTheme.peachLight),
                                title: Text(context.tr('Поддержать проект'),
                                    style: const TextStyle(color: LrsTheme.text)),
                                trailing: Icon(Icons.chevron_right, color: LrsTheme.muted),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _tile(Icons.chat_bubble_outline, 'Чаты', () {
                        selectedIndex = 2;
                        nextScreenReplace(context, HomePage());
                      }),
                      _tile(Icons.visibility_outlined, 'Гости', () {
                        final stream = firebaseFirestore
                            .collection('users')
                            .doc(firebaseAuth.currentUser!.uid)
                            .collection('visiters')
                            .orderBy('lastVisitTs', descending: true)
                            .snapshots();
                        nextScreen(context, MyVisitersPage(visiters: stream));
                      }),
                      _tile(Icons.people_outline, 'Список пользователей',
                          () async {
                        final current = firebaseAuth.currentUser;
                        if (current == null) return;
                        selectedIndex = 1;
                        final userGroup = await getUserGroup();
                        if (!mounted ||
                            firebaseAuth.currentUser?.uid != current.uid) {
                          return;
                        }
                        nextScreenReplace(
                          context,
                          ProfilesList(startPosition: 0, group: userGroup),
                        );
                      }),
                      _tile(Icons.person_add_alt_1_outlined, 'Друзья', () {
                        nextScreen(context, FriendsPage());
                      }),
                      _tile(Icons.notifications_none, 'Уведомления', () {
                        nextScreen(context, NotificationsPage());
                      }),
                      _tile(Icons.card_giftcard, 'Дарить подарки', () {
                        nextScreen(context, ShopPage());
                      }),
                      _tile(Icons.event_outlined, 'Встречи', () {
                        selectedIndex = 3;
                        nextScreenReplace(context, MeetingPage());
                      }),
                      _tile(Icons.info_outline, 'О приложении', () {
                        nextScreen(context, About_App());
                      }),
                      Divider(color: Color(0x44FFFFFF)),
                      if (!_isAdmin && !_requestedRoles.contains('author'))
                        _tile(Icons.edit_note, 'Хочу стать автором',
                            () => _requestRole('author')),
                      if (!_isAdmin && !_requestedRoles.contains('moderator'))
                        _tile(Icons.shield_outlined, 'Хочу стать модератором',
                            () => _requestRole('moderator')),
                      if (_isAdmin)
                        _tile(Icons.admin_panel_settings_outlined,
                            'Панель для админа', () {
                          nextScreen(context, AdminPanel());
                        }),
                      _tile(Icons.settings_outlined, 'Настройки', () {
                        nextScreen(context, const ProfileSettingsPage());
                      }),
                      _tile(Icons.logout, 'Выйти', _confirmLogout),
                      SizedBox(height: 18),
                      const ClrsValuesFooter(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String text, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(.65)),
      ),
      child: Text(context.tr(text),
          style: TextStyle(color: LrsTheme.text, fontSize: 10)),
    );
  }

  Future<void> _toggleInvisibility(bool active) async {
    final uid = _dataUid;
    if (_savingVisibility || uid == null ||
        firebaseAuth.currentUser?.uid != uid) return;
    setState(() => _savingVisibility = true);
    try {
      await InvisibilityToggleService().setActive(active);
      if (!mounted || firebaseAuth.currentUser?.uid != uid) return;
      setState(() {
        _data = {
          ..._data,
          'isUnVisible': active,
          'isUnvisible': active,
        };
      });
    } catch (_) {
      if (mounted && firebaseAuth.currentUser?.uid == uid) {
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось сохранить статус. Проверьте подключение.'));
      }
    } finally {
      if (mounted) setState(() => _savingVisibility = false);
    }
  }

  Widget _tile(IconData icon, String title, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClrsPanel(
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            dense: true,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            leading: Icon(icon, color: LrsTheme.peachLight),
            title: Text(context.tr(title),
                style: TextStyle(color: LrsTheme.text)),
            trailing: Icon(Icons.chevron_right, color: LrsTheme.muted),
            onTap: onTap,
          ),
        ),
      ),
    );
  }

  Future<void> _requestRole(String role) async {
    if (!_sendingRoles.add(role)) return;
    final uid = firebaseAuth.currentUser?.uid;
    try {
      final confirmed = role == 'author'
          ? await showAuthorRequestSheet(context, _social) == true
          : await (_roleWrites.putIfAbsent(role,
              () => PendingWrite(() => _social.requestRole(role)))).wait();
      if (!mounted || firebaseAuth.currentUser?.uid != uid) return;
      if (!confirmed) {
        if (role != 'author') {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context.tr(
                'Подтверждение ещё не получено. Проверьте результат без повторной отправки.')),
            action: SnackBarAction(label: context.tr('Проверить отправку'),
                onPressed: () => _requestRole(role)),
          ));
        }
        return;
      }
      _roleWrites.remove(role);
      setState(() => _requestedRoles.add(role));
      showSnackbar(
        context,
        LrsTheme.surface,
        context.tr(role == 'author'
            ? 'Заявка автора отправлена администраторам'
            : 'Заявка модератора отправлена администраторам'),
      );
    } catch (e) {
      _roleWrites.remove(role);
      if (mounted) {
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось отправить заявку. Попробуйте ещё раз.'));
      }
    } finally {
      _sendingRoles.remove(role);
    }
  }

  Future<void> _supportProject() async {
    final uri = Uri.parse(
      'https://qr.nspk.ru/BS2A002KUIKV3G1Q8JGRDS9N32P84DCB?type=01&bank=100000000008&crc=5D81',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _confirmLogout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: LrsTheme.surface,
        title: Text(context.tr('Выйти')),
        content: Text(context.tr('Вы уверены, что хотите выйти?')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('Нет'))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.tr('Да'))),
        ],
      ),
    );
    if (yes != true) return;
    // Presence is best effort; a disconnected backend must not prevent sign-out.
    final uid = firebaseAuth.currentUser?.uid;
    if (uid != null) {
      try {
        await firebaseFirestore.collection('users').doc(uid).update({
          'online': false,
          'lastOnlineTS': DateTime.now(),
        }).timeout(const Duration(seconds: 3));
      } catch (_) {/* Auth sign-out remains available offline. */}
    }
    try {
      await _auth.signOut();
    } catch (_) {
      if (mounted)
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось выйти. Попробуйте ещё раз.'));
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginPage()),
      (_) => false,
    );
  }

  Future<void> _goToProfile() async {
    selectedIndex = 4;
    final current = firebaseAuth.currentUser;
    if (current == null) return;
    final doc =
        await firebaseFirestore.collection('users').doc(current.uid).get();
    if (!mounted || !doc.exists || firebaseAuth.currentUser?.uid != current.uid)
      return;
    final data = doc.data()!;
    nextScreenReplace(
      context,
      ProfilePage(
        group: data['группа']?.toString() ?? '',
        email: current.email ?? data['email']?.toString() ?? '',
        userName: current.displayName ?? data['fullName']?.toString() ?? '',
        about: data['about']?.toString() ?? '',
        age: data['age']?.toString() ?? '',
        rost: data['rost']?.toString() ?? '',
        hobbi: data['hobbi']?.toString() ?? '',
        city: (data['region'] ?? data['city'] ?? '').toString(),
        deti: data['deti'] == true,
        pol: data['pol']?.toString() ?? '',
      ),
    );
  }
}
