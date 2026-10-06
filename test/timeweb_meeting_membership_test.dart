import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_chat_flow.dart';
import 'package:wbrs/service/timeweb_meeting_membership_flow.dart';
import 'support/timeweb_people_fixtures.dart';

const meeting = 'native-reviewed-meeting', target = 'synthetic-target', op = '12345678-1234-4234-8234-123456789abc';
TimewebMutationRequest request(bool kick, [String uuid = op]) => kick ?
    TimewebMutationRequest.kickMeetingParticipant(operationId: uuid, meetingId: meeting, targetUid: target) :
    TimewebMutationRequest.leaveMeeting(operationId: uuid, meetingId: meeting);
Map<String, dynamic> receipt(bool kick, {bool noop = false}) => kick ?
    {'meetingId': meeting, 'targetUid': target, 'kicked': true, 'alreadyKicked': noop, 'membershipRevision': 2, 'kickedAt': peopleStamp, 'leftAt': peopleStamp} :
    {'meetingId': meeting, 'left': true, 'alreadyLeft': noop, 'membershipRevision': noop ? null : 2, 'leftAt': noop ? null : peopleStamp};
Map<String, dynamic> envelope(TimewebMutationRequest original, Object? result, {bool absent = false, bool replayed = false, int? revision = 2}) => {
  'operation': original.operation, 'operationId': original.operationId, 'requestHash': original.requestHash,
  'state': absent ? 'not_found' : 'committed', 'replayed': replayed, 'result': result, 'entityRevision': absent ? null : revision,
};
Map<String, dynamic> page({bool empty = true}) => {'kind': 'canonical-current', 'meetingId': meeting, 'chatRevision': empty ? 0 : 2,
  'ordering': 'sequence_desc', 'items': empty ? [] : [{'meetingId': meeting, 'messageId': 'tw-meet-msg-${'a' * 64}',
    'sequence': 2, 'senderUid': 'A', 'text': 'Confirmed text', 'createdAt': peopleStamp}], 'nextCursor': empty ? null : 'opaque', 'mediaReady': false};
TimewebAppRuntime runtime(PeopleWire wire, Directory root, {bool enabled = true}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(endpoint: Uri.parse('https://api.example.invalid'), enabled: true, currentReadsEnabled: enabled, runtimeWritesEnabled: enabled),
  secureStore: PeopleStore(), transport: wire, clock: () => peopleNow, deviceId: 'synthetic-device', expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {}, currentOwnProfileEnabled: true,
  meetingMembershipJournal: TimewebMeetingMembershipJournal(directory: () async => root), meetingChatJournal: TimewebMeetingChatJournal(directory: () async => root));
TimewebAuthClient client(PeopleWire wire) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(endpoint: Uri.parse('https://api.example.invalid'), enabled: true, currentReadsEnabled: true, runtimeWritesEnabled: true),
  secureStore: PeopleStore(), transport: wire, clock: () => peopleNow);
Future<TimewebMeetingMembershipFlow> open(TimewebAppRuntime owner, bool kick) => kick ? owner.openMeetingKick(meeting) : owner.openMeetingLeave(meeting);
List<File> journals(Directory root) => root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.json')).toList();
Matcher authError(TimewebAuthError error) => isA<TimewebAuthException>().having((v) => v.error, 'error', error);
Future<void> tick(bool Function() ready) async { for (var i = 0; i < 100 && !ready(); i++) { await Future<void>.delayed(const Duration(milliseconds: 2)); } expect(ready(), isTrue); }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('both originals durable before one POST; UNKNOWN restart is restore-only lookup; exact kick target and disk ACK', () async {
    for (final kick in [false, true]) {
      final root = await Directory.systemTemp.createTemp('native-member-original-'); TimewebMutationRequest? original; var found = false;
      final wire = PeopleWire((call) async {
        if (call.method == 'POST') {
          final body = jsonDecode((call as http.Request).body); original = request(kick, body['operationId']);
          expect(call.url.path, '/v1/runtime/meetings/${kick ? 'kick' : 'leave'}');
          expect(body, {'operationId': original!.operationId, 'meetingId': meeting, if (kick) 'targetUid': target});
          final saved = jsonDecode(await journals(root).single.readAsString());
          expect(saved['fields'], {'meetingId': meeting, if (kick) 'targetUid': target}); expect(saved['uid'], 'A');
          expect(saved['operationId'], original!.operationId); expect(saved['requestHash'], original!.requestHash);
          expect(original!.requestHash, sha256.convert(utf8.encode(jsonEncode({'meetingId': meeting, if (kick) 'targetUid': target}))).toString());
          throw StateError('Synthetic committed ACK loss');
        }
        expect(call.url.path, '/v1/runtime/operations/${original!.operation}/${original!.operationId}');
        expect(call.url.queryParameters, {'requestHash': original!.requestHash});
        return peopleReply(envelope(original!, found ? receipt(kick) : null, absent: !found, replayed: found));
      }); final first = runtime(wire, root); TimewebAppRuntime? restart;
      try {
        await first.start(remember: true); final flow = await open(first, kick);
        final a = flow.submit(targetUid: kick ? target : null), b = flow.submit(targetUid: kick ? target : null);
        expect(identical(a, b), isTrue); expect(await a, TimewebMeetingMembershipOutcome.unknown); flow.close(); await first.stop();
        restart = runtime(wire, root); await restart.start(remember: true); final restored = await open(restart, kick);
        expect(restored.needsCheck, isTrue); expect(restored.targetUid, kick ? target : null);
        expect(() => restored.submit(targetUid: kick ? 'other' : null), throwsStateError);
        expect(await restored.check(), TimewebMeetingMembershipOutcome.unknown); expect(journals(root), hasLength(1));
        found = true; expect(await restored.check(), TimewebMeetingMembershipOutcome.confirmed); expect(journals(root), isEmpty);
        if (kick) { expect(restored.kickReceipt!.targetUid, target); expect(restored.kickReceipt!.membershipRevision, 2); }
        else { expect(restored.leaveReceipt!.meetingId, meeting); expect(restored.leaveReceipt!.leftAt, peopleStamp); }
        expect(restored.needsCheck, isFalse); expect(restart.client.currentUid, 'A');
        expect(wire.calls.where((c) => c.method == 'POST'), hasLength(1)); expect(wire.calls.where((c) => c.url.path.endsWith('/messages')), isEmpty); restored.close();
      } finally { await restart?.stop(); await first.stop(); await root.delete(recursive: true); }
    }
  });

  test('short errors never ACK; only exact seven committed errors and original-bound nullable/typed receipts', () async {
    for (final kick in [false, true]) {
      for (final row in [(400, 'invalid_request'), (401, 'unauthorized'), (404, 'not_found'), (409, 'operation_conflict'), (429, 'rate_limited'), (503, 'unavailable')]) {
        final root = await Directory.systemTemp.createTemp('native-member-short-'); final wire = PeopleWire((_) async => peopleReply({'error': row.$2}, status: row.$1)); final owner = runtime(wire, root);
        try { await owner.start(remember: true); final flow = await open(owner, kick);
          expect(await flow.submit(targetUid: kick ? target : null), TimewebMeetingMembershipOutcome.unknown);
          expect(flow.needsCheck, isTrue); expect(flow.rejected, isFalse); expect(journals(root), hasLength(1)); expect(wire.calls, hasLength(1)); flow.close();
        } finally { await owner.stop(); await root.delete(recursive: true); }
      }
      for (final row in [(404, 'meeting_not_found', TimewebMutationFailure.meetingNotFound), (404, 'profile_not_found', TimewebMutationFailure.notFound),
          (409, 'meeting_unavailable', TimewebMutationFailure.meetingUnavailable), (409, 'profile_not_ready', TimewebMutationFailure.profileNotReady),
          (404, 'participant_not_found', TimewebMutationFailure.participantNotFound), (409, 'organizer_required', TimewebMutationFailure.organizerRequired),
          (409, 'cannot_kick_self', TimewebMutationFailure.cannotKickSelf), (409, 'profile_changed', null)]) {
        final original = request(kick), owner = client(PeopleWire((_) async => peopleReply(envelope(request(kick), {'error': row.$2}, revision: null), status: row.$1)));
        try { await owner.restore(); final result = await owner.mutate(owner.bindMutation(original, expectedOwnerUid: 'A'));
          expect(result.canAcknowledge, row.$3 != null); expect(result.failure, row.$3);
          expect(result.state, row.$3 == null ? TimewebMutationState.unknown : TimewebMutationState.declaredFailure);
        } finally { await owner.stop(); }
      }
      for (final bad in [{'meetingId': 'foreign'}, {kick ? 'kicked' : 'left': false}, {kick ? 'alreadyKicked' : 'alreadyLeft': null},
          {'membershipRevision': 2.0}, {'membershipRevision': -1}, {kick ? 'kickedAt' : 'leftAt': '2026-10-02T12:00:00Z'},
          {'raw': {}}, if (kick) {'targetUid': 'other'}, if (!kick) {'membershipRevision': null}]) {
        final owner = client(PeopleWire((_) async => peopleReply(envelope(request(kick), {...receipt(kick), ...bad}))));
        try { await owner.restore(); final result = await owner.mutate(owner.bindMutation(request(kick), expectedOwnerUid: 'A'));
          expect(result.canAcknowledge, isFalse); expect(result.unknownReason, TimewebAuthError.invalidResponse);
        } finally { await owner.stop(); }
      }
      final owner = client(PeopleWire((_) async => peopleReply(envelope(request(kick), receipt(kick, noop: true), revision: kick ? 2 : null))));
      try { await owner.restore(); expect((await owner.mutate(owner.bindMutation(request(kick), expectedOwnerUid: 'A'))).canAcknowledge, isTrue); }
      finally { await owner.stop(); }
    }
  });

  test('ACK invalidates held item/cursor, late page and EMPTY chat authority without logout; new GET can mint fresh authority', () async {
    for (final kick in [false, true]) {
      final root = await Directory.systemTemp.createTemp('native-member-reads-'), late = Completer<http.StreamedResponse>(); var reads = 0;
      final wire = PeopleWire((call) async {
        if (call.method == 'POST') { final body = jsonDecode((call as http.Request).body); return peopleReply(envelope(request(kick, body['operationId']), receipt(kick))); }
        reads++; if (reads == 3) return late.future;
        return peopleReply(page(empty: reads != 1));
      }); final owner = runtime(wire, root);
      try {
        await owner.start(remember: true); final held = await owner.readMeetingMessages(meeting); final item = held.items.single, cursor = held.nextCursor!;
        final chat = await owner.openMeetingConversation(meeting); expect(chat.messages, isEmpty);
        final pending = owner.readMeetingMessages(meeting); final denied = expectLater(pending, throwsA(isA<TimewebMeetingNotFound>())); await tick(() => reads == 3);
        final action = await open(owner, kick); expect(await action.submit(targetUid: kick ? target : null), TimewebMeetingMembershipOutcome.confirmed);
        expect(journals(root), isEmpty); expect(() => item.text, throwsA(isA<TimewebMeetingNotFound>())); expect(() => cursor.requireCurrent(), throwsA(isA<TimewebMeetingNotFound>()));
        expect(() => held.items, throwsA(isA<TimewebMeetingNotFound>())); expect(() => chat.messages, throwsA(isA<TimewebMeetingNotFound>())); expect(chat.targetAvailable, isFalse);
        late.complete(peopleReply(page())); await denied; expect(owner.client.currentUid, 'A');
        expect((await owner.readMeetingMessages(meeting)).items, isEmpty); expect(wire.calls.where((c) => c.url.path.contains('/auth/')), isEmpty);
        if (kick) { expect(action.kickReceipt!.targetUid, target); } else { expect(action.leaveReceipt!.left, isTrue); }
        action.close(); chat.close();
      } finally { if (!late.isCompleted) late.complete(peopleReply({}, status: 503)); await owner.stop(); await root.delete(recursive: true); }
    }
  });

  test('late A result cannot publish or ACK A disk original for B; stop drains transfer, A restart only looks up', () async {
    final root = await Directory.systemTemp.createTemp('native-member-owner-'), late = Completer<http.StreamedResponse>();
    TimewebMutationRequest? original; http.AbortableRequest? transfer; var lookup = false;
    final wire = PeopleWire((call) async {
      if (call.url.path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      if (lookup) return peopleReply(envelope(original!, null, absent: true));
      transfer = call as http.AbortableRequest; original = request(false, jsonDecode(transfer!.body)['operationId']); return late.future;
    }); final first = runtime(wire, root); TimewebAppRuntime? restart;
    try {
      await first.start(remember: true); final a = await first.openMeetingLeave(meeting), pending = a.submit();
      final stale = expectLater(pending, throwsA(authError(TimewebAuthError.staleSession))); await tick(() => original != null);
      var aborted = false; transfer!.abortTrigger!.then((_) => aborted = true); await first.login(email: 'synthetic-b@example.invalid', password: 'synthetic'); await tick(() => aborted);
      expect(() => a.leaveReceipt, throwsA(isA<AppSessionException>()));
      final b = await first.openMeetingLeave(meeting); expect(b.needsCheck, isFalse); expect(b.ownerUid, 'B'); b.close();
      var drained = false; final stop = first.stop().then((value) { drained = true; return value; }); await Future<void>.delayed(Duration.zero); expect(drained, isFalse);
      late.complete(peopleReply(envelope(original!, receipt(false)))); await stale; expect(await stop, isTrue); expect(journals(root), hasLength(1));
      lookup = true; restart = runtime(wire, root); await restart.start(remember: true); final restored = await restart.openMeetingLeave(meeting);
      expect(restored.needsCheck, isTrue); expect(await restored.check(), TimewebMeetingMembershipOutcome.unknown); expect(() => restored.submit(), throwsStateError);
      expect(wire.calls.where((c) => c.url.path.endsWith('/leave')), hasLength(1)); restored.close();
    } finally { if (!late.isCompleted) late.complete(peopleReply({}, status: 503)); await restart?.stop(); await first.stop(); await root.delete(recursive: true); }
  });

  test('disk ACK exact readback refuses replaced original and preserves authority; restore corruption fails before network; gates unchanged', () async {
    final root = await Directory.systemTemp.createTemp('native-member-ack-');
    final wire = PeopleWire((call) async {
      if (call.method == 'GET') return peopleReply(page());
      final original = request(false, jsonDecode((call as http.Request).body)['operationId']); final file = journals(root).single;
      final saved = jsonDecode(await file.readAsString()); await file.writeAsString(jsonEncode({...saved, 'operationId': op}), flush: true);
      return peopleReply(envelope(original, receipt(false)));
    }); final owner = runtime(wire, root); TimewebAppRuntime? restart;
    try {
      await owner.start(remember: true); final held = await owner.readMeetingMessages(meeting), flow = await owner.openMeetingLeave(meeting);
      await expectLater(flow.submit(), throwsStateError); expect(flow.leaveReceipt, isNull); expect(flow.needsCheck, isTrue); expect(journals(root), hasLength(1)); expect(held.items, isEmpty);
      flow.close(); await owner.stop(); final file = journals(root).single, saved = jsonDecode(await file.readAsString());
      await file.writeAsString(jsonEncode({...saved, 'fields': {'meetingId': meeting, 'targetUid': 'foreign'}}), flush: true);
      restart = runtime(wire, root); await restart.start(remember: true); await expectLater(restart.openMeetingLeave(meeting), throwsA(isA<FormatException>())); expect(wire.calls, hasLength(2));
    } finally { await restart?.stop(); await owner.stop(); await root.delete(recursive: true); }
    final offroot = await Directory.systemTemp.createTemp('native-member-off-'), offwire = PeopleWire((_) async => throw StateError('No HTTP'));
    final off = runtime(offwire, offroot, enabled: false);
    try { await off.start(remember: true); await expectLater(off.openMeetingLeave(meeting), throwsStateError); await expectLater(off.openMeetingKick(meeting), throwsStateError); expect(offwire.calls, isEmpty); expect(journals(offroot), isEmpty); }
    finally { await off.stop(); await offroot.delete(recursive: true); }
  });
}
