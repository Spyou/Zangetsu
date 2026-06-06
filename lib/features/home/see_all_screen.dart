import 'package:flutter/material.dart';

import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';

/// Full-grid view of a single home row ("See All"). Reuses the home's tap /
/// long-press handlers so an item opens the same Detail / info card.
class SeeAllScreen extends StatelessWidget {
  const SeeAllScreen({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onLongPress,
  });

  final String title;
  final List<MediaItem> items;
  final void Function(MediaItem) onTap;
  final void Function(MediaItem)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cellW = (MediaQuery.of(context).size.width - 32 - 24) / 3;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(title, style: AppText.headline),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        cacheExtent: 800,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.62,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          return PosterCard(
            title: item.title,
            imageUrl: item.cover,
            headers: item.coverHeaders,
            cellWidth: cellW,
            onTap: () => onTap(item),
            onLongPress: onLongPress == null ? null : () => onLongPress!(item),
          );
        },
      ),
    );
  }
}
