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
  // The rest of MangaDex's language set — without these, its sources in these
  // languages fell through sourceLangVisible's "unknown lang" escape hatch and
  // showed even when you'd filtered to English, and weren't in the picker to
  // turn off.
  'af': 'Afrikaans',
  'sq': 'Albanian',
  'am': 'Amharic',
  'hy': 'Armenian',
  'az': 'Azerbaijani',
  'eu': 'Basque',
  'be': 'Belarusian',
  'ceb': 'Cebuano',
  'cv': 'Chuvash',
  'eo': 'Esperanto',
  'et': 'Estonian',
  'ka': 'Georgian',
  'gu': 'Gujarati',
  'ha': 'Hausa',
  'ht': 'Haitian Creole',
  'is': 'Icelandic',
  'ig': 'Igbo',
  'ga': 'Irish',
  'jv': 'Javanese',
  'kn': 'Kannada',
  'kk': 'Kazakh',
  'km': 'Khmer',
  'ku': 'Kurdish',
  'ky': 'Kyrgyz',
  'la': 'Latin',
  'lo': 'Lao',
  'lv': 'Latvian',
  'lt': 'Lithuanian',
  'lb': 'Luxembourgish',
  'mk': 'Macedonian',
  'mg': 'Malagasy',
  'ml': 'Malayalam',
  'mt': 'Maltese',
  'mi': 'Maori',
  'mr': 'Marathi',
  'ne': 'Nepali',
  'no': 'Norwegian',
  'ny': 'Nyanja',
  'ps': 'Pashto',
  'pa': 'Punjabi',
  'sm': 'Samoan',
  'gd': 'Scottish Gaelic',
  'sn': 'Shona',
  'sd': 'Sindhi',
  'si': 'Sinhala',
  'sk': 'Slovak',
  'sl': 'Slovenian',
  'so': 'Somali',
  'st': 'Sesotho',
  'su': 'Sundanese',
  'sw': 'Swahili',
  'tg': 'Tajik',
  'te': 'Telugu',
  'ur': 'Urdu',
  'uz': 'Uzbek',
  'cy': 'Welsh',
  'xh': 'Xhosa',
  'yi': 'Yiddish',
  'yo': 'Yoruba',
  'zu': 'Zulu',
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
/// Multi-language (`all`) and blank entries always show.
///
/// [offered] is the set of codes the language picker can actually toggle. A
/// language outside it always shows — hiding one with no toggle would strand
/// the source with no way to bring it back.
///
/// Pass [offered] wherever the full set of languages IS known (your installed
/// sources, a repo index you just fetched). Leave it null and the fallback is
/// [kSourceLanguages], a hand-written list — which is where this went wrong:
/// 41 codes in the real Mihon catalogue aren't in it (`tl`, `gl`, `mo`, `gn`,
/// `other`…), so MangaDot and friends ignored the filter completely. The list
/// had already been extended once for MangaDex; it is not a list that can ever
/// be finished, which is why callers should supply what they actually have.
bool sourceLangVisible(
  String lang,
  Set<String> enabled, {
  Set<String>? offered,
}) {
  final base = sourceLangBase(lang);
  if (base.isEmpty) return true;
  final toggleable = offered ?? kSourceLanguages.keys.toSet();
  if (!toggleable.contains(base)) return true;
  return enabled.contains(base);
}

/// Every base language code present in [items] — what the picker must offer so
/// that [sourceLangVisible] is allowed to filter them.
Set<String> presentLangCodes<T>(
  Iterable<T> items,
  String Function(T) langOf,
) {
  final out = <String>{};
  for (final i in items) {
    final base = sourceLangBase(langOf(i));
    // 'all' is not a language you can switch off.
    if (base.isEmpty || base == 'all') continue;
    out.add(base);
  }
  return out;
}

/// Narrows a list of INSTALLED sources to [enabled], without ever hiding an
/// extension outright.
///
/// The installed list is also where you uninstall, open settings and sign in,
/// so a source filtered out of sight is one you can no longer manage. An
/// extension whose every language is filtered out therefore keeps all of its
/// rows instead of vanishing — you still see it, you just don't get 60 rows of
/// languages you don't read.
///
/// Grouped by [pkgOf] because that is what an "extension" is: MangaDex is one
/// package yielding one source per language.
List<T> visibleInstalledSources<T>(
  Iterable<T> items,
  Set<String> enabled, {
  required String Function(T) pkgOf,
  required String Function(T) langOf,
}) {
  // What's installed IS the full set here, so every one of these languages is
  // offered in the picker and therefore fair game to filter.
  final offered = presentLangCodes(items, langOf);
  final byPkg = <String, List<T>>{};
  for (final i in items) {
    (byPkg[pkgOf(i)] ??= <T>[]).add(i);
  }
  final out = <T>[];
  for (final group in byPkg.values) {
    final keep = group
        .where((i) => sourceLangVisible(langOf(i), enabled, offered: offered))
        .toList();
    out.addAll(keep.isEmpty ? group : keep);
  }
  return out;
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
