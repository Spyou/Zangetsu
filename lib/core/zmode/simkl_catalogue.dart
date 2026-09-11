import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../environment.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/episode.dart';
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

  /// Pre-built trending lists, served off Cloudflare. Simkl asked us to read
  /// these instead of `/movies/trending/week` and friends: they carry the same
  /// titles, 100 at a time instead of 30, and they do NOT count against the
  /// app's request limit. No api key on these — just the standard params the
  /// Dio interceptor adds.
  static const String _files = 'https://data.simkl.in/discover/trending';

  /// One file is ~300 KB, so re-fetching all four on every Home build would
  /// cost a megabyte of somebody's mobile data. They regenerate daily, so an
  /// hour in memory is conservative and still spares the repeat loads within a
  /// session (mode switches, pull-to-refresh, coming back from a detail).
  static const Duration _fileTtl = Duration(hours: 1);
  final Map<String, (DateTime, List<dynamic>)> _fileCache = {};

  Future<List<dynamic>> _trending(String row) async {
    final hit = _fileCache[row];
    if (hit != null && DateTime.now().difference(hit.$1) < _fileTtl) {
      return hit.$2;
    }
    final res = await _dio.get<dynamic>(
      '$_files/$row.json',
      options: Options(validateStatus: (s) => s != null && s < 500),
    );
    final data = res.data;
    if (data is! List) return const [];
    _fileCache[row] = (DateTime.now(), data);
    return data;
  }

  /// The four files Simkl publishes for these, `<type>/<window>_100`. The old
  /// `/movies/trending/week` API calls these replace were the bulk of our
  /// daily quota — four of them on every Home build, from every install.
  ///
  /// The first row also feeds Home's hero banner rather than showing as a
  /// row, which is why this list is one longer than what you see.
  /// Row titles without a fetch — see [AniListCatalogue.rowTitles].
  static List<String> rowTitles() => [for (final r in _rows) r.$1];

  /// Posters in a Home rail. Not the file's length — that's 100, and a rail
  /// nobody scrolls to the end of doesn't need them.
  static const int _rowLength = 30;

  static const List<(String, String, bool)> _rows = [
    ('Trending movies', 'movies/week_100', false),
    ('Trending series', 'tv/week_100', true),
    ('Popular movies', 'movies/month_100', false),
    ('Popular series', 'tv/month_100', true),
  ];

  @override
  Future<List<HomeSection>> home() async {
    final sections = await Future.wait(
      _rows.map((row) async {
        final (title, path, isTv) = row;
        try {
          // The file holds 100; a Home rail shows the same 30 it always has.
          // The rest is See All's business, and it reads the deeper file.
          final items = _items(
            await _trending(path),
            isTv: isTv,
          ).take(_rowLength).toList();
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

  /// The file holds the whole list, so paging is a local slice — no second
  /// request, and no reliance on `page` being honoured (it never was
  /// documented). Running off the end returns empty, which is what the browse
  /// grid already treats as "that's all".
  @override
  Future<List<MediaItem>> browseRow(String rowId, int page) async {
    const perPage = 30;
    try {
      // See All swaps to the 500-item file. It's ~1.5 MB against the 300 KB
      // one Home uses, which is why Home doesn't load it — but someone who
      // opened the row is going to scroll, and this way the whole thing pages
      // locally instead of asking for more.
      final all = _items(
        await _trending(rowId.replaceFirst('_100', '_500')),
        isTv: rowId.startsWith('tv/'),
      );
      final from = (page - 1) * perPage;
      if (from >= all.length) return const [];
      return all.sublist(from, (from + perPage).clamp(0, all.length));
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
    // TMDB one. Free when the row or search result this was opened from
    // already handed us the Simkl id — which is the usual case.
    final simklId = await simklIdFor(
      _dio,
      int.tryParse(tmdbId) ?? -1,
      isTv: isTv,
    );
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
      // Synthesised from the count Simkl already returned in this same
      // payload — no extra request. This used to be a hard `const []`, so a
      // Simkl user with no source installed saw an empty episode list on
      // EVERY title. The matched source replaces this list when there is one
      // (see MetadataRepository.detail); this is what shows when there isn't.
      // Films keep the single synthetic episode the movie path uses.
      episodes: _episodesFor(map, c, isTv: isTv),
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

  /// TMDB id -> Simkl id, filled in from whatever we've already fetched.
  /// Rows and search results hand us both ids for free; [detail] would
  /// otherwise spend a `/search/id` call re-asking for one we were given a
  /// moment ago. Session-scoped — a cold start on a title from the user's own
  /// library still pays the lookup once.
  static final Map<int, int> _simklByTmdb = {};

  /// The Simkl id for a TMDB id — from whatever we've already fetched, or off
  /// the redirect endpoint when we haven't seen this one.
  ///
  /// `/redirect` is what Simkl points at for translating an external id: it
  /// answers 301 with the id in the `Location` header and no body at all,
  /// where `/search/id` returns a whole record we throw away. Don't follow the
  /// redirect — the header IS the answer.
  ///
  /// Static, and shared: the Cast/Relations enrichment runs on the same screen
  /// as the detail fetch, and both used to resolve the same title separately.
  static Future<int?> simklIdFor(
    Dio dio,
    int tmdbId, {
    required bool isTv,
  }) async {
    final known = _simklByTmdb[tmdbId];
    if (known != null) return known;
    try {
      final res = await dio.get<dynamic>(
        '$_api/redirect',
        queryParameters: {
          'to': 'simkl',
          'tmdb': '$tmdbId',
          // Without `type` a series id is searched against MOVIES and comes
          // back as a bare `//simkl.com` with no id — every show would fail
          // to open while films worked.
          'type': isTv ? 'tv' : 'movie',
        },
        options: Options(
          followRedirects: false,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      // `//simkl.com/movies/53894/fight-club` when found, bare `//simkl.com`
      // when not.
      final loc = res.headers.value('location') ?? '';
      final id = int.tryParse(
        RegExp(r'/(?:movies|tv|anime)/(\d+)').firstMatch(loc)?.group(1) ?? '',
      );
      if (id != null) _simklByTmdb[tmdbId] = id;
      return id;
    } catch (_) {
      return null;
    }
  }

  /// The map outlives any one catalogue instance on purpose — the enrichment
  /// shares it. That also means it survives between tests, where one test's
  /// id would silently satisfy the next one's lookup.
  @visibleForTesting
  static void resetIdCache() => _simklByTmdb.clear();

  /// Feed the map from anywhere that already holds both ids — the user's own
  /// synced lists carry them, and a title they track is exactly the one they
  /// are most likely to open. Accepts the raw value because Simkl hands these
  /// back as an int on some endpoints and a string on others.
  static void rememberSimklId(int tmdbId, Object? raw) {
    final id = raw is int ? raw : int.tryParse('${raw ?? ''}');
    if (id != null && id > 0) _simklByTmdb[tmdbId] = id;
  }

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
      // Every row already carries its Simkl id, so remember it — opening this
      // title later costs one call instead of two. `simkl_id` in the data
      // files and /search/*, `simkl` on the sync payloads; both spellings
      // appear, so read either.
      rememberSimklId(tmdbId, ids is Map ? (ids['simkl_id'] ?? ids['simkl']) : null);
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
          score: _score(row['ratings']),
        ),
      );
    }
    return out;
  }
  /// 1..total_episodes for a series, one entry for a film. Simkl exposes a
  /// real per-episode endpoint (`/tv/episodes/{id}`) with titles and seasons,
  /// but it costs a second round-trip for names the matched source overwrites
  /// a moment later — the COUNT is what stops the list reading as empty.
  static List<Episode> _episodesFor(
    Map<String, dynamic> m,
    ZCanonical c, {
    required bool isTv,
  }) {
    if (!isTv) {
      return [
        Episode(
          id: '1',
          title: m['title'] as String? ?? 'Movie',
          number: 1,
          url: ZmodeIds.episodeUrl(c, 1),
        ),
      ];
    }
    final n = (m['total_episodes'] as num?)?.toInt() ?? 0;
    if (n <= 0) return const [];
    return [
      for (var i = 1; i <= n; i++)
        Episode(
          id: '$i',
          title: 'Episode $i',
          number: i.toDouble(),
          url: ZmodeIds.episodeUrl(c, i),
        ),
    ];
  }

}
