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
      const a = TileSpec(sample: 2, source: Rect.fromLTWH(0, 0, 10, 10));
      const b = TileSpec(sample: 2, source: Rect.fromLTWH(0, 0, 10, 10));
      expect(a, b);
      expect({a, b}, hasLength(1));
    });
  });
}
