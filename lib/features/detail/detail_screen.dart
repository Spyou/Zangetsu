import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/resume_store.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/buttons.dart';
import '../../core/ui/segmented_toggle.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.item});
  final MediaItem item;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final _repo = sl<SourceRepository>();
  Future<MediaDetail>? _detail;
  int _audioIndex = 0;

  @override
  void initState() {
    super.initState();
    _detail = _repo.detail(widget.item.url);
  }

  void _openPlayer(List<Episode> episodes, int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        sourceId: widget.item.sourceId,
        episodes: episodes,
        startIndex: index,
        resume: sl<ResumeStore>(),
        resolveSources: _repo.sources,
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

  String _statusLabel(MediaStatus status) {
    switch (status) {
      case MediaStatus.ongoing:
        return 'Ongoing';
      case MediaStatus.completed:
        return 'Completed';
      case MediaStatus.hiatus:
        return 'Hiatus';
      case MediaStatus.cancelled:
        return 'Cancelled';
      case MediaStatus.unknown:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: FutureBuilder<MediaDetail>(
        future: _detail,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              message: 'Failed to load this title',
            );
          }
          final detail = snap.data!;
          final eps = detail.episodes;
          final resumeIdx = _resumeIndex(eps);
          final store = sl<ResumeStore>();
          // "Continue" whenever ANY episode has been touched (the user is
          // mid-series), even if the resume target itself is freshly unwatched
          // (e.g. the previous episode just finished). "Play" only when fresh.
          final hasAnyMark = eps.any(
              (e) => store.get(widget.item.sourceId, e.id) != null);
          final episodeNum = eps.isNotEmpty
              ? (eps[resumeIdx].number?.toInt() ?? resumeIdx + 1)
              : 1;
          final buttonLabel =
              hasAnyMark ? 'Continue E$episodeNum' : 'Play';

          // Meta row pieces
          final statusLabel = _statusLabel(detail.status);
          final metaParts = <String>['${eps.length} episodes'];
          if (statusLabel.isNotEmpty) metaParts.add(statusLabel);
          if (detail.genres.isNotEmpty) {
            metaParts.add(detail.genres.first);
          } else if (detail.studios.isNotEmpty) {
            metaParts.add(detail.studios.first);
          }
          final metaLine = metaParts.join(' • ');

          final coverUrl =
              detail.cover ?? widget.item.cover ?? '';
          final coverHeaders =
              detail.coverHeaders ?? widget.item.coverHeaders;
          final hasCover = coverUrl.isNotEmpty;

          return CustomScrollView(
            slivers: [
              // ── 1. Cinematic hero SliverAppBar ──
              SliverAppBar(
                expandedHeight: 360,
                pinned: true,
                stretch: true,
                backgroundColor: AppColors.bg,
                surfaceTintColor: Colors.transparent,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.parallax,
                  titlePadding: const EdgeInsetsDirectional.fromSTEB(
                      16, 0, 16, 14),
                  title: Text(
                    detail.title,
                    style: AppText.headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  background: RepaintBoundary(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Cover image (or fallback surface)
                        hasCover
                            ? CachedNetworkImage(
                                imageUrl: coverUrl,
                                httpHeaders: coverHeaders,
                                fit: BoxFit.cover,
                                placeholder: (context, url) =>
                                    const ColoredBox(
                                        color: AppColors.surface2),
                                errorWidget: (context, url, error) =>
                                    const ColoredBox(
                                        color: AppColors.surface2),
                              )
                            : const ColoredBox(color: AppColors.surface2),
                        // Gradient scrim — no BackdropFilter
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: AppColors.scrim,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // ── 2. Header block ──
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Big title
                      Text(detail.title, style: AppText.largeTitle),
                      if ((detail.englishTitle ?? '').isNotEmpty &&
                          detail.englishTitle != detail.title) ...[
                        const SizedBox(height: 4),
                        Text(detail.englishTitle!,
                            style: AppText.caption),
                      ],
                      const SizedBox(height: 8),
                      // Meta row
                      Text(metaLine, style: AppText.caption),
                      const SizedBox(height: 20),
                      // Play / Continue button
                      PrimaryButton(
                        label: buttonLabel,
                        icon: Icons.play_arrow,
                        onPressed: eps.isNotEmpty
                            ? () => _openPlayer(eps, resumeIdx)
                            : null,
                      ),
                      const SizedBox(height: 12),
                      // Sub / Dub toggle
                      SegmentedToggle(
                        segments: const ['Sub', 'Dub'],
                        index: _audioIndex,
                        onChanged: (i) =>
                            setState(() => _audioIndex = i),
                      ),
                      if ((detail.description ?? '').isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          detail.description!,
                          style: AppText.body,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 20),
                      const Divider(color: AppColors.hairline),
                      const SizedBox(height: 12),
                      const Text('Episodes', style: AppText.headline),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),

              // ── 3. Episode list ──
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final ep = eps[i];
                    final mark = store.get(widget.item.sourceId, ep.id);
                    final epNum = ep.number != null
                        ? ep.number!.toInt().toString()
                        : '${i + 1}';
                    final isInProgress = mark != null &&
                        !mark.finished &&
                        mark.duration > Duration.zero;
                    final isWatched =
                        mark != null && mark.finished;

                    // Progress fraction (clamped)
                    final fraction = isInProgress
                        ? (mark.position.inMilliseconds /
                                mark.duration.inMilliseconds)
                            .clamp(0.0, 1.0)
                        : 0.0;

                    // Trailing icon
                    Widget trailing;
                    if (isInProgress) {
                      trailing = const Icon(
                        Icons.play_circle_fill,
                        color: AppColors.accent,
                        size: 22,
                      );
                    } else if (isWatched) {
                      trailing = const Icon(
                        Icons.check_circle,
                        color: AppColors.textTertiary,
                        size: 22,
                      );
                    } else {
                      trailing = const Icon(
                        Icons.play_arrow,
                        color: AppColors.textSecondary,
                        size: 22,
                      );
                    }

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: () => _openPlayer(eps, i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 14),
                            child: Row(
                              children: [
                                // Episode number
                                SizedBox(
                                  width: 36,
                                  child: Text(
                                    epNum,
                                    style: AppText.headline.copyWith(
                                        color: AppColors.textSecondary),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Title + filler chip
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        ep.title,
                                        style: AppText.body.copyWith(
                                            color: AppColors.textPrimary),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (ep.filler) ...[
                                        const SizedBox(height: 4),
                                        const _FillerChip(),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                trailing,
                              ],
                            ),
                          ),
                        ),
                        // Progress bar (only when in progress)
                        if (isInProgress)
                          _ProgressBar(fraction: fraction),
                        // Hairline divider between rows
                        if (i < eps.length - 1)
                          const Divider(
                            height: 1,
                            thickness: 0,
                            color: AppColors.hairline,
                            indent: 20,
                            endIndent: 20,
                          ),
                      ],
                    );
                  },
                  childCount: eps.length,
                ),
              ),

              // Bottom padding
              const SliverToBoxAdapter(
                child: SizedBox(height: 40),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Thin progress bar underneath a row (height ~3).
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          height: 3,
          width: constraints.maxWidth,
          child: Stack(
            children: [
              // Track
              ColoredBox(
                color: AppColors.hairline,
                child: const SizedBox.expand(),
              ),
              // Fill
              FractionallySizedBox(
                widthFactor: fraction,
                alignment: Alignment.centerLeft,
                child: const ColoredBox(color: AppColors.accent),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Small rounded "Filler" chip.
class _FillerChip extends StatelessWidget {
  const _FillerChip();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          'Filler',
          style: AppText.caption,
        ),
      ),
    );
  }
}
