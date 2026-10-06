import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'support/timeweb_people_fixtures.dart';

const meeting = 'native-reviewed-meeting', op = '12345678-1234-1234-8234-123456789abc';
Map<String, dynamic> window() => {'throughSequence': 10, 'capturedAt': peopleStamp, 'operationId': op, 'membershipRevision': 2};
Map<String, dynamic> message(int sequence) => {'meetingId': meeting, 'messageId': 'tw-meet-msg-${sequence.toRadixString(16).padLeft(64, '0')}',
  'sequence': sequence, 'senderUid': 'synthetic-sender', 'text': ' Exact\r\narchive\t🙂 ', 'createdAt': peopleStamp};
Map<String, dynamic> page(List<Object?> items, {String? cursor, Map<String, dynamic>? pin}) => {
  'kind': 'canonical-current', 'meetingId': meeting, 'archiveWindow': pin ?? window(), 'ordering': 'sequence_desc',
  'items': items, 'nextCursor': cursor, 'mediaReady': false};
TimewebAuthClient client(PeopleWire wire, {DateTime Function()? clock}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(endpoint: Uri.parse('https://api.example.invalid'), enabled: true, currentReadsEnabled: true, runtimeWritesEnabled: true),
  secureStore: PeopleStore(), transport: wire, clock: clock ?? () => peopleNow);
TimewebAppRuntime runtime(PeopleWire wire, {bool enabled = true}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(endpoint: Uri.parse('https://api.example.invalid'), enabled: true, currentReadsEnabled: enabled, runtimeWritesEnabled: enabled),
  secureStore: PeopleStore(), transport: wire, clock: () => peopleNow, deviceId: 'synthetic-device', expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {}, currentOwnProfileEnabled: true);
Matcher authError(TimewebAuthError error) => isA<TimewebAuthException>().having((e) => e.error, 'error', error);
Future<void> tick(bool Function() ready) async { for (var i = 0; i < 100 && !ready(); i++) { await Future<void>.delayed(const Duration(milliseconds: 2)); } expect(ready(), isTrue); }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('exact owner window/cutoff and descending items; cursor target/limit/owner, all four pins and original expiry; nested lease guards', () async {
    var now = peopleNow;
    final wire = PeopleWire((call) async {
      expect(call.method, 'GET'); expect(call.url.path, '/v1/runtime/meetings/$meeting/archived-messages'); expect(call.followRedirects, isFalse);
      expect(call.url.queryParameters.keys, everyElement(isIn(['limit', 'cursor'])));
      return peopleReply(call.url.queryParameters.containsKey('cursor') ? page([message(8)], cursor: 'second') : page([message(10), message(9)], cursor: 'first'));
    }); final owner = client(wire, clock: () => now), other = client(PeopleWire((_) async => throw StateError('No transfer')));
    try {
      await owner.restore(); await other.restore(); final first = await owner.readMeetingArchive(meeting, limit: 2);
      expect(first.items.map((v) => v.sequence), [10, 9]); expect(first.window.operationId, op); expect(first.window.membershipRevision, 2);
      expect(first.window.capturedAt, peopleStamp); expect(first.window.throughSequence, 10); expect(first.mediaReady, isFalse);
      final cursor = first.nextCursor!; now = now.add(const Duration(seconds: 100)); final second = await owner.readMeetingArchive(meeting, limit: 2, cursor: cursor);
      expect(second.items.single.sequence, 8);
      await expectLater(owner.readMeetingArchive('other-meeting', limit: 2, cursor: cursor), throwsA(authError(TimewebAuthError.invalidRequest)));
      await expectLater(owner.readMeetingArchive(meeting, limit: 1, cursor: cursor), throwsA(authError(TimewebAuthError.invalidRequest)));
      await expectLater(other.readMeetingArchive(meeting, limit: 2, cursor: cursor), throwsA(authError(TimewebAuthError.invalidRequest)));
      var live = true; void guard() { if (!live) throw const TimewebAuthException(TimewebAuthOperation.currentRead, TimewebAuthError.staleSession); }
      final bound = first.bindSessionGuard(guard), item = bound.items.first, pin = bound.window, heldCursor = bound.nextCursor!; live = false;
      expect(() => item.text, throwsA(authError(TimewebAuthError.staleSession))); expect(() => pin.capturedAt, throwsA(authError(TimewebAuthError.staleSession)));
      expect(() => heldCursor.requireCurrent(), throwsA(authError(TimewebAuthError.staleSession)));
      now = now.add(const Duration(seconds: 200)); await expectLater(owner.readMeetingArchive(meeting, limit: 2, cursor: second.nextCursor), throwsA(authError(TimewebAuthError.invalidRequest)));
      expect(wire.calls, hasLength(2));
    } finally { await owner.stop(); await other.stop(); }
    for (final changed in [{'throughSequence': 11}, {'capturedAt': '2026-10-02T12:00:00.000002Z'},
        {'operationId': '22345678-1234-1234-8234-123456789abc'}, {'membershipRevision': 3}]) {
      var calls = 0; final owner = client(PeopleWire((_) async => peopleReply(++calls == 1 ? page([message(10)], cursor: 'first') : page([message(9)], pin: {...window(), ...changed}))));
      try { await owner.restore(); final first = await owner.readMeetingArchive(meeting);
        await expectLater(owner.readMeetingArchive(meeting, cursor: first.nextCursor), throwsA(authError(TimewebAuthError.invalidResponse))); expect(owner.currentUid, 'A');
      } finally { await owner.stop(); }
    }
  });

  test('malformed/unbounded page refused whole; zero cutoff honest empty; no chatRevision/raw/URL or invented archive UUID narrowing', () async {
    for (final invalid in [page([], cursor: 'empty'), page([message(11)]), page([message(9), message(10)]), page([message(10), message(10)]),
        page([{...message(10), 'url': 'https://invalid.example'}]), page([{...message(10), 'createdAt': null}]), page([{...message(10), 'sequence': 10.0}]),
        page([{...message(10), 'meetingId': 'foreign'}]), page([{...message(10), 'text': ' '}]), {...page([]), 'chatRevision': 10},
        page([], pin: {...window(), 'operationId': op.toUpperCase()}), page([], pin: {...window(), 'membershipRevision': 0}),
        page([], pin: {...window(), 'capturedAt': '2026-10-02T12:00:00Z'}), page([], pin: {...window(), 'raw': {}}),
        page([message(1)], pin: {...window(), 'throughSequence': 0}), page(List.generate(31, (_) => message(1)))]) {
      final owner = client(PeopleWire((_) async => peopleReply(invalid)));
      try { await owner.restore(); await expectLater(owner.readMeetingArchive(meeting), throwsA(authError(TimewebAuthError.invalidResponse))); }
      finally { await owner.stop(); }
    }
    final zero = client(PeopleWire((_) async => peopleReply(page([], pin: {...window(), 'throughSequence': 0}))));
    try { await zero.restore(); final empty = await zero.readMeetingArchive(meeting); expect(empty.items, isEmpty); expect(empty.nextCursor, isNull); expect(empty.window.throughSequence, 0); }
    finally { await zero.stop(); }
    for (final version in ['1', '4', '8']) {
      final owner = client(PeopleWire((_) async => peopleReply(page([], pin: {...window(), 'operationId': '12345678-1234-${version}234-8234-123456789abc'}))));
      try { await owner.restore(); expect((await owner.readMeetingArchive(meeting)).items, isEmpty); }
      finally { await owner.stop(); }
    }
    final big = client(PeopleWire((_) async => peopleReply(page([]), stream: Stream.value(utf8.encode('x' * 65537)))));
    try { await big.restore(); await expectLater(big.readMeetingArchive(meeting), throwsA(authError(TimewebAuthError.invalidResponse))); }
    finally { await big.stop(); }
  });

  test('read-only flow has no current roster/chat GET or writes; stale window/unavailable clears held data without logout; rolling 300 reaches final older page', () async {
    for (final status in [400, 403, 404]) {
      var calls = 0; final wire = PeopleWire((call) async {
        expect(call.url.path, '/v1/runtime/meetings/$meeting/archived-messages'); expect(call.method, 'GET');
        return ++calls == 1 ? peopleReply(page([message(10)], cursor: 'first')) : peopleReply({'error': 'archive_unavailable'}, status: status);
      }); final owner = runtime(wire);
      try {
        await owner.start(remember: true); final flow = await owner.openMeetingArchive(meeting), item = flow.messages.single, pin = flow.window;
        expect(flow.ownerUid, 'A'); expect(flow.hasOlder, isTrue);
        await expectLater(flow.loadOlder(), throwsA(isA<TimewebMeetingArchiveUnavailable>())); expect(flow.targetAvailable, isFalse);
        expect(() => flow.messages, throwsA(isA<TimewebMeetingArchiveUnavailable>())); expect(() => item.text, throwsA(isA<TimewebMeetingArchiveUnavailable>()));
        expect(() => pin.operationId, throwsA(isA<TimewebMeetingArchiveUnavailable>())); expect(owner.client.currentUid, 'A'); expect(wire.calls, hasLength(2));
        flow.close(); expect(flow.targetAvailable, isFalse);
      } finally { await owner.stop(); }
    }
    var reads = 0; final owner = runtime(PeopleWire((_) async {
      final top = 330 - reads++ * 30; return peopleReply(page(List.generate(30, (i) => message(top - i)), cursor: reads < 11 ? 'page-$reads' : null, pin: {...window(), 'throughSequence': 330}));
    }));
    try { await owner.start(remember: true); final flow = await owner.openMeetingArchive(meeting);
      for (var i = 0; i < 10; i++) {
        expect(flow.hasOlder, isTrue); await flow.loadOlder(); expect(flow.messages.length, lessThanOrEqualTo(300));
        expect(flow.window.throughSequence, 330); expect(flow.window.capturedAt, peopleStamp);
        expect(flow.window.operationId, op); expect(flow.window.membershipRevision, 2);
      }
      expect(flow.messages, hasLength(300)); expect(flow.messages.first.sequence, 300); expect(flow.messages.last.sequence, 1); expect(flow.hasOlder, isFalse);
      await flow.loadOlder(); expect(reads, 11); flow.close();
    } finally { await owner.stop(); }
  });

  test('late A archive cannot publish for B; shared actual four transfers and stop drain; default gates and request bounds unchanged', () async {
    final late = Completer<http.StreamedResponse>(); http.AbortableRequest? transfer;
    final wire = PeopleWire((call) async {
      if (call.url.path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      transfer = call as http.AbortableRequest; return late.future;
    }); final owner = runtime(wire);
    try {
      await owner.start(remember: true); final pending = owner.openMeetingArchive(meeting), stale = expectLater(pending,
        throwsA(isA<AppSessionException>().having((e) => e.error, 'error', AppSessionError.staleSession)));
      await tick(() => transfer != null); var aborted = false; transfer!.abortTrigger!.then((_) => aborted = true);
      await owner.login(email: 'synthetic-b@example.invalid', password: 'synthetic'); await tick(() => aborted);
      var drained = false; final stop = owner.stop().then((value) { drained = true; return value; }); await Future<void>.delayed(Duration.zero); expect(drained, isFalse);
      late.complete(peopleReply(page([message(10)]))); await stale; expect(await stop, isTrue);
    } finally { if (!late.isCompleted) late.complete(peopleReply({}, status: 503)); await owner.stop(); }
    final hold = Completer<void>(), budgetWire = PeopleWire((_) async { await hold.future; return peopleReply({}, status: 503); }), budget = client(budgetWire);
    try { await budget.restore(); final flights = [for (var i = 0; i < 4; i++) budget.readMeetingArchive('$meeting-$i')];
      final errors = [for (final flight in flights) expectLater(flight, throwsA(authError(TimewebAuthError.unavailable)))]; await tick(() => budgetWire.calls.length == 4);
      await expectLater(budget.readMeetingArchive('fifth-meeting'), throwsA(authError(TimewebAuthError.unavailable)));
      hold.complete(); await Future.wait(errors);
    } finally { if (!hold.isCompleted) hold.complete(); await budget.stop(); }
    final offWire = PeopleWire((_) async => throw StateError('No HTTP')), off = runtime(offWire, enabled: false);
    try { await off.start(remember: true); await expectLater(off.openMeetingArchive(meeting), throwsStateError); expect(offWire.calls, isEmpty); }
    finally { await off.stop(); }
    final bounds = client(PeopleWire((_) async => throw StateError('No HTTP')));
    try { await bounds.restore(); for (final limit in [0, 31]) { await expectLater(bounds.readMeetingArchive(meeting, limit: limit), throwsArgumentError); }
      await expectLater(bounds.readMeetingArchive('../meeting'), throwsA(authError(TimewebAuthError.invalidRequest)));
    } finally { await bounds.stop(); }
  });
}
