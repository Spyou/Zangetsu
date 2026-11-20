import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../cache/app_image_cache.dart';
import '../models/media_item.dart';

/// Fanned deck of covers for a grouped series card — [child] (usually a
/// PosterCard) in front, with up to two more covers peeking out rotated
/// behind it on each side, like a hand of cards. Mirrors the "stacked cover"
/// grid card from other library apps that support manual series grouping.
///
/// Only the first 3 of [covers] are drawn (center + one per side) — a 5-cover
/// fan needs more surrounding space than a tight grid cell has here.
class SeriesStackedCover extends StatelessWidget {
  const SeriesStackedCover({super.key, required this.covers, required this.child});

  final List<MediaItem> covers;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        if (covers.length > 2)
          _peek(covers[2], xFactor: 0.12, rotation: -0.22, scale: 0.88, opacity: 0.55),
        if (covers.length > 1)
          _peek(covers[1], xFactor: -0.1, rotation: 0.14, scale: 0.94, opacity: 0.8),
        child,
      ],
    );
  }

  Widget _peek(
    MediaItem cover, {
    required double xFactor,
    required double rotation,
    required double scale,
    required double opacity,
  }) {
    return FractionalTranslation(
      translation: Offset(xFactor, 0),
      child: Transform.rotate(
        angle: rotation,
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: cover.cover == null
                  ? Container(color: Colors.black26)
                  : CachedNetworkImage(
                      imageUrl: cover.cover!,
                      cacheManager: AppImageCache.manager,
                      httpHeaders: cover.coverHeaders,
                      fit: BoxFit.cover,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
