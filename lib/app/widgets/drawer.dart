import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/presentation/screens/about_app/about_app.dart';
import 'package:wbrs/app/pages/admin/panel.dart';
import 'package:wbrs/presentation/screens/home/home_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/presentation/screens/shop/shop.dart';
import 'package:wbrs/presentation/screens/list_of_visiters/visiters.dart';
import 'package:wbrs/app/widgets/splash.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/app/widgets/donate_button.dart';

import '../../presentation/screens/auth/login_screen/login_page.dart';
import '../../presentation/screens/profile/profile_page.dart';
import '../../presentation/screens/list_of_users/profiles_list.dart';
import '../../presentation/screens/test/red_group.dart';
import '../../service/auth_service.dart';

class MyDrawer extends StatefulWidget {
  const MyDrawer({super.key});

  @override
  State<MyDrawer> createState() => _MyDrawerState();
}

class _MyDrawerState extends State<MyDrawer> {
  String? userName;
  String? email;
  User? currentUser;

  FirebaseAuth auth = firebaseAuth;
  get uid => auth.currentUser!.uid;
  AuthService authService = AuthService();

  Stream? groups;
  String groupName = '';
  String? displayName;

  @override
  void initState() {
    super.initState();
    var currentUser = firebaseAuth.currentUser;

    if (currentUser != null) {
      displayName = currentUser.displayName;
    }

    firebaseFirestore
        .collection('users')
        .where('uid', isEqualTo: currentUser!.uid)
        .get()
        .then((QuerySnapshot snapshot) {
      setState(() {
        globalAge = snapshot.docs[0].get('age'.toString()).toString();
        globalAbout = snapshot.docs[0].get('about'.toString()).toString();
        globalCity = snapshot.docs[0]['city'].toString();
        globalHobbi = snapshot.docs[0]['hobbi'];
        globalRost = snapshot.docs[0]['rost'];
        globalDeti = snapshot.docs[0]['deti'];
        group = snapshot.docs[0]['группа'];
      });
    });

    currentUser = firebaseAuth.currentUser;
    if (currentUser != null) {
      userName = firebaseAuth.currentUser!.displayName.toString();
      email = firebaseAuth.currentUser!.email.toString();
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Image.asset(
          'assets/fon.jpg',
          height: double.infinity,
          width: 300,
          fit: BoxFit.cover,
        ),
        Drawer(
            backgroundColor: Colors.transparent,

            // child: ListView.builder(
            //   itemBuilder: (BuildContext context,int index){
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 50),
              children: <Widget>[
                GestureDetector(
                  onTap: () async {
                    goToProfile(context);
                  },
                  child: Column(
                    children: [
                      Column(
                        children: [
                          firebaseAuth.currentUser!.photoURL == '' ||
                                  firebaseAuth.currentUser!.photoURL == null
                              ? const Icon(
                                  Icons.account_circle,
                                  size: 150,
                                  color: Colors.white,
                                )
                              : userImageWithCircle(
                                  (firebaseAuth.currentUser!.photoURL == '' ||
                                          firebaseAuth.currentUser!.photoURL ==
                                              null)
                                      ? 'assets/profile.png'
                                      : FirebaseAuth
                                          .instance.currentUser!.photoURL
                                          .toString(),
                                  group,
                                  false),
                          const SizedBox(
                            height: 15,
                          ),
                          Text(
                            userName!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(
                  height: 30,
                ),
                const Divider(
                  height: 2,
                ),
                ListTile(
                  leading: const Icon(
                    Icons.question_answer,
                    color: Colors.grey,
                  ),
                  title: const Text(
                    'Пройти тест',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    //nextScreenReplace(context, const AboutUserWriting());
                    nextScreen(context, const FirstGroupRed());
                  },
                ),
                DonateButton(
                  child: Container(
                    width: double.infinity,
                    color: Colors.transparent,
                    child: const Text(
                      'Поддержать проект  ❤️🫴',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                ListTile(
                  onTap: () {
                    setState(() {
                      selectedIndex = 1;
                    });
                    nextScreenReplace(context, const HomePage());
                  },
                  selectedColor: Theme.of(context).primaryColor,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                  leading: const Icon(
                    Icons.messenger_rounded,
                    color: Colors.grey,
                  ),
                  title: const Text(
                    'Чаты',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                ListTile(
                  onTap: () {
                    var visiters = firebaseFirestore
                        .collection('users')
                        .doc(firebaseAuth.currentUser!.uid)
                        .collection('visiters')
                        .orderBy('lastVisitTs', descending: true)
                        .snapshots();
                    nextScreenReplace(
                        context,
                        MyVisitersPage(
                          visiters: visiters,
                        ));
                  },
                  title: const Text('Гости',
                      style: TextStyle(color: Colors.white)),
                  leading: const Icon(
                    Icons.transfer_within_a_station,
                    color: Colors.grey,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                ),
                ListTile(
                  onTap: () async {
                    bool isLoading = true;
                    setState(() {
                      selectedIndex = 2;
                    });
                    nextScreenReplace(context, const SplashScreen());

                    setState(() {
                      isLoading = false;
                    });
                    if (isLoading) {
                      nextScreenReplace(context, const SplashScreen());
                    } else {
                      var x = await getUserGroup();

                      if (context.mounted) {
                        nextScreenReplace(
                            context,
                            ProfilesList(
                              startPosition: 0,
                              group: x,
                            ));
                      }
                    }
                  },
                  leading: const Icon(
                    Icons.people,
                    color: Colors.grey,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                  title: const Text(
                    'Список пользователей',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                ListTile(
                  onTap: () {
                    nextScreenReplace(context, const ShopPage());
                  },
                  title: const Text('Дарить подарки',
                      style: TextStyle(color: Colors.white)),
                  leading: const Icon(
                    Icons.shopping_basket,
                    color: Colors.grey,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                ),
                ListTile(
                  onTap: () {
                    setState(() {
                      selectedIndex = 3;
                    });
                    nextScreenReplace(context, const MeetingPage());
                  },
                  title: const Text('Встречи',
                      style: TextStyle(color: Colors.white)),
                  leading: const Icon(
                    Icons.person_pin_circle,
                    color: Colors.grey,
                    size: 30,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                ),
                ListTile(
                  onTap: () {
                    nextScreenReplace(context, const About_App());
                  },
                  title: const Text('О приложении',
                      style: TextStyle(color: Colors.white)),
                  leading: const Icon(
                    Icons.info,
                    color: Colors.grey,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                ),
                const Divider(
                  color: Colors.grey,
                ),
                if ([
                  'T4zb6OLzDgMh0qrfp3eEahNKmNl1',
                  'lyNcv2xr33Ms6G9fI0bhBEcDKFj2',
                  'vLeB8v4b1pUL8h5dtxJSkifF2v72'
                ].contains(firebaseAuth.currentUser!.uid))
                  ListTile(
                    onTap: () => nextScreenReplace(context, const AdminPanel()),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                    leading: const Icon(
                      Icons.admin_panel_settings_outlined,
                      color: Colors.grey,
                    ),
                    title: const Text(
                      'Панель для админа',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ListTile(
                  onTap: () async {
                    showDialog(
                        barrierDismissible: false,
                        context: context,
                        builder: (context) {
                          return AlertDialog(
                            backgroundColor: darkGrey,
                            elevation: 0.0,
                            titleTextStyle:
                                const TextStyle(color: Colors.white),
                            contentTextStyle:
                                const TextStyle(color: Colors.white),
                            title: const Text('Выйти'),
                            content: const Text('Вы уверены что хотите выйти?'),
                            actions: [
                              TextButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                },
                                child: const Text(
                                  'Нет',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                              TextButton(
                                onPressed: () async {
                                  firebaseFirestore
                                      .collection('TOKENS')
                                      .doc(FirebaseAuth
                                          .instance.currentUser?.uid)
                                      .set({'token': ''});
                                  firebaseFirestore
                                      .collection('users')
                                      .doc(firebaseAuth.currentUser!.uid)
                                      .update({'online': false});
                                  await authService.signOut();
                                  if (context.mounted) {
                                    Navigator.of(context).pushAndRemoveUntil(
                                        MaterialPageRoute(
                                            builder: (context) =>
                                                const LoginPage()),
                                        (route) => false);
                                  }
                                },
                                child: const Text(
                                  'Да',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                            ],
                          );
                        });
                  },
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                  leading: const Icon(
                    Icons.exit_to_app,
                    color: Colors.grey,
                  ),
                  title: const Text(
                    'Выйти',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            )
            //   }
            // )
            ),
      ],
    );
  }

  goToProfile(context) async {
    setState(() {
      selectedIndex = 0;
    });
    var x = await getUserGroup();

    var doc = await firebaseFirestore
        .collection('users')
        .doc(firebaseAuth.currentUser!.uid)
        .get();

    nextScreenReplace(
        context,
        ProfilePage(
          group: x,
          email: firebaseAuth.currentUser!.email.toString(),
          userName: FirebaseAuth.instance.currentUser!.displayName.toString(),
          about: doc.get('about'),
          age: doc.get('age').toString(),
          rost: doc.get('rost'),
          hobbi: doc.get('hobbi'),
          city: doc.get('city'),
          deti: doc.get('deti'),
          pol: doc.get('pol'),
        ));
  }
}
