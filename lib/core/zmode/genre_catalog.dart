import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import 'metadata_filters.dart';
import 'zmode_ids.dart';

/// AniList's own genre list, cached, with the built-in list as the floor.
///
/// The built-in list in [metaGenresFor] was hand-typed, which is exactly how
/// it came to be missing an entry AniList has always returned. AniList will
/// answer `{GenreCollection}` for free and without a token, so the honest
/// source is AniList — the hard-coded list stays as what to show before the
/// first fetch lands, offline, and on a provider that is not AniList at all.
///
/// Deliberately synchronous to read: every caller renders a list of chips and
/// must not wait on a network round trip to draw. [refresh] is the only async
/// part, and nothing depends on it having run.
class GenreCatalog {
  static const String boxName = 'genre_catalog';
  static const String _kGenres = 'anilist_genres';
  static const String _kFetchedAt = 'fetched_at';

  /// Re-asked about once a week. Genres change on the order of years, so this
  /// is about not pinning a bad or truncated answer forever, not freshness.
  static const Duration maxAge = Duration(days: 7);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  static Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// The cached list, or empty when nothing has been fetched yet.
  static List<String> get cached {
    final raw = _box?.get(_kGenres);
    if (raw is! List) return const [];
    return [for (final g in raw) '$g'];
  }

  static bool get isStale {
    final at = _box?.get(_kFetchedAt);
    if (at is! int) return true;
    final age = DateTime.now().millisecondsSinceEpoch - at;
    return age < 0 || age > maxAge.inMilliseconds;
  }

  /// Replace the cache. Ignores an empty answer: a provider hiccup must not
  /// wipe a good list and leave every genre screen on the fallback.
  static Future<void> save(List<String> genres) async {
    if (genres.isEmpty) return;
    final box = _box;
    if (box == null) return;
    await box.put(_kGenres, genres);
    await box.put(_kFetchedAt, DateTime.now().millisecondsSinceEpoch);
  }

  /// The genres to show for [kind].
  ///
  /// AniList's list covers anime, manga and novels — they share one genre
  /// vocabulary. Movie/TV come from TMDB, whose genres are a different set
  /// with their own ids, so those always use the built-in list.
  ///
  /// [adult] is applied here rather than by the caller because AniList's list
  /// contains [kAdultGenre] outright: dropping it is what keeps a fetched list
  /// obeying the same Privacy rule the hard-coded one does.
  static List<String> genresFor(ZKind kind, {bool adult = false}) {
    if (kind == ZKind.movie || kind == ZKind.tv) {
      return metaGenresFor(kind, adult: adult);
    }
    final live = cached;
    if (live.isEmpty) return metaGenresFor(kind, adult: adult);
    final out = [
      for (final g in live)
        if (adult || g != kAdultGenre) g,
    ]..sort();
    return out;
  }
}
