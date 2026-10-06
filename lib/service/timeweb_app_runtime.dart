import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_session.dart';
import 'timeweb_auth_client.dart';
import 'timeweb_auth_lifecycle.dart';
import 'timeweb_profile_edit_flow.dart';
import 'timeweb_chat_flow.dart';
import 'timeweb_temperament_flow.dart';
import 'timeweb_geography_flow.dart';
import 'timeweb_personal_chat_flow.dart';
import 'timeweb_meeting_create_flow.dart';
import 'timeweb_meeting_join_flow.dart';
import 'timeweb_meeting_chat_flow.dart';
import 'timeweb_meeting_membership_flow.dart';
import 'timeweb_meeting_archive_flow.dart';
import 'timeweb_photo_upload_flow.dart';
import 'timeweb_initial_profile_flow.dart';

/// One native runtime owner. No Firebase identity, profile hydration or token
/// fallback. Replacing this owner requires awaiting stop, which keeps protected
/// remembered credentials; close on the underlying client remains destructive.
final class TimewebAppRuntime {
  TimewebAppRuntime({
    required TimewebAuthConfiguration configuration,
    required TimewebSecureTokenStore secureStore,
    required this.deviceId,
    required this.expectedSourceSnapshot,
    required Future<void> Function() clearLocal,
    http.Client? transport,
    DateTime Function()? clock,
    TimewebProfileEditJournal? profileEditJournal,
    TimewebTemperamentJournal? temperamentJournal,
    TimewebGeographyJournal? geographyJournal,
    TimewebChatJournal? chatJournal,
    TimewebPersonalChatJournal? personalChatJournal,
    TimewebMeetingCreateJournal? meetingCreateJournal,
    TimewebMeetingJoinJournal? meetingJoinJournal,
    TimewebMeetingChatJournal? meetingChatJournal,
    TimewebMeetingMembershipJournal? meetingMembershipJournal,
    TimewebPhotoUploadJournal? photoUploadJournal,
    TimewebInitialProfileJournal? initialProfileJournal,
    bool? profileEditorEnabled,
    this.currentChatsEnabled = false,
    this.currentOwnProfileEnabled = false,
    this.currentTemperamentEnabled = false,
    this.emailLifecycleEnabled = false,
    this.registrationEnabled = false,
    Duration waitTimeout = const Duration(seconds: 20),
  }) {
    if (!configuration.enabled ||
        !RegExp(r'^[A-Za-z0-9._:-]{1,191}$').hasMatch(deviceId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSourceSnapshot)) {
      throw ArgumentError('Native runtime configuration is unavailable.');
    }
    _rememberStore = _RememberingTokenStore(secureStore);
    _profileEditJournal = profileEditJournal ?? TimewebProfileEditJournal();
    _chatJournal = chatJournal ?? TimewebChatJournal();
    _personalChatJournal = personalChatJournal ?? TimewebPersonalChatJournal();
    _meetingCreateJournal = meetingCreateJournal ?? TimewebMeetingCreateJournal();
    _meetingJoinJournal = meetingJoinJournal ?? TimewebMeetingJoinJournal();
    _meetingChatJournal = meetingChatJournal ?? TimewebMeetingChatJournal();
    _meetingMembershipJournal = meetingMembershipJournal ?? TimewebMeetingMembershipJournal();
    _photoUploadJournal = photoUploadJournal ?? TimewebPhotoUploadJournal();
    _initialProfileJournal = initialProfileJournal ?? TimewebInitialProfileJournal();
    _temperamentJournal = temperamentJournal ?? TimewebTemperamentJournal();
    _geographyJournal = geographyJournal ?? TimewebGeographyJournal();
    _profileEditorEnabled =
        profileEditorEnabled ??
        (configuration.runtimeWritesEnabled &&
            !currentChatsEnabled &&
            !currentOwnProfileEnabled);
    client = TimewebAuthClient(
      configuration: configuration,
      secureStore: _rememberStore,
      transport: transport,
      clock: clock,
    );
    session = AppSession.timeweb(
      client: client,
      clearLocal: clearLocal,
      waitTimeout: waitTimeout,
    );
  }

  late final TimewebAuthClient client;
  late final _RememberingTokenStore _rememberStore;
  late final TimewebProfileEditJournal _profileEditJournal;
  late final TimewebChatJournal _chatJournal;
  late final TimewebPersonalChatJournal _personalChatJournal;
  late final TimewebMeetingCreateJournal _meetingCreateJournal;
  late final TimewebMeetingJoinJournal _meetingJoinJournal;
  late final TimewebMeetingChatJournal _meetingChatJournal;
  late final TimewebMeetingMembershipJournal _meetingMembershipJournal;
  late final TimewebPhotoUploadJournal _photoUploadJournal;
  late final TimewebInitialProfileJournal _initialProfileJournal;
  late final TimewebTemperamentJournal _temperamentJournal;
  late final TimewebGeographyJournal _geographyJournal;
  late final bool _profileEditorEnabled;
  final bool currentChatsEnabled,
      currentOwnProfileEnabled,
      currentTemperamentEnabled;
  final String deviceId, expectedSourceSnapshot;
  final bool emailLifecycleEnabled, registrationEnabled;
  late final AppSession session;
  Future<AppSessionResult>? _start;
  bool _policyUnsafe = false;
  int? _adminProbeEpoch;
  Future<bool>? _adminProbe;

  /// The install ID is routing metadata, never a password/token/account ID.
  static Future<String> loadDeviceId(SharedPreferences preferences) async {
    const key = 'timeweb_device_id';
    final old = preferences.getString(key);
    if (old != null) {
      if (!RegExp(r'^clrs-android-[a-f0-9]{32}$').hasMatch(old)) {
        throw StateError('Native device configuration is unavailable.');
      }
      return old;
    }
    final random = Random.secure();
    final id =
        'clrs-android-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    if (!await preferences.setString(key, id)) {
      throw StateError('Native device configuration is unavailable.');
    }
    return id;
  }

  /// Read OS-protected tokens once. Explicit remember=false clears locally at
  /// cold start, before any restore/read, without claiming remote logout.
  Future<AppSessionResult> start({required bool remember}) =>
      _start ??= (() async {
        await setRemember(remember);
        return session.restore();
      })();

  Future<void> setRemember(bool remember) async {
    if (_policyUnsafe) {
      throw StateError('Protected session storage is unavailable.');
    }
    try {
      await _rememberStore.setRemember(remember);
    } catch (_) {
      // An unconfirmed clear revokes the runtime too. This owner cannot be
      // reused for B or claim a safe remembered restart after that failure.
      _policyUnsafe = true;
      await stop();
      throw StateError('Protected session storage is unavailable.');
    }
  }

  Future<AppSessionResult> login({
    required String email,
    required String password,
  }) => session.login(email: email, password: password, deviceId: deviceId);

  Future<TimewebSessionProfile> readGateProfile() =>
      session.runAuthenticated((lease) async {
        final profile = await client.readFullOwnProfile(
          expectedSourceSnapshot: expectedSourceSnapshot,
        );
        lease.requireCurrent();
        profile.requireCurrent();
        return TimewebSessionProfile._(lease, profile);
      });

  bool get profileEditorEnabled =>
      _profileEditorEnabled && client.configuration.runtimeWritesEnabled;
  bool get chatsEnabled =>
      currentChatsEnabled &&
      client.configuration.currentReadsEnabled &&
      client.configuration.runtimeWritesEnabled;

  bool get ownProfileEnabled =>
      currentOwnProfileEnabled &&
      client.configuration.currentReadsEnabled &&
      client.configuration.runtimeWritesEnabled;

  Future<TimewebCurrentOwnProfile> readCurrentOwnProfile() => session
      .runAuthenticated((lease) async {
        if (!ownProfileEnabled) {
          throw StateError('Current own profile is unavailable.');
        }
        final profile = await client.readCurrentOwnProfile();
        lease.requireCurrent();
        profile.requireCurrent();
        return profile.bindSessionGuard(lease.requireCurrent);
      })
      .timeout(session.waitTimeout);

  bool get peopleEnabled => ownProfileEnabled;

  bool get meetingsEnabled => ownProfileEnabled;
  bool get meetingCreationEnabled => meetingsEnabled;

  Future<TimewebMeetingCreateFlow> openMeetingCreation() => session
      .runAuthenticated((lease) {
        if (!meetingCreationEnabled) throw StateError('Current meeting creation is unavailable.');
        return TimewebMeetingCreateFlow.open(
          client: client,
          session: session,
          lease: lease,
          journal: _meetingCreateJournal,
        );
      })
      .timeout(session.waitTimeout);

  Future<TimewebMeetingJoinFlow> openMeetingJoin(String meetingId) => session
      .runAuthenticated((lease) {
        if (!meetingsEnabled) throw StateError('Current meeting join is unavailable.');
        return TimewebMeetingJoinFlow.open(client: client, session: session,
          lease: lease, journal: _meetingJoinJournal, meetingId: meetingId);
      })
      .timeout(session.waitTimeout);

  Future<TimewebMeetingMembershipFlow> openMeetingLeave(String meetingId) => _openMeetingMembership(meetingId, false);
  Future<TimewebMeetingMembershipFlow> openMeetingKick(String meetingId) => _openMeetingMembership(meetingId, true);
  Future<TimewebMeetingMembershipFlow> _openMeetingMembership(String meetingId, bool kick) => session
      .runAuthenticated((lease) {
        if (!meetingsEnabled) throw StateError('Current meeting membership action is unavailable.');
        return TimewebMeetingMembershipFlow.open(client: client, session: session, lease: lease,
          journal: _meetingMembershipJournal, meetingId: meetingId, kick: kick);
      })
      .timeout(session.waitTimeout);

  Future<TimewebMeetingChatFlow> openMeetingConversation(String meetingId) => session
      .runAuthenticated((lease) {
        if (!meetingsEnabled) throw StateError('Current meeting conversation is unavailable.');
        return TimewebMeetingChatFlow.open(client: client, session: session,
          lease: lease, journal: _meetingChatJournal, meetingId: meetingId);
      })
      .timeout(session.waitTimeout);

  Future<TimewebMeetingArchiveFlow> openMeetingArchive(String meetingId) => session
      .runAuthenticated((lease) {
        if (!meetingsEnabled) throw StateError('Current meeting archive is unavailable.');
        return TimewebMeetingArchiveFlow.open(client: client, session: session, lease: lease, meetingId: meetingId);
      })
      .timeout(session.waitTimeout);
  Future<TimewebMeetingArchivePage> readMeetingArchive(String meetingId, {int limit = 30, TimewebMeetingArchiveCursor? cursor}) => session
      .runAuthenticated((lease) async {
        if (!meetingsEnabled) throw StateError('Current meeting archive is unavailable.');
        final page = await client.readMeetingArchive(meetingId, limit: limit, cursor: cursor);
        lease.requireCurrent(); page.requireCurrent(); return page.bindSessionGuard(lease.requireCurrent);
      })
      .timeout(session.waitTimeout);

  Future<TimewebMeetingMessagePage> readMeetingMessages(String meetingId, {int limit = 30, TimewebMeetingCursor? cursor}) => session
      .runAuthenticated((lease) async {
        if (!meetingsEnabled) throw StateError('Current meeting messages are unavailable.');
        final page = await client.readMeetingMessages(meetingId, limit: limit, cursor: cursor);
        lease.requireCurrent(); page.requireCurrent(); return page.bindSessionGuard(lease.requireCurrent);
      })
      .timeout(session.waitTimeout);

  Future<TimewebMeetingPage<TimewebMeeting>> readMeetings(
    TimewebMeetingFilters filters, {
    TimewebMeetingCursor? cursor,
  }) => session
      .runAuthenticated((lease) async {
        if (!meetingsEnabled) throw StateError('Current meetings are unavailable.');
        final page = await client.readMeetings(filters, cursor: cursor);
        lease.requireCurrent();
        page.requireCurrent();
        return page.bindSessionGuard(lease.requireCurrent);
      })
      .timeout(session.waitTimeout);

  Future<TimewebMeeting> readMeeting(String meetingId) => session
      .runAuthenticated((lease) async {
        if (!meetingsEnabled) throw StateError('Current meeting is unavailable.');
        final meeting = await client.readMeeting(meetingId);
        lease.requireCurrent();
        meeting.requireCurrent();
        return meeting.bindSessionGuard(lease.requireCurrent);
      })
      .timeout(session.waitTimeout);

  Future<TimewebMeetingPage<TimewebMeetingParticipant>> readMeetingParticipants(
    String meetingId, {
    int limit = 30,
    TimewebMeetingCursor? cursor,
  }) => session
      .runAuthenticated((lease) async {
        if (!meetingsEnabled) throw StateError('Current meeting participants are unavailable.');
        final page = await client.readMeetingParticipants(meetingId, limit: limit, cursor: cursor);
        lease.requireCurrent();
        page.requireCurrent();
        return page.bindSessionGuard(lease.requireCurrent);
      })
      .timeout(session.waitTimeout);

  Future<TimewebInitialProfileFlow> openInitialProfile() => session.runAuthenticated((lease) {
    if(!ownProfileEnabled){throw StateError('Initial profile is unavailable.');}
    return TimewebInitialProfileFlow.open(client:client,session:session,lease:lease,journal:_initialProfileJournal);
  }).timeout(session.waitTimeout);

  Future<TimewebPhotoUploadFlow> openPhotoUpload({Future<void> Function(TimewebCommittedPhotoReceipt)? onReady}) => session.runAuthenticated((lease) {
    if (!ownProfileEnabled) { throw StateError('Current photo upload is unavailable.'); }
    return TimewebPhotoUploadFlow.open(client: client,session: session,lease: lease,journal: _photoUploadJournal,onReady:onReady);
  }).timeout(session.waitTimeout);

  Future<TimewebPhotoUploadAvailability> readPhotoUploadAvailability() => session.runAuthenticated((lease) async {
    if (!ownProfileEnabled) throw StateError('Current photo upload is unavailable.');
    final availability = await client.readPhotoUploadAvailability();
    lease.requireCurrent();
    availability.requireCurrent();
    return availability.bindSessionGuard(lease.requireCurrent);
  }).timeout(session.waitTimeout);

  bool get profilePhotosEnabled => ownProfileEnabled;

  Future<TimewebProfilePhotoReader> openProfilePhotos(String targetUid) =>
      session.runAuthenticated((lease) async {
        if (!profilePhotosEnabled) {
          throw StateError('Current profile photos are unavailable.');
        }
        final reader = client.openProfilePhotos(targetUid);
        try {
          lease.requireCurrent();
          return reader.bindSessionGuard(lease.requireCurrent);
        } catch (_) {
          unawaited(reader.close());
          rethrow;
        }
      });

  Future<TimewebPeoplePage> readPeople(
    TimewebPeopleFilters filters, {
    TimewebPeopleCursor? cursor,
  }) => session
      .runAuthenticated((lease) async {
        if (!peopleEnabled) {
          throw StateError('Current people directory is unavailable.');
        }
        final page = await client.readPeople(filters, cursor: cursor);
        lease.requireCurrent();
        page.requireCurrent();
        return page.bindSessionGuard(lease.requireCurrent);
      })
      .timeout(session.waitTimeout);

  Future<TimewebPublicPerson> readPerson(String uid) => session
      .runAuthenticated((lease) async {
        if (!peopleEnabled) {
          throw StateError('Current public profile is unavailable.');
        }
        final person = await client.readPerson(uid);
        lease.requireCurrent();
        person.requireCurrent();
        return person.bindSessionGuard(lease.requireCurrent);
      })
      .timeout(session.waitTimeout);

  bool get adminUsersEnabled => ownProfileEnabled;

  Future<TimewebAdminUsersResult> readAdminUsers(
    TimewebAdminUsersRequest request, {
    TimewebAdminUsersCursor? cursor,
  }) => session
      .runAuthenticated((lease) async {
        if (!adminUsersEnabled) {
          throw StateError('Current admin users are unavailable.');
        }
        try {
          final page = await client.readAdminUsers(request, cursor: cursor);
          lease.requireCurrent();
          page.requireCurrent();
          return page.bindSessionGuard(lease.requireCurrent);
        } on TimewebAdminAccessDenied {
          lease.requireCurrent();
          _adminProbeEpoch = lease.epoch;
          _adminProbe = Future.value(false);
          rethrow;
        }
      })
      .timeout(session.waitTimeout);

  /// One bounded role probe per native epoch. Only an affordance: each admin
  /// page still receives fresh server role/session authorization.
  Future<bool> probeAdminUsersAccess() {
    final epoch = session.state.epoch;
    if (!adminUsersEnabled || !session.state.authenticated) {
      return Future.value(false);
    }
    if (_adminProbeEpoch == epoch && _adminProbe != null) return _adminProbe!;
    _adminProbeEpoch = epoch;
    return _adminProbe = (() async {
      try {
        final result = await readAdminUsers(TimewebAdminUsersRequest(limit: 1));
        result.requireCurrent();
        return session.state.authenticated && session.state.epoch == epoch;
      } catch (_) {
        return false;
      }
    })();
  }

  bool get personalChatEnabled => peopleEnabled && chatsEnabled;

  Future<TimewebPersonalChatFlow> openPersonalChat(String targetUid) => session
      .runAuthenticated((lease) {
        if (!personalChatEnabled) {
          throw StateError('Personal chat is unavailable.');
        }
        return TimewebPersonalChatFlow.open(
          client: client,
          session: session,
          lease: lease,
          journal: _personalChatJournal,
          targetUid: targetUid,
        );
      })
      .timeout(session.waitTimeout);

  Future<TimewebChatFlow> openPersonalConversation(
    TimewebOpenedPersonalChatReceipt receipt,
  ) => session
      .runAuthenticated((lease) {
        if (!personalChatEnabled) {
          throw StateError('Personal chat is unavailable.');
        }
        return TimewebChatFlow.openPersonal(
          client: client,
          session: session,
          lease: lease,
          journal: _chatJournal,
          receipt: receipt,
        );
      })
      .timeout(session.waitTimeout);

  bool get temperamentEnabled => currentTemperamentEnabled && ownProfileEnabled;

  Future<TimewebTemperamentFlow> openTemperament(
    TimewebCurrentOwnProfile snapshot,
  ) => session
      .runAuthenticated((lease) {
        if (!temperamentEnabled) {
          throw StateError('Current temperament test is unavailable.');
        }
        snapshot.requireCurrent();
        return TimewebTemperamentFlow.open(
          client: client,
          session: session,
          lease: lease,
          journal: _temperamentJournal,
          snapshot: snapshot,
        );
      })
      .timeout(session.waitTimeout);

  Future<TimewebGeographyFlow> openGeography(
    TimewebCurrentOwnProfile snapshot,
  ) => session
      .runAuthenticated((lease) {
        if (!profileEditorEnabled) {
          throw StateError('Current geography editor is unavailable.');
        }
        snapshot.requireCurrent();
        return TimewebGeographyFlow.open(
          client: client,
          session: session,
          lease: lease,
          journal: _geographyJournal,
          snapshot: snapshot,
        );
      })
      .timeout(session.waitTimeout);

  Future<TimewebCurrentReadPage> readChats({
    TimewebCurrentReadCursor? cursor,
  }) => session
      .runAuthenticated((lease) async {
        if (!chatsEnabled) {
          throw StateError('Current chats are unavailable.');
        }
        final page = await client.readCurrent(
          TimewebCurrentReadRequest.chats(cursor: cursor),
        );
        lease.requireCurrent();
        page.requireCurrent();
        return page;
      })
      .timeout(session.waitTimeout);

  Future<TimewebChatFlow> openChat(TimewebCurrentChat chat) => session
      .runAuthenticated((lease) {
        if (!chatsEnabled) {
          throw StateError('Current chats are unavailable.');
        }
        return TimewebChatFlow.open(
          client: client,
          session: session,
          lease: lease,
          journal: _chatJournal,
          chat: chat,
        );
      })
      .timeout(session.waitTimeout);

  Future<TimewebProfileEditFlow> openProfileEditor() => session
      .runAuthenticated(
        (lease) => TimewebProfileEditFlow.open(
          client: client,
          session: session,
          lease: lease,
          journal: _profileEditJournal,
        ),
      )
      .timeout(session.waitTimeout);

  TimewebAuthLifecycleClient createEmailLifecycleClient(
    TimewebLifecyclePurpose purpose,
  ) {
    // A route builder may run after stop. Keep it an explicitly native,
    // disabled form instead of throwing in the builder or falling to Firebase.
    final live =
        session.state.phase != AppSessionPhase.stopped &&
        session.state.phase != AppSessionPhase.closed;
    return TimewebAuthLifecycleClient(
      configuration: client.configuration,
      enabled:
          live &&
          emailLifecycleEnabled &&
          (purpose != TimewebLifecyclePurpose.registerEmail ||
              registrationEnabled),
      session: session,
    );
  }

  Future<bool> stop() async {
    _adminProbe = null;
    _adminProbeEpoch = null;
    var result = await session.stop();
    while (result.outcome == AppSessionOutcome.pending &&
        result.settled != null) {
      result = await result.settled!;
    }
    await _profileEditJournal.drain();
    await _chatJournal.drain();
    await _temperamentJournal.drain();
    await _geographyJournal.drain();
    await _personalChatJournal.drain();
    await _meetingCreateJournal.drain();
    await _meetingJoinJournal.drain();
    await _meetingChatJournal.drain();
    await _photoUploadJournal.drain();
    await _initialProfileJournal.drain();
    await _meetingMembershipJournal.drain();
    return result.confirmed && !_policyUnsafe;
  }

  @override
  String toString() => 'TimewebAppRuntime(<redacted>)';
}

/// Policy only: tokens remain in the actual client or protected store. There is
/// no second RAM token cache/plaintext persistence. Serialize against actual
/// platform IO, including a prior remembered write that is still settling.
final class _RememberingTokenStore implements TimewebSecureTokenStore {
  _RememberingTokenStore(this._protected);
  final TimewebSecureTokenStore _protected;
  bool _remember = true;
  Future<void> _tail = Future<void>.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> setRemember(bool value) {
    _remember = value;
    return _serial(() async {
      if (!value) {
        await _protected.clear();
      }
    });
  }

  @override
  Future<TimewebSession?> read() => _serial(() async {
    if (!_remember) {
      await _protected.clear();
      return null;
    }
    return _protected.read();
  });
  @override
  Future<void> write(TimewebSession session) => _serial(() async {
    if (_remember) {
      await _protected.write(session);
    } else {
      await _protected.clear();
    }
  });
  @override
  Future<void> clear() => _serial(_protected.clear);
}

/// The source DTO is an immutable reviewed snapshot, not current production
/// profile authority. Both facade and native-client leases must still be live.
final class TimewebSessionProfile {
  TimewebSessionProfile._(this._lease, this._source);
  final AppSessionLease _lease;
  final TimewebFullOwnProfile _source;
  void requireCurrent() {
    _lease.requireCurrent();
    _source.requireCurrent();
  }

  TimewebOnboarding get onboarding {
    requireCurrent();
    return _source.onboarding;
  }

  TimewebFullOwnProfile get source {
    requireCurrent();
    return _source;
  }

  @override
  String toString() => 'TimewebSessionProfile(<redacted>)';
}
