import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

/// Source-language keys are deliberately readable Russian UI strings. Only
/// explicitly marked UI text is localized; user content and stored enum values
/// must never be passed to [text]. Placeholders use `{name}`, not interpolation.
class ClrsLocalizations {
  ClrsLocalizations(this.locale, Map<String, dynamic> messages,
      {Map<String, dynamic> english = const {},
      Map<String, dynamic> russian = const {}})
      : _messages = Map.unmodifiable(messages),
        _english = Map.unmodifiable(english),
        _russian = Map.unmodifiable(russian) {
    // intl's bundled initializer installs symbols synchronously before returning
    // its completed Future; source-only widgets can format dates without a
    // MaterialApp localization delegate (for example isolated previews/tests).
    initializeDateFormatting();
  }

  final Locale locale;
  final Map<String, dynamic> _messages, _english, _russian;
  static const codes = <String>[
    'en',
    'de',
    'es',
    'fr',
    'it',
    'pt',
    'el',
    'ru',
    'sr',
    'pl',
    'sl',
    'sk',
    'cs',
    'bg',
    'ro',
    'mk',
    'hu',
    'sv',
    'nb',
    'fi',
    'da',
    'nl',
    'is',
  ];
  static const nativeNames = <String, String>{
    'en': 'English',
    'de': 'Deutsch',
    'es': 'Español',
    'fr': 'Français',
    'it': 'Italiano',
    'pt': 'Português',
    'el': 'Ελληνικά',
    'ru': 'Русский',
    'sr': 'Srpski',
    'pl': 'Polski',
    'sl': 'Slovenščina',
    'sk': 'Slovenčina',
    'cs': 'Čeština',
    'bg': 'Български',
    'ro': 'Română',
    'mk': 'Македонски',
    'hu': 'Magyar',
    'sv': 'Svenska',
    'nb': 'Norsk bokmål',
    'fi': 'Suomi',
    'da': 'Dansk',
    'nl': 'Nederlands',
    'is': 'Íslenska',
  };
  static final supportedLocales =
      List<Locale>.unmodifiable(codes.map(localeFor));
  static const delegate = _ClrsDelegate();
  static const delegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
  static final _sourceOnly = ClrsLocalizations(const Locale('ru'), const {});
  static ClrsLocalizations of(BuildContext context) =>
      Localizations.of<ClrsLocalizations>(context, ClrsLocalizations) ??
      _sourceOnly;

  static Locale localeFor(String code) => code == 'sr'
      ? const Locale.fromSubtags(languageCode: 'sr', scriptCode: 'Latn')
      : Locale(code);
  static String normalizeCode(String? code) {
    final language =
        (code ?? '').toLowerCase().replaceAll('-', '_').split('_').first;
    return language == 'no' ? 'nb' : language;
  }

  static Locale resolveLocale(Locale? device, [Iterable<Locale>? supported]) {
    final code = normalizeCode(device?.languageCode);
    return localeFor(codes.contains(code) ? code : 'en');
  }

  static Future<ClrsLocalizations> load(Locale locale,
      {AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final code = normalizeCode(locale.languageCode);
    final selected = codes.contains(code) ? code : 'en';
    Future<Map<String, dynamic>> read(String language) async =>
        Map<String, dynamic>.from(
            jsonDecode(await assets.loadString('assets/l10n/$language.json'))
                as Map);
    // Catalogs are bundled app resources; an absent/broken one is a build defect,
    // not a silently swallowed network failure. Completeness is checked in CI.
    final values = await Future.wait([read(selected), read('en'), read('ru')]);
    await initializeDateFormatting(selected);
    return ClrsLocalizations(localeFor(selected), values[0],
        english: values[1], russian: values[2]);
  }

  String text(String key, {Map<String, Object?> args = const {}, num? count}) {
    final value = _messages[key] ?? _english[key] ?? _russian[key] ?? key;
    final String template;
    if (value is Map) {
      if (count == null) {
        throw ArgumentError('Plural message requires a count: $key');
      }
      String? form(String name) => value[name] as String?;
      template = Intl.pluralLogic(count,
          locale: locale.languageCode,
          zero: form('zero'),
          one: form('one'),
          two: form('two'),
          few: form('few'),
          many: form('many'),
          other: form('other') ?? key);
    } else {
      template = value.toString();
    }
    final parameters = <String, Object?>{
      ...args,
      if (count != null) 'count': number(count)
    };
    return template.replaceAllMapped(RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}'),
        (match) {
      final name = match.group(1)!;
      if (!parameters.containsKey(name)) {
        throw ArgumentError('Missing localization argument "$name" for "$key"');
      }
      return '${parameters[name] ?? ''}';
    });
  }

  /// Exact, parameter-free catalog matches may be reused for legacy enum values.
  /// Arbitrary content is otherwise handled by the authenticated translator.
  String? literalTranslation(String original) {
    // Native gift notices contain a catalog name, not free-form user prose.
    // Keep the approved name instead of asking language detection to guess
    // from a short product title.
    final gift = RegExp(r'^Подарок «([^«»\n]{1,200})»( ❤️)?$')
        .firstMatch(original);
    if (gift != null) {
      final name = literalTranslation(gift.group(1)!);
      final label = literalTranslation('Подарок');
      if (name != null && label != null) {
        return '$label «$name»${gift.group(2) ?? ''}';
      }
    }
    final value =
        _messages[original] ?? _english[original] ?? _russian[original];
    if (value is! String ||
        RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}').hasMatch(value)) return null;
    return value;
  }

  String get _formatLocale =>
      locale.languageCode == 'sr' ? 'sr_Latn' : locale.languageCode;

  String number(num value, {int? decimalDigits}) {
    final format = NumberFormat.decimalPattern(_formatLocale);
    if (decimalDigits != null) {
      format.minimumFractionDigits = decimalDigits;
      format.maximumFractionDigits = decimalDigits;
    }
    return format.format(value);
  }

  String date(DateTime value) => DateFormat.yMMMd(_formatLocale).format(value);
  String shortDate(DateTime value) =>
      DateFormat.yMd(_formatLocale).format(value);
  String time(DateTime value, {bool alwaysUse24HourFormat = false}) =>
      (alwaysUse24HourFormat
              ? DateFormat.Hm(_formatLocale)
              : DateFormat.jm(_formatLocale))
          .format(value);
  String dateTime(DateTime value) => '${date(value)}, ${time(value)}';

  String get cancel => text('Отмена');
  String get save => text('Сохранить');
  String get retry => text('Повторить');
  String get close => text('Закрыть');
  String get language => text('Язык');
}

extension ClrsTranslations on BuildContext {
  ClrsLocalizations get l10n => ClrsLocalizations.of(this);
  String tr(String key, {Map<String, Object?> args = const {}, num? count}) =>
      l10n.text(key, args: args, count: count);
}

class _ClrsDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _ClrsDelegate();
  @override
  bool isSupported(Locale locale) => ClrsLocalizations.codes
      .contains(ClrsLocalizations.normalizeCode(locale.languageCode));
  @override
  Future<ClrsLocalizations> load(Locale locale) =>
      ClrsLocalizations.load(locale);
  @override
  bool shouldReload(_ClrsDelegate old) => false;
}
