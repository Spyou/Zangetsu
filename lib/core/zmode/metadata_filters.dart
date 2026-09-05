import 'dart:convert';

import 'zmode_ids.dart';

/// Filters for a metadata-provider search or browse.
///
/// Only AniList (anime/manga) and TMDB (movies/TV) apply these. MAL and Simkl
/// accept the parameters and return unfiltered results — verified against both
/// APIs — so the UI must not offer filters while one of those is the active
/// provider rather than showing results that only look filtered.
class MetaFilters {
  const MetaFilters({
    this.genres = const [],
    this.tags = const [],
    this.year,
    this.season,
    this.format,
    this.status,
    this.sort = MetaSort.popularity,
    this.minScore,
    this.adult = false,
  });

  /// Genre names as the provider spells them, e.g. `Action`. Translated to
  /// TMDB's numeric ids on the way out; AniList takes the names directly.
  final List<String> genres;

  /// AniList tags — finer than a genre ("Time Skip" against "Action"), and
  /// AniList's alone. Nothing else exposes them, so a tag chip is only
  /// offered while AniList is the one answering.
  final List<String> tags;
  final int? year;
  final MetaSeason? season;
  final MetaFormat? format;
  final MetaStatus? status;
  final MetaSort sort;

  /// 0-100. AniList compares on `averageScore`; TMDB on `vote_average`, which
  /// is out of 10, so it is divided on the way out.
  final int? minScore;

  /// Include adult (18+) titles. Only reachable when the Privacy switch is on,
  /// and re-checked there before any request — see [PlaybackPrefs.adultMetadata].
  final bool adult;

  /// Whether anything here would actually narrow a request. A search with
  /// nothing set must take the plain path, so an untouched sheet does not turn
  /// a search into a filtered browse.
  bool get isEmpty =>
      genres.isEmpty &&
      tags.isEmpty &&
      year == null &&
      season == null &&
      format == null &&
      status == null &&
      minScore == null &&
      !adult &&
      sort == MetaSort.popularity;

  bool get isNotEmpty => !isEmpty;

  /// Whether anything here narrows the CATALOGUE, ignoring [adult].
  ///
  /// Adult is a visibility flag, not a query. TMDB serves filters from
  /// /discover, which takes no query at all, so counting "NSFW on" as a filter
  /// sent a plain text search down the discover path — where the query is
  /// dropped and the title match is done locally against popular titles, which
  /// finds almost nothing.
  bool get narrowsCatalogue =>
      genres.isNotEmpty ||
      tags.isNotEmpty ||
      year != null ||
      season != null ||
      format != null ||
      status != null ||
      minScore != null ||
      sort != MetaSort.popularity;

  MetaFilters copyWith({
    List<String>? genres,
    List<String>? tags,
    int? year,
    MetaSeason? season,
    MetaFormat? format,
    MetaStatus? status,
    MetaSort? sort,
    int? minScore,
    bool? adult,
    bool clearYear = false,
    bool clearSeason = false,
    bool clearFormat = false,
    bool clearStatus = false,
    bool clearScore = false,
  }) => MetaFilters(
    genres: genres ?? this.genres,
    tags: tags ?? this.tags,
    year: clearYear ? null : (year ?? this.year),
    season: clearSeason ? null : (season ?? this.season),
    format: clearFormat ? null : (format ?? this.format),
    status: clearStatus ? null : (status ?? this.status),
    sort: sort ?? this.sort,
    minScore: clearScore ? null : (minScore ?? this.minScore),
    adult: adult ?? this.adult,
  );

  /// Encoded for [HomeSection]-style plumbing: the search bloc already carries
  /// an opaque per-source filter string, so riding that instead of adding a
  /// parallel channel keeps one path for "filters were applied".
  String toJson() => jsonEncode({
    if (genres.isNotEmpty) 'g': genres,
    if (tags.isNotEmpty) 't': tags,
    if (year != null) 'y': year,
    if (season != null) 's': season!.name,
    if (format != null) 'f': format!.name,
    if (status != null) 'st': status!.name,
    if (minScore != null) 'ms': minScore,
    if (adult) 'a': true,
    'so': sort.name,
  });

  static MetaFilters? fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      T? pick<T extends Enum>(List<T> values, String? name) =>
          name == null ? null : values.where((v) => v.name == name).firstOrNull;
      return MetaFilters(
        genres: [...?(m['g'] as List?)?.cast<String>()],
        tags: [...?(m['t'] as List?)?.cast<String>()],
        year: m['y'] as int?,
        season: pick(MetaSeason.values, m['s'] as String?),
        format: pick(MetaFormat.values, m['f'] as String?),
        status: pick(MetaStatus.values, m['st'] as String?),
        minScore: m['ms'] as int?,
        adult: m['a'] == true,
        sort: pick(MetaSort.values, m['so'] as String?) ?? MetaSort.popularity,
      );
    } catch (_) {
      // A malformed string means an unfiltered search, never a crash.
      return null;
    }
  }
}

enum MetaSeason { winter, spring, summer, fall }

enum MetaFormat { tv, movie, ova, special, manga, novel, oneShot }

enum MetaStatus { releasing, finished, notYetReleased, cancelled }

enum MetaSort { popularity, score, trending, newest, title }

/// The genres offered for [kind]. AniList's list is fixed and small, and the
/// TMDB ids below cover the same ground for movies and TV, so one picker
/// serves every provider that can filter.
/// AniList's adult genre. Kept out of [metaGenresFor] unless asked for: it is
/// a real genre on every anime/manga/novel query, but offering it while the
/// Privacy switch is off would show a tile that can only ever come back empty
/// (the catalogue sends `isAdult:false`, so nothing in it can match).
const String kAdultGenre = 'Hentai';

/// The genres offered for [kind], plus [kAdultGenre] when [adult] is on.
///
/// [adult] is the caller's read of `PlaybackPrefs.adultMetadata`; the
/// repository re-checks the same switch before any request, so passing true
/// here can widen what is OFFERED but never what is returned.
List<String> metaGenresFor(ZKind kind, {bool adult = false}) {
  final base = _metaGenresFor(kind);
  if (!adult || kind == ZKind.movie || kind == ZKind.tv) return base;
  // Inserted where it sorts, not appended. These lists are alphabetical, and
  // one entry stuck on the end reads as a bolted-on afterthought — you go
  // looking under H and it is at the bottom of the grid.
  final out = [...base];
  final at = out.indexWhere((g) => g.compareTo(kAdultGenre) > 0);
  out.insert(at < 0 ? out.length : at, kAdultGenre);
  return out;
}

List<String> _metaGenresFor(ZKind kind) => switch (kind) {
  ZKind.anime || ZKind.manga || ZKind.novel => const [
    'Action',
    'Adventure',
    'Comedy',
    'Drama',
    'Ecchi',
    'Fantasy',
    'Horror',
    'Mahou Shoujo',
    'Mecha',
    'Music',
    'Mystery',
    'Psychological',
    'Romance',
    'Sci-Fi',
    'Slice of Life',
    'Sports',
    'Supernatural',
    'Thriller',
  ],
  ZKind.movie || ZKind.tv => const [
    'Action',
    'Adventure',
    'Animation',
    'Comedy',
    'Crime',
    'Documentary',
    'Drama',
    'Family',
    'Fantasy',
    'History',
    'Horror',
    'Music',
    'Mystery',
    'Romance',
    'Science Fiction',
    'Thriller',
    'War',
    'Western',
  ],
};

/// TMDB genre ids, which `/discover` takes instead of names. Movie and TV
/// share most ids; the ones that differ are handled by [tmdbGenreId].
const Map<String, int> _tmdbMovieGenres = {
  'Action': 28,
  'Adventure': 12,
  'Animation': 16,
  'Comedy': 35,
  'Crime': 80,
  'Documentary': 99,
  'Drama': 18,
  'Family': 10751,
  'Fantasy': 14,
  'History': 36,
  'Horror': 27,
  'Music': 10402,
  'Mystery': 9648,
  'Romance': 10749,
  'Science Fiction': 878,
  'Thriller': 53,
  'War': 10752,
  'Western': 37,
};

/// TV uses its own ids for the genres that exist at all on the TV side.
const Map<String, int> _tmdbTvGenres = {
  'Action': 10759,
  'Adventure': 10759,
  'Animation': 16,
  'Comedy': 35,
  'Crime': 80,
  'Documentary': 99,
  'Drama': 18,
  'Family': 10751,
  'Fantasy': 10765,
  'History': 36,
  'Mystery': 9648,
  'Science Fiction': 10765,
  'War': 10768,
  'Western': 37,
};

/// The genre names behind TMDB's `genre_ids`, which is all a list response
/// carries — full `genres` objects only come back on a detail fetch.
///
/// Without this every movie/TV item reached the app with no genres at all, so
/// anything keyed on them (the genre tiles' artwork) had nothing to match and
/// silently fell back. Ids that map to more than one name (TV folds Adventure
/// into Action, and Science Fiction into Fantasy) yield each of them; ids with
/// no entry are dropped rather than guessed.
List<String> tmdbGenreNames(List<dynamic> ids, {required bool isTv}) {
  final table = isTv ? _tmdbTvGenres : _tmdbMovieGenres;
  final out = <String>[];
  for (final raw in ids) {
    final id = raw is int ? raw : int.tryParse('$raw');
    if (id == null) continue;
    for (final e in table.entries) {
      if (e.value == id && !out.contains(e.key)) out.add(e.key);
    }
  }
  return out;
}

/// The TMDB id for [genre], or null when that genre has no equivalent on this
/// side (Horror and Thriller are movie-only, for instance) — a null must drop
/// the genre rather than send a wrong id.
int? tmdbGenreId(String genre, {required bool isTv}) =>
    (isTv ? _tmdbTvGenres : _tmdbMovieGenres)[genre];
