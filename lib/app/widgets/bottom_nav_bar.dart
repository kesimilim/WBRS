// ignore_for_file: use_build_context_synchronously, duplicate_ignore

import 'package:curved_navigation_bar/curved_navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/presentation/screens/home/home_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/presentation/screens/profile/profile_page.dart';
import 'package:wbrs/presentation/screens/list_of_users/profiles_list.dart';
import 'package:wbrs/app/widgets/splash.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/app/widgets/donate_button.dart';

import '../helper/global.dart';
import '../helper/helper_function.dart';

class MyBottomNavigationBar extends StatefulWidget {
  const MyBottomNavigationBar({super.key});

  @override
  State<MyBottomNavigationBar> createState() => _MyBottomNavigationBarState();
}

class _MyBottomNavigationBarState extends State<MyBottomNavigationBar> {
  @override
  void initState() {
    super.initState();
  }

  void _onItemTapped(int index) async {
    setState(() {
      selectedIndex = index;
    });

    switch (index) {
      case 0:
        bool isLoading = true;
        nextScreen(context, const SplashScreen());
        setState(() {
          isLoading = false;
        });

        if (isLoading == false) {
          var x = await getUserGroup();

          var doc = await firebaseFirestore
              .collection('users')
              .doc(firebaseAuth.currentUser!.uid)
              .get();

          nextScreen(
              context,
              ProfilePage(
                group: x,
                email: firebaseAuth.currentUser!.email.toString(),
                userName: firebaseAuth.currentUser!.displayName.toString(),
                about: doc.get('about'),
                age: doc.get('age').toString(),
                rost: doc.get('rost'),
                hobbi: doc.get('hobbi'),
                city: doc.get('city'),
                deti: doc.get('deti'),
                pol: doc.get('pol'),
              ));
        } else {
          nextScreen(context, const SplashScreen());
        }
        // ignore: use_build_context_synchronously

        break;
      case 1:
        nextScreen(context, const HomePage());
        break;
      case 2:
        bool isLoading = true;
        nextScreen(context, const SplashScreen());
        setState(() {
          isLoading = false;
        });

        if (isLoading) {
          nextScreen(context, const SplashScreen());
          // ignore: dead_code
        } else {
          var x = await getUserGroup();
          nextScreen(
              context,
              ProfilesList(
                startPosition: 0,
                group: x,
              ));
        }
        break;
      case 3:
        nextScreen(context, const MeetingPage());
        break;
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.08,
      child: Column(
        children: [
          CurvedNavigationBar(
            items: const [
              Icon(
                Icons.person,
                size: 30,
              ),
              Icon(
                Icons.message_outlined,
                size: 30,
              ),
              Icon(
                Icons.people,
                size: 30,
              ),
              Icon(
                Icons.access_alarm_sharp,
                size: 30,
              ),
            ],
            index: selectedIndex,
            backgroundColor: Colors.transparent,
            animationDuration: const Duration(milliseconds: 300),
            color: Colors.orangeAccent.shade400,
            buttonBackgroundColor: Colors.orangeAccent.shade100,
            onTap: _onItemTapped,
            height: MediaQuery.of(context).size.height * 0.05,
          ),
          DonateButton(
            child: Container(
              padding: EdgeInsets.zero,
              width: double.infinity,
              height: MediaQuery.of(context).size.height * 0.03,
              color: Colors.orangeAccent.shade400,
              child: const Text(
                'Поддержать ❤ проект ',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, letterSpacing: 0.3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
