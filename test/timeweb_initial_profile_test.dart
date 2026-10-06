import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_photo_upload_flow.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'support/timeweb_people_fixtures.dart';

const initialStamp = '2026-10-02T12:00:00.000002Z';
String uuid(int n) =>
    '${n.toRadixString(16).padLeft(8, '0')}-1234-4234-8234-123456789abc';
String media(String id) =>
    'tw-profile-photo-${crypto.sha256.convert(utf8.encode('clrs-native-profile-photo-v1\u0000${jsonEncode(['A', id])}'))}';
final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
TimewebProfilePhotoSource source() =>
    TimewebProfilePhotoSource.fromBytes(bytes, mimeType: 'image/png');
TimewebMutationRequest prep(String id) =>
    TimewebMutationRequest.prepareProfilePhoto(
      operationId: id,
      metadata: source().metadata,
    );
TimewebMutationRequest commit(String id, String prepare) =>
    TimewebMutationRequest.commitProfilePhoto(
      operationId: id,
      prepareOperationId: prepare,
      mediaId: media(prepare),
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
Map<String, Object?> ready(String prepare, {int ordinal = 0}) => {
  'mediaId': media(prepare),
  'ready': true,
  'ordinal': ordinal,
  'isPrimary': ordinal == 0,
  'updatedAt': peopleStamp,
  'profileAuthority': 'canonical-current-v1',
};
Map<String, Object?> finish() => {
  'uid': 'A',
  'profileDetailsSaved': true,
  'onboarding': 'test',
  'updatedAt': initialStamp,
  'profileAuthority': 'canonical-current-v1',
};
TimewebProfileChanges changes() => TimewebProfileChanges(
  fullName: ' Exact own name ',
  age: 28,
  rost: 173,
  about: ' Original multiline about\nwith twenty characters 🙂 ',
  hobbi: ' Original interests retained\twith whitespace ',
  deti: false,
  pol: 'м',
  relationStatus: 'не женат',
);
Future<TimewebInitialProfileRequest> request(TimewebInitialProfileFlow flow) =>
    TimewebGeographyChanges.fromCatalog(
      countryCode: 'RU',
      region: 'Республика Адыгея',
    ).then(
      (geo) => TimewebInitialProfileRequest(
        expectedUpdatedAt: peopleStamp,
        changes: changes(),
        geography: geo,
        photos: flow.readyPhotos,
      ),
    );
TimewebAppRuntime runtime(PeopleWire wire, Directory folder) =>
    TimewebAppRuntime(
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
      photoUploadJournal: TimewebPhotoUploadJournal(
        directory: () async => folder,
      ),
      initialProfileJournal: TimewebInitialProfileJournal(
        directory: () async => folder,
      ),
    );
Future<File?> recordFile(Directory folder, String name) async {
  final d = Directory('${folder.path}/$name');
  if (!await d.exists()) return null;
  final files = await d
      .list()
      .where((p) => p is File && p.path.endsWith('.json'))
      .cast<File>()
      .toList();
  return files.isEmpty ? null : files.single;
}

Future<Map<String, dynamic>> record(Directory folder, String name) async =>
    jsonDecode(await (await recordFile(folder, name))!.readAsString());
Future<void> retainPhoto(
  TimewebAppRuntime r,
  TimewebInitialProfileFlow flow,
  int n,
) async {
  final ref = r.client.bindMutation(
        commit(uuid(n + 100), uuid(n)),
        expectedOwnerUid: 'A',
      ),
      result = await r.client.mutate(ref);
  await flow.addReadyPhoto(result.committedPhoto!);
  r.client.acknowledgeMutation(ref);
}

Future<void> tick(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(ready(), isTrue);
}

Matcher authError(TimewebAuthError e) =>
    isA<TimewebAuthException>().having((v) => v.error, 'error', e);
// Synthetic exact receipt responder, with no real SQL/S3/photo proof claim.
http.StreamedResponse photoReply(http.BaseRequest call) {
  final lookup = call.method == 'GET';
  final id = lookup
      ? call.url.pathSegments.last
      : jsonDecode((call as http.Request).body)['operationId'];
  final n = int.parse(id.substring(0, 8), radix: 16) - 100, prepare = uuid(n);
  return peopleReply(
    envelope(
      commit(id, prepare),
      ready(prepare, ordinal: n - 1),
      lookup: lookup,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final path = utf8.decode(
            message!.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          if (path != 'assets/geo_catalog.json') {
            throw StateError('Unexpected asset');
          }
          final data = await File(path).readAsBytes();
          return ByteData.sublistView(data);
        });
  });
  test(
    'before-ACK callback crash retains original photo; restart lookup replays idempotent pointer fsync before ACK; three original proofs persist without URL/binary',
    () async {
      final folder = await Directory.systemTemp.createTemp('initial-callback-');
      String? prepareId, commitId;
      var crash = true;
      final wire = PeopleWire((call) async {
        if (call.method == 'PUT') return peopleReply({});
        if (call.url.path.endsWith('/lease')) {
          final meta = source().metadata,
              shaBytes = [
                for (var i = 0; i < 64; i += 2)
                  int.parse(meta.sha256.substring(i, i + 2), radix: 16),
              ];
          return peopleReply({
            'mediaId': media(prepareId!),
            'method': 'PUT',
            'url': Uri.https(
              's3.twcstorage.ru',
              '/synthetic-bucket/clrs-native-profile/${media(prepareId!).substring(17)}',
              {
                'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
                'X-Amz-Credential':
                    'SYNTHETIC_ACCESS-ID/20261002/ru-1/s3/aws4_request',
                'X-Amz-Date': '20261002T000000Z',
                'X-Amz-Expires': '60',
                'X-Amz-SignedHeaders':
                    'content-length;content-type;host;if-none-match;x-amz-checksum-sha256;x-amz-content-sha256',
                'X-Amz-Signature': 'a' * 64,
              },
            ).toString(),
            'headers': {
              'Content-Type': meta.mimeType,
              'Content-Length': '${meta.byteSize}',
              'If-None-Match': '*',
              'x-amz-checksum-sha256': base64Encode(shaBytes),
              'x-amz-content-sha256': meta.sha256,
            },
            'expiresAt': '2026-10-02T00:01:00.000000Z',
            ...meta.fields,
          });
        }
        if (call.url.path.endsWith('/prepare')) {
          prepareId = jsonDecode((call as http.Request).body)['operationId'];
          return peopleReply(
            envelope(prep(prepareId!), {
              'mediaId': media(prepareId!),
              ...source().metadata.fields,
              'status': 'pending',
              'profileAuthority': 'canonical-current-v1',
            }),
            status: 201,
          );
        }
        if (call.url.path.endsWith('/commit')) {
          final body = jsonDecode((call as http.Request).body);
          if (body['prepareOperationId'] == prepareId) {
            commitId = body['operationId'];
            return peopleReply(
              envelope(commit(commitId!, prepareId!), ready(prepareId!)),
            );
          }
          return photoReply(call);
        }
        if (call.url.pathSegments.last == commitId) {
          return peopleReply(
            envelope(
              commit(commitId!, prepareId!),
              ready(prepareId!),
              lookup: true,
            ),
          );
        }
        return photoReply(call);
      });
      TimewebAppRuntime? r;
      TimewebInitialProfileFlow? initial;
      TimewebPhotoUploadFlow? photo;
      try {
        r = runtime(wire, folder);
        await r.start(remember: true);
        initial = await r.openInitialProfile();
        photo = await r.openPhotoUpload(
          onReady: (receipt) async {
            await initial!.addReadyPhoto(receipt);
            expect(
              (await record(
                folder,
                'clrs_native_photo_upload',
              ))['commitOperationId'],
              receipt.commitOperationId,
            );
            if (crash) {
              crash = false;
              throw StateError(
                'Synthetic crash after draft fsync before photo ACK.',
              );
            }
          },
        );
        await photo.prepare(source());
        await expectLater(photo.uploadAndCommit(), throwsStateError);
        expect(photo.needsCheck, isTrue);
        expect(photo.readyReceipt, isNull);
        expect(
          (await record(folder, 'clrs_native_initial_profile'))['photos'],
          hasLength(1),
        );
        expect(await recordFile(folder, 'clrs_native_photo_upload'), isNotNull);
        await photo.close();
        initial.close();
        await r.stop();
        r = runtime(wire, folder);
        await r.start(remember: true);
        initial = await r.openInitialProfile();
        expect(initial.readyPhotos, hasLength(1));
        expect(initial.photosVerified, isFalse);
        final count = wire.calls.length;
        photo = await r.openPhotoUpload(onReady: initial.addReadyPhoto);
        expect(wire.calls, hasLength(count));
        expect(await photo.check(), TimewebPhotoUploadOutcome.ready);
        expect(initial.readyPhotos, hasLength(1));
        expect(await recordFile(folder, 'clrs_native_photo_upload'), isNull);
        expect(wire.calls.where((c) => c.method == 'PUT'), hasLength(1));
        final kept = initial.readyPhotos.single;
        expect(kept.prepareOperationId, prepareId);
        expect(kept.commitOperationId, commitId);
        await photo.close();
        expect(kept.mediaId, media(prepareId!));
        await retainPhoto(r, initial, 2);
        await retainPhoto(r, initial, 3);
        expect(initial.readyPhotos, hasLength(3));
        initial.close();
        initial = await r.openInitialProfile();
        expect(initial.readyPhotos, hasLength(3));
        await initial.checkPhotos();
        expect(initial.photosVerified, isTrue);
        final raw = await (await recordFile(
          folder,
          'clrs_native_initial_profile',
        ))!.readAsString();
        for (final forbidden in [
          's3.twcstorage',
          'X-Amz-',
          'headers',
          'mimeType',
          'sha256',
          'url',
          'byteSize',
        ]) {
          expect(raw.contains(forbidden), isFalse);
        }
      } finally {
        await photo?.close();
        initial?.close();
        await r?.stop();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'finish intent exact fields/hash fsynced before POST; UNKNOWN restart performs only original lookup, notFound preserves operation; disk ACK before canonical test receipt',
    () async {
      final folder = await Directory.systemTemp.createTemp('initial-finish-');
      TimewebMutationRequest? original;
      var checks = 0;
      final wire = PeopleWire((call) async {
        if (call.url.path.endsWith('/registration')) {
          final v = await record(folder, 'clrs_native_initial_profile'),
              body = jsonDecode((call as http.Request).body);
          expect(body.keys.toSet(), {
            'operationId',
            'expectedUpdatedAt',
            'changes',
            'geography',
            'photos',
          });
          expect(body['operationId'], v['operationId']);
          expect(body['changes'].keys.toSet(), {
            'fullName',
            'age',
            'rost',
            'about',
            'hobbi',
            'deti',
            'pol',
            'relationStatus',
          });
          expect(body['photos'], hasLength(3));
          expect(v['request'], {
            for (final e in body.entries)
              if (e.key != 'operationId') e.key: e.value,
          });
          return peopleReply({'error': 'temporarily_unavailable'}, status: 503);
        }
        if (call.url.path.contains('/profile.finish-registration.v1/')) {
          expect(call.url.path.endsWith('/${original!.operationId}'), isTrue);
          expect(
            call.url.queryParameters['requestHash'],
            original.requestHash,
          );
          return peopleReply(
            envelope(original, finish(), lookup: true, missing: ++checks == 1),
          );
        }
        return photoReply(call);
      });
      TimewebAppRuntime? r;
      TimewebInitialProfileFlow? flow;
      try {
        r = runtime(wire, folder);
        await r.start(remember: true);
        flow = await r.openInitialProfile();
        for (var i = 1; i <= 3; i++) {
          await retainPhoto(r, flow, i);
        }
        final input = await request(flow);
        final future = flow.submit(input);
        expect(identical(future, flow.submit(input)), isTrue);
        expect(await future, TimewebInitialProfileOutcome.unknown);
        final disk = await record(folder, 'clrs_native_initial_profile');
        original = TimewebMutationRequest.finishInitialProfile(
          operationId: disk['operationId'],
          request: input,
        );
        expect(disk['requestHash'], original.requestHash);
        expect(flow.needsCheck, isTrue);
        expect(flow.receipt, isNull);
        flow.close();
        await r.stop();
        final calls = wire.calls.length;
        r = runtime(wire, folder);
        await r.start(remember: true);
        flow = await r.openInitialProfile();
        expect(wire.calls, hasLength(calls));
        expect(flow.pendingRequest!.changes['about'], input.changes['about']);
        expect(flow.pendingRequest!.photos, hasLength(3));
        expect(flow.pendingRequest!.countryCode, 'RU');
        expect(flow.checkPhotos, throwsStateError);
        expect(await flow.check(), TimewebInitialProfileOutcome.unknown);
        expect(flow.needsCheck, isTrue);
        expect(await flow.check(), TimewebInitialProfileOutcome.confirmed);
        expect(await recordFile(folder, 'clrs_native_initial_profile'), isNull);
        final result = flow.receipt!;
        expect(result.uid, 'A');
        expect(result.profileDetailsSaved, isTrue);
        expect(result.onboarding, 'test');
        expect(result.updatedAt, initialStamp);
        expect(flow.readyPhotos, isEmpty);
        expect(flow.pendingRequest, isNull);
        expect(wire.calls.skip(calls), hasLength(2));
        expect(
          wire.calls.where((c) => c.url.path.endsWith('/registration')),
          hasLength(1),
        );
        expect(r.client.currentUid, 'A');
        flow.close();
        expect(() => result.uid, throwsStateError);
      } finally {
        flow?.close();
        await r?.stop();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'short 403/404/errors UNKNOWN healthy; exact committed allowlist/stamps and result, same-runtime owner/three pointers enforced',
    () async {
      final folder = await Directory.systemTemp.createTemp('initial-wire-');
      Object? reply;
      var status = 200;
      final wire = PeopleWire(
        (call) async => call.url.path.endsWith('/registration')
            ? peopleReply(reply!, status: status)
            : photoReply(call),
      );
      final r = runtime(wire, folder);
      TimewebInitialProfileFlow? flow;
      try {
        await r.start(remember: true);
        flow = await r.openInitialProfile();
        for (var i = 1; i <= 3; i++) {
          await retainPhoto(r, flow, i);
        }
        final input = await request(flow);
        await expectLater(
          TimewebGeographyChanges.fromCatalog(
            countryCode: 'ZZ',
            region: 'unknown',
          ),
          throwsArgumentError,
        );
        final geo = await TimewebGeographyChanges.fromCatalog(
          countryCode: 'RU',
          region: 'Республика Адыгея',
        );
        expect(
          () => TimewebInitialProfileRequest(
            expectedUpdatedAt: peopleStamp,
            changes: TimewebProfileChanges(fullName: 'Name'),
            geography: geo,
            photos: input.photos,
          ),
          throwsArgumentError,
        );
        expect(
          () => TimewebInitialProfileRequest(
            expectedUpdatedAt: peopleStamp,
            changes: changes(),
            geography: geo,
            photos: [input.photos.first, input.photos.first, input.photos.last],
          ),
          throwsArgumentError,
        );
        for (final code in [400, 403, 404, 409, 429, 503]) {
          status = code;
          reply = {'error': 'registration_unavailable'};
          final req = TimewebMutationRequest.finishInitialProfile(
                operationId: uuid(900 + code),
                request: input,
              ),
              ref = r.client.bindMutation(req, expectedOwnerUid: 'A'),
              result = await r.client.mutate(ref);
          expect(result.state, TimewebMutationState.unknown);
          expect(result.canAcknowledge, isFalse);
          expect(r.client.currentUid, 'A');
          expect(
            () => r.client.acknowledgeMutation(ref),
            throwsA(authError(TimewebAuthError.invalidRequest)),
          );
        }
        final errors = [
          (404, 'profile_not_found', false),
          (404, 'photo_not_found', false),
          (409, 'photo_not_ready', false),
          (409, 'profile_changed', true),
          (409, 'registration_already_saved', true),
          (409, 'registration_already_completed', true),
        ];
        for (var i = 0; i < errors.length; i++) {
          final error = errors[i],
              req = TimewebMutationRequest.finishInitialProfile(
                operationId: uuid(1500 + i),
                request: input,
              );
          status = error.$1;
          reply = envelope(req, {
            'error': error.$2,
            if (error.$3) 'updatedAt': initialStamp,
          });
          final ref = r.client.bindMutation(req, expectedOwnerUid: 'A'),
              result = await r.client.mutate(ref);
          expect(result.state, TimewebMutationState.declaredFailure);
          expect(result.canAcknowledge, isTrue);
          expect(result.conflictUpdatedAt, error.$3 ? initialStamp : null);
          r.client.acknowledgeMutation(ref);
          expect(r.client.currentUid, 'A');
        }
        final bad = [
          {...finish(), 'uid': 'B'},
          {...finish(), 'profileDetailsSaved': false},
          {...finish(), 'onboarding': 'search'},
          {...finish(), 'profileAuthority': 'legacy-source-v1'},
          {...finish(), 'updatedAt': peopleStamp},
          {...finish(), 'updatedAt': '2026-10-02T12:00:00Z'},
          {...finish(), 'photoURL': 'https://foreign.invalid/photo'},
        ];
        for (var i = 0; i < bad.length; i++) {
          final req = TimewebMutationRequest.finishInitialProfile(
            operationId: uuid(2000 + i),
            request: input,
          );
          status = 200;
          reply = envelope(req, bad[i]);
          final result = await r.client.mutate(
            r.client.bindMutation(req, expectedOwnerUid: 'A'),
          );
          expect(result.state, TimewebMutationState.unknown);
          expect(result.canAcknowledge, isFalse);
        }
        for (var i = 0; i < 3; i++) {
          final req = TimewebMutationRequest.finishInitialProfile(
            operationId: uuid(2100 + i),
            request: input,
          );
          status = i == 0 ? 200 : 409;
          reply = i == 0
              ? envelope(req, finish(), revision: 0)
              : envelope(req, {
                  'error': i == 1
                      ? 'profile_changed'
                      : 'photo_verification_failed',
                });
          final result = await r.client.mutate(
            r.client.bindMutation(req, expectedOwnerUid: 'A'),
          );
          expect(result.canAcknowledge, isFalse);
        }
        final other = TimewebAuthClient(
          configuration: r.client.configuration,
          secureStore: PeopleStore(),
          transport: PeopleWire((_) async => throw StateError('No transfer')),
          clock: () => peopleNow,
        );
        try {
          await other.restore();
          expect(
            () => other.bindMutation(
              TimewebMutationRequest.finishInitialProfile(
                operationId: uuid(2500),
                request: input,
              ),
              expectedOwnerUid: 'A',
            ),
            throwsA(authError(TimewebAuthError.staleSession)),
          );
        } finally {
          await other.stop();
        }
      } finally {
        flow?.close();
        await r.stop();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'A to B late finish cannot publish; held ready pointers revoked, durable A operation retained and actual transfer drains before stop',
    () async {
      final folder = await Directory.systemTemp.createTemp('initial-epoch-'),
          held = Completer<http.StreamedResponse>();
      bool posted = false;
      TimewebMutationRequest? original;
      final wire = PeopleWire((call) async {
        if (call.url.path.endsWith('/registration')) {
          posted = true;
          return held.future;
        }
        if (call.url.path == '/v1/auth/login') {
          return peopleReply(peopleTokens('B'));
        }
        return photoReply(call);
      });
      final r = runtime(wire, folder);
      TimewebInitialProfileFlow? flow;
      try {
        await r.start(remember: true);
        flow = await r.openInitialProfile();
        for (var i = 1; i <= 3; i++) {
          await retainPhoto(r, flow, i);
        }
        final input = await request(flow), pointer = flow.readyPhotos.first;
        final submit = flow.submit(input),
            observed = expectLater(
              submit,
              throwsA(
                anyOf(isA<TimewebAuthException>(), isA<AppSessionException>()),
              ),
            );
        await tick(() => posted);
        final stored = await record(folder, 'clrs_native_initial_profile');
        original = TimewebMutationRequest.finishInitialProfile(
          operationId: stored['operationId'],
          request: input,
        );
        await r.login(email: 'b@example.invalid', password: 'synthetic');
        await observed;
        expect(r.client.currentUid, 'B');
        expect(
          () => pointer.mediaId,
          throwsA(authError(TimewebAuthError.staleSession)),
        );
        expect(() => flow!.readyPhotos, throwsA(isA<AppSessionException>()));
        expect(
          (await record(folder, 'clrs_native_initial_profile'))['uid'],
          'A',
        );
        final other = await r.openInitialProfile();
        expect(other.readyPhotos, isEmpty);
        other.close();
        var done = false;
        final stop = r.stop().then((v) {
          done = true;
          return v;
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(done, isFalse);
        held.complete(peopleReply(envelope(original, finish())));
        expect(await stop, isTrue);
        expect(
          (await record(folder, 'clrs_native_initial_profile'))['operationId'],
          original.operationId,
        );
      } finally {
        if (!held.isCompleted) held.complete(peopleReply({}));
        flow?.close();
        await r.stop();
        await folder.delete(recursive: true);
      }
    },
  );
}
