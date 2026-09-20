import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../cache/app_image_cache.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// The square logo that identifies a source in a list.
///
/// One widget for every screen that lists sources, so they cannot drift apart:
/// the picker, the Sources screen, each ecosystem's own screen and the browse
/// lists all draw the same tile. [icon] is a URL; when there is none, or it is
/// still loading, or it fails, the tile falls back to the source's first
/// letter on a plate.
class SourceIconTile extends StatelessWidget {
  const SourceIconTile({
    super.key,
    required this.name,
    this.icon,
    this.size = 30,
  });

  /// Display name. Only its first letter is used, for the fallback.
  final String name;

  /// URL of the source's logo, when the catalogue or repo index named one.
  final String? icon;

  final double size;

  bool get _hasIcon => icon != null && icon!.isNotEmpty;

  double get _radius => size * 0.3;

  String get _initial {
    final n = name.trim();
    return n.isEmpty ? '?' : n.characters.first.toUpperCase();
  }

  /// Carries its own plate and centring rather than leaning on the outer box:
  /// this is ALSO handed to CachedNetworkImage as placeholder and errorWidget,
  /// and there it sits in a bare box that aligns top-left and paints nothing —
  /// a source whose icon url 404s drew a bare letter in the corner.
  Widget get _letterTile => Container(
    decoration: BoxDecoration(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(_radius),
    ),
    alignment: Alignment.center,
    child: Text(
      _initial,
      style: AppText.headline.copyWith(
        color: AppColors.textSecondary,
        fontSize: size * 0.47,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // No plate under a real icon. Extension logos ship with a pixel or two
        // of transparent margin, so the plate showed through as a grey frame
        // around every one of them; the letter carries its own plate instead.
        color: _hasIcon ? Colors.transparent : AppColors.surface2,
        borderRadius: BorderRadius.circular(_radius),
      ),
      alignment: Alignment.center,
      child: !_hasIcon
          ? _letterTile
          : ClipRRect(
              borderRadius: BorderRadius.circular(_radius),
              child: CachedNetworkImage(
                imageUrl: icon!,
                cacheManager: AppImageCache.manager,
                width: size,
                height: size,
                // contain, NOT cover: these are logos, and a good share of
                // them are wide wordmarks. cover cropped those to their middle
                // — 4K HDHUB came out as a sliver of letters with both ends
                // cut off. contain shrinks a wide logo instead of beheading
                // it; square icons look the same either way.
                fit: BoxFit.contain,
                placeholder: (context, url) => _letterTile,
                errorWidget: (context, url, error) => _letterTile,
              ),
            ),
    );
  }
}
