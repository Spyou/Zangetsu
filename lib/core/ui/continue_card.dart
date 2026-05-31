import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Landscape "Continue Watching" card — 16:9 art with title + subtitle
/// overlaid at the bottom-left and a thin progress bar pinned to the base.
///
/// No [BackdropFilter]. Image decoded at display size via [memCacheWidth].
/// Press-scale animation on tap. Progress clamped to [0, 1].
class ContinueCard extends StatefulWidget {
  const ContinueCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.headers,
    required this.progress,
    this.subtitle,
    this.onTap,
    this.width = 300,
  });

  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;

  /// Playback progress in [0, 1].
  final double progress;

  final String? subtitle;
  final VoidCallback? onTap;
  final double width;

  @override
  State<ContinueCard> createState() => _ContinueCardState();
}

class _ContinueCardState extends State<ContinueCard> {
  bool _pressed = false;

  void _handleTapDown(TapDownDetails _) => setState(() => _pressed = true);
  void _handleTapUp(TapUpDetails _) => setState(() => _pressed = false);
  void _handleTapCancel() => setState(() => _pressed = false);

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final memW = (widget.width * dpr).round();
    final clampedProgress = widget.progress.clamp(0.0, 1.0);

    return RepaintBoundary(
      child: SizedBox(
        width: widget.width,
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: _handleTapDown,
          onTapUp: _handleTapUp,
          onTapCancel: _handleTapCancel,
          child: AnimatedScale(
            scale: _pressed ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // ── Background art ─────────────────────────────────────
                    if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: widget.imageUrl!,
                        httpHeaders: widget.headers,
                        memCacheWidth: memW,
                        fit: BoxFit.cover,
                        fadeInDuration: const Duration(milliseconds: 180),
                        placeholder: (context, url) =>
                            const ColoredBox(color: AppColors.surface2),
                        errorWidget: (context, url, err) =>
                            const ColoredBox(color: AppColors.surface2),
                      )
                    else
                      const ColoredBox(color: AppColors.surface2),

                    // ── Bottom scrim for text legibility ───────────────────
                    const DecoratedBox(
                      decoration: BoxDecoration(gradient: AppColors.scrim),
                    ),

                    // ── Overlaid title + subtitle ──────────────────────────
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: AppText.body.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (widget.subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.subtitle!,
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),

                    // ── Progress bar pinned to very bottom ─────────────────
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 3,
                      child: Row(
                        children: [
                          // Filled portion (accent colour)
                          Expanded(
                            flex: (clampedProgress * 1000).round(),
                            child: const ColoredBox(color: AppColors.accent),
                          ),
                          // Unfilled track (hairline colour)
                          Expanded(
                            flex: ((1.0 - clampedProgress) * 1000).round(),
                            child: const ColoredBox(color: AppColors.hairline),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
