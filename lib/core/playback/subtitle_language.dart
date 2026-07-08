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

import '../models/video_source.dart';

class Language {
  const Language({
    required this.name,
    required this.iso1,
    required this.iso2,
    String? iso2t,
    this.native = const [],
    this.aliases = const [],
  }) : iso2t = iso2t ?? iso2;

  /// Human-readable English name (e.g. "English", "Arabic").
  final String name;

  /// ISO-639-1 two-letter code (e.g. "en", "ar").
  final String iso1;

  /// ISO-639-2/B ("bibliographic") three-letter code (e.g. "fre", "ger").
  final String iso2;

  /// ISO-639-2/T ("terminology") code where it differs from [iso2]
  /// (e.g. "fra", "deu"); equals [iso2] when there is no distinct /T code.
  final String iso2t;

  /// Native/self names a source might use (e.g. "Français", "日本語").
  final List<String> native;

  /// Regional/descriptive labels a source might use (e.g. "Brazilian",
  /// "Farsi", "Simplified") — all mapped to this language.
  final List<String> aliases;

  @override
  String toString() => name;
}

/// Canonical list of ~25 common languages for the subtitle-language picker.
const List<Language> kSubtitleLanguages = [
  Language(name: 'English',    iso1: 'en', iso2: 'eng', native: ['English']),
  Language(name: 'Spanish',    iso1: 'es', iso2: 'spa', native: ['Español'],
      aliases: ['Latino', 'Castilian', 'Latinoamérica', 'Latin American']),
  Language(name: 'Arabic',     iso1: 'ar', iso2: 'ara', native: ['العربية']),
  Language(name: 'Hindi',      iso1: 'hi', iso2: 'hin', native: ['हिन्दी']),
  Language(name: 'French',     iso1: 'fr', iso2: 'fre', iso2t: 'fra',
      native: ['Français']),
  Language(name: 'German',     iso1: 'de', iso2: 'ger', iso2t: 'deu',
      native: ['Deutsch']),
  Language(name: 'Portuguese', iso1: 'pt', iso2: 'por', native: ['Português'],
      aliases: ['Brazilian', 'Brasil', 'Brazilian Portuguese']),
  Language(name: 'Italian',    iso1: 'it', iso2: 'ita', native: ['Italiano']),
  Language(name: 'Russian',    iso1: 'ru', iso2: 'rus', native: ['Русский']),
  Language(name: 'Japanese',   iso1: 'ja', iso2: 'jpn', native: ['日本語']),
  Language(name: 'Korean',     iso1: 'ko', iso2: 'kor', native: ['한국어']),
  Language(name: 'Chinese',    iso1: 'zh', iso2: 'chi', iso2t: 'zho',
      native: ['中文'],
      aliases: ['Simplified', 'Traditional', 'Mandarin', 'Cantonese']),
  Language(name: 'Turkish',    iso1: 'tr', iso2: 'tur', native: ['Türkçe']),
  Language(name: 'Indonesian', iso1: 'id', iso2: 'ind',
      native: ['Bahasa Indonesia']),
  Language(name: 'Dutch',      iso1: 'nl', iso2: 'dut', iso2t: 'nld',
      native: ['Nederlands']),
  Language(name: 'Polish',     iso1: 'pl', iso2: 'pol', native: ['Polski']),
  Language(name: 'Vietnamese', iso1: 'vi', iso2: 'vie',
      native: ['Tiếng Việt']),
  Language(name: 'Thai',       iso1: 'th', iso2: 'tha', native: ['ไทย']),
  Language(name: 'Tamil',      iso1: 'ta', iso2: 'tam', native: ['தமிழ்']),
  Language(name: 'Telugu',     iso1: 'te', iso2: 'tel', native: ['తెలుగు']),
  Language(name: 'Bengali',    iso1: 'bn', iso2: 'ben', native: ['বাংলা']),
  Language(name: 'Malayalam',  iso1: 'ml', iso2: 'mal', native: ['മലയാളം']),
  Language(name: 'Urdu',       iso1: 'ur', iso2: 'urd', native: ['اردو']),
  Language(name: 'Persian',    iso1: 'fa', iso2: 'per', iso2t: 'fas',
      native: ['فارسی'], aliases: ['Farsi']),
  Language(name: 'Greek',      iso1: 'el', iso2: 'gre', iso2t: 'ell',
      native: ['Ελληνικά']),
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
/// corresponds to [lang]. Tolerates English names, native names, ISO 639-1,
/// both ISO 639-2 variants, and regional aliases — as whole strings, as a
/// decorated name ("French (SDH)"), or as standalone tokens. Codes/names are
/// never matched as substrings, so short codes can't match inside an unrelated
/// word (e.g. "eng"/"en" must not match "Bengali").
bool matchesSourceLang(String sourceLang, Language lang) {
  final s = sourceLang.toLowerCase().trim();
  if (s.isEmpty) return false;

  final codes = <String>{lang.iso1, lang.iso2, lang.iso2t};
  final names = <String>[
    lang.name.toLowerCase(),
    ...lang.native.map((n) => n.toLowerCase()),
    ...lang.aliases.map((a) => a.toLowerCase()),
  ];

  // Whole-string match against any code or name.
  if (codes.contains(s) || names.contains(s)) return true;
  // Decorated-name match: the source string contains a full name/alias
  // ("english (sdh)", "brazilian portuguese"). Names only — never codes.
  for (final n in names) {
    if (n.length >= 3 && s.contains(n)) return true;
  }
  // Token match: a Latin code or name recognised only as a standalone word
  // ("pt-BR" → "pt"). Native/CJK/RTL names are handled by the whole-string and
  // contains checks above, so ASCII tokenisation here is sufficient.
  for (final token in s.split(RegExp(r'[^a-z0-9]+'))) {
    if (token.isEmpty) continue;
    if (codes.contains(token) || names.contains(token)) return true;
  }
  return false;
}

/// The first [kSubtitleLanguages] entry that [matchesSourceLang] for the
/// free-form [sourceLang] label, or null if none.
Language? languageOfSource(String sourceLang) {
  for (final lang in kSubtitleLanguages) {
    if (matchesSourceLang(sourceLang, lang)) return lang;
  }
  return null;
}

/// The first source subtitle whose [Subtitle.lang] or [Subtitle.label]
/// matches [lang], or null.
Subtitle? pickPreferredSub(List<Subtitle> subs, Language lang) {
  for (final s in subs) {
    if (matchesSourceLang(s.lang, lang)) return s;
    final label = s.label;
    if (label != null && matchesSourceLang(label, lang)) return s;
  }
  return null;
}
