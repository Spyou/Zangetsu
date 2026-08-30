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
    if (c.kind != ZKind.manga && c.kind != ZKind.novel) return d;

    // Reading: the reader screens fetch pages/text from SourceRepository with
    // the detail's sourceId + id, so hand them the matched source's chapters.
    final m = await _matcher.resolve(c, title: d.title, altTitle: d.englishTitle, malId: d.malId);
    if (m == null) return d;
    final chapters = await _src.episodes(m.showUrl, sourceId: m.sourceId);
    return MediaDetail(
      id: m.showId,
      title: d.title,
      englishTitle: d.englishTitle,
      cover: d.cover,
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

  /// The source episode behind a `zm://…/ep/n` url: same number, else the
  /// n-th entry.
  Future<({String url, String sourceId})> _sourceEpisode(String episodeUrl) async {
    final p = ZmodeIds.parseEpisode(episodeUrl);
    if (p == null) throw ArgumentError('not a metadata episode url: $episodeUrl');
    final m = await _matchFor(p.show);
    final eps = await _src.episodes(m.showUrl, sourceId: m.sourceId);
    final byNumber = eps.where((e) => e.number == p.episode.toDouble()).firstOrNull;
    final ep = byNumber ?? (p.episode - 1 < eps.length ? eps[p.episode - 1] : null);
    if (ep == null) throw NoSourceMatch(p.show);
    return (url: ep.url, sourceId: m.sourceId);
  }

  Future<SourceMatch> _matchFor(ZCanonical c) async {
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
