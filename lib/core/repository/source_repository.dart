import '../aniyomi/aniyomi_filters.dart';
import '../aniyomi/aniyomi_provider.dart';
import '../lnreader/lnreader_manager.dart';
import '../logging/app_logger.dart';
import '../mihon/mihon_filters.dart';
import '../mihon/mihon_manager.dart';
import '../mihon/mihon_provider.dart';
import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/page_content.dart';
import '../models/video_source.dart';
import '../playback/playback_prefs.dart';
import '../playback/source_health_store.dart';
import '../provider/base_provider.dart';
import '../i18n/source_languages.dart';
import '../prefs/source_lang_prefs.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_manager.dart';
import '../provider/reading_provider.dart';
import '../state/active_source_cubit.dart';

/// Facade over the active provider runtime for the UI layer.
/// The active source is driven by [activeSource] so callers can switch at
/// runtime without recreating the repository.
class SourceRepository {
  SourceRepository({
    required ProviderManager manager,
    required CloudStreamManager csManager,
    required AniyomiManager aniManager,
    required ActiveSourceCubit activeSource,
    required PlaybackPrefs prefs,
    MihonManager? mihonManager,
    LnReaderManager? lnrManager,
    // Optional so existing tests construct this unchanged; null simply means
    // "no language filtering", which is also the behaviour for a user who has
    // never picked a language set.
    MangaLangPrefs? mangaLangs,
    AnimeLangPrefs? animeLangs,
  }) : _mangaLangs = mangaLangs,
       _animeLangs = animeLangs,
       _manager = manager,
       _csManager = csManager,
       _aniManager = aniManager,
       _active = activeSource,
       _prefs = prefs,
       // Optional (not `required`) purely so adding manga wiring changes no
       // existing call site — omitting it yields an EMPTY registry, which is
       // exactly the right behaviour anywhere Mihon isn't wired (tests,
       // non-Android): `mihon:` ids simply never resolve, same as any other
       // unknown id. The injector always passes the real one.
       _mihonManager = mihonManager ?? MihonManager(),
       // Novel twin of the above, kept nullable rather than defaulted:
       // LnReaderManager has no cheap no-arg default the way MihonManager
       // does (it's a thin read-through over a Hive box that [init] must
       // open first), so every `_lnrManager` use below is `?.`-guarded
       // instead. Omitting it yields the same "EMPTY registry" behaviour —
       // `lnr:` ids simply never resolve. The injector always passes the
       // real one.
       _lnrManager = lnrManager;

  final ProviderManager _manager;
  final CloudStreamManager _csManager;
  final AniyomiManager _aniManager;
  final MihonManager _mihonManager;
  final LnReaderManager? _lnrManager;
  final ActiveSourceCubit _active;
  final PlaybackPrefs _prefs;

  /// Prefetch cache: `sourceId|episodeUrl` → an in-flight/complete fast
  /// resolution started on the detail screen, so "tap Play" reuses work already
  /// done. Consumed once per key by the next fast [sources] call; never used by
  /// downloads (fast=false).
  final Map<String, ({DateTime at, Future<List<VideoSource>> future})>
  _prefetch = {};
  static const Duration _prefetchTtl = Duration(minutes: 2);

  /// Resolved-source cache: `sourceId|episodeUrl` → the fast-resolved sources +
  /// when they were resolved. Unlike [_prefetch] (consumed once), this PERSISTS,
  /// so re-opening a recently-played episode (Continue Watching, back-out then
  /// resume, a quality switch) replays instantly instead of re-scraping. Short
  /// TTL because stream URLs are signed/expiring — this mirrors CloudStream's
  /// 20-minute link cache. ONLY the fast (playback) path uses it; downloads
  /// (fast=false) always resolve fresh. Cleared by [invalidateSources] when
  /// every mirror stalls (the cached links are likely dead).
  final Map<String, ({DateTime at, List<VideoSource> sources})> _resolved = {};
  static const Duration _resolvedTtl = Duration(minutes: 20);

  /// Search result cache (opt-in via [searchStatus]'s `cache` flag) + in-flight
  /// dedup, so a repeat search or a scope/filter toggle doesn't re-hit every
  /// source. Keyed PER SOURCE (id + query + category + filters), so a newly
  /// added source is never in the cache — it's always searched live. A short TTL
  /// bounds staleness for an updated same-id source, and [syncSearchCache] wipes
  /// the whole cache the moment the loaded-source set changes (add/remove/
  /// enable/disable). Only successful outcomes (ok/empty) are cached — a
  /// transient error/timeout is never remembered, so a failed source retries.
  final Map<String, ({DateTime at, List<MediaItem> items, SourceOutcome outcome})>
  _searchCache = {};
  final Map<String, Future<({List<MediaItem> items, SourceOutcome outcome})>>
  _searchInflight = {};
  static const Duration _searchTtl = Duration(minutes: 3);
  String _searchSourcesSig = '';

  String _prefetchKey(String url, String? sourceId) =>
      '${sourceId ?? _active.state}|$url';

  String _searchKey(
    String sourceId,
    String query,
    String category,
    String? filtersJson,
    int page,
  ) => '$sourceId|${query.trim().toLowerCase()}|$category|'
      '${filtersJson ?? ''}|$page';

  /// Drop the search cache when the set of loaded sources changed since the last
  /// call (a source was added, removed, or enabled/disabled) — so cached results
  /// never outlive a source-list change. Cheap; call once before a search batch.
  void syncSearchCache() {
    final sig = loadedSources.map((s) => s.id).join(',');
    if (sig != _searchSourcesSig) {
      _searchCache.clear();
      _searchInflight.clear();
      _searchSourcesSig = sig;
    }
  }

  /// True for CloudStream source ids (`cs:<name>`), which route to the native
  /// plugin host instead of the JS runtime.
  static bool _isCloudStream(String id) => id.startsWith('cs:');

  /// True for Aniyomi source ids (`ani:<sourceId>`).
  static bool _isAniyomi(String id) => id.startsWith('ani:');

  /// True for Mihon manga source ids (`mihon:<sourceId>`). A separate prefix
  /// from `ani:` on purpose (spec Decision 1) — `sourceTypeOf` hardcodes
  /// `ani:` to anime, so reusing it would type every manga source as anime.
  static bool _isMihon(String id) => id.startsWith('mihon:');

  /// True for LNReader novel source ids (`lnr:<pluginId>`). Novel twin of
  /// [_isMihon] — its own prefix so `sourceTypeOf` can type it novel without
  /// disturbing the `mihon:`/`ani:` lines.
  static bool _isLnReader(String id) => id.startsWith('lnr:');

  /// The currently-active source identifier.
  String get sourceId => _active.state;

  /// All currently-loaded sources (id + display name), for cross-source search
  /// and source labelling. JS providers first (registry order), then any
  /// installed CloudStream sources, then Aniyomi sources.
  ///
  /// NSFW Aniyomi sources are excluded when [PlaybackPrefs.showNsfwAniyomi]
  /// is false so toggling the pref is immediately reflected here.
  /// Installed sources as `{id, name}`, with same-named entries disambiguated
  /// by language.
  ///
  /// Multi-language extensions install one source PER language, each carrying
  /// the same `info.name` — so MangaDex alone showed up as a dozen identical
  /// "MangaDex" chips, an unreadable picker, and a stack of identical result
  /// sections. Only names that actually collide get the suffix, so a
  /// single-language source reads exactly as before.
  List<({String id, String name})> get loadedSources {
    final raw = _rawLoadedSources;
    final counts = <String, int>{};
    for (final s in raw) {
      counts[s.name] = (counts[s.name] ?? 0) + 1;
    }
    return [
      for (final s in raw)
        (
          id: s.id,
          name: (counts[s.name]! > 1 && (s.lang ?? '').isNotEmpty)
              ? '${s.name} (${s.lang!.toUpperCase()})'
              : s.name,
        ),
    ];
  }

  /// The user's enabled language codes for [T], or null when they've never
  /// configured them (or in tests where the prefs aren't registered). Null
  /// means "don't filter" — a language set is only ever applied because the
  /// user picked one, so an untouched install keeps every source it had.
  final MangaLangPrefs? _mangaLangs;
  final AnimeLangPrefs? _animeLangs;

  /// The language set to filter by, mirroring what the sources screens do
  /// (`mihon_repo_tab.dart`): an unset preference falls back to the DEFAULTS,
  /// not to "no filtering". Getting this wrong is why choosing English on the
  /// sources screen still returned Telugu and Hebrew in search — that screen
  /// was showing the default set while the repo filtered by nothing.
  ///
  /// Null only when the prefs object itself is absent (tests), which keeps
  /// every existing test's source list untouched.
  Set<String>? _langsFor(LangPrefs? prefs) {
    if (prefs == null) return null;
    final set = prefs.enabled;
    if (set != null) return set;
    try {
      return defaultSourceLangs();
    } catch (_) {
      // defaultSourceLangs reads the platform locale, which needs a binding.
      return const {'en'};
    }
  }

  /// True when a source declaring [lang] should be used at all, given [enabled].
  /// `sourceLangVisible` already lets blank/`all`/unknown codes through, so a
  /// source can never be hidden with no way to bring it back.
  bool _langOk(String? lang, Set<String>? enabled) =>
      enabled == null || sourceLangVisible(lang ?? '', enabled);

  List<({String id, String name, String? lang})> get _rawLoadedSources => [
    ..._manager.all.map(
      (p) => (id: p.sourceId, name: p.displayName, lang: null),
    ),
    // Only ENABLED CloudStream sources — a disabled source shouldn't be
    // searched (and skipping them trims the search fan-out).
    ..._csManager.enabled.map(
      (p) => (id: p.sourceId, name: p.displayName, lang: null),
    ),
    // Aniyomi sources — NSFW entries filtered when the pref is off.
    ..._aniManager.all
        .where(
          (p) => aniyomiNsfwVisible(p, showNsfwAniyomi: _prefs.showNsfwAniyomi),
        )
        .map(
          (p) => (
            id: p.sourceId,
            name: p.displayName,
            lang: p is AniyomiProvider ? p.info.lang : null,
          ),
        )
        .where((s) => _langOk(s.lang, _langsFor(_animeLangs))),
    // Mihon manga sources. There is no Mihon-specific NSFW pref, so these
    // reuse the general "show NSFW sources" toggle rather than inventing a
    // third one — same default (off), so an 18+ manga source stays hidden
    // until the user opts in, exactly like every other NSFW source.
    ..._mihonManager.all
        .where((p) => !p.info.nsfw || _prefs.nsfwSources)
        .map(
          (p) => (id: p.sourceId, name: p.displayName, lang: p.info.lang),
        )
        // A multi-language extension installs one source PER language, so
        // installing MangaDex registered a dozen of them and search queried
        // every one — Hebrew results for a user who'd chosen English. The
        // sources screen already filtered its list this way; the source list
        // that actually gets searched never did.
        .where((s) => _langOk(s.lang, _langsFor(_mangaLangs))),
    // LNReader novel sources — already `{id, name}` shaped, straight from
    // stored plugin meta (no NSFW concept for these yet).
    if (_lnrManager != null)
      ..._lnrManager.installedSources.map(
        (s) => (id: s.id, name: s.name, lang: null),
      ),
  ];

  /// Base site URL for a source, used to turn a relative item URL into an
  /// absolute web link. Aniyomi stores `SAnime.url` as a path (the native side
  /// requests `baseUrl + anime.url`); CloudStream/JS items are already
  /// absolute, so this returns '' for them.
  String baseUrlFor(String sourceId) {
    // Mihon stores `SManga.url` as a path for the same reason Aniyomi does
    // (the native side requests `baseUrl + manga.url`), so a manga item needs
    // the same relative→absolute treatment before it can be shared/opened.
    final m = _mihonManager.get(sourceId);
    if (m != null) return m.info.baseUrl;
    // LNReader chapter urls are paths too (resolved against the plugin's
    // `site`), same rationale as Mihon above.
    final l = _lnrManager?.get(sourceId);
    if (l != null) return l.site;
    final p = _aniManager.get(sourceId);
    return p is AniyomiProvider ? p.info.baseUrl : '';
  }

  /// Human-friendly name for a source id (falls back to the id itself).
  String displayName(String sourceId) {
    if (_isCloudStream(sourceId)) {
      return _csManager.get(sourceId)?.displayName ?? sourceId;
    }
    if (_isAniyomi(sourceId)) {
      return _aniManager.get(sourceId)?.displayName ?? sourceId;
    }
    if (_isMihon(sourceId)) {
      return _mihonManager.get(sourceId)?.displayName ?? sourceId;
    }
    if (_isLnReader(sourceId)) {
      return _lnrManager?.get(sourceId)?.displayName ?? sourceId;
    }
    return _manager.get(sourceId)?.displayName ?? sourceId;
  }

  /// Returns true when [sourceId] resolves to an installed/enabled provider on
  /// this device. Read-only — does not affect resolution or health.
  /// CS ids use identity-compatible lookup ([resolveCompatible]); Aniyomi and JS
  /// ids use their respective manager registries.
  bool hasSource(String sourceId) {
    if (_isCloudStream(sourceId)) {
      return _csManager.resolveCompatible(sourceId) != null;
    }
    if (_isAniyomi(sourceId)) {
      return _aniManager.get(sourceId) != null;
    }
    if (_isMihon(sourceId)) {
      return _mihonManager.get(sourceId) != null;
    }
    if (_isLnReader(sourceId)) {
      return _lnrManager?.get(sourceId) != null;
    }
    return _manager.get(sourceId) != null;
  }

  /// Resolves the provider for a per-call [id], falling back to the active
  /// source when [id] is null. Lets cross-source items (Continue Watching,
  /// My List, etc.) route to their OWN provider instead of the active one.
  /// CloudStream ids (`cs:<name>`) route to the native plugin host; Aniyomi
  /// ids (`ani:<id>`) route to the Aniyomi manager; all others go to the JS
  /// runtime.
  BaseProvider _providerFor(String? id) {
    final resolved = id ?? _active.state;
    // CloudStream ids carry a `@version@repoTag` suffix that differs between
    // installs, so resolve by provider IDENTITY (exact id first) — otherwise a
    // Watch Together room created on one device can't open on another that has
    // the same provider from a different repo/version.
    final BaseProvider? p;
    if (_isCloudStream(resolved)) {
      p = _csManager.resolveCompatible(resolved);
    } else if (_isAniyomi(resolved)) {
      p = _aniManager.get(resolved);
    } else if (_isMihon(resolved)) {
      p = _mihonManager.get(resolved);
    } else if (_isLnReader(resolved)) {
      p = _lnrManager?.get(resolved);
    } else {
      p = _manager.get(resolved);
    }
    if (p == null) {
      throw StateError('Provider not loaded: $resolved');
    }
    return p;
  }

  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
    String? sourceId,
  }) => _providerFor(
    sourceId,
  ).popular(category: category, dateRange: dateRange, page: page);

  /// CloudStream-style Home: the active provider's own named rows. When the
  /// provider defines `getHome` we render exactly what it returns (empty rows
  /// dropped). When it doesn't, we synthesize the legacy three rows from
  /// [popular] so older providers keep working. Each underlying fetch is
  /// fail-safe — one broken row never kills the others.
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    final provider = _providerFor(sourceId);

    final sections = await provider.getHome(category: category);
    if (sections != null) {
      return sections.where((s) => s.items.isNotEmpty).toList();
    }

    // Fallback for providers without getHome.
    final results = await Future.wait([
      provider
          .popular(category: category, dateRange: 1)
          .catchError((_) => <MediaItem>[]),
      provider
          .popular(category: category, dateRange: 30)
          .catchError((_) => <MediaItem>[]),
      provider
          .popular(category: category, dateRange: 0)
          .catchError((_) => <MediaItem>[]),
    ]);
    final fallback = <HomeSection>[
      HomeSection(title: 'Trending Now', items: results[0]),
      HomeSection(title: 'Popular This Month', items: results[1]),
      HomeSection(title: 'All-Time Favorites', items: results[2]),
    ];
    return fallback.where((s) => s.items.isNotEmpty).toList();
  }

  /// Fetches the next [page] of a paginable Home row (the "See all" grid's
  /// infinite scroll), routing on [BrowseMore.kind]:
  ///   * `ani_popular` → the Aniyomi/JS provider's `popular(page:)`
  ///   * `ani_latest`  → the Aniyomi provider's `latest(page:)`
  ///   * `mihon_popular` → the Mihon manga provider's `popular(page:)`
  ///   * `mihon_latest`  → the Mihon manga provider's `latest(page:)`
  ///   * `lnr_popular` → the LNReader novel provider's `popular(page:)`
  ///   * `cs_mainpage` → the CloudStream provider's `browseMainPage(id, page)`
  ///
  /// Never throws — any failure (unknown kind, wrong provider type, provider
  /// error) degrades to an empty list so the caller just stops the scroll.
  Future<List<MediaItem>> browseMore(BrowseMore more, int page) async {
    try {
      final p = _providerFor(more.sourceId);
      switch (more.kind) {
        case 'ani_popular':
          return p.popular(page: page);
        case 'ani_latest':
          return p is AniyomiProvider ? p.latest(page: page) : const [];
        case 'mihon_popular':
          return p.popular(page: page);
        case 'mihon_latest':
          return p is MihonProvider ? p.latest(page: page) : const [];
        case 'lnr_popular':
          return p.popular(page: page);
        case 'cs_mainpage':
          return (p is CloudStreamProvider && more.categoryId != null)
              ? p.browseMainPage(more.categoryId!, page)
              : const [];
        default:
          return const [];
      }
    } catch (_) {
      return const [];
    }
  }

  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) => _providerFor(sourceId).search(query, 1, category: category);

  /// Status-reporting search for the source-health feature (search ordering +
  /// the "Test sources" screen). Unlike [search] it surfaces whether a source
  /// FAILED vs simply returned nothing, so the caller can record health
  /// correctly (empty-without-error is ALIVE, only error/timeout is dead).
  ///
  ///  - `outcome` is one of [SourceOutcome] (ok / empty / timeout / blocked /
  ///    error). It NEVER throws — failures are mapped to an outcome.
  ///  - For JS providers, [BaseProvider.search] throws on error (caught here);
  ///    an empty list is reported as [SourceOutcome.empty].
  ///  - For CloudStream sources it routes to [CloudStreamProvider.searchWithStatus]
  ///    (native `searchStatus`), which distinguishes timeout/error from empty.
  ///  - For Aniyomi sources, [filtersJson] (when non-null) is forwarded to the
  ///    provider so the native bridge can apply the user's filter selection.
  ///    CloudStream and JS paths never receive it.
  ///  - Mihon manga sources forward [filtersJson] the same way (their bridge
  ///    takes the identical `filters` argument).
  ///
  /// CF suppression is reused automatically: JS search goes through the
  /// provider-manager `search` path (suppresses the solver) and CS search goes
  /// through native `searchStatus` (bumps `CfClearance.searchDepth`).
  /// [cache] opts this call into the short-TTL search cache + in-flight dedup
  /// (see [_searchCache]). Off by default so probes/tests and filter-apply always
  /// hit the network fresh; the cross-source search fan-out passes `cache: true`.
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) {
    final resolved = sourceId ?? _active.state;
    if (!cache) {
      return _searchStatusUncached(
        query,
        category: category,
        sourceId: resolved,
        filtersJson: filtersJson,
        page: page,
      );
    }
    final key = _searchKey(resolved, query, category, filtersJson, page);
    final hit = _searchCache[key];
    if (hit != null && DateTime.now().difference(hit.at) < _searchTtl) {
      return Future.value((items: hit.items, outcome: hit.outcome));
    }
    final inflight = _searchInflight[key];
    if (inflight != null) return inflight; // share an already-running fetch
    final future = _searchStatusUncached(
      query,
      category: category,
      sourceId: resolved,
      filtersJson: filtersJson,
      page: page,
    ).then((res) {
      // Cache only successful outcomes so a transient failure isn't remembered.
      if (res.outcome == SourceOutcome.ok ||
          res.outcome == SourceOutcome.empty) {
        _searchCache[key] = (at: DateTime.now(), items: res.items, outcome: res.outcome);
      }
      return res;
    });
    _searchInflight[key] = future;
    future.whenComplete(() => _searchInflight.remove(key));
    return future;
  }

  Future<({List<MediaItem> items, SourceOutcome outcome})> _searchStatusUncached(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    int page = 1,
  }) async {
    final resolved = sourceId ?? _active.state;
    try {
      if (_isCloudStream(resolved)) {
        final p = _csManager.get(resolved);
        if (p is! CloudStreamProvider) {
          return (items: const <MediaItem>[], outcome: SourceOutcome.error);
        }
        final r = await p.searchWithStatus(query);
        if (r.error != null) {
          return (items: r.items, outcome: _outcomeFromError(r.error!));
        }
        return (
          items: r.items,
          outcome: r.items.isEmpty ? SourceOutcome.empty : SourceOutcome.ok,
        );
      }
      final provider = _providerFor(resolved);
      final items = (_isAniyomi(resolved) && provider is AniyomiProvider)
          ? await provider.search(
              query,
              page,
              category: category,
              filtersJson: filtersJson,
            )
          : (_isMihon(resolved) && provider is MihonProvider)
          ? await provider.search(
              query,
              page,
              category: category,
              filtersJson: filtersJson,
            )
          : await provider.search(query, page, category: category);
      return (
        items: items,
        outcome: items.isEmpty ? SourceOutcome.empty : SourceOutcome.ok,
      );
    } catch (e) {
      return (items: const <MediaItem>[], outcome: _outcomeFromError('$e'));
    }
  }

  /// Returns the typed Aniyomi filter schema for [sourceId], or an empty list
  /// for non-Aniyomi sources or when the source has no filters.
  Future<List<AniyomiFilter>> aniFilters(String sourceId) async {
    if (!_isAniyomi(sourceId)) return const [];
    final p = _providerFor(sourceId);
    return p is AniyomiProvider ? p.getFilters() : const [];
  }

  /// Mihon twin of [aniFilters] — the typed manga filter schema for [sourceId],
  /// or an empty list for non-Mihon sources / sources with no filters. Separate
  /// method (and a separate `MihonFilter` type) rather than a shared one, per
  /// spec Decision 3: the anime path never changes for a manga change.
  Future<List<MihonFilter>> mihonFilters(String sourceId) async {
    if (!_isMihon(sourceId)) return const [];
    final p = _providerFor(sourceId);
    return p is MihonProvider ? p.getFilters() : const [];
  }

  /// Classifies a failure message into a [SourceOutcome]. Timeouts and CF/WAF
  /// blocks get their own reason; everything else is a generic error.
  static SourceOutcome _outcomeFromError(String message) {
    final m = message.toLowerCase();
    if (m.contains('timed out') ||
        m.contains('timeout') ||
        m.contains('deadline')) {
      return SourceOutcome.timeout;
    }
    if (m.contains('cloudflare') ||
        m.contains('cf_clearance') ||
        m.contains('challenge') ||
        m.contains('403') ||
        m.contains('forbidden') ||
        m.contains('blocked') ||
        m.contains('captcha')) {
      return SourceOutcome.blocked;
    }
    return SourceOutcome.error;
  }

  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) => _providerFor(sourceId).getDetail(url, category: category);

  /// Drop the native source HTTP cache (Mihon/Aniyomi) so a subsequent fetch is
  /// fresh — used by pull-to-refresh. No-op on platforms/sources without it.
  Future<void> clearHttpCache() => clearMihonHttpCache();

  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) => _providerFor(sourceId).getEpisodes(url, category: category);

  /// The links resolved SO FAR for [episodeUrl], plus whether more may arrive.
  ///
  /// A fast [sources] call returns on the first usable link while the native
  /// resolve keeps running, so mirrors needing an extra round-trip land shortly
  /// afterwards. This reads that growing set without starting any work.
  ///
  /// CloudStream sources only — every other provider resolves in one shot, so
  /// there is nothing to poll. Those (and any failure) report `done: true` with
  /// no sources, which tells a caller to simply stop asking.
  Future<({List<VideoSource> sources, bool done})> polledSources(
    String episodeUrl, {
    String? sourceId,
  }) async {
    final provider = _providerFor(sourceId);
    if (provider is! CloudStreamProvider) {
      return (sources: const <VideoSource>[], done: true);
    }
    try {
      return await provider.pollVideoSources(episodeUrl);
    } catch (_) {
      // Never surfaced: the caller already has a playable list.
      return (sources: const <VideoSource>[], done: true);
    }
  }

  /// Resolve playable sources. [fast] (playback) returns as soon as the first
  /// link(s) are ready; downloads leave it false to get every mirror. A fast
  /// call reuses a fresh [prefetch] for the same episode when one exists.
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    if (fast) {
      final key = _prefetchKey(episodeUrl, sourceId);
      // 1. One-shot prefetch started on the detail screen.
      final entry = _prefetch.remove(key);
      if (entry != null && DateTime.now().difference(entry.at) < _prefetchTtl) {
        final cached = await entry.future;
        // Fall through to a fresh resolve only if the prefetch came back empty
        // (or had failed → []), so this is never worse than no prefetch.
        if (cached.isNotEmpty) {
          _resolved[key] = (at: DateTime.now(), sources: cached);
          return cached;
        }
      }
      // 2. Persistent TTL cache → instant re-open of a recent episode.
      final hit = _resolved[key];
      if (hit != null &&
          hit.sources.isNotEmpty &&
          DateTime.now().difference(hit.at) < _resolvedTtl) {
        return hit.sources;
      }
      // 3. Fresh resolve → cache it for the next re-open.
      final fresh = await _providerFor(
        sourceId,
      ).getVideoSources(episodeUrl, fast: true);
      if (fresh.isNotEmpty) {
        _resolved[key] = (at: DateTime.now(), sources: fresh);
      }
      return fresh;
    }
    return _providerFor(sourceId).getVideoSources(episodeUrl, fast: fast);
  }

  /// Manga leaf — ordered page images for [chapterUrl]. No expiry cache here:
  /// unlike stream links, page image URLs don't rot within a session, so this
  /// never touches [_prefetch]/[_resolved]. Throws [UnsupportedError] if the
  /// resolved source isn't a [ReadingProvider] (e.g. CloudStream/Aniyomi) —
  /// unreachable through mode-filtered UI, but a hard guard regardless.
  Future<List<PageImage>> pages(String chapterUrl, {String? sourceId}) {
    final p = _providerFor(sourceId);
    if (p is! ReadingProvider) {
      throw UnsupportedError('${p.sourceId} does not support reading content');
    }
    // ReadingProvider is deliberately unrelated to BaseProvider (Task 3), so
    // the `is!` check above doesn't statically promote — cast explicitly.
    return (p as ReadingProvider).getPages(chapterUrl);
  }

  /// Novel leaf — chapter text for [chapterUrl]. Same no-cache rationale and
  /// [ReadingProvider] guard as [pages].
  Future<ChapterText> chapterText(String chapterUrl, {String? sourceId}) {
    final p = _providerFor(sourceId);
    if (p is! ReadingProvider) {
      throw UnsupportedError('${p.sourceId} does not support reading content');
    }
    return (p as ReadingProvider).getText(chapterUrl);
  }

  /// Drop the cached fast-resolution for an episode so the next [sources] call
  /// re-scrapes fresh links. Called when every mirror stalls — the cached links
  /// have likely expired. No-op when the episode isn't cached (e.g. downloads).
  ///
  /// [includePrefetch] also drops an in-flight/complete prefetch for the same
  /// episode. Off by default: the stall path wants the prefetch kept, since it
  /// may be the thing about to succeed. A user asking to reload links wants it
  /// gone — the next fast call consumes the prefetch before it ever looks at
  /// [_resolved], so leaving it would hand back the same stale links and make
  /// the reload look like it did nothing.
  void invalidateSources(
    String episodeUrl, {
    String? sourceId,
    bool includePrefetch = false,
  }) {
    final key = _prefetchKey(episodeUrl, sourceId);
    final hadResolved = _resolved.remove(key) != null;
    final hadPrefetch = includePrefetch && _prefetch.remove(key) != null;
    // Logged because there is otherwise no way to tell a working reload from a
    // no-op: the caches are in-memory, and a reload that cleared nothing looks
    // exactly like one that cleared everything.
    AppLogger.instance.log(
      '[links] invalidate ${_short(episodeUrl)} '
      'resolved=${hadResolved ? "cleared" : "none"} '
      'prefetch=${hadPrefetch ? "cleared" : includePrefetch ? "none" : "kept"}',
    );
  }

  /// Tail of a URL — enough to tell two episodes apart in a log without
  /// printing signed query strings.
  static String _short(String url) {
    final path = url.split('?').first;
    return path.length <= 42 ? path : '…${path.substring(path.length - 42)}';
  }

  /// Fire-and-forget background resolution for [episodeUrl] (the episode the
  /// detail screen's Play will start) so the actual play is near-instant. Safe
  /// to call repeatedly — deduped within [_prefetchTtl], errors swallowed.
  void prefetch(String episodeUrl, {String? sourceId}) {
    final key = _prefetchKey(episodeUrl, sourceId);
    final existing = _prefetch[key];
    if (existing != null &&
        DateTime.now().difference(existing.at) < _prefetchTtl) {
      return;
    }
    final future = _providerFor(sourceId)
        .getVideoSources(episodeUrl, fast: true)
        .catchError((_) => <VideoSource>[]);
    _prefetch[key] = (at: DateTime.now(), future: future);
  }
}
