import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'support/timeweb_people_fixtures.dart';

const op = '12345678-1234-4234-8234-123456789abc';
const local = '03.10.2026 18:30';
String derived([String uid = 'A', String id = op]) => 'tw-meeting-${sha256.convert(utf8.encode('clrs-native-meeting-v1\u0000${jsonEncode([uid, id])}'))}';
Future<TimewebMeetingCreateRequest> draft({String description = '', String type = 'групповая', String? invitedUid, String datetime = local}) =>
    TimewebMeetingCreateRequest.fromCatalog(name: '  Живая встреча  ', description: description, countryCode: 'RU', region: 'Республика Адыгея', datetime: datetime, type: type, invitedUid: invitedUid);
Map<String, dynamic> created([Map<String, dynamic> edits = const {}]) => {'meetingId': derived(), 'created': true, 'meetingRevision': 0, 'localDatetime': local, ...edits};
Map<String, dynamic> envelope(TimewebMutationRequest request, Object? result, {bool replayed = false, bool absent = false, int? revision = 0}) => {
  'operation': request.operation, 'operationId': request.operationId, 'requestHash': request.requestHash,
  'state': absent ? 'not_found' : 'committed', 'replayed': replayed, 'result': result, 'entityRevision': absent ? null : revision,
};
Map<String, dynamic> meeting(String id, {String kind = 'group', String? invited, Map<String, dynamic> edits = const {}}) => {
  'meetingId': id, 'organizerUid': 'A', 'invitedUid': invited, 'kind': kind,
  'title': '  Живая встреча  ', 'description': '', 'countryCode': 'RU', 'region': 'Республика Адыгея',
  'startsAt': null, 'localDatetime': local, 'createdAt': peopleStamp, 'updatedAt': null, 'revision': 0,
  'media': null, 'mediaReady': false, ...edits,
};
Map<String, dynamic> list(List<Object?> items, {String? cursor, String scope = 'group'}) => {
  'kind': 'canonical-current', 'ordering': 'starts_at_asc_meeting_id_asc_null_first',
  'scope': scope, 'items': items, 'nextCursor': cursor, 'mediaReady': false,
};
Map<String, dynamic> detail(Map<String, dynamic> item) => {'kind': 'canonical-current', 'meeting': item, 'mediaReady': false};
Map<String, dynamic> roster(List<Object?> items, {String id = 'M', String? cursor}) => {
  'kind': 'canonical-current', 'meetingId': id, 'ordering': 'uid_binary_asc', 'items': items, 'nextCursor': cursor, 'mediaReady': false,
};
Map<String, dynamic> participant(String uid) => {'uid': uid, 'fullName': null, 'primaryGroup': null, 'joinedAt': null, 'membershipRevision': 0, 'avatar': null, 'mediaReady': false};
TimewebAuthClient client(PeopleWire wire, {bool enabled = true, PeopleStore? store, DateTime Function()? clock}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(endpoint: Uri.parse('https://api.example.invalid'), enabled: true, currentReadsEnabled: enabled, runtimeWritesEnabled: enabled),
  secureStore: store ?? PeopleStore(), transport: wire, clock: clock ?? () => peopleNow,
);
Matcher error(TimewebAuthError value) => isA<TimewebAuthException>().having((e) => e.error, 'error', value);
Future<void> tick(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) { await Future<void>.delayed(Duration.zero); }
  expect(ready(), isTrue);
}

Future<void> attachMeetingCatalog() async {
  final bytes = await File('assets/geo_catalog.json').readAsBytes();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler('flutter/assets', (message) async {
    final name = utf8.decode(message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes));
    return name == 'assets/geo_catalog.json' ? ByteData.sublistView(bytes) : null;
  });
  addTearDown(() => messenger.setMockMessageHandler('flutter/assets', null));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('exact native request and derived receipt; empty description, original bytes, catalog and calendar; default off', () async {
    final input = await draft(description: ' \r\n\t');
    final request = TimewebMutationRequest.createMeeting(operationId: op, request: input);
    final canonical = {for (final key in (input.fields.keys.toList()..sort())) key: input.fields[key]};
    expect(request.requestHash, sha256.convert(utf8.encode(jsonEncode(canonical))).toString());
    expect(TimewebMutationRequest.createMeeting(operationId: '22345678-1234-4234-8234-123456789abc', request: input).requestHash, request.requestHash);
    expect(() => input.fields['name'] = 'rewrite', throwsUnsupportedError);
    final wire = PeopleWire((call) async {
      expect(call.method, 'POST'); expect(call.url.path, '/v1/runtime/meetings');
      expect(call.followRedirects, isFalse); expect(call.headers['Authorization'], 'Bearer na1.A.first');
      expect(jsonDecode((call as http.Request).body), {'operationId': op, ...input.fields});
      return peopleReply(envelope(request, created()), status: 201);
    });
    final owner = client(wire); await owner.restore();
    final ref = owner.bindMutation(request, expectedOwnerUid: 'A');
    final first = owner.mutate(ref), second = owner.mutate(ref);
    expect(identical(first, second), isTrue);
    final result = await first, receipt = result.createdMeeting!;
    expect(receipt.meetingId, derived()); expect(receipt.localDatetime, local);
    expect(receipt.created, isTrue); expect(receipt.meetingRevision, 0); expect(result.hasReceipt, isTrue);
    await owner.stop(); expect(() => receipt.meetingId, throwsA(error(TimewebAuthError.staleSession)));
    expect(wire.calls, hasLength(1));
    for (final bad in ['29.02.2025 12:00', '31.04.2026 12:00', '03.10.0000 12:00', '3.10.2026 12:00', '03.10.2026 24:00']) {
      await expectLater(draft(datetime: bad), throwsArgumentError);
    }
    await expectLater(draft(type: 'group'), throwsArgumentError);
    await expectLater(draft(type: 'индивидуальная'), throwsArgumentError);
    await expectLater(draft(invitedUid: 'B'), throwsArgumentError);
    await expectLater(TimewebMeetingCreateRequest.fromCatalog(name: ' ', description: '', countryCode: 'RU', region: 'Республика Адыгея', datetime: local, type: 'групповая'), throwsArgumentError);
    await expectLater(TimewebMeetingFilters.fromCatalog(countryCode: 'RU', region: 'unknown'), throwsArgumentError);
    await expectLater(TimewebMeetingFilters.fromCatalog(limit: 31), throwsArgumentError);
    final off = client(wire, enabled: false); await off.restore();
    await expectLater(off.readMeetings(await TimewebMeetingFilters.fromCatalog()), throwsA(error(TimewebAuthError.disabled)));
    expect(() => off.bindMutation(request, expectedOwnerUid: 'A'), throwsA(error(TimewebAuthError.disabled)));
    await off.stop(); expect(wire.calls, hasLength(1));
  });

  test('lost ACK and recovered original perform lookup only; short preview 404 and fresh access refusal stay unknown', () async {
    final request = TimewebMutationRequest.createMeeting(operationId: op, request: await draft());
    final store = PeopleStore(); var lookup = 0;
    final wire = PeopleWire((call) async {
      if (call.method == 'POST') return peopleReply({'error': 'not_found'}, status: 404);
      expect(call.url.path, '/v1/runtime/operations/meeting.create.v1/$op');
      expect(call.url.queryParameters, {'requestHash': request.requestHash});
      lookup++;
      if (lookup == 1) return peopleReply(envelope(request, null, absent: true));
      if (lookup == 3) return peopleReply({'error': 'meeting_unavailable'}, status: 404);
      return peopleReply(envelope(request, created(), replayed: true));
    });
    final before = client(wire, store: store); await before.restore();
    final lost = await before.mutate(before.bindMutation(request, expectedOwnerUid: 'A'));
    expect(lost.state, TimewebMutationState.unknown); expect(lost.canAcknowledge, isFalse);
    await before.stop();
    final after = client(wire, store: store); await after.restore();
    final original = after.bindMutation(request, expectedOwnerUid: 'A');
    expect((await after.reconcileMutation(original)).state, TimewebMutationState.notFound);
    expect((await after.mutate(original)).state, TimewebMutationState.notFound);
    expect((await after.reconcileMutation(original)).createdMeeting!.meetingId, derived());
    final denied = await after.reconcileMutation(original);
    expect(denied.state, TimewebMutationState.unknown); expect(denied.canAcknowledge, isFalse);
    expect(denied.failure, TimewebMutationFailure.meetingUnavailable);
    expect(after.currentUid, 'A'); expect(wire.calls.where((c) => c.method == 'POST'), hasLength(1));
    expect(wire.calls.where((c) => c.url.path.contains('/auth/')), isEmpty);
    await after.stop();
  });

  test('actual lost POST ACK restarts as original lookup and cannot issue a second POST', () async {
    final request = TimewebMutationRequest.createMeeting(operationId: op, request: await draft());
    final store = PeopleStore();
    final wire = PeopleWire((call) async {
      if (call.method == 'POST') throw StateError('Synthetic ACK lost after commit');
      return peopleReply(envelope(request, created(), replayed: true));
    });
    final first = client(wire, store: store); await first.restore();
    final unknown = await first.mutate(first.bindMutation(request, expectedOwnerUid: 'A'));
    expect(unknown.state, TimewebMutationState.unknown); expect(unknown.canAcknowledge, isFalse); await first.stop();
    final restarted = client(wire, store: store); await restarted.restore();
    final recovered = restarted.bindMutation(request, expectedOwnerUid: 'A');
    expect((await restarted.reconcileMutation(recovered)).createdMeeting!.meetingId, derived());
    expect((await restarted.mutate(recovered)).createdMeeting!.meetingId, derived());
    expect(wire.calls.where((call) => call.method == 'POST'), hasLength(1)); await restarted.stop();
  });

  test('all short create errors stay unknown without ACK, keep original and never authorize another POST', () async {
    final request = TimewebMutationRequest.createMeeting(operationId: op, request: await draft());
    for (final row in [(400, 'invalid_request', TimewebMutationFailure.invalidRequest),
        (401, 'unauthorized', TimewebMutationFailure.unauthorized),
        (404, 'not_found', TimewebMutationFailure.notFound),
        (409, 'operation_conflict', TimewebMutationFailure.conflict),
        (429, 'rate_limited', TimewebMutationFailure.rateLimited), (503, 'unavailable', null)]) {
      final wire = PeopleWire((call) async => call.method == 'POST'
          ? peopleReply({'error': row.$2}, status: row.$1)
          : peopleReply(envelope(request, created(), replayed: true)));
      final owner = client(wire); await owner.restore();
      final ref = owner.bindMutation(request, expectedOwnerUid: 'A');
      final original = await owner.mutate(ref);
      expect(original.state, TimewebMutationState.unknown); expect(original.failure, row.$3);
      expect(original.canAcknowledge, isFalse); expect(original.hasReceipt, isFalse);
      expect(() => owner.acknowledgeMutation(ref), throwsA(error(TimewebAuthError.invalidRequest)));
      expect((await owner.mutate(ref)).canAcknowledge, isFalse);
      expect((await owner.reconcileMutation(ref)).createdMeeting!.meetingId, derived());
      expect(wire.calls.where((call) => call.method == 'POST'), hasLength(1));
      await owner.stop(); expect(() => original.canAcknowledge, throwsA(error(TimewebAuthError.staleSession)));
    }
  });

  test('receipt binds operation/hash/owner/derived ID/local time and only exact committed creation failures are definitive', () async {
    final request = TimewebMutationRequest.createMeeting(operationId: op, request: await draft(type: 'индивидуальная', invitedUid: 'B'));
    for (final bad in [created({'meetingId': derived('B')}), created({'localDatetime': '03.10.2026 18:31'}), created({'created': false}), created({'meetingRevision': 0.0}), created({'url': 'https://invalid.example'}), created({'meetingRevision': 1})]) {
      final owner = client(PeopleWire((_) async => peopleReply(envelope(request, bad), status: 201))); await owner.restore();
      final result = await owner.mutate(owner.bindMutation(request, expectedOwnerUid: 'A'));
      expect(result.state, TimewebMutationState.unknown); expect(result.canAcknowledge, isFalse);
      expect(result.unknownReason, TimewebAuthError.invalidResponse); await owner.stop();
    }
    for (final refusal in [(404, 'profile_not_found', TimewebMutationFailure.notFound), (409, 'profile_not_ready', TimewebMutationFailure.profileNotReady), (404, 'person_unavailable', TimewebMutationFailure.personUnavailable), (409, 'profile_changed', null)]) {
      final owner = client(PeopleWire((_) async => peopleReply(envelope(request, {'error': refusal.$2}, revision: null), status: refusal.$1))); await owner.restore();
      final result = await owner.mutate(owner.bindMutation(request, expectedOwnerUid: 'A'));
      expect(result.state, refusal.$3 == null ? TimewebMutationState.unknown : TimewebMutationState.declaredFailure);
      expect(result.canAcknowledge, refusal.$3 != null); expect(result.failure, refusal.$3); await owner.stop();
    }
    for (final edits in [{'operationId': '22345678-1234-4234-8234-123456789abc'}, {'requestHash': 'a' * 64}]) {
      final owner = client(PeopleWire((_) async => peopleReply({...envelope(request, created()), ...edits}, status: 201))); await owner.restore();
      expect((await owner.mutate(owner.bindMutation(request, expectedOwnerUid: 'A'))).canAcknowledge, isFalse); await owner.stop();
    }
  });

  test('sparse empty list/cursor, exact filtered page, metadata and nullable roster have nested epoch guards', () async {
    final wire = PeopleWire((call) async {
      if (call.url.path.endsWith('/participants')) return peopleReply(roster([participant('A'), participant('B')], cursor: 'rosterNext'));
      if (call.url.path.endsWith('/M')) { expect(call.url.hasQuery, isFalse); return peopleReply(detail(meeting('M'))); }
      expect(call.url.queryParameters['limit'], '2');
      expect(call.url.queryParameters['countryCode'], 'RU');
      return peopleReply(call.url.queryParameters.containsKey('cursor') ? list([meeting('M')]) : list([], cursor: 'listNext'));
    });
    final owner = client(wire); await owner.restore();
    final filters = await TimewebMeetingFilters.fromCatalog(limit: 2, countryCode: 'RU', region: 'Республика Адыгея');
    final empty = await owner.readMeetings(filters); expect(empty.items, isEmpty); expect(empty.nextCursor, isNotNull);
    final page = await owner.readMeetings(filters, cursor: empty.nextCursor), item = page.items.single;
    expect(item.title, '  Живая встреча  '); expect(item.description, ''); expect(item.startsAt, isNull);
    expect(item.localDatetime, local); expect(item.updatedAt, isNull); expect(item.media, isNull);
    expect(() => page.items.clear(), throwsUnsupportedError);
    expect((await owner.readMeeting('M')).meetingId, 'M');
    final participants = await owner.readMeetingParticipants('M', limit: 2), self = participants.items.first;
    expect(self.uid, 'A'); expect(self.fullName, isNull); expect(self.primaryGroup, isNull); expect(self.joinedAt, isNull); expect(self.avatar, isNull);
    await expectLater(owner.readMeetingParticipants('X', limit: 2, cursor: participants.nextCursor), throwsA(error(TimewebAuthError.invalidRequest)));
    await expectLater(owner.readMeetings(await TimewebMeetingFilters.fromCatalog(limit: 1), cursor: empty.nextCursor), throwsA(error(TimewebAuthError.invalidRequest)));
    var runtimeCurrent = true;
    void guard() { if (!runtimeCurrent) throw const TimewebAuthException(TimewebAuthOperation.currentRead, TimewebAuthError.staleSession); }
    final guarded = page.bindSessionGuard(guard), nested = guarded.items.single;
    runtimeCurrent = false; expect(() => nested.title, throwsA(error(TimewebAuthError.staleSession)));
    await owner.stop();
    for (final getter in [() => item.title, () => self.uid, () => empty.nextCursor!.requireCurrent(), () => participants.items]) { expect(getter, throwsA(error(TimewebAuthError.staleSession))); }
  });

  test('cursor expiry/owner/query, strict native DTO and bounded response reject without fallback', () async {
    var now = peopleNow;
    final wire = PeopleWire((_) async => peopleReply(list([], cursor: 'first')));
    final owner = client(wire, clock: () => now); await owner.restore();
    final filters = await TimewebMeetingFilters.fromCatalog(); final cursor = (await owner.readMeetings(filters)).nextCursor!;
    final other = client(wire); await other.restore();
    await expectLater(other.readMeetings(filters, cursor: cursor), throwsA(error(TimewebAuthError.invalidRequest)));
    await expectLater(owner.readMeetings(await TimewebMeetingFilters.fromCatalog(scope: 'individual'), cursor: cursor), throwsA(error(TimewebAuthError.invalidRequest)));
    now = now.add(const Duration(seconds: 300)); await expectLater(owner.readMeetings(filters, cursor: cursor), throwsA(error(TimewebAuthError.invalidRequest)));
    await owner.stop(); await other.stop();
    for (final body in [list([meeting('B'), meeting('A')]), list([meeting('M', edits: {'startsAt': peopleStamp})]), list([meeting('M', edits: {'raw': {}})]), list([meeting('M', edits: {'media': 'https://invalid.example'})]), list([meeting('M', kind: 'individual', invited: 'B')]), roster([participant('B'), participant('A')]), detail(meeting('X')), detail(meeting('M', kind: 'individual', invited: 'C', edits: {'organizerUid': 'B'}))]) {
      final participantPage = body.containsKey('meetingId'); final detailPage = body.containsKey('meeting');
      final check = client(PeopleWire((_) async => peopleReply(body))); await check.restore();
      await expectLater(participantPage ? check.readMeetingParticipants('M') : detailPage ? check.readMeeting('M') : check.readMeetings(filters), throwsA(error(TimewebAuthError.invalidResponse)));
      await check.stop();
    }
    for (final response in [peopleReply(list([]), length: 65537), peopleReply(list([]), headers: {'content-encoding': 'gzip'}), peopleReply(list([]), headers: {'cache-control': 'public,no-store'}), peopleReply(list([]), status: 302), peopleReply(list([]), length: 1)]) {
      final check = client(PeopleWire((_) async => response)); await check.restore();
      await expectLater(check.readMeetings(filters), throwsA(error(TimewebAuthError.invalidResponse))); await check.stop();
    }
  });

  test('A to B late read is rejected; 404 metadata is healthy and 401 keeps existing refresh/revoke contract', () async {
    final held = Completer<http.StreamedResponse>();
    final wire = PeopleWire((call) async {
      if (call.url.path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      if (call.headers['Authorization'] == 'Bearer na1.A.first') return held.future;
      return peopleReply(detail(meeting('M')));
    });
    final owner = client(wire); await owner.restore(); final late = owner.readMeeting('M');
    final stale = expectLater(late, throwsA(error(TimewebAuthError.staleSession))); await tick(() => wire.calls.length == 1);
    await owner.login(email: 'synthetic-b@example.invalid', password: 'synthetic', deviceId: 'synthetic-device');
    held.complete(peopleReply(detail(meeting('M')))); await stale;
    expect((await owner.readMeeting('M')).meetingId, 'M'); expect(owner.currentUid, 'B'); await owner.stop();
    var reads = 0, refreshes = 0;
    final errors = PeopleWire((call) async {
      if (call.url.path == '/v1/auth/refresh') { refreshes++; return peopleReply(peopleTokens('A')); }
      reads++; return peopleReply({'error': 'not_found'}, status: reads == 1 ? 404 : 401);
    });
    final active = client(errors); await active.restore();
    await expectLater(active.readMeeting('M'), throwsA(isA<TimewebMeetingNotFound>()));
    expect(active.currentUid, 'A'); expect(refreshes, 0);
    // Existing owner invalidation aborts the current read as stale after the
    // second 401; this is a real global revoke, unlike the healthy 404 above.
    await expectLater(active.readMeeting('M'), throwsA(error(TimewebAuthError.staleSession)));
    expect(refreshes, 1); expect(active.currentUid, isNull); await active.stop();
  });

  test('native meetings share the four actual read slots and stop waits for transport drain', () async {
    final held = <Completer<http.StreamedResponse>>[];
    final wire = PeopleWire((_) { final reply = Completer<http.StreamedResponse>(); held.add(reply); return reply.future; });
    final owner = client(wire); await owner.restore();
    final pending = <Future<Object>>[owner.readPeople(await TimewebPeopleFilters.fromCatalog()), for (var i = 0; i < 3; i++) owner.readMeeting('M$i')];
    final rejected = [for (final future in pending) expectLater(future, throwsA(error(TimewebAuthError.staleSession)))];
    await tick(() => held.length == 4);
    await expectLater(owner.readMeeting('fifth'), throwsA(error(TimewebAuthError.unavailable))); expect(wire.calls, hasLength(4));
    var drained = false; final stop = owner.stop().then((_) { drained = true; }); await Future<void>.delayed(Duration.zero); expect(drained, isFalse);
    for (final response in held) { response.complete(peopleReply({})); }
    await Future.wait(rejected); await stop; expect(drained, isTrue);
  });

  test('imported schedule: original local literals and canonical UTC labels retain nested guards', () async {
    await attachMeetingCatalog();
    const utc = '2026-10-03T18:30:45.123456Z';
    final rows = {
      'utc': meeting('utc', edits: {'startsAt': utc, 'localDatetime': null}),
      'local': meeting('local', edits: {'localDatetime': '3.9.2026 7:05'}),
      'leap': meeting('leap', edits: {'localDatetime': '29.2.2024 09:05'}),
      'ancient': meeting('ancient', edits: {'localDatetime': '1.1.0001 0:00'}),
    };
    final owner = client(PeopleWire((call) async => peopleReply(detail(rows[call.url.path.split('/').last]!))));
    await owner.restore();
    final item = await owner.readMeeting('utc');
    expect(item.startsAt, utc); expect(item.localDatetime, isNull);
    expect(item.scheduleLabel, '03.10.2026 18:30 UTC');
    for (final id in ['local', 'leap', 'ancient']) {
      final localItem = await owner.readMeeting(id);
      expect(localItem.startsAt, isNull);
      expect(localItem.scheduleLabel, rows[id]!['localDatetime']);
    }
    var current = true;
    final guarded = item.bindSessionGuard(() { if (!current) throw const TimewebAuthException(TimewebAuthOperation.currentRead, TimewebAuthError.staleSession); });
    current = false;
    for (final getter in [() => guarded.localDatetime, () => guarded.startsAt, () => guarded.scheduleLabel]) {
      expect(getter, throwsA(error(TimewebAuthError.staleSession)));
    }
    await owner.stop(); expect(() => item.scheduleLabel, throwsA(error(TimewebAuthError.staleSession)));
  });

  test('imported schedule: ambiguous malformed or unrepresentable values fail closed; native create stays strict', () async {
    await attachMeetingCatalog();
    const utc = '2026-10-03T18:30:00.000000Z';
    final invalid = <Map<String, dynamic>>[
      {'startsAt': null, 'localDatetime': null}, {'startsAt': utc, 'localDatetime': local},
      for (final stamp in ['2026-10-03T18:30:00.000000+00:00', '2026-10-03T18:30:00Z',
        '2026-10-03T18:30:00.0000000Z', '0999-10-03T18:30:00.000000Z',
        '2025-02-29T18:30:00.000000Z', '2026-10-03T24:30:00.000000Z', '2026-10-03T18:30:00.000000Z\n'])
        {'startsAt': stamp, 'localDatetime': null},
      for (final literal in ['31.4.2026 7:05', '3.10.2026 24:00', '3.10.2026 7:5',
        '003.10.2026 7:05', '3.10.0000 7:05', '3.10.2026 7:05 UTC', '3.10.2026 7:05\n'])
        {'startsAt': null, 'localDatetime': literal},
    ];
    for (final edits in invalid) {
      final wire = PeopleWire((_) async => peopleReply(detail(meeting('M', edits: edits))));
      final owner = client(wire); await owner.restore();
      await expectLater(owner.readMeeting('M'), throwsA(error(TimewebAuthError.invalidResponse)));
      expect(owner.currentUid, 'A'); expect(wire.calls, hasLength(1)); await owner.stop();
    }
    await expectLater(draft(datetime: '3.10.2026 7:05'), throwsArgumentError);
    expect((await draft()).fields['datetime'], local);
  });

  test('imported schedule: null-first UTC binary-ID order continues through guarded sparse cursors', () async {
    await attachMeetingCatalog();
    const early = '2026-03-01T12:00:00.000000Z', later = '2026-04-01T12:00:00.000000Z';
    Map<String, dynamic> timed(String id, String stamp) => meeting(id, edits: {'startsAt': stamp, 'localDatetime': null});
    final wire = PeopleWire((call) async {
      final cursor = call.url.queryParameters['cursor'];
      if (cursor == null) { return peopleReply(list([meeting('z-local'), timed('z-utc', early), timed('a-utc', later)], cursor: 'next-one')); }
      if (cursor == 'next-one') { return peopleReply(list([], cursor: 'next-empty')); }
      if (cursor == 'next-empty') { return peopleReply(list([timed('b-utc', later)], cursor: 'next-last')); }
      return peopleReply(list([timed('z-rewind', early)]));
    });
    final owner = client(wire); await owner.restore();
    final filters = await TimewebMeetingFilters.fromCatalog(limit: 3);
    final first = (await owner.readMeetings(filters)).bindSessionGuard(() {});
    expect(first.items.map((item) => item.meetingId), ['z-local', 'z-utc', 'a-utc']);
    final empty = (await owner.readMeetings(filters, cursor: first.nextCursor)).bindSessionGuard(() {});
    expect(empty.items, isEmpty); expect(empty.nextCursor, isNotNull);
    final last = await owner.readMeetings(filters, cursor: empty.nextCursor);
    expect(last.items.single.meetingId, 'b-utc');
    await expectLater(owner.readMeetings(filters, cursor: last.nextCursor), throwsA(error(TimewebAuthError.invalidResponse)));
    expect(owner.currentUid, 'A'); await owner.stop();
    for (final rows in [[timed('a', later), timed('z', early)], [timed('a', early), meeting('z')],
        [timed('b', early), timed('a', early)], [timed('same', early), timed('same', later)]]) {
      final check = client(PeopleWire((_) async => peopleReply(list(rows)))); await check.restore();
      await expectLater(check.readMeetings(filters), throwsA(error(TimewebAuthError.invalidResponse)));
      await check.stop();
    }
  });
}
