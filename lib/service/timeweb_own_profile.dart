part of 'timeweb_auth_client.dart';

enum TimewebOnboarding { registration, test, search }

enum TimewebOwnProfileMediaKind { quarantined, unavailable }

/// Immutable read snapshot. Recheck after consumer awaits; retained A results,
/// including nested data, become unusable after logout or a new A/B login.
/// No FirebaseUser, email, admin capability, financial map or mutable cache.
final class TimewebFullOwnProfile {
  TimewebFullOwnProfile._(
    this._uid,
    this._profile,
    this._onboarding,
    this._sourceSnapshot,
    this._documentHash,
    List<String> unavailable,
    this._check,
  ) : _unavailableFields = List.unmodifiable(unavailable);

  final String _uid;
  final TimewebOwnProfile? _profile;
  final TimewebOnboarding _onboarding;
  final String _sourceSnapshot;
  final String? _documentHash;
  final List<String> _unavailableFields;
  final void Function() _check;

  void requireCurrent() => _check();
  String get uid {
    _check();
    return _uid;
  }

  TimewebOwnProfile? get profile {
    _check();
    return _profile;
  }

  bool get profileExists {
    _check();
    return _profile != null;
  }

  TimewebOnboarding get onboarding {
    _check();
    return _onboarding;
  }

  String get sourceSnapshot {
    _check();
    return _sourceSnapshot;
  }

  String? get profileDocumentHash {
    _check();
    return _documentHash;
  }

  List<String> get unavailableFields {
    _check();
    return _unavailableFields;
  }

  String get profileAuthority {
    _check();
    return 'immutable-reviewed-snapshot';
  }

  String get accountAuthority {
    _check();
    return 'active-local-account';
  }

  bool get mediaReady {
    _check();
    return false;
  }

  bool get readOnly {
    _check();
    return true;
  }

  @override
  String toString() => 'TimewebFullOwnProfile(<redacted>)';
}

/// All nullable values retain truthful absence/corruption. Snapshot online or
/// visibility timestamps do not establish current presence/subscriptions.
/// No toMap/toJson: this is deliberately not SessionService.hydrate input.
final class TimewebOwnProfile {
  TimewebOwnProfile._(Map<String, Object?> values, this._check)
    : _values = Map.unmodifiable(values);
  final Map<String, Object?> _values;
  final void Function() _check;

  void requireCurrent() => _check();
  T _read<T>(String key) {
    _check();
    return _values[key] as T;
  }

  String get uid => _read<String>('uid');
  String? get status => _read<String?>('status');
  String? get registrationStatus => _read<String?>('registrationStatus');
  bool? get deleted => _read<bool?>('deleted');
  bool? get isRegistrationEnd => _read<bool?>('isRegistrationEnd');
  bool? get profileDetailsSaved => _read<bool?>('profileDetailsSaved');
  String? get legacyGroup => _read<String?>('группа');
  String? get group => _read<String?>('group');
  String? get fullName => _read<String?>('fullName');
  String? get country => _read<String?>('country');
  String? get countryCode => _read<String?>('countryCode');
  String? get region => _read<String?>('region');
  String? get city => _read<String?>('city');
  String? get languageGroup => _read<String?>('languageGroup');
  String? get countrySegment => _read<String?>('countrySegment');
  String? get pol => _read<String?>('pol');
  String? get about => _read<String?>('about');
  String? get hobbi => _read<String?>('hobbi');
  String? get rost => _read<String?>('rost');
  String? get relationStatus => _read<String?>('relationStatus');
  num? get age => _read<num?>('age');
  bool? get deti => _read<bool?>('deti');
  bool? get online => _read<bool?>('online');
  bool? get isUnVisible => _read<bool?>('isUnVisible');
  bool? get isUnvisible => _read<bool?>('isUnvisible');
  TimewebOwnNotificationPreferences? get notificationPreferences =>
      _read<TimewebOwnNotificationPreferences?>('notificationPreferences');
  // ISO source strings preserve nanoseconds and never invent a timezone.
  String? get lastOnlineTimestamp => _read<String?>('lastOnlineTS');
  String? get unvisibleEnd => _read<String?>('unvisibleEnd');
  TimewebOwnProfileMedia? get profilePic =>
      _read<TimewebOwnProfileMedia?>('profilePic');
  TimewebOwnProfileMedia? get profilePicThumb =>
      _read<TimewebOwnProfileMedia?>('profilePicThumb');

  @override
  String toString() => 'TimewebOwnProfile(<redacted>)';
}

final class TimewebOwnNotificationPreferences {
  TimewebOwnNotificationPreferences._(
    this._messages,
    this._meetings,
    this._sound,
    this._check,
  );
  final bool? _messages, _meetings, _sound;
  final void Function() _check;
  void requireCurrent() => _check();
  bool? get messages {
    _check();
    return _messages;
  }

  bool? get meetings {
    _check();
    return _meetings;
  }

  bool? get sound {
    _check();
    return _sound;
  }

  @override
  String toString() => 'TimewebOwnNotificationPreferences(<redacted>)';
}

/// An opaque quarantined reference is not a public URL or permission to load
/// an image. Promotion/ownership/HTTP lease/UI integration remain separate.
final class TimewebOwnProfileMedia {
  TimewebOwnProfileMedia._(
    this._kind,
    this._reference,
    this._reason,
    this._check,
  );
  final TimewebOwnProfileMediaKind _kind;
  final String? _reference, _reason;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebOwnProfileMediaKind get kind {
    _check();
    return _kind;
  }

  String? get opaqueReference {
    _check();
    return _reference;
  }

  String? get unavailableReason {
    _check();
    return _reason;
  }

  @override
  String toString() => 'TimewebOwnProfileMedia(<redacted>)';
}

const _ownProfileTextFields = {
  'status': 191,
  'registrationStatus': 191,
  'группа': 191,
  'group': 191,
  'fullName': 1000,
  'country': 191,
  'countryCode': 20,
  'region': 1000,
  'city': 1000,
  'languageGroup': 191,
  'countrySegment': 191,
  'pol': 191,
  'about': 4096,
  'hobbi': 4096,
  'rost': 191,
  'relationStatus': 191,
};
const _ownProfileBooleanFields = {
  'deleted',
  'isRegistrationEnd',
  'profileDetailsSaved',
  'deti',
  'online',
  'isUnVisible',
  'isUnvisible',
};
const _ownProfileOptionalFields = {
  'fullName',
  'country',
  'countryCode',
  'region',
  'city',
  'languageGroup',
  'countrySegment',
  'pol',
  'about',
  'hobbi',
  'rost',
  'relationStatus',
  'age',
  'deti',
  'online',
  'isUnVisible',
  'isUnvisible',
  'notificationPreferences',
  'lastOnlineTS',
  'unvisibleEnd',
  'profilePic',
  'profilePicThumb',
};
const _ownProfileGroups = {
  'коричнево-красная',
  'коричнево-синяя',
  'коричневая',
  'коричнево-белая',
  'бело-коричневая',
  'бело-красная',
  'бело-синяя',
  'белая',
  'сине-белая',
  'красно-синяя',
  'красно-белая',
  'красная',
  'красно-коричневая',
  'синяя',
  'сине-коричневая',
  'сине-красная',
};

Never _invalidOwnProfile() => throw const TimewebAuthException(
  TimewebAuthOperation.profile,
  TimewebAuthError.invalidResponse,
);
bool _ownProfileDigest(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
Map<String, dynamic> _ownProfileMap(Object? value) {
  if (value is! Map<String, dynamic>) _invalidOwnProfile();
  return value;
}

void _ownProfileKeys(Map<String, dynamic> value, Set<String> expected) {
  if (value.length != expected.length || !expected.every(value.containsKey)) {
    _invalidOwnProfile();
  }
}

void _ownProfileString(Object? value, int maximum, {bool nullable = true}) {
  if (nullable && value == null) return;
  if (value is! String ||
      value.runes.length > maximum ||
      utf8.decode(utf8.encode(value)) != value)
    _invalidOwnProfile();
}

void _ownProfileUid(Object? value) {
  _ownProfileString(value, 191, nullable: false);
  final uid = value as String;
  if (uid.isEmpty ||
      const {'.', '..'}.contains(uid) ||
      uid.contains('/') ||
      uid.contains('\u0000') ||
      utf8.encode(uid).length > 764)
    _invalidOwnProfile();
}

void _ownProfileBool(Object? value) {
  if (value != null && value is! bool) _invalidOwnProfile();
}

void _ownProfileTimestamp(Object? value) {
  if (value == null) return;
  _ownProfileString(value, 30, nullable: false);
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$',
  ).firstMatch(value as String);
  if (match == null) _invalidOwnProfile();
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  if (parts[0] < 1) _invalidOwnProfile();
  final date = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if (date.year != parts[0] ||
      date.month != parts[1] ||
      date.day != parts[2] ||
      date.hour != parts[3] ||
      date.minute != parts[4] ||
      date.second != parts[5]) {
    _invalidOwnProfile();
  }
}

TimewebOwnProfileMedia? _ownProfileMedia(Object? value, void Function() check) {
  if (value == null) return null;
  final data = _ownProfileMap(value);
  if (data['kind'] == 'legacy_storage') {
    _ownProfileKeys(data, {'kind', 'status', 'reference'});
    final reference = data['reference'];
    if (data['status'] != 'quarantined' ||
        reference is! String ||
        reference.isEmpty ||
        reference.length > 4096 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(reference))
      _invalidOwnProfile();
    return TimewebOwnProfileMedia._(
      TimewebOwnProfileMediaKind.quarantined,
      reference,
      null,
      check,
    );
  }
  _ownProfileKeys(data, {'kind', 'reason'});
  if (data['kind'] != 'unavailable' ||
      !const {
        'unmapped_external_media',
        'unmapped_profile_media',
      }.contains(data['reason']))
    _invalidOwnProfile();
  return TimewebOwnProfileMedia._(
    TimewebOwnProfileMediaKind.unavailable,
    null,
    data['reason'] as String,
    check,
  );
}

TimewebFullOwnProfile _decodeFullOwnProfile(
  Map<String, dynamic> body, {
  required String uid,
  required String expectedSourceSnapshot,
  required void Function() check,
}) {
  _ownProfileKeys(body, {
    'uid',
    'profile',
    'onboarding',
    'profileExists',
    'sourceSnapshot',
    'profileDocumentHash',
    'profileAuthority',
    'accountAuthority',
    'mediaReady',
    'readOnly',
    'unavailableFields',
  });
  _ownProfileUid(body['uid']);
  if (body['uid'] != uid ||
      body['sourceSnapshot'] != expectedSourceSnapshot ||
      !_ownProfileDigest(body['sourceSnapshot']) ||
      body['profileAuthority'] != 'immutable-reviewed-snapshot' ||
      body['accountAuthority'] != 'active-local-account' ||
      body['mediaReady'] != false ||
      body['readOnly'] != true ||
      body['profileExists'] is! bool)
    _invalidOwnProfile();
  final onboarding = switch (body['onboarding']) {
    'registration' => TimewebOnboarding.registration,
    'test' => TimewebOnboarding.test,
    'search' => TimewebOnboarding.search,
    _ => _invalidOwnProfile(),
  };
  final rawUnavailable = body['unavailableFields'];
  if (rawUnavailable is! List ||
      rawUnavailable.length > _ownProfileOptionalFields.length ||
      rawUnavailable.any(
        (item) => item is! String || !_ownProfileOptionalFields.contains(item),
      ) ||
      rawUnavailable.toSet().length != rawUnavailable.length)
    _invalidOwnProfile();
  final unavailable = rawUnavailable.cast<String>();
  final rawProfile = body['profile'];
  if (rawProfile == null) {
    if (body['profileExists'] != false ||
        body['profileDocumentHash'] != null ||
        onboarding != TimewebOnboarding.registration ||
        unavailable.isNotEmpty)
      _invalidOwnProfile();
    return TimewebFullOwnProfile._(
      uid,
      null,
      onboarding,
      expectedSourceSnapshot,
      null,
      unavailable,
      check,
    );
  }
  if (body['profileExists'] != true ||
      !_ownProfileDigest(body['profileDocumentHash']))
    _invalidOwnProfile();
  final profile = _ownProfileMap(rawProfile);
  _ownProfileKeys(profile, {
    'uid',
    ..._ownProfileTextFields.keys,
    ..._ownProfileBooleanFields,
    'age',
    'notificationPreferences',
    'lastOnlineTS',
    'unvisibleEnd',
    'profilePic',
    'profilePicThumb',
  });
  _ownProfileUid(profile['uid']);
  if (profile['uid'] != uid) _invalidOwnProfile();
  for (final entry in _ownProfileTextFields.entries) {
    _ownProfileString(profile[entry.key], entry.value);
  }
  for (final key in _ownProfileBooleanFields) {
    _ownProfileBool(profile[key]);
  }
  if (!const {null, '', 'active'}.contains(profile['status']) ||
      const {'deleted', 'blocked'}.contains(profile['registrationStatus']) ||
      profile['deleted'] == true ||
      (profile['группа'] != null && profile['group'] != profile['группа']))
    _invalidOwnProfile();
  final age = profile['age'];
  if (age != null && (age is! num || !age.isFinite || age < 0 || age > 150))
    _invalidOwnProfile();
  for (final key in unavailable) {
    if (profile[key] != null) _invalidOwnProfile();
  }
  _ownProfileTimestamp(profile['lastOnlineTS']);
  _ownProfileTimestamp(profile['unvisibleEnd']);
  final values = Map<String, Object?>.from(profile);
  final preferences = profile['notificationPreferences'];
  if (preferences != null) {
    final data = _ownProfileMap(preferences);
    _ownProfileKeys(data, {'messages', 'meetings', 'sound'});
    for (final item in data.values) {
      _ownProfileBool(item);
    }
    values['notificationPreferences'] = TimewebOwnNotificationPreferences._(
      data['messages'] as bool?,
      data['meetings'] as bool?,
      data['sound'] as bool?,
      check,
    );
  }
  values['profilePic'] = _ownProfileMedia(profile['profilePic'], check);
  values['profilePicThumb'] = _ownProfileMedia(
    profile['profilePicThumb'],
    check,
  );
  // Verify source semantics without substituting missing fields or using group
  // alias as an invented completion marker; retain the server's typed result.
  final completed =
      profile['isRegistrationEnd'] == true ||
      _ownProfileGroups.contains(
        (profile['группа'] as String?)?.trim().toLowerCase(),
      );
  TimewebOnboarding expected;
  if (completed) {
    expected = TimewebOnboarding.search;
  } else if (profile['profileDetailsSaved'] == true) {
    expected = TimewebOnboarding.test;
  } else {
    if (unavailable.any(
      const {'fullName', 'age', 'pol', 'about', 'hobbi'}.contains,
    ))
      _invalidOwnProfile();
    bool nonempty(String key, {bool trim = false}) {
      final value = profile[key] as String?;
      return value != null && (trim ? value.trim() : value).isNotEmpty;
    }

    expected =
        nonempty('fullName', trim: true) &&
            age != null &&
            nonempty('pol') &&
            nonempty('about') &&
            nonempty('hobbi')
        ? TimewebOnboarding.test
        : TimewebOnboarding.registration;
  }
  if (onboarding != expected) _invalidOwnProfile();
  return TimewebFullOwnProfile._(
    uid,
    TimewebOwnProfile._(values, check),
    onboarding,
    expectedSourceSnapshot,
    body['profileDocumentHash'] as String,
    unavailable,
    check,
  );
}
