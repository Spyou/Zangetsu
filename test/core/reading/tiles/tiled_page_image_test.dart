import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tiles/tile_decoder.dart';
import 'package:watch_app/core/reading/tiles/tile_pyramid.dart';
import 'package:watch_app/core/reading/tiles/tiled_page_image.dart';

/// Records every spec it is asked to decode and always succeeds, with a
/// tiny real [ui.Image] so the painter has something valid to hold. Lets the
/// refinement test run without a device: [TileDecoder] itself always
/// returns null here, since there is no native library on the test host.
class _FakeTileSource implements TileSource {
  final requested = <TileSpec>[];

  @override
  Future<TileImage?> decode(String path, TileSpec spec) async {
    requested.add(spec);
    final pixels = Uint8List(4 * 4 * 4);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      4,
      4,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return TileImage(await completer.future, spec);
  }

  @override
  void release(String path) {}
}

/// Pumps with real wall-clock gaps between them, inside [WidgetTester.runAsync].
///
/// [ui.decodeImageFromPixels] completes via a genuine engine callback, not a
/// Dart Timer or microtask — flutter_test's [WidgetTester.pumpAndSettle]
/// alone (even wrapped in `runAsync`) does not reliably wait for one: it
/// stops as soon as no *frame* is scheduled, which says nothing about a
/// decode still in flight in the background. Real elapsed time between pumps
/// is what actually gives the callback a chance to land.
Future<void> _settle(WidgetTester tester) {
  return tester.runAsync(() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
}

void main() {
  testWidgets('falls back when the device cannot tile', (tester) async {
    // In a widget test the native library is absent, so tiling is unavailable
    // and the fallback is the ONLY thing that may be shown. This is the
    // guarantee the whole feature rests on: never a blank page.
    await tester.pumpWidget(
      MaterialApp(
        home: TiledPageImage(
          path: '/nonexistent/page.jpg',
          imageWidth: 1080,
          imageHeight: 6000,
          decoder: TileDecoder(),
          fallbackBuilder: () => const Text('fallback'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);
  });

  testWidgets('reserves the page height while it decides', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        // Center loosens the screen-tight width so the SizedBox below can
        // actually pick 540 instead of being stretched full-screen; the
        // SingleChildScrollView is what a real page always sits inside,
        // which is what gives it unbounded height to grow into.
        home: Center(
          child: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: TiledPageImage(
                path: '/nonexistent/page.jpg',
                imageWidth: 1080,
                imageHeight: 6000,
                decoder: TileDecoder(),
                fallbackBuilder: () => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    // No extra pump() here on purpose: the base-tile decode above resolves
    // in exactly one more pump (see the fallback test), so pumping again
    // here would race straight past the "still deciding" window this test
    // means to catch and land on the already-failed frame instead.
    // 540 wide at a 1080x6000 aspect is 3000 tall. The slot must not collapse,
    // or the strip jumps — the exact failure this reader spent a week fixing.
    final size = tester.getSize(find.byType(TiledPageImage));
    expect(size.height, closeTo(3000, 1));
  });

  testWidgets(
    'refinement requests tiles for the visible middle, not the whole page',
    (tester) async {
      // Pin the test surface to exactly the page's own width so its layout
      // width is knowable (a bare SizedBox inside a ListView gets stretched
      // to the list's cross-axis width instead of picking its own).
      tester.view.physicalSize = const Size(540, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final source = _FakeTileSource();
      final controller = ScrollController();

      // A page 1080x6000, shown 540 wide (scale 0.5), sitting inside a much
      // taller scrollable so its middle can be scrolled into view while its
      // top and bottom stay off screen.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: controller,
              children: [
                const SizedBox(height: 2000),
                TiledPageImage(
                  path: '/page.jpg',
                  imageWidth: 1080,
                  imageHeight: 6000,
                  decoder: source,
                  fallbackBuilder: () => const SizedBox.shrink(),
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      );
      await _settle(tester);

      // Page occupies list-local [2000, 5000] (3000 tall at scale 0.5).
      // Center the screen on the page's own middle (list-local y = 3500),
      // leaving both the page's top and its bottom off screen.
      final viewportHeight = tester.getRect(find.byType(ListView)).height;
      controller.jumpTo(2000 + 1500 - viewportHeight / 2);
      await _settle(tester);

      expect(source.requested, isNotEmpty);

      // The base tile (the whole page, coarsest level) is always requested —
      // it is what stops the page going blank while sharper tiles load.
      final pyramid = TilePyramid(imageWidth: 1080, imageHeight: 6000);
      expect(source.requested, contains(pyramid.baseTile));

      // Every requested tile must actually overlap what's on screen. The
      // visible band, in full-image pixels, is roughly the middle third of
      // the page (computed from the scroll position set above).
      final visibleBand = Rect.fromLTWH(0, 2200, 1080, 1600);
      for (final spec in source.requested) {
        expect(
          spec.source.overlaps(visibleBand),
          isTrue,
          reason: '$spec does not overlap the visible band $visibleBand',
        );
      }

      // The negative that actually catches broken arithmetic: a tile over
      // the page's far bottom (nowhere near the screen) must not have been
      // requested.
      final farBottom = Rect.fromLTWH(0, 5500, 1080, 500);
      for (final spec in source.requested) {
        expect(
          spec.source.overlaps(farBottom) && spec != pyramid.baseTile,
          isFalse,
          reason: '$spec should not have been requested; it is nowhere '
              'near the viewport',
        );
      }
    },
  );
}
