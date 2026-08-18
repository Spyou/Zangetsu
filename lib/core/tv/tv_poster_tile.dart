import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../ui/poster_card.dart';
import 'tv_focusable.dart';

/// Shared TV grid tile. The poster ARTWORK gets the white-outline float focus
/// (the outline hugs the art) and the title sits BELOW the outline — so the
/// My List / See-all / Search grids all match the Home rows.
class TvPosterTile extends StatelessWidget {
  const TvPosterTile({
    super.key,
    required this.title,
    this.imageUrl,
    this.headers,
    this.tags = const [],
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
  });

  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final List<String> tags;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: TvFocusable(
            autofocus: autofocus,
            variant: TvFocusVariant.float,
            scale: 1.04,
            onTap: onTap,
            onLongPress: onLongPress,
            semanticLabel: title,
            child: PosterCard(
              title: title,
              imageUrl: imageUrl,
              headers: headers,
              tags: tags,
              showTitle: false,
              // Touch gestures are disabled on TV; TvFocusable handles OK-key
              // (including held-OK long-press when [onLongPress] is set).
              onTap: null,
              onLongPress: null,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // The focusable above already announces the title via semanticLabel —
        // exclude this sibling so TalkBack doesn't say it twice.
        ExcludeSemantics(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
