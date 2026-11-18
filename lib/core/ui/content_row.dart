import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'placement_slide.dart';
import 'reveal_item.dart';

/// An edge-bleed horizontal content row with an optional header and "See All" link.
///
/// Content scrolls lazily via [ListView.builder] so items off-screen are never
/// built. Left/right padding is 16 px; items spill off the right edge to signal
/// "more" (no right-side padding on the list itself).
///
/// When [itemKeys] is provided (one stable key per item, aligned with
/// [itemCount]), the row diffs items across rebuilds and glides moved cards
/// from their old slot instead of teleporting them — the same placement
/// animation as the library grid. Uniform-width rows only (a single
/// [itemWidth] plus the 12px gap); rows with per-index widths skip placement
/// and behave exactly as before.
class ContentRow extends StatefulWidget {
  const ContentRow({
    super.key,
    required this.title,
    this.overline,
    required this.itemCount,
    required this.itemBuilder,
    this.itemWidth = 124,
    this.itemWidthForIndex,
    this.itemHeight = 210,
    this.onSeeAll,
    this.itemKeys,
    // 300ms like the library grid: reads as a glide, not a snap.
    this.slideDuration = const Duration(milliseconds: 300),
  });

  final String title;
  final String? overline;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double itemWidth;
  final double Function(int index)? itemWidthForIndex;
  final double itemHeight;
  final VoidCallback? onSeeAll;
  final List<String>? itemKeys;
  final Duration slideDuration;

  @override
  State<ContentRow> createState() => _ContentRowState();
}

class _ContentRowState extends State<ContentRow> {
  /// Item key → where its card starts gliding from. Same shape as the library
  /// grid's map: ends at zero, which is always the true spot.
  final Map<String, Offset> _placing = {};

  @override
  void didUpdateWidget(ContentRow old) {
    super.didUpdateWidget(old);
    final keys = widget.itemKeys;
    if (keys == null || widget.itemWidthForIndex != null) return;
    if (identical(keys, _prevKeys)) return;
    final step = widget.itemWidth + 12;
    final oldIndex = <String, int>{};
    for (var i = 0; i < _prevKeys.length; i++) {
      oldIndex.putIfAbsent(_prevKeys[i], () => i);
    }
    for (var i = 0; i < keys.length; i++) {
      final from = oldIndex[keys[i]];
      if (from == null || from == i) continue;
      // Everything moves along one axis here: left by the slots jumped.
      _placing[keys[i]] = Offset((from - i) * step, 0);
    }
    _placing.removeWhere((k, _) => !keys.contains(k));
    _prevKeys = keys;
  }

  List<String> _prevKeys = const [];

  @override
  Widget build(BuildContext context) {
    // Baseline the key list on first build (didUpdateWidget never runs for
    // it). Mutating here triggers no rebuild — it only keeps the next diff
    // honest — and the next build recomputes from scratch anyway.
    final keys = widget.itemKeys;
    if (_prevKeys.isEmpty && keys != null && keys.isNotEmpty) {
      _prevKeys = keys;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(
          title: widget.title,
          overline: widget.overline,
          onSeeAll: widget.onSeeAll,
        ),
        SizedBox(
          height: widget.itemHeight,
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
            itemCount: widget.itemCount,
            // Keyed cells: each entry's element (image included) travels to
            // its new slot instead of a fresh card remounting there with a
            // fade-in. Null keys (rows that don't opt in) behave exactly as
            // before.
            findChildIndexCallback: (key) {
              final keys = widget.itemKeys;
              if (keys == null || key is! ValueKey<String>) return null;
              const prefix = 'cell:';
              final v = key.value;
              if (!v.startsWith(prefix)) return null;
              final i = keys.indexOf(v.substring(prefix.length));
              return i < 0 ? null : i;
            },
            itemBuilder: (context, index) {
              final keys = widget.itemKeys;
              final key = keys != null && index < keys.length
                  ? keys[index]
                  : null;
              final from = key == null
                  ? Offset.zero
                  : (_placing[key] ?? Offset.zero);
              return Padding(
                // The key lives on the slot widget itself: only direct sliver
                // children participate in key-based moves, so a key deeper
                // inside would remount (and replay the entrance) on every
                // shift.
                key: key == null ? null : ValueKey('cell:$key'),
                padding: const EdgeInsetsDirectional.only(end: 12),
                child: SizedBox(
                  width:
                      widget.itemWidthForIndex?.call(index) ?? widget.itemWidth,
                  child: RepaintBoundary(
                    child: RevealItem(
                      index: index,
                      // The slide rides INSIDE the entrance wrapper for the
                      // same reason — and stays mounted (zero travel when
                      // still) so the subtree shape never changes and cached
                      // images never remount.
                      child: PlacementSlide(
                        from: from,
                        duration: widget.slideDuration,
                        onDone: key == null
                            ? () {}
                            : () => _placing.remove(key),
                        child: widget.itemBuilder(context, index),
                      ),
                    ),
                  ),
                ),
              );
            },
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
                    padding: const EdgeInsetsDirectional.only(start: 8),
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
