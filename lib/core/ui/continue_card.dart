import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Portrait "Continue Watching" poster.
///
/// Same footprint as [PosterCard] (so the row visually matches the other browse
/// rows — no more oversized landscape cards), with three additions that mark it
/// as a resume tile: a centred play affordance, a thin progress bar pinned to
/// the base of the art, and an episode subtitle below.
///
/// No [BackdropFilter]. Image decoded at display size via [memCacheWidth].
class ContinueCard extends StatefulWidget {
  const ContinueCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.headers,
    required this.progress,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.cellWidth = 140,
  });

  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;

  /// Playback progress in [0, 1].
  final double progress;

  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double cellWidth;

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
    final memW = (widget.cellWidth * dpr).round();
    final p = widget.progress.clamp(0.0, 1.0);

    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Poster art (fills the cell, same as PosterCard) ───────────
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.imageUrl == null || widget.imageUrl!.isEmpty)
                        const ColoredBox(color: AppColors.surface2)
                      else
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
                        ),

                      // Subtle scrim for the play affordance + progress contrast.
                      const DecoratedBox(
                        decoration: BoxDecoration(gradient: AppColors.scrim),
                      ),

                      // Centre resume affordance.
                      Center(
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0x73000000),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.9),
                              width: 1.5,
                            ),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),

                      // Progress bar pinned to the base of the art.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 3,
                        child: Row(
                          children: [
                            Expanded(
                              flex: (p * 1000).round(),
                              child: const ColoredBox(color: AppColors.accent),
                            ),
                            Expanded(
                              flex: ((1.0 - p) * 1000).round(),
                              child: const ColoredBox(
                                color: AppColors.hairline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // ── Title + episode subtitle ──────────────────────────────────
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: AppColors.textPrimary),
              ),
              if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  widget.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
