import 'package:image_picker/image_picker.dart';
import 'package:wbrs/service/submission_journal.dart';

/// Fast deterministic journal only for UI tests; disk recovery has separate real-FS tests.
class MemorySubmissionJournal extends SubmissionJournal {
  final records = <String, Map<String, dynamic>>{};
  var _next = 0;
  @override
  Future<Map<String, dynamic>?> load(String uid, String scope) async =>
      records['$uid/$scope'];
  @override
  Future<Map<String, dynamic>> prepare(
      String uid, String scope, Map<String, dynamic> fields, List<XFile>? images,
      {bool replaceRejected = false}) async {
    final key = '$uid/$scope';
    if (records[key] != null && !replaceRejected) return records[key]!;
    final imagePaths = <String>[];
    if (images != null) {
      for (var i = 0; i < images.length; i++) {
        imagePaths.add('memory://${images[i].path}-$i');
      }
    }
    return records[key] = {
      'version': 1,
      'uid': uid,
      'scope': scope,
      'id': 'request-${_next++}',
      'fields': fields,
      'imagePaths': imagePaths,
    };
  }

  @override
  Future<void> acknowledge(String uid, String scope, String requestId) async {
    final key = '$uid/$scope';
    if (records[key]?['id'] == requestId) records.remove(key);
  }
}