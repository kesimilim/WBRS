import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_session.dart';
import 'timeweb_auth_client.dart';

enum TimewebChatWriteOutcome { confirmed, declined, unknown }

/// Existing canonical chat only, using the runtime's actual client and leases.
/// Send and own-read receipts are independent; an unknown read cannot block a
/// new text send or be mistaken for the counterpart having read that text.
final class TimewebChatFlow {
  TimewebChatFlow._(
    this._client,
    this._session,
    this._lease,
    this._journal,
    this._chat, [
    this._opened,
  ]);
  final TimewebAuthClient _client;
  final AppSession _session;
  final AppSessionLease _lease;
  final TimewebChatJournal _journal;
  final TimewebCurrentChat? _chat;
  final TimewebOpenedPersonalChatReceipt? _opened;
  List<TimewebCurrentMessage> _messages = [];
  TimewebCurrentReadCursor? _older;
  Future<void>? _readFlight;
  final _intents = <bool, _ChatIntent>{};
  final _references = <bool, TimewebMutationReference>{};
  final _writes = <bool, Future<TimewebChatWriteOutcome>>{};
  TimewebChatWriteOutcome? _completedSend;
  // Zero is only a local lower bound until a current own-read receipt arrives.
  late int _knownRead = _chat?.readThrough ?? 0;
  bool _closed = false;
  static const _limit = 50, _maximumMessages = 300;

  static Future<TimewebChatFlow> open({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebChatJournal journal,
    required TimewebCurrentChat chat,
  }) async {
    lease.requireCurrent();
    chat.requireCurrent();
    final flow = TimewebChatFlow._(client, session, lease, journal, chat);
    await flow
        .loadLatest(); // server checks current membership, not a supplied UID
    await flow._restoreIntents();
    return flow;
  }

  static Future<TimewebChatFlow> openPersonal({
    required TimewebAuthClient client,
    required AppSession session,
    required AppSessionLease lease,
    required TimewebChatJournal journal,
    required TimewebOpenedPersonalChatReceipt receipt,
  }) async {
    lease.requireCurrent();
    receipt.requireClient(client);
    if (receipt.ownerUid != lease.identity.uid ||
        receipt.peerUid == lease.identity.uid) {
      throw StateError('Personal chat receipt owner mismatch.');
    }
    final flow = TimewebChatFlow._(
      client,
      session,
      lease,
      journal,
      null,
      receipt,
    );
    await flow.loadLatest(); // fresh current membership check for the exact ID
    await flow._restoreIntents();
    return flow;
  }

  Future<void> _restoreIntents() async {
    for (final read in [false, true]) {
      final intent = await _journal._load(
        _origin,
        _lease.identity.uid,
        chatId,
        read,
      );
      requireCurrent();
      if (intent != null) {
        _intents[read] = intent;
        _references[read] = _client.bindMutation(
          intent.request,
          expectedOwnerUid: _lease.identity.uid,
        );
      }
    }
  }

  String get _origin => _client.configuration.endpoint.toString();
  void requireCurrent() {
    if (_closed) throw StateError('Chat screen is closed.');
    _lease.requireCurrent();
    _chat?.requireCurrent();
    _opened?.requireCurrent();
  }

  Stream<AppSessionState> get sessionStates => _session.states;
  Duration get observationTimeout =>
      _client.requestDeadline + const Duration(seconds: 2);
  String? get name {
    requireCurrent();
    return _chat?.name;
  }

  String get ownerUid {
    requireCurrent();
    return _lease.identity.uid;
  }

  String get chatId {
    requireCurrent();
    return _chat?.chatId ?? _opened!.chatId;
  }

  List<TimewebCurrentMessage> get messages {
    requireCurrent();
    for (final message in _messages) {
      message.requireCurrent();
    }
    return List.unmodifiable(_messages);
  }

  bool get hasOlder {
    requireCurrent();
    return _older != null;
  }

  bool get sendNeedsCheck {
    requireCurrent();
    return _intents.containsKey(false) ||
        _writes.containsKey(false) ||
        _completedSend != null;
  }

  String? get pendingText {
    requireCurrent();
    return _intents[false]?.payload['text'] as String?;
  }

  Future<void> loadLatest() => _load(false);
  Future<void> loadOlder() => _load(true);
  Future<void> loadUpdates() => _load(false, updates: true);
  Future<TimewebCurrentReadPage> readEvents(
    TimewebCurrentReadCursor? after,
  ) async {
    requireCurrent();
    final page = await _client.readCurrent(
      TimewebCurrentReadRequest.events(limit: 100, after: after),
    );
    requireCurrent();
    page.requireCurrent();
    return page;
  }

  Future<void> _load(bool older, {bool updates = false}) {
    requireCurrent();
    if (_readFlight != null) return _readFlight!;
    if (older && !hasOlder) return Future.value();
    final future = (() async {
      final page = await _client.readCurrent(
        TimewebCurrentReadRequest.messages(
          chatId,
          limit: _limit,
          before: older ? _older : null,
        ),
      );
      requireCurrent();
      page.requireCurrent();
      if (_opened != null && page.chatRevision! < _opened.chatRevision) {
        throw StateError('Current chat revision precedes its receipt.');
      }
      final rows = <String, TimewebCurrentMessage>{
        if (older || updates)
          for (final message in _messages) message.messageId: message,
        for (final message in page.messages) message.messageId: message,
      }.values.toList()..sort((a, b) => b.sequence.compareTo(a.sequence));
      // Keep the oldest continuation intact while bounding the rendered window.
      // A manual latest refresh restores the newest page without a bare cursor.
      final capped = rows.length > _maximumMessages;
      if (capped) {
        if (updates) {
          rows.removeRange(_maximumMessages, rows.length);
        } else {
          rows.removeRange(0, rows.length - _maximumMessages);
        }
      }
      _messages = rows;
      if (!updates || capped || _older == null) _older = page.nextCursor;
    })();
    _readFlight = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_readFlight, future)) _readFlight = null;
        },
        onError: (Object _, StackTrace __) {
          if (identical(_readFlight, future)) _readFlight = null;
        },
      ),
    );
    return future;
  }

  Future<TimewebChatWriteOutcome> send(String originalText) {
    requireCurrent();
    if (_writes[false] != null) return _writes[false]!;
    if (sendNeedsCheck) {
      throw StateError('Check the original text operation first.');
    }
    final intent = _ChatIntent(_origin, ownerUid, chatId, false, _uuid(), {
      'chatId': chatId,
      'text': originalText,
      'quoteMessageId': null,
    });
    return _start(intent);
  }

  Future<TimewebChatWriteOutcome> checkSend() {
    requireCurrent();
    if (_writes[false] != null) return _writes[false]!;
    if (_completedSend != null) return Future.value(_completedSend);
    return _lookup(false);
  }

  void acceptDisplayedSendResult() {
    requireCurrent();
    if (_completedSend == null) {
      throw StateError('Send is not confirmed or declined.');
    }
    _completedSend = null;
  }

  /// Call after the newest page is displayed on the current route. An existing
  /// uncertain marker is checked under its own original UUID, never resent.
  Future<TimewebChatWriteOutcome> markDisplayedRead() {
    requireCurrent();
    if (_writes[true] != null) return _writes[true]!;
    if (_intents.containsKey(true)) return _lookup(true);
    final through = _messages.isEmpty ? 0 : _messages.first.sequence;
    if (through <= _knownRead) {
      return Future.value(TimewebChatWriteOutcome.confirmed);
    }
    return _start(
      _ChatIntent(_origin, ownerUid, chatId, true, _uuid(), {
        'chatId': chatId,
        'throughSequence': through,
      }),
    );
  }

  Future<TimewebChatWriteOutcome> _start(_ChatIntent intent) =>
      _track(intent.read, () async {
        await _journal._prepare(intent);
        requireCurrent();
        _intents[intent.read] = intent;
        final reference = _client.bindMutation(
          intent.request,
          expectedOwnerUid: ownerUid,
        );
        _references[intent.read] = reference;
        return _finish(intent.read, await _client.mutate(reference));
      });
  Future<TimewebChatWriteOutcome> _lookup(bool read) {
    final reference = _references[read];
    if (reference == null) {
      throw StateError('No original chat operation to lookup.');
    }
    return _track(
      read,
      () async => _finish(read, await _client.reconcileMutation(reference)),
    );
  }

  Future<TimewebChatWriteOutcome> _track(
    bool read,
    Future<TimewebChatWriteOutcome> Function() action,
  ) {
    final future = Future<TimewebChatWriteOutcome>.sync(action);
    _writes[read] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_writes[read], future)) _writes.remove(read);
        },
        onError: (Object _, StackTrace __) {
          if (identical(_writes[read], future)) _writes.remove(read);
        },
      ),
    );
    return future;
  }

  Future<TimewebChatWriteOutcome> _finish(
    bool read,
    TimewebMutationResult result,
  ) async {
    requireCurrent();
    result.requireCurrent();
    if (!result.canAcknowledge) return TimewebChatWriteOutcome.unknown;
    final confirmed =
        result.state == TimewebMutationState.confirmed &&
        (read ? result.readReceipt != null : result.message != null);
    final through = confirmed && read
        ? result.readReceipt!.readThroughSequence
        : null;
    await _journal._acknowledge(_intents[read]!);
    requireCurrent();
    _client.acknowledgeMutation(_references[read]!);
    _intents.remove(read);
    _references.remove(read);
    if (through != null && through > _knownRead) _knownRead = through;
    final outcome = confirmed
        ? TimewebChatWriteOutcome.confirmed
        : TimewebChatWriteOutcome.declined;
    if (!read) _completedSend = outcome;
    return outcome;
  }

  void close() => _closed = true;
  @override
  String toString() => 'TimewebChatFlow(<redacted>)';
}

/// Two narrow intent shapes, one serialized private-disk owner. This is not a
/// transport or arbitrary mutation framework. Recovered entries are lookup-only.
final class TimewebChatJournal {
  TimewebChatJournal({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();
  static const _bound = 32768;
  Future<T> _serial<T>(Future<T> Function() action) {
    final task = _tail.then((_) => action());
    _tail = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  Future<void> drain() => _tail;
  Future<File> _file(
    String origin,
    String uid,
    String chatId,
    bool read,
  ) async {
    final root = await _directory();
    final folder = Directory('${root.path}/clrs_native_chat_intents');
    await folder.create(recursive: true);
    final key = sha256.convert(
      utf8.encode('$origin\u0000$uid\u0000$chatId\u0000$read'),
    );
    return File('${folder.path}/$key.json');
  }

  Future<_ChatIntent?> _read(
    File file,
    String origin,
    String uid,
    String chatId,
    bool read,
  ) async {
    if (!await file.exists()) return null;
    if (await file.length() > _bound) {
      throw const FormatException('Invalid private chat intent.');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      bytes.addAll(chunk);
      if (bytes.length > _bound) {
        throw const FormatException('Invalid private chat intent.');
      }
    }
    final raw = utf8.decode(bytes), data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        jsonEncode(data) != raw ||
        data.length != 8 ||
        data['version'] != 1 ||
        data['origin'] != origin ||
        data['uid'] != uid ||
        data['chatId'] != chatId ||
        data['operation'] !=
            (read ? 'chat.mark-read.v1' : 'chat.send-text.v1') ||
        data['operationId'] is! String ||
        data['requestHash'] is! String ||
        data['payload'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid private chat intent.');
    }
    final payload = data['payload'] as Map<String, dynamic>;
    if (payload['chatId'] != chatId ||
        (read
            ? payload.length != 2 || payload['throughSequence'] is! int
            : payload.length != 3 ||
                  payload['text'] is! String ||
                  !payload.containsKey('quoteMessageId') ||
                  payload['quoteMessageId'] != null)) {
      throw const FormatException('Invalid private chat intent.');
    }
    final intent = _ChatIntent(
      origin,
      uid,
      chatId,
      read,
      data['operationId'],
      payload,
    );
    if (intent.request.requestHash != data['requestHash']) {
      throw const FormatException('Invalid private chat intent.');
    }
    return intent;
  }

  Future<_ChatIntent?> _load(
    String origin,
    String uid,
    String chatId,
    bool read,
  ) => _serial(
    () async => _read(
      await _file(origin, uid, chatId, read),
      origin,
      uid,
      chatId,
      read,
    ),
  );
  Future<void> _prepare(_ChatIntent intent) => _serial(() async {
    final file = await _file(
      intent.origin,
      intent.uid,
      intent.chatId,
      intent.read,
    );
    if (await _read(
          file,
          intent.origin,
          intent.uid,
          intent.chatId,
          intent.read,
        ) !=
        null) {
      throw StateError('Original chat operation remains unresolved.');
    }
    final data = jsonEncode(intent.data);
    if (utf8.encode(data).length > _bound) {
      throw const FormatException('Private chat intent exceeds its bound.');
    }
    final temporary = File('${file.path}.${intent.id}.tmp');
    try {
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<void> _acknowledge(_ChatIntent intent) => _serial(() async {
    final file = await _file(
      intent.origin,
      intent.uid,
      intent.chatId,
      intent.read,
    );
    final current = await _read(
      file,
      intent.origin,
      intent.uid,
      intent.chatId,
      intent.read,
    );
    if (current == null ||
        current.id != intent.id ||
        current.request.requestHash != intent.request.requestHash) {
      throw StateError('Original private chat intent is unavailable.');
    }
    await file.delete();
  });
  @override
  String toString() => 'TimewebChatJournal(<redacted>)';
}

final class _ChatIntent {
  _ChatIntent(
    this.origin,
    this.uid,
    this.chatId,
    this.read,
    this.id,
    Map<String, dynamic> payload,
  ) : payload = Map.unmodifiable(payload) {
    request = read
        ? TimewebMutationRequest.markRead(
            operationId: id,
            chatId: chatId,
            throughSequence: payload['throughSequence'],
          )
        : TimewebMutationRequest.sendMessage(
            operationId: id,
            chatId: chatId,
            text: payload['text'],
          );
  }
  final String origin, uid, chatId, id;
  final bool read;
  final Map<String, dynamic> payload;
  late final TimewebMutationRequest request;
  Map<String, Object> get data => {
    'version': 1,
    'origin': origin,
    'uid': uid,
    'chatId': chatId,
    'operation': request.operation,
    'operationId': id,
    'payload': payload,
    'requestHash': request.requestHash,
  };
  @override
  String toString() => 'PrivateChatIntent(<redacted>)';
}

String _uuid() {
  final random = Random.secure(), bytes = List.generate(16, (_) => 0);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
