import '../di/injector.dart';
import '../zmode/metadata_provider_prefs.dart';

/// Pick a title out of AniList's `title { romaji english native }` map.
///
/// One place, because the app used to decide this per file: the browse rows
/// took romaji, the library and search took english, and the same show read
/// differently depending on which row you were looking at.
///
/// [lang] is a preference, not a guarantee — AniList leaves `english` null on
/// plenty of entries. Falls back through the other two rather than showing
/// nothing, romaji first since it exists for everything.
String? aniListTitle(Object? titleMap, TitleLanguage lang) {
  if (titleMap is! Map) return null;
  String? at(String key) {
    final v = titleMap[key];
    return (v is String && v.isNotEmpty) ? v : null;
  }

  final wanted = switch (lang) {
    TitleLanguage.romaji => at('romaji'),
    TitleLanguage.english => at('english'),
    TitleLanguage.native => at('native'),
  };
  return wanted ?? at('romaji') ?? at('english') ?? at('native');
}

/// The variant to keep for source matching: whichever of romaji/english the
/// display title ISN'T. Sources index by both, so dropping one loses matches
/// (`MediaItem.englishTitle` is documented as exactly this alternative).
String? aniListAltTitle(Object? titleMap, String? shown) {
  if (titleMap is! Map) return null;
  for (final key in ['romaji', 'english']) {
    final v = titleMap[key];
    if (v is String && v.isNotEmpty && v != shown) return v;
  }
  return null;
}

/// The saved preference, or romaji when prefs aren't registered (widget tests
/// build screens with a minimal DI set; a title is not worth throwing over).
TitleLanguage get titleLanguagePref =>
    sl.isRegistered<MetadataProviderPrefs>()
    ? sl<MetadataProviderPrefs>().titleLanguage
    : TitleLanguage.romaji;
