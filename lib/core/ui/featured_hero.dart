import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'buttons.dart';

/// Amazon-Prime-style cinematic hero for the home spotlight.
///
/// Full-bleed backdrop (no floating info-card) with a slow Ken-Burns zoom, a
/// gradient that melts the art into the page background, and bottom-anchored
/// content: title → tagline (lazily fetched) → Play / My-List.
///
/// It FILLS whatever height the parent (the carousel) gives it — the carousel
/// pins a fixed height so the container never resizes between slides. The root
/// [Stack] clips (default hard-edge) so the Ken-Burns overflow stays bounded.
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

  /// Lazily-fetched tagline for the show. While null/loading the box is
  /// reserved (empty text), so the hero height never changes.
  final Future<String?>? descriptionFuture;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final memW = (mq.size.width * mq.devicePixelRatio).round();

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Full-bleed backdrop with a continuous Ken-Burns zoom ──────────
          if (item.cover != null && item.cover!.isNotEmpty)
            _KenBurns(
              child: CachedNetworkImage(
                imageUrl: item.cover!,
                httpHeaders: item.coverHeaders,
                memCacheWidth: memW,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 300),
                placeholder: (context, url) =>
                    const ColoredBox(color: AppColors.surface2),
                errorWidget: (context, url, err) =>
                    const ColoredBox(color: AppColors.surface2),
              ),
            )
          else
            const ColoredBox(color: AppColors.surface2),

          // ── Top scrim — status-bar legibility ─────────────────────────────
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: AppColors.topScrim),
            ),
          ),

          // ── Bottom cinematic gradient — melts art into bg + text contrast ──
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 340,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x000B0B0F),
                      Color(0xB30B0B0F),
                      AppColors.bg,
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // ── Bottom-anchored content ───────────────────────────────────────
          Positioned(
            left: 16,
            right: 16,
            bottom: 46,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title (tappable → info)
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: onInfo,
                  child: Text(
                    item.title,
                    style: AppText.largeTitle.copyWith(
                      fontSize: 30,
                      height: 1.05,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                const SizedBox(height: 10),

                // Tagline — fixed 2-line box; empty while loading/null so the
                // hero height stays constant.
                SizedBox(
                  height: 40,
                  child: FutureBuilder<String?>(
                    future: descriptionFuture,
                    builder: (context, snap) {
                      final d = (snap.data ?? '').trim();
                      return Text(
                        d,
                        style: AppText.body.copyWith(
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ),

                const SizedBox(height: 16),

                // Action buttons
                Row(
                  children: [
                    Expanded(
                      child: PrimaryButton(
                        label: 'Play',
                        icon: Icons.play_arrow,
                        onPressed: onPlay,
                      ),
                    ),
                    const SizedBox(width: 12),
                    _ToggleButton(inList: inList, onTap: onToggleList),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ken-Burns — a slow, looping zoom on the backdrop. GPU-cheap (one Transform on
// a RepaintBoundary child). Pauses nothing; the controller is disposed on unmount.
// ─────────────────────────────────────────────────────────────────────────────

class _KenBurns extends StatefulWidget {
  const _KenBurns({required this.child});
  final Widget child;

  @override
  State<_KenBurns> createState() => _KenBurnsState();
}

class _KenBurnsState extends State<_KenBurns>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat(reverse: true);

  late final Animation<double> _scale = Tween<double>(
    begin: 1.0,
    end: 1.14,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scale, child: widget.child);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Square toggle (＋ / ✓) button — fixed 52×52, matches PrimaryButton height.
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
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.hairline, width: 0.5),
        ),
        child: Center(
          child: Icon(
            inList ? Icons.check : Icons.add,
            color: inList ? AppColors.accent : AppColors.textPrimary,
            size: 24,
          ),
        ),
      ),
    );
  }
}
