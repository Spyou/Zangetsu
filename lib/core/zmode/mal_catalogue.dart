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
      // media_type is what separates a light novel from a manga: MAL has no
      // novel endpoint, so /manga/ranking answers for both and only this
      // field says which one came back.
      'start_season,mean,media_type';
  static const String _detailFields =
      '$_listFields,synopsis,studios,media_type,num_chapters,'
      'mean,num_list_users,average_episode_duration,source,'
      'start_date,end_date,nsfw';

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

  /// What an item actually IS. MAL keeps light novels on the manga endpoint,
  /// so only `media_type` separates them — the same rule the tracker's list
  /// reader uses, which is why a MAL novel list works but these rows did not.
  static ProviderType _typeOf(ZKind kind, String? mediaType) {
    if (kind != ZKind.manga && kind != ZKind.novel) return ProviderType.anime;
    return (mediaType == 'novel' || mediaType == 'light_novel')
        ? ProviderType.novel
        : ProviderType.manga;
  }

  /// Whether an item's real type belongs in the kind being browsed. Anime and
  /// movies share MAL's anime catalogue, so both pass there.
  static bool _matchesKind(ZKind kind, ProviderType type) => switch (kind) {
    ZKind.manga => type == ProviderType.manga,
    ZKind.novel => type == ProviderType.novel,
    _ => type == ProviderType.anime || type == ProviderType.movie,
  };

  /// The home rows, as (title, ranking_type). Deliberately close to the
  /// AniList set so switching provider changes the data, not the shape of the
  /// screen. MAL has no "trending" or per-season ranking, so `airing`/`upcoming`
  /// stand in for the seasonal rows.
  /// Row titles for [k] without a fetch — see [AniListCatalogue.rowTitles].
  static List<String> rowTitles(ZKind k) => [for (final r in _rows(k)) r.$1];

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
              // The reading kinds share one endpoint and are filtered after
              // the fact: only about a third of a manga page is light novels,
              // so asking for 30 left a novel row with roughly eight entries.
              'limit': kind == ZKind.anime ? 30 : 100,
              'fields': _listFields,
            })
            .then<List<MediaItem>>((r) => _items(r.data, kind))
            .catchError((_) => <MediaItem>[]),
    ]);
    final out = <HomeSection>[];
    for (final (i, (title, rankingType)) in rows.indexed) {
      if (results[i].isNotEmpty) {
        out.add(
          HomeSection(
            title: title,
            items: results[i],
            more: BrowseMore(
              sourceId: ZmodeIds.sourceId,
              kind: 'zm_${kind.name}',
              categoryId: rankingType,
            ),
          ),
        );
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
        // MAL cannot filter by genre but DOES honour this one, so it is the
        // one filter that works here.
        'nsfw': filters?.adult ?? false,
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
      // MAL scores out of 10, the model holds out of 100 — the same scale
      // AniList reports, so the page can print one number either way.
      score: _score(map['mean']),
      format: _prettyEnum(map['media_type'] as String?),
      // Seconds per episode, not minutes.
      durationMins: _durationMins(map['average_episode_duration']),
      sourceMaterial: _prettyEnum(map['source'] as String?),
      startDate: _date(map['start_date'] as String?),
      endDate: _date(map['end_date'] as String?),
      // How many people have it listed. MAL's own `popularity` is a RANK
      // (3 = third most popular), which would read as a count of three.
      popularity: map['num_list_users'] as int?,
      nativeTitle: (titles['ja'] as String?)?.trim().isEmpty == true
          ? null
          : titles['ja'] as String?,
      synonyms: [
        for (final x in (titles['synonyms'] as List? ?? const [])) '$x',
      ],
      // 'white' is the safe bucket; 'gray' and 'black' are not.
      isAdult: (map['nsfw'] as String?) != null && map['nsfw'] != 'white',
    );
  }

  Future<List<Episode>> episodes(ZCanonical c) async =>
      (await detail(c)).episodes;

  static int? _score(Object? mean) {
    final v = (mean as num?)?.toDouble();
    return v == null || v <= 0 ? null : (v * 10).round();
  }

  static int? _durationMins(Object? seconds) {
    final v = (seconds as num?)?.toInt();
    return v == null || v <= 0 ? null : (v / 60).round();
  }

  /// `light_novel` → `Light novel`. MAL uses snake_case where AniList SHOUTS;
  /// both end up reading the same on the page.
  static String? _prettyEnum(String? v) {
    if (v == null || v.isEmpty) return null;
    final words = v.replaceAll('_', ' ').toLowerCase();
    return words[0].toUpperCase() + words.substring(1);
  }

  /// MAL dates are `YYYY-MM-DD`, and a partial one is legitimately just the
  /// year or the year and month.
  static DateTime? _date(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final p = raw.split('-');
    final y = int.tryParse(p.first);
    if (y == null) return null;
    return DateTime(
      y,
      p.length > 1 ? int.tryParse(p[1]) ?? 1 : 1,
      p.length > 2 ? int.tryParse(p[2]) ?? 1 : 1,
    );
  }

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
    return ((large ? p['large'] : null) ?? p['medium'] ?? p['large'])
        as String?;
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
      out.add(
        MediaItem(
          id: c.id,
          title: m['title'] as String? ?? '',
          englishTitle: (titles['en'] as String?)?.trim().isNotEmpty == true
              ? titles['en'] as String
              : null,
          cover: _picture(m, large: true),
          banner: null,
          url: ZmodeIds.showUrl(c),
          type: _typeOf(kind, m['media_type'] as String?),
          sourceId: ZmodeIds.sourceId,
          malId: id,
          genres: [
            for (final g in (m['genres'] as List? ?? const []))
              if (g is Map && g['name'] is String) g['name'] as String,
          ],
        ),
      );
    }
    // /manga/ranking returns manga AND light novels together. Without this,
    // novel mode listed manga — labelled "novel", because the old mapper
    // trusted the kind it asked for — and manga mode listed novels.
    return [
      for (final i in out)
        if (_matchesKind(kind, i.type)) i,
    ];
  }
}
