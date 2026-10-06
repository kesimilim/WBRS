part of 'timeweb_auth_client.dart';

const _initialFields = {
  'fullName',
  'age',
  'rost',
  'about',
  'hobbi',
  'deti',
  'pol',
  'relationStatus',
};

final class TimewebInitialPhotoProof {
  TimewebInitialPhotoProof._(this._data, this._reference);
  factory TimewebInitialPhotoProof.fromReady(
    TimewebCommittedPhotoReceipt receipt,
  ) {
    receipt.requireCurrent();
    return TimewebInitialPhotoProof._(
      Map.unmodifiable({
        'mediaId': receipt.mediaId,
        'prepareOperationId': receipt.prepareOperationId,
        'commitOperationId': receipt.commitOperationId,
      }),
      receipt._reference,
    );
  }
  final Map<String, dynamic> _data;
  final TimewebMutationReference _reference;
  void requireCurrent() => _reference.requireCurrent();
  String _read(String key) {
    requireCurrent();
    return _data[key];
  }

  String get mediaId => _read('mediaId');
  String get prepareOperationId => _read('prepareOperationId');
  String get commitOperationId => _read('commitOperationId');
  Map<String, dynamic> get fields {
    requireCurrent();
    return _data;
  }

  static TimewebInitialPhotoProof restore({
    required TimewebAuthClient client,
    required String ownerUid,
    required Map<String, dynamic> fields,
  }) {
    if (!_mutationExact(fields, {
          'mediaId',
          'prepareOperationId',
          'commitOperationId',
        }) ||
        !_uploadMid(fields['mediaId']) ||
        !_uploadUuid(fields['prepareOperationId']) ||
        !_uploadUuid(fields['commitOperationId']) ||
        fields['mediaId'] !=
            _uploadId(ownerUid, fields['prepareOperationId'])) {
      throw const FormatException('Invalid original photo pointer.');
    }
    final request = TimewebMutationRequest.commitProfilePhoto(
      operationId: fields['commitOperationId'],
      prepareOperationId: fields['prepareOperationId'],
      mediaId: fields['mediaId'],
    );
    return TimewebInitialPhotoProof._(
      Map.unmodifiable(fields),
      client.bindMutation(request, expectedOwnerUid: ownerUid),
    );
  }

  void requireOwner(TimewebAuthClient client, String uid) {
    requireCurrent();
    if (!identical(_reference._owner, client) || _reference._uid != uid) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.staleSession,
      );
    }
  }

  @override
  String toString() => 'TimewebInitialPhotoProof(<redacted>)';
}

final class TimewebInitialProfileRequest {
  TimewebInitialProfileRequest({
    required String expectedUpdatedAt,
    required TimewebProfileChanges changes,
    required TimewebGeographyChanges geography,
    required List<TimewebInitialPhotoProof> photos,
  }) : this._(
         expectedUpdatedAt,
         changes._fields,
         geography._fields,
         photos,
         false,
       );
  TimewebInitialProfileRequest._(
    String stamp,
    Map<String, dynamic> changes,
    Map<String, dynamic> geo,
    List<TimewebInitialPhotoProof> photos,
    this._lookupOnly,
  ) {
    if (!_mutationStamp(stamp) ||
        !_mutationExact(changes, _initialFields) ||
        photos.length != 3 ||
        !_mutationExact(geo, {'countryCode', 'region'}) ||
        geo['countryCode'] is! String ||
        !RegExp(r'^[A-Z]{2}$').hasMatch(geo['countryCode']) ||
        !_mutationText(geo['region'], maximum: 191)) {
      throw ArgumentError('Invalid initial profile.');
    }
    for (final field in [
      'mediaId',
      'prepareOperationId',
      'commitOperationId',
    ]) {
      if (photos.map((p) => p.fields[field]).toSet().length != 3) {
        throw ArgumentError('Three distinct original photos are required.');
      }
    }
    _photos = List.unmodifiable(photos);
    _fields = Map.unmodifiable({
      'expectedUpdatedAt': stamp,
      'changes': Map<String, dynamic>.unmodifiable(changes),
      'geography': Map<String, dynamic>.unmodifiable(geo),
      'photos': List.unmodifiable(photos.map((p) => p.fields)),
    });
  }
  final bool _lookupOnly;
  bool get lookupOnly => _lookupOnly;
  late final Map<String, dynamic> _fields;
  late final List<TimewebInitialPhotoProof> _photos;
  String get expectedUpdatedAt => _fields['expectedUpdatedAt'];
  Map<String, dynamic> get changes => _fields['changes'];
  String get countryCode => _fields['geography']['countryCode'];
  String get region => _fields['geography']['region'];
  List<TimewebInitialPhotoProof> get photos => _photos;
  void requireOwner(TimewebAuthClient client, String uid) {
    for (final p in photos) {
      p.requireOwner(client, uid);
    }
  }

  Map<String, dynamic> get fields => _fields;
  static TimewebInitialProfileRequest restore(
    Map<String, dynamic> fields,
    List<TimewebInitialPhotoProof> photos,
  ) {
    if (!_mutationExact(fields, {
          'expectedUpdatedAt',
          'changes',
          'geography',
          'photos',
        }) ||
        fields['changes'] is! Map<String, dynamic> ||
        fields['geography'] is! Map<String, dynamic> ||
        fields['photos'] is! List ||
        jsonEncode(fields['photos']) !=
            jsonEncode(photos.map((p) => p.fields).toList())) {
      throw const FormatException('Invalid initial profile intent.');
    }
    final c = fields['changes'];
    final changes = TimewebProfileChanges(
      fullName: c['fullName'],
      age: c['age'],
      rost: c['rost'],
      about: c['about'],
      hobbi: c['hobbi'],
      deti: c['deti'],
      pol: c['pol'],
      relationStatus: c['relationStatus'],
    );
    return TimewebInitialProfileRequest._(
      fields['expectedUpdatedAt'],
      changes._fields,
      fields['geography'],
      photos,
      true,
    );
  }

  @override
  String toString() => 'TimewebInitialProfileRequest(<redacted>)';
}

final class TimewebInitialProfileReceipt {
  TimewebInitialProfileReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebInitialProfileReceipt bindSessionGuard(void Function() check) =>
      TimewebInitialProfileReceipt._(_data, () {
        requireCurrent();
        check();
      });
  T _read<T>(String key) {
    requireCurrent();
    return _data[key] as T;
  }

  String get uid => _read('uid');
  bool get profileDetailsSaved => _read('profileDetailsSaved');
  String get onboarding => _read('onboarding');
  String get updatedAt => _read('updatedAt');
  String get profileAuthority => _read('profileAuthority');
  @override
  String toString() => 'TimewebInitialProfileReceipt(<redacted>)';
}
