import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/continue_card.dart';
import '../../core/ui/featured_carousel.dart';
import '../../core/ui/genre_chips.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/row_skeleton.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';
import 'search_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _repo = sl<SourceRepository>();
  final _myList = sl<MyListStore>();

  // Futures cached in fields (not in build) to prevent refetch on every rebuild.
  late Future<List<MediaItem>> _trending;
  late Future<List<MediaItem>> _month;
  late Future<List<MediaItem>> _allTime;

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

  void _load() {
    _trending = _repo.popular(dateRange: 1);
    _month = _repo.popular(dateRange: 30);
    _allTime = _repo.popular(dateRange: 0);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

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
      final eps = await _repo.episodes(item.url);
      if (eps.isEmpty) {
        _openDetail(item);
        return;
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            sourceId: item.sourceId,
            episodes: eps,
            startIndex: 0,
            resume: sl<ResumeStore>(),
            resolveSources: _repo.sources,
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
      final eps = await _repo.episodes(e.showUrl, category: e.category);
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
            resolveSources: _repo.sources,
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
            const Expanded(
              child: Text(kAppName, style: AppText.largeTitle),
            ),
            // Symmetry spacer (Search is now a bottom-nav tab).
            const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Read Continue Watching + My List in build so they refresh after returning
    // from player/detail without triggering a re-fetch of network futures.
    final history = sl<WatchHistory>().recent();
    final savedItems = _myList.all();

    return Scaffold(
      backgroundColor: AppColors.bg,
      // Extend content behind the status bar; the floating header handles
      // its own SafeArea(bottom: false).
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: () async {
          setState(_load);
        },
        child: CustomScrollView(
          slivers: [
            // ── Hero + floating header (first sliver) ─────────────────────
            SliverToBoxAdapter(
              child: FutureBuilder<List<MediaItem>>(
                future: _trending,
                builder: (context, snap) {
                  final hasHero = snap.connectionState != ConnectionState.waiting &&
                      !snap.hasError &&
                      (snap.data?.isNotEmpty ?? false);

                  if (hasHero) {
                    return Stack(
                      children: [
                        // Auto-rotating carousel (up to 6 trending items)
                        FeaturedCarousel(
                          items: snap.data!,
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

            // ── Genre chips ───────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: GenreChips(
                  onTap: (g) => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SearchScreen(initialQuery: g),
                    ),
                  ),
                ),
              ),
            ),

            // ── My List (only when non-empty) ─────────────────────────────
            if (savedItems.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: _animated(
                    ContentRow(
                      title: 'My List',
                      itemWidth: 140,
                      itemHeight: 236,
                      itemCount: savedItems.length,
                      itemBuilder: (c, i) => PosterCard(
                        title: savedItems[i].title,
                        imageUrl: savedItems[i].cover,
                        headers: savedItems[i].coverHeaders,
                        cellWidth: 140,
                        onTap: () => _openDetail(savedItems[i]),
                      ),
                    ),
                  ),
                ),
              ),

            // ── Continue Watching ─────────────────────────────────────────
            if (history.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: _animated(
                    ContentRow(
                      title: 'Continue Watching',
                      itemWidth: 300,
                      itemHeight: 230,
                      itemCount: history.length,
                      itemBuilder: (c, i) {
                        final e = history[i];
                        return ContinueCard(
                          title: e.showTitle,
                          imageUrl: e.cover,
                          headers: e.coverHeaders,
                          progress: e.progress,
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

            // ── Trending Now ──────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: FutureBuilder<List<MediaItem>>(
                  future: _trending,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const RowSkeleton();
                    }
                    if (snap.hasError || (snap.data?.isEmpty ?? true)) {
                      return const SizedBox.shrink();
                    }
                    final items = snap.data!;
                    return _animated(
                      ContentRow(
                        title: 'Trending Now',
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
                  },
                ),
              ),
            ),

            // ── Popular This Month ────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: FutureBuilder<List<MediaItem>>(
                  future: _month,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const RowSkeleton();
                    }
                    if (snap.hasError || (snap.data?.isEmpty ?? true)) {
                      return const SizedBox.shrink();
                    }
                    final items = snap.data!;
                    return _animated(
                      ContentRow(
                        title: 'Popular This Month',
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
                  },
                ),
              ),
            ),

            // ── All-Time Favorites ────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: FutureBuilder<List<MediaItem>>(
                  future: _allTime,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const RowSkeleton();
                    }
                    if (snap.hasError || (snap.data?.isEmpty ?? true)) {
                      return const SizedBox.shrink();
                    }
                    final items = snap.data!;
                    return _animated(
                      ContentRow(
                        title: 'All-Time Favorites',
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
                  },
                ),
              ),
            ),

            // ── Bottom padding ────────────────────────────────────────────
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }
}
