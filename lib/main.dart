import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sizer/sizer.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/firebase_options.dart';
import 'package:wbrs/presentation/screens/auth/session_gate.dart';
import 'package:wbrs/presentation/screens/auth/timeweb_session_gate.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/presentation/screens/list_of_meets/show/about_meet.dart';
import 'package:wbrs/presentation/screens/notifications_center/notification_destination_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/session_service.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/push_target.dart';
import 'package:wbrs/service/push_language_sync.dart';
import 'package:wbrs/service/timeweb_push_coordinator.dart';
import 'package:wbrs/service/timeweb_notification_delivery.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/presentation/screens/notifications_center/timeweb_notifications_page.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/locale_controller.dart';
import 'package:wbrs/core/utils/account_destination.dart';

final _navigatorKey = GlobalKey<NavigatorState>();
final _localNotifications = FlutterLocalNotificationsPlugin();
void Function(String)? _localTapHandler;
String? _initialLocalPayload;

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (AppBackend.useEmulators || AppBackend.usesTimeweb) return;
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Startup());
}

class _Startup extends StatefulWidget {
  const _Startup();
  @override
  State<_Startup> createState() => _StartupState();
}

class _StartupState extends State<_Startup> {
  late Future<void> _ready = _initializeForUi();
  Future<void> _initializeForUi() {
    final ready = _initialize();
    // A retry can fail before the next frame subscribes FutureBuilder. Keep
    // that failure handled immediately; FutureBuilder still displays it.
    ready.ignore();
    return ready;
  }

  Future<void> _initialize() async {
    if (!LocaleController.instance.initialized) {
      await LocaleController.instance.initialize();
    }
    await AppBackend.initialize().timeout(const Duration(seconds: 20));
    if (AppBackend.usesTimeweb) {
      FlutterError.onError = FlutterError.presentError;
      // Notification transport is optional. Never hold the login/Home screen
      // behind Google services or a platform notification plugin.
      return;
    }
    FlutterError.onError = AppBackend.useEmulators
        ? FlutterError.presentError
        : FirebaseCrashlytics.instance.recordFlutterFatalError;
    if (!AppBackend.useEmulators) {
      FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler);
    }
    try {
      await _localNotifications.initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
            iOS: DarwinInitializationSettings(),
          ), onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null) return;
        if (_localTapHandler != null) {
          _localTapHandler!(payload);
        } else {
          _initialLocalPayload = payload;
        }
      }).timeout(const Duration(seconds: 10));
      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
              'wbrs_silent', 'CLRS',
              importance: Importance.high, playSound: false));
      final launch =
          await _localNotifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true)
        _initialLocalPayload = launch?.notificationResponse?.payload;
    } catch (_) {
      debugPrint('CLRS: local notifications unavailable.');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: LocaleController.instance,
        builder: (context, _) => FutureBuilder<void>(
            future: _ready,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done &&
                  !snapshot.hasError) {
                return const MyApp();
              }
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: LrsTheme.theme,
                locale: LocaleController.instance.locale,
                supportedLocales: ClrsLocalizations.supportedLocales,
                localizationsDelegates: ClrsLocalizations.delegates,
                localeResolutionCallback: ClrsLocalizations.resolveLocale,
                home: Builder(
                    builder: (context) => ClrsScaffold(
                          body: SafeArea(
                              child: Center(
                                  child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const ClrsBrandHeader(centered: true),
                                  if (snapshot.hasError)
                                    ClrsPanel(
                                        child: Column(children: [
                                      Text(
                                          context.tr(
                                              'Не удалось запустить CLRS. Проверьте подключение и повторите попытку.'),
                                          textAlign: TextAlign.center),
                                      const SizedBox(height: 20),
                                      ElevatedButton(
                                          onPressed: () => setState(() {
                                                _ready = _initializeForUi();
                                              }),
                                          child: Text(context.tr('Повторить'))),
                                    ]))
                                  else
                                    const CircularProgressIndicator(),
                                ]),
                          ))),
                        )),
              );
            }),
      );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late final PushLanguageSync _pushLanguageSync;
  String? _translationUserId;
  TimewebPushCoordinator? _nativePush;
  TimewebNotificationDelivery? _nativeNotifications;
  bool _nativeLocalNotificationsReady = false;

  @override
  void initState() {
    super.initState();
    if (AppBackend.usesTimeweb) {
      WidgetsBinding.instance.addObserver(this);
      _nativeNotifications = TimewebNotificationDelivery(runtime: AppBackend.timewebRuntime,
        onForeground: _showNativeNotification, onTap: _openNativeNotification,
        onClear: () => unawaited(_localNotifications.cancelAll().catchError((Object _) {})))..start();
      _localTapHandler = (payload) => unawaited(_nativeNotifications!.receiveLocal(payload));
      final local = _initialLocalPayload;
      _initialLocalPayload = null;
      if (local != null) unawaited(_nativeNotifications!.receiveLocal(local));
      if (!AppBackend.useEmulators) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_initializeNativeNotifications());
        });
      }
      return;
    }
    _pushLanguageSync = PushLanguageSync(
      firestore: firebaseFirestore,
      currentUid: () => firebaseAuth.currentUser?.uid,
      readyUid: () => SessionService.readyUserId.value,
      isMounted: () => mounted,
    );
    _translationUserId = firebaseAuth.currentUser?.uid;
    WidgetsBinding.instance.addObserver(this);
    SessionService.readyUserId.addListener(_onSessionReady);
    LocaleController.instance.addListener(_syncPushLanguage);
    _syncPushLanguage();
    _localTapHandler = (payload) {
      final message = RemoteMessage(data: {'payload': payload});
      if (_profileReady) {
        _openMessage(message);
      } else {
        _pendingMessage = message;
      }
    };
    if (_initialLocalPayload != null) {
      _pendingMessage = RemoteMessage(data: {'payload': _initialLocalPayload!});
      _initialLocalPayload = null;
    }
    _subscriptions.add(
      firebaseAuth.authStateChanges().listen((user) {
        if (_translationUserId != user?.uid) {
          _translationUserId = user?.uid;
          _pushLanguageSync.invalidate();
          ContentTranslationService.instance.clear();
          _profileReady = false;
          _pendingMessage = null;
        }
        if (user != null) {
          if (!AppBackend.useEmulators) _refreshToken(user.uid);
        } else {
          _profileReady = false;
          _pendingMessage = null;
        }
      }),
    );
    if (!AppBackend.useEmulators) {
      _subscriptions.add(
        firebaseMessaging.onTokenRefresh.listen((token) async {
          final uid = firebaseAuth.currentUser?.uid;
          if (uid != null) await _saveToken(uid, token);
        }),
      );
      _subscriptions.add(FirebaseMessaging.onMessage.listen(_showMessage));
      _subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen(_openMessage),
      );
      firebaseMessaging.getInitialMessage().then((message) {
        // Keep the intended destination until profile loading has completed.
        if (message != null && mounted) {
          if (_profileReady) {
            _openMessage(message);
          } else {
            _pendingMessage = message;
          }
        }
      });
      firebaseMessaging.requestPermission();
    }
  }

  Future<void> _initializeNativeNotifications() async {
    try {
      await _localNotifications
          .initialize(
            const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              iOS: DarwinInitializationSettings(),
            ),
            onDidReceiveNotificationResponse: (response) {
              if (!mounted || response.payload == null) return;
              _localTapHandler?.call(response.payload!);
            },
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final launch = await _localNotifications
          .getNotificationAppLaunchDetails()
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (launch?.didNotificationLaunchApp == true &&
          launch?.notificationResponse?.payload != null) {
        unawaited(
          _nativeNotifications!.receiveLocal(
            launch!.notificationResponse!.payload!,
          ),
        );
      }
      final android = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              'wbrs',
              'CLRS',
              importance: Importance.high,
            ),
          )
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      await android
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              'wbrs_silent',
              'CLRS',
              importance: Importance.high,
              playSound: false,
            ),
          )
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      _nativeLocalNotificationsReady = true;
    } catch (_) {
      debugPrint('CLRS: local notification transport unavailable.');
    }
    if (!mounted) return;
    try {
      // FCM is only a notification courier. Login and data stay on Timeweb.
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        ).timeout(const Duration(seconds: 10));
      }
      if (!mounted) return;
      final messaging = FirebaseMessaging.instance;
      _nativePush = TimewebPushCoordinator(
        runtime: AppBackend.timewebRuntime,
        readToken: () =>
            messaging.getToken().timeout(const Duration(seconds: 10)),
        tokenRefreshes: messaging.onTokenRefresh,
      )..start();
      unawaited(
        messaging.requestPermission().then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ),
      );
      _subscriptions.add(
        FirebaseMessaging.onMessage.listen((message) {
          if (mounted) {
            unawaited(
              _nativeNotifications!.receive(message.data, opened: false),
            );
          }
        }),
      );
      _subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen((message) {
          if (mounted) {
            unawaited(
              _nativeNotifications!.receive(message.data, opened: true),
            );
          }
        }),
      );
      unawaited(
        messaging
            .getInitialMessage()
            .timeout(const Duration(seconds: 10))
            .then<void>((message) {
              if (message != null && mounted) {
                unawaited(
                  _nativeNotifications!.receive(message.data, opened: true),
                );
              }
            }, onError: (Object _, StackTrace __) {}),
      );
    } catch (_) {
      debugPrint('CLRS: native push transport unavailable.');
    }
  }

  Future<void> _showNativeNotification(TimewebNotification item, bool sound) async {
    if (!_nativeLocalNotificationsReady || !mounted) return;
    final runtime = AppBackend.timewebRuntime, lease = AppBackend.timewebRuntime.session.captureLease();
    item.requireCurrent(); lease.requireCurrent();
    final context = _navigatorKey.currentContext;
    if (!mounted || context == null) return;
    final id = int.parse(item.id.substring(2)) % 2147483647;
    final body = context.tr(item.targetKind == 'meeting' ? 'Встречи' : 'Сообщения');
    await _localNotifications.show(id, 'CLRS', body, NotificationDetails(
      android: AndroidNotificationDetails(sound ? 'wbrs' : 'wbrs_silent', 'CLRS',
        importance: Importance.high, priority: Priority.high, playSound: sound),
      iOS: DarwinNotificationDetails(presentSound: sound),
    ), payload: 'native-notification:${jsonEncode({'notificationId': item.id, 'recipientUid': lease.identity.uid})}');
    if (!mounted || !lease.isCurrent || !runtime.session.state.authenticated) {
      await _localNotifications.cancel(id);
    }
  }
  Future<void> _openNativeNotification(TimewebNotification item) async {
    final runtime = AppBackend.timewebRuntime, lease = AppBackend.timewebRuntime.session.captureLease();
    await WidgetsBinding.instance.endOfFrame;
    lease.requireCurrent(); item.requireCurrent();
    final context = _navigatorKey.currentContext;
    if (!mounted || context == null || !context.mounted) return;
    await openTimewebNotification(context, runtime, item, refresh: false);
  }

  RemoteMessage? _pendingMessage;
  bool _profileReady = false;

  void _onSessionReady() {
    _profileReady = SessionService.readyUserId.value != null &&
        SessionService.readyUserId.value == firebaseAuth.currentUser?.uid;
    _syncPushLanguage();
    if (!_profileReady) return;
    final state = WidgetsBinding.instance.lifecycleState;
    _updatePresence(state == null || state == AppLifecycleState.resumed);
    final message = _pendingMessage;
    _pendingMessage = null;
    if (message != null) _openMessage(message);
  }

  void _syncPushLanguage() {
    unawaited(
        _pushLanguageSync.sync(LocaleController.instance.locale.languageCode));
  }

  Future<void> _saveToken(String uid, String token) async {
    if (firebaseAuth.currentUser?.uid != uid) return;
    try {
      await firebaseFirestore.collection('TOKENS').doc(uid).set({
        'token': token,
      });
    } catch (error, stack) {
      FirebaseCrashlytics.instance.recordError(
        error,
        stack,
        reason: 'FCM token',
      );
    }
  }

  Future<void> _refreshToken(String uid) async {
    try {
      final token = await firebaseMessaging.getToken();
      if (token != null && firebaseAuth.currentUser?.uid == uid) {
        await _saveToken(uid, token);
      }
    } catch (error, stack) {
      FirebaseCrashlytics.instance.recordError(
        error,
        stack,
        reason: 'FCM registration',
      );
    }
  }

  Future<void> _showMessage(RemoteMessage message) async {
    final notification = message.notification;
    final uid = firebaseAuth.currentUser?.uid;
    if (uid == null || !_profileReady || notification == null) return;
    if (!await _pushTargetsCurrentAccount(message, uid,
            respectPreferences: true) ||
        firebaseAuth.currentUser?.uid != uid) return;
    final soundEnabled = message.data['soundEnabled'] != 'false';
    await _localNotifications.show(
      message.messageId.hashCode & 0x7fffffff,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          soundEnabled ? 'wbrs' : 'wbrs_silent',
          'CLRS',
          importance: Importance.max,
          priority: Priority.high,
          playSound: soundEnabled,
        ),
        iOS: DarwinNotificationDetails(presentSound: soundEnabled),
      ),
      payload: message.data['payload']?.toString(),
    );
  }

  Future<bool> _pushTargetsCurrentAccount(RemoteMessage message, String uid,
      {bool respectPreferences = false}) async {
    try {
      if (message.data['recipientUid'] != null &&
          message.data['recipientUid'] != uid) return false;
      final body = PushTarget.parse(message.data['payload']);
      if (body == null || !PushTarget.recipientMatches(body, uid)) return false;
      final profile = await firebaseFirestore
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
      if (firebaseAuth.currentUser?.uid != uid ||
          !profile.exists ||
          accountDestination(profile.data()) != AccountDestination.search) {
        return false;
      }
      final rawPreferences = profile.data()?['notificationPreferences'];
      final preferences = rawPreferences is Map<String, dynamic>
          ? rawPreferences
          : <String, dynamic>{};
      if (body['kind'] == 'social') {
        final id = PushTarget.socialNotificationId(body, uid);
        if (id == null) return false;
        final notice = await firebaseFirestore
            .collection('users')
            .doc(uid)
            .collection('notifications')
            .doc(id)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        return firebaseAuth.currentUser?.uid == uid &&
            notice.exists &&
            (!respectPreferences ||
                notice.data()?['type'] != 'meeting' ||
                preferences['meetings'] != false);
      }
      if (respectPreferences && body['kind'] == 'new_meeting' &&
          preferences['meetings'] == false) return false;
      if (respectPreferences && body['kind'] != 'new_meeting' &&
          preferences['messages'] == false) return false;
      if (body['isChat'] == true) {
        final id = body['chatId']?.toString() ?? '';
        if (id.isEmpty || id.contains('/')) return false;
        final chat = await firebaseFirestore
            .collection('chats')
            .doc(id)
            .get(const GetOptions(source: Source.server));
        return firebaseAuth.currentUser?.uid == uid &&
            chat.exists &&
            PushTarget.chatMatches(chat.data()!, uid);
      }
      final id = body['groupId']?.toString() ?? '';
      if (id.isEmpty || id.contains('/')) return false;
      final meet = await firebaseFirestore
          .collection('meets')
          .doc(id)
          .get(const GetOptions(source: Source.server));
      return firebaseAuth.currentUser?.uid == uid &&
          meet.exists &&
          PushTarget.meetingMatches(meet.data()!, profile.data()!, body, uid);
    } catch (_) {
      // A notification with an unverified target must not expose another
      // account's message on the lock screen.
      return false;
    }
  }

  Future<void> _openMessage(RemoteMessage message) async {
    if (!_profileReady) {
      _pendingMessage = message;
      return;
    }
    final uid = firebaseAuth.currentUser?.uid;
    if (uid == null) return;
    try {
      if (!await _pushTargetsCurrentAccount(message, uid)) return;
      final profile = await firebaseFirestore
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
      if (!profile.exists ||
          accountDestination(profile.data()) != AccountDestination.search ||
          firebaseAuth.currentUser?.uid != uid) return;
      final body = PushTarget.parse(message.data['payload']);
      if (body == null) return;
      Widget destination;
      if (body['kind'] == 'social') {
        final id = PushTarget.socialNotificationId(body, uid);
        if (id == null) return;
        final notice = await firebaseFirestore
            .collection('users')
            .doc(uid)
            .collection('notifications')
            .doc(id)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        if (!notice.exists || firebaseAuth.currentUser?.uid != uid) return;
        destination = NotificationDestinationPage(notification: notice.data()!);
      } else if (body['isChat'] == true) {
        final chatId = body['chatId']?.toString();
        if (chatId == null || chatId.contains('/')) return;
        final chat = await firebaseFirestore
            .collection('chats')
            .doc(chatId)
            .get(const GetOptions(source: Source.server));
        if (!chat.exists || !PushTarget.chatMatches(chat.data()!, uid)) return;
        final chatData = chat.data()!;
        final otherRaw =
            chatData['user1'] == uid ? chatData['user2'] : chatData['user1'];
        final otherId = otherRaw?.toString();
        if (otherId == null || otherId.isEmpty || otherId.contains('/')) return;
        final other = await firebaseFirestore
            .collection('users')
            .doc(otherId)
            .get(const GetOptions(source: Source.server));
        if (!other.exists) return;
        destination = ChatScreen(
          chatWithUsername: other.data()?['fullName']?.toString() ?? '',
          photoUrl: other.data()?['profilePic']?.toString() ?? '',
          id: otherId,
          chatId: chatId,
        );
      } else {
        final id = body['groupId']?.toString();
        if (id == null || id.contains('/')) return;
        final meet = await firebaseFirestore
            .collection('meets')
            .doc(id)
            .get(const GetOptions(source: Source.server));
        if (!meet.exists) return;
        if (!PushTarget.meetingMatches(
            meet.data()!, profile.data()!, body, uid)) return;
        final users = meet.data()?['users'] is List
            ? meet.data()!['users'] as List
            : const [];
        destination = AboutMeet(
          id: id,
          users: users,
          name: meet.data()?['name']?.toString() ?? '',
          is_user_join: users.contains(uid),
        );
      }
      if (!mounted || firebaseAuth.currentUser?.uid != uid) return;
      _navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => destination),
      );
    } catch (error, stack) {
      if (!AppBackend.useEmulators)
        FirebaseCrashlytics.instance.recordError(
          error,
          stack,
          reason: 'Notification navigation',
        );
    }
  }

  int _presenceRevision = 0;
  Future<void> _updatePresence(bool online) async {
    final revision = ++_presenceRevision;
    final uid = firebaseAuth.currentUser?.uid;
    if (uid == null) return;
    try {
      final ref = firebaseFirestore.collection('users').doc(uid);
      final profile = await ref.get().timeout(const Duration(seconds: 10));
      if (!profile.exists ||
          firebaseAuth.currentUser?.uid != uid ||
          revision != _presenceRevision) return;
      await ref.update({
        'online': online,
        if (!online) 'lastOnlineTS': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (AppBackend.usesTimeweb) {
      if (state == AppLifecycleState.resumed) { unawaited(_nativePush?.synchronize().catchError((Object _) {})); }
    } else {
      _updatePresence(state == AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    if (AppBackend.usesTimeweb) {
      _nativePush?.close();
      _nativeNotifications?.close();
      _localTapHandler = null; _initialLocalPayload = null;
      for (final subscription in _subscriptions) { unawaited(subscription.cancel()); }
      WidgetsBinding.instance.removeObserver(this);
      // Runtime teardown preserves remembered protected credentials.
      unawaited(AppBackend.timewebRuntime.stop());
      super.dispose();
      return;
    }
    _localTapHandler = null;
    SessionService.readyUserId.removeListener(_onSessionReady);
    LocaleController.instance.removeListener(_syncPushLanguage);
    _pushLanguageSync.dispose();
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: LocaleController.instance,
        builder: (context, _) => Sizer(
          builder: (context, orientation, deviceType) {
            return MaterialApp(
              navigatorKey: _navigatorKey,
              locale: LocaleController.instance.locale,
              supportedLocales: ClrsLocalizations.supportedLocales,
              localizationsDelegates: ClrsLocalizations.delegates,
              localeResolutionCallback: ClrsLocalizations.resolveLocale,
              theme: LrsTheme.theme.copyWith(
                textTheme: LrsTheme.theme.textTheme.apply(fontFamily: 'Lato'),
              ),
              debugShowCheckedModeBanner: false,
              home: AppBackend.usesTimeweb
                  ? TimewebSessionGate(runtime: AppBackend.timewebRuntime)
                  : const SessionGate(enforceRememberMe: true),
            );
          },
        ),
      );
}
