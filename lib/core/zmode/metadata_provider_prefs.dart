import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';

/// Who supplies anime/manga metadata.
enum AnimeProvider { anilist, mal }

/// Which of AniList's titles to show.
///
/// AniList carries all three for every entry and its accounts have their own
/// preference, which we seed from on sign-in. Kept as our own setting rather
/// than leaning on the API's `userPreferred` field: that only honours the
/// account setting on AUTHENTICATED requests, so the browse rows (which are
/// public) would keep drifting back to romaji while the library obeyed it.
enum TitleLanguage { romaji, english, native }

/// Who supplies movie/TV metadata.
enum VideoProvider { tmdb, simkl }

/// A specific provider to prefer for one request, whatever the saved choice.
///
/// Opening a title from a tracker should read it from THAT tracker's own
/// catalogue: you are looking at your AniList library, so the page you land on
/// should be AniList's, even when MyAnimeList is the app-wide pick. A tracker
/// with no catalogue behind it (Trakt, say) simply has no value here and falls
/// back to the saved choice.
enum PreferredProvider { anilist, mal, tmdb, simkl }

/// The user's metadata provider choice, and nothing else — which provider is
/// actually answering right now is [MetadataRepository]'s business, since it
/// falls back on its own when the chosen one is unreachable.
class MetadataProviderPrefs {
  MetadataProviderPrefs._(this._box);
  final Box _box;

  static const String boxName = 'metadata_provider';
  static const String _kAnime = 'anime';
  static const String _kVideo = 'video';

  /// Bumped whenever the choice changes, so screens holding cached rows can
  /// reload without every one of them subscribing to Hive.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<MetadataProviderPrefs> open() async =>
      MetadataProviderPrefs._(await openBoxSafely(boxName));

  AnimeProvider get anime => _box.get(_kAnime) == AnimeProvider.mal.name
      ? AnimeProvider.mal
      : AnimeProvider.anilist;

  Future<void> setAnime(AnimeProvider p) async {
    if (p == anime) return;
    await _box.put(_kAnime, p.name);
    revision.value++;
  }

  VideoProvider get video => _box.get(_kVideo) == VideoProvider.simkl.name
      ? VideoProvider.simkl
      : VideoProvider.tmdb;

  Future<void> setVideo(VideoProvider p) async {
    if (p == video) return;
    await _box.put(_kVideo, p.name);
    revision.value++;
  }

  static const String _kTitleLang = 'titleLanguage';

  /// Romaji by default — AniList's own default, and what the browse rows
  /// always showed. The library used to disagree and show English.
  TitleLanguage get titleLanguage {
    final v = _box.get(_kTitleLang) as String?;
    return TitleLanguage.values.asNameMap()[v] ?? TitleLanguage.romaji;
  }

  /// Whether the user has ever chosen one. False means [seedTitleLanguage] may
  /// still adopt the AniList account's setting.
  bool get titleLanguageChosen => _box.get(_kTitleLang) != null;

  Future<void> setTitleLanguage(TitleLanguage l) async {
    if (titleLanguageChosen && l == titleLanguage) return;
    await _box.put(_kTitleLang, l.name);
    revision.value++;
  }

  /// Adopt the AniList account's own title language, but only when the user
  /// has never picked one here — signing in should fix the mismatch this
  /// setting exists for, and must never overwrite a deliberate choice.
  Future<void> seedTitleLanguage(TitleLanguage l) async {
    if (titleLanguageChosen) return;
    await setTitleLanguage(l);
  }
}
