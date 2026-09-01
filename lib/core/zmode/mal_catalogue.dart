import 'package:dio/dio.dart';

import '../environment.dart';
import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import 'anime_catalogue.dart';
import 'metadata_filters.dart';
import 'zmode_ids.dart';

/// Anime/manga metadata from MyAnimeList, as a stand-in for AniList.
///
/// Reads are made with `X-MAL-CLIENT-ID` only — MAL v2 serves public data on
/// that alone, so browsing works with nobody signed in. A user token is only
/// needed for THEIR lists, which is why switching to MAL prompts a login for
/// list features and nothing else.
///
/// Ids stay the app's canonical `mal:<n>`, which is what AniList already
/// stamps whenever a title has a MAL id (see `AniListCatalogue._canonical`) —
/// so a title saved while AniList was up resolves here unchanged. An `al:<n>`
/// id has no MAL equivalent and is rejected rather than guessed at.
class MalCatalogue implements AnimeCatalogue {
  MalCatalogue(this._dio);
  final Dio _dio;

  static const String _api = 'https://api.myanimelist.net/v2';

  /// Everything the list/detail builders below read. MAL returns only the
  /// fields you ask for, so this list IS the schema.
  static const String _listFields =
      'id,title,main_picture,alternative_titles,num_episodes,status,genres,'
      'start_season,mean';
  static const String _detailFields =
      '$_listFields,synopsis,studios,media_type,num_chapters';

  Future<Response<dynamic>> _get(String path, Map<String, dynamic> q) =>
      _dio.get<dynamic>(
        '$_api$path',
        queryParameters: q,
        options: Options(
          headers: {'X-MAL-CLIENT-ID': Environment.malClientId},
          // MAL answers 404 for an unknown id; let the callers below decide,
          // rather than Dio throwing before we can say what went wrong.
          validateStatus: (s) => s != null && s < 500,
        ),
      );

  static ProviderType _providerType(ZKind k) => switch (k) {
    ZKind.manga => ProviderType.manga,
    ZKind.novel => ProviderType.novel,
    _ => ProviderType.anime,
  };

  /// MAL splits anime and manga across different paths and ranking types.
  static String _path(ZKind k) => k == ZKind.anime ? 'anime' : 'manga';

  /// The home rows, as (title, ranking_type). Deliberately close to the
  /// AniList set so switching provider changes the data, not the shape of the
  /// screen. MAL has no "trending" or per-season ranking, so `airing`/`upcoming`
  /// stand in for the seasonal rows.
  static List<(String, String)> _rows(ZKind k) => k == ZKind.anime
      ? const [
          ('Trending', 'airing'),
          ('Popular this season', 'airing'),
          ('Upcoming next season', 'upcoming'),
          ('All-time popular', 'bypopularity'),
          ('Top rated', 'all'),
          ('Most favorited', 'favorite'),
        ]
      : const [
          ('Trending', 'bypopularity'),
          ('Popular', 'bypopularity'),
          ('Top rated', 'all'),
        ];

  /// One request per row — MAL has no aliasing, so this is N calls where
  /// AniList makes one. They run together; a row that fails is dropped rather
  /// than failing the screen.
  Future<List<HomeSection>> home(ZKind kind) async {
    final rows = _rows(kind);
    final results = await Future.wait([
      for (final (_, rankingType) in rows)
        _get('/${_path(kind)}/ranking', {
          'ranking_type': rankingType,
          'limit': 30,
          'fields': _listFields,
        }).then<List<MediaItem>>((r) => _items(r.data, kind)).catchError(
              (_) => <MediaItem>[],
            ),
    ]);
    final out = <HomeSection>[];
    for (final (i, (title, rankingType)) in rows.indexed) {
      if (results[i].isNotEmpty) {
        out.add(HomeSection(
          title: title,
          items: results[i],
          more: BrowseMore(
            sourceId: ZmodeIds.sourceId,
            kind: 'zm_${kind.name}',
            categoryId: rankingType,
          ),
        ));
      }
    }
    return out;
  }

  @override
  Future<List<MediaItem>> browseRow(ZKind kind, String rowId, int page) async {
    // MAL pages by offset rather than page number, and page 1 is what home()
    // already showed.
    const limit = 30;
    try {
      final r = await _get('/${_path(kind)}/ranking', {
        'ranking_type': rowId,
        'limit': limit,
        'offset': (page - 1) * limit,
        'fields': _listFields,
      });
      return _items(r.data, kind);
    } catch (_) {
      return const [];
    }
  }

  /// MAL v2 has no server-side filtering: `genres=26` alongside `q=naruto`
  /// returns Naruto titles with no such genre and no error. So this ignores
  /// [filters] rather than pretending, and [supportsFilters] tells the UI not
  /// to offer them while MAL is the provider.
  @override
  bool get supportsFilters => false;

  @override
  Future<List<MediaItem>> searchFiltered(
    String q,
    ZKind kind, {
    MetaFilters? filters,
    int page = 1,
  }) async {
    const limit = 20;
    if (q.trim().isEmpty) return const [];
    try {
      final res = await _get('/${_path(kind)}', {
        'q': q,
        'limit': limit,
        'offset': (page - 1) * limit,
        'fields': _listFields,
      });
      return _items(res.data, kind);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<MediaItem>> search(String q, ZKind kind) async {
    final res = await _get('/${_path(kind)}', {
      'q': q,
      'limit': 20,
      'fields': _listFields,
    });
    return _items(res.data, kind);
  }

  Future<MediaDetail> detail(ZCanonical c) async {
    final id = _malIdOf(c);
    final res = await _get('/${_path(c.kind)}/$id', {'fields': _detailFields});
    final m = res.data;
    if (m is! Map) throw StateError('MAL returned no media for $c');
    final map = Map<String, dynamic>.from(m);
    final titles = map['alternative_titles'] as Map? ?? const {};
    return MediaDetail(
      id: c.id,
      title: map['title'] as String? ?? '',
      englishTitle: (titles['en'] as String?)?.trim().isNotEmpty == true
          ? titles['en'] as String
          : null,
      cover: _picture(map, large: true),
      // MAL has no banner art at all; the Detail hero falls back to the cover.
      banner: null,
      url: ZmodeIds.showUrl(c),
      description: map['synopsis'] as String?,
      status: _status(map['status'] as String?),
      genres: [
        for (final g in (map['genres'] as List? ?? const []))
          if (g is Map && g['name'] is String) g['name'] as String,
      ],
      studios: [
        for (final s in (map['studios'] as List? ?? const []))
          if (s is Map && s['name'] is String) s['name'] as String,
      ],
      episodes: _episodesFor(map, c),
      year: (map['start_season'] as Map?)?['year']?.toString(),
      type: _providerType(c.kind),
      sourceId: ZmodeIds.sourceId,
      malId: int.tryParse(id),
    );
  }

  Future<List<Episode>> episodes(ZCanonical c) async =>
      (await detail(c)).episodes;

  // ── helpers ──────────────────────────────────────────────────────────────

  /// The numeric MAL id, or a throw for an `al:` id. AniList only issues those
  /// for titles it has no MAL id for, so there is nothing to look up here —
  /// better to fail loudly than to fetch some other show.
  static String _malIdOf(ZCanonical c) {
    if (!c.id.startsWith('mal:')) {
      throw StateError('MAL cannot resolve ${c.id} (AniList-only id)');
    }
    return c.id.split(':').last;
  }

  static String? _picture(Map<String, dynamic> m, {bool large = false}) {
    final p = m['main_picture'] as Map?;
    if (p == null) return null;
    return ((large ? p['large'] : null) ?? p['medium'] ?? p['large']) as String?;
  }

  /// MAL's `status` strings mapped onto the app's own vocabulary. Anime and
  /// manga use different words for the same states. MAL has no hiatus or
  /// cancelled, and the enum has no "upcoming" — not-yet-aired lands on
  /// unknown, which is exactly where AniList's NOT_YET_RELEASED lands too.
  static MediaStatus _status(String? s) => switch (s) {
    'currently_airing' || 'currently_publishing' => MediaStatus.ongoing,
    'finished_airing' || 'finished' => MediaStatus.completed,
    _ => MediaStatus.unknown,
  };

  /// Same synthesis AniList uses: 1..count, because neither provider exposes a
  /// real episode list. A count of 0 means "unknown/still airing" on MAL, and
  /// an empty list lets the matched source supply the episodes instead.
  static List<Episode> _episodesFor(Map<String, dynamic> m, ZCanonical c) {
    final n = c.kind == ZKind.anime
        ? m['num_episodes'] as int?
        : m['num_chapters'] as int?;
    if (n == null || n <= 0) return const [];
    final word = c.kind == ZKind.anime ? 'Episode' : 'Chapter';
    return [
      for (var i = 1; i <= n; i++)
        Episode(
          id: '$i',
          title: '$word $i',
          number: i.toDouble(),
          url: ZmodeIds.episodeUrl(c, i),
        ),
    ];
  }

  /// Both `/ranking` and `/{type}` return `{data: [{node: {...}}]}`.
  static List<MediaItem> _items(dynamic data, ZKind kind) {
    final rows = (data is Map ? data['data'] : null);
    if (rows is! List) return const [];
    final out = <MediaItem>[];
    for (final row in rows) {
      final node = (row is Map ? row['node'] : null);
      if (node is! Map) continue;
      final m = Map<String, dynamic>.from(node);
      final id = m['id'];
      if (id is! int) continue;
      final c = ZCanonical(kind, 'mal:$id');
      final titles = m['alternative_titles'] as Map? ?? const {};
      out.add(MediaItem(
        id: c.id,
        title: m['title'] as String? ?? '',
        englishTitle: (titles['en'] as String?)?.trim().isNotEmpty == true
            ? titles['en'] as String
            : null,
        cover: _picture(m, large: true),
        banner: null,
        url: ZmodeIds.showUrl(c),
        type: _providerType(kind),
        sourceId: ZmodeIds.sourceId,
        malId: id,
        genres: [
          for (final g in (m['genres'] as List? ?? const []))
            if (g is Map && g['name'] is String) g['name'] as String,
        ],
      ));
    }
    return out;
  }
}
