import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/continue_card.dart';
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

  // Futures cached in fields (not in build) to prevent refetch on every rebuild.
  late Future<List<MediaItem>> _trending;
  late Future<List<MediaItem>> _month;
  late Future<List<MediaItem>> _allTime;

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
      // Refresh Continue Watching row when returning from detail.
      if (mounted) setState(() {});
    });
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

  @override
  Widget build(BuildContext context) {
    // Read Continue Watching in build so it refreshes after returning from player/detail.
    final history = sl<WatchHistory>().recent();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: () async {
          setState(_load);
        },
        child: CustomScrollView(
          slivers: [
            // ── Brand header ──────────────────────────────────────────────
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: const Text(kAppName, style: AppText.largeTitle),
                      ),
                      IconButton(
                        icon: const Icon(Icons.search, color: Colors.white),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SearchScreen(),
                          ),
                        ),
                        tooltip: 'Search',
                      ),
                    ],
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
                      itemWidth: 260,
                      itemHeight: 196,
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
                        itemWidth: 124,
                        itemHeight: 210,
                        itemCount: items.length,
                        itemBuilder: (c, i) => PosterCard(
                          title: items[i].title,
                          imageUrl: items[i].cover,
                          headers: items[i].coverHeaders,
                          cellWidth: 124,
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
                        itemWidth: 124,
                        itemHeight: 210,
                        itemCount: items.length,
                        itemBuilder: (c, i) => PosterCard(
                          title: items[i].title,
                          imageUrl: items[i].cover,
                          headers: items[i].coverHeaders,
                          cellWidth: 124,
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
                        itemWidth: 124,
                        itemHeight: 210,
                        itemCount: items.length,
                        itemBuilder: (c, i) => PosterCard(
                          title: items[i].title,
                          imageUrl: items[i].cover,
                          headers: items[i].coverHeaders,
                          cellWidth: 124,
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
