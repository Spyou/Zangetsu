import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../playback/source_health_store.dart';
import '../models/video_source.dart';
import '../repository/catalogue_repository.dart';
import '../repository/source_repository.dart';
import 'anilist_catalogue.dart';
import 'match_store.dart';
import 'source_matcher.dart';
import 'tmdb_catalogue.dart';
import 'zmode_ids.dart';

/// The Zangetsu Mode catalogue: browsing comes from AniList/TMDB, playback
/// from whichever installed source [SourceMatcher] pairs the title with.
/// `sources()` is the one method that never answers from metadata.
class MetadataRepository implements CatalogueRepository {
  MetadataRepository({
    required AniListCatalogue anilist,
    required TmdbCatalogue tmdb,
    required SourceRepository sources,
    required SourceMatcher matcher,
    required ZKind Function() browseKind,
  }) : _al = anilist,
       _tmdb = tmdb,
       _src = sources,
       _matcher = matcher,
       _browseKind = browseKind;

  final AniListCatalogue _al;
  final TmdbCatalogue _tmdb;
  final SourceRepository _src;
  final SourceMatcher _matcher;
  final ZKind Function() _browseKind;

  /// Titles seen on this run, so `sources()` can search by name without a
  /// second metadata round-trip.
  final _titles = <String, ({String title, String? alt, int? malId})>{};

  static bool _isTmdb(ZKind k) => k == ZKind.movie || k == ZKind.tv;

  // ── identity ─────────────────────────────────────────────────────────────

  @override
  String get sourceId => ZmodeIds.sourceId;
  @override
  List<({String id, String name})> get loadedSources =>
      [(id: ZmodeIds.sourceId, name: displayName(ZmodeIds.sourceId))];
  @override
  bool hasSource(String sourceId) => sourceId == ZmodeIds.sourceId;
  @override
  String displayName(String sourceId) =>
      _isTmdb(_browseKind()) ? 'TMDB' : 'AniList';
  @override
  void syncSearchCache() {}
  @override
  Future<void> clearHttpCache() async {}

  // ── browsing ─────────────────────────────────────────────────────────────

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async {
    final k = _browseKind();
    final rows = _isTmdb(k) ? await _tmdb.home() : await _al.home(k);
    for (final r in rows) {
      r.items.forEach(_remember);
    }
    return rows;
  }

  @override
  Future<List<MediaItem>> search(String query, {String category = 'sub', String? sourceId}) async {
    final k = _browseKind();
    final items = _isTmdb(k) ? await _tmdb.search(query) : await _al.search(query, k);
    items.forEach(_remember);
    return items;
  }

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    if (page > 1) return (items: const <MediaItem>[], outcome: SourceOutcome.ok);
    try {
      return (items: await search(query), outcome: SourceOutcome.ok);
    } catch (_) {
      return (items: const <MediaItem>[], outcome: SourceOutcome.error);
    }
  }

  // ── a title ──────────────────────────────────────────────────────────────

  @override
  Future<MediaDetail> detail(String url, {String category = 'sub', String? sourceId}) async {
    final c = ZmodeIds.parseShow(url);
    if (c == null) throw ArgumentError('not a metadata url: $url');
    final d = _isTmdb(c.kind) ? await _tmdb.detail(c) : await _al.detail(c);
    _titles[c.key] = (title: d.title, alt: d.englishTitle, malId: d.malId);

    if (c.kind == ZKind.manga || c.kind == ZKind.novel) {
      // Reading: the reader screens fetch pages/text from SourceRepository
      // with the detail's sourceId + id, so hand them the matched source's
      // chapters, real urls and all — progress there is keyed off that.
      final m = await _matcher.resolve(c, title: d.title, altTitle: d.englishTitle, malId: d.malId);
      // No match: AniList may still have synthesised a full zm://…/ep/n
      // chapter list (it knows the chapter count for plenty of completed
      // manga), but those urls have no source behind them — drop them rather
      // than hand the reader a real-looking list that throws when it tries
      // to read one.
      if (m == null) return d.copyWith(episodes: const <Episode>[]);
      final chapters = await _src.episodes(m.showUrl, sourceId: m.sourceId);
      return MediaDetail(
        id: m.showId,
        title: d.title,
        englishTitle: d.englishTitle,
        cover: d.cover,
        banner: d.banner,
        url: d.url,
        description: d.description,
        status: d.status,
        genres: d.genres,
        studios: d.studios,
        episodes: chapters,
        year: d.year,
        type: d.type,
        sourceId: m.sourceId,
        malId: d.malId,
      );
    }

    // Watching: playback is already routed through zm://…/ep/n (see
    // _sourceEpisode below), and resume progress is keyed off that same
    // canonical id/url — never the source's own. So only the DISPLAY comes
    // from the matched source here: titles, thumbnails, dates, descriptions,
    // and the count. id/url are rewritten back to the canonical, numbered-by-
    // position form so progress keeps following the title, not the source.
    final m = await _matcher.resolve(c, title: d.title, altTitle: d.englishTitle, malId: d.malId);
    if (m == null) return d; // no match: metadata's synthesised list stands.
    final srcEpisodes = await _src.episodes(m.showUrl, sourceId: m.sourceId);
    final episodes = [
      for (var i = 0; i < srcEpisodes.length; i++) _canonicalize(srcEpisodes[i], c, i + 1),
    ];
    return d.copyWith(episodes: episodes);
  }

  /// [e] with its display kept but id/url/number replaced by the canonical,
  /// position-numbered form — see the comment in [detail]. [number] in
  /// particular is read as ground truth by trackers (AniList/MAL/Simkl
  /// scrobbling), filler lookups and skip-time lookups — all keyed by the
  /// canonical episode count, not whatever the source calls it (a source
  /// that restarts numbering per season would otherwise scrobble the wrong
  /// episode). The source's own number, if worth showing, belongs in the
  /// title, never here.
  static Episode _canonicalize(Episode e, ZCanonical c, int n) => Episode(
    id: '$n',
    title: e.title,
    number: n.toDouble(),
    url: ZmodeIds.episodeUrl(c, n),
    date: e.date,
    thumbnail: e.thumbnail,
    filler: e.filler,
    season: e.season,
    scanlator: e.scanlator,
    description: e.description,
    metaTitle: e.metaTitle,
    rating: e.rating,
    runtimeMinutes: e.runtimeMinutes,
  );

  @override
  Future<List<Episode>> episodes(String url, {String category = 'sub', String? sourceId}) async =>
      (await detail(url)).episodes;

  // ── playback ─────────────────────────────────────────────────────────────

  @override
  Future<List<VideoSource>> sources(String episodeUrl, {String? sourceId, bool fast = false}) async {
    final ep = await _sourceEpisode(episodeUrl);
    return _src.sources(ep.url, sourceId: ep.sourceId, fast: fast);
  }

  @override
  Future<({List<VideoSource> sources, bool done})> polledSources(String episodeUrl, {String? sourceId}) async {
    final ep = await _sourceEpisode(episodeUrl);
    return _src.polledSources(ep.url, sourceId: ep.sourceId);
  }

  /// The source episode behind a `zm://…/ep/n` url: the n-th entry of that
  /// same source's episode list — the exact list [detail] builds the
  /// DISPLAY from, fetched the exact same way, so position is not a guess,
  /// it's the same lookup. Out of range is an honest "not found", not a
  /// guess: [EpisodeNotOnSource], not [NoSourceMatch] (the show did match).
  Future<({String url, String sourceId})> _sourceEpisode(String episodeUrl) async {
    final p = ZmodeIds.parseEpisode(episodeUrl);
    if (p == null) throw ArgumentError('not a metadata episode url: $episodeUrl');
    final m = await _matchFor(p.show);
    final eps = await _src.episodes(m.showUrl, sourceId: m.sourceId);
    final i = p.episode - 1;
    if (i < 0 || i >= eps.length) throw EpisodeNotOnSource(p.show, p.episode);
    return (url: eps[i].url, sourceId: m.sourceId);
  }

  Future<SourceMatch> _matchFor(ZCanonical c) async {
    // Already matched (e.g. from a previous run): skip the metadata round
    // trip entirely, since resolve() wouldn't have used the title anyway.
    final saved = _matcher.saved(c);
    if (saved != null) return saved;
    var t = _titles[c.key];
    if (t == null) {
      final d = _isTmdb(c.kind) ? await _tmdb.detail(c) : await _al.detail(c);
      t = (title: d.title, alt: d.englishTitle, malId: d.malId);
      _titles[c.key] = t;
    }
    final m = await _matcher.resolve(c, title: t.title, altTitle: t.alt, malId: t.malId);
    if (m == null) throw NoSourceMatch(c);
    return m;
  }

  void _remember(MediaItem i) {
    final c = ZmodeIds.parseShow(i.url);
    if (c != null) _titles[c.key] = (title: i.title, alt: i.englishTitle, malId: i.malId);
  }
}
