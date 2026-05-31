import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Landscape "Continue Watching" card with a progress bar and press-scale.
///
/// No [BackdropFilter]. Image decoded at display size via [memCacheWidth].
/// Progress is clamped to [0, 1].
class ContinueCard extends StatefulWidget {
  const ContinueCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.headers,
    required this.progress,
    this.subtitle,
    this.onTap,
    this.width = 260,
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
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: SizedBox(
            width: widget.width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── 16:9 thumbnail with scrim, play button, progress bar ──
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Background / image
                        if (widget.imageUrl == null)
                          const ColoredBox(color: AppColors.surface2)
                        else
                          CachedNetworkImage(
                            imageUrl: widget.imageUrl!,
                            httpHeaders: widget.headers,
                            memCacheWidth: memW,
                            fit: BoxFit.cover,
                            fadeInDuration:
                                const Duration(milliseconds: 180),
                            placeholder: (context, url) =>
                                const ColoredBox(color: AppColors.surface2),
                            errorWidget: (context, url, err) =>
                                const ColoredBox(color: AppColors.surface2),
                          ),

                        // Bottom scrim
                        const DecoratedBox(
                          decoration:
                              BoxDecoration(gradient: AppColors.scrim),
                        ),

                        // Centered play button
                        Center(
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black
                                    .withValues(alpha: 0.45),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 26,
                              ),
                            ),
                          ),
                        ),

                        // Progress bar pinned to bottom
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: SizedBox(
                            height: 3,
                            child: Row(
                              children: [
                                // Filled portion
                                Expanded(
                                  flex: (clampedProgress * 1000).round(),
                                  child: const ColoredBox(
                                      color: AppColors.accent),
                                ),
                                // Unfilled track
                                Expanded(
                                  flex: ((1.0 - clampedProgress) * 1000)
                                      .round(),
                                  child: const ColoredBox(
                                      color: AppColors.hairline),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                // Title
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body
                      .copyWith(color: AppColors.textPrimary),
                ),

                // Optional subtitle
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
