import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// A request is durable before the first upload/write. Its stable ID survives a
/// killed process, so an uncertain commit can be checked/replayed idempotently.
class SubmissionJournal {
  SubmissionJournal({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  static final _random = Random.secure();

  Future<Directory> _folder(String uid, String scope) async {
    final root = await _directory();
    final key = base64Url.encode(utf8.encode('$uid/$scope'));
    final dir = Directory('${root.path}/clrs_submissions/$key');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Map<String, dynamic>?> load(String uid, String scope) async {
    final dir = await _folder(uid, scope);
    final file = File('${dir.path}/request.json');
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['uid'] != uid || data['scope'] != scope || data['version'] != 1)
      throw const FormatException('Invalid local request');
    return data;
  }

  Future<Map<String, dynamic>> prepare(String uid, String scope,
      Map<String, dynamic> fields, List<XFile>? images, {bool replaceRejected = false}) async {
    final previous = await load(uid, scope);
    if (previous != null && !replaceRejected) return previous;
    final dir = await _folder(uid, scope);
    final id = List.generate(20, (_) => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'[_random.nextInt(62)]).join();
    final imagePaths = <String>[];
    if (images != null) {
      for (var i = 0; i < images.length; i++) {
        final path = '${dir.path}/$id-image-$i';
        await File(images[i].path).copy(path);
        imagePaths.add(path);
      }
    }
    final data = <String, dynamic>{'version': 1, 'uid': uid, 'scope': scope,
      'id': id, 'fields': fields, 'imagePaths': imagePaths};
    final temporary = File('${dir.path}/request.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename('${dir.path}/request.json');
    return data;
  }

  Future<void> acknowledge(String uid, String scope, String requestId) async {
    final current = await load(uid, scope);
    if (current == null || current['id'] != requestId) return;
    final dir = await _folder(uid, scope);
    // Remove the identity only after server confirmation. Orphaned local image
    // cleanup can fail without turning a confirmed write into a send failure.
    await File('${dir.path}/request.json').delete();
    try { await dir.delete(recursive: true); } catch (_) {}
  }
}
