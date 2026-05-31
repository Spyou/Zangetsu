import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'badge.dart';
import 'buttons.dart';

/// Hero banner for the home-screen spotlight.
///
/// Layout:
///   • 210 px background art strip (cropped/zoomed cover) with a top scrim
///     for status-bar legibility and a bottom fade into [AppColors.bg].
///   • Rounded info card that overlaps the art by 28 px (Transform.translate),
///     containing a poster thumbnail + title / meta / Play / ＋ buttons.
///
/// No [BackdropFilter] — gradient scrims only for scroll perf.
class FeaturedHero extends StatelessWidget {
  const FeaturedHero({
    super.key,
    required this.item,
    required this.inList,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
  });

  final MediaItem item;
  final bool inList;
  final VoidCallback onPlay;
  final VoidCallback onInfo;
  final VoidCallback onToggleList;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio;
    final heroMemW = (mq.size.width * dpr).round();
    final thumbMemW = (82 * dpr).round();

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 1. Background art strip ──────────────────────────────────────
          SizedBox(
            height: 210,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Cover image (cropped / zoomed)
                if (item.cover != null && item.cover!.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: item.cover!,
                    httpHeaders: item.coverHeaders,
                    memCacheWidth: heroMemW,
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 250),
                    placeholder: (context, url) =>
                        const ColoredBox(color: AppColors.surface2),
                    errorWidget: (context, url, err) =>
                        const ColoredBox(color: AppColors.surface2),
                  )
                else
                  const ColoredBox(color: AppColors.surface2),

                // Top scrim — status-bar legibility
                const DecoratedBox(
                  decoration: BoxDecoration(gradient: AppColors.topScrim),
                ),

                // Bottom fade — art melts into AppColors.bg
                const Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 120,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, AppColors.bg],
                        stops: [0.0, 1.0],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── 2. Info card (overlaps art by 28 px) ────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Transform.translate(
              offset: const Offset(0, -28),
              child: _InfoCard(
                item: item,
                inList: inList,
                thumbMemW: thumbMemW,
                onPlay: onPlay,
                onInfo: onInfo,
                onToggleList: onToggleList,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info card
// ─────────────────────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.item,
    required this.inList,
    required this.thumbMemW,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
  });

  final MediaItem item;
  final bool inList;
  final int thumbMemW;
  final VoidCallback onPlay;
  final VoidCallback onInfo;
  final VoidCallback onToggleList;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Poster thumbnail ────────────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 82,
                height: 116,
                child: item.cover != null && item.cover!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: item.cover!,
                        httpHeaders: item.coverHeaders,
                        memCacheWidth: thumbMemW,
                        fit: BoxFit.cover,
                        fadeInDuration: const Duration(milliseconds: 180),
                        placeholder: (context, url) =>
                            const ColoredBox(color: AppColors.surface2),
                        errorWidget: (context, url, err) =>
                            const ColoredBox(color: AppColors.surface2),
                      )
                    : const ColoredBox(color: AppColors.surface2),
              ),
            ),

            const SizedBox(width: 14),

            // ── Text + buttons (tappable for info, except buttons) ──────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title + english title — tappable for info
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onInfo,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.title,
                          style: AppText.headline,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (item.englishTitle != null &&
                            item.englishTitle != item.title) ...[
                          const SizedBox(height: 2),
                          Text(
                            item.englishTitle!,
                            style: AppText.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 8),
                        _MetaRow(item: item),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Action buttons ────────────────────────────────────────
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: PrimaryButton(
                            label: 'Play',
                            icon: Icons.play_arrow,
                            onPressed: onPlay,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Square ＋ / ✓ toggle button
                      _ToggleButton(inList: inList, onTap: onToggleList),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Meta row
// ─────────────────────────────────────────────────────────────────────────────

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final subCount = item.subCount ?? 0;
    final dubCount = item.dubCount ?? 0;
    final maxCount = max(subCount, dubCount);
    final hasSub = subCount > 0;
    final hasDub = dubCount > 0;
    final hasEpisodes = maxCount > 0;

    if (!hasEpisodes && !hasSub && !hasDub) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (hasEpisodes)
          Text(
            '$maxCount Episodes',
            style: AppText.caption,
          ),
        if (hasSub) const TagBadge(text: 'SUB'),
        if (hasDub) TagBadge(text: 'DUB', color: AppColors.textSecondary),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Square toggle (＋ / ✓) button
// ─────────────────────────────────────────────────────────────────────────────

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({required this.inList, required this.onTap});

  final bool inList;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.hairline, width: 0.5),
        ),
        child: Center(
          child: Icon(
            inList ? Icons.check : Icons.add,
            color: inList ? AppColors.accent : AppColors.textPrimary,
            size: 22,
          ),
        ),
      ),
    );
  }
}
