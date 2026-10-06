part of 'timeweb_auth_client.dart';

const _mutationOperation = TimewebAuthOperation.mutation;
const _mutationMaximumBytes = 65536;
const _mutationMax63 = 9223372036854775807;

enum TimewebMutationKind {
  sendMessage,
  markRead,
  editProfile,
  completeTest,
  editGeography,
  openPersonalChat,
  createMeeting,
  joinMeeting,
  sendMeetingText,
  leaveMeeting,
  kickMeetingParticipant,
  prepareProfilePhoto,
  commitProfilePhoto,
  finishInitialProfile,
}

enum TimewebMutationState { confirmed, declaredFailure, unknown, notFound }

enum TimewebMutationFailure {
  invalidRequest,
  unauthorized,
  notFound,
  conflict,
  rateLimited,
  chatNotFound,
  chatUnavailable,
  personUnavailable,
  quoteUnavailable,
  sequenceAhead,
  profileChanged,
  testAlreadyCompleted,
  profileIncomplete,
  profileNotReady,
  meetingUnavailable,
  meetingNotFound,
  participantNotFound,
  organizerRequired,
  cannotKickSelf,
  photoLimitReached,
  photoNotFound,
  photoVerificationFailed,
  photoUnavailable,
  photoNotReady,
  registrationAlreadySaved,
  registrationAlreadyCompleted,
}

/// Only the reviewed editable fields. Original strings are preserved for the
/// durable request hash; validation never silently trims or rewrites a journal.
final class TimewebProfileChanges {
  TimewebProfileChanges({
    String? fullName,
    int? age,
    int? rost,
    String? about,
    String? hobbi,
    bool? deti,
    String? pol,
    String? relationStatus,
  }) {
    final fields = <String, dynamic>{
      if (fullName != null) 'fullName': fullName,
      if (age != null) 'age': age,
      if (rost != null) 'rost': rost,
      if (about != null) 'about': about,
      if (hobbi != null) 'hobbi': hobbi,
      if (deti != null) 'deti': deti,
      if (pol != null) 'pol': pol,
      if (relationStatus != null) 'relationStatus': relationStatus,
    };
    if (fields.isEmpty) throw ArgumentError('Empty profile changes.');
    for (final entry in fields.entries) {
      final key = entry.key, value = entry.value;
      if (key == 'deti') continue;
      if (key == 'age' || key == 'rost') {
        if (value < (key == 'age' ? 18 : 1) ||
            value > (key == 'age' ? 100 : 300)) {
          throw ArgumentError('Invalid profile changes.');
        }
      } else {
        final multiline = key == 'about' || key == 'hobbi';
        final normalized = (value as String).trim();
        if (!_mutationText(
              value,
              maximum: multiline
                  ? 4096
                  : key == 'fullName'
                  ? 1000
                  : 191,
              multiline: multiline,
            ) ||
            normalized.runes.length < (multiline ? 20 : 1)) {
          throw ArgumentError('Invalid profile changes.');
        }
      }
    }
    _fields = Map.unmodifiable(fields);
  }
  late final Map<String, dynamic> _fields;
  @override
  String toString() => 'TimewebProfileChanges(<redacted>)';
}

/// Counts from the existing 80-question test; the server assigns the group.
final class TimewebTemperamentScores {
  TimewebTemperamentScores({
    required int brown,
    required int red,
    required int blue,
    required int white,
  }) {
    final values = [brown, red, blue, white];
    if (values.any((v) => v < 0 || v > 20) ||
        values.fold<int>(0, (a, b) => a + b) < 20) {
      throw ArgumentError('Select at least 20 of the 80 statements.');
    }
    _values = Map.unmodifiable({
      'brown': brown,
      'red': red,
      'blue': blue,
      'white': white,
    });
  }
  late final Map<String, int> _values;
  @override
  String toString() => 'TimewebTemperamentScores(<redacted>)';
}

/// The caller supplies and durably retains its UUID and exact input before a
/// tap. No URL, authority, bearer, balance, role or arbitrary JSON is accepted.
final class TimewebMutationRequest {
  TimewebMutationRequest._(
    this.kind,
    this.operationId,
    this._payload,
    this._segments, {
    TimewebGeographyChanges? geography,
    TimewebInitialProfileRequest? initialProfile,
  }) : _geography = geography, _initialProfile = initialProfile {
    if (!RegExp(
      r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
    ).hasMatch(operationId)) {
      throw ArgumentError('Invalid mutation operation ID.');
    }
    requestHash = crypto.sha256
        .convert(utf8.encode(_mutationCanonical(_payload)))
        .toString();
    final body = _wireBody;
    if (utf8.encode(jsonEncode(body)).length > _mutationMaximumBytes) {
      throw ArgumentError('Mutation body exceeds its bound.');
    }
  }
  factory TimewebMutationRequest.sendMessage({
    required String operationId,
    required String chatId,
    required String text,
    String? quoteMessageId,
  }) {
    if (!_mutationId(chatId) ||
        !_mutationText(text) ||
        (quoteMessageId != null && !_mutationId(quoteMessageId))) {
      throw ArgumentError('Invalid message mutation.');
    }
    return TimewebMutationRequest._(
      TimewebMutationKind.sendMessage,
      operationId,
      Map.unmodifiable({
        'chatId': chatId,
        'text': text,
        'quoteMessageId': quoteMessageId,
      }),
      ['v1', 'runtime', 'chats', chatId, 'messages'],
    );
  }
  factory TimewebMutationRequest.markRead({
    required String operationId,
    required String chatId,
    required int throughSequence,
  }) {
    if (!_mutationId(chatId) || !_mutationInteger(throughSequence)) {
      throw ArgumentError('Invalid read mutation.');
    }
    return TimewebMutationRequest._(
      TimewebMutationKind.markRead,
      operationId,
      Map.unmodifiable({'chatId': chatId, 'throughSequence': throughSequence}),
      ['v1', 'runtime', 'chats', chatId, 'read'],
    );
  }
  factory TimewebMutationRequest.editOwnProfile({
    required String operationId,
    required String expectedUpdatedAt,
    required TimewebProfileChanges changes,
  }) {
    if (!_mutationStamp(expectedUpdatedAt))
      throw ArgumentError('Invalid profile revision.');
    return TimewebMutationRequest._(
      TimewebMutationKind.editProfile,
      operationId,
      Map.unmodifiable({
        'expectedUpdatedAt': expectedUpdatedAt,
        'changes': changes._fields,
      }),
      ['v1', 'runtime', 'me', 'profile'],
    );
  }
  factory TimewebMutationRequest.completeOwnTemperament({
    required String operationId,
    required String expectedUpdatedAt,
    required TimewebTemperamentScores scores,
  }) {
    if (!_mutationStamp(expectedUpdatedAt)) {
      throw ArgumentError('Invalid profile revision.');
    }
    return TimewebMutationRequest._(
      TimewebMutationKind.completeTest,
      operationId,
      Map.unmodifiable({
        'expectedUpdatedAt': expectedUpdatedAt,
        'scores': scores._values,
      }),
      ['v1', 'runtime', 'me', 'temperament'],
    );
  }
  factory TimewebMutationRequest.editOwnGeography({
    required String operationId,
    required String expectedUpdatedAt,
    required TimewebGeographyChanges changes,
  }) {
    if (!_mutationStamp(expectedUpdatedAt)) {
      throw ArgumentError('Invalid profile revision.');
    }
    return TimewebMutationRequest._(
      TimewebMutationKind.editGeography,
      operationId,
      Map.unmodifiable({
        'expectedUpdatedAt': expectedUpdatedAt,
        'changes': changes._fields,
      }),
      ['v1', 'runtime', 'me', 'geography'],
      geography: changes,
    );
  }
  factory TimewebMutationRequest.openPersonalChat({
    required String operationId,
    required String targetUid,
  }) {
    if (!_mutationId(targetUid)) {
      throw ArgumentError('Invalid personal chat target.');
    }
    return TimewebMutationRequest._(
      TimewebMutationKind.openPersonalChat,
      operationId,
      Map.unmodifiable({'targetUid': targetUid}),
      ['v1', 'runtime', 'personal-chats'],
    );
  }
  factory TimewebMutationRequest.createMeeting({
    required String operationId,
    required TimewebMeetingCreateRequest request,
  }) => TimewebMutationRequest._(
    TimewebMutationKind.createMeeting, operationId, request.fields,
    ['v1', 'runtime', 'meetings'],
  );
  factory TimewebMutationRequest.joinMeeting({required String operationId, required String meetingId}) {
    TimewebMeetingJoinRequest(meetingId: meetingId);
    return TimewebMutationRequest._(TimewebMutationKind.joinMeeting, operationId,
      Map.unmodifiable({'meetingId': meetingId}), ['v1', 'runtime', 'meetings', 'join']);
  }
  factory TimewebMutationRequest.sendMeetingText({required String operationId, required String meetingId, required String text}) {
    TimewebMeetingTextRequest(meetingId: meetingId, text: text);
    return TimewebMutationRequest._(TimewebMutationKind.sendMeetingText, operationId,
      Map.unmodifiable({'meetingId': meetingId, 'text': text}), ['v1', 'runtime', 'meetings', meetingId, 'messages']);
  }
  factory TimewebMutationRequest.leaveMeeting({required String operationId, required String meetingId}) {
    TimewebMeetingLeaveRequest(meetingId: meetingId);
    return TimewebMutationRequest._(TimewebMutationKind.leaveMeeting, operationId,
      Map.unmodifiable({'meetingId': meetingId}), ['v1', 'runtime', 'meetings', 'leave']);
  }
  factory TimewebMutationRequest.kickMeetingParticipant({required String operationId, required String meetingId, required String targetUid}) {
    TimewebMeetingKickRequest(meetingId: meetingId, targetUid: targetUid);
    return TimewebMutationRequest._(TimewebMutationKind.kickMeetingParticipant, operationId,
      Map.unmodifiable({'meetingId': meetingId, 'targetUid': targetUid}), ['v1', 'runtime', 'meetings', 'kick']);
  }
  factory TimewebMutationRequest.finishInitialProfile({required String operationId,required TimewebInitialProfileRequest request}) => TimewebMutationRequest._(TimewebMutationKind.finishInitialProfile,operationId,request.fields,['v1','runtime','me','registration'],initialProfile:request);
  factory TimewebMutationRequest.prepareProfilePhoto({required String operationId, required TimewebPhotoMetadata metadata}) =>
    TimewebMutationRequest._(TimewebMutationKind.prepareProfilePhoto,operationId,metadata.fields,['v1','runtime','profile','photos','prepare']);
  factory TimewebMutationRequest.commitProfilePhoto({required String operationId,required String prepareOperationId,required String mediaId}) {
    if(!_uploadUuid(prepareOperationId)||!_uploadMid(mediaId)) { throw ArgumentError('Invalid original photo.'); }
    return TimewebMutationRequest._(TimewebMutationKind.commitProfilePhoto,operationId,Map.unmodifiable({'prepareOperationId':prepareOperationId,'mediaId':mediaId}),['v1','runtime','profile','photos','commit']);
  }
  final TimewebMutationKind kind;
  final String operationId;
  final Map<String, dynamic> _payload;
  final List<String> _segments;
  final TimewebGeographyChanges? _geography;
  final TimewebInitialProfileRequest? _initialProfile;
  late final String requestHash;
  String get operation => switch (kind) {
    TimewebMutationKind.sendMessage => 'chat.send-text.v1',
    TimewebMutationKind.markRead => 'chat.mark-read.v1',
    TimewebMutationKind.editProfile => 'profile.edit.v1',
    TimewebMutationKind.completeTest => 'profile.complete-test.v1',
    TimewebMutationKind.editGeography => 'profile.edit-geography.v1',
    TimewebMutationKind.openPersonalChat => 'chat.open-personal.v1',
    TimewebMutationKind.createMeeting => 'meeting.create.v1',
    TimewebMutationKind.joinMeeting => 'meeting.join.v1',
    TimewebMutationKind.sendMeetingText => 'meeting.send-text.v1',
    TimewebMutationKind.leaveMeeting => 'meeting.leave.v1',
    TimewebMutationKind.kickMeetingParticipant => 'meeting.kick.v1',
    TimewebMutationKind.prepareProfilePhoto => 'profile.photo.prepare.v1',
    TimewebMutationKind.commitProfilePhoto => 'profile.photo.commit.v1',
    TimewebMutationKind.finishInitialProfile => 'profile.finish-registration.v1',
  };
  Map<String, dynamic> get _wireBody => {
    'operationId': operationId,
    for (final entry in _payload.entries)
      if (entry.key != 'chatId' && !(kind == TimewebMutationKind.sendMeetingText && entry.key == 'meetingId')) entry.key: entry.value,
  };
  @override
  String toString() => 'TimewebMutationRequest(<redacted>)';
}

/// Binding a recovered journal requires its original owner explicitly. A/B or
/// ABA cannot reuse a reference. Binding performs no network or persistence.
final class TimewebMutationReference {
  TimewebMutationReference._(
    this._owner,
    this._epoch,
    this._uid,
    this._request,
  );
  final TimewebAuthClient _owner;
  final int _epoch;
  final String _uid;
  final TimewebMutationRequest _request;
  Future<TimewebMutationResult>? _postFlight, _lookupFlight;
  TimewebMutationResult? _settledResult;
  bool _attempted = false;
  void requireCurrent() {
    _owner._checkEpoch(_epoch, _mutationOperation);
    if (_owner._secureStoreUnsafe || _owner._session?.uid != _uid) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.staleSession,
      );
    }
  }

  String get operationId {
    requireCurrent();
    return _request.operationId;
  }

  String get operation {
    requireCurrent();
    return _request.operation;
  }

  String get requestHash {
    requireCurrent();
    return _request.requestHash;
  }

  @override
  String toString() => 'TimewebMutationReference(<redacted>)';
}

final class TimewebMutationResult {
  TimewebMutationResult._(
    this._reference,
    this._state,
    this._status, {
    TimewebMutationFailure? failure,
    TimewebAuthError? unknownReason,
    bool replayed = false,
    int? revision,
    TimewebSentMessageReceipt? message,
    TimewebMarkReadReceipt? read,
    TimewebProfileEditReceipt? profile,
    TimewebCompletedTemperamentReceipt? temperament,
    TimewebGeographyReceipt? geography,
    TimewebOpenedPersonalChatReceipt? personalChat,
    TimewebMeetingCreateReceipt? meeting,
    TimewebMeetingJoinReceipt? joinedMeeting,
    TimewebSentMeetingMessageReceipt? meetingMessage,
    TimewebMeetingLeaveReceipt? leftMeeting,
    TimewebMeetingKickReceipt? kickedParticipant,
    TimewebInitialProfileReceipt? initialProfile,
    TimewebPreparedPhotoReceipt? preparedPhoto,
    TimewebCommittedPhotoReceipt? committedPhoto,
    String? updatedAt,
    bool receiptConfirmed = false,
    bool originalPostDeclaredFailure = false,
  }) : _failure = failure,
       _unknownReason = unknownReason,
       _replayed = replayed,
       _revision = revision,
       _message = message,
       _read = read,
       _profile = profile,
       _temperament = temperament,
       _geography = geography,
       _personalChat = personalChat,
       _meeting = meeting,
       _joinedMeeting = joinedMeeting,
       _meetingMessage = meetingMessage,
       _leftMeeting = leftMeeting,
       _kickedParticipant = kickedParticipant,
       _initialProfile = initialProfile,
       _preparedPhoto = preparedPhoto,
       _committedPhoto = committedPhoto,
       _updatedAt = updatedAt,
       _receiptConfirmed = receiptConfirmed,
       _originalPostDeclaredFailure = originalPostDeclaredFailure;
  final TimewebMutationReference _reference;
  final TimewebMutationState _state;
  final int? _status;
  final TimewebMutationFailure? _failure;
  final TimewebAuthError? _unknownReason;
  final bool _replayed;
  final int? _revision;
  final TimewebSentMessageReceipt? _message;
  final TimewebMarkReadReceipt? _read;
  final TimewebProfileEditReceipt? _profile;
  final TimewebCompletedTemperamentReceipt? _temperament;
  final TimewebGeographyReceipt? _geography;
  final TimewebOpenedPersonalChatReceipt? _personalChat;
  final TimewebMeetingCreateReceipt? _meeting;
  final TimewebMeetingJoinReceipt? _joinedMeeting;
  final TimewebSentMeetingMessageReceipt? _meetingMessage;
  final TimewebMeetingLeaveReceipt? _leftMeeting;
  final TimewebMeetingKickReceipt? _kickedParticipant;
  final TimewebInitialProfileReceipt? _initialProfile;
  final TimewebPreparedPhotoReceipt? _preparedPhoto;
  final TimewebCommittedPhotoReceipt? _committedPhoto;
  final String? _updatedAt;
  final bool _receiptConfirmed;
  final bool _originalPostDeclaredFailure;
  bool get _acknowledgeable =>
      _receiptConfirmed || _originalPostDeclaredFailure;
  void requireCurrent() => _reference.requireCurrent();
  TimewebMutationReference get reference {
    requireCurrent();
    return _reference;
  }

  TimewebMutationState get state {
    requireCurrent();
    return _state;
  }

  int? get statusCode {
    requireCurrent();
    return _status;
  }

  TimewebMutationFailure? get failure {
    requireCurrent();
    return _failure;
  }

  TimewebAuthError? get unknownReason {
    requireCurrent();
    return _unknownReason;
  }

  bool get replayed {
    requireCurrent();
    return _replayed;
  }

  bool get hasReceipt {
    requireCurrent();
    return _receiptConfirmed;
  }

  bool get canAcknowledge {
    requireCurrent();
    return _acknowledgeable;
  }

  int? get entityRevision {
    requireCurrent();
    return _revision;
  }

  String? get conflictUpdatedAt {
    requireCurrent();
    return _updatedAt;
  }

  TimewebSentMessageReceipt? get message {
    requireCurrent();
    return _message;
  }

  TimewebMarkReadReceipt? get readReceipt {
    requireCurrent();
    return _read;
  }

  TimewebProfileEditReceipt? get editedProfile {
    requireCurrent();
    return _profile;
  }

  TimewebCompletedTemperamentReceipt? get completedTemperament {
    requireCurrent();
    return _temperament;
  }

  TimewebGeographyReceipt? get editedGeography {
    requireCurrent();
    return _geography;
  }

  TimewebOpenedPersonalChatReceipt? get openedPersonalChat {
    requireCurrent();
    return _personalChat;
  }

  TimewebMeetingCreateReceipt? get createdMeeting {
    requireCurrent();
    return _meeting;
  }

  TimewebMeetingJoinReceipt? get joinedMeeting {
    requireCurrent();
    return _joinedMeeting;
  }

  TimewebSentMeetingMessageReceipt? get sentMeetingMessage {
    requireCurrent();
    return _meetingMessage;
  }

  TimewebMeetingLeaveReceipt? get leftMeeting { requireCurrent(); return _leftMeeting; }
  TimewebMeetingKickReceipt? get kickedParticipant { requireCurrent(); return _kickedParticipant; }

  TimewebInitialProfileReceipt? get initialProfile { requireCurrent(); return _initialProfile; }
  TimewebPreparedPhotoReceipt? get preparedPhoto { requireCurrent(); return _preparedPhoto; }
  TimewebCommittedPhotoReceipt? get committedPhoto { requireCurrent(); return _committedPhoto; }

  @override
  String toString() => 'TimewebMutationResult(<redacted>)';
}

final class TimewebCompletedTemperamentReceipt {
  TimewebCompletedTemperamentReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  String get uid {
    _check();
    return _data['uid'];
  }

  String get primaryGroup {
    _check();
    return _data['primaryGroup'];
  }

  String get updatedAt {
    _check();
    return _data['updatedAt'];
  }

  bool get isRegistrationEnd {
    _check();
    return true;
  }

  TimewebOnboarding get onboarding {
    _check();
    return TimewebOnboarding.search;
  }

  String get profileAuthority {
    _check();
    return 'canonical-current-v1';
  }

  @override
  String toString() => 'TimewebCompletedTemperamentReceipt(<redacted>)';
}

final class TimewebQuotedMessage {
  TimewebQuotedMessage._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  String get messageId {
    _check();
    return _data['messageId'];
  }

  int get sequence {
    _check();
    return _data['sequence'];
  }

  String get senderUid {
    _check();
    return _data['senderUid'];
  }

  String? get text {
    _check();
    return _data['text'];
  }

  @override
  String toString() => 'TimewebQuotedMessage(<redacted>)';
}

final class TimewebSentMessageReceipt {
  TimewebSentMessageReceipt._(this._data, this._check, this._quote);
  final Map<String, dynamic> _data;
  final void Function() _check;
  final TimewebQuotedMessage? _quote;
  String get chatId {
    _check();
    return _data['chatId'];
  }

  String get messageId {
    _check();
    return _data['messageId'];
  }

  int get sequence {
    _check();
    return _data['sequence'];
  }

  String get senderUid {
    _check();
    return _data['senderUid'];
  }

  String get text {
    _check();
    return _data['text'];
  }

  String get createdAt {
    _check();
    return _data['createdAt'];
  }

  int get chatRevision {
    _check();
    return _data['chatRevision'];
  }

  List<int> get eventIds {
    _check();
    return List<int>.unmodifiable(_data['eventIds']);
  }

  TimewebQuotedMessage? get quote {
    _check();
    return _quote;
  }

  @override
  String toString() => 'TimewebSentMessageReceipt(<redacted>)';
}

final class TimewebMarkReadReceipt {
  TimewebMarkReadReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  String get chatId {
    _check();
    return _data['chatId'];
  }

  int get readThroughSequence {
    _check();
    return _data['readThroughSequence'];
  }

  bool get changed {
    _check();
    return _data['changed'];
  }

  int get chatRevision {
    _check();
    return _data['chatRevision'];
  }

  List<int> get eventIds {
    _check();
    return List<int>.unmodifiable(_data['eventIds']);
  }

  @override
  String toString() => 'TimewebMarkReadReceipt(<redacted>)';
}

final class TimewebProfileEditReceipt {
  TimewebProfileEditReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  String? get fullName {
    _check();
    return _data['fullName'];
  }

  int? get age {
    _check();
    return _data['age'];
  }

  int? get rost {
    _check();
    return _data['rost'];
  }

  String? get about {
    _check();
    return _data['about'];
  }

  String? get hobbi {
    _check();
    return _data['hobbi'];
  }

  bool? get deti {
    _check();
    return _data['deti'];
  }

  String? get pol {
    _check();
    return _data['pol'];
  }

  String? get relationStatus {
    _check();
    return _data['relationStatus'];
  }

  bool? get profileDetailsSaved {
    _check();
    return _data['profileDetailsSaved'];
  }

  bool? get isRegistrationEnd {
    _check();
    return _data['isRegistrationEnd'];
  }

  String get updatedAt {
    _check();
    return _data['updatedAt'];
  }

  @override
  String toString() => 'TimewebProfileEditReceipt(<redacted>)';
}

TimewebMutationReference _bindMutation(
  TimewebAuthClient owner,
  TimewebMutationRequest request,
  String expectedOwnerUid,
) {
  owner._checkEnabled(_mutationOperation);
  if (!owner.configuration.runtimeWritesEnabled) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.disabled,
    );
  }
  if (owner._session == null || owner._secureStoreUnsafe) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.notAuthenticated,
    );
  }
  if (owner._session!.uid != expectedOwnerUid) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.staleSession,
    );
  }
  request._initialProfile?.requireOwner(owner, expectedOwnerUid);
  final key = '${request.operation}\u0000${request.operationId}';
  final prior = owner._mutationReferences[key];
  if (prior != null) {
    prior.requireCurrent();
    if (prior._request.requestHash != request.requestHash) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.invalidRequest,
      );
    }
    return prior;
  }
  if (owner._mutationReferences.length >= 64) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.unavailable,
    );
  }
  return owner._mutationReferences[key] = TimewebMutationReference._(
    owner,
    owner._epoch,
    expectedOwnerUid,
    request,
  );
}

void _checkMutationOwner(
  TimewebAuthClient owner,
  TimewebMutationReference reference,
) {
  owner._checkEnabled(_mutationOperation);
  if (!owner.configuration.runtimeWritesEnabled) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.disabled,
    );
  }
  if (!identical(owner, reference._owner)) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.invalidRequest,
    );
  }
  reference.requireCurrent();
}

void _acknowledgeMutation(
  TimewebAuthClient owner,
  TimewebMutationReference reference,
) {
  _checkMutationOwner(owner, reference);
  if (reference._settledResult?._acknowledgeable != true) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.invalidRequest,
    );
  }
  final key =
      '${reference._request.operation}\u0000${reference._request.operationId}';
  if (identical(owner._mutationReferences[key], reference)) {
    owner._mutationReferences.remove(key);
    if (_meetingMembershipKind(reference._request.kind) && reference._settledResult?._state == TimewebMutationState.confirmed) {
      _invalidateMeetingReads(owner);
    }
  }
  // Receipts and definite original POST 400/401/404/409/429 may be retired
  // after durable caller acknowledgement. Unknown/not-found/lookup failures
  // cannot. Old references retain their outcome and never become a fresh POST.
  // A later bind after retirement still relies on the server's UUID/hash lock;
  // the caller must never reuse that durable UUID for a different intent.
}

TimewebMutationResult _retainMutationOutcome(
  TimewebMutationReference reference,
  TimewebMutationResult result,
) {
  final confirmed = reference._settledResult;
  // Personal lookup must pass its fresh visibility/membership guard. A
  // transport failure cannot fall back to an earlier route's cached receipt.
  if (confirmed?._acknowledgeable == true &&
      !result._receiptConfirmed &&
      !const {TimewebMutationKind.openPersonalChat,
        TimewebMutationKind.createMeeting, TimewebMutationKind.joinMeeting,
        TimewebMutationKind.sendMeetingText, TimewebMutationKind.leaveMeeting,
        TimewebMutationKind.kickMeetingParticipant, TimewebMutationKind.prepareProfilePhoto, TimewebMutationKind.commitProfilePhoto, TimewebMutationKind.finishInitialProfile}.contains(reference._request.kind)) {
    return confirmed!;
  }
  reference._settledResult = result;
  reference._postFlight = Future.value(result);
  return result;
}

Future<TimewebMutationResult> _mutate(
  TimewebAuthClient owner,
  TimewebMutationReference reference,
) {
  try {
    _checkMutationOwner(owner, reference);
    final existing = reference._postFlight;
    if (existing != null) return existing;
    final future = _executeMutation(reference);
    reference._postFlight = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {
          if (!reference._attempted &&
              identical(reference._postFlight, future)) {
            reference._postFlight = null;
          }
        },
      ),
    );
    return future;
  } on TimewebAuthException catch (error) {
    return Future.error(error);
  }
}

Future<TimewebMutationResult> _executeMutation(
  TimewebMutationReference reference,
) async {
  final owner = reference._owner;
  try {
    var session = owner._session!;
    if (!owner
        ._clock()
        .add(owner.accessExpirySkew)
        .isBefore(session.accessExpiresAt)) {
      session = await owner.refresh();
      reference.requireCurrent();
    }
    // Before this point a local rejection has not sent the mutation. From this
    // point on, timeout/transport loss never permits this reference to POST again.
    if (owner._inflightRequests >= 4) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.unavailable,
      );
    }
    reference.requireCurrent();
    reference._attempted = true;
    final reply = await _mutationTransfer(
      owner,
      'POST',
      owner.configuration.endpoint.replace(
        pathSegments: reference._request._segments,
      ),
      session.accessToken,
      body: reference._request._wireBody,
    );
    reference.requireCurrent();
    return _retainMutationOutcome(
      reference,
      _decodeMutationReply(reference, reply, lookup: false),
    );
  } on TimewebAuthException catch (error) {
    reference.requireCurrent();
    if (!reference._attempted) rethrow;
    return _retainMutationOutcome(
      reference,
      TimewebMutationResult._(
        reference,
        TimewebMutationState.unknown,
        null,
        unknownReason: error.error,
      ),
    );
  }
}

Future<TimewebMutationResult> _reconcileMutation(
  TimewebAuthClient owner,
  TimewebMutationReference reference,
) {
  try {
    _checkMutationOwner(owner, reference);
    final existing = reference._lookupFlight;
    if (existing != null) return existing;
    // A recovered journal's absent receipt does not prove that a previous
    // uncertain POST cannot still commit. Lookup never unlocks another POST.
    reference._attempted = true;
    reference._postFlight ??= Future.value(
      TimewebMutationResult._(
        reference,
        TimewebMutationState.unknown,
        null,
        unknownReason: TimewebAuthError.unavailable,
      ),
    );
    final future = _executeMutationLookup(reference);
    reference._lookupFlight = future;
    unawaited(
      future.then<void>(
        (_) {
          reference._lookupFlight = null;
        },
        onError: (Object _, StackTrace __) {
          reference._lookupFlight = null;
        },
      ),
    );
    return future;
  } on TimewebAuthException catch (error) {
    return Future.error(error);
  }
}

Future<TimewebMutationResult> _executeMutationLookup(
  TimewebMutationReference reference,
) async {
  final owner = reference._owner;
  var session = owner._session!;
  if (!owner
      ._clock()
      .add(owner.accessExpirySkew)
      .isBefore(session.accessExpiresAt)) {
    session = await owner.refresh();
    reference.requireCurrent();
  }
  final uri = owner.configuration.endpoint.replace(
    pathSegments: [
      'v1',
      'runtime',
      'operations',
      reference._request.operation,
      reference._request.operationId,
    ],
    queryParameters: {'requestHash': reference._request.requestHash},
  );
  var reply = await _mutationTransfer(owner, 'GET', uri, session.accessToken);
  reference.requireCurrent();
  if (reply.status == 401) {
    if (owner._session?.accessToken == session.accessToken)
      await owner.refresh();
    reference.requireCurrent();
    session = owner._session!;
    reply = await _mutationTransfer(owner, 'GET', uri, session.accessToken);
    reference.requireCurrent();
  }
  final result = _decodeMutationReply(reference, reply, lookup: true);
  return _retainMutationOutcome(reference, result);
}

final class _MutationTransfer {
  final abort = Completer<void>(), done = Completer<void>();
  bool cancelled = false;
  Future<void> Function()? cancelReader;
  void cancel() {
    cancelled = true;
    if (!abort.isCompleted) abort.complete();
    unawaited(cancelReader?.call().catchError((Object _) {}));
  }

  void check() {
    if (cancelled) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.staleSession,
      );
    }
  }
}

Future<void> _cancelMutationTransfers(TimewebAuthClient owner) async {
  final pending = owner._mutationTransfers.toList();
  for (final transfer in pending) {
    transfer.cancel();
  }
  await Future.wait(pending.map((transfer) => transfer.done.future));
}

Future<_Reply> _mutationTransfer(
  TimewebAuthClient owner,
  String method,
  Uri uri,
  String bearer, {
  Map<String, dynamic>? body,
}) async {
  if (owner._inflightRequests >= 4) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.unavailable,
    );
  }
  final flight = _MutationTransfer();
  owner._mutationTransfers.add(flight);
  final abort = flight.abort;
  final request = http.AbortableRequest(method, uri, abortTrigger: abort.future)
    ..followRedirects = false
    ..headers['Accept'] = 'application/json'
    ..headers['Authorization'] = 'Bearer $bearer'
    ..headers['Cache-Control'] = 'no-store';
  if (body != null) {
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.body = jsonEncode(body);
  }
  owner._inflightRequests++;
  var abandoned = false;
  StreamIterator<List<int>>? reader;
  Future<void>? cancellation;
  Future<void> cancelReader() {
    final current = reader;
    if (current == null) return Future.value();
    return cancellation ??= current.cancel();
  }

  flight.cancelReader = cancelReader;
  Future<_Reply> transfer() async {
    try {
      final response = await owner._http.send(request);
      reader = StreamIterator(response.stream);
      var moving = reader!.moveNext();
      unawaited(
        moving.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
      );
      flight.check();
      if (abandoned)
        throw const TimewebAuthException(
          _mutationOperation,
          TimewebAuthError.deadline,
        );
      if (response.isRedirect ||
          response.statusCode >= 300 && response.statusCode < 400) {
        throw const TimewebAuthException(
          _mutationOperation,
          TimewebAuthError.invalidResponse,
        );
      }
      if (response.statusCode == 401) return _Reply(401, null);
      if (!const [200, 201, 400, 404, 409, 429].contains(response.statusCode)) {
        return _Reply(response.statusCode, null);
      }
      final mime = response.headers['content-type']?.toLowerCase() ?? '';
      final cache = (response.headers['cache-control'] ?? '')
          .toLowerCase()
          .split(',')
          .map((v) => v.trim());
      if (mime.split(';').first.trim() != 'application/json' ||
          !cache.contains('no-store') ||
          (response.contentLength != null &&
              response.contentLength! > _mutationMaximumBytes)) {
        throw const TimewebAuthException(
          _mutationOperation,
          TimewebAuthError.invalidResponse,
        );
      }
      final bytes = <int>[];
      while (await moving) {
        flight.check();
        if (abandoned)
          throw const TimewebAuthException(
            _mutationOperation,
            TimewebAuthError.deadline,
          );
        final chunk = reader!.current;
        if (bytes.length + chunk.length > _mutationMaximumBytes) {
          throw const TimewebAuthException(
            _mutationOperation,
            TimewebAuthError.invalidResponse,
          );
        }
        bytes.addAll(chunk);
        moving = reader!.moveNext();
      }
      if (abandoned)
        throw const TimewebAuthException(
          _mutationOperation,
          TimewebAuthError.deadline,
        );
      flight.check();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const TimewebAuthException(
          _mutationOperation,
          TimewebAuthError.invalidResponse,
        );
      }
      return _Reply(response.statusCode, decoded);
    } finally {
      try {
        if (!abort.isCompleted) abort.complete();
        await cancelReader();
      } finally {
        owner._inflightRequests--;
        owner._mutationTransfers.remove(flight);
        if (!flight.done.isCompleted) flight.done.complete();
      }
    }
  }

  try {
    return await transfer().timeout(owner.requestDeadline);
  } on TimeoutException {
    abandoned = true;
    if (!abort.isCompleted) abort.complete();
    unawaited(cancelReader().catchError((Object _) {}));
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.deadline,
    );
  } on FormatException {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.invalidResponse,
    );
  } on TimewebAuthException {
    rethrow;
  } catch (_) {
    throw const TimewebAuthException(
      _mutationOperation,
      TimewebAuthError.network,
    );
  }
}

String _mutationCanonical(Object? value) {
  Object? canonical(Object? item) {
    if (item is Map<String, dynamic>) {
      final keys = item.keys.toList()..sort();
      return {for (final key in keys) key: canonical(item[key])};
    }
    if (item is List) return item.map(canonical).toList();
    return item;
  }

  return jsonEncode(canonical(value));
}

bool _mutationInteger(Object? value, {bool positive = false}) =>
    value is int && value >= (positive ? 1 : 0) && value <= _mutationMax63;
bool _mutationId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.runes.length <= 191 &&
    utf8.encode(value).length <= 764 &&
    !const ['.', '..'].contains(value) &&
    !value.contains('/') &&
    utf8.decode(utf8.encode(value)) == value &&
    !value.runes.any((r) => r < 32 || r == 127);
bool _mutationText(
  Object? value, {
  int maximum = 4096,
  bool multiline = true,
}) =>
    value is String &&
    value.isNotEmpty &&
    value.trim().isNotEmpty &&
    value.runes.length <= maximum &&
    utf8.encode(value).length <= maximum * 4 &&
    utf8.decode(utf8.encode(value)) == value &&
    !value.runes.any(
      (r) =>
          (r < 32 && (!multiline || !const [9, 10, 13].contains(r))) ||
          r == 127,
    );
bool _mutationStamp(Object? value) {
  if (value is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$').hasMatch(value))
    return false;
  final date = DateTime.tryParse(value);
  return date != null &&
      date.year >= 1 &&
      date.year.toString().padLeft(4, '0') == value.substring(0, 4) &&
      date.month == int.parse(value.substring(5, 7)) &&
      date.day == int.parse(value.substring(8, 10)) &&
      date.hour == int.parse(value.substring(11, 13)) &&
      date.minute == int.parse(value.substring(14, 16)) &&
      date.second == int.parse(value.substring(17, 19));
}

TimewebMutationResult _decodeMutationReply(
  TimewebMutationReference ref,
  _Reply reply, {
  required bool lookup,
}) {
  ref.requireCurrent();
  if (reply.status == 401) {
    if (!lookup && const {TimewebMutationKind.createMeeting, TimewebMutationKind.joinMeeting, TimewebMutationKind.sendMeetingText, TimewebMutationKind.leaveMeeting,
        TimewebMutationKind.kickMeetingParticipant, TimewebMutationKind.prepareProfilePhoto, TimewebMutationKind.commitProfilePhoto, TimewebMutationKind.finishInitialProfile}.contains(ref._request.kind)) {
      return TimewebMutationResult._(ref, TimewebMutationState.unknown, 401,
        failure: TimewebMutationFailure.unauthorized,
        unknownReason: TimewebAuthError.unauthorized);
    }
    if (lookup) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.unauthorized,
      );
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      401,
      failure: TimewebMutationFailure.unauthorized,
      originalPostDeclaredFailure: true,
    );
  }
  if (!const [200, 201, 400, 404, 409, 429].contains(reply.status)) {
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.unknown,
      reply.status,
      unknownReason: TimewebAuthError.unavailable,
    );
  }
  final body = reply.body;
  if (body == null) _mutationInvalidReply();
  if (body.containsKey('error')) {
    if (!_mutationExact(body, {'error'}) ||
        !const [400, 404, 409, 429].contains(reply.status)) {
      _mutationInvalidReply();
    }
    if (lookup &&
        ref._request.kind == TimewebMutationKind.openPersonalChat &&
        reply.status == 404 &&
        body['error'] == 'person_unavailable') {
      // A fresh pair-visibility refusal does not alter/prove the original POST.
      // Keep its intent/reference uncertain; do not refresh healthy actor auth.
      return TimewebMutationResult._(
        ref,
        TimewebMutationState.unknown,
        404,
        failure: TimewebMutationFailure.personUnavailable,
        unknownReason: TimewebAuthError.unavailable,
      );
    }
    if (const {TimewebMutationKind.createMeeting, TimewebMutationKind.joinMeeting, TimewebMutationKind.sendMeetingText, TimewebMutationKind.leaveMeeting,
        TimewebMutationKind.kickMeetingParticipant, TimewebMutationKind.prepareProfilePhoto, TimewebMutationKind.commitProfilePhoto, TimewebMutationKind.finishInitialProfile}.contains(ref._request.kind)) {
      // Every short refusal lacks the original operation/hash receipt. Only a
      // matching committed envelope below can retire this durable create intent.
      final failure = switch ((reply.status, body['error'])) {
        (400, 'invalid_request') => TimewebMutationFailure.invalidRequest,
        (404, 'not_found') => TimewebMutationFailure.notFound,
        (404, 'meeting_unavailable') when lookup => TimewebMutationFailure.meetingUnavailable,
        (404, 'meeting_not_found') when const {TimewebMutationKind.joinMeeting, TimewebMutationKind.sendMeetingText, TimewebMutationKind.leaveMeeting,
        TimewebMutationKind.kickMeetingParticipant, TimewebMutationKind.prepareProfilePhoto, TimewebMutationKind.commitProfilePhoto, TimewebMutationKind.finishInitialProfile}.contains(ref._request.kind) => TimewebMutationFailure.meetingNotFound,
        (409, 'operation_conflict') => TimewebMutationFailure.conflict,
        (429, 'rate_limited') => TimewebMutationFailure.rateLimited,
        _ => null,
      };
      return TimewebMutationResult._(ref, TimewebMutationState.unknown, reply.status,
        failure: failure, unknownReason: failure == null
          ? TimewebAuthError.invalidResponse : TimewebAuthError.unavailable);
    }
    final failure = switch ((reply.status, body['error'])) {
      (400, 'invalid_request') => TimewebMutationFailure.invalidRequest,
      (404, 'not_found') => TimewebMutationFailure.notFound,
      (409, 'operation_conflict') => TimewebMutationFailure.conflict,
      (429, 'rate_limited') => TimewebMutationFailure.rateLimited,
      _ => null,
    };
    if (failure == null) _mutationInvalidReply();
    if (lookup) {
      // Refusing a receipt lookup says nothing about the earlier POST outcome.
      // Keep its journal uncertain instead of declaring that write rejected.
      throw TimewebAuthException(_mutationOperation, switch (failure) {
        TimewebMutationFailure.rateLimited => TimewebAuthError.rateLimited,
        TimewebMutationFailure.invalidRequest ||
        TimewebMutationFailure.conflict => TimewebAuthError.invalidRequest,
        _ => TimewebAuthError.unavailable,
      });
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      reply.status,
      failure: failure,
      originalPostDeclaredFailure: true,
    );
  }
  if (!_mutationExact(body, {
        'operation',
        'operationId',
        'requestHash',
        'state',
        'replayed',
        'result',
        'entityRevision',
      }) ||
      body['operation'] != ref._request.operation ||
      body['operationId'] != ref._request.operationId ||
      body['requestHash'] != ref._request.requestHash ||
      body['replayed'] is! bool ||
      (body['entityRevision'] != null &&
          !_mutationInteger(body['entityRevision']))) {
    _mutationInvalidReply();
  }
  if (body['state'] == 'not_found') {
    if (!lookup ||
        reply.status != 200 ||
        body['replayed'] != false ||
        body['result'] != null ||
        body['entityRevision'] != null)
      _mutationInvalidReply();
    return TimewebMutationResult._(ref, TimewebMutationState.notFound, 200);
  }
  if (body['state'] != 'committed' ||
      (lookup && body['replayed'] != true) ||
      body['result'] is! Map<String, dynamic>)
    _mutationInvalidReply();
  final result = body['result'] as Map<String, dynamic>;
  final replayed = body['replayed'] as bool;
  final revision = body['entityRevision'] as int?;
  if (const [404, 409].contains(reply.status)) {
    if(ref._request.kind==TimewebMutationKind.finishInitialProfile) {
      final stamped=const {'profile_changed','registration_already_saved','registration_already_completed'}.contains(result['error']);
      final failure=switch((reply.status,result['error'])) {
        (404,'profile_not_found')=>TimewebMutationFailure.notFound,
        (404,'photo_not_found')=>TimewebMutationFailure.photoNotFound,
        (409,'photo_not_ready')=>TimewebMutationFailure.photoNotReady,
        (409,'profile_changed')=>TimewebMutationFailure.profileChanged,
        (409,'registration_already_saved')=>TimewebMutationFailure.registrationAlreadySaved,
        (409,'registration_already_completed')=>TimewebMutationFailure.registrationAlreadyCompleted,
        _=>null,
      };
      if(!_mutationExact(result,stamped?{'error','updatedAt'}:{'error'})||revision!=null||failure==null||stamped&&!_mutationStamp(result['updatedAt'])){_mutationInvalidReply();}
      return TimewebMutationResult._(ref,TimewebMutationState.declaredFailure,reply.status,failure:failure,replayed:replayed,receiptConfirmed:true,updatedAt:stamped?result['updatedAt']:null);
    }
    if (_photoMutationKind(ref._request.kind)) {
      final commit=ref._request.kind==TimewebMutationKind.commitProfilePhoto;
      final failure=switch((reply.status,result['error'])) {
        (404,'profile_not_found')=>TimewebMutationFailure.notFound,
        (409,'photo_limit_reached')=>TimewebMutationFailure.photoLimitReached,
        (404,'photo_not_found') when commit=>TimewebMutationFailure.photoNotFound,
        (409,'photo_verification_failed') when commit=>TimewebMutationFailure.photoVerificationFailed,
        (409,'photo_unavailable') when commit=>TimewebMutationFailure.photoUnavailable,
        _=>null,
      };
      if(!_mutationExact(result,{'error'})||revision!=null||failure==null){_mutationInvalidReply();}
      return TimewebMutationResult._(ref,TimewebMutationState.declaredFailure,reply.status,failure:failure,replayed:replayed,receiptConfirmed:true);
    }
    if (const {TimewebMutationKind.joinMeeting, TimewebMutationKind.sendMeetingText, TimewebMutationKind.leaveMeeting,
        TimewebMutationKind.kickMeetingParticipant, TimewebMutationKind.prepareProfilePhoto, TimewebMutationKind.commitProfilePhoto, TimewebMutationKind.finishInitialProfile}.contains(ref._request.kind)) {
      final failure = switch ((reply.status, result['error'])) {
        (404, 'meeting_not_found') => TimewebMutationFailure.meetingNotFound,
        (404, 'profile_not_found') => TimewebMutationFailure.notFound,
        (409, 'meeting_unavailable') => TimewebMutationFailure.meetingUnavailable,
        (409, 'profile_not_ready') => TimewebMutationFailure.profileNotReady,
        (404, 'participant_not_found') when _meetingMembershipKind(ref._request.kind) => TimewebMutationFailure.participantNotFound,
        (409, 'organizer_required') when _meetingMembershipKind(ref._request.kind) => TimewebMutationFailure.organizerRequired,
        (409, 'cannot_kick_self') when _meetingMembershipKind(ref._request.kind) => TimewebMutationFailure.cannotKickSelf,
        _ => null,
      };
      if (!_mutationExact(result, {'error'}) || revision != null || failure == null) _mutationInvalidReply();
      return TimewebMutationResult._(ref, TimewebMutationState.declaredFailure, reply.status,
        failure: failure, replayed: replayed, receiptConfirmed: true);
    }
    if (ref._request.kind == TimewebMutationKind.createMeeting) {
      final failure = switch ((reply.status, result['error'])) {
        (404, 'profile_not_found') => TimewebMutationFailure.notFound,
        (409, 'profile_not_ready') => TimewebMutationFailure.profileNotReady,
        (404, 'person_unavailable') when ref._request._payload['type'] == 'индивидуальная'
          => TimewebMutationFailure.personUnavailable,
        _ => null,
      };
      if (!_mutationExact(result, {'error'}) || revision != null || failure == null) _mutationInvalidReply();
      return TimewebMutationResult._(ref, TimewebMutationState.declaredFailure, reply.status,
        failure: failure, replayed: replayed, receiptConfirmed: true);
    }
    final profileChanged = const {
      'profile_changed',
      'test_already_completed',
    }.contains(result['error']);
    if (!_mutationExact(
          result,
          profileChanged ? {'error', 'updatedAt'} : {'error'},
        ) ||
        (profileChanged && !_mutationStamp(result['updatedAt'])) ||
        revision != null) {
      _mutationInvalidReply();
    }
    final failure = switch ((reply.status, result['error'])) {
      (404, 'chat_not_found') => TimewebMutationFailure.chatNotFound,
      (404, 'person_unavailable') => TimewebMutationFailure.personUnavailable,
      (404, 'profile_not_found') => TimewebMutationFailure.notFound,
      (409, 'chat_unavailable') => TimewebMutationFailure.chatUnavailable,
      (409, 'quote_unavailable') => TimewebMutationFailure.quoteUnavailable,
      (409, 'sequence_ahead') => TimewebMutationFailure.sequenceAhead,
      (409, 'profile_changed') => TimewebMutationFailure.profileChanged,
      (409, 'test_already_completed') =>
        TimewebMutationFailure.testAlreadyCompleted,
      (409, 'profile_incomplete') => TimewebMutationFailure.profileIncomplete,
      (409, 'profile_not_ready') => TimewebMutationFailure.profileNotReady,
      _ => null,
    };
    final profileFailure =
        failure == TimewebMutationFailure.profileChanged ||
        failure == TimewebMutationFailure.testAlreadyCompleted ||
        failure == TimewebMutationFailure.profileIncomplete ||
        failure == TimewebMutationFailure.profileNotReady ||
        result['error'] == 'profile_not_found';
    if (failure == null ||
        (failure == TimewebMutationFailure.personUnavailable &&
            ref._request.kind != TimewebMutationKind.openPersonalChat) ||
        (ref._request.kind == TimewebMutationKind.openPersonalChat &&
            !const {
              TimewebMutationFailure.personUnavailable,
              TimewebMutationFailure.chatUnavailable,
            }.contains(failure)) ||
        profileFailure !=
            (const {
              TimewebMutationKind.editProfile,
              TimewebMutationKind.completeTest,
              TimewebMutationKind.editGeography,
            }.contains(ref._request.kind)) ||
        (const {
              TimewebMutationFailure.testAlreadyCompleted,
              TimewebMutationFailure.profileIncomplete,
            }.contains(failure) &&
            ref._request.kind != TimewebMutationKind.completeTest) ||
        (failure == TimewebMutationFailure.profileNotReady &&
            ref._request.kind != TimewebMutationKind.editGeography) ||
        (failure == TimewebMutationFailure.quoteUnavailable &&
            ref._request.kind != TimewebMutationKind.sendMessage) ||
        (failure == TimewebMutationFailure.sequenceAhead &&
            ref._request.kind != TimewebMutationKind.markRead)) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      reply.status,
      failure: failure,
      replayed: replayed,
      updatedAt: profileChanged ? result['updatedAt'] : null,
      receiptConfirmed: true,
    );
  }
  if (!const [200, 201].contains(reply.status)) _mutationInvalidReply();
  final frozen = _immutableJson(result) as Map<String, dynamic>;
  final request = ref._request;
  final check = ref.requireCurrent;
  if(request.kind==TimewebMutationKind.finishInitialProfile) {
    if(reply.status!=200||revision!=null||!_mutationExact(frozen,{'uid','profileDetailsSaved','onboarding','updatedAt','profileAuthority'})||frozen['uid']!=ref._uid||frozen['profileDetailsSaved']!=true||frozen['onboarding']!='test'||frozen['profileAuthority']!='canonical-current-v1'||!_mutationStamp(frozen['updatedAt'])||DateTime.parse(frozen['updatedAt']).compareTo(DateTime.parse(request._payload['expectedUpdatedAt']))<=0){_mutationInvalidReply();}
    return TimewebMutationResult._(ref,TimewebMutationState.confirmed,reply.status,replayed:replayed,initialProfile:TimewebInitialProfileReceipt._(frozen,ref.requireCurrent),receiptConfirmed:true);
  }
  if (_photoMutationKind(request.kind)) { return _decodePhotoMutation(ref,reply.status,frozen,revision,replayed); }
  if (_meetingMembershipKind(request.kind)) {
    return _decodeMeetingMembership(ref, reply.status, frozen, revision, replayed);
  }
  if (request.kind == TimewebMutationKind.sendMeetingText) {
    return _decodeSentMeetingMessage(ref, reply.status, frozen, revision, replayed);
  }
  if (request.kind == TimewebMutationKind.joinMeeting) {
    return _decodeJoinedMeeting(ref, reply.status, frozen, revision, replayed);
  }
  if (request.kind == TimewebMutationKind.createMeeting) {
    return _decodeCreatedMeeting(ref, reply.status, frozen, revision, replayed);
  }
  if (request.kind == TimewebMutationKind.openPersonalChat) {
    return _decodeOpenedPersonalChat(
      ref,
      reply.status,
      frozen,
      revision,
      replayed,
    );
  }
  if (request.kind == TimewebMutationKind.sendMessage) {
    if (!_mutationExact(result, {
          'chatId',
          'messageId',
          'sequence',
          'senderUid',
          'text',
          'quote',
          'createdAt',
          'chatRevision',
          'eventIds',
        }) ||
        result['chatId'] != request._payload['chatId'] ||
        !_mutationId(result['messageId']) ||
        !_mutationInteger(result['sequence'], positive: true) ||
        result['senderUid'] != ref._uid ||
        result['text'] != request._payload['text'] ||
        !_mutationStamp(result['createdAt']) ||
        !_mutationInteger(result['chatRevision']) ||
        revision != result['chatRevision'] ||
        !_mutationEventIds(result['eventIds'], alwaysTwo: true))
      _mutationInvalidReply();
    final quote = result['quote'];
    TimewebQuotedMessage? quoteView;
    if (request._payload['quoteMessageId'] == null) {
      if (quote != null) _mutationInvalidReply();
    } else {
      if (quote is! Map<String, dynamic> ||
          !_mutationExact(quote, {
            'messageId',
            'sequence',
            'senderUid',
            'text',
          }) ||
          quote['messageId'] != request._payload['quoteMessageId'] ||
          !_mutationInteger(quote['sequence'], positive: true) ||
          !_mutationId(quote['senderUid']) ||
          (quote['text'] != null && !_mutationText(quote['text'])))
        _mutationInvalidReply();
      quoteView = TimewebQuotedMessage._(frozen['quote'], check);
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.confirmed,
      reply.status,
      replayed: replayed,
      revision: revision,
      message: TimewebSentMessageReceipt._(frozen, check, quoteView),
      receiptConfirmed: true,
    );
  }
  if (request.kind == TimewebMutationKind.markRead) {
    if (reply.status != 200 ||
        !_mutationExact(result, {
          'chatId',
          'readThroughSequence',
          'changed',
          'chatRevision',
          'eventIds',
        }) ||
        result['chatId'] != request._payload['chatId'] ||
        !_mutationInteger(result['readThroughSequence']) ||
        result['readThroughSequence'] < request._payload['throughSequence'] ||
        result['changed'] is! bool ||
        !_mutationInteger(result['chatRevision']) ||
        revision != result['chatRevision'] ||
        !_mutationEventIds(result['eventIds']) ||
        ((result['changed'] as bool) !=
            (result['eventIds'] as List).isNotEmpty)) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.confirmed,
      200,
      replayed: replayed,
      revision: revision,
      read: TimewebMarkReadReceipt._(frozen, check),
      receiptConfirmed: true,
    );
  }
  if (request.kind == TimewebMutationKind.editGeography) {
    final input = request._geography!;
    if (reply.status != 200 ||
        revision != null ||
        !_mutationExact(result, {
          'uid',
          'country',
          'countryCode',
          'region',
          'updatedAt',
          'profileAuthority',
        }) ||
        result['uid'] != ref._uid ||
        result['country'] != input._country ||
        result['countryCode'] != input.countryCode ||
        result['region'] != input.region ||
        result['profileAuthority'] != 'canonical-current-v1' ||
        !_mutationStamp(result['updatedAt'])) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.confirmed,
      200,
      replayed: replayed,
      geography: TimewebGeographyReceipt._(frozen, check),
      receiptConfirmed: true,
    );
  }
  if (request.kind == TimewebMutationKind.completeTest) {
    if (reply.status != 200 ||
        revision != null ||
        !_mutationExact(result, {
          'uid',
          'primaryGroup',
          'isRegistrationEnd',
          'onboarding',
          'updatedAt',
          'profileAuthority',
        }) ||
        result['uid'] != ref._uid ||
        result['isRegistrationEnd'] != true ||
        result['onboarding'] != 'search' ||
        result['profileAuthority'] != 'canonical-current-v1' ||
        !_mutationStamp(result['updatedAt']) ||
        !_ownProfileGroups.contains(result['primaryGroup'])) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.confirmed,
      200,
      replayed: replayed,
      temperament: TimewebCompletedTemperamentReceipt._(frozen, check),
      receiptConfirmed: true,
    );
  }
  if (reply.status != 200 ||
      revision != null ||
      !_mutationExact(result, {
        'uid',
        'profile',
        'operationId',
        'profileAuthority',
      }) ||
      result['uid'] != ref._uid ||
      result['operationId'] != request.operationId ||
      result['profileAuthority'] != 'canonical-current-v1' ||
      result['profile'] is! Map<String, dynamic> ||
      !_mutationProfile(result['profile'])) {
    _mutationInvalidReply();
  }
  return TimewebMutationResult._(
    ref,
    TimewebMutationState.confirmed,
    200,
    replayed: replayed,
    profile: TimewebProfileEditReceipt._(frozen['profile'], check),
    receiptConfirmed: true,
  );
}

Never _mutationInvalidReply() => throw const TimewebAuthException(
  _mutationOperation,
  TimewebAuthError.invalidResponse,
);
bool _mutationExact(Map<String, dynamic> value, Set<String> fields) =>
    value.length == fields.length && fields.every(value.containsKey);
bool _mutationEventIds(Object? value, {bool alwaysTwo = false}) =>
    value is List &&
    (alwaysTwo ? value.length == 2 : const [0, 2].contains(value.length)) &&
    value.every((v) => _mutationInteger(v, positive: true)) &&
    value.toSet().length == value.length;
bool _mutationProfile(Map<String, dynamic> profile) {
  if (!_mutationExact(profile, {
        'fullName',
        'age',
        'rost',
        'about',
        'hobbi',
        'deti',
        'pol',
        'relationStatus',
        'profileDetailsSaved',
        'isRegistrationEnd',
        'updatedAt',
      }) ||
      !_mutationStamp(profile['updatedAt']))
    return false;
  for (final key in ['fullName', 'about', 'hobbi', 'pol', 'relationStatus']) {
    final value = profile[key];
    if (value != null &&
        (value is! String ||
            utf8.decode(utf8.encode(value)) != value ||
            utf8.encode(value).length > 16384))
      return false;
  }
  for (final key in ['age', 'rost']) {
    if (profile[key] != null && profile[key] is! int) return false;
  }
  for (final key in ['deti', 'profileDetailsSaved', 'isRegistrationEnd']) {
    if (profile[key] != null && profile[key] is! bool) return false;
  }
  return true;
}
