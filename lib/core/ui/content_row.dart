import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// An edge-bleed horizontal content row with an optional header and "See All" link.
///
/// Content scrolls lazily via [ListView.builder] so items off-screen are never
/// built. Left/right padding is 16 px; items spill off the right edge to signal
/// "more" (no right-side padding on the list itself).
class ContentRow extends StatelessWidget {
  const ContentRow({
    super.key,
    required this.title,
    this.overline,
    required this.itemCount,
    required this.itemBuilder,
    this.itemWidth = 124,
    this.itemHeight = 210,
    this.onSeeAll,
  });

  final String title;
  final String? overline;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double itemWidth;
  final double itemHeight;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(
          title: title,
          overline: overline,
          onSeeAll: onSeeAll,
        ),
        SizedBox(
          height: itemHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            cacheExtent: 600,
            itemCount: itemCount,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SizedBox(
                width: itemWidth,
                child: RepaintBoundary(
                  child: itemBuilder(context, index),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    this.overline,
    this.onSeeAll,
  });

  final String title;
  final String? overline;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (overline != null) ...[
            Text(overline!, style: AppText.overline),
            const SizedBox(height: 2),
          ],
          if (onSeeAll != null)
            Row(
              children: [
                Expanded(
                  child: Text(title, style: AppText.headline),
                ),
                GestureDetector(
                  onTap: onSeeAll,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      'See All',
                      style: AppText.caption
                          .copyWith(color: AppColors.accent),
                    ),
                  ),
                ),
              ],
            )
          else
            Text(title, style: AppText.headline),
        ],
      ),
    );
  }
}
