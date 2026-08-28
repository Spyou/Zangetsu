import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../cache/app_image_cache.dart';
import '../di/injector.dart';
import '../playback/playback_prefs.dart';

import 'image_fade.dart';
import '../aniyomi/aniyomi_image_provider.dart';
import '../mihon/mihon_image_provider.dart';
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
    this.qualityBadge,
    this.dubBadge,
  });
  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Small overlay badges drawn at the bottom-left of the art (e.g. SUB/DUB).
  final List<String> tags;

  /// Release quality ("4K", "HD", "CAM"), drawn in the TOP-RIGHT corner —
  /// its own spot, so it reads at a glance and never competes with the
  /// SUB/DUB tags along the bottom. Null for the many sources that don't
  /// report one, and the corner stays empty.
  ///
  /// Pass the raw label; whether it's actually SHOWN is decided here, against
  /// the user's setting, inside a listener scoped to this one badge. That way
  /// flipping the switch repaints the corner and nothing else — no screen
  /// rebuild, and no listener that anything else can trip.
  final String? qualityBadge;

  /// "SUB" / "DUB" / "SUB DUB" for anime listings that report it. Sits opposite
  /// the quality badge and rides the SAME setting — one switch for poster
  /// badges, not one per kind.
  final String? dubBadge;
  final double cellWidth;

  /// When false, render only the poster art (no title below). Used on TV so the
  /// D-pad focus highlight wraps just the thumbnail; the caller draws the title
  /// separately. Defaults to true — every phone call site is unchanged.
  final bool showTitle;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

/// The user's "Poster badges" setting, read defensively: poster rows get
/// built in widget tests with no PlaybackPrefs registered, and a badge is not
/// worth throwing over.
bool get _showBadges {
  try {
    return sl<PlaybackPrefs>().qualityBadges;
  } catch (_) {
    return true;
  }
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

  /// The Mihon source id for this cover, or null. Twin of [_aniSrcId] — routes
  /// Cloudflare-gated manga covers through the native, cf_clearance-carrying
  /// [MihonImage] instead of CachedNetworkImage.
  int? get _mihonSrcId {
    final raw = widget.headers?['x-mihon-src'];
    if (raw == null || widget.imageUrl == null) return null;
    return int.tryParse(raw);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final memW = (widget.cellWidth * dpr).round();
    final aniSrcId = _aniSrcId;
    final mihonSrcId = _mihonSrcId;
    // Only wire the press-scale handlers when this card is actually tappable.
    // On TV the card is wrapped in a TvFocusable and passed onTap: null — if we
    // still attached onTapDown/Up/Cancel they'd claim the tap in the gesture
    // arena and do nothing (onTap is null), swallowing the touch before the
    // parent TvFocusable's onTap could fire. Null handlers = no recognizer = the
    // parent gets the tap. (D-pad is unaffected; it never uses the arena.)
    final interactive = widget.onTap != null || widget.onLongPress != null;
    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onTapDown: interactive ? _handleTapDown : null,
        onTapUp: interactive ? _handleTapUp : null,
        onTapCancel: interactive ? _handleTapCancel : null,
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
                        ColoredBox(color: AppColors.surface2)
                      else if (aniSrcId != null || mihonSrcId != null)
                        // Aniyomi/Mihon path: fetch bytes through the source's own
                        // OkHttpClient (carries CF session cookies) instead of
                        // going through CachedNetworkImage which can't pass CF.
                        Image(
                          // Resize to the cell's pixel width so a big cover
                          // doesn't sit full-res in the image cache (matches the
                          // memCacheWidth the non-native path already uses).
                          image: ResizeImage(
                            aniSrcId != null
                                ? AniyomiImage(aniSrcId, widget.imageUrl!)
                                : MihonImage(mihonSrcId!, widget.imageUrl!),
                            width: memW,
                          ),
                          fit: BoxFit.cover,
                          frameBuilder: imageFadeIn,
                          loadingBuilder: (_, child, progress) =>
                              progress == null
                                  ? child
                                  : ColoredBox(color: AppColors.surface2),
                          errorBuilder: (context, error, stackTrace) =>
                              ColoredBox(color: AppColors.surface2),
                        )
                      else
                        CachedNetworkImage(
                          imageUrl: widget.imageUrl!,
                          cacheManager: AppImageCache.manager,
                          httpHeaders: widget.headers,
                          memCacheWidth: memW,
                          fit: BoxFit.cover,
                          fadeInDuration: const Duration(milliseconds: 180),
                          placeholder: (context, url) =>
                              ColoredBox(color: AppColors.surface2),
                          errorWidget: (context, url, err) =>
                              ColoredBox(color: AppColors.surface2),
                        ),
                      const DecoratedBox(
                        decoration: BoxDecoration(gradient: AppColors.scrim),
                      ),
                      if (widget.qualityBadge != null)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: ValueListenableBuilder<int>(
                            valueListenable: PlaybackPrefs.badgeRevision,
                            builder: (_, _, _) => _showBadges
                                ? _PosterTag(widget.qualityBadge!)
                                : const SizedBox.shrink(),
                          ),
                        ),
                      if (widget.dubBadge != null)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: ValueListenableBuilder<int>(
                            valueListenable: PlaybackPrefs.badgeRevision,
                            builder: (_, _, _) => _showBadges
                                ? _PosterTag(widget.dubBadge!)
                                : const SizedBox.shrink(),
                          ),
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
