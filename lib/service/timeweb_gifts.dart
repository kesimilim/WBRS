part of 'timeweb_auth_client.dart';

bool _giftId(Object? value) =>
    value is String &&
    RegExp(r'^assets/gifts/(?:[1-9]|[1-5][0-9]|6[0-4])\.png$').hasMatch(value);

/// Server catalog IDs are existing bundled images, not arbitrary URLs.
final class TimewebGiftAction {
  TimewebGiftAction._(this.payload);
  final Map<String, dynamic> payload;
  factory TimewebGiftAction.buy(String giftId, int expectedWalletRevision) =>
      TimewebGiftAction.fromPayload({
        'kind': 'buy',
        'giftId': giftId,
        'expectedWalletRevision': expectedWalletRevision,
      });
  factory TimewebGiftAction.send(
    String giftId,
    String chatId,
    int expectedOwnedQuantity,
  ) => TimewebGiftAction.fromPayload({
    'kind': 'send',
    'giftId': giftId,
    'chatId': chatId,
    'expectedOwnedQuantity': expectedOwnedQuantity,
  });
  factory TimewebGiftAction.fromPayload(Map<String, dynamic> value) {
    final buying = value['kind'] == 'buy';
    if (!const {'buy', 'send'}.contains(value['kind']) ||
        !_mutationExact(
          value,
          buying
              ? {'kind', 'giftId', 'expectedWalletRevision'}
              : {'kind', 'giftId', 'chatId', 'expectedOwnedQuantity'},
        ) ||
        !_giftId(value['giftId']) ||
        !_mutationInteger(
          value[buying ? 'expectedWalletRevision' : 'expectedOwnedQuantity'],
        ) ||
        !buying && !_mutationId(value['chatId'])) {
      throw ArgumentError('Invalid native gift action.');
    }
    return TimewebGiftAction._(Map<String, dynamic>.unmodifiable(value));
  }
  String get kind => payload['kind'];
  String get operation => 'gift.$kind.v1';
  @override
  String toString() => 'TimewebGiftAction(<redacted>)';
}

final class TimewebGiftReceipt {
  TimewebGiftReceipt._(this._data, this._kind, this._check);
  final Map<String, dynamic> _data;
  final String _kind;
  final void Function() _check;
  void requireCurrent() => _check();
  String get kind {
    _check();
    return _kind;
  }

  String get giftId {
    _check();
    return _data['giftId'];
  }

  String? get chatId {
    _check();
    return _data['chatId'];
  }

  String? get recipientUid {
    _check();
    return _data['recipientUid'];
  }

  String? get messageId {
    _check();
    return _data['messageId'];
  }

  int? get balanceAg {
    _check();
    return _data['balanceAg'];
  }

  int? get walletRevision {
    _check();
    return _data['walletRevision'];
  }

  TimewebGiftReceipt bindSessionGuard(void Function() guard) =>
      TimewebGiftReceipt._(_data, _kind, () {
        _check();
        guard();
      });
  @override
  String toString() => 'TimewebGiftReceipt(<redacted>)';
}

TimewebMutationResult _decodeGiftReceipt(
  TimewebMutationReference ref,
  _Reply reply,
  Map<String, dynamic> result,
  bool replayed,
  int? revision,
) {
  final p = ref._request._payload, buying = p['kind'] == 'buy';
  if (reply.status == 409) {
    final failure = switch (result['error']) {
      'balance_changed' when buying => TimewebMutationFailure.balanceChanged,
      'insufficient_silver' when buying =>
        TimewebMutationFailure.insufficientSilver,
      'inventory_changed' when !buying =>
        TimewebMutationFailure.inventoryChanged,
      'gift_not_owned' when !buying => TimewebMutationFailure.giftNotOwned,
      _ => null,
    };
    if (!_mutationExact(result, {'error'}) ||
        failure == null ||
        buying && revision == null ||
        !buying && revision != null) {
      _mutationInvalidReply();
    }
    return TimewebMutationResult._(
      ref,
      TimewebMutationState.declaredFailure,
      409,
      failure: failure,
      revision: revision,
      replayed: replayed,
      receiptConfirmed: true,
    );
  }
  final derived =
      'tw-gift-${crypto.sha256.convert(utf8.encode(_mutationCanonical([ref._uid, ref._request.operationId])))}';
  if (reply.status != 201 ||
      result['giftId'] != p['giftId'] ||
      !_mutationExact(
        result,
        buying
            ? {'giftId', 'entryId', 'balanceAg', 'walletRevision'}
            : {
                'giftId',
                'transferId',
                'recipientUid',
                'chatId',
                'messageId',
                'sequence',
              },
      )) {
    _mutationInvalidReply();
  }
  if (buying) {
    if (result['entryId'] != derived ||
        !_mutationInteger(result['balanceAg']) ||
        !_mutationInteger(result['walletRevision']) ||
        result['walletRevision'] != p['expectedWalletRevision'] + 1 ||
        revision != result['walletRevision']) {
      _mutationInvalidReply();
    }
  } else {
    final message =
        'tw-${crypto.sha256.convert(utf8.encode(_mutationCanonical([ref._uid, ref._request.operationId, 'gift-notice'])))}';
    if (revision != null ||
        result['transferId'] != derived ||
        result['chatId'] != p['chatId'] ||
        !_mutationId(result['recipientUid']) ||
        result['recipientUid'] == ref._uid ||
        result['messageId'] != message ||
        !_mutationInteger(result['sequence']) ||
        result['sequence'] < 1) {
      _mutationInvalidReply();
    }
  }
  return TimewebMutationResult._(
    ref,
    TimewebMutationState.confirmed,
    201,
    revision: revision,
    replayed: replayed,
    receiptConfirmed: true,
    gift: TimewebGiftReceipt._(
      Map<String, dynamic>.unmodifiable(result),
      p['kind'],
      ref.requireCurrent,
    ),
  );
}

final class TimewebGiftCatalogItem {
  TimewebGiftCatalogItem._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  String get id {
    _check();
    return _data['id'];
  }

  String get assetPath {
    _check();
    return _data['assetPath'];
  }

  String get name {
    _check();
    return _data['name'];
  }

  int? get priceAg {
    _check();
    return _data['priceAg'];
  }

  @override
  String toString() => 'TimewebGiftCatalogItem(<redacted>)';
}

final class TimewebGiftInventoryItem {
  TimewebGiftInventoryItem._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  String get giftId {
    _check();
    return _data['giftId'];
  }

  int get ownedQuantity {
    _check();
    return _data['ownedQuantity'];
  }

  int get receivedQuantity {
    _check();
    return _data['receivedQuantity'];
  }

  @override
  String toString() => 'TimewebGiftInventoryItem(<redacted>)';
}

final class TimewebGiftInventory {
  TimewebGiftInventory._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  int get balanceAg {
    _check();
    return _data['balanceAg'];
  }

  int get walletRevision {
    _check();
    return _data['walletRevision'];
  }

  List<TimewebGiftCatalogItem> get catalog {
    _check();
    return List.unmodifiable(
      (_data['catalog'] as List<Map<String, dynamic>>).map(
        (v) => TimewebGiftCatalogItem._(v, _check),
      ),
    );
  }

  List<TimewebGiftInventoryItem> get inventory {
    _check();
    return List.unmodifiable(
      (_data['inventory'] as List<Map<String, dynamic>>).map(
        (v) => TimewebGiftInventoryItem._(v, _check),
      ),
    );
  }

  int owned(String id) {
    _check();
    return inventory.where((v) => v.giftId == id).firstOrNull?.ownedQuantity ??
        0;
  }

  int received(String id) {
    _check();
    return inventory
            .where((v) => v.giftId == id)
            .firstOrNull
            ?.receivedQuantity ??
        0;
  }

  TimewebGiftInventory bindSessionGuard(void Function() guard) =>
      TimewebGiftInventory._(_data, () {
        _check();
        guard();
      });
  @override
  String toString() => 'TimewebGiftInventory(<redacted>)';
}

final class TimewebGiftAccessDenied implements Exception {
  const TimewebGiftAccessDenied();
}

extension TimewebGiftReads on TimewebAuthClient {
  Future<TimewebGiftInventory> readGifts() {
    try {
      _checkEnabled(_peopleOperation);
      if (!configuration.currentReadsEnabled ||
          !configuration.runtimeWritesEnabled) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.disabled,
        );
      }
      final session = _session;
      if (session == null || _secureStoreUnsafe) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.notAuthenticated,
        );
      }
      final key = '$_epoch\u0000gifts';
      final prior = _peopleFlights[key];
      if (prior != null) {
        return prior.result.future.then((v) => v as TimewebGiftInventory);
      }
      if (_peopleFlights.length >= 4) {
        throw const TimewebAuthException(
          _peopleOperation,
          TimewebAuthError.unavailable,
        );
      }
      final f = _PeopleFlight(this, null, null, null, _epoch, session.uid, key);
      _peopleFlights[key] = f;
      unawaited(_executeGiftRead(f));
      return f.result.future.then((v) => v as TimewebGiftInventory);
    } catch (error) {
      return Future.error(error);
    }
  }
}

Future<void> _executeGiftRead(_PeopleFlight f) async {
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
      pathSegments: ['v1', 'runtime', 'gifts', 'mine'],
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
        throw const TimewebGiftAccessDenied();
      }
      throw owner._statusError(_peopleOperation, reply.status);
    }
    final b = reply.body!;
    if (!_mutationExact(b, {
          'kind',
          'balanceAg',
          'walletRevision',
          'inventory',
          'catalog',
        }) ||
        b['kind'] != 'native-gifts' ||
        !_mutationInteger(b['balanceAg']) ||
        !_mutationInteger(b['walletRevision']) ||
        b['catalog'] is! List ||
        b['inventory'] is! List ||
        b['catalog'].length > 64 ||
        b['inventory'].length > 64) {
      _mutationInvalidReply();
    }
    final ids = <String>{};
    final catalog = <Map<String, dynamic>>[];
    for (final v in b['catalog']) {
      if (v is! Map<String, dynamic> ||
          !_mutationExact(v, {'id', 'assetPath', 'name', 'priceAg'}) ||
          !_giftId(v['id']) ||
          v['assetPath'] != v['id'] ||
          !_mutationText(v['name'], maximum: 191) ||
          v['priceAg'] != null && !_mutationInteger(v['priceAg']) ||
          !ids.add(v['id'])) {
        _mutationInvalidReply();
      }
      catalog.add(Map<String, dynamic>.unmodifiable(v));
    }
    ids.clear();
    final inventory = <Map<String, dynamic>>[];
    for (final v in b['inventory']) {
      if (v is! Map<String, dynamic> ||
          !_mutationExact(v, {'giftId', 'ownedQuantity', 'receivedQuantity'}) ||
          !_giftId(v['giftId']) ||
          !_mutationInteger(v['ownedQuantity']) ||
          !_mutationInteger(v['receivedQuantity']) ||
          !ids.add(v['giftId'])) {
        _mutationInvalidReply();
      }
      inventory.add(Map<String, dynamic>.unmodifiable(v));
    }
    final result = TimewebGiftInventory._(
      Map<String, dynamic>.unmodifiable({
        ...b,
        'catalog': List<Map<String, dynamic>>.unmodifiable(catalog),
        'inventory': List<Map<String, dynamic>>.unmodifiable(inventory),
      }),
      f.checkSession,
    );
    f.check();
    if (!f.result.isCompleted) {
      f.result.complete(result);
    }
  } catch (error) {
    if (!f.result.isCompleted) {
      try {
        f.check();
        f.result.completeError(
          error is TimewebAuthException || error is TimewebGiftAccessDenied
              ? error
              : const TimewebAuthException(
                  _peopleOperation,
                  TimewebAuthError.invalidResponse,
                ),
        );
      } catch (stale) {
        if (!f.result.isCompleted) {
          f.result.completeError(stale);
        }
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
