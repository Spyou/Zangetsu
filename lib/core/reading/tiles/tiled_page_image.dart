import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'tile_decoder.dart';
import 'tile_pyramid.dart';

/// Draws a page from tiles: a coarse base layer, with sharper tiles over it
/// for whatever is on screen.
///
/// When tiling is not possible — an old Android, a format the platform
/// declines, an unreadable file — this builds [fallbackBuilder] instead and
/// never shows anything of its own. Half a tiled page is worse than none.
class TiledPageImage extends StatefulWidget {
  const TiledPageImage({
    super.key,
    required this.path,
    required this.imageWidth,
    required this.imageHeight,
    required this.decoder,
    required this.fallbackBuilder,
  });

  final String path;
  final int imageWidth;
  final int imageHeight;
  final TileSource decoder;
  final Widget Function() fallbackBuilder;

  @override
  State<TiledPageImage> createState() => _TiledPageImageState();
}

class _TiledPageImageState extends State<TiledPageImage> {
  late final TilePyramid _pyramid = TilePyramid(
    imageWidth: widget.imageWidth,
    imageHeight: widget.imageHeight,
  );

  final _tiles = <TileSpec, TileImage>{};
  bool _failed = false;
  bool _baseRequested = false;
  bool _refining = false;

  @override
  void initState() {
    super.initState();
    if (!widget.decoder.available) _failed = true;
  }

  @override
  void dispose() {
    for (final tile in _tiles.values) {
      tile.dispose();
    }
    _tiles.clear();
    widget.decoder.release(widget.path);
    super.dispose();
  }

  Future<void> _requestBase() async {
    if (_baseRequested) return;
    _baseRequested = true;
    final tile = await widget.decoder.decode(widget.path, _pyramid.baseTile);
    if (!mounted) return;
    if (tile == null) {
      // The base layer is the proof that this page can tile at all. If it
      // cannot be had, this page uses the old path entirely.
      setState(() => _failed = true);
      return;
    }
    setState(() => _tiles[tile.spec] = tile);
    _refineForViewport();
  }

  /// The part of this page currently on screen, in full-image pixels.
  ///
  /// The page lives inside a sliver, so the widget cannot know what part of
  /// itself is visible without asking the viewport it sits in.
  Rect? _visibleSource() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.isEmpty) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;

    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return null;
    final offsetToTop =
        viewport.getOffsetToReveal(box, 0.0).offset - scrollable.position.pixels;
    final screenHeight = scrollable.position.viewportDimension;

    // Where the page's own top sits relative to the screen, converted back
    // into image pixels.
    final pxPerImagePx = box.size.height / widget.imageHeight;
    if (pxPerImagePx <= 0) return null;
    final topImagePx = (-offsetToTop) / pxPerImagePx;
    final heightImagePx = screenHeight / pxPerImagePx;

    return Rect.fromLTWH(
      0,
      topImagePx,
      widget.imageWidth.toDouble(),
      heightImagePx,
    ).intersect(
      Rect.fromLTWH(
        0,
        0,
        widget.imageWidth.toDouble(),
        widget.imageHeight.toDouble(),
      ),
    );
  }

  /// Asks for sharp tiles covering what is on screen, and drops tiles for
  /// what is not. The base layer is never dropped — it is what stops the page
  /// going blank.
  Future<void> _refineForViewport() async {
    if (_failed || !mounted || _refining) return;
    _refining = true;
    try {
      final visible = _visibleSource();
      if (visible == null || visible.isEmpty) return;

      final box = context.findRenderObject() as RenderBox?;
      if (box == null) return;
      final scale = box.size.width / widget.imageWidth;
      final sample = _pyramid.sampleFor(scale);
      final wanted = _pyramid.tilesFor(visible, sample).toSet();

      // Free anything that is neither wanted nor the base layer.
      final base = _pyramid.baseTile;
      for (final spec in _tiles.keys.toList()) {
        if (spec != base && !wanted.contains(spec)) {
          _tiles.remove(spec)?.dispose();
        }
      }

      for (final spec in wanted) {
        if (_tiles.containsKey(spec)) continue;
        final tile = await widget.decoder.decode(widget.path, spec);
        if (tile == null) continue;
        if (!mounted || _tiles.containsKey(spec)) {
          tile.dispose();
          if (!mounted) return;
          continue;
        }
        setState(() => _tiles[spec] = tile);
      }
    } finally {
      _refining = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallbackBuilder();

    if (!_baseRequested) {
      // Off the build phase.
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestBase());
    } else {
      // Scrolling changes what is visible, so refinement is re-checked after
      // each frame this page takes part in. `_refineForViewport` is cheap when
      // nothing has changed: every wanted tile is already held.
      WidgetsBinding.instance.addPostFrameCallback((_) => _refineForViewport());
    }

    return AspectRatio(
      aspectRatio: widget.imageWidth / widget.imageHeight,
      child: CustomPaint(
        painter: _TilePainter(
          tiles: _tiles.values.toList(growable: false),
          imageWidth: widget.imageWidth.toDouble(),
          imageHeight: widget.imageHeight.toDouble(),
        ),
      ),
    );
  }
}

/// Paints tiles coarsest-first, so a sharper tile always lands on top of the
/// blurry one it replaces rather than the other way round.
class _TilePainter extends CustomPainter {
  _TilePainter({
    required this.tiles,
    required this.imageWidth,
    required this.imageHeight,
  });

  final List<TileImage> tiles;
  final double imageWidth;
  final double imageHeight;

  @override
  void paint(Canvas canvas, Size size) {
    if (tiles.isEmpty) return;
    final sorted = [...tiles]
      ..sort((a, b) => b.spec.sample.compareTo(a.spec.sample));
    final scaleX = size.width / imageWidth;
    final scaleY = size.height / imageHeight;
    final paint = Paint()..filterQuality = FilterQuality.low;

    for (final tile in sorted) {
      final src = Rect.fromLTWH(
        0,
        0,
        tile.image.width.toDouble(),
        tile.image.height.toDouble(),
      );
      final dst = Rect.fromLTRB(
        tile.spec.source.left * scaleX,
        tile.spec.source.top * scaleY,
        tile.spec.source.right * scaleX,
        tile.spec.source.bottom * scaleY,
      );
      canvas.drawImageRect(tile.image, src, dst, paint);
    }
  }

  @override
  bool shouldRepaint(_TilePainter old) =>
      !listEquals(old.tiles, tiles) ||
      old.imageWidth != imageWidth ||
      old.imageHeight != imageHeight;
}
