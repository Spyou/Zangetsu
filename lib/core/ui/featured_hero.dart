import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'buttons.dart';

/// Hero banner for the home-screen spotlight.
///
/// Layout (fixed total height = 450 px — never jumps regardless of content):
///   • 250 px background art strip (cropped/zoomed cover) with a top scrim
///     for status-bar legibility and a bottom fade into [AppColors.bg].
///   • Rounded info card that overlaps the art by 34 px (Transform.translate),
///     containing a poster thumbnail (104×150) + title (fixed 48 px) +
///     description (fixed 54 px, 3-line, lazily fetched) + Play / ＋ buttons.
///
/// No [BackdropFilter] — gradient scrims only for scroll perf.
/// All inner boxes are FIXED height → carousel container never resizes.
class FeaturedHero extends StatelessWidget {
  const FeaturedHero({
    super.key,
    required this.item,
    required this.inList,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
    this.descriptionFuture,
  });

  final MediaItem item;
  final bool inList;
  final VoidCallback onPlay;
  final VoidCallback onInfo;
  final VoidCallback onToggleList;

  /// Lazily-fetched description for the show. While null/loading the 54 px
  /// box is reserved (empty text), so the hero height never changes.
  final Future<String?>? descriptionFuture;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio;
    final heroMemW = (mq.size.width * dpr).round();
    final thumbMemW = (104 * dpr).round();

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 1. Background art strip (250 px) ────────────────────────────
          SizedBox(
            height: 250,
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
                        stops: [0.4, 1.0],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── 2. Info card (overlaps art by 34 px via Transform.translate) ─
          // Transform.translate does NOT affect layout — the card still
          // occupies its natural position in the Column.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Transform.translate(
              offset: const Offset(0, -34),
              child: _InfoCard(
                item: item,
                inList: inList,
                thumbMemW: thumbMemW,
                descriptionFuture: descriptionFuture,
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
// Fixed inner heights:
//   padding top+bottom   16+16 = 32
//   poster               150
//   col: title(48)+gap(8)+desc(54)+gap(12)+buttons(46) = 168
//   max(poster, col)     168
//   total card height    32 + 168 = 200
// ─────────────────────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.item,
    required this.inList,
    required this.thumbMemW,
    required this.descriptionFuture,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
  });

  final MediaItem item;
  final bool inList;
  final int thumbMemW;
  final Future<String?>? descriptionFuture;
  final VoidCallback onPlay;
  final VoidCallback onInfo;
  final VoidCallback onToggleList;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.hairline, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Poster thumbnail (tappable → info) ─────────────────────────
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onInfo,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 104,
                  height: 150,
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
            ),

            const SizedBox(width: 14),

            // ── Right column: title + description + buttons ─────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title — fixed 2-line height (tappable → info)
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onInfo,
                    child: SizedBox(
                      height: 48,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          item.title,
                          style: AppText.headline,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Description — fixed 3-line height (tappable → info)
                  // The SizedBox is ALWAYS 54 px; empty while loading/null.
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onInfo,
                    child: SizedBox(
                      height: 54,
                      child: FutureBuilder<String?>(
                        future: descriptionFuture,
                        builder: (context, snap) {
                          final d = (snap.data ?? '').trim();
                          return Align(
                            alignment: Alignment.topLeft,
                            child: Text(
                              d,
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Action buttons row — fixed 46 px height
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: PrimaryButton(
                            label: 'Play',
                            icon: Icons.play_arrow,
                            onPressed: onPlay,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
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
// Square toggle (＋ / ✓) button — fixed 46×46
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
        width: 46,
        height: 46,
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
