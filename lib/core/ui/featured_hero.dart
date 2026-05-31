import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'buttons.dart';

/// Cinematic full-width hero banner for the home screen spotlight.
///
/// Wraps the whole widget in a [RepaintBoundary] for GPU layer isolation.
/// No [BackdropFilter] — scrims are gradient-only for scrolling perf.
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
    return RepaintBoundary(
      child: SizedBox(
        height: 460,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Cover art ───────────────────────────────────────────────────
            if (item.cover != null && item.cover!.isNotEmpty)
              CachedNetworkImage(
                imageUrl: item.cover!,
                httpHeaders: item.coverHeaders,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 250),
                placeholder: (context, url) =>
                    const ColoredBox(color: AppColors.surface2),
                errorWidget: (context, url, err) =>
                    const ColoredBox(color: AppColors.surface2),
              )
            else
              const ColoredBox(color: AppColors.surface2),

            // ── Top scrim (status bar legibility) ───────────────────────────
            const DecoratedBox(
              decoration: BoxDecoration(gradient: AppColors.topScrim),
            ),

            // ── Bottom scrim (title + buttons legibility) ───────────────────
            const Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 300,
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: AppColors.scrim),
              ),
            ),

            // ── Tap on art → onInfo (but buttons take precedence above) ─────
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onInfo,
              ),
            ),

            // ── Bottom content: title + actions ─────────────────────────────
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    item.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.largeTitle,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Play button — white fill, black label
                      SizedBox(
                        width: 150,
                        child: PrimaryButton(
                          label: 'Play',
                          icon: Icons.play_arrow,
                          onPressed: onPlay,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // My List toggle — compact translucent button
                      _MyListButton(
                        inList: inList,
                        onTap: onToggleList,
                      ),
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

/// Compact "My List" toggle button — translucent surface2 fill, 52px tall.
class _MyListButton extends StatelessWidget {
  const _MyListButton({required this.inList, required this.onTap});

  final bool inList;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          // surface2 at ~60% opacity
          color: AppColors.surface2.withAlpha(153),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.hairline, width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              inList ? Icons.check : Icons.add,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(height: 2),
            Text(
              'My List',
              style: AppText.caption.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
