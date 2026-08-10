import 'package:flutter/widgets.dart';

/// The languages manga/anime source extensions ship in, keyed by base ISO code.
///
/// Unlike the LNReader novel index (whose `lang` is already a native name),
/// Mihon/Aniyomi extensions tag `lang` with an ISO code — `en`, `ja`, `pt-BR`,
/// `zh-Hans`, `all`… — and there's no built-in code→name lookup in the app, so
/// this is it. It doesn't have to be exhaustive: a `lang` we don't know about
/// is always shown ([sourceLangVisible]) rather than hidden behind a toggle
/// that doesn't exist.
const Map<String, String> kSourceLanguages = {
  'en': 'English',
  'ja': 'Japanese',
  'zh': 'Chinese',
  'ko': 'Korean',
  'es': 'Spanish',
  'pt': 'Portuguese',
  'fr': 'French',
  'de': 'German',
  'it': 'Italian',
  'ru': 'Russian',
  'id': 'Indonesian',
  'th': 'Thai',
  'vi': 'Vietnamese',
  'ar': 'Arabic',
  'tr': 'Turkish',
  'pl': 'Polish',
  'uk': 'Ukrainian',
  'nl': 'Dutch',
  'fa': 'Persian',
  'hi': 'Hindi',
  'fil': 'Filipino',
  'ms': 'Malay',
  'ca': 'Catalan',
  'cs': 'Czech',
  'hu': 'Hungarian',
  'ro': 'Romanian',
  'he': 'Hebrew',
  'el': 'Greek',
  'bg': 'Bulgarian',
  'sr': 'Serbian',
  'hr': 'Croatian',
  'sv': 'Swedish',
  'fi': 'Finnish',
  'da': 'Danish',
  'nb': 'Norwegian',
  'bn': 'Bengali',
  'ta': 'Tamil',
  'my': 'Burmese',
  'mn': 'Mongolian',
};

/// Reduce a raw `lang` value to the base code the filter toggles on. Region
/// variants collapse to their language (`pt-BR` → `pt`, `zh-Hans` → `zh`), and
/// the multi-language / blank sentinels collapse to '' — they aren't a
/// filterable language, they're "always show".
String sourceLangBase(String lang) {
  final l = lang.trim().toLowerCase();
  if (l.isEmpty || l == 'all' || l == 'other') return '';
  return l.split(RegExp('[-_]')).first;
}

/// Whether an entry with this [lang] should show under the [enabled] set.
///
/// Multi-language (`all`) and blank entries always show. A language the picker
/// can't offer (not in [kSourceLanguages]) also always shows — otherwise it'd
/// be permanently hidden with no toggle to bring it back. Everything else shows
/// only when its base code is enabled.
bool sourceLangVisible(String lang, Set<String> enabled) {
  final base = sourceLangBase(lang);
  if (base.isEmpty) return true;
  if (!kSourceLanguages.containsKey(base)) return true;
  return enabled.contains(base);
}

/// Filterable language codes for the picker, English first then alphabetical by
/// name.
List<String> sortedSourceLangCodes() {
  final codes = kSourceLanguages.keys.toList()
    ..sort((a, b) {
      if (a == b) return 0;
      if (a == 'en') return -1;
      if (b == 'en') return 1;
      return kSourceLanguages[a]!.compareTo(kSourceLanguages[b]!);
    });
  return codes;
}

/// Display name for a language code (falls back to the raw code for the rare
/// unknown value).
String sourceLangLabel(String code) => kSourceLanguages[code] ?? code;

/// First-run default: English plus the device's language (when it's one we can
/// filter on). Used until the user opens the Languages picker and saves a set.
Set<String> defaultSourceLangs() {
  final device =
      WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  final base = sourceLangBase(device);
  return {'en', if (kSourceLanguages.containsKey(base)) base};
}
