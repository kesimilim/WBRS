import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

part 'timeweb_own_profile.dart';
part 'timeweb_private_media.dart';
part 'timeweb_mutations.dart';
part 'timeweb_meetings.dart';
part 'timeweb_current_reads.dart';
part 'timeweb_profile_editor.dart';
part 'timeweb_current_own_profile.dart';
part 'timeweb_geography.dart';
part 'timeweb_people.dart';
part 'timeweb_personal_chat.dart';
part 'timeweb_admin_users.dart';
part 'timeweb_profile_photos.dart';
part 'timeweb_profile_photo_uploads.dart';
part 'timeweb_initial_profile.dart';

/// Public routing only. This is intentionally not wired to AppBackend or UI.
class TimewebAuthConfiguration {
  TimewebAuthConfiguration({
    required this.endpoint,
    this.enabled = false,
    this.privateMediaEnabled = false,
    this.runtimeWritesEnabled = false,
    this.currentReadsEnabled = false,
  }) {
    final host = endpoint.host.toLowerCase();
    final dnsName = RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$');
    if (endpoint.scheme != 'https' ||
        !dnsName.hasMatch(host) ||
        !host.contains('.') ||
        !host
            .split('.')
            .every(
              (label) => RegExp(
                r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
              ).hasMatch(label),
            ) ||
        RegExp(r'^[0-9.]+$').hasMatch(host) ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.lan') ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.hasPort && endpoint.port != 443) ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      throw ArgumentError('A public HTTPS API origin is required.');
    }
  }

  final Uri endpoint;
  final bool enabled;
  final bool privateMediaEnabled;
  final bool runtimeWritesEnabled;
  final bool currentReadsEnabled;
}

/// The implementation must use an OS protected token store, never plaintext
/// preferences/files, logs or a password cache. Android adapter is separate.
/// Calls are serialized; a timed out Future would not cancel a native write.
abstract interface class TimewebSecureTokenStore {
  Future<TimewebSession?> read();
  Future<void> write(TimewebSession session);
  Future<void> clear();
}

/// Opaque credentials: never decode a token to infer identity or expiry.
class TimewebSession {
  TimewebSession({
    required this.uid,
    required this.emailVerified,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  }) {
    if (uid.isEmpty ||
        uid.runes.length > 191 ||
        uid.contains('\u0000') ||
        utf8.decode(utf8.encode(uid)) != uid ||
        !_validToken(accessToken, 'na1.') ||
        !_validToken(refreshToken, 'nr1.') ||
        refreshExpiresAt.isBefore(accessExpiresAt)) {
      throw ArgumentError('Invalid protected session.');
    }
  }

  final String uid;
  final bool emailVerified;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;

  @override
  String toString() => 'TimewebSession(<redacted>)';
}

bool _validToken(String token, String prefix) =>
    token.startsWith(prefix) &&
    token.length > prefix.length &&
    token.length <= 8192 &&
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(token);

enum TimewebAuthOperation {
  restore,
  login,
  refresh,
  logout,
  profile,
  conversation,
  media,
  mutation,
  currentRead,
}

enum TimewebAuthError {
  disabled,
  invalidRequest,
  notAuthenticated,
  unauthorized,
  rateLimited,
  unavailable,
  network,
  deadline,
  invalidResponse,
  staleSession,
  secureStore,
  closed,
}

/// No raw request, response, password, token, email or low-level exception.
class TimewebAuthException implements Exception {
  const TimewebAuthException(this.operation, this.error);
  final TimewebAuthOperation operation;
  final TimewebAuthError error;

  @override
  String toString() => 'TimewebAuthException(${operation.name}, ${error.name})';
}

/// A started POST may have committed despite a timeout/503/malformed answer.
/// No request ID/status route exists; this must not be automatically retried.
class TimewebUnknownOutcome extends TimewebAuthException {
  const TimewebUnknownOutcome(super.operation, super.error);

  @override
  String toString() =>
      'TimewebUnknownOutcome(${operation.name}, ${error.name})';
}

enum TimewebLogoutOutcome {
  confirmed,
  accessRejected,
  remoteUnknown,
  localOnly,
}

class TimewebLogoutResult {
  const TimewebLogoutResult({
    required this.outcome,
    required this.allSessions,
    required this.secureTokensCleared,
    required this.superseded,
  });
  final TimewebLogoutOutcome outcome;
  final bool allSessions;
  final bool secureTokensCleared;

  /// A later login/logout replaced this operation; UI must ignore its result.
  final bool superseded;

  /// Only a loggedOut:true response confirms server logout (including all).
  bool get remoteConfirmed => outcome == TimewebLogoutOutcome.confirmed;
}

/// Lifecycle only, never a server logout confirmation. An unknown auth POST
/// may require a new login even though its existing invalidation cleared disk.
class TimewebStopResult {
  const TimewebStopResult({
    required this.protectedStateSafe,
    required this.remoteOutcomeUnknown,
  });
  final bool protectedStateSafe;
  final bool remoteOutcomeUnknown;
}

class _Reply {
  const _Reply(this.status, this.body);
  final int status;
  final Map<String, dynamic>? body;
}

enum TimewebConversationResource {
  chats,
  chatMessages,
  meetings,
  meeting,
  meetingMessages,
  meetingParticipants,
}

/// Only these exact reviewed GET routes can use the authenticated transport.
/// No caller-controlled URI, owner UID, method, body or bearer is accepted.
final class TimewebConversationReadRequest {
  TimewebConversationReadRequest._(
    this.resource, {
    this.resourceId,
    this.limit,
    this.cursor,
    this.ownRemoved = false,
  }) {
    final detail = resource == TimewebConversationResource.meeting;
    final identified = !const [
      TimewebConversationResource.chats,
      TimewebConversationResource.meetings,
    ].contains(resource);
    if (identified != (resourceId != null) ||
        (resourceId != null && !_validResourceId(resourceId!)) ||
        (!detail && (limit == null || limit! < 1 || limit! > 50)) ||
        (detail && (limit != null || cursor != null)) ||
        (ownRemoved &&
            resource != TimewebConversationResource.meetingMessages)) {
      throw ArgumentError('Invalid conversation read request.');
    }
  }
  factory TimewebConversationReadRequest.chats({
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => TimewebConversationReadRequest._(
    TimewebConversationResource.chats,
    limit: limit,
    cursor: cursor,
  );
  factory TimewebConversationReadRequest.chatMessages(
    String id, {
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => TimewebConversationReadRequest._(
    TimewebConversationResource.chatMessages,
    resourceId: id,
    limit: limit,
    cursor: cursor,
  );
  factory TimewebConversationReadRequest.meetings({
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => TimewebConversationReadRequest._(
    TimewebConversationResource.meetings,
    limit: limit,
    cursor: cursor,
  );
  factory TimewebConversationReadRequest.meeting(String id) =>
      TimewebConversationReadRequest._(
        TimewebConversationResource.meeting,
        resourceId: id,
      );
  factory TimewebConversationReadRequest.meetingMessages(
    String id, {
    bool ownRemoved = false,
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => TimewebConversationReadRequest._(
    TimewebConversationResource.meetingMessages,
    resourceId: id,
    ownRemoved: ownRemoved,
    limit: limit,
    cursor: cursor,
  );
  factory TimewebConversationReadRequest.meetingParticipants(
    String id, {
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => TimewebConversationReadRequest._(
    TimewebConversationResource.meetingParticipants,
    resourceId: id,
    limit: limit,
    cursor: cursor,
  );

  final TimewebConversationResource resource;
  final String? resourceId;
  final int? limit;
  final TimewebReadCursor? cursor;
  final bool ownRemoved;
  String get _scope =>
      '${resource.name}\u0000${resourceId ?? ''}\u0000$ownRemoved';

  Uri _uri(Uri origin) {
    final segments = switch (resource) {
      TimewebConversationResource.chats => ['v1', 'chats'],
      TimewebConversationResource.chatMessages => [
        'v1',
        'chats',
        resourceId!,
        'messages',
      ],
      TimewebConversationResource.meetings => ['v1', 'meetings'],
      TimewebConversationResource.meeting => ['v1', 'meetings', resourceId!],
      TimewebConversationResource.meetingMessages => [
        'v1',
        'meetings',
        resourceId!,
        'messages',
      ],
      TimewebConversationResource.meetingParticipants => [
        'v1',
        'meetings',
        resourceId!,
        'participants',
      ],
    };
    return origin.replace(
      pathSegments: segments,
      queryParameters: {
        if (limit != null) 'limit': '$limit',
        if (cursor != null) 'cursor': cursor!._value,
        if (ownRemoved) 'own_removed': '1',
      },
    );
  }
}

bool _validResourceId(String value) =>
    value.isNotEmpty &&
    !const ['.', '..'].contains(value) &&
    !value.contains('/') &&
    !value.contains('\u0000') &&
    utf8.encode(value).length <= 1500 &&
    utf8.decode(utf8.encode(value)) == value;
bool _validReadCursor(String value) =>
    value.isNotEmpty &&
    value.length <= 4096 &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

/// Opaque pagination capability. Cannot be manufactured from a string or
/// reused by B/another client/another resource. Never decode or log its value.
final class TimewebReadCursor {
  TimewebReadCursor._(this._value, this._owner, this._scope, this._check);
  final String _value;
  final TimewebAuthClient _owner;
  final String _scope;
  final void Function() _check;
  @override
  String toString() => 'TimewebReadCursor(<redacted>)';
}

/// No token or epoch is exposed. Recheck after a consumer await/parsing step;
/// a late result or cursor from A cannot become data for the new account B.
final class TimewebAuthorizedRead {
  TimewebAuthorizedRead._(this._body, this._owner, this._scope, this._check);
  final Map<String, dynamic> _body;
  final TimewebAuthClient _owner;
  final String _scope;
  final void Function() _check;
  void requireCurrent() => _check();
  Map<String, dynamic> get body {
    _check();
    return _body;
  }

  TimewebReadCursor? paginationCursor(Object? value) {
    _check();
    if (value == null) return null;
    if (value is! String || !_validReadCursor(value)) {
      throw const TimewebAuthException(
        TimewebAuthOperation.conversation,
        TimewebAuthError.invalidResponse,
      );
    }
    return TimewebReadCursor._(value, _owner, _scope, _check);
  }

  @override
  String toString() => 'TimewebAuthorizedRead(<redacted>)';
}

class _GrantedReply {
  const _GrantedReply(this.body, this.epoch, this.uid);
  final Map<String, dynamic> body;
  final int epoch;
  final String uid;
}

Object? _immutableJson(Object? value, [int depth = 0]) {
  if (depth > 24) {
    throw const TimewebAuthException(
      TimewebAuthOperation.conversation,
      TimewebAuthError.invalidResponse,
    );
  }
  if (value == null ||
      value is String ||
      value is bool ||
      (value is num && value.isFinite))
    return value;
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((item) => _immutableJson(item, depth + 1)),
    );
  }
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, item) => MapEntry(key, _immutableJson(item, depth + 1))),
    );
  }
  throw const TimewebAuthException(
    TimewebAuthOperation.conversation,
    TimewebAuthError.invalidResponse,
  );
}

/// Migration adapter only. Native backend flags and client configuration stay
/// off until imported credentials, runtime grants and live Auth proof pass.
class TimewebAuthClient {
  TimewebAuthClient({
    required this.configuration,
    required TimewebSecureTokenStore secureStore,
    http.Client? transport,
    DateTime Function()? clock,
    this.requestDeadline = const Duration(seconds: 10),
    this.accessExpirySkew = const Duration(seconds: 30),
    this.mediaRequestDeadline = const Duration(seconds: 60),
  }) : _store = secureStore,
       _http = transport ?? http.Client(),
       _ownsTransport = transport == null,
       _clock = clock ?? DateTime.now {
    if (requestDeadline <= Duration.zero ||
        requestDeadline > const Duration(seconds: 30) ||
        accessExpirySkew < Duration.zero ||
        mediaRequestDeadline <= Duration.zero ||
        mediaRequestDeadline > const Duration(seconds: 60)) {
      throw ArgumentError('Invalid client deadlines.');
    }
  }

  final TimewebAuthConfiguration configuration;
  final Duration requestDeadline;
  final Duration accessExpirySkew;
  final Duration mediaRequestDeadline;
  final TimewebSecureTokenStore _store;
  final http.Client _http;
  final bool _ownsTransport;
  final DateTime Function() _clock;
  Future<void> _storeTail = Future<void>.value();
  Future<TimewebSession>? _refreshFlight;
  Future<TimewebSession?>? _restoreFlight;
  Future<bool>? _closeFlight;
  Future<TimewebStopResult>? _stopFlight;
  final Set<Future<void>> _authDrains = {};
  final Set<_MutationTransfer> _mutationTransfers = {};
  bool _stopping = false;
  bool _stopAuthUnknown = false;
  bool _authStoreFailure = false;
  int _epoch = 0;
  TimewebSession? _session;
  bool _secureStoreUnsafe = false;
  bool _closed = false;
  int _inflightRequests = 0;
  final Map<String, _PrivateMediaFlight> _mediaFlights = {};
  bool _mediaPumping = false;
  final Map<String, TimewebMutationReference> _mutationReferences = {};
  final Map<String, _CurrentReadFlight> _currentReadFlights = {};
  final Map<int, _ProfileEditorFlight> _profileEditorFlights = {};
  final Map<int, _CurrentOwnProfileFlight> _currentOwnProfileFlights = {};
  final Map<String, _PeopleFlight> _peopleFlights = {};
  final Set<_PhotoPutFlight> _profilePhotoUploadFlights = {};
  final Map<String, _AdminUsersFlight> _adminUsersFlights = {};
  final Map<String, _ProfilePhotoFlight> _profilePhotoFlights = {};
  int _profilePhotoReaderSequence = 0;

  /// Exposes identity only; credentials remain between transport/store.
  String? get currentUid => _stopping || _closed ? null : _session?.uid;
  bool get hasSession =>
      _session != null && !_secureStoreUnsafe && !_closed && !_stopping;

  void _checkEnabled(TimewebAuthOperation operation) {
    if (_closed || _stopping) {
      throw TimewebAuthException(operation, TimewebAuthError.closed);
    }
    if (!configuration.enabled) {
      throw TimewebAuthException(operation, TimewebAuthError.disabled);
    }
  }

  void _checkEpoch(int epoch, TimewebAuthOperation operation) {
    // Already started auth may finish durable rotation while runtime reads are
    // stopped. Its final identity adoption uses the stricter runtime guard.
    if (_closed ||
        _epoch != epoch ||
        (_stopping &&
            !const {
              TimewebAuthOperation.restore,
              TimewebAuthOperation.login,
              TimewebAuthOperation.refresh,
              TimewebAuthOperation.logout,
            }.contains(operation))) {
      throw TimewebAuthException(operation, TimewebAuthError.staleSession);
    }
  }

  void _checkRuntimeEpoch(int epoch, TimewebAuthOperation operation) {
    _checkEpoch(epoch, operation);
    if (_stopping) {
      throw TimewebAuthException(operation, TimewebAuthError.staleSession);
    }
  }

  Future<T> _trackAuth<T>(Future<T> operation) {
    late final Future<void> drain;
    drain = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        if (_stopping && error is TimewebUnknownOutcome) {
          _stopAuthUnknown = true;
        }
        if (error is TimewebAuthException &&
            error.error == TimewebAuthError.secureStore) {
          _authStoreFailure = true;
        }
      },
    );
    _authDrains.add(drain);
    unawaited(
      drain.then<void>((_) {
        _authDrains.remove(drain);
      }),
    );
    return operation;
  }

  int _newEpoch() {
    _epoch++;
    _cancelPrivateMedia(this);
    _mutationReferences.clear();
    unawaited(_cancelMutationTransfers(this));
    _cancelCurrentReads(this);
    unawaited(_cancelProfileEditorRead(this));
    unawaited(_cancelCurrentOwnProfileRead(this));
    unawaited(_cancelPeopleReads(this));
    unawaited(_cancelAdminUsersReads(this));
    unawaited(_cancelPhotoFlights(this));
    unawaited(_cancelPhotoUploadFlights(this));
    _session = null;
    _refreshFlight = null;
    _restoreFlight = null;
    return _epoch;
  }

  Future<T> _stored<T>(
    int epoch,
    TimewebAuthOperation operation,
    Future<T> Function() action,
  ) {
    final task = _storeTail.then((_) async {
      _checkEpoch(epoch, operation);
      final value = await action();
      _checkEpoch(epoch, operation);
      return value;
    });
    // A later clear/B-write waits for the actual old native operation, even if
    // A became stale. Catch only on the queue tail, not on caller's result.
    _storeTail = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  Future<bool> _clearStore(int epoch) async {
    if (_epoch != epoch || _closed) return true;
    try {
      await _stored(epoch, TimewebAuthOperation.logout, _store.clear);
      _secureStoreUnsafe = false;
      return true;
    } on TimewebAuthException catch (error) {
      if (error.error == TimewebAuthError.staleSession) return true;
      _secureStoreUnsafe = true;
      return false;
    } catch (_) {
      if (_epoch == epoch) _secureStoreUnsafe = true;
      return false;
    }
  }

  Future<void> _invalidate(int expectedEpoch) async {
    if (_epoch != expectedEpoch || _closed) return;
    final next = _newEpoch();
    await _clearStore(next);
  }

  /// Restore once on startup. Subsequent calls use the current logical state,
  /// never re-read an old disk token after logout or while B is logging in.
  Future<TimewebSession?> restore() {
    const op = TimewebAuthOperation.restore;
    _checkEnabled(op);
    final pending = _restoreFlight;
    if (pending != null) return pending;
    if (_epoch != 0 && !_secureStoreUnsafe) return Future.value(_session);
    final epoch = _newEpoch();
    late Future<TimewebSession?> flight;
    flight = _trackAuth(_restore(epoch)).whenComplete(() {
      if (identical(_restoreFlight, flight)) _restoreFlight = null;
    });
    _restoreFlight = flight;
    return flight;
  }

  Future<TimewebSession?> _restore(int epoch) async {
    const op = TimewebAuthOperation.restore;
    // A failed prior clear never becomes a later silent restore of A.
    if (_secureStoreUnsafe) {
      if (!await _clearStore(epoch)) {
        throw const TimewebAuthException(op, TimewebAuthError.secureStore);
      }
      return null;
    }
    TimewebSession? stored;
    try {
      stored = await _stored(epoch, op, _store.read);
    } on TimewebAuthException {
      rethrow;
    } catch (_) {
      throw const TimewebAuthException(op, TimewebAuthError.secureStore);
    }
    _checkRuntimeEpoch(epoch, op);
    if (stored != null && !_clock().isBefore(stored.refreshExpiresAt)) {
      if (!await _clearStore(epoch)) {
        throw const TimewebAuthException(op, TimewebAuthError.secureStore);
      }
      return null;
    }
    _session = stored;
    return stored;
  }

  Future<TimewebSession> login({
    required String email,
    required String password,
    required String deviceId,
  }) =>
      _trackAuth(_login(email: email, password: password, deviceId: deviceId));

  Future<TimewebSession> _login({
    required String email,
    required String password,
    required String deviceId,
  }) async {
    const op = TimewebAuthOperation.login;
    _checkEnabled(op);
    final body = {'email': email, 'password': password, 'deviceId': deviceId};
    final normalizedEmail = email.trim().toLowerCase();
    if (email.isEmpty ||
        !normalizedEmail.contains('@') ||
        normalizedEmail.contains('\u0000') ||
        normalizedEmail.contains(RegExp(r'\s')) ||
        email.length > 320 ||
        utf8.encode(email).length > 1280 ||
        utf8.encode(password).length > 4096 ||
        !RegExp(r'^[A-Za-z0-9._:-]{1,191}$').hasMatch(deviceId) ||
        utf8.encode(jsonEncode(body)).length > 8192) {
      throw const TimewebAuthException(op, TimewebAuthError.invalidRequest);
    }
    final epoch = _newEpoch();
    if (!await _clearStore(epoch)) {
      throw const TimewebAuthException(op, TimewebAuthError.secureStore);
    }
    _checkRuntimeEpoch(epoch, op);
    final started = _clock();
    final reply = await _forEpoch(
      epoch,
      op,
      _post('/v1/auth/login', op, body: body),
    );
    _checkEpoch(epoch, op);
    final session = _tokens(reply, started, op);
    await _persist(epoch, op, session);
    _checkRuntimeEpoch(epoch, op);
    _session = session;
    return session;
  }

  Future<void> _persist(
    int epoch,
    TimewebAuthOperation operation,
    TimewebSession session,
  ) async {
    try {
      await _stored(epoch, operation, () => _store.write(session));
    } on TimewebAuthException {
      rethrow;
    } catch (_) {
      await _invalidate(epoch);
      throw TimewebAuthException(operation, TimewebAuthError.secureStore);
    }
    _checkEpoch(epoch, operation);
  }

  /// A single Future is shared even when several profile reads get 401.
  Future<TimewebSession> refresh() {
    const op = TimewebAuthOperation.refresh;
    _checkEnabled(op);
    final current = _session;
    if (current == null || _secureStoreUnsafe) {
      throw TimewebAuthException(op, TimewebAuthError.notAuthenticated);
    }
    final pending = _refreshFlight;
    if (pending != null) return pending;
    final epoch = _epoch;
    late Future<TimewebSession> flight;
    flight = _trackAuth(_refresh(epoch, current)).whenComplete(() {
      if (identical(_refreshFlight, flight)) _refreshFlight = null;
    });
    _refreshFlight = flight;
    return flight;
  }

  Future<TimewebSession> _refresh(int epoch, TimewebSession old) async {
    const op = TimewebAuthOperation.refresh;
    try {
      if (!_clock().isBefore(old.refreshExpiresAt)) {
        throw TimewebAuthException(op, TimewebAuthError.notAuthenticated);
      }
      final started = _clock();
      final reply = await _forEpoch(
        epoch,
        op,
        _post('/v1/auth/refresh', op, body: {'refreshToken': old.refreshToken}),
      );
      _checkEpoch(epoch, op);
      final next = _tokens(reply, started, op);
      if (next.uid != old.uid) {
        throw const TimewebUnknownOutcome(op, TimewebAuthError.invalidResponse);
      }
      await _persist(epoch, op, next);
      _checkRuntimeEpoch(epoch, op);
      _session = next;
      return next;
    } on TimewebAuthException catch (error) {
      if (error is TimewebUnknownOutcome ||
          error.error == TimewebAuthError.unauthorized ||
          error.error == TimewebAuthError.notAuthenticated ||
          error.error == TimewebAuthError.secureStore) {
        // Retrying an old refresh can revoke every device session via replay.
        await _invalidate(epoch);
      }
      rethrow;
    }
  }

  /// No media cache. Binary reads are bound to the current logical session.
  Future<TimewebPrivateMediaBytes> readPrivateMedia(
    TimewebPrivateMediaRequest request,
  ) => _readPrivateMedia(this, request);

  TimewebMutationReference bindMutation(
    TimewebMutationRequest request, {
    required String expectedOwnerUid,
  }) => _bindMutation(this, request, expectedOwnerUid);

  Future<TimewebMutationResult> mutate(TimewebMutationReference reference) =>
      _mutate(this, reference);

  Future<TimewebMutationResult> reconcileMutation(
    TimewebMutationReference reference,
  ) => _reconcileMutation(this, reference);

  /// After a receipt or definite original POST failure was durably acknowledged.
  void acknowledgeMutation(TimewebMutationReference reference) =>
      _acknowledgeMutation(this, reference);

  Future<TimewebCurrentReadPage> readCurrent(
    TimewebCurrentReadRequest request,
  ) => _readCurrent(this, request);

  Future<TimewebProfileEditorSnapshot> readProfileForEdit(
    TimewebProfileEditorRequest request,
  ) => _readProfileForEdit(this, request);

  Future<TimewebCurrentOwnProfile> readCurrentOwnProfile() =>
      _readCurrentOwnProfile(this);

  Future<TimewebPeoplePage> readPeople(
    TimewebPeopleFilters filters, {
    TimewebPeopleCursor? cursor,
  }) => _startPeopleRead(
    this,
    filters: filters,
    cursor: cursor,
  ).then((value) => value as TimewebPeoplePage);

  Future<TimewebAdminUsersResult> readAdminUsers(
    TimewebAdminUsersRequest request, {
    TimewebAdminUsersCursor? cursor,
  }) => _startAdminUsersRead(
    this,
    request,
    cursor,
  ).then((value) => value as TimewebAdminUsersResult);

  TimewebProfilePhotoReader openProfilePhotos(String targetUid) =>
      _openProfilePhotos(this, targetUid);

  Future<TimewebPublicPerson> readPerson(String uid) => _startPeopleRead(
    this,
    targetUid: uid,
  ).then((value) => value as TimewebPublicPerson);

  /// No profile value cache. Every read is authorized by its own opaque bearer.
  Future<Map<String, dynamic>> readOwnProfile() async {
    const op = TimewebAuthOperation.profile;
    final granted = await _authorizedGet(op, '/v1/me/profile', maxBytes: 65536);
    _checkEpoch(granted.epoch, op);
    final profile = granted.body['profile'];
    if (profile is! Map<String, dynamic> || profile['uid'] != granted.uid) {
      throw const TimewebAuthException(op, TimewebAuthError.invalidResponse);
    }
    _checkEpoch(granted.epoch, op);
    return Map<String, dynamic>.unmodifiable(profile);
  }

  /// Fixed read-only route, bound to the reviewed public snapshot and current
  /// logical session. This DTO cannot be used as a financial hydration map.
  Future<TimewebFullOwnProfile> readFullOwnProfile({
    required String expectedSourceSnapshot,
  }) async {
    const op = TimewebAuthOperation.profile;
    _checkEnabled(op);
    if (!_ownProfileDigest(expectedSourceSnapshot)) {
      throw const TimewebAuthException(op, TimewebAuthError.invalidRequest);
    }
    final granted = await _authorizedGet(
      op,
      '/v1/me/full-profile',
      maxBytes: 262144,
    );
    void check() {
      _checkEpoch(granted.epoch, op);
      if (_secureStoreUnsafe || _session?.uid != granted.uid) {
        throw const TimewebAuthException(op, TimewebAuthError.staleSession);
      }
    }

    check();
    final result = _decodeFullOwnProfile(
      granted.body,
      uid: granted.uid,
      expectedSourceSnapshot: expectedSourceSnapshot,
      check: check,
    );
    check();
    return result;
  }

  Future<TimewebAuthorizedRead> readConversation(
    TimewebConversationReadRequest request,
  ) async {
    const op = TimewebAuthOperation.conversation;
    _checkEnabled(op);
    final cursor = request.cursor;
    if (cursor != null) {
      if (!identical(cursor._owner, this) || cursor._scope != request._scope) {
        throw const TimewebAuthException(op, TimewebAuthError.invalidRequest);
      }
      cursor._check();
    }
    final granted = await _authorizedGet(
      op,
      '',
      uri: request._uri(configuration.endpoint),
      maxBytes: 262144,
    );
    _checkEpoch(granted.epoch, op);
    final frozen = _immutableJson(granted.body) as Map<String, dynamic>;
    void check() {
      _checkEpoch(granted.epoch, op);
      if (_secureStoreUnsafe || _session?.uid != granted.uid) {
        throw const TimewebAuthException(op, TimewebAuthError.staleSession);
      }
    }

    check();
    return TimewebAuthorizedRead._(frozen, this, request._scope, check);
  }

  Future<_GrantedReply> _authorizedGet(
    TimewebAuthOperation op,
    String path, {
    Uri? uri,
    required int maxBytes,
  }) async {
    _checkEnabled(op);
    final epoch = _epoch;
    var current = _session;
    if (current == null || _secureStoreUnsafe) {
      throw TimewebAuthException(op, TimewebAuthError.notAuthenticated);
    }
    if (!_clock().add(accessExpirySkew).isBefore(current.accessExpiresAt)) {
      current = await refresh();
      _checkEpoch(epoch, op);
    }
    var reply = await _forEpoch(
      epoch,
      op,
      _request(
        'GET',
        path,
        op,
        bearer: current.accessToken,
        uri: uri,
        maxResponseBytes: maxBytes,
      ),
    );
    _checkEpoch(epoch, op);
    if (reply.status == 401) {
      // Another caller may already have rotated the token. Never rotate it a
      // second time just because this older GET's 401 arrived late.
      if (_session?.accessToken == current.accessToken) await refresh();
      _checkEpoch(epoch, op);
      current = _session;
      if (current == null) {
        throw TimewebAuthException(op, TimewebAuthError.notAuthenticated);
      }
      reply = await _forEpoch(
        epoch,
        op,
        _request(
          'GET',
          path,
          op,
          bearer: current.accessToken,
          uri: uri,
          maxResponseBytes: maxBytes,
        ),
      );
      _checkEpoch(epoch, op);
    }
    if (reply.status != 200) {
      if (reply.status == 401 && _session?.accessToken == current.accessToken) {
        await _invalidate(epoch);
      }
      throw _statusError(op, reply.status);
    }
    if (reply.body == null) {
      throw TimewebAuthException(op, TimewebAuthError.invalidResponse);
    }
    return _GrantedReply(reply.body!, epoch, current.uid);
  }

  /// Local identity is dropped immediately; persistent clearing is attempted
  /// in finally even for deadline, network, malformed reply or logout-all.
  Future<TimewebLogoutResult> logout({bool allSessions = false}) =>
      _trackAuth(_logout(allSessions: allSessions));

  Future<TimewebLogoutResult> _logout({bool allSessions = false}) async {
    const op = TimewebAuthOperation.logout;
    _checkEnabled(op);
    final old = _session;
    final epoch = _newEpoch();
    final initialClear = _clearStore(epoch);
    var outcome = TimewebLogoutOutcome.localOnly;
    var cleared = false;
    try {
      if (old != null) {
        try {
          final reply = await _post(
            '/v1/auth/logout',
            op,
            body: {'allSessions': allSessions},
            bearer: old.accessToken,
          );
          outcome = reply.body?['loggedOut'] == true
              ? TimewebLogoutOutcome.confirmed
              : TimewebLogoutOutcome.remoteUnknown;
        } on TimewebAuthException catch (error) {
          outcome = error.error == TimewebAuthError.unauthorized
              ? TimewebLogoutOutcome.accessRejected
              : TimewebLogoutOutcome.remoteUnknown;
        }
      }
    } finally {
      cleared = await initialClear;
      if (!cleared) cleared = await _clearStore(epoch);
    }
    return TimewebLogoutResult(
      outcome: outcome,
      allSessions: allSessions,
      secureTokensCleared: cleared,
      superseded: _epoch != epoch || _closed || _stopping,
    );
  }

  Future<T> _forEpoch<T>(
    int epoch,
    TimewebAuthOperation operation,
    Future<T> future,
  ) async {
    try {
      final value = await future;
      _checkEpoch(epoch, operation);
      return value;
    } catch (_) {
      // Late errors must not be mistaken for the current account's failure.
      _checkEpoch(epoch, operation);
      rethrow;
    }
  }

  TimewebSession _tokens(
    _Reply reply,
    DateTime started,
    TimewebAuthOperation op,
  ) {
    final data = reply.body;
    const fields = {
      'accessToken',
      'refreshToken',
      'expiresIn',
      'refreshExpiresIn',
      'uid',
      'emailVerified',
    };
    if (data == null ||
        data.length != fields.length ||
        !fields.every(data.containsKey) ||
        data['uid'] is! String ||
        data['emailVerified'] is! bool ||
        data['accessToken'] is! String ||
        data['refreshToken'] is! String ||
        data['expiresIn'] is! int ||
        data['refreshExpiresIn'] is! int ||
        data['expiresIn'] < 1 ||
        data['expiresIn'] > 900 ||
        data['refreshExpiresIn'] < data['expiresIn'] ||
        data['refreshExpiresIn'] > 1209600) {
      throw TimewebUnknownOutcome(op, TimewebAuthError.invalidResponse);
    }
    try {
      return TimewebSession(
        uid: data['uid'],
        emailVerified: data['emailVerified'],
        accessToken: data['accessToken'],
        refreshToken: data['refreshToken'],
        // Conservative expiry begins before the request/KDF, not after it.
        accessExpiresAt: started.add(Duration(seconds: data['expiresIn'])),
        refreshExpiresAt: started.add(
          Duration(seconds: data['refreshExpiresIn']),
        ),
      );
    } catch (_) {
      throw TimewebUnknownOutcome(op, TimewebAuthError.invalidResponse);
    }
  }

  Future<_Reply> _post(
    String path,
    TimewebAuthOperation op, {
    required Map<String, dynamic> body,
    String? bearer,
  }) async {
    try {
      final reply = await _request(
        'POST',
        path,
        op,
        body: body,
        bearer: bearer,
      );
      if (reply.status == 200) return reply;
      if (const [400, 401, 404, 405, 429].contains(reply.status)) {
        throw _statusError(op, reply.status);
      }
      throw TimewebUnknownOutcome(op, TimewebAuthError.unavailable);
    } on TimewebAuthException catch (error) {
      if (const [
        TimewebAuthError.network,
        TimewebAuthError.deadline,
        TimewebAuthError.invalidResponse,
      ].contains(error.error)) {
        throw TimewebUnknownOutcome(op, error.error);
      }
      rethrow;
    }
  }

  TimewebAuthException _statusError(TimewebAuthOperation op, int status) =>
      TimewebAuthException(op, switch (status) {
        400 => TimewebAuthError.invalidRequest,
        401 => TimewebAuthError.unauthorized,
        429 => TimewebAuthError.rateLimited,
        _ => TimewebAuthError.unavailable,
      });

  Future<_Reply> _request(
    String method,
    String path,
    TimewebAuthOperation op, {
    Map<String, dynamic>? body,
    String? bearer,
    Uri? uri,
    int? maxResponseBytes,
  }) async {
    if (_inflightRequests >= 4) {
      throw TimewebAuthException(op, TimewebAuthError.unavailable);
    }
    final request =
        http.Request(method, uri ?? configuration.endpoint.resolve(path))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json'
          ..headers['Cache-Control'] = 'no-store';
    if (bearer != null) request.headers['Authorization'] = 'Bearer $bearer';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    _inflightRequests++;
    var abandoned = false;
    StreamIterator<List<int>>? reader;
    Future<void>? cancellation;
    Future<void> cancelReader() =>
        cancellation ??= reader?.cancel() ?? Future<void>.value();
    Future<_Reply> transfer() async {
      try {
        final response = await _http.send(request);
        reader = StreamIterator(response.stream);
        if (abandoned) {
          throw TimewebAuthException(op, TimewebAuthError.deadline);
        }
        // Do not consume or expose error bodies. A redirect is never followed.
        if (response.statusCode != 200) {
          return _Reply(response.statusCode, null);
        }
        final contentType =
            response.headers['content-type']?.toLowerCase() ?? '';
        final cacheControl =
            response.headers['cache-control']?.toLowerCase() ?? '';
        if (contentType.split(';').first.trim() != 'application/json' ||
            !cacheControl
                .split(',')
                .map((value) => value.trim())
                .contains('no-store')) {
          throw TimewebAuthException(op, TimewebAuthError.invalidResponse);
        }
        final bytes = <int>[];
        final maxBytes =
            maxResponseBytes ??
            (op == TimewebAuthOperation.profile ? 65536 : 16384);
        while (await reader!.moveNext()) {
          if (abandoned)
            throw TimewebAuthException(op, TimewebAuthError.deadline);
          final chunk = reader!.current;
          if (bytes.length + chunk.length > maxBytes) {
            throw TimewebAuthException(op, TimewebAuthError.invalidResponse);
          }
          bytes.addAll(chunk);
        }
        if (abandoned)
          throw TimewebAuthException(op, TimewebAuthError.deadline);
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) {
          throw TimewebAuthException(op, TimewebAuthError.invalidResponse);
        }
        return _Reply(response.statusCode, decoded);
      } finally {
        // Keep the bounded transport slot until actual send/stream cleanup
        // settles. A hanging injected Client cannot create an unbounded queue.
        try {
          await cancelReader();
        } finally {
          _inflightRequests--;
        }
      }
    }

    try {
      // Timeout does not cancel a server write. The late transport future has
      // no storage/state continuation; a mutation caller reports unknown.
      return await transfer().timeout(requestDeadline);
    } on TimeoutException {
      abandoned = true;
      if (reader != null) unawaited(cancelReader().catchError((Object _) {}));
      throw TimewebAuthException(op, TimewebAuthError.deadline);
    } on FormatException {
      throw TimewebAuthException(op, TimewebAuthError.invalidResponse);
    } on TimewebAuthException {
      rethrow;
    } catch (_) {
      throw TimewebAuthException(op, TimewebAuthError.network);
    }
  }

  /// Local-only close, not confirmed server logout. Await it before sharing
  /// this protected store with a replacement client instance.
  Future<bool> close() {
    final existing = _closeFlight;
    if (existing != null) return existing;
    _newEpoch();
    _closed = true;
    if (_ownsTransport) _http.close();
    final clear = _storeTail.then((_) => _store.clear());
    _storeTail = clear.then<void>((_) {}, onError: (Object _) {});
    return _closeFlight = _finishClose(clear);
  }

  /// Stop runtime ownership without initiating token clearing or remote logout.
  /// Await the real drain before a replacement client shares this store. A
  /// started auth operation retains its own fail-closed invalidation semantics.
  Future<TimewebStopResult> stop() {
    if (_closeFlight != null) {
      return Future.value(
        const TimewebStopResult(
          protectedStateSafe: false,
          remoteOutcomeUnknown: false,
        ),
      );
    }
    final existing = _stopFlight;
    if (existing != null) return existing;
    if (_closed) {
      return Future.value(
        const TimewebStopResult(
          protectedStateSafe: false,
          remoteOutcomeUnknown: false,
        ),
      );
    }
    _stopping = true;
    _session = null;
    _cancelPrivateMedia(this);
    _cancelCurrentReads(this);
    final editorDrain = _cancelProfileEditorRead(this);
    final ownProfileDrain = _cancelCurrentOwnProfileRead(this);
    final peopleDrain = _cancelPeopleReads(this);
    final adminUsersDrain = _cancelAdminUsersReads(this);
    final photosDrain = _cancelPhotoFlights(this);
    final uploadsDrain = _cancelPhotoUploadFlights(this);
    final mutationDrain = _cancelMutationTransfers(this);
    _mutationReferences.clear();
    return _stopFlight = (() async {
      await Future.wait(_authDrains.toList());
      await _storeTail;
      await editorDrain;
      await ownProfileDrain;
      await peopleDrain;
      await adminUsersDrain;
      await photosDrain;
      await uploadsDrain;
      await mutationDrain;
      _newEpoch();
      _closed = true;
      if (_ownsTransport) _http.close();
      return TimewebStopResult(
        protectedStateSafe: !_secureStoreUnsafe && !_authStoreFailure,
        remoteOutcomeUnknown: _stopAuthUnknown,
      );
    })();
  }

  Future<bool> _finishClose(Future<void> clear) async {
    try {
      await clear;
      _secureStoreUnsafe = false;
      return true;
    } catch (_) {
      _secureStoreUnsafe = true;
      return false;
    }
  }
}
