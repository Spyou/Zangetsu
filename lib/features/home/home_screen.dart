import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/continue_card.dart';
import '../../core/ui/featured_carousel.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/row_skeleton.dart';
import '../../core/ui/source_switcher.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';
import 'cubit/home_cubit.dart';

/// Provides the [HomeCubit] (which owns the three browse rows + the carousel's
/// trending source) and kicks off the first load. The view itself stays
/// Stateful for the per-item lazy hero-description cache and the navigation
/// helpers.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => HomeCubit(sl<SourceRepository>())..load(),
      child: const _HomeView(),
    );
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

  /// Description cache: key = "sourceId:id", value = lazily-fetched Future.
  /// Futures are stored so they are never re-fetched on carousel rotation.
  final Map<String, Future<String?>> _descCache = {};

  Future<String?> _describe(MediaItem m) => _descCache.putIfAbsent(
    '${m.sourceId}:${m.id}',
    () => _repo
        .detail(m.url)
        .then((d) => d.description)
        // ignore: avoid_types_on_closure_parameters
        .catchError((_) => null as String?),
  );

  void _openDetail(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
    ).then((_) {
      // Refresh Continue Watching + My List row when returning from detail.
      if (mounted) setState(() {});
    });
  }

  Future<void> _playFeatured(MediaItem item) async {
    try {
      final eps = await _repo.episodes(item.url, sourceId: item.sourceId);
      if (eps.isEmpty) {
        _openDetail(item);
        return;
      }
      if (!mounted) return;
      // Fresh play: prefer a saved per-title sub/dub choice, else the global
      // default category, else 'sub'.
      final category =
          sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
          sl<PlaybackPrefs>().defaultCategory;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            sourceId: item.sourceId,
            episodes: eps,
            startIndex: 0,
            resume: sl<ResumeStore>(),
            resolveSources: (u) => _repo.sources(u, sourceId: item.sourceId),
            history: sl<WatchHistory>(),
            showTitle: item.title,
            cover: item.cover,
            coverHeaders: item.coverHeaders,
            showUrl: item.url,
            category: category,
          ),
        ),
      );
      if (mounted) setState(() {});
    } catch (_) {
      // On any error fall back to detail screen.
      if (mounted) _openDetail(item);
    }
  }

  Future<void> _resume(HistoryEntry e) async {
    try {
      final eps = await _repo.episodes(
        e.showUrl,
        category: e.category,
        sourceId: e.sourceId,
      );
      var idx = eps.indexWhere((x) => x.id == e.episodeId);
      if (idx < 0) idx = 0;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            sourceId: e.sourceId,
            episodes: eps,
            startIndex: idx,
            resume: sl<ResumeStore>(),
            resolveSources: (u) => _repo.sources(u, sourceId: e.sourceId),
            history: sl<WatchHistory>(),
            showTitle: e.showTitle,
            cover: e.cover,
            coverHeaders: e.coverHeaders,
            showUrl: e.showUrl,
            category: e.category,
          ),
        ),
      );
      if (mounted) setState(() {});
    } catch (_) {
      // Ignore; row stays as-is.
    }
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
            Expanded(
              child: Text(
                kAppName.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.wordmark.copyWith(fontSize: 21),
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
        itemBuilder: (c, i) => PosterCard(
          title: items[i].title,
          imageUrl: items[i].cover,
          headers: items[i].coverHeaders,
          cellWidth: 140,
          onTap: () => _openDetail(items[i]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Read Continue Watching in build so it refreshes after returning from
    // player/detail without triggering a re-fetch of network futures. (My List
    // has its own screen — it is intentionally NOT shown as a home row.)
    final history = sl<WatchHistory>().recent();

    return BlocListener<ActiveSourceCubit, String>(
      listener: (context, _) {
        if (!mounted) return;
        _descCache.clear();
        context.read<HomeCubit>().load();
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
              return CustomScrollView(
                slivers: [
                  // ── Hero + floating header (first sliver) ─────────────────
                  SliverToBoxAdapter(
                    child: Builder(
                      builder: (context) {
                        final heroItems = state.heroItems;
                        final hasHero = heroItems.isNotEmpty;

                        if (hasHero) {
                          return Stack(
                            children: [
                              // Auto-rotating carousel (up to 6 trending items)
                              FeaturedCarousel(
                                items: heroItems,
                                inList: (m) => _myList.contains(m),
                                onPlay: _playFeatured,
                                onInfo: _openDetail,
                                onToggleList: (m) async {
                                  await _myList.toggle(m);
                                  if (mounted) setState(() {});
                                },
                                describe: _describe,
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
