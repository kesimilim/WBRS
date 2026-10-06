import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_create_flow.dart';

import 'support/timeweb_people_fixtures.dart';

TimewebAppRuntime runtime(PeopleWire wire, Directory root) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: PeopleStore(),
  transport: wire,
  clock: () => peopleNow,
  deviceId: 'synthetic-device',
  expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {},
  currentOwnProfileEnabled: true,
  meetingCreateJournal: TimewebMeetingCreateJournal(directory: () async => root),
);
List<File> journalFiles(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.json'))
    .toList();
String meetingId(String operationId) =>
    'tw-meeting-${sha256.convert(utf8.encode('clrs-native-meeting-v1\u0000${jsonEncode(['A', operationId])}'))}';
Map<String, dynamic> envelope(TimewebMutationRequest original, {bool absent = false}) => {
  'operation': original.operation,
  'operationId': original.operationId,
  'requestHash': original.requestHash,
  'state': absent ? 'not_found' : 'committed',
  'replayed': !absent,
  'entityRevision': absent ? null : 0,
  'result': absent
      ? null
      : {
          'meetingId': meetingId(original.operationId),
          'created': true,
          'meetingRevision': 0,
          'localDatetime': '03.10.2026 19:15',
        },
};
Future<void> tick(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(ready(), isTrue);
}

Future<void> durableOriginal(TimewebMeetingCreateRequest request) async {
  final root = await Directory.systemTemp.createTemp('native-meeting-original-');
  TimewebMutationRequest? original;
  var response = 'preview';
  final wire = PeopleWire((call) async {
    expect(call.headers['Authorization'], 'Bearer na1.A.first');
    if (call.method == 'POST') {
      expect(call.url.path, '/v1/runtime/meetings');
      final body = jsonDecode((call as http.Request).body) as Map<String, dynamic>;
      original = TimewebMutationRequest.createMeeting(
        operationId: body['operationId'],
        request: request,
      );
      expect(body, {'operationId': original!.operationId, ...request.fields});
      final saved = jsonDecode(await journalFiles(root).single.readAsString());
      expect(
        saved.keys,
        unorderedEquals([
          'version',
          'origin',
          'uid',
          'operation',
          'operationId',
          'requestHash',
          'fields',
        ]),
      );
      expect(saved['uid'], 'A');
      expect(saved['fields'], request.fields);
      expect(saved['operationId'], original!.operationId);
      expect(saved['requestHash'], original!.requestHash);
      expect(jsonEncode(saved), isNot(contains('na1.')));
      return peopleReply({'error': 'outcome_unknown'}, status: 503);
    }
    expect(call.method, 'GET');
    expect(call.url.path, '/v1/runtime/operations/meeting.create.v1/${original!.operationId}');
    expect(call.url.queryParameters, {'requestHash': original!.requestHash});
    if (response == 'preview') return peopleReply({'error': 'not_found'}, status: 404);
    if (response == 'unknown') return peopleReply({'error': 'service_unavailable'}, status: 503);
    return peopleReply(
      envelope(original!, absent: response == 'absent'),
      status: response == 'absent' ? 200 : 201,
    );
  });
  final first = runtime(wire, root);
  TimewebAppRuntime? restarted;
  try {
    await first.start(remember: true);
    final flow = await first.openMeetingCreation();
    final initial = flow.submit(request), duplicate = flow.submit(request);
    expect(identical(initial, duplicate), isTrue);
    expect(await initial, TimewebMeetingCreateOutcome.unknown);
    expect(flow.pendingRequest!.fields, request.fields);
    flow.close();
    await first.stop();
    restarted = runtime(wire, root);
    await restarted.start(remember: true);
    final restored = await restarted.openMeetingCreation();
    expect(restored.needsCheck, isTrue);
    expect(restored.pendingRequest!.fields, request.fields);
    expect(() => restored.submit(request), throwsStateError);
    for (final stage in ['preview', 'unknown', 'absent']) {
      response = stage;
      expect(await restored.check(), TimewebMeetingCreateOutcome.unknown);
      expect(restored.receipt, isNull);
      expect(journalFiles(root), hasLength(1));
    }
    response = 'confirmed';
    expect(await restored.check(), TimewebMeetingCreateOutcome.confirmed);
    expect(journalFiles(root), isEmpty); // durable ACK before navigation
    final receipt = restored.receipt!;
    expect(receipt.meetingId, meetingId(original!.operationId));
    expect(receipt.localDatetime, '03.10.2026 19:15');
    restored.close();
    receipt.requireCurrent();
    expect(wire.calls.where((call) => call.method == 'POST'), hasLength(1));
    await restarted.stop();
    expect(() => receipt.requireCurrent(), throwsA(isA<TimewebAuthException>()));
  } finally {
    await restarted?.stop();
    await first.stop();
    await root.delete(recursive: true);
  }
}

Future<void> ownerTransfer(TimewebMeetingCreateRequest request) async {
  final root = await Directory.systemTemp.createTemp('native-meeting-owner-');
  final late = Completer<http.StreamedResponse>();
  TimewebMutationRequest? original;
  http.AbortableRequest? transfer;
  var checking = false;
  final wire = PeopleWire((call) async {
    if (call.url.path == '/v1/auth/login') return peopleReply(peopleTokens('B'));
    if (checking) {
      expect(call.method, 'GET');
      expect(call.headers['Authorization'], 'Bearer na1.A.first');
      expect(call.url.path, '/v1/runtime/operations/meeting.create.v1/${original!.operationId}');
      expect(call.url.queryParameters, {'requestHash': original!.requestHash});
      return peopleReply(envelope(original!, absent: true));
    }
    transfer = call as http.AbortableRequest;
    original = TimewebMutationRequest.createMeeting(
      operationId: jsonDecode(transfer!.body)['operationId'],
      request: request,
    );
    return late.future;
  });
  final first = runtime(wire, root);
  TimewebAppRuntime? restoredA;
  try {
    await first.start(remember: true);
    final old = await first.openMeetingCreation();
    final flight = old.submit(request);
    final expected = expectLater(
      flight,
      throwsA(
        isA<TimewebAuthException>().having(
          (error) => error.error,
          'error',
          TimewebAuthError.staleSession,
        ),
      ),
    );
    await tick(() => original != null);
    var aborted = false;
    transfer!.abortTrigger!.then((_) => aborted = true);
    await first.login(email: 'b@example.invalid', password: 'synthetic-password');
    await tick(() => aborted);
    final stale = throwsA(
      isA<AppSessionException>().having(
        (error) => error.error,
        'error',
        AppSessionError.staleSession,
      ),
    );
    expect(() => old.pendingRequest, stale);
    expect(() => old.receipt, stale);
    final other = await first.openMeetingCreation();
    expect(other.pendingRequest, isNull);
    expect(other.needsCheck, isFalse);
    other.close();
    var drained = false;
    final stop = first.stop().then((result) {
      drained = true;
      return result;
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(drained, isFalse);
    late.complete(peopleReply(envelope(original!), status: 201));
    await expected;
    expect(await stop, isTrue);
    expect(journalFiles(root), hasLength(1)); // late A ACK cannot clear intent
    checking = true;
    restoredA = runtime(wire, root);
    await restoredA.start(remember: true);
    final recovered = await restoredA.openMeetingCreation();
    expect(recovered.pendingRequest!.fields, request.fields);
    expect(await recovered.check(), TimewebMeetingCreateOutcome.unknown);
    expect(() => recovered.submit(request), throwsStateError);
    expect(wire.calls.where((call) => call.url.path == '/v1/runtime/meetings'), hasLength(1));
    recovered.close();
  } finally {
    if (!late.isCompleted) late.complete(peopleReply({}, status: 503));
    await restoredA?.stop();
    await first.stop();
    await root.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'durable native meeting: original/double tap/restart lookup only; A→B late ACK and stop drain',
    () async {
      final request = await TimewebMeetingCreateRequest.fromCatalog(
        name: '  Точная встреча  ',
        description: 'Исходное описание\n',
        countryCode: 'RU',
        region: 'Москва',
        datetime: '03.10.2026 19:15',
        type: 'индивидуальная',
        invitedUid: 'B',
      );
      await durableOriginal(request);
      await ownerTransfer(request);
    },
  );
}
