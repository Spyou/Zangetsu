import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/brand_loader.dart';
import '../../core/ui/buttons.dart';
import '../../core/ui/segmented_toggle.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';
import 'cubit/detail_cubit.dart';

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => DetailCubit(
        repo: sl<SourceRepository>(),
        url: item.url,
        sourceId: item.sourceId,
      )..load(),
      child: _DetailView(item: item),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DetailView — StatefulWidget for the scroll-driven app-bar title fade.
// The scroll position is pure UI state and stays widget-level; everything
// data-related (detail / category / season / desc-expand) lives in
// DetailCubit and is consumed via BlocBuilder below.
// ─────────────────────────────────────────────────────────────────────────────

class _DetailView extends StatefulWidget {
  const _DetailView({required this.item});
  final MediaItem item;

  @override
  State<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<_DetailView> {
  static const double _expandedHeight = 360;
  bool _showAppBarTitle = false;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final shouldShow = n.metrics.pixels > (_expandedHeight - kToolbarHeight - 24);
    if (shouldShow != _showAppBarTitle) {
      setState(() => _showAppBarTitle = shouldShow);
    }
    return false;
  }

  // ── Preserved exactly from original ──────────────────────────────────────

  void _openPlayer(
    List<Episode> episodes,
    int index,
    MediaDetail detail,
    String category,
  ) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        sourceId: widget.item.sourceId,
        episodes: episodes,
        startIndex: index,
        resume: sl<ResumeStore>(),
        resolveSources: (u) =>
            sl<SourceRepository>().sources(u, sourceId: widget.item.sourceId),
        history: sl<WatchHistory>(),
        showTitle: detail.title,
        cover: detail.cover ?? widget.item.cover,
        coverHeaders: detail.coverHeaders ?? widget.item.coverHeaders,
        showUrl: widget.item.url,
        category: category,
      ),
    ));
  }

  /// Walk episodes and return the best resume target index.
  /// - No marks → 0 ("Play")
  /// - Highest marked & not finished → that index ("Continue EN")
  /// - Highest marked & finished + next exists → next index ("Continue EN+1")
  /// - Highest marked & finished & last → same index ("Continue EN")
  int _resumeIndex(List<Episode> eps) {
    final store = sl<ResumeStore>();
    int? highestMarked;
    for (int j = 0; j < eps.length; j++) {
      final mark = store.get(widget.item.sourceId, eps[j].id);
      if (mark != null) {
        highestMarked = j;
      }
    }
    if (highestMarked == null) return 0;
    final mark = store.get(widget.item.sourceId, eps[highestMarked].id)!;
    if (!mark.finished) return highestMarked;
    if (highestMarked + 1 < eps.length) return highestMarked + 1;
    return highestMarked;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: BlocBuilder<DetailCubit, DetailState>(
        builder: (context, state) {
          if (state.status == DetailStatus.loading) {
            return const Center(child: BrandLoader(label: 'Loading…'));
          }
          if (state.status == DetailStatus.error || state.detail == null) {
            return const EmptyState(
              icon: Icons.error_outline,
              message: 'Failed to load this title',
            );
          }
          return _buildBody(context, state, state.detail!);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, DetailState state, MediaDetail detail) {
    final item = widget.item;
    final cubit = context.read<DetailCubit>();
    final category = state.category;
    final audioIndex = category == 'sub' ? 0 : 1;
    final descExpanded = state.descExpanded;
    final selectedSeason = state.selectedSeason;
    final showSubDub = showSubDubFor(detail);
    final eps = detail.episodes;
    final store = sl<ResumeStore>();

    // Resume / play button logic
    final resumeIdx = _resumeIndex(eps);
    final hasAnyMark =
        eps.any((e) => store.get(item.sourceId, e.id) != null);
    final episodeNum = eps.isNotEmpty
        ? (eps[resumeIdx].number?.toInt() ?? resumeIdx + 1)
        : 1;
    final buttonLabel = hasAnyMark ? 'Continue E$episodeNum' : 'Play';

    // Cover
    final coverUrl = detail.cover ?? item.cover ?? '';
    final coverHeaders = detail.coverHeaders ?? item.coverHeaders;
    final hasCover = coverUrl.isNotEmpty;

    // Season data
    final seasonSet = seasonsOf(eps);
    final hasMultipleSeasons = seasonSet.length > 1;

    // Season to display (clamp in case detail reloads with fewer seasons)
    final currentSeason = hasMultipleSeasons
        ? (seasonSet.contains(selectedSeason) ? selectedSeason : seasonSet.first)
        : 1;

    // Episodes filtered by season
    final seasonEps = hasMultipleSeasons
        ? eps
            .where((e) => parseSeason(e.title) == currentSeason)
            .toList()
        : eps;

    // Meta row
    final statusStr = statusLabel(detail.status);
    final metaParts = <String>['${eps.length} Episodes'];
    if (statusStr.isNotEmpty) metaParts.add(statusStr);
    if (detail.genres.isNotEmpty) metaParts.add(detail.genres.first);
    final metaLine = metaParts.join(' · ');

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: CustomScrollView(
      slivers: [
        // ── 1. Cinematic hero SliverAppBar ─────────────────────────────────
        SliverAppBar(
          expandedHeight: _expandedHeight,
          pinned: true,
          stretch: true,
          backgroundColor: AppColors.bg,
          surfaceTintColor: Colors.transparent,
          // Fades in only once the hero cover has scrolled out of view —
          // mirrors Sozo Read's NotificationListener-driven pattern.
          title: AnimatedOpacity(
            opacity: _showAppBarTitle ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: Text(
              detail.title,
              style: AppText.headline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          flexibleSpace: FlexibleSpaceBar(
            collapseMode: CollapseMode.parallax,
            background: RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Backdrop cover
                  hasCover
                      ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          httpHeaders: coverHeaders,
                          fit: BoxFit.cover,
                          memCacheWidth: 800,
                          placeholder: (context0, url0) =>
                              const ColoredBox(color: AppColors.surface2),
                          errorWidget: (context0, url0, err) =>
                              const ColoredBox(color: AppColors.surface2),
                        )
                      : const ColoredBox(color: AppColors.surface2),
                  // Top scrim (status-bar legibility)
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: AppColors.topScrim,
                    ),
                  ),
                  // Bottom-up scrim
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: AppColors.scrim,
                    ),
                  ),
                  // Sozo-style: 2:3 thumbnail + title block at the bottom
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // 2:3 cover thumbnail
                        SizedBox(
                          height: 150,
                          child: AspectRatio(
                            aspectRatio: 2 / 3,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: hasCover
                                  ? CachedNetworkImage(
                                      imageUrl: coverUrl,
                                      httpHeaders: coverHeaders,
                                      fit: BoxFit.cover,
                                      memCacheWidth: 200,
                                      placeholder: (context0, url0) =>
                                          const ColoredBox(
                                              color: AppColors.surface2),
                                      errorWidget: (context0, url0, err) =>
                                          const ColoredBox(
                                              color: AppColors.surface2),
                                    )
                                  : const ColoredBox(color: AppColors.surface2),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        // Title + status badge block
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  detail.title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.3,
                                    height: 1.15,
                                    shadows: [
                                      Shadow(
                                        blurRadius: 6,
                                        color: Colors.black87,
                                      ),
                                    ],
                                  ),
                                ),
                                if ((detail.englishTitle ?? '').isNotEmpty &&
                                    detail.englishTitle != detail.title) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    detail.englishTitle!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      height: 1.2,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                if (detail.status != MediaStatus.unknown)
                                  _StatusBadge(status: detail.status),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ── 2. Header block ─────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Meta row — title lives only in the hero + fading app-bar
                Text(metaLine,
                    style: AppText.caption.copyWith(
                        color: AppColors.textTertiary)),
                const SizedBox(height: 16),
                // Description with "More" affordance
                if ((detail.description ?? '').isNotEmpty) ...[
                  GestureDetector(
                    onTap: cubit.toggleDesc,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          detail.description!,
                          style: AppText.body,
                          maxLines: descExpanded ? null : 3,
                          overflow: descExpanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          descExpanded ? 'Less' : 'More',
                          style: AppText.caption.copyWith(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // Genre chips
                if (detail.genres.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: detail.genres
                        .map((g) => TagBadge(
                              text: g,
                              color: AppColors.textSecondary,
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                ],
                // Play / Continue button
                PrimaryButton(
                  label: buttonLabel,
                  icon: Icons.play_arrow,
                  onPressed: eps.isNotEmpty
                      ? () => _openPlayer(eps, resumeIdx, detail, category)
                      : null,
                ),
                const SizedBox(height: 12),
                // Sub / Dub toggle — anime only, when both counts are meaningful
                if (showSubDub)
                  SegmentedToggle(
                    segments: const ['Sub', 'Dub'],
                    index: audioIndex,
                    onChanged: (i) =>
                        cubit.setCategory(i == 0 ? 'sub' : 'dub'),
                  ),
                if (showSubDub) const SizedBox(height: 4),
                const SizedBox(height: 16),
                const Divider(color: AppColors.hairline),
                const SizedBox(height: 12),
                // "Episodes" heading + season selector
                Row(
                  children: [
                    const Text('Episodes', style: AppText.headline),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),

        // ── 3. Season selector (only when multi-season) ─────────────────────
        if (hasMultipleSeasons)
          SliverToBoxAdapter(
            child: _SeasonSelector(
              seasons: seasonSet.toList()..sort(),
              selectedSeason: currentSeason,
              onSelectSeason: cubit.selectSeason,
            ),
          ),

        // ── 4. Netflix/Prime-style episode list ──────────────────────────────
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final ep = seasonEps[i];
              // Map season-filtered index back to the FULL episode list index
              // so playback / resume keys remain correct.
              final fullIndex = eps.indexOf(ep);
              final mark = store.get(item.sourceId, ep.id);
              final isInProgress = mark != null &&
                  !mark.finished &&
                  mark.duration > Duration.zero;
              final isWatched = mark != null && mark.finished;
              final isResume = hasAnyMark && fullIndex == _resumeIndex(eps);

              final fraction = isInProgress
                  ? (mark.position.inMilliseconds /
                          mark.duration.inMilliseconds)
                      .clamp(0.0, 1.0)
                  : 0.0;

              final epNumStr =
                  'E${ep.number?.toInt() ?? i + 1}';
              final rawTitle = ep.title;
              final displayTitle = hasMultipleSeasons
                  ? cleanTitle(rawTitle)
                  : rawTitle;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _EpisodeRow(
                    ep: ep,
                    epNumStr: epNumStr,
                    displayTitle: displayTitle,
                    coverUrl: coverUrl,
                    coverHeaders: coverHeaders,
                    isWatched: isWatched,
                    isInProgress: isInProgress,
                    isResume: isResume,
                    fraction: fraction,
                    onTap: () => _openPlayer(eps, fullIndex, detail, category),
                  ),
                  if (i < seasonEps.length - 1)
                    const Divider(
                      height: 1,
                      thickness: 0,
                      color: AppColors.hairline,
                      indent: 16,
                      endIndent: 16,
                    ),
                ],
              );
            },
            childCount: seasonEps.length,
          ),
        ),

        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Season selector — horizontal pill chips
// ─────────────────────────────────────────────────────────────────────────────

class _SeasonSelector extends StatelessWidget {
  const _SeasonSelector({
    required this.seasons,
    required this.selectedSeason,
    required this.onSelectSeason,
  });

  final List<int> seasons;
  final int selectedSeason;
  final ValueChanged<int> onSelectSeason;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: seasons.length,
        separatorBuilder: (context0, i0) => const SizedBox(width: 8),
        itemBuilder: (context0, i) {
          final s = seasons[i];
          final selected = s == selectedSeason;
          return GestureDetector(
            onTap: () => onSelectSeason(s),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: selected ? AppColors.accentSoft : AppColors.surface2,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? AppColors.accent : Colors.transparent,
                  width: 1,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                'Season $s',
                style: AppText.caption.copyWith(
                  color: selected ? AppColors.accent : AppColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Netflix/Prime-style episode row — landscape thumbnail + meta
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.ep,
    required this.epNumStr,
    required this.displayTitle,
    required this.coverUrl,
    required this.coverHeaders,
    required this.isWatched,
    required this.isInProgress,
    required this.isResume,
    required this.fraction,
    required this.onTap,
  });

  final Episode ep;
  final String epNumStr;
  final String displayTitle;
  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final bool isWatched;
  final bool isInProgress;
  final bool isResume;
  final double fraction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Dim watched rows slightly
    final rowOpacity = isWatched ? 0.55 : 1.0;
    final titleColor = isResume
        ? AppColors.accent
        : (isWatched ? AppColors.textTertiary : AppColors.textPrimary);

    final thumbUrl =
        (ep.thumbnail != null && ep.thumbnail!.isNotEmpty)
            ? ep.thumbnail!
            : coverUrl;

    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: rowOpacity,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 16:9 thumbnail
              SizedBox(
                width: 132,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        thumbUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: thumbUrl,
                                httpHeaders: coverHeaders,
                                fit: BoxFit.cover,
                                memCacheWidth: 264,
                                placeholder: (context0, url0) =>
                                    const ColoredBox(
                                        color: AppColors.surface2),
                                errorWidget: (context0, url0, err) =>
                                    const ColoredBox(
                                        color: AppColors.surface2),
                              )
                            : const ColoredBox(color: AppColors.surface2),
                        // Play glyph overlay
                        Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              shape: BoxShape.circle,
                            ),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                        // Resume progress bar at the bottom of thumb
                        if (isInProgress)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _ThumbnailProgressBar(
                                fraction: fraction),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Meta column
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Episode number (headline weight)
                    Text(
                      epNumStr,
                      style: AppText.headline.copyWith(
                        color: titleColor,
                        fontWeight: isResume
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // Episode title
                    if (displayTitle.isNotEmpty)
                      Text(
                        displayTitle,
                        style: AppText.caption.copyWith(
                          color: isWatched
                              ? AppColors.textTertiary
                              : AppColors.textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 6),
                    // Indicators row: watched ✓ / filler badge
                    Row(
                      children: [
                        if (isWatched) ...[
                          const Icon(
                            Icons.check_circle,
                            color: AppColors.textTertiary,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (ep.filler)
                          const TagBadge(
                            text: 'FILLER',
                            color: AppColors.textTertiary,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Thin accent progress bar painted at the bottom of a thumbnail
// ─────────────────────────────────────────────────────────────────────────────

class _ThumbnailProgressBar extends StatelessWidget {
  const _ThumbnailProgressBar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: Stack(
        children: [
          const ColoredBox(
              color: Colors.black38, child: SizedBox.expand()),
          FractionallySizedBox(
            widthFactor: fraction,
            alignment: Alignment.centerLeft,
            child: const ColoredBox(color: AppColors.accent),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status badge pill (mirrors Sozo Read's _StatusBadge)
// ─────────────────────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final MediaStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      MediaStatus.ongoing => const Color(0xFF30D158),   // green
      MediaStatus.completed => AppColors.accent,
      MediaStatus.hiatus => const Color(0xFFFF9F0A),    // amber
      MediaStatus.cancelled => AppColors.textTertiary,
      MediaStatus.unknown => AppColors.textTertiary,
    };
    final label = switch (status) {
      MediaStatus.ongoing => 'ONGOING',
      MediaStatus.completed => 'COMPLETED',
      MediaStatus.hiatus => 'HIATUS',
      MediaStatus.cancelled => 'CANCELLED',
      MediaStatus.unknown => 'UNKNOWN',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
