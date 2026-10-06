import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:wbrs/service/timeweb_auth_client.dart';

final peopleNow = DateTime.utc(2026, 10, 2);
const peopleStamp = '2026-10-02T12:00:00.000001Z';
TimewebSession peopleSession(String uid, [String revision = 'first']) =>
    TimewebSession(
      uid: uid,
      emailVerified: true,
      accessToken: 'na1.$uid.$revision',
      refreshToken: 'nr1.$uid.$revision',
      accessExpiresAt: peopleNow.add(const Duration(minutes: 15)),
      refreshExpiresAt: peopleNow.add(const Duration(days: 14)),
    );

class PeopleStore implements TimewebSecureTokenStore {
  TimewebSession? value = peopleSession('A');
  @override
  Future<TimewebSession?> read() async => value;
  @override
  Future<void> write(TimewebSession session) async {
    value = session;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class PeopleWire extends http.BaseClient {
  PeopleWire(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return handler(request);
  }
}

http.StreamedResponse peopleReply(
  Object body, {
  int status = 200,
  Stream<List<int>>? stream,
  int? length,
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  stream ?? Stream.value(utf8.encode(jsonEncode(body))),
  status,
  contentLength: length,
  headers: {
    'content-type': 'application/json',
    'cache-control': 'private,no-store',
    ...headers,
  },
);
Map<String, dynamic> peopleTokens(String uid, [String revision = 'rotated']) =>
    {
      'uid': uid,
      'emailVerified': true,
      'accessToken': 'na1.$uid.$revision',
      'refreshToken': 'nr1.$uid.$revision',
      'expiresIn': 900,
      'refreshExpiresIn': 1209600,
    };
Map<String, dynamic> publicPerson(
  String uid, {
  String? name = ' Current person ',
  String? stamp,
  int? age = 28,
  bool details = false,
}) => {
  'uid': uid,
  'fullName': name,
  'age': age,
  'pol': 'ж',
  'country': 'Россия',
  'countryCode': null,
  'region': 'Республика Адыгея',
  'city': null,
  'primaryGroup': 'белая',
  'secondaryGroup': null,
  'lastOnlineAt': stamp,
  'avatar': null,
  'mediaReady': false,
  if (details) ...{
    'rost': null,
    'about': '  Full\noriginal details  ',
    'hobbi': '',
    'deti': null,
    'relationStatus': null,
  },
};
Map<String, dynamic> directoryReply(List<Object?> items, [String? cursor]) => {
  'kind': 'canonical-current',
  'ordering': 'last_online_at_desc_uid_binary_asc_null_last',
  'items': items,
  'nextCursor': cursor,
  'mediaReady': false,
};
Map<String, dynamic> personReply(Map<String, dynamic> person) => {
  'kind': 'canonical-current',
  'profile': person,
  'mediaReady': false,
};
Map<String, dynamic> peopleOwn(String uid, {String stage = 'search'}) => {
  'uid': uid,
  'profileExists': true,
  'profileAuthority': 'canonical-current-v1',
  'onboarding': stage,
  'mediaReady': false,
  'profile': {
    'fullName': 'Own $uid',
    'age': 28,
    'rost': null,
    'about': 'Own native source details',
    'hobbi': null,
    'deti': null,
    'pol': null,
    'relationStatus': null,
    'country': 'Россия',
    'countryCode': 'RU',
    'region': 'Республика Адыгея',
    'city': null,
    'languageCode': 'ru',
    'primaryGroup': stage == 'search' ? 'белая' : null,
    'secondaryGroup': null,
    'profileDetailsSaved': stage != 'registration',
    'isRegistrationEnd': stage == 'search',
    'updatedAt': peopleStamp,
  },
};
