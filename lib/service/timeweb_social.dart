part of 'timeweb_auth_client.dart';

extension TimewebDonationClient on TimewebAuthClient {
  Future<Uri> donationCheckout(int amountMinor) {
    try {
      _checkEnabled(_peopleOperation);
      if (!configuration.runtimeWritesEnabled ||
          _session == null ||
          _secureStoreUnsafe ||
          amountMinor < 100 ||
          amountMinor > 10000000) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.invalidRequest,
        );
      }
      final key = 'donation:$_epoch:$amountMinor';
      final prior = _peopleFlights[key];
      if (prior != null) return prior.result.future.then((v) => v as Uri);
      if (_peopleFlights.length >= 4)
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.unavailable,
        );
      final f = _PeopleFlight(
        this,
        null,
        null,
        null,
        _epoch,
        _session!.uid,
        key,
      );
      _peopleFlights[key] = f;
      unawaited(_executeDonation(f, amountMinor));
      return f.result.future.then((v) => v as Uri);
    } catch (e) {
      return Future.error(e);
    }
  }
}

Future<void> _executeDonation(_PeopleFlight f, int amountMinor) async {
  final owner = f.owner;
  try {
    f.check();
    var session = owner._session!;
    if (!owner
        ._clock()
        .add(owner.accessExpirySkew)
        .isBefore(session.accessExpiresAt)) {
      session = await owner.refresh();
      f.check();
    }
    final uri = owner.configuration.endpoint.replace(
      path: '/v1/runtime/social/donation-checkout',
      queryParameters: {'amountMinor': '$amountMinor'},
    );
    var reply = await _meetingAttempt(f, uri, session.accessToken);
    f.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken)
        await owner.refresh();
      f.check();
      session = owner._session!;
      reply = await _meetingAttempt(f, uri, session.accessToken);
      f.check();
    }
    if (reply.status != 200)
      throw owner._statusError(_peopleOperation, reply.status);
    final data = reply.body!;
    if (!_mutationExact(data, {'url', 'amountMinor', 'test'}) ||
        data['amountMinor'] != amountMinor ||
        data['test'] is! bool ||
        data['url'] is! String ||
        data['url'].length > 2048)
      _peopleInvalid();
    final target = Uri.tryParse(data['url']);
    if (target == null ||
        target.scheme != 'https' ||
        target.host != 'auth.robokassa.ru' ||
        target.hasPort ||
        target.userInfo.isNotEmpty ||
        target.hasFragment ||
        target.path != '/Merchant/Index.aspx')
      _peopleInvalid();
    final params = target.queryParameters;
    if (params['MerchantLogin'] != 'WBRS' ||
        params['InvId'] != '0' ||
        params['OutSum'] !=
            '${amountMinor ~/ 100}.${(amountMinor % 100).toString().padLeft(2, '0')}' ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(params['SignatureValue'] ?? '') ||
        (params['IsTest'] == '1') != data['test']) {
      _peopleInvalid();
    }
    if (!f.result.isCompleted) f.result.complete(target);
  } catch (e) {
    if (!f.result.isCompleted) f.result.completeError(e);
  } finally {
    f.timer.cancel();
    if (identical(owner._peopleFlights[f.key], f))
      owner._peopleFlights.remove(f.key);
    f.settled.complete();
  }
}

/// Exact original action. Text is retained for hashing; the server owns display
/// normalization, role checks and the affected rows.
final class TimewebSocialAction {
  TimewebSocialAction._(this.payload);
  final Map<String, dynamic> payload;
  factory TimewebSocialAction.publish(String text, {List<String>? mediaIds}) =>
      TimewebSocialAction.fromPayload({
        'kind': 'publish',
        'text': text,
        if (mediaIds != null) 'mediaIds': mediaIds,
      });
  factory TimewebSocialAction.updatePost(
    TimewebSocialItem post,
    String text,
    List<String> mediaIds,
  ) => TimewebSocialAction.fromPayload({
    'kind': 'update-post',
    'postId': post.id,
    'text': text,
    'mediaIds': mediaIds,
    'expectedContentHash': post.contentHash,
  });
  factory TimewebSocialAction.deletePost(TimewebSocialItem post) =>
      TimewebSocialAction.fromPayload({
        'kind': 'delete-post',
        'postId': post.id,
        'expectedContentHash': post.contentHash,
      });
  factory TimewebSocialAction.prepareMedia(TimewebPhotoMetadata metadata) =>
      TimewebSocialAction.fromPayload({
        'kind': 'prepare-media',
        ...metadata.fields,
      });
  factory TimewebSocialAction.commitMedia(
    TimewebPreparedPhotoReceipt prepared,
  ) => TimewebSocialAction.fromPayload({
    'kind': 'commit-media',
    'mediaId': prepared.mediaId,
    'prepareOperationId': prepared.prepareOperationId,
  });
  factory TimewebSocialAction.comment(
    String postId,
    String text, {
    String? parentId,
  }) => TimewebSocialAction.fromPayload({
    'kind': 'comment',
    'postId': postId,
    'text': text,
    'parentId': parentId,
  });
  factory TimewebSocialAction.react(
    String postId,
    bool active, {
    String? commentId,
  }) => TimewebSocialAction.fromPayload({
    'kind': 'react',
    'postId': postId,
    'commentId': commentId,
    'active': active,
  });
  factory TimewebSocialAction.report(String postId, {String? commentId}) =>
      TimewebSocialAction.fromPayload({
        'kind': 'report',
        'postId': postId,
        'commentId': commentId,
      });
  factory TimewebSocialAction.hideComment(String postId, String commentId) =>
      TimewebSocialAction.fromPayload({
        'kind': 'hide-comment',
        'postId': postId,
        'commentId': commentId,
      });
  factory TimewebSocialAction.fromPayload(Map<String, dynamic> value) {
    final keys = switch (value['kind']) {
      'publish' => {
        'kind',
        'text',
        if (value.containsKey('mediaIds')) 'mediaIds',
      },
      'update-post' => {
        'kind',
        'postId',
        'text',
        'mediaIds',
        'expectedContentHash',
      },
      'delete-post' => {'kind', 'postId', 'expectedContentHash'},
      'prepare-media' => {'kind', 'sha256', 'byteSize', 'mimeType'},
      'commit-media' => {'kind', 'mediaId', 'prepareOperationId'},
      'comment' => {'kind', 'postId', 'text', 'parentId'},
      'react' => {'kind', 'postId', 'commentId', 'active'},
      'report' || 'hide-comment' => {'kind', 'postId', 'commentId'},
      _ => <String>{},
    };
    if (keys.isEmpty ||
        !_mutationExact(value, keys) ||
        !const {
              'publish',
              'prepare-media',
              'commit-media',
            }.contains(value['kind']) &&
            !_mutationId(value['postId']) ||
        const {'publish', 'comment', 'update-post'}.contains(value['kind']) &&
            !_socialText(
              value['text'],
              input:
                  value['mediaIds'] is! List ||
                  (value['mediaIds'] as List).isEmpty,
            ) ||
        value.containsKey('parentId') &&
            value['parentId'] != null &&
            !_mutationId(value['parentId']) ||
        value.containsKey('commentId') &&
            value['commentId'] != null &&
            !_mutationId(value['commentId']) ||
        value['kind'] == 'hide-comment' && value['commentId'] == null ||
        value['kind'] == 'react' && value['active'] is! bool) {
      throw ArgumentError('Invalid native social action.');
    }
    if (value.containsKey('mediaIds') && !_socialMediaIds(value['mediaIds']) ||
        value.containsKey('expectedContentHash') &&
            (value['expectedContentHash'] is! String ||
                !RegExp(
                  r'^[a-f0-9]{64}$',
                ).hasMatch(value['expectedContentHash'])) ||
        value['kind'] == 'commit-media' &&
            (!_uploadUuid(value['prepareOperationId']) ||
                !_socialMid(value['mediaId']))) {
      throw ArgumentError('Invalid post content.');
    }
    if (value['kind'] == 'prepare-media') {
      TimewebPhotoMetadata(
        sha256: value['sha256'],
        byteSize: value['byteSize'],
        mimeType: value['mimeType'],
      );
    }
    return TimewebSocialAction._(
      Map<String, dynamic>.unmodifiable({
        ...value,
        if (value.containsKey('mediaIds'))
          'mediaIds': List<String>.unmodifiable(value['mediaIds']),
      }),
    );
  }
  String get kind => payload['kind'];
  String get operation => 'social.$kind.v1';
  @override
  String toString() => 'TimewebSocialAction(<redacted>)';
}

bool _socialMid(Object? v) =>
    v is String && RegExp(r'^tw-post-media-[a-f0-9]{64}$').hasMatch(v);
bool _socialMediaIds(Object? v) =>
    v is List &&
    v.length <= 10 &&
    v.every(_mutationId) &&
    v.toSet().length == v.length;
String _socialContentHash(String? text, List<String> ids) => crypto.sha256
    .convert(utf8.encode(_mutationCanonical({'text': text, 'mediaIds': ids})))
    .toString();
String _socialMediaId(String uid, String operation) =>
    'tw-post-media-${crypto.sha256.convert(utf8.encode('clrs-native-post-photo-v1\u0000${_mutationCanonical([uid, operation])}'))}';

bool _socialText(Object? value, {bool input = false}) =>
    value is String &&
    (!input || value.trim().isNotEmpty) &&
    value.runes.length <= 4000 &&
    utf8.encode(value).length <= 16000 &&
    !value.contains('\u0000') &&
    utf8.decode(utf8.encode(value)) == value;

final class TimewebSocialReceipt {
  TimewebSocialReceipt._(this._data, this._kind, this._check, this._reference);
  final TimewebMutationReference _reference;
  TimewebPreparedPhotoReceipt get preparedMedia {
    requireCurrent();
    if (_kind != 'prepare-media') throw StateError('Not a post image receipt.');
    return TimewebPreparedPhotoReceipt._(_data, _reference, _check);
  }

  String? get mediaId {
    requireCurrent();
    return _data['mediaId'];
  }

  final Map<String, dynamic> _data;
  final String _kind;
  final void Function() _check;
  void requireCurrent() => _check();
  String get kind {
    _check();
    return _kind;
  }

  String get postId {
    _check();
    return _data['postId'];
  }

  String? get commentId {
    _check();
    return _data['commentId'];
  }

  bool? get active {
    _check();
    return _data['active'];
  }

  TimewebSocialReceipt bindSessionGuard(void Function() guard) =>
      TimewebSocialReceipt._(_data, _kind, () {
        requireCurrent();
        guard();
      }, _reference);
  @override
  String toString() => 'TimewebSocialReceipt(<redacted>)';
}

String _socialCreatedId(String kind, String uid, String id) =>
    '${kind == 'publish' ? 'tw-post-' : 'tw-comment-'}${crypto.sha256.convert(utf8.encode('$kind\u0000$uid\u0000$id'))}';

TimewebMutationResult _decodeSocialReceipt(
  TimewebMutationReference ref,
  _Reply reply,
  Map<String, dynamic> data,
  bool replayed,
  int? revision,
) {
  final action = ref._request._payload;
  final kind = action['kind'];
  if (reply.status == 409 &&
      _mutationExact(data, {'error'}) &&
      revision == null &&
      const {
        'post_changed',
        'social_access_denied',
        'media_not_verified',
      }.contains(data['error'])) {
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      409,
      replayed: replayed,
      receiptConfirmed: true,
      failure: data['error'] == 'post_changed'
          ? TimewebMutationFailure.conflict
          : data['error'] == 'media_not_verified'
          ? TimewebMutationFailure.photoVerificationFailed
          : TimewebMutationFailure.socialAccessDenied,
    );
  }
  if (kind == 'prepare-media' || kind == 'commit-media') {
    final prepare = kind == 'prepare-media';
    final expected = _socialMediaId(
      ref._uid,
      prepare ? ref._request.operationId : action['prepareOperationId'],
    );
    if (revision != null ||
        reply.status != (prepare ? 201 : 200) ||
        !_mutationExact(
          data,
          prepare
              ? {'mediaId', 'status', 'sha256', 'byteSize', 'mimeType'}
              : {'mediaId', 'ready'},
        ) ||
        data['mediaId'] != expected ||
        (!prepare &&
            (action['mediaId'] != expected || data['ready'] != true)) ||
        prepare &&
            (data['status'] != 'pending' ||
                data['byteSize'] is! int ||
                data['byteSize'] != action['byteSize'] ||
                data['mimeType'] != action['mimeType'] ||
                data['sha256'] != action['sha256'])) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.confirmed,
      reply.status,
      replayed: replayed,
      receiptConfirmed: true,
      social: TimewebSocialReceipt._(
        Map.unmodifiable(data),
        kind,
        ref.requireCurrent,
        ref,
      ),
    );
  }
  final keys = switch (kind) {
    'publish' => {'postId'},
    'update-post' => {'postId', 'updated'},
    'delete-post' => {'postId', 'deleted'},
    'comment' => {'postId', 'commentId'},
    'react' => {'postId', 'commentId', 'active'},
    'report' => {'postId', 'commentId', 'reported'},
    'hide-comment' => {'postId', 'commentId', 'hidden'},
    _ => <String>{},
  };
  if (!_mutationExact(data, keys) ||
      revision != null ||
      reply.status !=
          (const {'publish', 'comment'}.contains(kind) ? 201 : 200) ||
      !_mutationId(data['postId']) ||
      (kind == 'publish'
          ? data['postId'] !=
                _socialCreatedId('publish', ref._uid, ref._request.operationId)
          : data['postId'] != action['postId']) ||
      kind == 'comment' &&
          data['commentId'] !=
              _socialCreatedId('comment', ref._uid, ref._request.operationId) ||
      const {'react', 'report', 'hide-comment'}.contains(kind) &&
          data['commentId'] != action['commentId'] ||
      kind == 'react' && data['active'] != action['active'] ||
      kind == 'report' && data['reported'] != true ||
      kind == 'hide-comment' && data['hidden'] != true ||
      kind == 'update-post' && data['updated'] != true ||
      kind == 'delete-post' && data['deleted'] != true) {
    _mutationInvalidReply();
  }
  return TimewebMutationResult._(
    ref,
    TimewebMutationState.confirmed,
    reply.status,
    replayed: replayed,
    receiptConfirmed: true,
    social: TimewebSocialReceipt._(
      Map.unmodifiable(data),
      kind,
      ref.requireCurrent,
      ref,
    ),
  );
}

/// Only current server allowlist fields; no inferred name/avatar/media URL.
final class TimewebSocialItem {
  TimewebSocialItem._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  T? _read<T>(String key) {
    _check();
    return _data[key] as T?;
  }

  String get id => _read<String>('id')!;
  String get authorUid => _read<String>('authorUid')!;
  String? get text => _read<String>('text');
  String? get mediaId => _read<String>('mediaId');
  List<String> get mediaIds {
    requireCurrent();
    return List<String>.unmodifiable(
      _data['mediaIds'] ?? (mediaId == null ? <String>[] : [mediaId!]),
    );
  }

  String get contentHash {
    requireCurrent();
    return _data['contentHash'] ?? _socialContentHash(text, mediaIds);
  }

  String? get createdAt => _read<String>('createdAt');
  String? get parentId => _read<String>('parentId');
  int? get likeCount => _read<int>('likeCount');
  int? get commentCount => _read<int>('commentCount');
  bool? get liked => _read<bool>('liked');
  TimewebSocialItem bindSessionGuard(void Function() guard) =>
      TimewebSocialItem._(_data, () {
        requireCurrent();
        guard();
      });
  @override
  String toString() => 'TimewebSocialItem(<redacted>)';
}

final class TimewebSocialCursor {
  TimewebSocialCursor._(
    this._value,
    this._owner,
    this._scope,
    this._expiresAt,
    this._lastDate,
    this._lastId,
    this._check,
  );
  final String _value, _scope, _lastId;
  final String? _lastDate;
  final TimewebAuthClient _owner;
  final DateTime _expiresAt;
  final void Function() _check;
  void requireCurrent() {
    _check();
    if (!_owner._clock().isBefore(_expiresAt)) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.invalidRequest,
      );
    }
  }

  @override
  String toString() => 'TimewebSocialCursor(<redacted>)';
}

final class TimewebSocialPage {
  TimewebSocialPage._(
    this._items,
    this._cursor,
    this._publish,
    this._moderate,
    this._check,
  );
  final List<TimewebSocialItem> _items;
  final TimewebSocialCursor? _cursor;
  final bool _publish, _moderate;
  final void Function() _check;
  void requireCurrent() => _check();
  List<TimewebSocialItem> get items {
    _check();
    return _items;
  }

  TimewebSocialCursor? get nextCursor {
    _check();
    return _cursor;
  }

  bool get canPublish {
    _check();
    return _publish;
  }

  bool get canModerate {
    _check();
    return _moderate;
  }

  TimewebSocialPage bindSessionGuard(void Function() guard) {
    void check() {
      requireCurrent();
      guard();
    }

    final cursor = _cursor;
    return TimewebSocialPage._(
      List.unmodifiable(_items.map((v) => v.bindSessionGuard(guard))),
      cursor == null
          ? null
          : TimewebSocialCursor._(
              cursor._value,
              cursor._owner,
              cursor._scope,
              cursor._expiresAt,
              cursor._lastDate,
              cursor._lastId,
              () {
                cursor.requireCurrent();
                guard();
              },
            ),
      _publish,
      _moderate,
      check,
    );
  }

  @override
  String toString() => 'TimewebSocialPage(<redacted>)';
}

final class TimewebSocialAccessDenied implements Exception {
  const TimewebSocialAccessDenied();
  @override
  String toString() => 'TimewebSocialAccessDenied';
}

extension TimewebSocialReads on TimewebAuthClient {
  Future<TimewebSocialPage> readSocialFeed({
    int limit = 10,
    String? wallUid,
    TimewebSocialCursor? cursor,
  }) => _startSocialRead(this, limit, wallUid, null, cursor);
  Future<TimewebSocialPage> readSocialComments(
    String postId, {
    TimewebSocialCursor? cursor,
  }) => _startSocialRead(this, 3, null, postId, cursor);
}

Future<TimewebSocialPage> _startSocialRead(
  TimewebAuthClient owner,
  int limit,
  String? wallUid,
  String? postId,
  TimewebSocialCursor? cursor,
) {
  try {
    owner._checkEnabled(_peopleOperation);
    if (!owner.configuration.currentReadsEnabled ||
        !owner.configuration.runtimeWritesEnabled) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.disabled,
      );
    }
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    if (limit < 1 ||
        limit > 10 ||
        wallUid != null && !_mutationId(wallUid) ||
        postId != null && !_mutationId(postId)) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.invalidRequest,
      );
    }
    final scope = jsonEncode([
      postId == null ? 'feed' : 'comments',
      limit,
      wallUid,
      postId,
    ]);
    if (cursor != null) {
      if (!identical(owner, cursor._owner) || cursor._scope != scope) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.invalidRequest,
        );
      }
      cursor.requireCurrent();
    }
    final key =
        '${owner._epoch}\u0000social:$scope\u0000${cursor?._value ?? ''}';
    final previous = owner._peopleFlights[key];
    if (previous != null) {
      return previous.result.future.then((v) => v as TimewebSocialPage);
    }
    if (owner._peopleFlights.length >= 4) {
      throw const TimewebAuthException(
        _peopleOperation,
        TimewebAuthError.unavailable,
      );
    }
    final f = _PeopleFlight(
      owner,
      null,
      null,
      null,
      owner._epoch,
      session.uid,
      key,
    );
    owner._peopleFlights[key] = f;
    unawaited(_executeSocialRead(f, limit, wallUid, postId, scope, cursor));
    return f.result.future.then((v) => v as TimewebSocialPage);
  } catch (error) {
    return Future.error(error);
  }
}

Future<void> _executeSocialRead(
  _PeopleFlight f,
  int limit,
  String? wallUid,
  String? postId,
  String scope,
  TimewebSocialCursor? cursor,
) async {
  final owner = f.owner;
  try {
    f.check();
    var session = owner._session!;
    if (!owner
        ._clock()
        .add(owner.accessExpirySkew)
        .isBefore(session.accessExpiresAt)) {
      session = await owner.refresh();
      f.check();
    }
    final uri = owner.configuration.endpoint.replace(
      pathSegments: [
        'v1',
        'runtime',
        'social',
        if (postId == null) 'feed' else ...['posts', postId, 'comments'],
      ],
      queryParameters: {
        if (postId == null) 'limit': '$limit',
        if (postId == null) 'media': 'all',
        if (wallUid != null) 'wallUid': wallUid,
        if (cursor != null) 'cursor': cursor._value,
      },
    );
    var reply = await _meetingAttempt(f, uri, session.accessToken);
    f.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken) {
        await owner.refresh();
      }
      f.check();
      session = owner._session!;
      reply = await _meetingAttempt(f, uri, session.accessToken);
      f.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 &&
          owner._session?.accessToken == session.accessToken) {
        await owner._invalidate(f.epoch);
      }
      if (const [403, 404].contains(reply.status)) {
        throw const TimewebSocialAccessDenied();
      }
      throw owner._statusError(_peopleOperation, reply.status);
    }
    final value = _decodeSocialPage(
      f,
      reply.body!,
      limit,
      postId,
      scope,
      cursor,
    );
    f.check();
    if (!f.result.isCompleted) f.result.complete(value);
  } catch (error) {
    if (!f.result.isCompleted) {
      try {
        f.check();
        f.result.completeError(
          error is TimewebAuthException || error is TimewebSocialAccessDenied
              ? error
              : const TimewebAuthException(
                  _peopleOperation,
                  TimewebAuthError.invalidResponse,
                ),
        );
      } catch (stale) {
        if (!f.result.isCompleted) f.result.completeError(stale);
      }
    }
  } finally {
    f.timer.cancel();
    if (identical(owner._peopleFlights[f.key], f)) {
      owner._peopleFlights.remove(f.key);
    }
    f.settled.complete();
  }
}

TimewebSocialPage _decodeSocialPage(
  _PeopleFlight f,
  Map<String, dynamic> body,
  int limit,
  String? postId,
  String scope,
  TimewebSocialCursor? cursor,
) {
  final comments = postId != null;
  if (!_mutationExact(
        body,
        comments
            ? {'kind', 'ordering', 'postId', 'items', 'nextCursor'}
            : {
                'kind',
                'ordering',
                'items',
                'nextCursor',
                'canPublish',
                'canModerate',
              },
      ) ||
      body['kind'] != (comments ? 'native-comments' : 'native-feed') ||
      body['ordering'] !=
          (comments
              ? 'created_asc_id_asc_null_first'
              : 'created_desc_id_desc_null_last') ||
      (comments
          ? body['postId'] != postId
          : body['canPublish'] is! bool || body['canModerate'] is! bool) ||
      body['items'] is! List ||
      (body['items'] as List).length > (limit < 3 ? limit : 3)) {
    _peopleInvalid();
  }
  final raw = body['items'] as List, next = body['nextCursor'];
  if (next != null &&
      (next is! String ||
          !_validReadCursor(next) ||
          next == cursor?._value ||
          raw.isEmpty)) {
    _peopleInvalid();
  }
  final ids = <String>{}, items = <TimewebSocialItem>[];
  String? previousDate = cursor?._lastDate, previousId = cursor?._lastId;
  for (final value in raw) {
    if (value is! Map<String, dynamic> ||
        !_mutationExact(
          value,
          comments
              ? {
                  'id',
                  'authorUid',
                  'text',
                  'parentId',
                  'mediaId',
                  'createdAt',
                  'liked',
                }
              : {
                  'id',
                  'authorUid',
                  'text',
                  'mediaId',
                  'createdAt',
                  'likeCount',
                  'commentCount',
                  'liked',
                  if (value.containsKey('mediaIds')) 'mediaIds',
                  if (value.containsKey('contentHash')) 'contentHash',
                },
        ) ||
        !_mutationId(value['id']) ||
        value.containsKey('mediaIds') &&
            (!_socialMediaIds(value['mediaIds']) ||
                value['contentHash'] !=
                    _socialContentHash(
                      value['text'],
                      List<String>.from(value['mediaIds']),
                    ) ||
                value['mediaId'] !=
                    ((value['mediaIds'] as List).isEmpty
                        ? null
                        : value['mediaIds'][0])) ||
        !_mutationId(value['authorUid']) ||
        !ids.add(value['id']) ||
        value['text'] != null && !_socialText(value['text']) ||
        value['mediaId'] != null && !_mutationId(value['mediaId']) ||
        value['createdAt'] != null && !_mutationStamp(value['createdAt']) ||
        (comments
            ? value['liked'] is! bool ||
                  value['parentId'] != null && !_mutationId(value['parentId'])
            : !_mutationInteger(value['likeCount']) ||
                  !_mutationInteger(value['commentCount']) ||
                  value['liked'] is! bool)) {
      _peopleInvalid();
    }
    if (previousId != null &&
        _socialCompare(
              previousDate,
              previousId,
              value['createdAt'],
              value['id'],
              comments,
            ) >=
            0) {
      _peopleInvalid();
    }
    previousId = value['id'];
    previousDate = value['createdAt'];
    items.add(TimewebSocialItem._(Map.unmodifiable(value), f.checkSession));
  }
  final expires =
      cursor?._expiresAt ?? f.startedAt.add(const Duration(seconds: 300));
  return TimewebSocialPage._(
    List.unmodifiable(items),
    next == null
        ? null
        : TimewebSocialCursor._(
            next,
            f.owner,
            scope,
            expires,
            previousDate,
            previousId!,
            f.checkSession,
          ),
    !comments && body['canPublish'] == true,
    !comments && body['canModerate'] == true,
    f.checkSession,
  );
}

int _socialCompare(
  String? aDate,
  String aId,
  String? bDate,
  String bId,
  bool comments,
) {
  final date = aDate == null
      ? (bDate == null ? 0 : -1)
      : bDate == null
      ? 1
      : aDate.compareTo(bDate);
  final compared = date != 0 ? date : _currentCompareIds(aId, bId);
  return comments ? compared : -compared;
}

extension TimewebSocialRetry on TimewebAuthClient {
  Future<TimewebMutationResult> retryOriginalSocialAction(
    TimewebMutationReference reference,
  ) {
    _checkMutationOwner(this, reference);
    if (reference._request.kind != TimewebMutationKind.socialAction ||
        reference._settledResult?.state != TimewebMutationState.notFound) {
      throw StateError(
        'Check the original social operation before retrying it.',
      );
    }
    reference._postFlight = null;
    return _mutate(this, reference);
  }
}
