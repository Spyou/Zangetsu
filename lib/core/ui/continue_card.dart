import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../aniyomi/aniyomi_image_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Landscape (16:9) "Continue Watching" card — the episode thumbnail with the
/// title + episode label overlaid bottom-left on a scrim, and a resume progress
/// bar pinned to the base. Used only in the home Continue Watching row.
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
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Landscape art (fills the 16:9 cell) ─────────────────────
                if (widget.imageUrl == null || widget.imageUrl!.isEmpty)
                  ColoredBox(color: AppColors.surface2)
                else if (widget.headers?['x-ani-src'] != null)
                  // Cloudflare-walled Aniyomi image — load via the source's
                  // native client instead of CachedNetworkImage.
                  Image(
                    image: ResizeImage(
                      AniyomiImage(
                        int.parse(widget.headers!['x-ani-src']!),
                        widget.imageUrl!,
                      ),
                      width: memW,
                    ),
                    fit: BoxFit.cover,
                    errorBuilder: (context, err, st) =>
                        ColoredBox(color: AppColors.surface2),
                  )
                else
                  CachedNetworkImage(
                    imageUrl: widget.imageUrl!,
                    httpHeaders: widget.headers,
                    memCacheWidth: memW,
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 180),
                    placeholder: (context, url) =>
                        ColoredBox(color: AppColors.surface2),
                    errorWidget: (context, url, err) =>
                        ColoredBox(color: AppColors.surface2),
                  ),

                // ── Bottom scrim so the title/episode stay legible ──────────
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.center,
                      colors: [Color(0xD9000000), Color(0x00000000)],
                    ),
                  ),
                ),

                // ── Title + episode label, bottom-left (above the bar) ──────
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 9,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (widget.subtitle != null &&
                          widget.subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          widget.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // ── Resume progress bar pinned to the base ──────────────────
                // FractionallySizedBox (not Expanded/flex) so 0% and 100% both
                // render without an assertion.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 4,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: p,
                        child: ColoredBox(color: AppColors.accent),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
