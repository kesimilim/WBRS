part of 'timeweb_auth_client.dart';

bool _pushSid(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(value);
bool _pushKind(TimewebMutationKind kind) => const {
  TimewebMutationKind.registerPushToken,
  TimewebMutationKind.revokePushToken,
}.contains(kind);

/// The original SID/digest is durable. The actual FCM token exists only until
/// the first POST finishes; restored actions cannot produce another POST.
final class TimewebPushAction {
  factory TimewebPushAction.register({
    required String sessionId,
    required String token,
  }) {
    if (token.length < 20 ||
        token.length > 4096 ||
        token.codeUnits.any((v) => v < 33 || v > 126)) {
      throw ArgumentError('Invalid native push token.');
    }
    return TimewebPushAction._(
      sessionId,
      crypto.sha256.convert(utf8.encode(token)).toString(),
      token,
    );
  }
  TimewebPushAction.revoke({required String sessionId})
    : this._(sessionId, null, null);
  factory TimewebPushAction.restore(Map<String, dynamic> payload) {
    final register = payload.containsKey('tokenHash');
    if (!_mutationExact(
          payload,
          register ? {'sessionId', 'tokenHash'} : {'sessionId'},
        ) ||
        !_pushSid(payload['sessionId']) ||
        (register && payload['tokenHash'] is! String)) {
      throw ArgumentError('Invalid original push intent.');
    }
    return TimewebPushAction._(
      payload['sessionId'],
      payload['tokenHash'],
      null,
    );
  }
  TimewebPushAction._(this.sessionId, this.tokenHash, this._token) {
    if (!_pushSid(sessionId) ||
        (tokenHash != null &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(tokenHash!))) {
      throw ArgumentError('Invalid original push intent.');
    }
  }
  final String sessionId;
  final String? tokenHash;
  String? _token;
  bool get register => tokenHash != null;
  Map<String, dynamic> get payload => Map.unmodifiable({
    'sessionId': sessionId,
    if (register) 'tokenHash': tokenHash,
  });
  Map<String, dynamic> wire(String id) => {
    'operationId': id,
    if (register && _token != null) 'token': _token,
  };
  void requirePostSession(String? sid) {
    if (sid != sessionId || register && _token == null) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.staleSession,
      );
    }
  }

  void discardToken() => _token = null;
  @override
  String toString() => 'TimewebPushAction(<redacted>)';
}

/// A historical original acknowledgement is not current delivery authority.
final class TimewebPushReceipt {
  TimewebPushReceipt._(this._sid, this._registered, this._check);
  final String _sid;
  final bool _registered;
  final void Function() _check;
  void requireCurrent() => _check();
  String get sessionId {
    _check();
    return _sid;
  }

  bool get registered {
    _check();
    return _registered;
  }

  TimewebPushReceipt bindSessionGuard(void Function() guard) =>
      TimewebPushReceipt._(_sid, _registered, () {
        _check();
        guard();
      });
  @override
  String toString() => 'TimewebPushReceipt(<redacted>)';
}

TimewebMutationResult _decodePushReceipt(
  TimewebMutationReference ref,
  _Reply reply,
  Map<String, dynamic> result,
  bool replayed,
  int? revision,
) {
  final action = ref._request._push!;
  if (revision != null) {
    _mutationInvalidReply();
  }
  if (reply.status == 409 && action.register) {
    final failure = switch (result['error']) {
      'token_in_use' => TimewebMutationFailure.pushTokenInUse,
      'device_limit' => TimewebMutationFailure.pushDeviceLimit,
      _ => null,
    };
    if (!_mutationExact(result, {'error'}) || failure == null) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      409,
      failure: failure,
      replayed: replayed,
      receiptConfirmed: true,
    );
  }
  final key = action.register ? 'registered' : 'revoked';
  if (reply.status != 200 ||
      !_mutationExact(result, {'kind', 'sessionId', key}) ||
      result['kind'] != 'canonical-native-push' ||
      result['sessionId'] != action.sessionId ||
      result[key] != true) {
    _mutationInvalidReply();
  }
  return TimewebMutationResult._(
    ref,
    TimewebMutationState.confirmed,
    200,
    replayed: replayed,
    receiptConfirmed: true,
    push: TimewebPushReceipt._(
      action.sessionId,
      action.register,
      ref.requireCurrent,
    ),
  );
}

extension TimewebPushSession on TimewebAuthClient {
  /// Refresh before a new original digest is formed, not after it is journaled.
  Future<String> preparePushSession() async {
    _checkEnabled(_mutationOperation);
    final current = _session;
    if (current == null) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    if (!_clock().add(accessExpirySkew).isBefore(current.accessExpiresAt)) {
      await refresh();
    }
    final sid = currentPushSessionId;
    if (sid == null) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.notAuthenticated,
      );
    }
    return sid;
  }

  /// Nonsecret, already-authenticated token identifier; never exposes a bearer.
  String? get currentPushSessionId {
    if (!hasSession) return null;
    final parts = _session!.accessToken.split('.');
    if (parts.length != 3 || parts.first != 'na1' || !_pushSid(parts[1])) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.invalidResponse,
      );
    }
    return parts[1];
  }
}
