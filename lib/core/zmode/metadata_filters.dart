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
    this.year,
    this.season,
    this.format,
    this.status,
    this.sort = MetaSort.popularity,
    this.minScore,
  });

  /// Genre names as the provider spells them, e.g. `Action`. Translated to
  /// TMDB's numeric ids on the way out; AniList takes the names directly.
  final List<String> genres;
  final int? year;
  final MetaSeason? season;
  final MetaFormat? format;
  final MetaStatus? status;
  final MetaSort sort;

  /// 0-100. AniList compares on `averageScore`; TMDB on `vote_average`, which
  /// is out of 10, so it is divided on the way out.
  final int? minScore;

  /// Whether anything here would actually narrow a request. A search with
  /// nothing set must take the plain path, so an untouched sheet does not turn
  /// a search into a filtered browse.
  bool get isEmpty =>
      genres.isEmpty &&
      year == null &&
      season == null &&
      format == null &&
      status == null &&
      minScore == null &&
      sort == MetaSort.popularity;

  bool get isNotEmpty => !isEmpty;

  MetaFilters copyWith({
    List<String>? genres,
    int? year,
    MetaSeason? season,
    MetaFormat? format,
    MetaStatus? status,
    MetaSort? sort,
    int? minScore,
    bool clearYear = false,
    bool clearSeason = false,
    bool clearFormat = false,
    bool clearStatus = false,
    bool clearScore = false,
  }) => MetaFilters(
    genres: genres ?? this.genres,
    year: clearYear ? null : (year ?? this.year),
    season: clearSeason ? null : (season ?? this.season),
    format: clearFormat ? null : (format ?? this.format),
    status: clearStatus ? null : (status ?? this.status),
    sort: sort ?? this.sort,
    minScore: clearScore ? null : (minScore ?? this.minScore),
  );
}

enum MetaSeason { winter, spring, summer, fall }

enum MetaFormat { tv, movie, ova, special, manga, novel, oneShot }

enum MetaStatus { releasing, finished, notYetReleased, cancelled }

enum MetaSort { popularity, score, trending, newest, title }

/// The genres offered for [kind]. AniList's list is fixed and small, and the
/// TMDB ids below cover the same ground for movies and TV, so one picker
/// serves every provider that can filter.
List<String> metaGenresFor(ZKind kind) => switch (kind) {
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

/// The TMDB id for [genre], or null when that genre has no equivalent on this
/// side (Horror and Thriller are movie-only, for instance) — a null must drop
/// the genre rather than send a wrong id.
int? tmdbGenreId(String genre, {required bool isTv}) =>
    (isTv ? _tmdbTvGenres : _tmdbMovieGenres)[genre];
