part of 'timeweb_auth_client.dart';

const timewebGeographyCatalogSha256 =
    '6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05';
Future<Map<String, dynamic>>? _geographyCatalog;

Future<Map<String, dynamic>> _pinnedGeographyCatalog() =>
    _geographyCatalog ??= () async {
      final asset = await rootBundle.load('assets/geo_catalog.json');
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      if (bytes.length > 65536 ||
          crypto.sha256.convert(bytes).toString() !=
              timewebGeographyCatalogSha256) {
        throw const FormatException('Approved geography is unavailable.');
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }();

/// Both exact catalog values are required. No country text, city, language,
/// normalization, arbitrary GeoCountry object or caller URL enters the request.
final class TimewebGeographyChanges {
  TimewebGeographyChanges._(this.countryCode, this.region, this._country);
  final String countryCode, region, _country;
  static Future<TimewebGeographyChanges> fromCatalog({
    required String countryCode,
    required String region,
  }) async {
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(countryCode) ||
        region.isEmpty ||
        region.runes.length > 191 ||
        utf8.encode(region).length > 764) {
      throw ArgumentError('Choose an approved country and region.');
    }
    final catalog = await _pinnedGeographyCatalog();
    for (final row in catalog['countries'] as List) {
      if (row['code'] == countryCode &&
          (row['regions'] as List).contains(region)) {
        return TimewebGeographyChanges._(countryCode, region, row['name']);
      }
    }
    throw ArgumentError('Choose an approved country and region.');
  }

  Map<String, dynamic> get _fields =>
      Map.unmodifiable({'countryCode': countryCode, 'region': region});
  @override
  String toString() => 'TimewebGeographyChanges(<redacted>)';
}

final class TimewebGeographyReceipt {
  TimewebGeographyReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebGeographyReceipt bindSessionGuard(void Function() check) =>
      TimewebGeographyReceipt._(_data, () {
        requireCurrent();
        check();
      });
  String _read(String key) {
    _check();
    return _data[key];
  }

  String get uid => _read('uid');
  String get country => _read('country');
  String get countryCode => _read('countryCode');
  String get region => _read('region');
  String get updatedAt => _read('updatedAt');
  String get profileAuthority => _read('profileAuthority');
  @override
  String toString() => 'TimewebGeographyReceipt(<redacted>)';
}
