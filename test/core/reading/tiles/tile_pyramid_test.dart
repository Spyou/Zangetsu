import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tiles/tile_pyramid.dart';

void main() {
  group('TilePyramid', () {
    // A tall manhwa page: this is the shape the whole feature exists for.
    final tall = TilePyramid(imageWidth: 1080, imageHeight: 6000);

    test('the base level fits the whole page in one tile', () {
      final base = tall.baseTile;
      expect(base.sample, tall.maxSample);
      expect(base.source, Rect.fromLTWH(0, 0, 1080, 6000));
      // one tile at that level
      expect(tall.tilesFor(Rect.fromLTWH(0, 0, 1080, 6000), tall.maxSample),
          hasLength(1));
    });

    test('the coarsest level is small enough to be nearly free', () {
      // 6000 / maxSample must fit inside one 512px tile.
      expect(6000 / tall.maxSample, lessThanOrEqualTo(512));
      expect(1080 / tall.maxSample, lessThanOrEqualTo(512));
    });

    test('full zoom asks for full resolution', () {
      expect(tall.sampleFor(1.0), 1);
    });

    test('zoomed out asks for a coarser level', () {
      expect(tall.sampleFor(0.5), 2);
      expect(tall.sampleFor(0.25), 4);
      expect(tall.sampleFor(0.1), 8);
    });

    test('a scale of zero or less falls back to the coarsest level', () {
      expect(tall.sampleFor(0), tall.maxSample);
      expect(tall.sampleFor(-1), tall.maxSample);
    });

    test('never returns a level finer than full resolution', () {
      expect(tall.sampleFor(4.0), 1);
    });

    // The point of the whole exercise: a screenful of a 6000px page must not
    // ask for the whole page.
    test('only tiles overlapping the viewport are returned', () {
      final visible = Rect.fromLTWH(0, 2400, 1080, 2400);
      final tiles = tall.tilesFor(visible, 1);
      expect(tiles, isNotEmpty);
      for (final t in tiles) {
        expect(t.source.overlaps(visible), isTrue,
            reason: '${t.source} does not touch the viewport');
      }
      // and far less than the whole page
      final whole = tall.tilesFor(Rect.fromLTWH(0, 0, 1080, 6000), 1);
      expect(tiles.length, lessThan(whole.length));
    });

    test('tiles at a level cover the page without gaps or overlap', () {
      final tiles = tall.tilesFor(Rect.fromLTWH(0, 0, 1080, 6000), 1);
      var area = 0.0;
      for (final t in tiles) {
        area += t.source.width * t.source.height;
      }
      expect(area, closeTo(1080 * 6000, 0.5));
    });

    test('an edge tile is clipped to the page, not run past it', () {
      final tiles = tall.tilesFor(Rect.fromLTWH(0, 0, 1080, 6000), 1);
      for (final t in tiles) {
        expect(t.source.right, lessThanOrEqualTo(1080));
        expect(t.source.bottom, lessThanOrEqualTo(6000));
      }
    });

    test('a page smaller than one tile is a single tile', () {
      final small = TilePyramid(imageWidth: 300, imageHeight: 200);
      expect(small.maxSample, 1);
      expect(small.tilesFor(Rect.fromLTWH(0, 0, 300, 200), 1), hasLength(1));
    });

    test('a viewport off the page returns nothing', () {
      expect(tall.tilesFor(Rect.fromLTWH(0, 9000, 1080, 100), 1), isEmpty);
    });

    test('an empty viewport returns nothing', () {
      expect(tall.tilesFor(Rect.zero, 1), isEmpty);
    });

    // 20,000px pages exist. The base layer must stay bounded.
    test('a very tall page still has a one-tile base layer', () {
      final huge = TilePyramid(imageWidth: 1080, imageHeight: 20000);
      expect(huge.tilesFor(Rect.fromLTWH(0, 0, 1080, 20000), huge.maxSample),
          hasLength(1));
    });

    test('tiles compare by value, so they work as map keys', () {
      // Built at runtime, NOT const. Two identical const TileSpecs are
      // canonicalised by Dart into the same instance, so a const version of
      // this test passes even with operator== and hashCode deleted outright —
      // it measures the compiler, not TileSpec. The identical() line below is
      // here to keep it that way.
      final a = TileSpec(sample: 2, source: Rect.fromLTWH(0, 0, 10, 10));
      final b = TileSpec(sample: 2, source: Rect.fromLTWH(0, 0, 10, 10));
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));

      // And unequal specs must stay distinct, or every tile would collide.
      final other = TileSpec(sample: 4, source: Rect.fromLTWH(0, 0, 10, 10));
      expect(a, isNot(other));
      expect({a, other}, hasLength(2));
    });

    test('viewport edges on exact tile boundaries are not overfetched', () {
      // A 1024x2048 page with 512px tiles (sample 1).
      // Viewport bottom edge at y=512 is exactly on a tile boundary.
      // Should return only the first row of tiles, not a phantom row starting at 512.
      final boundary = TilePyramid(imageWidth: 1024, imageHeight: 2048);
      final tiles = boundary.tilesFor(Rect.fromLTWH(0, 0, 1024, 512), 1);
      // With 512px tiles, the first row spans y:0-512. The viewport is exactly that.
      // Expected: 2 tiles (columns 0 and 1, both in row 0), not 3 or 4.
      expect(tiles, hasLength(2));
      // Both should be in row 0 (y: 0 to 512)
      for (final t in tiles) {
        expect(t.source.top, 0.0);
        expect(t.source.bottom, 512.0);
      }
      // One covers x: 0-512, the other x: 512-1024
      expect(tiles.any((t) => t.source.left == 0 && t.source.right == 512), isTrue);
      expect(tiles.any((t) => t.source.left == 512 && t.source.right == 1024),
          isTrue);
    });

    test('maxSample boundary: power-of-two sample at dimension equality', () {
      // 512x512 fits exactly in one 512px tile with no shrinking.
      final exact512 = TilePyramid(imageWidth: 512, imageHeight: 512);
      expect(exact512.maxSample, 1);

      // 1024x1024 needs to be halved to fit in a 512px tile.
      final exact1024 = TilePyramid(imageWidth: 1024, imageHeight: 1024);
      expect(exact1024.maxSample, 2);
    });

    test('no two tiles in a tiling overlap (plus area coverage)', () {
      final tiles = tall.tilesFor(Rect.fromLTWH(0, 0, 1080, 6000), 1);
      // Existing check: total area covers the page.
      var area = 0.0;
      for (final t in tiles) {
        area += t.source.width * t.source.height;
      }
      expect(area, closeTo(1080 * 6000, 0.5));

      // New check: no two tiles overlap.
      for (var i = 0; i < tiles.length; i++) {
        for (var j = i + 1; j < tiles.length; j++) {
          expect(tiles[i].source.overlaps(tiles[j].source), isFalse,
              reason:
                  'Tiles $i (${tiles[i].source}) and $j (${tiles[j].source}) overlap');
        }
      }
    });
  });
}
