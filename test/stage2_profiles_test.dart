import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/core/utils/account_destination.dart';
import 'package:wbrs/presentation/screens/edit_profile/profile_edit_page.dart';
import 'package:wbrs/presentation/screens/friends/friends_page.dart';
import 'package:wbrs/presentation/screens/list_of_visiters/visiters.dart';
import 'package:wbrs/presentation/screens/list_of_users/profiles_list.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/presentation/screens/profile/profile_page.dart';
import 'package:wbrs/service/profile_delete_service.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/session_service.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/group_badge.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/profile_composition.dart';
import 'support/layout_firebase_fakes.dart';

class _ProfileUser extends LayoutUser {
  int reauths = 0, deletes = 0, metadataUpdates = 0;
  int passwordChanges = 0;
  Completer<void>? passwordGate;
  Object? reauthError, deleteError, metadataError;
  Future<void> Function()? afterReauth;
  @override
  String get email => 'qa@example.invalid';
  @override
  Future<UserCredential> reauthenticateWithCredential(
      AuthCredential credential) async {
    reauths++;
    if (reauthError != null) throw reauthError!;
    await afterReauth?.call();
    return _Credential();
  }

  @override
  Future<void> delete() async {
    deletes++;
    if (deleteError != null) throw deleteError!;
  }

  @override
  Future<void> updateDisplayName(String? displayName) async {
    metadataUpdates++;
    if (metadataError != null) throw metadataError!;
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    passwordChanges++;
    await passwordGate?.future;
  }
}

class _Credential extends Fake implements UserCredential {}

class _OtherProfileUser extends LayoutUser {
  @override
  String get uid => 'other';
}

class _NoStorage extends Fake implements FirebaseStorage {}

class _PeopleDatabase extends LayoutFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      path == 'users' ? _PeopleQuery(this, path) : super.collection(path);
}

// Test-only SDK interface double; production never substitutes Firestore.
// ignore: subtype_of_sealed_class
class _PeopleQuery extends LayoutCollection {
  _PeopleQuery(super.db, super.path);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #where) return this;
    return super.noSuchMethod(invocation);
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get(
          [GetOptions? options]) async =>
      LayoutQuerySnapshot([
        for (final entry in db.documents.entries.where(
            (e) => e.key.startsWith('users/') && e.key.split('/').length == 2))
          LayoutSnapshot(db, entry.key, entry.value),
      ]);
}

class _Friends extends Fake implements SocialService {
  final friendsStream =
      StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
  final requestsStream =
      StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
  final sentStream =
      StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
  final db = LayoutFirestore();
  Completer<void>? operation;
  Object? failure;
  int accepts = 0, cancellations = 0, friendsSubscriptions = 0;
  bool current = true;
  @override
  bool get isCurrentSession => current;
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> friends() {
    friendsSubscriptions++;
    return _friendEvents();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _friendEvents() async* {
    yield LayoutQuerySnapshot([]);
    yield* friendsStream.stream;
  }

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> friendRequests() async* {
    yield LayoutQuerySnapshot([
      LayoutSnapshot(db, 'requests/other', {
        'fromUid': 'other',
        'fromName': 'Очень длинное имя другого пользователя',
        'fromPhoto': ''
      })
    ]);
    yield* requestsStream.stream;
  }

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> sentFriendRequests() async* {
    yield LayoutQuerySnapshot([]);
    yield* sentStream.stream;
  }

  @override
  Future<void> cancelFriendRequest(String uid) async {
    cancellations++;
  }

  @override
  Future<void> acceptFriendRequest(String uid) async {
    accepts++;
    await operation?.future;
    if (failure != null) throw failure!;
  }

  void request() => requestsStream.add(LayoutQuerySnapshot([
        LayoutSnapshot(db, 'requests/other', {
          'fromUid': 'other',
          'fromName': 'Очень длинное имя другого пользователя',
          'fromPhoto': '',
        })
      ]));
  Future<void> close() async {
    await friendsStream.close();
    await requestsStream.close();
    await sentStream.close();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  late LayoutFirestore db;
  late LayoutAuth auth;
  late _ProfileUser user;
  late Map<String, dynamic> profile;
  setUp(() async {
    db = LayoutFirestore();
    auth = LayoutAuth();
    user = _ProfileUser();
    auth.user = user;
    firebaseFirestore = db;
    firebaseAuth = auth;
    firebaseMessaging = LayoutMessaging();
    final country = GeoCatalog.byCode(await GeoCatalog.load(), 'RU')!;
    profile = {
      'status': 'active',
      'fullName': 'Тестовый пользователь с длинным именем',
      'age': 35,
      'rost': '175',
      'about': List.filled(12, 'Описание').join(' '),
      'hobbi': List.filled(8, 'Интересы').join(' '),
      'deti': false,
      'pol': 'мужской',
      'countryCode': 'RU',
      'country': country.name,
      'region': country.regions.first,
      'profilePic': '',
      'группа': 'красная',
      'presentedGifts': {'assets/logo.png': 7},
      'online': true,
      'isUnVisible': false
    };
    db.documents['users/viewer'] = profile;
  });
  tearDown(() async {
    await db.close();
  });

  Future<void> page(WidgetTester tester, Widget screen,
      {Size size = const Size(390, 844), double scale = 1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: screen));
    await tester.pump();
  }

  ProfilePageEdit edit() => ProfilePageEdit(
      email: user.email,
      userName: profile['fullName'],
      about: profile['about'],
      age: '35',
      deti: false,
      rost: '175',
      city: profile['region'],
      hobbi: profile['hobbi']);

  test('wrong password leaves profile, photos and Auth intact', () async {
    user.reauthError = FirebaseAuthException(code: 'wrong-password');
    await expectLater(
        ProfileDeleteService(auth: auth, firestore: db).delete('incorrect'),
        throwsA(isA<FirebaseAuthException>()));
    expect(db.updates, 0);
    expect(profile['status'], 'active');
    expect(user.deletes, 0);
  });
  test('Auth deletion failure retains tombstone, never onboarding', () async {
    user.deleteError = FirebaseAuthException(code: 'network-request-failed');
    await expectLater(
        ProfileDeleteService(auth: auth, firestore: db).delete('correct'),
        throwsA(isA<ProfileDeletionIncomplete>()));
    expect(profile['status'], 'deleted');
    expect(user.reauths, 1);
    expect(user.deletes, 1);
    expect(profile['about'], isNotEmpty);
    expect(accountDestination(profile), AccountDestination.deleted);
  });
  test('denied tombstone prevents Auth deletion', () async {
    db.updateHandler = (_, __) async => throw StateError('permission denied');
    await expectLater(
        ProfileDeleteService(auth: auth, firestore: db).delete('correct'),
        throwsStateError);
    expect(profile['status'], 'active');
    expect(user.deletes, 0);
  });
  test('session switch after reauth cannot delete either account', () async {
    user.afterReauth = () async {
      auth.user = null;
    };
    await expectLater(
        ProfileDeleteService(auth: auth, firestore: db).delete('correct'),
        throwsStateError);
    expect(db.updates, 0);
    expect(user.deletes, 0);
  });
  test('successful deletion awaits reauth, tombstone and Auth', () async {
    await ProfileDeleteService(auth: auth, firestore: db).delete('correct');
    expect(user.reauths, 1);
    expect(profile['status'], 'deleted');
    expect(user.deletes, 1);
  });

  testWidgets('profile portrait reserves room for the main photo',
      (tester) async {
    await page(
        tester,
        Scaffold(
            body: ListView(children: const [
          ProfilePortrait(
              photo: '',
              name: 'Алексей',
              group: '',
              location: '',
              online: true),
        ])),
        size: const Size(360, 640));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ProfilePortrait)).height,
        greaterThan(300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile hero keeps the bottom of a tall main photo',
      (tester) async {
    await page(
        tester,
        Scaffold(
            body: ListView(children: const [
          ProfilePortrait(
              photo: 'https://example.invalid/portrait.jpg',
              name: 'Алексей',
              group: '',
              location: '',
              online: true),
        ])),
        size: const Size(360, 640));
    final image = tester.widget<CachedNetworkImage>(
        find.descendant(
            of: find.byType(ProfilePortrait),
            matching: find.byType(CachedNetworkImage)));
    final hero = tester.getSize(find.byType(ProfilePortrait));
    final fitted = applyBoxFit(image.fit!, const Size(640, 1120), hero);
    expect(fitted.source.height, 1120,
        reason: 'The portrait must not crop the lower part of the source');
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('live profile composition wraps long text at $size /2x',
        (tester) async {
      await page(
          tester,
          Scaffold(
              body: ListView(padding: const EdgeInsets.all(14), children: [
            ProfilePortrait(
                photo: '',
                name: List.filled(6, 'Длинное имя').join(' '),
                group: 'красно-коричневая',
                location:
                    List.filled(6, 'Очень длинная страна и регион').join(' '),
                online: true,
                status: 'Свободен'),
            ProfileSection(
                title: 'Обо мне',
                child: ProfileFacts(data: profile, showInterests: false)),
          ])),
          size: size,
          scale: 2);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(profile['hobbi']), findsNothing);
    });
  }

  testWidgets(
      'photo snapshot survives progress, pending retry and error status',
      (tester) async {
    await page(
        tester,
        ProfilePage(
            email: user.email,
            userName: profile['fullName'],
            about: profile['about'],
            age: '35',
            pol: 'мужской',
            group: 'красная',
            deti: false,
            rost: '175',
            city: profile['region'],
            hobbi: profile['hobbi']),
        size: const Size(390, 1200));
    await tester.pump();
    db.emit('users/viewer/images', [
      {'url': 'https://example.invalid/one.jpg', 'thumbnailUrl': ''}
    ]);
    await tester.pump();
    void expectPhotos() {
      expect(find.byType(ProfilePhotoStrip), findsOneWidget);
      expect(
          tester.widget<ProfilePhotoStrip>(find.byType(ProfilePhotoStrip)).urls,
          ['https://example.invalid/one.jpg']);
      expect(db.subscriptions['users/viewer/images'], 1,
          reason: 'status UI must not recreate the broadcast subscription');
    }

    expectPhotos();
    var gate = Completer<void>();
    db.updateHandler = (_, __) => gate.future;
    Future<void> chooseStatus() async {
      await tester.tap(find.text('Изменить статус'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Свободен').last);
      await tester.pump();
    }

    await chooseStatus();
    expectPhotos();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('Проверить результат'), findsOneWidget);
    expectPhotos();
    await tester.tap(find.text('Проверить результат'));
    await tester.pump();
    expectPhotos();
    gate.complete();
    await tester.pump();
    expectPhotos();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    gate = Completer<void>();
    await chooseStatus();
    gate.completeError(StateError('offline'));
    await tester.pump();
    expect(find.text('Не удалось сохранить изменения. Попробуйте ещё раз.'),
        findsOneWidget);
    expectPhotos();
    expect(tester.takeException(), isNull);
  });

  testWidgets('own profile reads presentedGifts and offers real settings',
      (tester) async {
    await page(
        tester,
        ProfilePage(
            email: user.email,
            userName: profile['fullName'],
            about: profile['about'],
            age: '35',
            pol: 'мужской',
            group: 'красная',
            deti: false,
            rost: '175',
            city: profile['region'],
            hobbi: profile['hobbi']),
        size: const Size(320, 640),
        scale: 2);
    await tester.pump();
    db.emit('users/viewer/images', []);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('Главное фото:'),
        220, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Главное фото:'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Подарки'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('7'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Интересы и увлечения'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Интересы и увлечения'), findsOneWidget);
    await page(tester, const ProfileSettingsPage(),
        size: const Size(320, 640), scale: 2);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Помощь'), 220,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Помощь'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('bottom edit action remains compact at ${width}dp /2x',
        (tester) async {
      await page(
          tester,
          ProfilePage(
              email: user.email,
              userName: profile['fullName'],
              about: profile['about'],
              age: '35',
              pol: 'мужской',
              group: 'красная',
              deti: false,
              rost: '175',
              city: profile['region'],
              hobbi: profile['hobbi']),
          size: Size(width, 640),
          scale: 2);
      db.emit('users/viewer/images', []);
      await tester.pumpAndSettle();
      final action = find.byKey(const ValueKey('profile-bottom-edit'));
      await tester.scrollUntilVisible(action, 250,
          scrollable: find.byType(Scrollable).first);
      expect(tester.getSize(action).width, lessThanOrEqualTo(260));
      expect(tester.widget<ElevatedButton>(action).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('own profile uses saved group and names every compatible group',
      (tester) async {
    profile['группа'] = 'сине-красная';
    await page(
        tester,
        ProfilePage(
            email: user.email,
            userName: profile['fullName'],
            about: profile['about'],
            age: '35',
            pol: 'мужской',
            group:
                'красная', // stale route argument must not override Firestore
            deti: false,
            rost: '175',
            city: profile['region'],
            hobbi: profile['hobbi']));
    await tester.pump();
    db.emit('users/viewer/images', []);
    await tester.pumpAndSettle();
    expect(find.text('Моя группа — сине-красная'), findsOneWidget);
    expect(find.byType(GroupCaption), findsWidgets);
    final nameText = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(ProfilePortrait), matching: find.byType(Text)))
        .firstWhere(
            (text) => text.textSpan?.toPlainText().contains('35') ?? false);
    final nameParts = (nameText.textSpan! as TextSpan).children!;
    expect((nameParts.last as TextSpan).text, ', 35');
    final portraitRing = tester.widget<GroupRing>(find.descendant(
        of: find.byType(ProfilePortrait), matching: find.byType(GroupRing)));
    expect(groupColors(portraitRing.group),
        [GroupBadge.colors['сине'], GroupBadge.colors['красная']]);
    expect(
        find.descendant(
            of: find.byType(ProfilePortrait),
            matching: find.byIcon(Icons.check_rounded)),
        findsNothing);
    await tester.scrollUntilVisible(find.text('Вам подходят'), 220,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('синяя'), findsOneWidget);
    expect(find.text('сине-коричневая'), findsOneWidget);
  });

  testWidgets('unfinished profile never inherits a route group',
      (tester) async {
    profile.remove('группа');
    await page(
        tester,
        ProfilePage(
            email: user.email,
            userName: profile['fullName'],
            about: profile['about'],
            age: '35',
            pol: 'мужской',
            group: 'красно-белая',
            deti: false,
            rost: '175',
            city: profile['region'],
            hobbi: profile['hobbi']));
    await tester.pump();
    db.emit('users/viewer/images', []);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-group-checks')), findsNothing);
    expect(find.textContaining('Моя группа'), findsNothing);
  });

  testWidgets('other profile uses its own female group and colored ring',
      (tester) async {
    db.documents['users/other'] = {
      ...profile,
      'uid': 'other',
      'fullName': 'Анна',
      'pol': 'женский',
      'группа': 'бело-коричневая'
    };
    await page(
        tester,
        SomebodyProfile(
            uid: 'other',
            photoUrl: '',
            name: 'Анна',
            userInfo: db.documents['users/other']!));
    await tester.pump();
    db.emit('users/other/images', []);
    await tester.pumpAndSettle();
    expect(find.text('Её группа — бело-коричневая'), findsOneWidget);
    final portraitRing = tester.widget<GroupRing>(find.descendant(
        of: find.byType(ProfilePortrait), matching: find.byType(GroupRing)));
    expect(groupColors(portraitRing.group),
        [GroupBadge.colors['бело'], GroupBadge.colors['коричневая']]);
    expect(
        find.descendant(
            of: find.byType(ProfilePortrait),
            matching: find.byIcon(Icons.check_rounded)),
        findsNothing);
  });

  testWidgets('pending password change checks one operation after navigation',
      (tester) async {
    user.passwordGate = Completer<void>();
    await page(tester, const ProfileSettingsPage());
    final passwordEntry = find.widgetWithText(ListTile, 'Сменить пароль');
    await tester.ensureVisible(passwordEntry);
    await tester.tap(passwordEntry);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'new-password');
    await tester.enterText(find.byType(TextFormField).last, 'new-password');
    final action = find.widgetWithText(ElevatedButton, 'Сменить пароль');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    final check = find.widgetWithText(ElevatedButton, 'Проверить результат');
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pump();
    expect(user.passwordChanges, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    user.passwordGate!.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings hide the previous account after login changes',
      (tester) async {
    SessionService.readyUserId.value = 'viewer';
    addTearDown(() => SessionService.readyUserId.value = null);
    await page(tester, const ProfileSettingsPage());
    expect(find.text('Сообщения'), findsOneWidget);
    auth.user = _OtherProfileUser();
    SessionService.readyUserId.value = 'other';
    await tester.pump();
    expect(find.text('Сообщения'), findsNothing);
    expect(find.text('Сеанс завершён. Войдите снова.'), findsOneWidget);
  });

  testWidgets(
      'profile edit captures changed height and persists only after Save',
      (tester) async {
    await page(tester, edit());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(2), '181');
    expect(profile['rost'], '175');
    await tester.scrollUntilVisible(find.text('Сохранить'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(db.documents['users/viewer']!['rost'], '181');
    expect(db.commits, 1);
    expect(user.metadataUpdates, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('profile metadata partial failure reports saved primary fields',
      (tester) async {
    user.metadataError = StateError('Auth unavailable');
    await page(tester, edit());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(2), '183');
    await tester.scrollUntilVisible(find.text('Сохранить'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(db.documents['users/viewer']!['rost'], '183');
    expect(
        find.text(
            'Профиль сохранён, но данные входа не обновились. Войдите снова.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('pending edit observes same commit and tolerates disposal',
      (tester) async {
    db.commitGate = Completer<void>();
    await page(tester, edit());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Сохранить'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.scrollUntilVisible(find.text('Проверить результат'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Проверить результат'));
    await tester.pump();
    expect(db.commits, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    db.commitGate!.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(db.commits, 1);
  });
  testWidgets('edit controls stay reachable at320/2x with keyboard',
      (tester) async {
    await page(tester, edit(), size: const Size(320, 640), scale: 2);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Удалить профиль'), 250,
        maxScrolls: 100, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Удалить профиль').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('friends stream error is not reported as an empty friend list',
      (tester) async {
    final social = _Friends();
    addTearDown(social.close);
    await page(tester, FriendsPage(social: social));
    social.friendsStream.addError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить список.'), findsOneWidget);
    expect(find.text('Список друзей пока пуст'), findsNothing);
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    expect(social.friendsSubscriptions, 2);
  });
  test('friend request is saved once and remains bound to the sender',
      () async {
    db.documents['users/other'] = {
      'fullName': 'Никнейм',
      'profilePicThumb': 'thumbnail',
      'status': 'active'
    };
    final social = SocialService(
        firestore: db,
        storage: _NoStorage(),
        currentUid: () => auth.currentUser?.uid);
    await social.sendFriendRequest('other');
    await social.sendFriendRequest('other');
    final sent = db.documents['users/viewer/friend_requests_sent/other']!;
    final received = db.documents['users/other/friend_requests/viewer']!;
    expect(sent['toName'], 'Никнейм');
    expect(sent['toPhoto'], 'thumbnail');
    expect(received['fromUid'], 'viewer');
    expect(
        db.documents.keys
            .where((path) =>
                path == 'users/other/notifications/friend-request-viewer')
            .length,
        1);
    auth.user = null;
    expect(() => social.sentFriendRequests(), throwsStateError);
  });
  testWidgets('friend acceptance double tap and pending check send once',
      (tester) async {
    final social = _Friends()..operation = Completer<void>();
    addTearDown(social.close);
    await page(tester, FriendsPage(social: social));
    social.friendsStream.add(LayoutQuerySnapshot([]));
    await tester.pump();
    await tester.tap(find.text('Входящие'));
    await tester.pump(const Duration(milliseconds: 500));
    social.request();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Принять'));
    await tester.tap(find.text('Принять'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.tap(find.text('Проверить результат'));
    await tester.pump();
    expect(social.accepts, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    social.operation!.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('friend acceptance failure remains actionable in compact layout',
      (tester) async {
    final social = _Friends()..failure = StateError('denied');
    addTearDown(social.close);
    await page(tester, FriendsPage(social: social),
        size: const Size(320, 640), scale: 2);
    social.friendsStream.add(LayoutQuerySnapshot([]));
    await tester.pump();
    await tester.tap(find.text('Входящие'));
    await tester.pump(const Duration(milliseconds: 500));
    social.request();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Принять'));
    await tester.tap(find.text('Принять'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось сохранить изменения. Попробуйте ещё раз.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('friends are sorted and searched by nickname', (tester) async {
    final social = _Friends();
    addTearDown(social.close);
    await page(tester, FriendsPage(social: social));
    social.friendsStream.add(LayoutQuerySnapshot([
      LayoutSnapshot(social.db, 'friends/z', {'uid': 'z', 'fullName': 'Анна', 'nickName': 'Ясная'}),
      LayoutSnapshot(social.db, 'friends/a', {'uid': 'a', 'fullName': 'Яна', 'nickName': 'Астра'}),
      LayoutSnapshot(social.db, 'friends/m', {'uid': 'm', 'fullName': 'Марта', 'nickName': '  '}),
    ]));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Астра')).dy,
        lessThan(tester.getTopLeft(find.text('Марта')).dy));
    expect(tester.getTopLeft(find.text('Марта')).dy,
        lessThan(tester.getTopLeft(find.text('Ясная')).dy));
    expect(find.text('Анна'), findsNothing);
    expect(find.text('Яна'), findsNothing);
    await tester.enterText(find.byType(TextField), 'яс');
    await tester.pumpAndSettle();
    expect(find.text('Ясная'), findsOneWidget);
    expect(find.text('Астра'), findsNothing);
    await tester.enterText(find.byType(TextField), 'март');
    await tester.pumpAndSettle();
    expect(find.text('Марта'), findsOneWidget);
    expect(find.text('Ясная'), findsNothing);
  });

  testWidgets('friend nickname request labels preserve legacy fallback', (tester) async {
    final social = _Friends();
    addTearDown(social.close);
    await page(tester, FriendsPage(social: social));
    await tester.tap(find.text('Входящие'));
    await tester.pumpAndSettle();
    social.requestsStream.add(LayoutQuerySnapshot([
      LayoutSnapshot(social.db, 'requests/other', {
        'fromUid': 'other', 'fromName': 'Имя', 'fromNickName': 'Ник заявки',
      }),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Ник заявки'), findsOneWidget);
    expect(find.text('Имя'), findsNothing);
    await tester.tap(find.text('Исходящие'));
    await tester.pumpAndSettle();
    social.sentStream.add(LayoutQuerySnapshot([
      LayoutSnapshot(social.db, 'sent/first', {
        'toUid': 'first', 'toName': 'Имя адресата', 'toNickName': 'Ник адресата',
      }),
      LayoutSnapshot(social.db, 'sent/legacy', {
        'toUid': 'legacy', 'toName': 'Старый никнейм',
      }),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Ник адресата'), findsOneWidget);
    expect(find.text('Старый никнейм'), findsOneWidget);
    expect(find.text('Имя адресата'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('outgoing friend request can be opened and withdrawn',
      (tester) async {
    final social = _Friends();
    addTearDown(social.close);
    await page(tester, FriendsPage(social: social),
        size: const Size(320, 640), scale: 2);
    await tester.tap(find.text('Исходящие'));
    await tester.pumpAndSettle();
    social.sentStream.add(LayoutQuerySnapshot([
      LayoutSnapshot(social.db, 'sent/other',
          {'toUid': 'other', 'toName': 'Никнейм', 'toPhoto': ''}),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Никнейм'), findsOneWidget);
    await tester.tap(find.text('Отозвать заявку'));
    await tester.pumpAndSettle();
    expect(social.cancellations, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('visitors handle invalid legacy age and failed stream distinctly',
      (tester) async {
    final stream =
        StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
    addTearDown(stream.close);
    await page(tester, MyVisitersPage(visiters: stream.stream),
        size: const Size(320, 640), scale: 2);
    stream.add(LayoutQuerySnapshot([
      LayoutSnapshot(db, 'visitors/a', {
        'uid': 'other',
        'fullName': List.filled(6, 'Имя').join(' '),
        'age': 'не указан'
      })
    ]));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    stream.addError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить список.'), findsOneWidget);
    expect(find.text('Пока на вашей странице не было гостей.'), findsNothing);
  });
  testWidgets(
      'visitor profile read completing after disposal does not navigate',
      (tester) async {
    final stream =
        StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
    addTearDown(stream.close);
    final read = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['users/other'] = read.future;
    await page(tester, MyVisitersPage(visiters: stream.stream));
    stream.add(LayoutQuerySnapshot([
      LayoutSnapshot(db, 'visitors/a', {'uid': 'other', 'fullName': 'Другой'})
    ]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Другой'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    read.complete(LayoutSnapshot(db, 'users/other', profile));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('people grid and filters share scrolling at320/2x',
      (tester) async {
    final people = _PeopleDatabase();
    addTearDown(people.close);
    people.documents['users/viewer'] = profile;
    people.documents['users/other'] = {
      ...profile,
      'uid': 'other',
      'fullName': 'Найденный человек',
      'country': 'Очень длинное название страны',
      'region': 'Очень длинное название региона'
    };
    people.documents['users/hidden'] = {
      ...profile,
      'uid': 'hidden',
      'fullName': 'Скрытый человек',
      'isUnvisible': true,
      'unvisibleEnd': DateTime.now().add(const Duration(days: 1)),
    };
    firebaseFirestore = people;
    await page(tester, const ProfilesList(group: 'красная', startPosition: 0),
        size: const Size(320, 640), scale: 2);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Найденный человек, 35'), 220,
        maxScrolls: 50, scrollable: find.byType(Scrollable).first);
    expect(find.text('Найденный человек, 35'), findsOneWidget);
    expect(find.text('Скрытый человек, 35'), findsNothing);
    await tester.scrollUntilVisible(find.byTooltip('Следующая страница'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'other profile hides private email and complaint makes no false success',
      (tester) async {
    db.documents['users/other'] = {
      ...profile,
      'uid': 'other',
      'fullName': 'Другой человек',
      'email': 'private@example.invalid'
    };
    await page(
        tester,
        SomebodyProfile(
            uid: 'other',
            photoUrl: '',
            name: 'Другой человек',
            userInfo: db.documents['users/other']!),
        size: const Size(320, 640),
        scale: 2);
    await tester.pump();
    db.emit('users/other/images', []);
    await tester.pumpAndSettle();
    expect(find.text('private@example.invalid'), findsNothing);
    await tester.tap(find.byTooltip('Пожаловаться'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Напишите в поддержку и укажите имя профиля и причину жалобы.'),
        findsOneWidget);
    expect(find.textContaining('рассматриваем заявку'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
