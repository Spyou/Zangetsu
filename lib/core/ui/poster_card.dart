import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../aniyomi/aniyomi_image_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.headers,
    this.onTap,
    this.onLongPress,
    this.tags = const [],
    this.cellWidth = 180,
    this.showTitle = true,
  });
  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Small overlay badges drawn at the bottom-left of the art (e.g. SUB/DUB).
  final List<String> tags;
  final double cellWidth;

  /// When false, render only the poster art (no title below). Used on TV so the
  /// D-pad focus highlight wraps just the thumbnail; the caller draws the title
  /// separately. Defaults to true — every phone call site is unchanged.
  final bool showTitle;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _pressed = false;

  void _handleTapDown(TapDownDetails _) => setState(() => _pressed = true);
  void _handleTapUp(TapUpDetails _) => setState(() => _pressed = false);
  void _handleTapCancel() => setState(() => _pressed = false);

  /// The Aniyomi source id for this cover, or null when the header is absent
  /// or malformed. Parsing here (instead of inline with `!`/`int.parse`) keeps
  /// a bad `x-ani-src` value or a null cover from throwing during build — an
  /// unhandled throw here renders the whole card as Flutter's grey error box.
  int? get _aniSrcId {
    final raw = widget.headers?['x-ani-src'];
    if (raw == null || widget.imageUrl == null) return null;
    return int.tryParse(raw);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final memW = (widget.cellWidth * dpr).round();
    final aniSrcId = _aniSrcId;
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
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.imageUrl == null)
                        const ColoredBox(color: AppColors.surface2)
                      else if (aniSrcId != null)
                        // Aniyomi path: fetch bytes through the source's own
                        // OkHttpClient (carries CF session cookies) instead of
                        // going through CachedNetworkImage which can't pass CF.
                        Image(
                          image: AniyomiImage(
                            aniSrcId,
                            widget.imageUrl!,
                          ),
                          fit: BoxFit.cover,
                          loadingBuilder: (_, child, progress) =>
                              progress == null
                                  ? child
                                  : const ColoredBox(color: AppColors.surface2),
                          errorBuilder: (context, error, stackTrace) =>
                              const ColoredBox(color: AppColors.surface2),
                        )
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
                      const DecoratedBox(
                        decoration: BoxDecoration(gradient: AppColors.scrim),
                      ),
                      if (widget.tags.isNotEmpty)
                        Positioned(
                          left: 6,
                          bottom: 6,
                          right: 6,
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final t in widget.tags) _PosterTag(t),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (widget.showTitle) ...[
                const SizedBox(height: 8),
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: AppColors.textPrimary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small frosted badge drawn over poster art (e.g. "SUB", "DUB", "MOVIE").
class _PosterTag extends StatelessWidget {
  const _PosterTag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 9,
          height: 1.1,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: Colors.white,
        ),
      ),
    );
  }
}
