import '../error/exceptions.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:async' show unawaited;
import '../logging/app_logger.dart';
import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
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
    PreferredProvider? prefer,
  }) async {
    var (primary, backup) = _animeChain;
    // A caller that knows which catalogue this title came from wins over the
    // saved choice — the fallback still applies if that one fails. Carried
    // over from main: the branch this resolver came from had dropped it,
    // which would have silently removed the metadata-provider switch.
    final forced = switch (prefer) {
      PreferredProvider.anilist => _al,
      PreferredProvider.mal => _mal,
      _ => null,
    };
    if (forced != null && forced != primary) {
      backup = primary;
      primary = forced;
    }
    // Copied into finals: `primary`/`backup` are reassignable now (the
    // `prefer` swap above), and Dart will not promote a mutable local inside
    // a closure.
    final chosen = primary;
    final standIn = backup;
    return _withProviderFallback(
      primary: () => op(chosen),
      backup: standIn == null ? null : () => op(standIn),
      fallbackLabel: standIn == null ? '' : _fallbackName(standIn),
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
    PreferredProvider? prefer,
  }) async {
    var (primary, backup) = _videoChain;
    final forced = switch (prefer) {
      PreferredProvider.tmdb => _tmdb,
      PreferredProvider.simkl => _simkl,
      _ => null,
    };
    if (forced != null && forced != primary) {
      backup = primary;
      primary = forced;
    }
    final chosen = primary;
    final standIn = backup;
    return _withProviderFallback(
      primary: () => op(chosen),
      backup: standIn == null ? null : () => op(standIn),
      fallbackLabel: standIn is SimklCatalogue ? 'Simkl' : 'TMDB',
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
  
  String nameForKind(ZKind kind) {
    if (_isTmdb(kind)) {
      return _providerPrefs?.video == VideoProvider.simkl ? 'Simkl' : 'TMDB';
    }
    return _providerPrefs?.anime == AnimeProvider.mal
        ? 'MyAnimeList'
        : 'AniList';
  }
  
  Future<MediaItem?> canonicalFor(MediaItem sourceItem) async {
    if (ZmodeIds.isZ(sourceItem.url)) return sourceItem; // already canonical
    final title = sourceItem.title.trim();
    if (title.isEmpty) return null;
    final k = switch (sourceItem.type) {
      ProviderType.anime => ZKind.anime,
      ProviderType.movie => ZKind.movie,
      ProviderType.manga => ZKind.manga,
      ProviderType.novel => ZKind.novel,
    };
    try {
      final results = _isTmdb(k)
          ? await _viaVideo((c) => c.search(title))
          : await _viaAnime((c) => c.search(title, k));
      // A MAL id anywhere in the results wins over a title match on an
      // earlier one, the same order [bestTitleMatch] uses — but the title rule
      // is [titleIdentityMatches], not the looser one, and there is no
      // fall-back-to-first-result here at all.
      MediaItem? hit;
      if (sourceItem.malId != null) {
        for (final m in results) {
          if (m.malId != null && m.malId == sourceItem.malId) {
            hit = m;
            break;
          }
        }
      }
      for (final m in results) {
        if (hit != null) break;
        if (titleIdentityMatches(m, title)) hit = m;
      }
      if (hit == null) return null;
      _remember(hit);
      return hit;
    } catch (_) {
      return null;
    }
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

    /// Read this title from a specific catalogue — the tracker you opened it
    /// from — rather than the app-wide choice. Kept from main: the branch this
    /// resolver came from had dropped it, which would have quietly removed the
    /// metadata-provider switch.
    PreferredProvider? prefer,
  }) async {
    final c = ZmodeIds.parseShow(url);
    if (c == null) throw ArgumentError('not a metadata url: $url');
    final sw = Stopwatch()..start();
    final via = _isTmdb(c.kind) ? 'video' : 'anime';
    AppLogger.instance.log(
      '[metadata] detail start kind=${c.kind} via=$via key=${c.key}',
    );
    final d = _isTmdb(c.kind)
        ? await _viaVideo((x) => x.detail(c), prefer: prefer)
        : await _viaAnime((x) => x.detail(c), prefer: prefer);
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
      // copyWith, not a fresh MediaDetail: listing the fields by hand meant
      // every one added later was silently dropped on the way through here,
      // and the page showed a thinner record than the catalogue returned.
      // Restored from main — the hand-written version had come back with the
      // resolver and was quietly losing 24 fields on every manga and novel:
      // score, tags, cast, relations, synonyms, dates, and coverHeaders, which
      // header-locked cover hosts need to render at all.
      return d.copyWith(
        id: m.showId,
        episodes: chapters,
        sourceId: m.sourceId,
      );
    }

    // Video: the catalogue's list has already been painted (onPartial above),
    // so the screen is up. Now let the matched source correct it.
    //
    // The catalogue's episode count is an ANNOUNCEMENT, not an inventory. An
    // airing show's last listed episode is routinely one no source has yet —
    // and tapping it cost a full 36-source sweep that could only ever fail:
    // 23 seconds of frozen UI, measured on device. It also cuts the other way:
    // MAL reports 0 episodes for open-ended shows (One Piece) and Simkl builds
    // no episode list at all, so titles that play perfectly well showed
    // "no episodes available". The source knows what can actually be played.
    //
    // Urls are rewritten back to canonical zm://…/ep/n, so PlaybackResolver
    // still sweeps every source at tap time — the source that supplied the
    // list is not locked in, and resume progress keeps following the title
    // rather than whichever source served it.
    final m = await _matcher.resolve(
      c,
      title: d.title,
      altTitle: d.englishTitle,
      malId: d.malId,
    );
    if (m == null) {
      // Keep the catalogue's list rather than blanking it. Playback sweeps
      // independently now (and with its own ordering, health and per-episode
      // matching), so a Detail-time miss no longer means unplayable — and an
      // empty screen tells the viewer less than a list plus an honest failure
      // on the tap.
      AppLogger.instance.log(
        '[metadata] detail video no source match, keeping catalogue eps '
        '${sw.elapsedMilliseconds}ms',
      );
      return d;
    }
    final srcEpisodes = await _src.episodes(m.showUrl, sourceId: m.sourceId);
    AppLogger.instance.log(
      '[metadata] detail video ${m.sourceId} eps=${srcEpisodes.length} '
      '(catalogue said ${d.episodes.length}) ${sw.elapsedMilliseconds}ms',
    );
    // A source that matched the title but lists nothing (yet) must not wipe
    // the catalogue's list out from under the screen.
    if (srcEpisodes.isEmpty) {
      return d;
    }
    // Union, longest wins: the SOURCE decides what plays, the CATALOGUE
    // decides what exists. Where both have an episode the source's row is
    // used (its titles, thumbnails and dates are real); past the end of the
    // source's list the catalogue's row stays, marked unavailable, so an
    // announced-but-unuploaded episode is still visible and still says why it
    // won't open. Past the end of the CATALOGUE's list the source simply wins
    // outright — which is how MAL's 0-episode long-runners and Simkl get a
    // full list at all.
    final count = d.episodes.length > srcEpisodes.length
        ? d.episodes.length
        : srcEpisodes.length;
    // Resolved once, not per row: a long airing show can leave dozens of
    // rows past the end of the source's list.
    final checked = count > srcEpisodes.length
        ? _src.displayName(m.sourceId)
        : null;
    // The tracker usually knows an episode simply isn't out yet — blaming the
    // source for that would be both wrong and unhelpful. `nextEpisode` is the
    // first one NOT yet aired (AniList reports it directly; MalCatalogue
    // derives it from the broadcast day), so anything at or past it is a
    // release-date matter, not a source gap.
    final firstUnaired = d.nextEpisode;
    final airsAt = d.airingAt;
    return d.copyWith(
      episodes: [
        for (var i = 0; i < count; i++)
          if (i < srcEpisodes.length)
            _canonicalize(srcEpisodes[i], c, i + 1)
          else
            d.episodes[i].copyWith(
              unavailable: _whyMissing(
                i + 1,
                firstUnaired: firstUnaired,
                airsAt: airsAt,
                checkedSource: checked,
              ),
            ),
      ],
    );
  }

  /// Why episode [n] can't be played, in the words the row shows.
  ///
  /// Release date first: if the tracker says this one hasn't aired there is
  /// nothing wrong with anyone's source, and naming a source would send the
  /// viewer off to fix something that isn't broken. Only once it HAS aired is
  /// a missing episode actually the source's gap — and even then we name only
  /// the source we asked, because that's all we checked.
  static String _whyMissing(
    int n, {
    required int? firstUnaired,
    required DateTime? airsAt,
    required String? checkedSource,
  }) {
    if (firstUnaired != null && n >= firstUnaired) {
      // An exact date only for the very next one — anything beyond it would be
      // us guessing at a schedule we were never told.
      if (n == firstUnaired && airsAt != null) return 'Airs ${_shortDate(airsAt)}';
      return 'Not out yet';
    }
    return checkedSource == null ? 'Not available' : 'Not on $checkedSource';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _shortDate(DateTime d) {
    final t = d.toLocal();
    return '${t.day} ${_months[t.month - 1]}';
  }

  /// [e] with its display kept but id/url/number replaced by the canonical,
  /// position-numbered form — see the comment in [detail]. [number] in
  /// particular is read as ground truth by trackers (AniList/MAL/Simkl
  /// scrobbling), filler lookups and skip-time lookups — all keyed by the
  /// canonical episode count, not whatever the source calls it (a source that
  /// restarts numbering per season would otherwise scrobble the wrong
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

  /// Streams for [episodeUrl] from the first source whose streams satisfy
  /// [accept] — one sweep, every candidate, in the usual order.
  ///
  /// Deliberately not on [CatalogueRepository]: only downloading needs it, and
  /// widening that interface would mean touching every implementation and
  /// every test fake for one caller. A source can play perfectly and still be
  /// undownloadable (all-DASH), which is a thing only the caller can judge.
  Future<({List<VideoSource> streams, String sourceId})> sourcesWhere(
    String episodeUrl,
    bool Function(List<VideoSource> streams) accept,
  ) async {
    final r = await _playback.resolveForPlayback(episodeUrl, accept: accept);
    return (streams: r.streams, sourceId: r.match.sourceId);
  }

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
