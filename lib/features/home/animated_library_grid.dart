import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../core/ui/placement_slide.dart';

/// A grid whose membership changes glide instead of blinking.
///
/// Declarative lists (cubit/block state) rebuild with N−1 items and every
/// card after the gap teleports in one frame. This grid instead flips to the
/// final layout instantly and glides every moved card from its old slot to
/// its new one — the same placement animation Nuvio's `animateItem` gives
/// its library. Same-row moves come out purely horizontal, row-boundary
/// moves diagonal; both are covered because the travel is computed, not
/// measured. No opacity anywhere: fades read as appearing/vanishing, this is
/// pure slide.
///
/// Why not AnimatedGrid's removeItem exit: in a grid the collapsing slot
/// can't move anything by itself — a row stays full-height until its last
/// card leaves, so same-row neighbours would still teleport while only the
/// rows below glide. Per-card placement is the only motion that covers both.
///
/// A translate that ends at zero is always the true spot — even if slots
/// shift again or the user scrolls mid-flight — so a stale slide can never
/// strand a card off-place. Resorting snaps (no per-card travel is recorded
/// for it); the parent re-keys the grid on sort change anyway.
class AnimatedLibraryGrid<T> extends StatefulWidget {
  const AnimatedLibraryGrid({
    super.key,
    required this.items,
    required this.keyOf,
    required this.itemBuilder,
    required this.gridDelegate,
    this.padding,
    this.physics,
    this.slideDuration = const Duration(milliseconds: 300),
  });

  final List<T> items;
  final String Function(T item) keyOf;

  /// Normal cell. The slide ticket rides INSIDE any entrance wrapper
  /// (RevealItem): wrapping outside would destroy the entrance state and every
  /// moved card would replay its fade-in — which reads exactly like appearing
  /// out of nowhere. Always present (zero travel when still) so the cell
  /// subtree never changes shape and keyed cards keep their cached images.
  final Widget Function(
    BuildContext context,
    int index,
    T item,
    SlideSpec slide,
  )
  itemBuilder;

  final SliverGridDelegate gridDelegate;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;

  /// Placement glide duration. Nuvio uses 180ms; 300ms reads smoother on
  /// mid-range phones without feeling laggy.
  final Duration slideDuration;

  @override
  State<AnimatedLibraryGrid<T>> createState() => _AnimatedLibraryGridState<T>();
}

class _AnimatedLibraryGridState<T> extends State<AnimatedLibraryGrid<T>> {
  /// Item key → where its card starts gliding from. Filled when slots shift,
  /// pruned when keys leave the items or their glide completes.
  final Map<String, Offset> _placing = {};

  /// Last measured grid geometry, for placement math. Null until the first
  /// layout, or when the delegate isn't a fixed-count grid.
  _GridGeom? _geom;

  @override
  void didUpdateWidget(AnimatedLibraryGrid<T> old) {
    super.didUpdateWidget(old);
    if (identical(widget.items, old.items)) return;
    final oldIndex = <String, int>{};
    for (var i = 0; i < old.items.length; i++) {
      oldIndex.putIfAbsent(widget.keyOf(old.items[i]), () => i);
    }
    final g = _geom;
    if (g != null) {
      for (var i = 0; i < widget.items.length; i++) {
        final key = widget.keyOf(widget.items[i]);
        final from = oldIndex[key];
        if (from == null || from == i) continue;
        _placing[key] = g.slot(from) - g.slot(i);
      }
    }
    _placing.removeWhere(
      (k, _) => !widget.items.any((item) => widget.keyOf(item) == k),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _geom = _GridGeom.tryOf(
          widget.gridDelegate,
          constraints.maxWidth -
              (widget.padding?.resolve(Directionality.of(context)).horizontal ??
                  0),
        );
        // Index by key so the sliver reuses each entry's element when slots
        // shift — the card (and its cached image) travels instead of a fresh
        // card remounting there with a fade-in. Keys are namespaced
        // ('cell:<id>') so unrelated keyed children never collide.
        final indexByKey = <String, int>{};
        for (var i = 0; i < widget.items.length; i++) {
          indexByKey.putIfAbsent(widget.keyOf(widget.items[i]), () => i);
        }
        const keyPrefix = 'cell:';
        return GridView.builder(
          gridDelegate: widget.gridDelegate,
          padding: widget.padding,
          physics: widget.physics,
          scrollCacheExtent: const ScrollCacheExtent.pixels(800),
          itemCount: widget.items.length,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final v = key.value;
            if (!v.startsWith(keyPrefix)) return null;
            return indexByKey[v.substring(keyPrefix.length)];
          },
          itemBuilder: (context, index) {
            final item = widget.items[index];
            final key = widget.keyOf(item);
            final from = _placing[key] ?? Offset.zero;
            final slide = SlideSpec(
              from,
              () => _placing.remove(key),
              duration: widget.slideDuration,
            );
            return widget.itemBuilder(context, index, item, slide);
          },
        );
      },
    );
  }
}

/// Uniform-grid geometry for placement math.
class _GridGeom {
  _GridGeom({
    required this.columns,
    required this.cellW,
    required this.cellH,
    required this.cross,
    required this.main,
  });

  final int columns;
  final double cellW;
  final double cellH;
  final double cross;
  final double main;

  /// Slot top-left in grid content coordinates.
  Offset slot(int s) =>
      Offset((s % columns) * (cellW + cross), (s ~/ columns) * (cellH + main));

  static _GridGeom? tryOf(SliverGridDelegate delegate, double gridWidth) {
    if (delegate is! SliverGridDelegateWithFixedCrossAxisCount) return null;
    final cross = delegate.crossAxisSpacing;
    final cellW =
        (gridWidth - (delegate.crossAxisCount - 1) * cross) /
        delegate.crossAxisCount;
    if (cellW <= 0) return null;
    return _GridGeom(
      columns: delegate.crossAxisCount,
      cellW: cellW,
      cellH: cellW / delegate.childAspectRatio,
      cross: cross,
      main: delegate.mainAxisSpacing,
    );
  }
}

/// Where a card now sitting in [slot] travelled from: its old slot along the
/// row-major path. Same-row moves come out purely horizontal; row-boundary
/// moves diagonal. Pure geometry — no measurement needed, so it works on the
/// very first post-removal frame.
@visibleForTesting
Offset placementFrom({
  required int slot,
  required double cellW,
  required double cellH,
  required double cross,
  required double main,
  required int columns,
}) {
  Offset at(int s) =>
      Offset((s % columns) * (cellW + cross), (s ~/ columns) * (cellH + main));
  return at(slot + 1) - at(slot);
}
