import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_join_flow.dart';
import 'support/timeweb_people_fixtures.dart';

const id = 'native-reviewed-meeting';
const op = '12345678-1234-4234-8234-123456789abc';
TimewebMutationRequest request([String operationId = op, String meetingId = id]) =>
    TimewebMutationRequest.joinMeeting(operationId: operationId, meetingId: meetingId);
Map<String, dynamic> joined({bool alreadyMember = false, int revision = 0}) =>
    {'meetingId': id, 'joined': true, 'alreadyMember': alreadyMember, 'membershipRevision': revision};
Map<String, dynamic> envelope(TimewebMutationRequest original, Object? result, {bool replayed = false, bool absent = false, int? revision = 0}) => {
  'operation': original.operation, 'operationId': original.operationId, 'requestHash': original.requestHash,
  'state': absent ? 'not_found' : 'committed', 'replayed': replayed, 'result': result, 'entityRevision': absent ? null : revision,
};
TimewebAppRuntime runtime(PeopleWire wire, Directory root, {bool enabled = true}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(endpoint: Uri.parse('https://api.example.invalid'), enabled: true, runtimeWritesEnabled: enabled, currentReadsEnabled: enabled),
  secureStore: PeopleStore(), transport: wire, clock: () => peopleNow,
  deviceId: 'synthetic-device', expectedSourceSnapshot: 'a' * 64, clearLocal: () async {},
  currentOwnProfileEnabled: true, meetingJoinJournal: TimewebMeetingJoinJournal(directory: () async => root),
);
List<File> journalFiles(Directory root) => root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.json')).toList();
Matcher authError(TimewebAuthError value) => isA<TimewebAuthException>().having((e) => e.error, 'error', value);
Future<void> tick(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) { await Future<void>.delayed(const Duration(milliseconds: 2)); }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('durable exact original before single POST; double tap, target scope, lost ACK restart, sparse absent lookup, ACK before return', () async {
    final root = await Directory.systemTemp.createTemp('native-join-original-');
    TimewebMutationRequest? original; var stage = 'absent';
    final wire = PeopleWire((call) async {
      expect(call.headers['Authorization'], 'Bearer na1.A.first');
      if (call.method == 'POST') {
        expect(call.url.path, '/v1/runtime/meetings/join'); expect(call.followRedirects, isFalse);
        final body = jsonDecode((call as http.Request).body); original = request(body['operationId']);
        expect(body, {'operationId': original!.operationId, 'meetingId': id});
        final saved = jsonDecode(await journalFiles(root).single.readAsString());
        expect(saved['fields'], {'meetingId': id}); expect(saved['uid'], 'A'); expect(saved['operation'], 'meeting.join.v1');
        expect(saved['operationId'], original!.operationId); expect(saved['requestHash'], original!.requestHash);
        expect(original!.requestHash, sha256.convert(utf8.encode(jsonEncode({'meetingId': id}))).toString());
        expect(jsonEncode(saved), isNot(contains('na1.'))); throw StateError('Synthetic lost ACK after commit');
      }
      expect(call.url.path, '/v1/runtime/operations/meeting.join.v1/${original!.operationId}');
      expect(call.url.queryParameters, {'requestHash': original!.requestHash});
      if (stage == 'denied') return peopleReply({'error': 'meeting_unavailable'}, status: 404);
      return peopleReply(envelope(original!, stage == 'absent' ? null : joined(alreadyMember: true, revision: 4),
        absent: stage == 'absent', replayed: stage != 'absent', revision: 4));
    });
    final first = runtime(wire, root); TimewebAppRuntime? restart;
    try {
      await first.start(remember: true); final flow = await first.openMeetingJoin(id);
      final a = flow.submit(), b = flow.submit(); expect(identical(a, b), isTrue);
      expect(await a, TimewebMeetingJoinOutcome.unknown); expect(flow.needsCheck, isTrue);
      final other = await first.openMeetingJoin('other-meeting'); expect(other.needsCheck, isFalse); other.close();
      flow.close(); await first.stop();
      restart = runtime(wire, root); await restart.start(remember: true); final recovered = await restart.openMeetingJoin(id);
      expect(recovered.needsCheck, isTrue); expect(() => recovered.submit(), throwsStateError);
      expect(await recovered.check(), TimewebMeetingJoinOutcome.unknown); expect(journalFiles(root), hasLength(1));
      stage = 'confirmed'; expect(await recovered.check(), TimewebMeetingJoinOutcome.confirmed);
      expect(journalFiles(root), isEmpty); final receipt = recovered.receipt!;
      expect(receipt.meetingId, id); expect(receipt.joined, isTrue); expect(receipt.alreadyMember, isTrue); expect(receipt.membershipRevision, 4);
      stage = 'denied'; expect(await recovered.check(), TimewebMeetingJoinOutcome.unknown);
      expect(recovered.receipt, isNull); expect(restart.client.currentUid, 'A');
      expect(wire.calls.where((c) => c.method == 'POST'), hasLength(1)); expect(wire.calls.where((c) => c.url.path.contains('/auth/')), isEmpty);
      recovered.close(); receipt.requireCurrent(); await restart.stop();
      expect(() => receipt.meetingId, throwsA(isA<TimewebAuthException>()));
    } finally { await restart?.stop(); await first.stop(); await root.delete(recursive: true); }
  });

  test('short errors never ACK; only four exact committed rejections; strict receipt binds original target/types/revision and operation hash', () async {
    final original = request();
    for (final row in [(400,'invalid_request'),(401,'unauthorized'),(404,'not_found'),(409,'operation_conflict'),(429,'rate_limited'),(503,'unavailable')]) {
      final root = await Directory.systemTemp.createTemp('native-join-short-');
      final wire = PeopleWire((_) async => peopleReply({'error': row.$2}, status: row.$1)); final owner = runtime(wire, root);
      try {
        await owner.start(remember: true); final flow = await owner.openMeetingJoin(id);
        expect(await flow.submit(), TimewebMeetingJoinOutcome.unknown); expect(flow.needsCheck, isTrue); expect(flow.rejected, isFalse);
        expect(journalFiles(root), hasLength(1)); expect(() => flow.submit(), throwsStateError); expect(wire.calls, hasLength(1)); flow.close();
      } finally { await owner.stop(); await root.delete(recursive: true); }
    }
    for (final row in [(404,'meeting_not_found',TimewebMutationFailure.meetingNotFound),
        (404,'profile_not_found',TimewebMutationFailure.notFound),(409,'meeting_unavailable',TimewebMutationFailure.meetingUnavailable),
        (409,'profile_not_ready',TimewebMutationFailure.profileNotReady),(409,'profile_changed',null)]) {
      final root = await Directory.systemTemp.createTemp('native-join-rejected-');
      final wire = PeopleWire((call) async {
        final body = jsonDecode((call as http.Request).body);
        return peopleReply(envelope(request(body['operationId']), {'error':row.$2}, revision:null), status:row.$1);
      }); final owner = runtime(wire, root);
      try {
        await owner.start(remember:true); final flow = await owner.openMeetingJoin(id); final outcome = await flow.submit();
        expect(outcome, row.$3 == null ? TimewebMeetingJoinOutcome.unknown : TimewebMeetingJoinOutcome.rejected);
        expect(flow.failure, row.$3); expect(flow.rejected, row.$3 != null); expect(journalFiles(root), hasLength(row.$3 == null ? 1 : 0)); flow.close();
      } finally { await owner.stop(); await root.delete(recursive:true); }
    }
    for (final bad in [{'meetingId':'foreign'},{'joined':false},{'alreadyMember':null},{'membershipRevision':0.0},{'membershipRevision':-1},{'raw':{}},{'url':'https://invalid.example'}]) {
      final wire = PeopleWire((_) async => peopleReply(envelope(original,{...joined(),...bad})));
      final owner = TimewebAuthClient(configuration:TimewebAuthConfiguration(endpoint:Uri.parse('https://api.example.invalid'),enabled:true,runtimeWritesEnabled:true),secureStore:PeopleStore(),transport:wire,clock:()=>peopleNow);
      try {
        await owner.restore(); final result = await owner.mutate(owner.bindMutation(original,expectedOwnerUid:'A'));
        expect(result.state,TimewebMutationState.unknown); expect(result.canAcknowledge,isFalse); expect(result.unknownReason,TimewebAuthError.invalidResponse);
      } finally { await owner.stop(); }
    }
    for (final response in [envelope(original,joined(revision:1)),{...envelope(original,joined()),'requestHash':'a'*64},
        {...envelope(original,joined()),'operationId':'22345678-1234-4234-8234-123456789abc'}]) {
      final wire = PeopleWire((_) async => peopleReply(response));
      final owner = TimewebAuthClient(configuration:TimewebAuthConfiguration(endpoint:Uri.parse('https://api.example.invalid'),enabled:true,runtimeWritesEnabled:true),secureStore:PeopleStore(),transport:wire,clock:()=>peopleNow);
      try { await owner.restore(); expect((await owner.mutate(owner.bindMutation(original,expectedOwnerUid:'A'))).canAcknowledge,isFalse); }
      finally { await owner.stop(); }
    }
  });

  test('late A join cannot publish or delete A intent for B; stop drains original transport; A restart only checks', () async {
    final root = await Directory.systemTemp.createTemp('native-join-owner-'); final late = Completer<http.StreamedResponse>();
    TimewebMutationRequest? original; http.AbortableRequest? transfer; var lookup = false;
    final wire = PeopleWire((call) async {
      if (call.url.path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
      if (lookup) return peopleReply(envelope(original!,null,absent:true));
      transfer = call as http.AbortableRequest; original = request(jsonDecode(transfer!.body)['operationId']); return late.future;
    }); final first = runtime(wire,root); TimewebAppRuntime? restored;
    try {
      await first.start(remember:true); final a = await first.openMeetingJoin(id); final pending = a.submit();
      final stale = expectLater(pending,throwsA(authError(TimewebAuthError.staleSession))); await tick(()=>original!=null);
      var aborted = false; transfer!.abortTrigger!.then((_)=>aborted=true);
      await first.login(email:'synthetic-b@example.invalid',password:'synthetic'); await tick(()=>aborted);
      expect(()=>a.receipt,throwsA(isA<AppSessionException>())); final b = await first.openMeetingJoin(id);
      expect(b.needsCheck,isFalse); expect(b.ownerUid,'B'); b.close();
      var drained = false; final stop = first.stop().then((value){drained=true;return value;});
      await Future<void>.delayed(Duration.zero); expect(drained,isFalse);
      late.complete(peopleReply(envelope(original!,joined()))); await stale; expect(await stop,isTrue);
      expect(journalFiles(root),hasLength(1)); lookup=true; restored=runtime(wire,root); await restored.start(remember:true);
      final originalA=await restored.openMeetingJoin(id); expect(originalA.needsCheck,isTrue);
      expect(await originalA.check(),TimewebMeetingJoinOutcome.unknown); expect(()=>originalA.submit(),throwsStateError);
      expect(wire.calls.where((c)=>c.url.path=='/v1/runtime/meetings/join'),hasLength(1)); originalA.close();
    } finally { if(!late.isCompleted)late.complete(peopleReply({},status:503));await restored?.stop();await first.stop();await root.delete(recursive:true); }
  });

  test('journal exact readback/CAS refuses corruption before network, ACK is guarded; runtime default off and target bounds', () async {
    for (final edit in [{'uid':'B'},{'requestHash':'a'*64},{'fields':{'meetingId':'foreign'}},{'operation':'meeting.create.v1'},{'extra':'private'}]) {
      final root = await Directory.systemTemp.createTemp('native-join-journal-');
      final wire = PeopleWire((_) async=>peopleReply({},status:503)); final first=runtime(wire,root); TimewebAppRuntime? restart;
      try {
        await first.start(remember:true);final flow=await first.openMeetingJoin(id);await flow.submit();flow.close();await first.stop();
        final file=journalFiles(root).single;final saved=jsonDecode(await file.readAsString());await file.writeAsString(jsonEncode({...saved,...edit}),flush:true);
        restart=runtime(wire,root);await restart.start(remember:true);
        await expectLater(restart.openMeetingJoin(id),throwsA(isA<FormatException>()));expect(wire.calls,hasLength(1));
      } finally {await restart?.stop();await first.stop();await root.delete(recursive:true);}
    }
    final root=await Directory.systemTemp.createTemp('native-join-cas-');
    final wire=PeopleWire((call)async {
      final body=jsonDecode((call as http.Request).body);final original=request(body['operationId']);
      final file=journalFiles(root).single;final saved=jsonDecode(await file.readAsString());
      await file.writeAsString(jsonEncode({...saved,'operationId':op}),flush:true);return peopleReply(envelope(original,joined()));
    });final owner=runtime(wire,root);
    try {
      await owner.start(remember:true);final flow=await owner.openMeetingJoin(id);
      await expectLater(flow.submit(),throwsStateError);expect(flow.receipt,isNull);expect(flow.needsCheck,isTrue);expect(journalFiles(root),hasLength(1));flow.close();
    } finally {await owner.stop();await root.delete(recursive:true);}
    final offroot=await Directory.systemTemp.createTemp('native-join-off-');
    final offwire=PeopleWire((_)async=>throw StateError('No HTTP'));final off=runtime(offwire,offroot,enabled:false);
    try {await off.start(remember:true);await expectLater(off.openMeetingJoin(id),throwsStateError);expect(journalFiles(offroot),isEmpty);expect(offwire.calls,isEmpty);}
    finally {await off.stop();await offroot.delete(recursive:true);}
    for(final target in ['', '../meeting','https://invalid.example']) {expect(()=>request(op,target),throwsArgumentError);}
  });
}
