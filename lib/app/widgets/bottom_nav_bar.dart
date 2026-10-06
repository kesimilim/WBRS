import 'package:wbrs/localization/clrs_localizations.dart';
// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/presentation/screens/feed/feed_page.dart';
import 'package:wbrs/presentation/screens/home/home_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/presentation/screens/list_of_users/profiles_list.dart';
import 'package:wbrs/presentation/screens/profile/profile_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class MyBottomNavigationBar extends StatefulWidget {
  const MyBottomNavigationBar({super.key});

  @override
  State<MyBottomNavigationBar> createState() => _MyBottomNavigationBarState();
}

class _MyBottomNavigationBarState extends State<MyBottomNavigationBar> {
  bool _navigating = false;
  Future<void> _onItemTapped(int index) async {
    if (_navigating || index == selectedIndex) return;
    _navigating = true;
    final previous = selectedIndex;
    selectedIndex = index;
    try {
      switch (index) {
        case 0:
          if (mounted) nextScreenReplace(context, FeedPage());
          break;
        case 1:
          final userGroup = await getUserGroup().timeout(Duration(seconds: 15));
          if (!mounted) return;
          nextScreenReplace(
            context,
            ProfilesList(startPosition: 0, group: userGroup),
          );
          break;
        case 2:
          if (mounted) nextScreenReplace(context, HomePage());
          break;
        case 3:
          if (mounted) nextScreenReplace(context, MeetingPage());
          break;
        case 4:
          await _openProfile();
          break;
      }
    } catch (_) {
      selectedIndex = previous;
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Не удалось открыть раздел. Проверьте подключение.'),
            ),
          ),
        );
      }
    } finally {
      _navigating = false;
    }
  }

  Future<void> _openProfile() async {
    final current = firebaseAuth.currentUser;
    if (current == null) return;
    final doc = await firebaseFirestore
        .collection('users')
        .doc(current.uid)
        .get()
        .timeout(Duration(seconds: 15));
    if (!mounted) return;
    if (!doc.exists || firebaseAuth.currentUser?.uid != current.uid) {
      throw StateError('Профиль недоступен');
    }
    final data = doc.data() ?? <String, dynamic>{};
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

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Color(0xD92A1E12),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: Color(0x66E7B092), width: .8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BottomNavigationBar(
              currentIndex: selectedIndex.clamp(0, 4),
              onTap: _onItemTapped,
              backgroundColor: Colors.transparent,
              selectedItemColor: LrsTheme.peach,
              unselectedItemColor: LrsTheme.muted,
              type: BottomNavigationBarType.fixed,
              elevation: 0,
              selectedFontSize: 11,
              unselectedFontSize: 11,
              items: [
                BottomNavigationBarItem(
                  icon: Icon(Icons.home_outlined),
                  activeIcon: Icon(Icons.home),
                  label: context.tr('Лента'),
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.search),
                  activeIcon: Icon(Icons.search),
                  label: context.tr('Поиск'),
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.chat_bubble_outline),
                  activeIcon: Icon(Icons.chat_bubble),
                  label: context.tr('Чаты'),
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.event_outlined),
                  activeIcon: Icon(Icons.event),
                  label: context.tr('Встречи'),
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  activeIcon: Icon(Icons.person),
                  label: context.tr('Профиль'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
