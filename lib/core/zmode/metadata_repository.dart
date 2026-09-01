import '../error/exceptions.dart';
import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../playback/source_health_store.dart';
import '../models/video_source.dart';
import '../repository/catalogue_repository.dart';
import '../repository/source_repository.dart';
import 'anilist_catalogue.dart';
import 'anime_catalogue.dart';
import 'mal_catalogue.dart';
import 'metadata_filters.dart';
import 'metadata_provider_prefs.dart';
import 'simkl_catalogue.dart';
import 'video_catalogue.dart';
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
    MalCatalogue? mal,
    SimklCatalogue? simkl,
    MetadataProviderPrefs? providerPrefs,
    void Function(String message)? onProviderFallback,
  }) : _al = anilist,
       _tmdb = tmdb,
       _mal = mal,
       _simkl = simkl,
       _providerPrefs = providerPrefs,
       _onFallback = onProviderFallback,
       _src = sources,
       _matcher = matcher,
       _browseKind = browseKind;

  final AniListCatalogue _al;
  final MalCatalogue? _mal;
  final SimklCatalogue? _simkl;
  final MetadataProviderPrefs? _providerPrefs;

  /// Told when a request had to be served by the other provider, so the UI can
  /// say so. Optional — tests and the TV shell pass nothing.
  final void Function(String message)? _onFallback;
  final TmdbCatalogue _tmdb;
  final SourceRepository _src;
  final SourceMatcher _matcher;
  final ZKind Function() _browseKind;

  /// Titles seen on this run, so `sources()` can search by name without a
  /// second metadata round-trip.
  final _titles = <String, ({String title, String? alt, int? malId})>{};

  static bool _isTmdb(ZKind k) => k == ZKind.movie || k == ZKind.tv;

  /// The chosen anime/manga provider, and the one that stands in for it.
  ///
  /// Falling back is worth doing because the two are genuinely
  /// interchangeable for most titles: AniList stamps `mal:` ids wherever a
  /// title has one, so the id a screen is already holding usually resolves on
  /// either. An `al:` id is the exception — MAL has nothing to look up — and
  /// [MalCatalogue.detail] throws rather than guessing, which lands us back on
  /// the original error below.
  (AnimeCatalogue, AnimeCatalogue?) get _animeChain {
    final mal = _mal;
    if (mal == null) return (_al, null);
    return _providerPrefs?.anime == AnimeProvider.mal
        ? (mal, _al)
        : (_al, mal);
  }

  /// Runs [op] on the chosen provider, and on the other one if that fails.
  ///
  /// Deliberately per-request rather than sticky: a provider that 500s once is
  /// usually back a moment later, and a session-long switch would leave the
  /// user on the fallback long after the outage ended, with no sign of it.
  Future<T> _viaAnime<T>(Future<T> Function(AnimeCatalogue c) op) async {
    final (primary, backup) = _animeChain;
    try {
      return await op(primary);
    } catch (primaryError, primaryStack) {
      if (backup == null) rethrow;
      try {
        final out = await op(backup);
        _onFallback?.call(_fallbackName(backup));
        return out;
      } catch (_) {
        // The stand-in failed too. Report the ORIGINAL failure with its own
        // stack: that is the provider the user chose, and "MAL is down" is a
        // confusing thing to be told when you are using AniList. A plain
        // `rethrow` here would surface the stand-in's error instead.
        Error.throwWithStackTrace(primaryError, primaryStack);
      }
    }
  }

  static String _fallbackName(AnimeCatalogue c) =>
      c is MalCatalogue ? 'MyAnimeList' : 'AniList';

  /// The movie/TV twin of [_animeChain].
  (VideoCatalogue, VideoCatalogue?) get _videoChain {
    final simkl = _simkl;
    if (simkl == null) return (_tmdb, null);
    return _providerPrefs?.video == VideoProvider.simkl
        ? (simkl, _tmdb)
        : (_tmdb, simkl);
  }

  /// The movie/TV twin of [_viaAnime]. Interchangeable for the same reason:
  /// Simkl carries a TMDB id on nearly everything, so both speak `tmdb:`.
  Future<T> _viaVideo<T>(Future<T> Function(VideoCatalogue c) op) async {
    final (primary, backup) = _videoChain;
    try {
      return await op(primary);
    } catch (primaryError, primaryStack) {
      if (backup == null) rethrow;
      try {
        final out = await op(backup);
        _onFallback?.call(backup is SimklCatalogue ? 'Simkl' : 'TMDB');
        return out;
      } catch (_) {
        Error.throwWithStackTrace(primaryError, primaryStack);
      }
    }
  }

  // ── identity ─────────────────────────────────────────────────────────────

  @override
  String get sourceId => ZmodeIds.sourceId;
  @override
  List<({String id, String name})> get loadedSources =>
      [(id: ZmodeIds.sourceId, name: displayName(ZmodeIds.sourceId))];
  @override
  bool hasSource(String sourceId) => sourceId == ZmodeIds.sourceId;

  /// The provider actually answering right now, so an error can name what
  /// failed. Hardcoding TMDB/AniList here stopped being true the moment MAL
  /// and Simkl could stand in for them.
  @override
  String displayName(String sourceId) {
    if (_isTmdb(_browseKind())) {
      return _providerPrefs?.video == VideoProvider.simkl ? 'Simkl' : 'TMDB';
    }
    return _providerPrefs?.anime == AnimeProvider.mal
        ? 'MyAnimeList'
        : 'AniList';
  }

  @override
  void syncSearchCache() {}
  @override
  Future<void> clearHttpCache() async {}

  // ── browsing ─────────────────────────────────────────────────────────────

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async {
    final k = _browseKind();
    final rows =
        _isTmdb(k) ? await _viaVideo((c) => c.home()) : await _viaAnime((c) => c.home(k));
    for (final r in rows) {
      r.items.forEach(_remember);
    }
    return rows;
  }

  /// Whether the CHOSEN provider filters server-side.
  ///
  /// Deliberately the chosen one, not the chain: the fallback only runs when a
  /// request fails, so a filter button must not appear because the backup
  /// could have honoured it. AniList and TMDB can; MAL and Simkl accept filter
  /// parameters and return unfiltered results, which is worse than refusing.
  bool get supportsFilters => _isTmdb(_browseKind())
      ? _videoChain.$1.supportsFilters
      : _animeChain.$1.supportsFilters;

  /// Search and/or browse with filters. An empty [query] plus filters is a
  /// browse; both are the same request to the providers that support it.
  Future<List<MediaItem>> searchFiltered(
    String query, {
    MetaFilters? filters,
    int page = 1,
  }) async {
    final k = _browseKind();
    final items = _isTmdb(k)
        ? await _viaVideo((c) => c.searchFiltered(query, filters: filters, page: page))
        : await _viaAnime(
            (c) => c.searchFiltered(query, k, filters: filters, page: page),
          );
    items.forEach(_remember);
    return items;
  }

  /// Next page of one home row, for the "See all" grid.
  ///
  /// Not part of [CatalogueRepository] — pagination never was, and the source
  /// side reaches its own repository the same way. Routes on the `kind` the
  /// catalogue stamped onto [HomeSection.more], so an AniList row keeps going
  /// to AniList even if the browse mode changed underneath.
  Future<List<MediaItem>> browseMore(BrowseMore more, int page) async {
    final rowId = more.categoryId;
    if (rowId == null || rowId.isEmpty) return const [];
    final items = switch (more.kind) {
      'zm_video' => await _viaVideo((c) => c.browseRow(rowId, page)),
      'zm_anime' => await _viaAnime((c) => c.browseRow(ZKind.anime, rowId, page)),
      'zm_manga' => await _viaAnime((c) => c.browseRow(ZKind.manga, rowId, page)),
      'zm_novel' => await _viaAnime((c) => c.browseRow(ZKind.novel, rowId, page)),
      _ => const <MediaItem>[],
    };
    items.forEach(_remember);
    return items;
  }

  @override
  Future<List<MediaItem>> search(String query, {String category = 'sub', String? sourceId}) async {
    final k = _browseKind();
    final items = _isTmdb(k)
        ? await _viaVideo((c) => c.search(query))
        : await _viaAnime((c) => c.search(query, k));
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
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
  }) async {
    final c = ZmodeIds.parseShow(url);
    if (c == null) throw ArgumentError('not a metadata url: $url');
    final d = _isTmdb(c.kind)
        ? await _viaVideo((x) => x.detail(c))
        : await _viaAnime((x) => x.detail(c));
    _titles[c.key] = (title: d.title, alt: d.englishTitle, malId: d.malId);

    // Hand the caller everything that does NOT depend on a source right now:
    // title, art, synopsis, cast. Everything past this point waits on
    // _matcher.resolve, which searches installed sources one at a time — the
    // whole reason opening a title used to sit on a spinner. Episodes are
    // stripped for the same reason the no-match branches below strip them: a
    // synthesised list has no source behind it and can't be played.
    onPartial?.call(d.copyWith(episodes: const <Episode>[]));

    if (c.kind == ZKind.manga || c.kind == ZKind.novel) {
      // Reading: the reader screens fetch pages/text from SourceRepository
      // with the detail's sourceId + id, so hand them the matched source's
      // chapters, real urls and all — progress there is keyed off that.
      final m = await _matcher.resolve(c, title: d.title, altTitle: d.englishTitle, malId: d.malId);
      if (m == null) {
        // A candidate genuinely had this title but a Cloudflare challenge
        // suppressed its search (see SourceMatcher.cfBlockedUrl) — surface
        // it the same way a Mihon/Aniyomi source does, instead of the flat
        // "no source has this yet".
        final blocked = _matcher.cfBlockedUrl(c.kind);
        if (blocked != null) throw CloudflareRequiredException(blocked);
        // No match: AniList may still have synthesised a full zm://…/ep/n
        // chapter list (it knows the chapter count for plenty of completed
        // manga), but those urls have no source behind them — drop them
        // rather than hand the reader a real-looking list that throws when
        // it tries to read one.
        return d.copyWith(episodes: const <Episode>[]);
      }
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
    if (m == null) {
      // Same Cloudflare-suppressed-search check as the reading branch above.
      final blocked = _matcher.cfBlockedUrl(c.kind);
      if (blocked != null) throw CloudflareRequiredException(blocked);
      // No match: the catalogue may still have synthesised a full zm://…/ep/n
      // list (TMDB knows a series' whole season/episode layout, AniList its
      // episode count), but those urls have no source behind them — Play
      // fails on the first tap. Drop them, exactly as the reading branch
      // above does, so the honest empty state shows BEFORE the user commits
      // to a tap instead of after it.
      return d.copyWith(episodes: const <Episode>[]);
    }
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
      final d = _isTmdb(c.kind)
        ? await _viaVideo((x) => x.detail(c))
        : await _viaAnime((x) => x.detail(c));
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
