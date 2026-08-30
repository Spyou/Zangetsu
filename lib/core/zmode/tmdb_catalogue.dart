import 'package:dio/dio.dart';

import '../metadata/tmdb.dart';
import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import 'zmode_ids.dart';

typedef TmdbGet =
    Future<Map<String, dynamic>?> Function(
      String path,
      Map<String, dynamic> params,
    );

/// TMDB as a browsing catalogue for films and series. `sl<Dio>()` already
/// attaches the API key, so paths are relative to [Tmdb.base].
class TmdbCatalogue {
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
    ('Trending', '/trending/all/week'),
    ('Popular movies', '/movie/popular'),
    ('Popular series', '/tv/popular'),
    ('Top rated', '/movie/top_rated'),
  ];

  Future<List<HomeSection>> home() async {
    final out = <HomeSection>[];
    for (final (title, path) in _rows) {
      // List endpoints under /movie/* and /tv/* don't carry a `media_type`
      // field, so the endpoint itself says what it holds. Mixed endpoints
      // (/trending/all, /search/multi) do carry it, so let _items read it.
      final forcedTv = path.startsWith('/tv/')
          ? true
          : path.startsWith('/movie/')
              ? false
              : null;
      final items = _items(await _get(path, const {}), forcedTv: forcedTv);
      if (items.isNotEmpty) out.add(HomeSection(title: title, items: items));
    }
    return out;
  }

  Future<List<MediaItem>> search(String q) async =>
      _items(await _get('/search/multi', {'query': q}), forcedTv: null);

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
      tmdbIsTv: isTv,
    );
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  static String? _poster(String? path) =>
      path == null ? null : '${Tmdb.img}/w500$path';

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
      out.add(MediaItem(
        id: c.id,
        title: ((isTv ? m['name'] : m['title']) as String?) ?? '',
        cover: _poster(m['poster_path'] as String?),
        url: ZmodeIds.showUrl(c),
        type: ProviderType.movie,
        sourceId: ZmodeIds.sourceId,
        tmdbId: id,
        tmdbIsTv: isTv,
      ));
    }
    return out;
  }

  /// Seasons 1..n in order, episodes numbered continuously across them, so
  /// "episode 11" of a 10-episode-season show is S2E1. Specials (season 0)
  /// are skipped.
  static List<Episode> _tvEpisodes(Map<String, dynamic> m, ZCanonical c) {
    final seasons = (m['seasons'] as List? ?? const [])
        .whereType<Map>()
        .where((s) => (s['season_number'] as int? ?? 0) > 0)
        .toList()
      ..sort((a, b) =>
          (a['season_number'] as int).compareTo(b['season_number'] as int));
    final out = <Episode>[];
    var n = 0;
    for (final s in seasons) {
      final count = s['episode_count'] as int? ?? 0;
      final season = s['season_number'] as int;
      for (var i = 1; i <= count; i++) {
        n++;
        out.add(Episode(
          id: '$n',
          title: 'S$season · E$i',
          number: n.toDouble(),
          url: ZmodeIds.episodeUrl(c, n),
          season: season,
        ));
      }
    }
    return out;
  }
}
