import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import '../playback/playback_prefs.dart';
import '../ui/poster_card.dart';
import 'tv_focusable.dart';

/// Shared TV grid tile. Title placement and artwork follow poster settings;
/// focus remains on the artwork itself.
class TvPosterTile extends StatelessWidget {
  const TvPosterTile({
    super.key,
    required this.title,
    this.imageUrl,
    this.wideImageUrl,
    this.headers,
    this.tags = const [],
    this.qualityBadge,
    this.dubBadge,
    this.scoreBadge,
    this.genres = const [],
    this.isAdult = false,
    this.progressBadge,
    this.logoItem,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
  });

  final String title;
  final String? imageUrl;
  final String? wideImageUrl;
  final Map<String, String>? headers;
  final List<String> tags;

  /// Release quality drawn in the poster's top-right corner. See [PosterCard].
  final String? qualityBadge;
  final String? dubBadge;
  final int? scoreBadge;
  final List<String> genres;
  final bool isAdult;
  final String? progressBadge;
  final MediaItem? logoItem;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final wide = posterLayout(context) == PosterCardLayout.wide;
    final titleInside = posterTitleInside(context, wide: wide);
    return LayoutBuilder(
      builder: (context, tileConstraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: wide ? 16 / 9 : 2 / 3,
            child: TvFocusable(
              autofocus: autofocus,
              variant: TvFocusVariant.float,
              scale: 1.04,
              borderRadius: 12,
              onTap: onTap,
              onLongPress: onLongPress,
              semanticLabel: title,
              child: LayoutBuilder(
                builder: (context, constraints) => PosterCard(
                  title: title,
                  logoItem: logoItem,
                  imageUrl: imageUrl,
                  wideImageUrl: wideImageUrl,
                  headers: headers,
                  tags: tags,
                  qualityBadge: qualityBadge,
                  dubBadge: dubBadge,
                  scoreBadge: scoreBadge,
                  genres: genres,
                  isAdult: isAdult,
                  progressBadge: progressBadge,
                  cellWidth: constraints.maxWidth,
                  showTitle: false,
                  // Touch gestures are disabled on TV; TvFocusable handles OK-key
                  // (including held-OK long-press when [onLongPress] is set).
                  onTap: null,
                  onLongPress: null,
                ),
              ),
            ),
          ),
          if (!titleInside) ...[
            const SizedBox(height: 8),
            // The focusable above already announces the title via semanticLabel.
            ExcludeSemantics(
              child: PosterCardTitle(
                title: title,
                logoItem: logoItem,
                width: tileConstraints.maxWidth,
                maxHeight: 20,
                maxLines: 1,
                inside: false,
                textStyle: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
