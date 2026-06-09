import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/continue_card.dart';
import '../../core/ui/featured_carousel.dart';
import '../../core/ui/featured_hero.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/media_info_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/row_skeleton.dart';
import '../../core/ui/source_switcher.dart';
import '../auth/auth_cubit.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';
import 'cubit/home_cubit.dart';
import 'see_all_screen.dart';

/// Provides the [HomeCubit] (which owns the three browse rows + the carousel's
/// trending source) and kicks off the first load. The view itself stays
/// Stateful for the per-item lazy hero-description cache and the navigation
/// helpers.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Use the shared singleton so the splash can warm it before this mounts.
    return BlocProvider.value(value: sl<HomeCubit>(), child: const _HomeView());
  }
}

class _HomeView extends StatefulWidget {
  const _HomeView();

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView> {
  final _repo = sl<SourceRepository>();
  final _myList = sl<MyListStore>();

  /// Hero metadata cache: key = "sourceId:id". Futures are stored so they're
  /// never re-fetched on carousel rotation; pre-warmed when hero items load.
  final Map<String, Future<HeroMeta?>> _metaCache = {};
  bool _heroPrewarmed = false;

  @override
  void initState() {
    super.initState();
    // The splash usually pre-warms the rows; only fetch here if it didn't
    // (e.g. first run right after onboarding, or a source with no warm yet).
    final cubit = context.read<HomeCubit>();
    if (cubit.state.sections == null && !cubit.state.loading) cubit.load();
  }

  /// Genres + episode count for the hero banner (lazily fetched, cached).
  Future<HeroMeta?> _heroMeta(MediaItem m) => _metaCache.putIfAbsent(
    '${m.sourceId}:${m.id}',
    () async {
      final d = await _detailOf(m.url, m.sourceId);
      if (d == null) return null;
      return HeroMeta(
        genres: d.genres,
        episodeCount: d.episodes.length,
        year: d.year,
      );
    },
  );

  /// Fire all hero items' metadata up front so banners are ready (and rotated
  /// slides are instant) instead of fetching one-at-a-time on display.
  void _prewarmHeroMeta(List<MediaItem> items) {
    if (_heroPrewarmed || items.isEmpty) return;
    _heroPrewarmed = true;
    for (final it in items) {
      _heroMeta(it);
    }
  }

  void _openDetail(MediaItem item) {
    Navigator.push(
      context,
      DetailScreen.route(item),
    ).then((_) {
      // Refresh Continue Watching + My List row when returning from detail.
      if (mounted) setState(() {});
    });
  }

  String _typeLabel(ProviderType t) =>
      t == ProviderType.movie ? 'Movie' : 'Anime';

  Future<MediaDetail?> _detailOf(String url, String sourceId) async {
    try {
      return await _repo.detail(url, sourceId: sourceId);
    } catch (_) {
      return null;
    }
  }

  /// Netflix-style long-press info card for a browse-row item.
  void _showInfo(MediaItem item) {
    showMediaInfoSheet(
      context,
      title: item.title,
      englishTitle: item.englishTitle,
      cover: item.cover,
      headers: item.coverHeaders,
      typeLabel: _typeLabel(item.type),
      subCount: item.subCount,
      dubCount: item.dubCount,
      detail: _detailOf(item.url, item.sourceId),
      inMyList: _myList.contains(item),
      onPlay: () => _playFeatured(item),
      onOpenDetail: () => _openDetail(item),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: item,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(item);
      },
    );
  }

  /// Long-press info card for a Continue Watching item — adds Resume + Remove.
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
      inMyList: _myList.contains(stub),
      playLabel: 'Resume',
      progress: e.progress,
      progressLabel: e.episodeNumber != null
          ? 'Episode ${e.episodeNumber!.toInt()} · $pct% watched'
          : '$pct% watched',
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
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        await sl<WatchHistory>().remove(e.sourceId, e.showId);
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _playFeatured(MediaItem item) async {
    // Fresh play: prefer a saved per-title sub/dub choice, else the global
    // default category, else 'sub'.
    final category =
        sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    // Instant nav — the player resolves the episode list behind its loader.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: item.sourceId,
          episodesResolver: () => _repo.episodes(item.url, sourceId: item.sourceId),
          resume: sl<ResumeStore>(),
          resolveSources: (u) => _repo.sources(u, sourceId: item.sourceId),
          history: sl<WatchHistory>(),
          showTitle: item.title,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          showUrl: item.url,
          category: category,
          malId: item.malId,
          scrobbleTitle: item.type == ProviderType.anime ? item.title : null,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Resume from Continue Watching. Navigates to the player INSTANTLY; the
  /// player resolves the episode list behind its own branded loader (no blocking
  /// pre-navigation spinner).
  Future<void> _resume(HistoryEntry e) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: e.sourceId,
          episodesResolver: () => _repo.episodes(
            e.showUrl,
            category: e.category,
            sourceId: e.sourceId,
          ),
          resumeEpisodeId: e.episodeId,
          resume: sl<ResumeStore>(),
          resolveSources: (u) => _repo.sources(u, sourceId: e.sourceId),
          history: sl<WatchHistory>(),
          showTitle: e.showTitle,
          cover: e.cover,
          coverHeaders: e.coverHeaders,
          showUrl: e.showUrl,
          category: e.category,
          malId: e.malId,
          scrobbleTitle: e.malId != null ? e.showTitle : null,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Wraps [child] in a subtle fade + upward slide entrance on first build.
  Widget _animated(Widget child) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOut,
      builder: (context, t, innerChild) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 16),
          child: innerChild,
        ),
      ),
      child: child,
    );
  }

  /// Floating brand header — always positioned on top of the hero or bg.
  Widget _buildHeader() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            // Brand wordmark — the actual logo lettering (exact font).
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Image.asset(
                  'assets/icon/wordmark.png',
                  height: 22,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            BlocBuilder<ActiveSourceCubit, String>(
              builder: (context, id) => SourceSwitcher(
                currentId: id,
                onChanged: (newId) =>
                    context.read<ActiveSourceCubit>().setSource(newId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds one provider-defined browse row (poster cards). The section is
  /// already guaranteed non-empty by [SourceRepository.home].
  Widget _sectionRow(HomeSection section) {
    final items = section.items;
    return _animated(
      ContentRow(
        title: section.title,
        itemWidth: 140,
        itemHeight: 236,
        itemCount: items.length,
        onSeeAll: () => _openSeeAll(section),
        itemBuilder: (c, i) => PosterCard(
          title: items[i].title,
          imageUrl: items[i].cover,
          headers: items[i].coverHeaders,
          cellWidth: 140,
          onTap: () => _openDetail(items[i]),
          onLongPress: () => _showInfo(items[i]),
        ),
      ),
    );
  }

  /// Open the full-grid "See All" view of a browse row.
  void _openSeeAll(HomeSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeeAllScreen(
          title: section.title,
          items: section.items,
          onTap: _openDetail,
          onLongPress: _showInfo,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    // Continue Watching is a logged-in feature; hide the row when signed out.
    final loggedIn = context.watch<AuthCubit>().state.isLoggedIn;
    final history = loggedIn
        ? sl<WatchHistory>().recent()
        : const <HistoryEntry>[];

    return BlocListener<ActiveSourceCubit, String>(
      listenWhen: (prev, curr) => prev != curr,
      listener: (context, _) {
        if (!mounted) return;
        _metaCache.clear();
        _heroPrewarmed = false;
        // reset:true clears the old source's rows so the switch is visible
        // immediately (skeletons), even if the new source's home is slow.
        context.read<HomeCubit>().load(reset: true);
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        // Extend content behind the status bar; the floating header handles
        // its own SafeArea(bottom: false).
        body: RefreshIndicator(
          color: AppColors.accent,
          onRefresh: () => context.read<HomeCubit>().load(),
          child: BlocBuilder<HomeCubit, HomeState>(
            builder: (context, state) {
              final sections = state.sections ?? const <HomeSection>[];
              // The first section feeds the hero carousel; the rest render as
              // browse rows (so the spotlight isn't duplicated right below it).
              final rowSections = sections.length > 1
                  ? sections.sublist(1)
                  : const <HomeSection>[];
              final showSkeletons = state.loading && sections.isEmpty;
              // The load finished but the source returned no rows — almost
              // always a dead/blocked site (or a search-only source). Show a
              // clear message instead of a blank screen.
              final loadedEmpty = !state.loading &&
                  state.sections != null &&
                  state.sections!.isEmpty;
              return CustomScrollView(
                slivers: [
                  // ── Hero + floating header (first sliver) ─────────────────
                  SliverToBoxAdapter(
                    child: Builder(
                      builder: (context) {
                        final heroItems = state.heroItems;
                        final hasHero = heroItems.isNotEmpty;
                        if (hasHero) _prewarmHeroMeta(heroItems);

                        if (hasHero) {
                          return Stack(
                            children: [
                              // Auto-rotating carousel (up to 6 trending items)
                              FeaturedCarousel(
                                items: heroItems,
                                inList: (m) => _myList.contains(m),
                                onPlay: _playFeatured,
                                onInfo: _openDetail,
                                onToggleList: (m) => showListStatusSheet(
                                  context,
                                  item: m,
                                  onChanged: () {
                                    if (mounted) setState(() {});
                                  },
                                ),
                                meta: _heroMeta,
                                style: HeroTransition.cinematic,
                              ),
                              // Floating header sits on top
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: _buildHeader(),
                              ),
                            ],
                          );
                        }

                        // While loading or on error: plain header on bg colour.
                        return ColoredBox(
                          color: AppColors.bg,
                          child: _buildHeader(),
                        );
                      },
                    ),
                  ),

                  // ── Continue Watching (same poster footprint as the rows) ─
                  if (history.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: _animated(
                          ContentRow(
                            title: 'Continue Watching',
                            itemWidth: 140,
                            itemHeight: 236,
                            itemCount: history.length,
                            itemBuilder: (c, i) {
                              final e = history[i];
                              return ContinueCard(
                                title: e.showTitle,
                                imageUrl: e.cover,
                                headers: e.coverHeaders,
                                progress: e.progress,
                                cellWidth: 140,
                                subtitle: e.episodeNumber != null
                                    ? 'Episode ${e.episodeNumber!.toInt()}'
                                    : null,
                                onTap: () => _resume(e),
                                onLongPress: () => _showContinueInfo(e),
                              );
                            },
                          ),
                        ),
                      ),
                    )
                  else
                    const SliverToBoxAdapter(child: SizedBox.shrink()),

                  // ── Provider-defined browse rows (CloudStream-style) ──────
                  // The active provider decides the rows + their names; empty
                  // ones are already dropped by SourceRepository.home.
                  if (showSkeletons)
                    ...List.generate(
                      3,
                      (_) => const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: RowSkeleton(),
                        ),
                      ),
                    )
                  else if (loadedEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _SourceUnavailable(
                        sourceName: sl<SourceRepository>().displayName(
                          context.read<ActiveSourceCubit>().state,
                        ),
                        onRetry: () =>
                            context.read<HomeCubit>().load(reset: true),
                      ),
                    )
                  else
                    ...rowSections.map(
                      (s) => SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: _sectionRow(s),
                        ),
                      ),
                    ),

                  // ── Bottom padding ────────────────────────────────────────
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Shown on Home when the active source finished loading but returned no rows —
/// typically a dead/blocked site. Offers a retry and points to the source
/// switcher. Continue Watching (app-side) still renders above this.
class _SourceUnavailable extends StatelessWidget {
  const _SourceUnavailable({required this.sourceName, required this.onRetry});

  final String sourceName;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 40, 36, 56),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.cloud_off_rounded,
              size: 40,
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            "Couldn't load $sourceName",
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            "This source isn't responding right now. It may be down or "
            "blocking requests — try again, or switch to another source "
            "from the top.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 13),
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
