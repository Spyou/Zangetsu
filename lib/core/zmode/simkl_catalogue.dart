import 'package:dio/dio.dart';

import '../environment.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import 'video_catalogue.dart';
import 'metadata_filters.dart';
import 'zmode_ids.dart';

/// Movie/TV metadata from Simkl, as a stand-in for TMDB.
///
/// Reads use `simkl-api-key` (our client id) only — no user login, so this
/// works for everyone. Signing in to the Simkl tracker is still only about
/// YOUR lists.
///
/// Ids stay `tmdb:<n>`: Simkl carries a TMDB id on nearly everything, so a
/// title saved while TMDB was the provider resolves here unchanged and the
/// two are genuinely interchangeable. The cost is that opening a detail takes
/// two calls — tmdb id to Simkl id, then the record — because Simkl's own
/// endpoints are keyed by its id.
class SimklCatalogue implements VideoCatalogue {
  SimklCatalogue(this._dio);
  final Dio _dio;

  static const String _api = 'https://api.simkl.com';

  /// `extended=title` is what actually returns titles. `extended=full` does
  /// NOT include one — it returns ratings/runtime/country and no name at all,
  /// which is a silent way to render a row of blank cards.
  static const String _listExtended = 'title,tmdb';

  Future<Response<dynamic>> _get(String path, Map<String, dynamic> q) =>
      _dio.get<dynamic>(
        '$_api$path',
        queryParameters: q,
        options: Options(
          headers: {'simkl-api-key': Environment.simklClientId},
          validateStatus: (s) => s != null && s < 500,
        ),
      );

  /// Verified endpoints only, and verified to return USABLE rows — a 200 is
  /// not enough on its own:
  ///  - `/movies/best` does not exist (404).
  ///  - `/tv/best/month` answers 200 with 60 titles and ZERO tmdb ids, so
  ///    every row is dropped by [_items] and the section renders empty. It is
  ///    left out rather than shipped as a row that can never appear.
  ///
  /// The first row also feeds Home's hero banner rather than showing as a
  /// row, which is why this list is one longer than what you see.
  static const List<(String, String, bool)> _rows = [
    ('Trending movies', '/movies/trending/week', false),
    ('Trending series', '/tv/trending/week', true),
    ('Popular movies', '/movies/trending/month', false),
    ('Popular series', '/tv/trending/month', true),
  ];

  @override
  Future<List<HomeSection>> home() async {
    final sections = await Future.wait(
      _rows.map((row) async {
        final (title, path, isTv) = row;
        try {
          final res = await _get(path, {
            'extended': _listExtended,
            'limit': 30,
          });
          final items = _items(res.data, isTv: isTv);
          return items.isEmpty
              ? null
              : HomeSection(
                  title: title,
                  items: items,
                  more: BrowseMore(
                    sourceId: ZmodeIds.sourceId,
                    kind: 'zm_video',
                    categoryId: path,
                  ),
                );
        } catch (_) {
          return null;
        }
      }),
    );
    return [
      for (final s in sections)
        if (s != null) s,
    ];
  }

  /// Their docs do not commit to `page` on the trending endpoints, but it works
  /// — verified on device. The safety net stays anyway: the browse grid stops
  /// on an empty page OR on one whose items it already has, so if this ever
  /// starts being ignored the list ends instead of repeating forever.
  @override
  Future<List<MediaItem>> browseRow(String rowId, int page) async {
    try {
      final res = await _get(rowId, {
        'extended': _listExtended,
        'limit': 30,
        'page': page,
      });
      return _items(res.data, isTv: rowId.startsWith('/tv/'));
    } catch (_) {
      return const [];
    }
  }

  /// Simkl ignores filter parameters the way MAL does — `genre=action` on a
  /// trending endpoint returns byte-identical results. So filters are dropped
  /// here rather than faked, and [supportsFilters] keeps the UI from offering
  /// them while Simkl is the provider.
  @override
  bool get supportsFilters => false;

  @override
  Future<List<MediaItem>> searchFiltered(
    String q, {
    MetaFilters? filters,
    int page = 1,
  }) async => q.trim().isEmpty ? const [] : search(q);

  /// Simkl keeps movies and shows in separate catalogues, so a single query is
  /// two calls; results are interleaved movies-first the way TMDB's mixed
  /// `/search/multi` comes back.
  @override
  Future<List<MediaItem>> search(String q) async {
    final res = await Future.wait([
      _get('/search/movie', {'q': q, 'extended': _listExtended, 'limit': 20})
          .then<List<MediaItem>>((r) => _items(r.data, isTv: false))
          .catchError((_) => <MediaItem>[]),
      _get('/search/tv', {'q': q, 'extended': _listExtended, 'limit': 20})
          .then<List<MediaItem>>((r) => _items(r.data, isTv: true))
          .catchError((_) => <MediaItem>[]),
    ]);
    return [...res[0], ...res[1]];
  }

  @override
  Future<MediaDetail> detail(ZCanonical c) async {
    final tmdbId = _tmdbIdOf(c);
    final isTv = c.kind == ZKind.tv;

    // Hop 1: Simkl's records are keyed by its own id, and all we hold is a
    // TMDB one.
    // `type` is required, not optional: /search/id searches MOVIES by default,
    // so a series id came back empty and every show failed to open while
    // films were fine. Simkl keeps movies and shows in separate catalogues —
    // the same split that makes search two calls.
    final lookup = await _get('/search/id', {
      'tmdb': tmdbId,
      'type': isTv ? 'show' : 'movie',
    });
    final first = (lookup.data is List && (lookup.data as List).isNotEmpty)
        ? (lookup.data as List).first
        : null;
    // `simkl` here, NOT `simkl_id`: Simkl spells this key both ways depending
    // on the endpoint, and /search/id answers with `simkl`. Reading the wrong
    // one made every lookup null, so detail threw for every title and the
    // provider looked broken while quietly falling back to TMDB. Accept both,
    // since the other spelling is what /search/* returns elsewhere.
    final ids = first is Map ? first['ids'] : null;
    final simklId = ids is Map ? (ids['simkl'] ?? ids['simkl_id']) : null;
    if (simklId == null) {
      throw StateError('Simkl has no record for ${c.id}');
    }

    // Hop 2: the record itself.
    final res = await _get('/${isTv ? 'tv' : 'movies'}/$simklId', {
      'extended': 'full',
    });
    final m = res.data;
    if (m is! Map) throw StateError('Simkl returned no media for $c');
    final map = Map<String, dynamic>.from(m);
    return MediaDetail(
      id: c.id,
      title: map['title'] as String? ?? '',
      cover: _poster(map['poster'] as String?),
      banner: _fanart(map['fanart'] as String?),
      url: ZmodeIds.showUrl(c),
      description: map['overview'] as String?,
      genres: [for (final g in (map['genres'] as List? ?? const [])) '$g'],
      // Simkl exposes a director, not studios; close enough to the same line
      // on the Detail screen and better than leaving it blank.
      studios: [
        if (map['director'] is String && (map['director'] as String).isNotEmpty)
          map['director'] as String,
      ],
      episodes: const [],
      year: map['year']?.toString(),
      type: ProviderType.movie,
      sourceId: ZmodeIds.sourceId,
      tmdbId: int.tryParse(tmdbId),
      // Selects TMDB's movie vs tv namespace for tracking. Without it every
      // series scrobbles as a film — TmdbCatalogue has always set this, and a
      // provider that stands in for it has to as well.
      tmdbIsTv: isTv,
      // Simkl's own 0-10 rating, on the model's 0-100 scale. IMDb's sits
      // beside it in the payload; the provider you picked should be the one
      // answering, so its own number is the one shown.
      score: _score(map['ratings']),
      popularity: _votes(map['ratings']),
      durationMins: (map['runtime'] as num?)?.toInt(),
      country: map['country'] as String?,
      startDate: _isoDate(map['first_aired'] as String?),
      endDate: _isoDate(map['last_aired'] as String?),
      synonyms: [
        for (final t in (map['alt_titles'] as List? ?? const []))
          if (t is Map && t['name'] is String)
            t['name'] as String
          else if (t is String)
            t,
      ],
    );
  }

  static int? _score(Object? ratings) {
    final simkl = (ratings is Map) ? ratings['simkl'] : null;
    final v = (simkl is Map) ? (simkl['rating'] as num?)?.toDouble() : null;
    return v == null || v <= 0 ? null : (v * 10).round();
  }

  static int? _votes(Object? ratings) {
    final simkl = (ratings is Map) ? ratings['simkl'] : null;
    return (simkl is Map) ? (simkl['votes'] as num?)?.toInt() : null;
  }

  /// `2008-01-21T02:00:00Z`. Parsed leniently: a malformed date is worth
  /// dropping a row over, never throwing a detail page away.
  static DateTime? _isoDate(String? raw) =>
      (raw == null || raw.isEmpty) ? null : DateTime.tryParse(raw);

  // ── helpers ──────────────────────────────────────────────────────────────

  static String _tmdbIdOf(ZCanonical c) {
    if (!c.id.startsWith('tmdb:')) {
      throw StateError('Simkl cannot resolve ${c.id}');
    }
    return c.id.split(':').last;
  }

  /// Simkl serves art off its own CDN by path, the same shape the release
  /// calendar uses (see `parseSimklCalendar`).
  static String? _poster(String? p) =>
      (p == null || p.isEmpty) ? null : 'https://simkl.in/posters/${p}_m.jpg';

  static String? _fanart(String? p) => (p == null || p.isEmpty)
      ? null
      : 'https://simkl.in/fanart/${p}_medium.jpg';

  /// Rows without a TMDB id are dropped: Detail is keyed `tmdb:<n>`, so one
  /// would render as a card that opens nothing.
  static List<MediaItem> _items(dynamic data, {required bool isTv}) {
    if (data is! List) return const [];
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final row in data) {
      if (row is! Map) continue;
      final ids = row['ids'];
      final tmdbRaw = ids is Map ? ids['tmdb'] : null;
      final tmdbId = tmdbRaw is int
          ? tmdbRaw
          : int.tryParse('${tmdbRaw ?? ''}');
      if (tmdbId == null) continue;
      final title = (row['title'] as String? ?? '').trim();
      if (title.isEmpty) continue;
      final c = ZCanonical(isTv ? ZKind.tv : ZKind.movie, 'tmdb:$tmdbId');
      if (!seen.add(c.id)) continue;
      out.add(
        MediaItem(
          id: c.id,
          title: title,
          cover: _poster(row['poster'] as String?),
          banner: _fanart(row['fanart'] as String?),
          url: ZmodeIds.showUrl(c),
          type: ProviderType.movie,
          sourceId: ZmodeIds.sourceId,
          tmdbId: tmdbId,
          tmdbIsTv: isTv,
        ),
      );
    }
    return out;
  }
}
