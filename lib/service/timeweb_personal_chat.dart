part of 'timeweb_auth_client.dart';

/// Only the committed pair receipt. It does not claim chat settings, presence,
/// read counters, display names, media or creation of a message.
final class TimewebOpenedPersonalChatReceipt {
  TimewebOpenedPersonalChatReceipt._(this._data, this._reference, this._check);
  final Map<String, dynamic> _data;
  final TimewebMutationReference _reference;
  final void Function() _check;
  void requireCurrent() => _check();
  void requireClient(TimewebAuthClient client) {
    requireCurrent();
    if (!identical(client, _reference._owner)) {
      throw const TimewebAuthException(
        _mutationOperation,
        TimewebAuthError.invalidRequest,
      );
    }
  }

  TimewebOpenedPersonalChatReceipt bindSessionGuard(void Function() check) =>
      TimewebOpenedPersonalChatReceipt._(_data, _reference, () {
        requireCurrent();
        check();
      });
  String get ownerUid {
    requireCurrent();
    return _reference._uid;
  }

  String get chatId {
    requireCurrent();
    return _data['chatId'];
  }

  String get peerUid {
    requireCurrent();
    return _data['peerUid'];
  }

  bool get created {
    requireCurrent();
    return _data['created'];
  }

  int get chatRevision {
    requireCurrent();
    return _data['chatRevision'];
  }

  @override
  String toString() => 'TimewebOpenedPersonalChatReceipt(<redacted>)';
}

TimewebMutationResult _decodeOpenedPersonalChat(
  TimewebMutationReference ref,
  int status,
  Map<String, dynamic> result,
  int? revision,
  bool replayed,
) {
  if (!_mutationExact(result, {
        'chatId',
        'peerUid',
        'created',
        'chatRevision',
      }) ||
      !_mutationId(result['chatId']) ||
      result['peerUid'] != ref._request._payload['targetUid'] ||
      result['peerUid'] == ref._uid ||
      result['created'] is! bool ||
      !_mutationInteger(result['chatRevision']) ||
      revision != result['chatRevision'] ||
      status != (result['created'] ? 201 : 200)) {
    _mutationInvalidReply();
  }
  return TimewebMutationResult._(
    ref,
    TimewebMutationState.confirmed,
    status,
    replayed: replayed,
    revision: revision,
    receiptConfirmed: true,
    personalChat: TimewebOpenedPersonalChatReceipt._(
      result,
      ref,
      ref.requireCurrent,
    ),
  );
}
