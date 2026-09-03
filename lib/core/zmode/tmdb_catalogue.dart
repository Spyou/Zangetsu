import 'package:dio/dio.dart';

import '../metadata/tmdb.dart';
import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import 'video_catalogue.dart';
import 'metadata_filters.dart';
import 'zmode_ids.dart';

typedef TmdbGet =
    Future<Map<String, dynamic>?> Function(
      String path,
      Map<String, dynamic> params,
    );

/// TMDB as a browsing catalogue for films and series. `sl<Dio>()` already
/// attaches the API key, so paths are relative to [Tmdb.base].
class TmdbCatalogue implements VideoCatalogue {
  TmdbCatalogue(this._get);
  final TmdbGet _get;

  /// Production transport. Same shape as `ComingSoonService` — the API key
  /// is attached by the Dio interceptor wired in initDependencies, so this
  /// never adds one itself.
  static TmdbGet dioGet(Dio dio) => (path, params) async {
    try {
      final res = await dio.get<dynamic>(
        '${Tmdb.base}$path',
        queryParameters: params,
      );
      final d = res.data;
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return null;
  };

  static const _rows = [
    // What's out right now leads (and feeds the hero banner, which Home
    // repeats as a row); discovery rows follow, Trending first among them.
    ('Now playing', '/movie/now_playing'),
    // The series half of "what's out right now" — /movie/now_playing has no
    // /tv twin, and on_the_air is the closest param-free endpoint: shows with
    // an episode airing this week.
    ('Airing now', '/tv/on_the_air'),
    ('Trending', '/trending/all/week'),
    ('Popular movies', '/movie/popular'),
    ('Popular series', '/tv/popular'),
    ('Top rated', '/movie/top_rated'),
    ('Upcoming', '/movie/upcoming'),
  ];

  /// All rows fired concurrently — TMDB has no aliased multi-query like
  /// AniList, so this is the closest equivalent to one round-trip: the user
  /// waits for the slowest row, not the sum of all of them. `Future.wait`
  /// keeps the results in the same order as [_rows] regardless of which
  /// finishes first.
  Future<List<HomeSection>> home() async {
    final sections = await Future.wait(_rows.map(_fetchRow));
    return [for (final s in sections) ?s];
  }

  Future<HomeSection?> _fetchRow((String, String) row) async {
    final (title, path) = row;
    // List endpoints under /movie/* and /tv/* don't carry a `media_type`
    // field, so the endpoint itself says what it holds. Mixed endpoints
    // (/trending/all, /search/multi) do carry it, so let _items read it.
    final forcedTv = path.startsWith('/tv/')
        ? true
        : path.startsWith('/movie/')
        ? false
        : null;
    final items = _items(await _get(path, const {}), forcedTv: forcedTv);
    return items.isEmpty
        ? null
        // The endpoint path is the row's identity, and every TMDB list
        // endpoint takes ?page=, so paging is the same call one page along.
        : HomeSection(
            title: title,
            items: items,
            more: BrowseMore(
              sourceId: ZmodeIds.sourceId,
              kind: 'zm_video',
              categoryId: path,
            ),
          );
  }

  @override
  Future<List<MediaItem>> browseRow(String rowId, int page) async {
    final forcedTv = rowId.startsWith('/tv/')
        ? true
        : rowId.startsWith('/movie/')
        ? false
        : null;
    try {
      return _items(await _get(rowId, {'page': page}), forcedTv: forcedTv);
    } catch (_) {
      return const [];
    }
  }

  Future<List<MediaItem>> search(String q) async =>
      _items(await _get('/search/multi', {'query': q}), forcedTv: null);

  @override
  bool get supportsFilters => true;

  /// Filtering lives on `/discover`, which takes no query, while `/search`
  /// takes a query and no filters — TMDB genuinely has no endpoint that does
  /// both. So a filtered search runs /discover and narrows by title locally;
  /// a filtered browse (no query) is just /discover.
  @override
  Future<List<MediaItem>> searchFiltered(
    String q, {
    MetaFilters? filters,
    int page = 1,
  }) async {
    final f = filters;
    // Adult alone stays on /search: both endpoints take include_adult, but
    // only /search takes the query.
    if (f == null || !f.narrowsCatalogue) {
      return _items(
        await _get('/search/multi', {
          'query': q,
          'page': page,
          'include_adult': f?.adult ?? false,
        }),
        forcedTv: null,
      );
    }
    // One side at a time: /discover is per-media-type, and a TV request with a
    // movie-only genre id returns nothing rather than an error.
    final isTv = f.format == MetaFormat.tv;
    final ids = f.genres
        .map((g) => tmdbGenreId(g, isTv: isTv))
        .whereType<int>()
        .toSet();
    final params = <String, dynamic>{
      'page': page,
      'include_adult': f.adult,
      'sort_by': switch (f.sort) {
        MetaSort.score => 'vote_average.desc',
        MetaSort.newest =>
          isTv ? 'first_air_date.desc' : 'primary_release_date.desc',
        MetaSort.title => 'title.asc',
        _ => 'popularity.desc',
      },
      if (ids.isNotEmpty) 'with_genres': ids.join(','),
      if (f.year != null)
        (isTv ? 'first_air_date_year' : 'primary_release_year'): f.year,
      // Sorting by score with no vote floor surfaces titles with one 10/10
      // vote, which reads as broken rather than as a top-rated list.
      if (f.sort == MetaSort.score || f.minScore != null) 'vote_count.gte': 200,
      if (f.minScore != null) 'vote_average.gte': f.minScore! / 10,
    };
    final items = _items(
      await _get('/discover/${isTv ? 'tv' : 'movie'}', params),
      forcedTv: isTv,
    );
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return items;
    return items
        .where((i) => i.title.toLowerCase().contains(needle))
        .toList(growable: false);
  }

  Future<MediaDetail> detail(ZCanonical c) async {
    final isTv = c.kind == ZKind.tv;
    final id = c.id.split(':').last;
    final m = await _get(isTv ? '/tv/$id' : '/movie/$id', const {});
    if (m == null) throw StateError('TMDB returned nothing for $c');
    final date = (isTv ? m['first_air_date'] : m['release_date']) as String?;
    return MediaDetail(
      id: c.id,
      title: (isTv ? m['name'] : m['title']) as String? ?? '',
      cover: _poster(m['poster_path'] as String?),
      banner: _backdrop(m['backdrop_path'] as String?),
      url: ZmodeIds.showUrl(c),
      description: m['overview'] as String?,
      status: switch (m['status'] as String?) {
        'Returning Series' => MediaStatus.ongoing,
        'Ended' || 'Released' => MediaStatus.completed,
        'Canceled' => MediaStatus.cancelled,
        _ => MediaStatus.unknown,
      },
      genres: [
        for (final g in (m['genres'] as List? ?? const []))
          if (g is Map && g['name'] is String) g['name'] as String,
      ],
      episodes: isTv
          ? _tvEpisodes(m, c)
          : [
              Episode(
                id: '1',
                title: (m['title'] as String?) ?? 'Movie',
                number: 1,
                url: ZmodeIds.episodeUrl(c, 1),
              ),
            ],
      year: date != null && date.length >= 4 ? date.substring(0, 4) : null,
      type: ProviderType.movie,
      sourceId: ZmodeIds.sourceId,
      tmdbId: int.tryParse(id),
      // Out of 10 in the payload, out of 100 in the model.
      score: _score(m['vote_average']),
      // vote_count, not `popularity`: TMDB's popularity is an internal
      // trending float (55.6) that means nothing printed on a page.
      popularity: (m['vote_count'] as num?)?.toInt(),
      // A series reports per-episode run times as a list; a film reports one
      // number. Both end up as minutes.
      durationMins: _runtime(isTv ? m['episode_run_time'] : m['runtime']),
      country: _country(m['production_countries']),
      startDate: _isoDate(date),
      endDate: _isoDate(m['last_air_date'] as String?),
      nativeTitle: (isTv ? m['original_name'] : m['original_title']) as String?,
      isAdult: m['adult'] == true,
      tmdbIsTv: isTv,
    );
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  static int? _score(Object? v) {
    final d = (v as num?)?.toDouble();
    return d == null || d <= 0 ? null : (d * 10).round();
  }

  static int? _runtime(Object? v) {
    if (v is num && v > 0) return v.toInt();
    // episode_run_time is a list, often with more than one entry when a show
    // changed length. The first is the usual one.
    if (v is List && v.isNotEmpty && v.first is num && (v.first as num) > 0) {
      return (v.first as num).toInt();
    }
    return null;
  }

  static String? _country(Object? v) {
    if (v is! List || v.isEmpty) return null;
    final first = v.first;
    return (first is Map) ? first['iso_3166_1'] as String? : null;
  }

  /// A malformed date is worth dropping a row over, never a detail page.
  static DateTime? _isoDate(String? raw) =>
      (raw == null || raw.isEmpty) ? null : DateTime.tryParse(raw);

  static String? _poster(String? path) =>
      path == null ? null : '${Tmdb.img}/w500$path';

  /// Wide 16:9 art for the hero — TMDB's `backdrop_path`.
  static String? _backdrop(String? path) =>
      path == null ? null : '${Tmdb.img}/w780$path';

  /// [forcedTv]: list endpoints don't carry `media_type`, so the caller says
  /// (see [home]); null means read `media_type` off each result and skip
  /// anything that's neither `movie` nor `tv` (e.g. `person` from search).
  static List<MediaItem> _items(
    Map<String, dynamic>? data, {
    required bool? forcedTv,
  }) {
    final results = data?['results'];
    if (results is! List) return const [];
    final out = <MediaItem>[];
    for (final r in results) {
      if (r is! Map) continue;
      final m = Map<String, dynamic>.from(r);
      final mediaType = m['media_type'];
      if (forcedTv == null && mediaType != 'tv' && mediaType != 'movie') {
        continue;
      }
      final isTv = forcedTv ?? (mediaType == 'tv');
      final id = m['id'];
      if (id is! int) continue;
      final c = ZCanonical(isTv ? ZKind.tv : ZKind.movie, 'tmdb:$id');
      out.add(
        MediaItem(
          id: c.id,
          title: ((isTv ? m['name'] : m['title']) as String?) ?? '',
          cover: _poster(m['poster_path'] as String?),
          banner: _backdrop(m['backdrop_path'] as String?),
          url: ZmodeIds.showUrl(c),
          type: ProviderType.movie,
          sourceId: ZmodeIds.sourceId,
          tmdbId: id,
          tmdbIsTv: isTv,
        ),
      );
    }
    return out;
  }

  /// Seasons 1..n in order, episodes numbered continuously across them, so
  /// "episode 11" of a 10-episode-season show is S2E1. Specials (season 0)
  /// are skipped.
  static List<Episode> _tvEpisodes(Map<String, dynamic> m, ZCanonical c) {
    final seasons =
        (m['seasons'] as List? ?? const [])
            .whereType<Map>()
            .where((s) => (s['season_number'] as int? ?? 0) > 0)
            .toList()
          ..sort(
            (a, b) => (a['season_number'] as int).compareTo(
              b['season_number'] as int,
            ),
          );
    final out = <Episode>[];
    var n = 0;
    for (final s in seasons) {
      final count = s['episode_count'] as int? ?? 0;
      final season = s['season_number'] as int;
      for (var i = 1; i <= count; i++) {
        n++;
        out.add(
          Episode(
            id: '$n',
            title: 'S$season · E$i',
            number: n.toDouble(),
            url: ZmodeIds.episodeUrl(c, n),
            season: season,
          ),
        );
      }
    }
    return out;
  }
}
