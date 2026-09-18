// ignore_for_file: use_build_context_synchronously

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/app/widgets/robokassa_webview.dart';
import 'package:wbrs/service/database_service.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:random_string/random_string.dart';

import '../../../service/notifications.dart';

class Podarok {
  String img;
  String name;
  int price;

  Podarok({required this.name, required this.price, required this.img});
}

class ShopPage extends StatefulWidget {
  final int? tabIndex;
  const ShopPage({super.key, this.tabIndex});

  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> with TickerProviderStateMixin {
  TabController? _controller;

  ValueNotifier<bool> threeDs = ValueNotifier<bool>(false);
  ValueNotifier<bool> threeDsV2 = ValueNotifier<bool>(false);
  ValueNotifier<String?> status = ValueNotifier<String?>('');
  ValueNotifier<String?> cardType = ValueNotifier<String?>('');

  FirebaseFirestore db = firebaseFirestore;
  FirebaseAuth auth = firebaseAuth;

  bool isUnvisible = false;

  final List<Tab> topTabs = <Tab>[
    const Tab(text: 'Выбрать подарки'),
    const Tab(text: 'Выбранные подарки'),
  ];

  checkUnVisible() async {
    db.collection('users').doc(auth.currentUser!.uid).get().then((value) {
      isUnvisible = value.data()!['isUnVisible'];
    });
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    checkUnVisible();
    _controller = TabController(
        vsync: this, length: 2, initialIndex: widget.tabIndex ?? 0);
  }

  @override
  void dispose() {
    _controller!.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Image.asset(
          'assets/fon.jpg',
          height: MediaQuery.of(context).size.height,
          width: MediaQuery.of(context).size.width,
          fit: BoxFit.cover,
        ),
        Scaffold(
            backgroundColor: Colors.transparent,
            drawer: const MyDrawer(),
            bottomNavigationBar: const MyBottomNavigationBar(),
            body: NestedScrollView(
              headerSliverBuilder:
                  (BuildContext context, bool innerBoxIsScrolled) {
                return [
                  SliverAppBar(
                    forceElevated: innerBoxIsScrolled,
                    backgroundColor: Colors.black87,
                    pinned: true,
                    foregroundColor: Colors.white,
                    actions: [
                      StreamBuilder(
                          stream: db
                              .collection('users')
                              .doc(auth.currentUser!.uid)
                              .snapshots(),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return RichText(
                                  text: TextSpan(
                                      text: 'Ваш баланс: ',
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 16),
                                      children: [
                                    TextSpan(
                                        text: '0 Ag',
                                        style: const TextStyle(
                                            color: Colors.orange,
                                            fontWeight: FontWeight.bold))
                                  ]));
                            } else {
                              globalBalance = snapshot.data!['balance'];
                              return RichText(
                                  text: TextSpan(
                                      text: 'Ваш баланс: ',
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 16),
                                      children: [
                                    TextSpan(
                                        text: '$globalBalance Ag',
                                        style: const TextStyle(
                                            color: Colors.orange,
                                            fontWeight: FontWeight.bold))
                                  ]));
                            }
                          }),
                    ],
                    centerTitle: false,
                    bottom: TabBar(
                      unselectedLabelColor: Colors.white60,
                      indicatorColor: Colors.white,
                      indicatorSize: TabBarIndicatorSize.label,
                      labelColor: Colors.white,
                      controller: _controller,
                      tabs: topTabs,
                      isScrollable: true,
                    ),
                  )
                ];
              },
              body: StreamBuilder(
                  stream: db
                      .collection('users')
                      .doc(auth.currentUser!.uid)
                      .snapshots(),
                  builder: (context, snapshot) {
                    return TabBarView(controller: _controller, children: [
                      first(context),
                      second(snapshot.data, context)
                    ]);
                  }),
            )),
      ],
    );
  }

  kartochkaTovara(
      String name, String url, int price, bool sold, BuildContext context) {
    return Card(
      color: Colors.white54,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Column(
            children: [
              Image.asset(
                url,
                fit: BoxFit.cover,
              ),
              Text(name,
                  style: const TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
            ],
          ),
          sold
              ? Text('Количество: $price',
                  style: const TextStyle(fontSize: 16, color: Colors.white))
              : const SizedBox.shrink(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              !sold
                  ? Text('$price Ag',
                      style: const TextStyle(fontSize: 16, color: Colors.white))
                  : const SizedBox.shrink(),
              ElevatedButton(
                onPressed: () async {
                  DocumentReference coll =
                      db.collection('users').doc(auth.currentUser!.uid);
                  DocumentSnapshot data = await coll.get();
                  Map userInfo = data.data() as Map;
                  Map<String, dynamic> initGifts =
                      userInfo.containsKey('gifts') ? userInfo['gifts'] : {};

                  if (!sold) {
                    if (globalBalance < price) {
                      showSnackbar(
                          context, Colors.redAccent, 'Недостаточно серебра');
                      return;
                    }

                    setState(() {
                      globalBalance -= price;
                    });

                    coll.update({'balance': globalBalance});

                    if (initGifts.containsKey(url)) {
                      initGifts[url] += 1;
                    } else {
                      initGifts.addAll({url: 1});
                    }
                    coll.update({'gifts': initGifts});
                    showSnackbar(
                        context, Colors.green, 'Подарок $name добавлен');
                  } else {
                    var snap = await db
                        .collection('chats')
                        .orderBy('lastMessage')
                        .get();

                    var chats = [];
                    for (var chat in snap.docs) {
                      if (chat.data()['user1'] == auth.currentUser!.uid ||
                          chat.data()['user2'] == auth.currentUser!.uid) {
                        chats.add(chat);
                      }
                    }

                    Map<int, dynamic> chatRoomInfoMap = {};
                    int count = 0;
                    for (var chat in chats) {
                      if (chat.data()['user1'] == auth.currentUser!.uid) {
                        chatRoomInfoMap.addAll({
                          count: {
                            'chatId': chat.data()['chatId'],
                            'id': chat.data()['user2'],
                            'nickname': chat.data()['user2Nickname'],
                            'image': chat.data()['user2_image']
                          },
                        });
                        count++;
                      } else {
                        chatRoomInfoMap.addAll({
                          count: {
                            'chatId': chat.data()['chatId'],
                            'id': chat.data()['user1'],
                            'nickname': chat.data()['user1Nickname'],
                            'image': chat.data()['user1_image']
                          },
                        });
                        count++;
                      }
                    }

                    if (mounted) {
                      List<bool> isSelected =
                          List.filled(chatRoomInfoMap.length, false);
                      showModalBottomSheet(
                          backgroundColor: grey,
                          context: context,
                          builder: (context) {
                            return StatefulBuilder(
                                builder: (context, StateSetter setState) {
                              return Container(
                                  height: 170,
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        height: 100,
                                        child: GridView.builder(
                                            itemCount: chatRoomInfoMap.length,
                                            gridDelegate:
                                                const SliverGridDelegateWithFixedCrossAxisCount(
                                                    crossAxisCount: 4),
                                            itemBuilder: (context, index) {
                                              return GestureDetector(
                                                onTap: () {
                                                  setState(() {
                                                    isSelected[index] =
                                                        !isSelected[index];
                                                    for (int i = 0;
                                                        i < isSelected.length;
                                                        i++) {
                                                      if (i != index) {
                                                        isSelected[i] = false;
                                                      }
                                                    }
                                                  });
                                                },
                                                child: Container(
                                                  height: 120,
                                                  width: 120,
                                                  margin:
                                                      const EdgeInsets.all(5),
                                                  child: Column(
                                                    children: [
                                                      Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .all(2),
                                                        decoration: isSelected[
                                                                index]
                                                            ? BoxDecoration(
                                                                border:
                                                                    Border.all(
                                                                  color: Colors
                                                                      .blue,
                                                                  width: 2,
                                                                ),
                                                                borderRadius:
                                                                    const BorderRadius
                                                                        .all(
                                                                  Radius
                                                                      .circular(
                                                                          100),
                                                                ))
                                                            : null,
                                                        child: CircleAvatar(
                                                          radius: 27,
                                                          backgroundImage: chatRoomInfoMap[
                                                                          index]
                                                                      [
                                                                      'image'] ==
                                                                  ''
                                                              ? const NetworkImage(
                                                                  'https://cdn-icons-png.flaticon.com/512/149/149071.png',
                                                                )
                                                              : NetworkImage(
                                                                  chatRoomInfoMap[
                                                                          index]
                                                                      [
                                                                      'image']),
                                                        ),
                                                      ),
                                                      Text(
                                                        chatRoomInfoMap[index]
                                                            ['nickname'],
                                                        style: const TextStyle(
                                                            color:
                                                                Colors.white),
                                                        overflow:
                                                            TextOverflow.fade,
                                                        softWrap: false,
                                                      )
                                                    ],
                                                  ),
                                                ),
                                              );
                                            }),
                                      ),
                                      isSelected.contains(true)
                                          ? Center(
                                              child: ElevatedButton(
                                                  style:
                                                      ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        Colors.orangeAccent,
                                                    elevation: 10,
                                                    textStyle: const TextStyle(
                                                        color: Colors.blue,
                                                        fontSize: 18,
                                                        fontWeight:
                                                            FontWeight.w700),
                                                    minimumSize:
                                                        const Size(200, 50),
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 20,
                                                        vertical: 5),
                                                  ),
                                                  onPressed: () async {
                                                    int selectedNumber = 0;
                                                    for (int i = 0;
                                                        i < isSelected.length;
                                                        i++) {
                                                      if (isSelected[i]) {
                                                        selectedNumber = i;
                                                      }
                                                    }
                                                    QuerySnapshot querySnap =
                                                        await FirebaseFirestore
                                                            .instance
                                                            .collection('users')
                                                            .where('fullName',
                                                                isEqualTo: chatRoomInfoMap[
                                                                        selectedNumber]
                                                                    [
                                                                    'nickname'])
                                                            .get();

                                                    String chatId =
                                                        chatRoomInfoMap[
                                                                selectedNumber]
                                                            ['chatId'];
                                                    String chatWith = querySnap
                                                        .docs[0]['chatWithId'];
                                                    bool isUserInChat =
                                                        chatWith ==
                                                            auth.currentUser!
                                                                .uid;

                                                    Map<String, dynamic>
                                                        messageInfoMap = {
                                                      'image': url,
                                                      'name': name,
                                                      'sendBy': auth
                                                          .currentUser!
                                                          .displayName,
                                                      'sendByID': FirebaseAuth
                                                          .instance
                                                          .currentUser!
                                                          .uid,
                                                      'ts': DateTime.now(),
                                                      'isRead': isUserInChat
                                                          ? true
                                                          : false
                                                    };

                                                    DatabaseService()
                                                        .addMessage(
                                                            chatId,
                                                            randomAlphaNumeric(
                                                                12),
                                                            messageInfoMap);

                                                    messageInfoMap = {
                                                      'image': url,
                                                      'message':
                                                          '${auth.currentUser!.displayName} подарил вам подарок $name! ❤️',
                                                      'sendBy': auth
                                                          .currentUser!
                                                          .displayName,
                                                      'sendByID': FirebaseAuth
                                                          .instance
                                                          .currentUser!
                                                          .uid,
                                                      'ts': DateTime.now(),
                                                      'isRead': isUserInChat
                                                          ? true
                                                          : false
                                                    };
                                                    DatabaseService()
                                                        .addMessage(
                                                            chatId,
                                                            randomAlphaNumeric(
                                                                12),
                                                            messageInfoMap);

                                                    initGifts[url] -= 1;
                                                    if (initGifts[url] == 0) {
                                                      initGifts.remove(url);
                                                    }
                                                    coll.update(
                                                        {'gifts': initGifts});
                                                    var data = await db
                                                        .collection('users')
                                                        .doc(chatRoomInfoMap[
                                                                selectedNumber]
                                                            ['id'])
                                                        .get();

                                                    Map<String, dynamic>
                                                        presentedGifts =
                                                        data.data() as Map<
                                                            String, dynamic>;
                                                    if (presentedGifts
                                                        .containsKey(
                                                            'presentedGifts')) {
                                                      presentedGifts =
                                                          presentedGifts[
                                                              'presentedGifts'];
                                                    } else {
                                                      presentedGifts = {};
                                                    }
                                                    if (presentedGifts
                                                        .containsKey(url)) {
                                                      presentedGifts[url] += 1;
                                                    } else {
                                                      presentedGifts
                                                          .addAll({url: 1});
                                                    }
                                                    showSnackbar(
                                                        context,
                                                        Colors.green,
                                                        'Подарок $name подарен!');
                                                    Navigator.pop(context);
                                                    nextScreenReplace(
                                                        context,
                                                        ChatScreen(
                                                            chatWithUsername:
                                                                chatRoomInfoMap[selectedNumber]
                                                                    [
                                                                    'nickname'],
                                                            photoUrl:
                                                                chatRoomInfoMap[
                                                                        selectedNumber]
                                                                    ['image'],
                                                            id: auth
                                                                .currentUser!
                                                                .uid,
                                                            chatId: chatId));
                                                    db
                                                        .collection('users')
                                                        .doc(chatRoomInfoMap[
                                                                selectedNumber]
                                                            ['id'])
                                                        .update({
                                                      'presentedGifts':
                                                          presentedGifts
                                                    });
                                                    DocumentSnapshot doc =
                                                        await firebaseFirestore
                                                            .collection(
                                                                'TOKENS')
                                                            .doc(chatRoomInfoMap[
                                                                    selectedNumber]
                                                                ['id'])
                                                            .get();
                                                    Map notificationBody = {
                                                      'message':
                                                          '${auth.currentUser!.displayName} подарил вам подарок $name ❤️',
                                                    };
                                                    NotificationsService()
                                                        .sendPushMessage(
                                                            doc.get('token'),
                                                            notificationBody,
                                                            chatRoomInfoMap[
                                                                    selectedNumber]
                                                                ['nickname'],
                                                            1,
                                                            chatId);
                                                  },
                                                  child:
                                                      const Text('Подарить')),
                                            )
                                          : Container()
                                    ],
                                  ));
                            });
                          });
                    }
                  }
                },
                style: const ButtonStyle(
                    shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(10)),
                    )),
                    padding: WidgetStatePropertyAll(EdgeInsets.all(7)),
                    backgroundColor:
                        WidgetStatePropertyAll(Colors.orangeAccent)),
                child: sold
                    ? const Text(
                        'Подарить',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      )
                    : const Text(
                        'Забрать',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
              ),
              const SizedBox(
                height: 20,
              ),
            ],
          ),
        ],
      ),
    );
  }

  final podarki = <Podarok>[
    Podarok(name: 'Фольксваген Туарег', price: 12, img: 'assets/gifts/1.png'),
    Podarok(name: 'Кофе и круассан', price: 12, img: 'assets/gifts/2.png'),
    Podarok(name: 'Большой красивый дом', price: 12, img: 'assets/gifts/3.png'),
    Podarok(name: 'Тесла', price: 12, img: 'assets/gifts/4.png'),
    Podarok(name: 'Гелендваген', price: 12, img: 'assets/gifts/5.png'),
    Podarok(name: 'Вино, сыр, виноград', price: 12, img: 'assets/gifts/6.png'),
    Podarok(name: 'Модная киса в шляпе', price: 12, img: 'assets/gifts/7.png'),
    Podarok(name: 'Киса в банте', price: 12, img: 'assets/gifts/8.png'),
    Podarok(name: 'Ты милая, как зайка', price: 12, img: 'assets/gifts/9.png'),
    Podarok(name: 'Букет красные розы', price: 12, img: 'assets/gifts/10.png'),
    Podarok(name: 'Пойдем поедим', price: 12, img: 'assets/gifts/11.png'),
    Podarok(name: 'Маленький щенок', price: 12, img: 'assets/gifts/12.png'),
    Podarok(
        name: 'Киса упакована в коробку',
        price: 12,
        img: 'assets/gifts/13.png'),
    Podarok(name: 'Серый красивый дом', price: 12, img: 'assets/gifts/14.png'),
    Podarok(name: 'Мне б такую как ты', price: 12, img: 'assets/gifts/15.png'),
    Podarok(
        name: 'Ты - самая прекрасная', price: 12, img: 'assets/gifts/16.png'),
    Podarok(name: 'Букет розовые розы', price: 12, img: 'assets/gifts/17.png'),
    Podarok(
        name: 'Истосковался по такой как ты',
        price: 12,
        img: 'assets/gifts/18.png'),
    Podarok(name: 'Диадема с рубинами', price: 12, img: 'assets/gifts/19.png'),
    Podarok(name: 'Жду встречи', price: 12, img: 'assets/gifts/20.png'),
    Podarok(
        name: 'Береги себя, ты мне нужна!',
        price: 12,
        img: 'assets/gifts/21.png'),
    Podarok(name: 'Яхта олигарха', price: 12, img: 'assets/gifts/22.png'),
    Podarok(
        name: 'Водочка с селедочкой', price: 12, img: 'assets/gifts/23.png'),
    Podarok(name: 'Диадема в алмазах', price: 12, img: 'assets/gifts/24.png'),
    Podarok(name: 'Додж челленджер', price: 12, img: 'assets/gifts/25.png'),
    Podarok(
        name: 'Классический красивый дом',
        price: 12,
        img: 'assets/gifts/26.png'),
    Podarok(
        name: 'Семейный красивый дом', price: 12, img: 'assets/gifts/27.png'),
    Podarok(
        name: 'Современный красивый дом',
        price: 12,
        img: 'assets/gifts/28.png'),
    Podarok(
        name: 'Мое почтение женщине со вкусом',
        price: 12,
        img: 'assets/gifts/29.png'),
    Podarok(name: 'Для такой зайки', price: 12, img: 'assets/gifts/30.png'),
    Podarok(name: 'Инфинити', price: 12, img: 'assets/gifts/31.png'),
    Podarok(name: 'Самой искрометной', price: 12, img: 'assets/gifts/32.png'),
    Podarok(name: 'Кадиллак', price: 12, img: 'assets/gifts/33.png'),
    Podarok(name: 'Кофе корица', price: 12, img: 'assets/gifts/34.png'),
    Podarok(name: 'Кофе и круасан', price: 12, img: 'assets/gifts/35.png'),
    Podarok(name: 'Линкольн', price: 12, img: 'assets/gifts/36.png'),
    Podarok(
        name: 'Мадам, без вас убого', price: 12, img: 'assets/gifts/37.png'),
    Podarok(name: 'Милый мишка', price: 12, img: 'assets/gifts/38.png'),
    Podarok(name: 'Самой мудрой', price: 12, img: 'assets/gifts/39.png'),
    Podarok(name: 'Мужчине со вкусом', price: 12, img: 'assets/gifts/40.png'),
    Podarok(
        name: 'Настоящему джентельмену', price: 12, img: 'assets/gifts/41.png'),
    Podarok(
        name: 'Серьезному джентельмену', price: 12, img: 'assets/gifts/42.png'),
    Podarok(name: 'Настоящему ковбою', price: 12, img: 'assets/gifts/43.png'),
    Podarok(
        name: 'Настоящему полковнику', price: 12, img: 'assets/gifts/44.png'),
    Podarok(name: 'Настоящему рыцарю', price: 12, img: 'assets/gifts/45.png'),
    Podarok(name: 'Ниссан Скайлайн', price: 12, img: 'assets/gifts/46.png'),
    Podarok(name: 'Ты меня покорила', price: 12, img: 'assets/gifts/47.png'),
    Podarok(
        name: 'Претендуешь - соответствуй',
        price: 12,
        img: 'assets/gifts/48.png'),
    Podarok(
        name: 'Не разменивайся по пустякам',
        price: 12,
        img: 'assets/gifts/49.png'),
    Podarok(name: 'Букет белые розы', price: 12, img: 'assets/gifts/50.png'),
    Podarok(name: 'Букет белых роз', price: 12, img: 'assets/gifts/51.png'),
    Podarok(name: 'Букет черные розы', price: 12, img: 'assets/gifts/52.png'),
    Podarok(name: 'Роковой женщине', price: 12, img: 'assets/gifts/53.png'),
    Podarok(name: 'Самой мудрой', price: 12, img: 'assets/gifts/54.png'),
    Podarok(name: 'Самой опасной', price: 12, img: 'assets/gifts/55.png'),
    Podarok(
        name: 'Самой притягательной', price: 12, img: 'assets/gifts/56.png'),
    Podarok(name: 'Серьезному мужчине', price: 12, img: 'assets/gifts/57.png'),
    Podarok(name: 'Коньяк и сигары', price: 12, img: 'assets/gifts/58.png'),
    Podarok(name: 'Королю', price: 12, img: 'assets/gifts/59.png'),
    Podarok(name: 'Текила и лимончик', price: 12, img: 'assets/gifts/60.png'),
    Podarok(name: 'Форд Мустанг', price: 12, img: 'assets/gifts/61.png'),
    Podarok(name: 'Хаммер', price: 12, img: 'assets/gifts/62.png'),
    Podarok(name: 'Чаек с вареньем', price: 12, img: 'assets/gifts/63.png'),
    Podarok(
        name: 'Чудесного настроения', price: 12, img: 'assets/gifts/64.png'),
  ];

  first(context) {
    return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Возможности',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
            ElevatedButton(
              onPressed: () {
                showModalBottomSheet(
                    backgroundColor: Colors.transparent,
                    constraints: BoxConstraints(
                        minWidth: MediaQuery.of(context).size.width,
                        maxWidth: MediaQuery.of(context).size.width),
                    context: context,
                    builder: (context) {
                      return Container(
                        decoration: const BoxDecoration(
                            borderRadius: BorderRadius.only(
                                topLeft: Radius.circular(20),
                                topRight: Radius.circular(20)),
                            color: Colors.white54),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        width: MediaQuery.of(context).size.width,
                        height: MediaQuery.of(context).size.height * 0.5,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Выберите сумму для пополнения',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 18),
                            ),
                            const SizedBox(
                              height: 15,
                            ),
                            for (int i = 0; i < 6; i++) buyButton(i)
                          ],
                        ),
                      );
                    });
              },
              style: const ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(Colors.orangeAccent)),
              child: const Text(
                'Пополнить баланс (от 150 руб.)',
                style: TextStyle(color: Colors.white),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                if (!isUnvisible) {
                  showModalBottomSheet(
                      backgroundColor: Colors.transparent,
                      constraints: BoxConstraints(
                          minWidth: MediaQuery.of(context).size.width,
                          maxWidth: MediaQuery.of(context).size.width),
                      context: context,
                      builder: (context) {
                        return Container(
                          decoration: const BoxDecoration(
                              borderRadius: BorderRadius.only(
                                  topLeft: Radius.circular(20),
                                  topRight: Radius.circular(20)),
                              color: Colors.white54),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Выберите количество дней',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 18),
                              ),
                              const SizedBox(
                                height: 15,
                              ),
                              for (int i = 0; i < 4; i++) buyButtonInvisible(i)
                            ],
                          ),
                        );
                      }).then((value) => setState(() {}));
                } else {
                  showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: const Text('Режим невидимки'),
                          content: const Text(
                              'Вы уверены, что хотите выключить режим невидимки?'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Нет')),
                            TextButton(
                                onPressed: () {
                                  setState(() {
                                    isUnvisible = false;
                                  });
                                  Navigator.pop(context);
                                },
                                child: const Text('Да'))
                          ],
                        );
                      });
                }
              },
              style: ButtonStyle(
                  backgroundColor: isUnvisible
                      ? const WidgetStatePropertyAll(Colors.green)
                      : const WidgetStatePropertyAll(Colors.redAccent)),
              child: const Text(
                'Режим невидимки',
                style: TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(
              height: 15,
            ),
            const Text(
              'Подарки',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
            const SizedBox(
              height: 15,
            ),
            SizedBox(
              height: podarki.length * 130.0,
              width: double.infinity,
              child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    childAspectRatio: 0.8,
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: podarki.length,
                  physics: const NeverScrollableScrollPhysics(),
                  itemBuilder: (context, int index) {
                    return kartochkaTovara(
                        podarki[index].name,
                        podarki[index].img,
                        podarki[index].price,
                        false,
                        context);
                  }),
            ),
            const SizedBox(
              height: 15,
            ),
          ],
        ));
  }

  Widget buyButtonInvisible(index) {
    List prices = [
      '3 дня = ',
      '7 дней = ',
      '15 дней = ',
      '30 дней = ',
    ];
    List bonuses = [
      '',
      ' (экономим 17серебра)',
      ' (экономим 51серебра)',
      ' (экономим 112серебра) ',
    ];
    List<int> pricesInt = [
      24,
      39,
      69,
      128,
    ];
    List<int> days = [3, 7, 15, 30];
    List lineThrough = [
      0,
      56,
      120,
      240,
    ];
    return ElevatedButton(
      onPressed: () {
        if (globalBalance >= pricesInt[index]) {
          setState(() {
            globalBalance -= pricesInt[index];
            isUnvisible = true;
          });
          db.collection('users').doc(firebaseAuth.currentUser!.uid).update({
            'balance': globalBalance,
            'isUnvisible': isUnvisible,
            'unvisibleEnd': DateTime.now().add(Duration(days: days[index])),
          });
          Navigator.pop(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Недостаточно средств')),
          );
        }
      },
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(
            Size(MediaQuery.of(context).size.width - 40, 40)),
        foregroundColor: const WidgetStatePropertyAll(Colors.cyan),
        backgroundColor: WidgetStatePropertyAll(Colors.orangeAccent.shade400),
      ),
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width),
        child: index == 0
            ? const Row(
                children: [
                  Text(
                    '3 дня = 24Ag',
                    style: TextStyle(color: Colors.white),
                    textAlign: TextAlign.start,
                  ),
                ],
              )
            : Row(
                children: [
                  Text(
                    '${prices[index]}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  Text(
                    '${lineThrough[index]}Ag',
                    style: const TextStyle(
                        color: Colors.white,
                        decoration: TextDecoration.lineThrough,
                        decorationColor: Colors.white,
                        decorationThickness: 3),
                  ),
                  Text(
                    ' ${pricesInt[index]}Ag',
                    style: const TextStyle(
                        color: Colors.white,
                        decoration: TextDecoration.underline,
                        decorationColor: Colors.white),
                  ),
                  Text(
                    '${bonuses[index]}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
      ),
    );
  }

  Widget buyButton(index) {
    List prices = [
      '150 р = ',
      '299 р = ',
      '490 р = ',
      '990 р = ',
      '1490 р = ',
      '2880 р = ',
    ];
    List bonuses = [
      ' 36Ag+3Ag бонуса ',
      ' 76Ag+10Ag бонусов ',
      ' 120Ag+25Ag бонусов ',
      ' 240Ag+65Ag бонусов ',
      ' 360Ag+130Ag бонусов ',
      ' 720Ag+300Ag бонусов ',
    ];
    List pricesInt = [30, 60, 98, 198, 298, 576];
    return ElevatedButton(
      onPressed: () async {
        String sum = '';
        switch (index) {
          case 0:
            sum = '150';
            break;
          case 1:
            sum = '299';
            break;
          case 2:
            sum = '490';
            break;
          case 3:
            sum = '990';
            break;
          case 4:
            sum = '1490';
            break;
          case 5:
            sum = '2880';
            break;
        }
        int count = 0;
        await firebaseFirestore.collection('transaction').get().then((value) {
          setState(() {
            count = value.docs.length + 1;
          });
        });
        await firebaseFirestore
            .collection('transaction')
            .doc(count.toString())
            .set({
          'id': count.toString(),
          'sum': sum,
          'user_email': firebaseAuth.currentUser!.email,
          'user_id': firebaseAuth.currentUser!.uid,
          'time': DateTime.now().toString(),
        });
        if (context.mounted) {
          nextScreen(
              context,
              RobokassaWebview(
                sum: sum,
                count: count,
              ));
        }
      },
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(
            Size(MediaQuery.of(context).size.width - 40, 40)),
        foregroundColor: const WidgetStatePropertyAll(Colors.cyan),
        backgroundColor: WidgetStatePropertyAll(Colors.orangeAccent.shade400),
      ),
      child: Row(
        children: [
          Text(
            '${prices[index]}',
            style: const TextStyle(color: Colors.white),
          ),
          Text(
            '${pricesInt[index]}Ag',
            style: const TextStyle(
                color: Colors.white,
                decoration: TextDecoration.lineThrough,
                decorationColor: Colors.white,
                decorationThickness: 3),
          ),
          Text(
            '${bonuses[index]}',
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }

  second(data, context) {
    if (data != null) {
      Map initGifts = data.data()!['gifts'] ?? {};
      List urls = initGifts.keys.toList();
      List counts = initGifts.values.toList();
      var indexInPodarki = [];
      for (int i = 0; i < urls.length; i++) {
        indexInPodarki
            .add(podarki.indexWhere((element) => element.img == urls[i]));
      }

      return initGifts.isEmpty
          ? const Center(
              child: Text(
              'У вас нет подарков',
              style: TextStyle(color: Colors.white),
            ))
          : SafeArea(
              child: SizedBox(
              height: (MediaQuery.of(context).size.height * 1) - 100,
              width: double.infinity,
              child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    childAspectRatio: 0.7,
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: initGifts.length,
                  physics: const NeverScrollableScrollPhysics(),
                  itemBuilder: (context, int index) {
                    return kartochkaTovara(podarki[indexInPodarki[index]].name,
                        urls[index], counts[index]!, true, context);
                  }),
            ));
    } else {
      return const Center(
          child: Text(
        'У вас нет подарков',
        style: TextStyle(color: Colors.white),
      ));
    }
  }
}
