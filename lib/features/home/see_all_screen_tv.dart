import 'package:flutter/material.dart';

import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/ui/poster_card.dart';

/// TV variant of [SeeAllScreen]: a full-screen D-pad-navigable poster grid.
///
/// Constructor is byte-compatible with [SeeAllScreen] so the caller's
/// `if (isTv)` branch is a one-line forwarding return.
/// The phone [SeeAllScreen] is byte-identical except for the single
/// `if (sl<AppMode>().isTv) return SeeAllScreenTv(...)` branch added at
/// the top of [SeeAllScreen.build].
class SeeAllScreenTv extends StatelessWidget {
  const SeeAllScreenTv({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onLongPress,
    this.tagsFor,
  });

  final String title;
  final List<MediaItem> items;
  final void Function(MediaItem) onTap;
  final void Function(MediaItem)? onLongPress;

  /// Optional per-item poster badges (e.g. SUB/DUB/MOVIE). Mirrors
  /// [SeeAllScreen.tagsFor] so callers are unchanged.
  final List<String> Function(MediaItem)? tagsFor;

  /// 5 columns matches a typical 1080p TV at ~140 dp card width + margins.
  static const int _crossAxisCount = 5;
  static const double _cardWidth = 140;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        // Suppress the touch-only auto back arrow; TvBackButton in the body
        // Stack provides a D-pad-focusable alternative.
        automaticallyImplyLeading: false,
        title: Text(title, style: AppText.headline),
      ),
      body: Stack(
        children: [
          GridView.builder(
            padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
            cacheExtent: 800,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _crossAxisCount,
              childAspectRatio: 0.62,
              crossAxisSpacing: 16,
              mainAxisSpacing: 20,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              return TvFocusable(
                autofocus: i == 0,
                onTap: () => onTap(item),
                child: PosterCard(
                  title: item.title,
                  imageUrl: item.cover,
                  headers: item.coverHeaders,
                  tags: tagsFor?.call(item) ?? const [],
                  cellWidth: _cardWidth,
                  // Touch gestures are disabled on TV; [TvFocusable] handles
                  // OK-key selection.
                  onTap: null,
                  onLongPress: null,
                ),
              );
            },
          ),
          // D-pad-focusable back button at top-left — reachable via D-pad up/left
          // from the first poster without stealing the initial autofocus.
          const Positioned(top: 8, left: 8, child: TvBackButton()),
        ],
      ),
    );
  }
}
