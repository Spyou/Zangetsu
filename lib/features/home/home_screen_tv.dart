import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/cache/app_image_cache.dart';
import '../../core/di/injector.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/ui/global_messenger.dart';
import '../../core/ui/native_cover_provider.dart';
import '../../core/metadata/title_logo_service.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/models/episode.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/repository/source_repository.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/featured_hero.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/media_info_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../auth/auth_cubit.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/ui/source_switcher.dart';
import '../detail/detail_screen.dart';
import '../player/tv_playback_launch.dart';
import '../search/browse_sources_screen.dart';
import '../sources/providers_hub_screen.dart';
import 'home_screen.dart' show HomeLoadedEmptyView;
import 'see_all_screen.dart';
import 'cubit/home_cubit.dart';

part 'home_screen_tv_rail.dart';
part 'home_screen_tv_continue.dart';
part 'home_screen_tv_hero.dart';

/// TV Home: a full-screen vertically-scrolling layout with the phone's real
/// [FeaturedHero] banner followed by horizontal poster rails (one per section).
/// The hero's action buttons are wrapped in [TvFocusable] for D-pad + OK
/// navigation; the phone render of [FeaturedHero] is byte-identical (the
/// [FeaturedHero.wrapButton] param defaults to null on phone).
class HomeScreenTv extends StatefulWidget {
  const HomeScreenTv({super.key});

  @override
  State<HomeScreenTv> createState() => _HomeScreenTvState();
}

class _HomeScreenTvState extends State<HomeScreenTv> {
  /// Per-item hero metadata cache (genres + episode count). Mirrors the phone's
  /// _metaCache; futures are stored so carousel rotation never re-fetches.
  final Map<String, Future<HeroMeta?>> _metaCache = {};

  /// tvOS: defer the Hive listenable until after the shell's first frame lands.
  bool _historyLive = !isAppleTv;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (isAppleTv) setState(() => _historyLive = true);
      final cubit = context.read<HomeCubit>();
      if (cubit.state.sections == null && !cubit.state.loading) {
        cubit.load();
      }
      unawaited(_warmStreamingHomeCaches());
    });
  }

  /// Prefetch both Anime and Movie/TV metadata home rows in parallel so the
  /// rail toggle swaps instantly — same effective behaviour as phone once splash
  /// has finished loading providers.
  Future<void> _warmStreamingHomeCaches() async {
    if (!ZModePrefs.enabled || !sl.isRegistered<MetadataRepository>()) {
      return;
    }
    final meta = sl<MetadataRepository>();
    await Future.wait([
      meta.ensureHomeCached(ZKind.anime),
      meta.ensureHomeCached(ZKind.movie),
    ]);
    if (!mounted) return;
    context.read<HomeCubit>().primeStreamKindCacheFromMetadata();
  }

  // ── Navigation helpers ────────────────────────────────────────────────────

  /// Open the Detail screen — mirrors phone's _HomeViewState._openDetail.
  void _openDetail(MediaItem item) {
    Navigator.push(context, DetailScreen.route(item));
  }

  /// Begin playback from scratch — mirrors phone's _HomeViewState._playFeatured.
  /// TV uses the native ExoPlayer player, which takes an episode LIST (not a
  /// resolver), so resolve the episodes first, then open it.
  Future<void> _play(MediaItem item) async {
    final category =
        sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    List<Episode> episodes;
    try {
      episodes = await sl<CatalogueRepository>().episodes(
        item.url,
        sourceId: item.sourceId,
      );
    } catch (_) {
      episodes = const [];
    }
    if (!mounted || episodes.isEmpty) return;
    resolveSources(String u) => sl<CatalogueRepository>().sources(
      u,
      sourceId: item.sourceId,
      fast: true,
    );
    await launchTvPlayback(
      context: context,
      sourceId: item.sourceId,
      episodes: episodes,
      startIndex: 0,
      resume: sl<ResumeStore>(),
      resolveSources: resolveSources,
      showUrl: item.url,
      showTitle: item.title,
      cover: item.cover,
      coverHeaders: item.coverHeaders,
      category: category,
      availableCategories: [
        if ((item.subCount ?? 0) > 0) 'sub',
        if ((item.dubCount ?? 0) > 0) 'dub',
      ],
      malId: item.malId,
      scrobbleTitle: item.type == ProviderType.anime ? item.title : null,
      tmdbId: item.tmdbId,
      tmdbIsTv: item.tmdbIsTv,
    );
    if (mounted) setState(() {});
  }

  /// Resume a Continue Watching entry — resolve its episodes, then open the
  /// ExoPlayer player at the saved episode (it seeks to the stored position on
  /// load via ResumeStore).
  Future<void> _resume(HistoryEntry e) async {
    List<Episode> episodes;
    try {
      episodes = await sl<CatalogueRepository>().episodes(
        e.showUrl,
        category: e.category,
        sourceId: e.sourceId,
      );
    } catch (_) {
      episodes = const [];
    }
    if (!mounted || episodes.isEmpty) return;
    var idx = episodes.indexWhere((ep) => ep.id == e.episodeId);
    if (idx < 0) idx = 0;
    resolveSources(String u) =>
        sl<CatalogueRepository>().sources(u, sourceId: e.sourceId, fast: true);
    await launchTvPlayback(
      context: context,
      sourceId: e.sourceId,
      episodes: episodes,
      startIndex: idx,
      resume: sl<ResumeStore>(),
      resolveSources: resolveSources,
      showUrl: e.showUrl,
      showTitle: e.showTitle,
      cover: e.cover,
      coverHeaders: e.coverHeaders,
      category: e.category,
      malId: e.malId,
      scrobbleTitle: e.malId != null ? e.showTitle : null,
    );
    if (mounted) setState(() {});
  }

  // ── Hero helpers ──────────────────────────────────────────────────────────

  /// True if [m] is in the user's My List. Returns false when the store is
  /// unavailable (e.g. test environments where sl is not configured).
  bool _inList(MediaItem m) {
    try {
      return sl<MyListStore>().contains(m);
    } catch (_) {
      return false;
    }
  }

  /// Genres + episode count for the hero banner, lazily fetched and cached.
  /// Metadata (`zm://`) rows already carry genres + counts on the [MediaItem]
  /// — skip [CatalogueRepository.detail] there or every stream-kind swap would
  /// re-match the title on AniKoto and pull the full episode list.
  Future<HeroMeta?> _heroMeta(MediaItem m) =>
      _metaCache.putIfAbsent('${m.sourceId}:${m.id}', () async {
        if (ZmodeIds.isZ(m.url)) {
          return HeroMeta(
            genres: m.genres,
            episodeCount: m.subCount ?? 0,
          );
        }
        try {
          final d = await sl<CatalogueRepository>().detail(
            m.url,
            sourceId: m.sourceId,
          );
          return HeroMeta(
            genres: d.genres,
            episodeCount: d.episodes.length,
            year: d.year,
          );
        } catch (_) {
          return null;
        }
      });

  void _openBrowseSources() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const BrowseSourcesScreen(),
      ),
    );
  }

  /// Open the full-grid "See All" view of a browse row.
  /// to the TV variant when [AppMode.isTv]; a paginable row (Aniyomi
  /// popular/latest, CloudStream mainPage) carries a `more` descriptor that
  /// drives infinite scroll, everything else stays a fixed list.
  void _openSeeAll(HomeSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeeAllScreen(
          title: section.title,
          items: section.items,
          onTap: _openDetail,
          onLongPress: _showInfo,
          // Pagination isn't part of CatalogueRepository — go to whichever
          // repository owns the row: metadata providers stamp the Z Mode
          // source id, everything else is a real source.
          onLoadMore: section.more == null
              ? null
              : (page) => section.more!.sourceId == ZmodeIds.sourceId
                    ? sl<MetadataRepository>().browseMore(section.more!, page)
                    : sl<SourceRepository>().browseMore(section.more!, page),
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  String _typeLabel(AppLocalizations l10n, ProviderType t) =>
      t == ProviderType.movie ? l10n.movieLabel : l10n.anime;

  Future<MediaDetail?> _detailOf(String url, String sourceId) async {
    try {
      return await sl<CatalogueRepository>().detail(url, sourceId: sourceId);
    } catch (_) {
      return null;
    }
  }

  /// Netflix-style long-press info card for a browse-row item — same sheet the
  /// phone home opens on long-press. Held OK on [TvFocusable] is the TV path.
  void _showInfo(MediaItem item) {
    showMediaInfoSheet(
      context,
      title: item.title,
      englishTitle: item.englishTitle,
      cover: item.cover,
      headers: item.coverHeaders,
      typeLabel: _typeLabel(context.l10n, item.type),
      subCount: item.subCount,
      dubCount: item.dubCount,
      detail: _detailOf(item.url, item.sourceId),
      inMyList: _inList(item),
      onPlay: () => _play(item),
      onOpenDetail: () => _openDetail(item),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: item,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _inList(item);
      },
    );
  }

  /// Long-press info card for a Continue Watching item — Resume + Remove + My
  /// List, matching the phone home continue long-press.
  void _showContinueInfo(HistoryEntry e) {
    final stub = MediaItem(
      id: e.showId,
      title: e.showTitle,
      cover: e.cover,
      coverHeaders: e.coverHeaders,
      url: e.showUrl,
      type: ProviderType.anime,
      sourceId: e.sourceId,
    );
    final pct = (e.progress * 100).round();
    showMediaInfoSheet(
      context,
      title: e.showTitle,
      cover: e.cover,
      headers: e.coverHeaders,
      detail: _detailOf(e.showUrl, e.sourceId),
      inMyList: _inList(stub),
      playLabel: context.l10n.resume,
      progress: e.progress,
      progressLabel: e.episodeNumber != null
          ? context.l10n.episodeWatchedPct(e.episodeNumber!.toInt(), pct)
          : context.l10n.percentWatched(pct),
      onPlay: () => _resume(e),
      onOpenDetail: () => _openDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _inList(stub);
      },
      onRemoveFromContinue: () async {
        try {
          await sl<WatchHistory>().remove(e.sourceId, e.showId);
        } catch (_) {
          showGlobalSnack("Couldn't remove from Continue Watching");
          return;
        }
        if (mounted) setState(() {});
      },
    );
  }

  /// Button decorator injected into [FeaturedHero.wrapButton]: wraps each hero
  /// action button with [TvFocusable] so it is D-pad focusable and OK-selectable.
  /// [autofocus] is true only for the primary Play button.
  Widget _tvWrapButton(
    Widget child,
    VoidCallback onTap, {
    bool autofocus = false,
    String? semanticLabel,
  }) {
    return TvFocusable(
      autofocus: autofocus,
      variant: TvFocusVariant.float,
      scale: 1.06,
      onTap: onTap,
      semanticLabel: semanticLabel,
      // The button's own label Text is baked into child — exclude it so
      // TalkBack only hears it once (from semanticLabel above).
      child: semanticLabel == null ? child : ExcludeSemantics(child: child),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HomeCubit>().state;
    final sections = state.sections ?? const <HomeSection>[];

    // Nothing installed for this mode. The phone shows _NoSourcesGuide here;
    // TV used to fall through and render an empty scroll view — a blank pane
    // with no hint, which is what every new user sees now that the app ships
    // no sources of its own. Give it the same guide plus a focusable CTA, so
    // the D-pad has somewhere to land instead of nowhere.
    // Fail open when the cubit isn't wired up (widget tests pump this screen
    // with only Home/Auth registered) — same reasoning as `hasSourcesFor`,
    // which returns true on error so a half-initialised app never shows a
    // false "no sources" screen. Production always has it.
    final mode = sl.isRegistered<ContentModeCubit>()
        ? sl<ContentModeCubit>().state
        : null;
    // Metadata-first Home browse doesn't require installed extensions. Match
    // mobile: only show the no-sources guide in source-only mode (tests).
    if (mode != null && !ZModePrefs.enabled && !hasSourcesFor(mode)) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: _TvNoSourcesGuide(mode: mode),
      );
    }

    final repo = sl<CatalogueRepository>();
    final loadedEmpty =
        !state.loading &&
        state.sections != null &&
        state.sections!.isEmpty;
    final activeId = context.watch<ActiveSourceCubit>().state;
    final noSourceForMode = ZModePrefs.enabled
        ? false
        : switch (mode) {
            ContentMode.manga => !activeId.startsWith('mihon:'),
            ContentMode.novel => !activeId.startsWith('lnr:'),
            ContentMode.anime => false,
            null => false,
          };

    // Continue Watching — same login-gated local history the phone home uses.
    final loggedIn = context.watch<AuthCubit>().state.isLoggedIn;

    if (noSourceForMode || loadedEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: HomeLoadedEmptyView(
          offline: state.offline,
          mode: mode ?? ContentMode.anime,
          sourceName: repo.displayName(repo.sourceId),
          onRetry: () => context.read<HomeCubit>().load(reset: true),
          onInstallSources: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ProvidersHubScreen(),
            ),
          ),
          cloudflareUrl: state.cloudflareUrl,
          onSolveCloudflare: state.cloudflareUrl == null
              ? null
              : () async {
                  // Mihon Cloudflare solve — same path as phone Home.
                  await MihonExtensionService.solveCloudflare(
                    state.cloudflareUrl!,
                  );
                  if (context.mounted) {
                    context.read<HomeCubit>().load(reset: true);
                  }
                },
        ),
      );
    }

    Widget historyBody(List<HistoryEntry> history) {
      return ValueListenableBuilder<int>(
        valueListenable: ZModePrefs.revision,
        builder: (context, _, _) {
          return ValueListenableBuilder<int>(
            valueListenable: context.read<HomeCubit>().streamCatalogRevision,
            builder: (context, _, _) {
              final cubit = context.read<HomeCubit>();
              final kind = ZModePrefs.streamKind;
              Widget catalog(StreamKind k) {
                final visible = k == kind;
                final rows = cubit.sectionsFor(k) ??
                    (visible ? sections : const <HomeSection>[]);
                return ExcludeFocus(
                  excluding: !visible,
                  child: TickerMode(
                    enabled: visible,
                    child: KeyedSubtree(
                      key: ValueKey('tv-home-catalog-$k'),
                      child: _catalogScroll(
                        rows,
                        history,
                        loading: visible && state.loading,
                        autofocus: visible,
                      ),
                    ),
                  ),
                );
              }

              final haveBoth = cubit.sectionsFor(StreamKind.anime) != null &&
                  cubit.sectionsFor(StreamKind.movie) != null;
              if (haveBoth) {
                return IndexedStack(
                  index: kind == StreamKind.movie ? 1 : 0,
                  sizing: StackFit.expand,
                  children: [
                    catalog(StreamKind.anime),
                    catalog(StreamKind.movie),
                  ],
                );
              }
              return catalog(kind);
            },
          );
        },
      );
    }

    final body = (loggedIn && _historyLive && Hive.isBoxOpen(WatchHistory.boxName))
        ? ValueListenableBuilder(
            valueListenable: Hive.box<Map>(WatchHistory.boxName).listenable(),
            builder: (context, _, _) =>
                historyBody(sl<WatchHistory>().recent()),
          )
        : historyBody(const <HistoryEntry>[]);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: body,
    );
  }

  Widget _catalogScroll(
    List<HomeSection> sections,
    List<HistoryEntry> history, {
    required bool loading,
    required bool autofocus,
  }) {
    final heroItems =
        sections.isNotEmpty ? sections.first.items : const <MediaItem>[];
    final heroItem = heroItems.isNotEmpty ? heroItems.first : null;
    return CustomScrollView(
      slivers: [
        if (heroItem != null)
          SliverToBoxAdapter(
            child: _TvHero(
              items: heroItems.take(6).toList(),
              inListOf: _inList,
              metaOf: _heroMeta,
              onPlay: _play,
              onInfo: _openDetail,
              onToggleList: (item) => showListStatusSheet(
                context,
                item: item,
                onChanged: () {
                  if (mounted) setState(() {});
                },
              ),
              wrapButton: _tvWrapButton,
              onBrowseSources: _openBrowseSources,
            ),
          ),
        if (history.isNotEmpty)
          SliverToBoxAdapter(
            child: _TvContinueRail(
              history: history,
              onResume: _resume,
              onLongPress: _showContinueInfo,
              firstAutofocus: autofocus && heroItem == null && !loading,
            ),
          ),
        for (var i = 0; i < sections.length; i++)
          SliverToBoxAdapter(
            child: TvRail(
              section: sections[i],
              onTap: _openDetail,
              onLongPress: _showInfo,
              onSeeAll: () => _openSeeAll(sections[i]),
              firstAutofocus: autofocus &&
                  heroItem == null &&
                  history.isEmpty &&
                  i == 0 &&
                  !loading,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 48)),
      ],
    );
  }
}

/// TV twin of the phone's `_NoSourcesGuide` — shown when nothing is installed
/// for the current mode. Same wording, sized for a 10-foot screen, and its
/// button is a [TvFocusable] with autofocus so the D-pad lands on it instead of
/// on an empty screen with nothing to reach.
class _TvNoSourcesGuide extends StatelessWidget {
  const _TvNoSourcesGuide({required this.mode});

  final ContentMode mode;

  @override
  Widget build(BuildContext context) {
    final (icon, _) = switch (mode) {
      ContentMode.anime => (Icons.live_tv_rounded, 'shows'),
      ContentMode.manga => (Icons.auto_stories_rounded, 'manga'),
      ContentMode.novel => (Icons.menu_book_rounded, 'novels'),
    };
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 54, color: AppColors.accent),
          ),
          const SizedBox(height: 24),
          Text(
            l10n.noModeSourcesYet(contentModeLabel(l10n, mode)),
            textAlign: TextAlign.center,
            style: AppText.headline.copyWith(fontSize: 26),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.addSourceFromProvidersHint(contentModeContentNoun(l10n, mode)),
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 30),
          TvFocusable(
            autofocus: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const BrowseSourcesScreen(),
              ),
            ),
            // ExcludeFocus so the D-pad stops on the TvFocusable itself, not on
            // the button inside it — same reason the TV onboarding buttons do.
            child: ExcludeFocus(
              child: SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const BrowseSourcesScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 22),
                  label: Text(l10n.browseSources),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    textStyle: AppText.button.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
