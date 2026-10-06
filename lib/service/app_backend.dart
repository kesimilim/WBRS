import 'package:shared_preferences/shared_preferences.dart';
import 'timeweb_android_secure_channel.dart';
import 'timeweb_app_runtime.dart';
import 'session_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:wbrs/firebase_options.dart';
import 'timeweb_auth_client.dart';
import 'timeweb_auth_lifecycle.dart';
import 'app_session.dart';

/// The sandbox flavor uses a demo project with no live Firebase resources.
/// A mismatched flavor/define stops startup before any account data is read.
class AppBackend {
  // Native selection is explicit and release-off. It never activates Firebase
  // destinations or implies completed native onboarding/Home services.
  static const backendMode = String.fromEnvironment(
    'CLRS_APP_BACKEND',
    defaultValue: 'firebase',
  );
  static const timewebAuthEnabled = bool.fromEnvironment(
    'CLRS_TIMEWEB_AUTH_ENABLED',
  );
  static const timewebProfileEditorEnabled = bool.fromEnvironment(
    'CLRS_TIMEWEB_PROFILE_EDITOR_ENABLED',
  );
  static const timewebTemperamentEnabled = bool.fromEnvironment(
    'CLRS_TIMEWEB_TEMPERAMENT_ENABLED',
  );
  static const timewebOwnProfileEnabled = bool.fromEnvironment(
    'CLRS_TIMEWEB_OWN_PROFILE_ENABLED',
  );
  static const timewebChatsEnabled = bool.fromEnvironment(
    'CLRS_TIMEWEB_CHATS_ENABLED',
  );
  static const timewebSourceSnapshot = String.fromEnvironment(
    'CLRS_TIMEWEB_SOURCE_SNAPSHOT',
  );
  static bool get usesTimeweb => backendMode == 'timeweb';
  static TimewebAppRuntime? _timewebRuntime;
  static Future<void>? _nativeStartup;
  static TimewebAppRuntime get timewebRuntime =>
      _timewebRuntime ?? (throw StateError('Native runtime is unavailable.'));

  static const emailLifecycleBackend = String.fromEnvironment(
    'CLRS_AUTH_LIFECYCLE_BACKEND',
    defaultValue: 'firebase',
  );
  static const timewebEmailLifecycleEnabled = bool.fromEnvironment(
    'CLRS_TIMEWEB_AUTH_LIFECYCLE_ENABLED',
  );
  static const timewebRegistrationEnabled = bool.fromEnvironment(
    'CLRS_TIMEWEB_REGISTRATION_ENABLED',
  );
  static const timewebApiOrigin = String.fromEnvironment(
    'CLRS_TIMEWEB_API_ORIGIN',
  );
  static bool get usesTimewebEmailLifecycle =>
      usesTimeweb || emailLifecycleBackend == 'timeweb';
  static AppSession? _emailLifecycleSession;

  /// Native startup must bind its real facade here after provider selection.
  /// Stop the old facade before replacing it. This creates no session, changes
  /// no backend default and provides no Firebase credential fallback.
  static void bindEmailLifecycleSession(AppSession session) {
    final old = _emailLifecycleSession;
    if (session.backend != AppSessionBackend.timeweb ||
        session.state.phase == AppSessionPhase.closed ||
        session.state.phase == AppSessionPhase.stopped ||
        (old != null &&
            !identical(old, session) &&
            old.state.phase != AppSessionPhase.closed &&
            old.state.phase != AppSessionPhase.stopped)) {
      throw StateError('A current native session owner is required.');
    }
    _emailLifecycleSession = session;
  }

  static TimewebAuthLifecycleClient createEmailLifecycleClient(
    TimewebLifecyclePurpose purpose,
  ) {
    if (!usesTimewebEmailLifecycle) {
      throw StateError('Native email lifecycle is not selected.');
    }
    final runtime = _timewebRuntime;
    if (usesTimeweb && runtime != null) {
      return runtime.createEmailLifecycleClient(purpose);
    }
    final session = _emailLifecycleSession;
    if (session == null ||
        session.state.phase == AppSessionPhase.closed ||
        session.state.phase == AppSessionPhase.stopped) {
      throw StateError('Native email lifecycle session is unavailable.');
    }
    final enabled =
        timewebEmailLifecycleEnabled &&
        (purpose != TimewebLifecyclePurpose.registerEmail ||
            timewebRegistrationEnabled);
    return TimewebAuthLifecycleClient(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse(timewebApiOrigin),
        enabled: enabled,
      ),
      enabled: enabled,
      session: session,
    );
  }

  static Future<void> _initializeNative() async {
    if (!timewebAuthEnabled ||
        useEmulators ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(timewebSourceSnapshot)) {
      throw StateError('Native runtime configuration is unavailable.');
    }
    final configuration = TimewebAuthConfiguration(
      endpoint: Uri.parse(timewebApiOrigin),
      enabled: true,
      runtimeWritesEnabled:
          timewebProfileEditorEnabled ||
          timewebChatsEnabled ||
          timewebOwnProfileEnabled ||
          timewebTemperamentEnabled,
      currentReadsEnabled: timewebChatsEnabled || timewebOwnProfileEnabled,
    );
    final store = createAndroidTimewebTokenStore();
    final preferences = await SharedPreferences.getInstance();
    final deviceId = await TimewebAppRuntime.loadDeviceId(preferences);
    final runtime = TimewebAppRuntime(
      configuration: configuration,
      secureStore: store,
      deviceId: deviceId,
      expectedSourceSnapshot: timewebSourceSnapshot,
      clearLocal: SessionService.clearLocal,
      emailLifecycleEnabled: timewebEmailLifecycleEnabled,
      registrationEnabled: timewebRegistrationEnabled,
      profileEditorEnabled: timewebProfileEditorEnabled,
      currentChatsEnabled: timewebChatsEnabled,
      currentOwnProfileEnabled: timewebOwnProfileEnabled,
      currentTemperamentEnabled: timewebTemperamentEnabled,
    );
    _timewebRuntime = runtime;
    bindEmailLifecycleSession(runtime.session);
    // A failed/unknown restore opens the native login/unavailable gate only.
    // It does not initialize or fall back to an existing Firebase account.
    await runtime.start(
      remember: preferences.getBool('timeweb_remember_me') ?? true,
    );
  }

  static const useEmulators = bool.fromEnvironment('CLRS_USE_EMULATORS');
  static const emulatorHost = String.fromEnvironment(
    'CLRS_EMULATOR_HOST',
    defaultValue: '10.0.2.2',
  );
  static const demoProjectId = 'demo-clrs-local';
  static bool _emulatorsConfigured = false;
  static bool _firestoreConfigured = false;
  static bool _firestorePrepared = false;

  static const demoOptions = FirebaseOptions(
    apiKey: 'demo-clrs-local-api-key',
    appId: '1:123456789000:android:0000000000000000000000',
    messagingSenderId: '123456789000',
    projectId: demoProjectId,
    storageBucket: 'demo-clrs-local.appspot.com',
  );

  static void validateConfiguration({
    required bool emulatorMode,
    required String projectId,
    required String host,
  }) {
    if (emulatorMode != projectId.startsWith('demo-')) {
      throw StateError(
        'Firebase build configuration does not match its backend.',
      );
    }
    if (emulatorMode &&
        (projectId != demoProjectId ||
            !const {'10.0.2.2', '127.0.0.1', 'localhost'}.contains(host))) {
      throw StateError('CLRS sandbox must use the local demo backend.');
    }
  }

  static Future<void> initialize() async {
    if (!const {'firebase', 'timeweb'}.contains(backendMode)) {
      throw StateError('Application backend is unavailable.');
    }
    if (usesTimeweb) {
      // No Firebase.initializeApp, Firestore, Messaging or FirebaseAuth access.
      await (_nativeStartup ??= _initializeNative());
      return;
    }
    final app = Firebase.apps.isEmpty
        ? await Firebase.initializeApp(
            options: useEmulators
                ? demoOptions
                : DefaultFirebaseOptions.currentPlatform,
          )
        : Firebase.app();
    validateConfiguration(
      emulatorMode: useEmulators,
      projectId: app.options.projectId,
      host: emulatorHost,
    );
    final firestore = FirebaseFirestore.instance;
    if (!_firestoreConfigured) {
      // Settings must be applied before the first Firestore operation. In
      // particular, clearPersistence initializes the native client; putting
      // the emulator host after it would send sandbox reads to Google.
      firestore.settings = const Settings(persistenceEnabled: false);
      if (useEmulators) {
        firestore.useFirestoreEmulator(emulatorHost, 8080);
      }
      // A later startup retry must not apply settings to an initialized client.
      _firestoreConfigured = true;
    }
    if (!_firestorePrepared) {
      // A previous installation may contain documents belonging to another
      // account. Clear those documents before opening any Firestore stream.
      try {
        await firestore.clearPersistence();
      } on FirebaseException catch (error) {
        // A still-running native client cannot clear its old disk cache. Disk
        // persistence is disabled above, so no old document is served to the
        // app; do not make a transient startup retry permanently unusable.
        if (error.code != 'failed-precondition') rethrow;
      }
      _firestorePrepared = true;
    }
    if (!useEmulators || _emulatorsConfigured) return;
    await FirebaseAuth.instance.useAuthEmulator(emulatorHost, 9099);
    await FirebaseStorage.instance.useStorageEmulator(emulatorHost, 9199);
    _emulatorsConfigured = true;
  }
}
