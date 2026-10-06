import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_photo_upload_flow.dart';
import 'support/timeweb_people_fixtures.dart';

const op = '12345678-1234-4234-8234-123456789abc';
const commitOp = '22345678-1234-4234-8234-123456789abc';
final binary = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);
TimewebProfilePhotoSource source() =>
    TimewebProfilePhotoSource.fromBytes(binary, mimeType: 'image/png');
String media(String id) =>
    'tw-profile-photo-${crypto.sha256.convert(utf8.encode('clrs-native-profile-photo-v1\u0000${jsonEncode(['A', id])}'))}';
TimewebMutationRequest prepare(String id) =>
    TimewebMutationRequest.prepareProfilePhoto(
      operationId: id,
      metadata: source().metadata,
    );
TimewebMutationRequest commit(String id, String prepareId) =>
    TimewebMutationRequest.commitProfilePhoto(
      operationId: id,
      prepareOperationId: prepareId,
      mediaId: media(prepareId),
    );
Map<String, Object?> envelope(
  TimewebMutationRequest request,
  Map<String, Object?>? result, {
  bool lookup = false,
  bool missing = false,
  Object? revision,
}) => {
  'operation': request.operation,
  'operationId': request.operationId,
  'requestHash': request.requestHash,
  'state': missing ? 'not_found' : 'committed',
  'replayed': lookup && !missing,
  'result': missing ? null : result,
  'entityRevision': revision,
};
Map<String, Object?> prepared(String id) => {
  'mediaId': media(id),
  ...source().metadata.fields,
  'status': 'pending',
  'profileAuthority': 'canonical-current-v1',
};
Map<String, Object?> ready(String id) => {
  'mediaId': media(id),
  'ready': true,
  'ordinal': 0,
  'isPrimary': true,
  'updatedAt': peopleStamp,
  'profileAuthority': 'canonical-current-v1',
};
Map<String, Object?> lease(String id, DateTime now) {
  final meta = source().metadata,
      shaBytes = [
        for (var i = 0; i < 64; i += 2)
          int.parse(meta.sha256.substring(i, i + 2), radix: 16),
      ];
  final url = Uri.https(
    's3.twcstorage.ru',
    '/synthetic-bucket/clrs-native-profile/${media(id).substring(17)}',
    {
      'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
      'X-Amz-Credential': 'SYNTHETIC_ACCESS-ID/20261002/ru-1/s3/aws4_request',
      'X-Amz-Date': '20261002T000000Z',
      'X-Amz-Expires': '60',
      'X-Amz-SignedHeaders':
          'content-length;content-type;host;if-none-match;x-amz-checksum-sha256;x-amz-content-sha256',
      'X-Amz-Signature': 'a' * 64,
    },
  );
  return {
    'mediaId': media(id),
    'method': 'PUT',
    'url': url.toString(),
    'headers': {
      'Content-Type': meta.mimeType,
      'Content-Length': '${meta.byteSize}',
      'If-None-Match': '*',
      'x-amz-checksum-sha256': base64Encode(shaBytes),
      'x-amz-content-sha256': meta.sha256,
    },
    'expiresAt': now
        .add(const Duration(seconds: 60))
        .toIso8601String()
        .replaceFirst('.000Z', '.000000Z'),
    ...meta.fields,
  };
}

TimewebAuthClient client(PeopleWire wire, {DateTime Function()? clock}) =>
    TimewebAuthClient(
      configuration: TimewebAuthConfiguration(
        endpoint: Uri.parse('https://api.example.invalid'),
        enabled: true,
        currentReadsEnabled: true,
        runtimeWritesEnabled: true,
      ),
      secureStore: PeopleStore(),
      transport: wire,
      clock: clock ?? () => peopleNow,
    );
TimewebAppRuntime runtime(
  PeopleWire wire,
  Directory folder, {
  DateTime Function()? clock,
}) => TimewebAppRuntime(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://api.example.invalid'),
    enabled: true,
    currentReadsEnabled: true,
    runtimeWritesEnabled: true,
  ),
  secureStore: PeopleStore(),
  transport: wire,
  clock: clock ?? () => peopleNow,
  deviceId: 'synthetic-device',
  expectedSourceSnapshot: 'a' * 64,
  clearLocal: () async {},
  currentOwnProfileEnabled: true,
  photoUploadJournal: TimewebPhotoUploadJournal(directory: () async => folder),
);
Future<File?> intentFile(Directory folder) async {
  final d = Directory('${folder.path}/clrs_native_photo_upload');
  if (!await d.exists()) return null;
  final files = await d
      .list()
      .where((f) => f is File && f.path.endsWith('.json'))
      .cast<File>()
      .toList();
  return files.isEmpty ? null : files.single;
}

Future<Map<String, dynamic>> intent(Directory folder) async =>
    jsonDecode(await (await intentFile(folder))!.readAsString());
Future<void> tick(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(ready(), isTrue);
}

Matcher authError(TimewebAuthError error) =>
    isA<TimewebAuthException>().having((e) => e.error, 'error', error);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'original prepare/commit durable before POST/PUT; lost ACK restart lookup-only, no upload URL/binary/path durable; disk ACK precedes READY',
    () async {
      final folder = await Directory.systemTemp.createTemp('photo-client-');
      String? prepId, commitId;
      var lookups = 0, commitLookups = 0;
      final wire = PeopleWire((call) async {
        if (call.method == 'PUT') {
          final record = await intent(folder);
          expect(record['commitOperationId'], isA<String>());
          commitId = record['commitOperationId'];
          final request = call as http.Request;
          expect(request.bodyBytes, binary);
          expect(request.followRedirects, isFalse);
          expect(request.headers.keys.toSet(), {
            'Content-Type',
            'Content-Length',
            'If-None-Match',
            'x-amz-checksum-sha256',
            'x-amz-content-sha256',
          });
          expect(
            request.headers['x-amz-content-sha256'],
            source().metadata.sha256,
          );
          expect(
            request.headers.keys.any((k) => k.toLowerCase() == 'authorization'),
            isFalse,
          );
          return peopleReply({}, status: 200);
        }
        if (call.method == 'POST') {
          final body = jsonDecode((call as http.Request).body),
              record = await intent(folder);
          expect(record.keys, hasLength(9));
          if (call.url.path.endsWith('/prepare')) {
            prepId = body['operationId'];
            expect(record['prepareOperationId'], prepId);
            expect(record['mediaId'], isNull);
            expect(body.keys.toSet(), {
              'operationId',
              'sha256',
              'byteSize',
              'mimeType',
            });
          } else {
            expect(body['operationId'], commitId);
            expect(record['commitOperationId'], commitId);
            expect(body.keys.toSet(), {
              'operationId',
              'prepareOperationId',
              'mediaId',
            });
          }
          return peopleReply({'error': 'temporarily_unavailable'}, status: 503);
        }
        if (call.url.path.endsWith('/lease')) {
          return peopleReply(lease(prepId!, peopleNow));
        }
        lookups++;
        if (call.url.path.contains('profile.photo.prepare.v1')) {
          return peopleReply(
            envelope(
              prepare(prepId!),
              prepared(prepId!),
              lookup: true,
              missing: lookups == 1,
            ),
            status: lookups == 1 ? 200 : 201,
          );
        }
        expect(call.url.path.endsWith('/$commitId'), isTrue);
        return peopleReply(
          envelope(
            commit(commitId!, prepId!),
            ready(prepId!),
            lookup: true,
            missing: ++commitLookups == 1,
          ),
        );
      });
      TimewebAppRuntime? owner;
      TimewebPhotoUploadFlow? flow;
      try {
        owner = runtime(wire, folder);
        await owner.start(remember: true);
        flow = await owner.openPhotoUpload();
        final original = source();
        final post = flow.prepare(original);
        expect(identical(post, flow.prepare(source())), isTrue);
        expect(await post, TimewebPhotoUploadOutcome.unknown);
        expect(flow.readyReceipt, isNull);
        expect(flow.needsCheck, isTrue);
        await flow.close();
        await owner.stop();
        expect(original.requireOpen, throwsStateError);
        owner = runtime(wire, folder);
        await owner.start(remember: true);
        flow = await owner.openPhotoUpload();
        expect(wire.calls, hasLength(1));
        expect(await flow.check(), TimewebPhotoUploadOutcome.unknown);
        expect(await flow.check(), TimewebPhotoUploadOutcome.prepared);
        expect(flow.prepared!.status, 'pending');
        expect(flow.readyReceipt, isNull);
        final file = File('${folder.path}/reattach-only-ram.png');
        await file.writeAsBytes(binary);
        await flow.reattachFile(file);
        expect(await flow.uploadAndCommit(), TimewebPhotoUploadOutcome.unknown);
        expect(flow.readyReceipt, isNull);
        final json = await (await intentFile(folder))!.readAsString();
        for (final secret in [
          's3.twcstorage',
          'X-Amz-',
          file.path,
          'Authorization',
          'headers',
          'url',
        ]) {
          expect(json.contains(secret), isFalse);
        }
        final persisted = await intent(folder);
        expect(persisted['prepareOperationId'], prepId);
        expect(persisted['commitOperationId'], commitId);
        await flow.close();
        await owner.stop();
        owner = runtime(wire, folder);
        await owner.start(remember: true);
        flow = await owner.openPhotoUpload();
        expect(flow.needsCheck, isTrue);
        expect(await flow.check(), TimewebPhotoUploadOutcome.unknown);
        expect(flow.needsCheck, isTrue);
        expect(wire.calls.where((c) => c.method == 'POST'), hasLength(2));
        expect(wire.calls.where((c) => c.method == 'PUT'), hasLength(1));
        expect(await flow.check(), TimewebPhotoUploadOutcome.ready);
        expect(await intentFile(folder), isNull);
        final receipt = flow.readyReceipt!;
        expect(receipt.ready, isTrue);
        expect(receipt.mediaId, media(prepId!));
        expect(receipt.isPrimary, isTrue);
        expect(wire.calls.where((c) => c.method == 'POST'), hasLength(2));
        expect(wire.calls.where((c) => c.method == 'PUT'), hasLength(1));
        await flow.close();
        expect(() => receipt.ready, throwsStateError);
      } finally {
        await flow?.close();
        await owner?.stop();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'all short errors UNKNOWN/no ACK; only exact original typed prepare/commit receipts or declared allowlist; no cached confirmed fallback',
    () async {
      for (final isCommit in [false, true]) {
        final req = isCommit ? commit(commitOp, op) : prepare(op);
        for (final status in [400, 403, 404, 409, 429, 503]) {
          final owner = client(
            PeopleWire(
              (_) async =>
                  peopleReply({'error': 'photo_unavailable'}, status: status),
            ),
          );
          try {
            await owner.restore();
            final ref = owner.bindMutation(req, expectedOwnerUid: 'A'),
                result = await owner.mutate(ref);
            expect(result.state, TimewebMutationState.unknown);
            expect(result.canAcknowledge, isFalse);
            expect(
              () => owner.acknowledgeMutation(ref),
              throwsA(authError(TimewebAuthError.invalidRequest)),
            );
            expect(owner.currentUid, 'A');
          } finally {
            await owner.stop();
          }
        }
        final failures = isCommit
            ? [
                (404, 'profile_not_found'),
                (404, 'photo_not_found'),
                (409, 'photo_limit_reached'),
                (409, 'photo_verification_failed'),
                (409, 'photo_unavailable'),
              ]
            : [(404, 'profile_not_found'), (409, 'photo_limit_reached')];
        for (final failure in failures) {
          final owner = client(
            PeopleWire(
              (_) async => peopleReply(
                envelope(req, {'error': failure.$2}),
                status: failure.$1,
              ),
            ),
          );
          try {
            await owner.restore();
            final ref = owner.bindMutation(req, expectedOwnerUid: 'A'),
                result = await owner.mutate(ref);
            expect(result.state, TimewebMutationState.declaredFailure);
            expect(result.canAcknowledge, isTrue);
            owner.acknowledgeMutation(ref);
            expect(owner.currentUid, 'A');
          } finally {
            await owner.stop();
          }
        }
        for (final bad in [
          envelope(
            req,
            isCommit
                ? {...ready(op), 'mediaId': media(commitOp)}
                : {...prepared(op), 'status': 'ready'},
          ),
          envelope(req, isCommit ? ready(op) : prepared(op), revision: 0),
          envelope(req, {'error': 'profile_not_ready'}),
        ]) {
          final owner = client(
            PeopleWire(
              (_) async => peopleReply(
                bad,
                status:
                    bad['result'] is Map &&
                        (bad['result'] as Map).containsKey('error')
                    ? 409
                    : isCommit
                    ? 200
                    : 201,
              ),
            ),
          );
          try {
            await owner.restore();
            final result = await owner.mutate(
              owner.bindMutation(req, expectedOwnerUid: 'A'),
            );
            expect(result.state, TimewebMutationState.unknown);
            expect(result.canAcknowledge, isFalse);
          } finally {
            await owner.stop();
          }
        }
      }
      var count = 0;
      final req = prepare(op),
          owner = client(
            PeopleWire(
              (_) async => ++count == 1
                  ? peopleReply(
                      envelope(prepare(op), prepared(op)),
                      status: 201,
                    )
                  : peopleReply({'error': 'photo_unavailable'}, status: 404),
            ),
          );
      try {
        await owner.restore();
        final ref = owner.bindMutation(req, expectedOwnerUid: 'A');
        expect((await owner.mutate(ref)).preparedPhoto!.status, 'pending');
        final latest = await owner.reconcileMutation(ref);
        expect(latest.state, TimewebMutationState.unknown);
        expect(latest.canAcknowledge, isFalse);
        expect(latest.preparedPhoto, isNull);
      } finally {
        await owner.stop();
      }
    },
  );
  test(
    'fresh lease exact TLS host/path/query/headers/metadata bounded expiry, single-use; lease failure never ACK; actual rejection clears durable intent',
    () async {
      var now = peopleNow;
      Map<String, Object?> body = lease(op, now);
      final wire = PeopleWire(
        (call) async => call.method == 'POST'
            ? peopleReply(envelope(prepare(op), prepared(op)), status: 201)
            : peopleReply(body),
      );
      final owner = client(wire, clock: () => now);
      try {
        await owner.restore();
        final result = await owner.mutate(
              owner.bindMutation(prepare(op), expectedOwnerUid: 'A'),
            ),
            receipt = result.preparedPhoto!;
        final issued = await owner.leaseProfilePhotoUpload(receipt);
        now = now.add(const Duration(seconds: 60));
        await expectLater(
          owner.putProfilePhoto(issued, source()),
          throwsA(authError(TimewebAuthError.invalidRequest)),
        );
        expect(wire.calls, hasLength(2));
        now = peopleNow;
        for (final changed in [
          <String, Object?>{'url': 'http://s3.twcstorage.ru/a'},
          <String, Object?>{
            'url': (body['url'] as String).replaceFirst(
              's3.twcstorage.ru',
              'foreign.invalid',
            ),
          },
          <String, Object?>{
            'url': '${body['url']}&X-Amz-Security-Token=secret',
          },
          <String, Object?>{'sha256': 'b' * 64},
          <String, Object?>{'byteSize': 11.0},
          <String, Object?>{'expiresAt': '2026-10-02T00:01:01.000000Z'},
          <String, Object?>{
            'headers': {
              ...(body['headers'] as Map),
              'x-amz-acl': 'public-read',
            },
          },
          <String, Object?>{
            'headers': {
              ...(body['headers'] as Map),
              'x-amz-content-sha256': 'UNSIGNED-PAYLOAD',
            },
          },
        ]) {
          final original = body;
          body = {...body, ...changed};
          await expectLater(
            owner.leaseProfilePhotoUpload(receipt),
            throwsA(authError(TimewebAuthError.invalidResponse)),
          );
          body = original;
        }
        final used = await owner.leaseProfilePhotoUpload(receipt);
        final bytes = source();
        expect(
          await owner.putProfilePhoto(used, bytes),
          TimewebPhotoPutOutcome.acknowledged,
        );
        expect(bytes.requireOpen, throwsStateError);
        await expectLater(
          owner.putProfilePhoto(used, source()),
          throwsA(authError(TimewebAuthError.invalidRequest)),
        );
      } finally {
        await owner.stop();
      }
      final folder = await Directory.systemTemp.createTemp('photo-rejection-');
      String? id;
      final rejectedWire = PeopleWire((call) async {
        final input = jsonDecode((call as http.Request).body);
        id = input['operationId'];
        expect((await intent(folder))['prepareOperationId'], id);
        return peopleReply(
          envelope(prepare(id!), {'error': 'photo_limit_reached'}),
          status: 409,
        );
      });
      final r = runtime(rejectedWire, folder);
      try {
        await r.start(remember: true);
        final f = await r.openPhotoUpload();
        expect(await f.prepare(source()), TimewebPhotoUploadOutcome.rejected);
        expect(f.failure, TimewebMutationFailure.photoLimitReached);
        expect(f.readyReceipt, isNull);
        expect(await intentFile(folder), isNull);
        expect(r.client.currentUid, 'A');
        await f.close();
      } finally {
        await r.stop();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'A to B late PUT cannot publish/commit; buffers purged, shared four actual slots and stop waits transport drain; original A intent retained',
    () async {
      final folder = await Directory.systemTemp.createTemp('photo-epoch-'),
          held = Completer<http.StreamedResponse>();
      String? id;
      final readReplies = <Completer<http.StreamedResponse>>[];
      http.Request? put;
      final wire = PeopleWire((call) async {
        if (call.method == 'PUT') {
          put = call as http.Request;
          return held.future;
        }
        if (call.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        if (call.url.path.contains('/people/')) {
          final reply = Completer<http.StreamedResponse>();
          readReplies.add(reply);
          return reply.future;
        }
        if (call.method == 'POST') {
          final body = jsonDecode((call as http.Request).body);
          id = body['operationId'];
          return peopleReply(
            envelope(prepare(id!), prepared(id!)),
            status: 201,
          );
        }
        return peopleReply(lease(id!, peopleNow));
      });
      final r = runtime(wire, folder);
      TimewebPhotoUploadFlow? flow;
      try {
        await r.start(remember: true);
        flow = await r.openPhotoUpload();
        final bytes = source();
        await flow.prepare(bytes);
        final upload = flow.uploadAndCommit();
        final observed = expectLater(
          upload,
          throwsA(
            anyOf(isA<AppSessionException>(), isA<TimewebAuthException>()),
          ),
        );
        await tick(() => put != null);
        final reads = [
          for (var i = 0; i < 3; i++)
            r.client.readPerson('synthetic-person-$i'),
        ];
        await tick(() => readReplies.length == 3);
        await expectLater(
          r.client.readPerson('fifth-transfer'),
          throwsA(authError(TimewebAuthError.unavailable)),
        );
        expect(readReplies, hasLength(3));
        for (var i = 0; i < 3; i++) {
          readReplies[i].complete(
            peopleReply(
              personReply(publicPerson('synthetic-person-$i', details: true)),
            ),
          );
        }
        await Future.wait(reads);
        expect(
          put!.headers.keys.any((k) => k.toLowerCase() == 'authorization'),
          isFalse,
        );
        await r.login(email: 'b@example.invalid', password: 'synthetic');
        await observed;
        expect(r.client.currentUid, 'B');
        expect(bytes.requireOpen, throwsStateError);
        expect(put!.bodyBytes, everyElement(0));
        expect(() => flow!.ownerUid, throwsA(isA<AppSessionException>()));
        final saved = await intent(folder);
        expect(saved['uid'], 'A');
        expect(saved['commitOperationId'], isNotNull);
        expect(
          wire.calls.where(
            (c) => c.method == 'POST' && c.url.path.endsWith('/commit'),
          ),
          isEmpty,
        );
        var stopped = false;
        final stop = r.stop().then((v) {
          stopped = true;
          return v;
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(stopped, isFalse);
        held.complete(peopleReply({}, status: 200));
        expect(await stop, isTrue);
        await flow.close();
        expect(await intentFile(folder), isNotNull);
      } finally {
        if (!held.isCompleted) held.complete(peopleReply({}, status: 200));
        for (var i = 0; i < readReplies.length; i++) {
          if (!readReplies[i].isCompleted) {
            readReplies[i].complete(
              peopleReply(
                personReply(publicPerson('synthetic-person-$i', details: true)),
              ),
            );
          }
        }
        await flow?.close();
        await r.stop();
        await folder.delete(recursive: true);
      }
    },
  );
}
