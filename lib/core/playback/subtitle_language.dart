// Language model and helpers for the preferred-subtitle-language feature.
//
// A [Language] carries the ISO-639-1 two-letter code (iso1), the ISO-639-2
// three-letter code (iso2), and a human-readable English name.
//
// kSubtitleLanguages is the canonical list shown in the Settings picker.
// languageByPref resolves a stored iso1 code back to a Language.
// matchesSourceLang checks whether a provider-supplied free-form language
// string corresponds to the given Language — tolerating both ISO codes and
// full English names (e.g. "English", "arabic", "chi").

class Language {
  const Language({
    required this.name,
    required this.iso1,
    required this.iso2,
  });

  /// Human-readable English name (e.g. "English", "Arabic").
  final String name;

  /// ISO-639-1 two-letter code (e.g. "en", "ar").
  final String iso1;

  /// ISO-639-2 three-letter code (e.g. "eng", "ara").
  final String iso2;

  @override
  String toString() => name;
}

/// Canonical list of ~25 common languages for the subtitle-language picker.
const List<Language> kSubtitleLanguages = [
  Language(name: 'English',    iso1: 'en', iso2: 'eng'),
  Language(name: 'Spanish',    iso1: 'es', iso2: 'spa'),
  Language(name: 'Arabic',     iso1: 'ar', iso2: 'ara'),
  Language(name: 'Hindi',      iso1: 'hi', iso2: 'hin'),
  Language(name: 'French',     iso1: 'fr', iso2: 'fre'),
  Language(name: 'German',     iso1: 'de', iso2: 'ger'),
  Language(name: 'Portuguese', iso1: 'pt', iso2: 'por'),
  Language(name: 'Italian',    iso1: 'it', iso2: 'ita'),
  Language(name: 'Russian',    iso1: 'ru', iso2: 'rus'),
  Language(name: 'Japanese',   iso1: 'ja', iso2: 'jpn'),
  Language(name: 'Korean',     iso1: 'ko', iso2: 'kor'),
  Language(name: 'Chinese',    iso1: 'zh', iso2: 'chi'),
  Language(name: 'Turkish',    iso1: 'tr', iso2: 'tur'),
  Language(name: 'Indonesian', iso1: 'id', iso2: 'ind'),
  Language(name: 'Dutch',      iso1: 'nl', iso2: 'dut'),
  Language(name: 'Polish',     iso1: 'pl', iso2: 'pol'),
  Language(name: 'Vietnamese', iso1: 'vi', iso2: 'vie'),
  Language(name: 'Thai',       iso1: 'th', iso2: 'tha'),
  Language(name: 'Tamil',      iso1: 'ta', iso2: 'tam'),
  Language(name: 'Telugu',     iso1: 'te', iso2: 'tel'),
  Language(name: 'Bengali',    iso1: 'bn', iso2: 'ben'),
  Language(name: 'Malayalam',  iso1: 'ml', iso2: 'mal'),
  Language(name: 'Urdu',       iso1: 'ur', iso2: 'urd'),
  Language(name: 'Persian',    iso1: 'fa', iso2: 'per'),
  Language(name: 'Greek',      iso1: 'el', iso2: 'gre'),
];

/// Returns the [Language] whose [Language.iso1] matches [pref], or null if
/// [pref] is empty or not found. [pref] is the value stored in
/// [PlaybackPrefs.preferredSubtitleLanguage].
Language? languageByPref(String pref) {
  if (pref.isEmpty) return null;
  final lower = pref.toLowerCase();
  for (final lang in kSubtitleLanguages) {
    if (lang.iso1 == lower) return lang;
  }
  return null;
}

/// Returns true if the provider-supplied free-form [sourceLang] string
/// corresponds to [lang].
///
/// Tolerates providers that emit "English", "English (SDH)", "eng", "en", etc.
/// Codes are matched as WHOLE TOKENS, never substrings, so a 2/3-letter code
/// can't accidentally match inside an unrelated name (e.g. "en"/"eng" must not
/// match "Bengali").
bool matchesSourceLang(String sourceLang, Language lang) {
  final s = sourceLang.toLowerCase().trim();
  if (s.isEmpty) return false;
  final name = lang.name.toLowerCase();
  // Whole-string or decorated-name match ("english", "english (sdh)").
  if (s == lang.iso1 || s == lang.iso2 || s == name || s.contains(name)) {
    return true;
  }
  // Token match: a code/name recognised only as a standalone word.
  for (final token in s.split(RegExp(r'[^a-z]+'))) {
    if (token.isEmpty) continue;
    if (token == lang.iso1 || token == lang.iso2 || token == name) return true;
  }
  return false;
}
