import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const photoPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
Uint8List photoPng() => base64Decode(photoPngBase64);
Map<String, dynamic> photoDescriptor(
  int ordinal, {
  String? reference,
  int? size,
  String mime = 'image/png',
}) => {
  'ordinal': ordinal,
  'isPrimary': ordinal == 0,
  'contentType': mime,
  'byteSize': size ?? photoPng().length,
  'reference': reference ?? 'Opaque_photo_$ordinal',
};
Map<String, dynamic> photoPage(
  String uid,
  List<Object?> items, [
  String? cursor,
]) => {
  'kind': 'canonical-profile-photos',
  'targetUid': uid,
  'ordering': 'ordinal_asc',
  'items': items,
  'nextCursor': cursor,
};
http.StreamedResponse photoContent({
  List<int>? bytes,
  int? length,
  int status = 200,
  Map<String, String> headers = const {},
  Stream<List<int>>? stream,
}) {
  final content = bytes ?? photoPng();
  return http.StreamedResponse(
    stream ?? Stream.value(content),
    status,
    contentLength: length ?? content.length,
    headers: {
      'content-type': 'image/png',
      'cache-control': 'private, no-store',
      ...headers,
    },
  );
}
