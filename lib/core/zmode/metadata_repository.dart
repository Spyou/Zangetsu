import '../error/exceptions.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:async' show unawaited;
import '../logging/app_logger.dart';
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
import '../di/injector.dart';
import '../playback/playback_prefs.dart';
import 'metadata_filters.dart';
import 'metadata_provider_prefs.dart';
import 'simkl_catalogue.dart';
import 'video_catalogue.dart';
import 'match_store.dart';
import 'playback_resolver.dart';
import 'source_matcher.dart';
import 'tmdb_catalogue.dart';
import 'zmode_ids.dart';
import 'zmode_source_prefs.dart';

/// The Zangetsu Mode catalogue: browsing and episode lists come from
/// AniList/TMDB; playback sweeps installed sources at play time via
/// [PlaybackResolver].
class MetadataRepository implements CatalogueRepository {
  MetadataRepository({
    required AniListCatalogue anilist,
    required TmdbCatalogue tmdb,
    required SourceRepository sources,
    required SourceMatcher matcher,
    required MatchStore matchStore,
    required ZSourcePrefs sourcePrefs,
    required ZKind Function() browseKind,
    MalCatalogue? mal,
    SimklCatalogue? simkl,
    MetadataProviderPrefs? providerPrefs,
    void Function(String message)? onProviderFallback,
    SourceHealthStore? health,
    List<({String id, String name})> Function(ZKind)? candidates,
  }) : _al = anilist,
       _tmdb = tmdb,
       _mal = mal,
       _simkl = simkl,
       _providerPrefs = providerPrefs,
       _onFallback = onProviderFallback,
       _src = sources,
       _matcher = matcher,
       _browseKind = browseKind,
       _playback = PlaybackResolver(
         matcher: matcher,
         sources: sources,
         store: matchStore,
         prefs: sourcePrefs,
         health: health ?? (sl.isRegistered<SourceHealthStore>() ? sl<SourceHealthStore>() : SourceHealthStore()),
         candidates: candidates ?? _defaultCandidates(sources),
       ) {
    _bindPlayback();
  }

  static List<({String id, String name})> Function(ZKind) _defaultCandidates(
    SourceRepository sources,
  ) =>
      (kind) {
        final all = sources.pickableSources;
        return switch (kind) {
          ZKind.manga => [for (final s in all) if (s.id.startsWith('mihon:')) s],
          ZKind.novel => [for (final s in all) if (s.id.startsWith('lnr:')) s],
          _ => [
            for (final s in all)
              if (!s.id.startsWith('mihon:') && !s.id.startsWith('lnr:')) s,
          ],
        };
      };

  void _bindPlayback() {
    _playback.bindTitleLookup(titleFor);
  }

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
  final PlaybackResolver _playback;
  final ZKind Function() _browseKind;

  /// Exposed so [PlaybackResolver] can be registered in DI and accessed
  /// directly for cache invalidation on playback errors.
  PlaybackResolver get playbackResolver => _playback;

  /// Cached metadata home rows per catalogue kind. Anime ↔ Movie/TV toggles can
  /// swap without waiting on AniList/TMDB again; the counterpart kind is
  /// prefetched after each successful home fetch.
  final Map<ZKind, List<HomeSection>> _homeCache = {};

  /// Optional hook when anime/movie home rows land in [_homeCache] — wired in
  /// [initDependencies] so [HomeCubit] can mirror them for instant toggles.
  void Function(ZKind kind, List<HomeSection> rows)? onStreamHomeCached;

  void clearHomeCache() => _homeCache.clear();

  /// Synchronous read of cached home rows — used by [HomeCubit] on Anime ↔
  /// Movie/TV toggles so a prefetched counterpart swaps instantly.
  List<HomeSection>? peekHomeCache(ZKind kind) => _homeCache[kind];

  /// Fetches and caches [kind] when missing. TV warms both streaming kinds
  /// up front so toggling never waits on AniList/TMDB.
  Future<List<HomeSection>> ensureHomeCached(ZKind kind) async {
    final hit = _homeCache[kind];
    if (hit != null) return hit;
    final sw = Stopwatch()..start();
    debugPrint('[metadata] warm · kind=$kind · fetch');
    final rows = await _homeForKind(kind);
    _homeCache[kind] = rows;
    debugPrint(
      '[metadata] warm · kind=$kind · ${rows.length} rows · ${sw.elapsedMilliseconds}ms',
    );
    _syncHomeCubitStreamCache(kind, rows);
    return rows;
  }

  void _syncHomeCubitStreamCache(ZKind kind, List<HomeSection> rows) {
    if (rows.isEmpty) return;
    if (kind != ZKind.anime && kind != ZKind.movie) return;
    onStreamHomeCached?.call(kind, rows);
  }

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
    return _providerPrefs?.anime == AnimeProvider.mal ? (mal, _al) : (_al, mal);
  }

  /// Runs [op] on the chosen provider, and on the other one if that fails.
  ///
  /// Deliberately per-request rather than sticky: a provider that 500s once is
  /// usually back a moment later, and a session-long switch would leave the
  /// user on the fallback long after the outage ended, with no sign of it.
  ///
  /// Some providers swallow HTTP errors and return an empty value instead of
  /// throwing (AniList's GraphQL client returns `null` → no home rows). Pass
  /// [treatAsFailure] so that case still reaches the stand-in.
  Future<T> _viaAnime<T>(
    Future<T> Function(AnimeCatalogue c) op, {
    bool Function(T)? treatAsFailure,
  }) async {
    final (primary, backup) = _animeChain;
    return _withProviderFallback(
      primary: () => op(primary),
      backup: backup == null ? null : () => op(backup),
      fallbackLabel: backup == null ? '' : _fallbackName(backup),
      treatAsFailure: treatAsFailure,
    );
  }

  Future<T> _withProviderFallback<T>({
    required Future<T> Function() primary,
    required Future<T> Function()? backup,
    required String fallbackLabel,
    bool Function(T)? treatAsFailure,
  }) async {
    try {
      final result = await primary();
      if (backup != null &&
          treatAsFailure != null &&
          treatAsFailure(result)) {
        try {
          final out = await backup();
          if (!treatAsFailure(out)) {
            _onFallback?.call(fallbackLabel);
            return out;
          }
        } catch (_) {}
      }
      return result;
    } catch (primaryError, primaryStack) {
      if (backup == null) rethrow;
      try {
        final out = await backup();
        _onFallback?.call(fallbackLabel);
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
  Future<T> _viaVideo<T>(
    Future<T> Function(VideoCatalogue c) op, {
    bool Function(T)? treatAsFailure,
  }) async {
    final (primary, backup) = _videoChain;
    return _withProviderFallback(
      primary: () => op(primary),
      backup: backup == null ? null : () => op(backup),
      fallbackLabel: backup is SimklCatalogue ? 'Simkl' : 'TMDB',
      treatAsFailure: treatAsFailure,
    );
  }

  // ── identity ─────────────────────────────────────────────────────────────

  @override
  String get sourceId => ZmodeIds.sourceId;
  @override
  List<({String id, String name})> get loadedSources => [
    (id: ZmodeIds.sourceId, name: displayName(ZmodeIds.sourceId)),
  ];
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
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    final k = _browseKind();
    final cached = _homeCache[k];
    if (cached != null) {
      debugPrint('[metadata] home · kind=$k · cache (${cached.length} rows)');
      return cached;
    }
    final sw = Stopwatch()..start();
    debugPrint('[metadata] home · kind=$k · fetch');
    final rows = await _homeForKind(k);
    _homeCache[k] = rows;
    debugPrint(
      '[metadata] home · kind=$k · ${rows.length} rows · ${sw.elapsedMilliseconds}ms',
    );
    _syncHomeCubitStreamCache(k, rows);
    _prefetchStreamingCounterpart(k);
    return rows;
  }

  static bool _homeFailed(List<HomeSection> rows) => rows.isEmpty;

  Future<List<HomeSection>> _homeForKind(ZKind k) async {
    final rows = _isTmdb(k)
        ? await _viaVideo((c) => c.home(), treatAsFailure: _homeFailed)
        : await _viaAnime((c) => c.home(k), treatAsFailure: _homeFailed);
    for (final r in rows) {
      r.items.forEach(_remember);
    }
    return rows;
  }

  void _prefetchStreamingCounterpart(ZKind loaded) {
    final other = switch (loaded) {
      ZKind.anime => ZKind.movie,
      ZKind.movie => ZKind.anime,
      _ => null,
    };
    if (other == null || _homeCache.containsKey(other)) return;
    unawaited(() async {
      final sw = Stopwatch()..start();
      try {
        final rows = await _homeForKind(other);
        _homeCache[other] = rows;
        _syncHomeCubitStreamCache(other, rows);
        debugPrint(
          '[metadata] prefetch · kind=$other · ${rows.length} rows · ${sw.elapsedMilliseconds}ms',
        );
      } catch (e) {
        debugPrint('[metadata] prefetch · kind=$other · failed · $e');
      }
    }());
  }

  /// The Privacy switch. Read through GetIt rather than injected because this
  /// is a guard, and a build that forgets to wire it must fail closed.
  bool _adultAllowed() =>
      sl.isRegistered<PlaybackPrefs>() && sl<PlaybackPrefs>().adultMetadata;

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
    // Enforced here, not just in the sheet: filters are persisted, so a saved
    // "adult" selection would otherwise survive the Privacy switch being
    // turned back off.
    if (filters != null && filters.adult && !_adultAllowed()) {
      filters = filters.copyWith(adult: false);
    }
    final items = _isTmdb(k)
        ? await _viaVideo(
            (c) => c.searchFiltered(query, filters: filters, page: page),
          )
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
      'zm_anime' => await _viaAnime(
        (c) => c.browseRow(ZKind.anime, rowId, page),
      ),
      'zm_manga' => await _viaAnime(
        (c) => c.browseRow(ZKind.manga, rowId, page),
      ),
      'zm_novel' => await _viaAnime(
        (c) => c.browseRow(ZKind.novel, rowId, page),
      ),
      _ => const <MediaItem>[],
    };
    items.forEach(_remember);
    return items;
  }

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async {
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
    final filters = MetaFilters.fromJson(filtersJson);
    // Filters ride the same opaque per-source string the extension sheets use,
    // so the search bloc needs no special case for Z Mode. Without filters the
    // old behaviour stands: one page, because a plain metadata search has no
    // paging UI behind it.
    if (filters == null && page > 1) {
      return (items: const <MediaItem>[], outcome: SourceOutcome.ok);
    }
    try {
      final items = filters == null
          ? await search(query)
          : await searchFiltered(query, filters: filters, page: page);
      return (items: items, outcome: SourceOutcome.ok);
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
    final sw = Stopwatch()..start();
    final via = _isTmdb(c.kind) ? 'video' : 'anime';
    AppLogger.instance.log(
      '[metadata] detail start kind=${c.kind} via=$via key=${c.key}',
    );
    final d = _isTmdb(c.kind)
        ? await _viaVideo((x) => x.detail(c))
        : await _viaAnime((x) => x.detail(c));
    _titles[c.key] = (title: d.title, alt: d.englishTitle, malId: d.malId);
    AppLogger.instance.log(
      '[metadata] detail catalogue title="${d.title}" eps=${d.episodes.length} '
      '${sw.elapsedMilliseconds}ms',
    );

    // Video: paint catalogue episodes immediately. Reading: chapters still
    // wait on source match below, so strip them from the partial.
    final partial = c.kind == ZKind.manga || c.kind == ZKind.novel
        ? d.copyWith(episodes: const <Episode>[])
        : d;
    if (onPartial != null) {
      onPartial(partial);
      AppLogger.instance.log(
        '[metadata] detail onPartial eps=${partial.episodes.length} '
        '${sw.elapsedMilliseconds}ms',
      );
    }

    if (c.kind == ZKind.manga || c.kind == ZKind.novel) {
      AppLogger.instance.log('[metadata] detail matching source…');
      // Reading: the reader screens fetch pages/text from SourceRepository
      // with the detail's sourceId + id, so hand them the matched source's
      // chapters, real urls and all — progress there is keyed off that.
      final m = await _matcher.resolve(
        c,
        title: d.title,
        altTitle: d.englishTitle,
        malId: d.malId,
      );
      if (m == null) {
        // A candidate genuinely had this title but a Cloudflare challenge
        // suppressed its search (see SourceMatcher.cfBlockedUrl) — surface
        // it the same way a Mihon/Aniyomi source does, instead of the flat
        // "no source has this yet".
        final blocked = _matcher.cfBlockedUrl(c.kind);
        if (blocked != null) throw CloudflareRequiredException(blocked);
        AppLogger.instance.log(
          '[metadata] detail no source match ${sw.elapsedMilliseconds}ms',
          level: 'W',
        );
        // No match: AniList may still have synthesised a full zm://…/ep/n
        // chapter list (it knows the chapter count for plenty of completed
        // manga), but those urls have no source behind them — drop them
        // rather than hand the reader a real-looking list that throws when
        // it tries to read one.
        return d.copyWith(episodes: const <Episode>[]);
      }
      final chapters = await _src.episodes(m.showUrl, sourceId: m.sourceId);
      AppLogger.instance.log(
        '[metadata] detail matched ${m.sourceId} chapters=${chapters.length} '
        '${sw.elapsedMilliseconds}ms',
      );
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

    // Video: episode list is catalogue-owned; playback resolves at tap time.
    AppLogger.instance.log('[metadata] detail video done ${sw.elapsedMilliseconds}ms');
    return d;
  }

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async => (await detail(url)).episodes;

  // ── playback ─────────────────────────────────────────────────────────────

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl,
    {
    String? sourceId,
    bool fast = false,
  }) async => _playback.sources(episodeUrl, fast: fast);

  @override
  Future<({List<VideoSource> sources, bool done})> polledSources(
    String episodeUrl, {
    String? sourceId,
  }) async => _playback.polledSources(episodeUrl);

  /// Title metadata for play-time resolution — cached from detail/browse.
  Future<({String title, String? alt, int? malId})> titleFor(
    ZCanonical c,
  ) async {
    var t = _titles[c.key];
    if (t != null) return t;
    final d = _isTmdb(c.kind)
        ? await _viaVideo((x) => x.detail(c))
        : await _viaAnime((x) => x.detail(c));
    t = (title: d.title, alt: d.englishTitle, malId: d.malId);
    _titles[c.key] = t;
    return t;
  }

  void _remember(MediaItem i) {
    final c = ZmodeIds.parseShow(i.url);
    if (c != null)
      _titles[c.key] = (title: i.title, alt: i.englishTitle, malId: i.malId);
  }
}
