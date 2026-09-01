import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'reveal_item.dart';

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
        _Header(title: title, overline: overline, onSeeAll: onSeeAll),
        SizedBox(
          height: itemHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // With a screen reader on, build every item (not just the lazy
            // window) so TalkBack can focus each one and the row auto-scrolls to
            // it — otherwise horizontal swipe navigation stalls at the first few.
            // Sighted users keep the lazy 600px window unchanged.
            cacheExtent: MediaQuery.of(context).accessibleNavigation
                ? double.infinity
                : 600,
            itemCount: itemCount,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SizedBox(
                width: itemWidth,
                child: RepaintBoundary(
                  child: RevealItem(
                    index: index,
                    child: itemBuilder(context, index),
                  ),
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
  const _Header({required this.title, this.overline, this.onSeeAll});

  final String title;
  final String? overline;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Top clears the previous row's posters so each section reads as its
      // own block; bottom is the tighter title-to-poster gap within this row.
      // The two are deliberately far apart — a header belongs to the row under
      // it, so the space above must beat the space below or the title reads as
      // a caption on the row above. Now that the poster title is a fixed two
      // lines, this gap is the same under every row instead of shifting with
      // how long the last title happened to be.
      padding: const EdgeInsets.fromLTRB(16, 26, 16, 14),
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
                Expanded(child: Text(title, style: AppText.headline)),
                GestureDetector(
                  onTap: onSeeAll,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      'See All',
                      style: AppText.caption.copyWith(color: AppColors.accent),
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
