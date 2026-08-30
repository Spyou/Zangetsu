import 'package:dio/dio.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import 'zmode_ids.dart';

typedef Gql =
    Future<Map<String, dynamic>?> Function(
      String query,
      Map<String, dynamic> variables,
    );

/// AniList as a browsing catalogue: home rows, search, and a detail with a
/// synthetic episode list. Anonymous — no token, so nothing here can touch the
/// user's list.
class AniListCatalogue {
  AniListCatalogue(this._gql);
  final Gql _gql;

  static const _endpoint = 'https://graphql.anilist.co';

  /// Production transport. Same shape as `AiringService`.
  static Gql dioGql(Dio dio) => (query, variables) async {
    try {
      final res = await dio.post<dynamic>(
        _endpoint,
        data: {'query': query, 'variables': variables},
        options: Options(
          headers: const {'Accept': 'application/json'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data;
      if (data is Map && data['data'] is Map) {
        return Map<String, dynamic>.from(data['data'] as Map);
      }
    } catch (_) {}
    return null;
  };

  static const _fields =
      'id idMal title{romaji english} coverImage{large extraLarge} bannerImage '
      'episodes chapters status genres description(asHtml:false) seasonYear '
      'studios(isMain:true){nodes{name}} nextAiringEpisode{episode}';

  /// Exactly what [_item] reads, and nothing else. Home asks for 7 rows of 30
  /// in one request, so every field here is paid for 210 times: carrying the
  /// detail-only half of [_fields] (description, studios, airing schedule)
  /// through it more than doubled the response for data no list cell shows.
  static const _listFields =
      'id idMal title{romaji english} coverImage{large} bannerImage genres';

  static String _type(ZKind k) => k == ZKind.anime ? 'ANIME' : 'MANGA';
  static String _format(ZKind k) => switch (k) {
    ZKind.novel => ',format_in:[NOVEL]',
    ZKind.manga => ',format_not_in:[NOVEL]',
    _ => '',
  };

  static ProviderType _providerType(ZKind k) => switch (k) {
    ZKind.manga => ProviderType.manga,
    ZKind.novel => ProviderType.novel,
    _ => ProviderType.anime,
  };

  /// (row title, extra media() arguments) — the home rows. Anime gets a
  /// season-aware "this season"/"next season" pair plus a couple of genre
  /// rows so the page feels populated instead of a wall of sort variants;
  /// manga/novel keep it shorter since AniList has thinner season data for
  /// them.
  static List<(String, String)> _rows(ZKind k) {
    final now = DateTime.now();
    final season = switch (now.month) {
      1 || 2 || 3 => 'WINTER',
      4 || 5 || 6 => 'SPRING',
      7 || 8 || 9 => 'SUMMER',
      _ => 'FALL',
    };
    if (k != ZKind.anime) {
      return [
        ('Trending', 'sort:TRENDING_DESC'),
        ('Popular', 'sort:POPULARITY_DESC'),
        ('Top rated', 'sort:SCORE_DESC'),
        ('Action', 'genre_in:["Action"],sort:POPULARITY_DESC'),
        ('Romance', 'genre_in:["Romance"],sort:POPULARITY_DESC'),
      ];
    }
    final (nextSeason, nextYear) = switch (season) {
      'WINTER' => ('SPRING', now.year),
      'SPRING' => ('SUMMER', now.year),
      'SUMMER' => ('FALL', now.year),
      _ => ('WINTER', now.year + 1),
    };
    return [
      ('Trending', 'sort:TRENDING_DESC'),
      ('Popular this season',
          'sort:POPULARITY_DESC,season:$season,seasonYear:${now.year}'),
      ('Upcoming next season',
          'sort:POPULARITY_DESC,season:$nextSeason,seasonYear:$nextYear,'
              'status:NOT_YET_RELEASED'),
      ('All-time popular', 'sort:POPULARITY_DESC'),
      ('Top rated', 'sort:SCORE_DESC'),
      ('Action', 'genre_in:["Action"],sort:POPULARITY_DESC'),
      ('Romance', 'genre_in:["Romance"],sort:POPULARITY_DESC'),
    ];
  }

  /// One request for every row, via aliased `Page` fields — `r0`, `r1`, …,
  /// one per entry in [_rows] — instead of a round-trip per row. A malformed
  /// or partial response (missing alias, non-list `media`, or no response at
  /// all) just drops that row rather than throwing.
  Future<List<HomeSection>> home(ZKind kind) async {
    final rows = _rows(kind);
    final query = rows.indexed.map((e) {
      final (i, (_, args)) = e;
      return 'r$i: Page(perPage:30){ media(type:${_type(kind)}${_format(kind)},$args){ $_listFields } }';
    }).join(' ');
    final data = await _gql('query{ $query }', const {});
    final out = <HomeSection>[];
    for (final (i, (title, _)) in rows.indexed) {
      final items = _itemsFromPage(data?['r$i'], kind);
      if (items.isNotEmpty) out.add(HomeSection(title: title, items: items));
    }
    return out;
  }

  Future<List<MediaItem>> search(String q, ZKind kind) async {
    const query = r'query($q:String,$n:Int){ Page(perPage:$n){ media(search:$q,type:';
    final full =
        '$query${_type(kind)}${_format(kind)}){ $_listFields } } }';
    return _items(await _gql(full, {'q': q, 'n': 20}), kind);
  }

  Future<MediaDetail> detail(ZCanonical c) async {
    final (arg, vars) = _idArg(c);
    final q =
        'query(${arg.$1}){ Media(${arg.$2},type:${_type(c.kind)}){ $_fields } }';
    final m = (await _gql(q, vars))?['Media'];
    if (m is! Map) throw StateError('AniList returned no media for $c');
    final map = Map<String, dynamic>.from(m);
    final eps = _episodesFor(map, c);
    final t = map['title'] as Map? ?? const {};
    final cover = map['coverImage'] as Map? ?? const {};
    return MediaDetail(
      id: c.id,
      title: (t['romaji'] as String?) ?? (t['english'] as String?) ?? '',
      englishTitle: t['english'] as String?,
      cover: (cover['extraLarge'] ?? cover['large']) as String?,
      banner: map['bannerImage'] as String?,
      url: ZmodeIds.showUrl(c),
      description: map['description'] as String?,
      status: _status(map['status'] as String?),
      genres: [for (final g in (map['genres'] as List? ?? const [])) '$g'],
      studios: [
        for (final n in ((map['studios'] as Map?)?['nodes'] as List? ?? const []))
          if (n is Map && n['name'] is String) n['name'] as String,
      ],
      episodes: eps,
      year: map['seasonYear']?.toString(),
      type: _providerType(c.kind),
      sourceId: ZmodeIds.sourceId,
      malId: map['idMal'] as int?,
    );
  }

  Future<List<Episode>> episodes(ZCanonical c) async =>
      (await detail(c)).episodes;

  // ── helpers ──────────────────────────────────────────────────────────────

  /// (`($idMal:Int)`, `idMal:$idMal`) or the `id` twin, plus the variables.
  static ((String, String), Map<String, dynamic>) _idArg(ZCanonical c) {
    final n = int.parse(c.id.split(':').last);
    return c.id.startsWith('mal:')
        ? ((r'$idMal:Int', r'idMal:$idMal'), {'idMal': n})
        : ((r'$id:Int', r'id:$id'), {'id': n});
  }

  static ZCanonical _canonical(Map<String, dynamic> m, ZKind kind) {
    final mal = m['idMal'] as int?;
    return ZCanonical(kind, mal != null ? 'mal:$mal' : 'al:${m['id']}');
  }

  static List<MediaItem> _items(Map<String, dynamic>? data, ZKind kind) =>
      _itemsFromPage(data?['Page'], kind);

  /// [page] is a `Page(){ media }` result — top-level for search/detail,
  /// or one aliased row (`data['r0']`, `data['r1']`, …) for [home]. Anything
  /// short of a well-shaped `{media: [...]}` map degrades to no items rather
  /// than throwing, so a partial multi-row response still yields the rows it
  /// legitimately has.
  static List<MediaItem> _itemsFromPage(dynamic page, ZKind kind) {
    if (page is! Map) return const [];
    final media = page['media'];
    if (media is! List) return const [];
    return [
      for (final m in media)
        if (m is Map) _item(Map<String, dynamic>.from(m), kind),
    ];
  }

  static MediaItem _item(Map<String, dynamic> m, ZKind kind) {
    final c = _canonical(m, kind);
    final t = m['title'] as Map? ?? const {};
    return MediaItem(
      id: c.id,
      title: (t['romaji'] as String?) ?? (t['english'] as String?) ?? '',
      englishTitle: t['english'] as String?,
      cover: (m['coverImage'] as Map?)?['large'] as String?,
      banner: m['bannerImage'] as String?,
      url: ZmodeIds.showUrl(c),
      type: _providerType(kind),
      sourceId: ZmodeIds.sourceId,
      malId: m['idMal'] as int?,
      genres: [for (final g in (m['genres'] as List? ?? const [])) '$g'],
    );
  }

  /// Anime: 1..episodes, or 1..(next-1) while airing. Manga/novel: 1..chapters.
  /// No count → no list; the matched source supplies chapters in that case.
  static List<Episode> _episodesFor(Map<String, dynamic> m, ZCanonical c) {
    int? n;
    if (c.kind == ZKind.anime) {
      n = m['episodes'] as int?;
      final next = (m['nextAiringEpisode'] as Map?)?['episode'] as int?;
      if (next != null) n = next - 1;
    } else {
      n = m['chapters'] as int?;
    }
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

  static MediaStatus _status(String? s) => switch (s) {
    'RELEASING' => MediaStatus.ongoing,
    'FINISHED' => MediaStatus.completed,
    'HIATUS' => MediaStatus.hiatus,
    'CANCELLED' => MediaStatus.cancelled,
    _ => MediaStatus.unknown,
  };
}
