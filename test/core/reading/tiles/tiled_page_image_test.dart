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
  bool get available => true;

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

/// A source that passes the startup gate (it CAN tile) but whose every decode
/// fails — the "still deciding, then the base tile itself doesn't pan out"
/// path, as opposed to the "can't tile at all" path the startup gate now
/// short-circuits before a single frame is built.
class _AvailableButFailingSource implements TileSource {
  @override
  bool get available => true;

  @override
  Future<TileImage?> decode(String path, TileSpec spec) async => null;

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

/// A [TileImage] that remembers whether [dispose] was called on it, so a
/// test can tell a correctly-disposed duplicate apart from a silently
/// dropped (leaked) one.
class _TrackedTileImage extends TileImage {
  _TrackedTileImage(super.image, super.spec);

  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// A source whose `decode()` never resolves on its own — the test resolves
/// each call explicitly, in whatever order it wants — and which counts how
/// many times each [TileSpec] was asked for. That's what lets a test drive
/// (and observe) the exact overlap ruling #4 guards against: two decodes for
/// the same spec in flight at once.
class _HeldTileSource implements TileSource {
  final calls = <TileSpec, int>{};
  final _pending = <TileSpec, List<Completer<TileImage?>>>{};

  @override
  bool get available => true;

  @override
  Future<TileImage?> decode(String path, TileSpec spec) {
    calls[spec] = (calls[spec] ?? 0) + 1;
    final completer = Completer<TileImage?>();
    (_pending[spec] ??= []).add(completer);
    return completer.future;
  }

  @override
  void release(String path) {}

  /// Resolves the [index]-th still-outstanding `decode()` call for [spec]
  /// with a small real, trackable image. Must run inside [WidgetTester.runAsync]
  /// — building the image goes through a genuine engine callback.
  Future<_TrackedTileImage> resolve(TileSpec spec, {int index = 0}) async {
    final pixels = Uint8List(4 * 4 * 4);
    final imageCompleter = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      4,
      4,
      ui.PixelFormat.rgba8888,
      imageCompleter.complete,
    );
    final tracked = _TrackedTileImage(await imageCompleter.future, spec);
    _pending[spec]![index].complete(tracked);
    return tracked;
  }
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
                // A real TileDecoder() would fail the startup gate on this
                // host and skip straight to fallback before frame one — this
                // test is about the window *before* that decision, so it
                // needs a source that passes the gate and only fails once
                // asked to decode.
                decoder: _AvailableButFailingSource(),
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

      // Every requested tile must overlap what's on screen PLUS the half-
      // screen margin kept either side, so scrolling back does not have to
      // decode again. The visible band, in full-image pixels, is roughly the
      // middle third of the page (from the scroll position set above); the
      // margin is half its height top and bottom.
      const visibleBand = Rect.fromLTWH(0, 2200, 1080, 1600);
      final keptBand = Rect.fromLTRB(
        visibleBand.left,
        visibleBand.top - visibleBand.height / 2,
        visibleBand.right,
        visibleBand.bottom + visibleBand.height / 2,
      );
      for (final spec in source.requested) {
        expect(
          spec.source.overlaps(keptBand),
          isTrue,
          reason: '$spec does not overlap the kept band $keptBand',
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

  testWidgets(
    'a spec already awaiting decode is not requested again while a scroll '
    'keeps rebuilding the page',
    (tester) async {
      tester.view.physicalSize = const Size(540, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final source = _HeldTileSource();
      final pyramid = TilePyramid(imageWidth: 1080, imageHeight: 6000);

      Widget page() => MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  TiledPageImage(
                    path: '/page.jpg',
                    imageWidth: 1080,
                    imageHeight: 6000,
                    decoder: source,
                    fallbackBuilder: () => const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          );

      // Frame 0: _requestBase fires and asks for the base tile.
      await tester.pumpWidget(page());
      expect(source.calls[pyramid.baseTile], 1);

      // Let the base tile land, which hands off to the first
      // _refineForViewport — it asks for a sharper tile over the top of the
      // page (the default, unscrolled viewport) and then hangs, since this
      // source never resolves anything on its own.
      await tester.runAsync(() => source.resolve(pyramid.baseTile));
      await tester.pump();

      final refinedSpecs =
          source.calls.keys.where((s) => s != pyramid.baseTile).toList();
      expect(refinedSpecs, hasLength(1),
          reason: 'expected exactly one sharper tile requested and stuck '
              'mid-decode; got $refinedSpecs');
      final stuck = refinedSpecs.single;
      expect(source.calls[stuck], 1);

      // Rebuild the page several times — as a real scroll would, each frame
      // — while that decode is still outstanding. Nothing about the page's
      // own state changed, so a correct _refineForViewport should see the
      // same "already asked for this" tile and do nothing.
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(page());
      }

      expect(
        source.calls[stuck],
        1,
        reason: 'a tile already awaiting decode must not be requested again '
            'while a decode for it is still in flight',
      );
      expect(source.calls[pyramid.baseTile], 1);
    },
  );

  testWidgets(
    'a duplicate decode result is disposed, not silently overwriting the '
    'tile already in use',
    (tester) async {
      tester.view.physicalSize = const Size(540, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final source = _HeldTileSource();
      // A page no bigger than one tile: the base tile IS the only tile at
      // any zoom, so _requestBase's own decode and _refineForViewport's
      // first decode both ask for the exact same TileSpec — the base tile
      // is requested once when the page starts up, and independently again
      // as soon as the first refine pass runs, before either has resolved.
      final pyramid = TilePyramid(imageWidth: 100, imageHeight: 100);

      Widget page() => MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  TiledPageImage(
                    path: '/page.jpg',
                    imageWidth: 100,
                    imageHeight: 100,
                    decoder: source,
                    fallbackBuilder: () => const SizedBox.shrink(),
                  ),
                  // Something to scroll against: one 100px page in an 800px
                  // viewport cannot scroll, so the drag below would move
                  // nothing and refinement would never be asked for.
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          );

      // Frame 0: _requestBase asks for the base tile (call #1) and hangs.
      await tester.pumpWidget(page());
      expect(source.calls[pyramid.baseTile], 1);

      // Now SCROLL. Refinement is driven by the scroll position, not by
      // rebuilds — a sliver translates its children rather than rebuilding
      // them, so a rebuild-driven refine only ran when something else
      // happened to rebuild the page. _refineForViewport wants the same base
      // tile (it's the only tile there is) and it is not in _tiles yet, so it
      // asks again (call #2), independently of _requestBase's own call.
      await tester.drag(find.byType(ListView), const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 150));
      expect(source.calls[pyramid.baseTile], 2);

      // Resolve _requestBase's call first: the tile lands and gets stored.
      final first = (await tester.runAsync(
        () => source.resolve(pyramid.baseTile, index: 0),
      ))!;
      await tester.pump();

      // Now resolve _refineForViewport's own (redundant) call.
      final second = (await tester.runAsync(
        () => source.resolve(pyramid.baseTile, index: 1),
      ))!;
      await tester.pump();

      expect(first.disposed, isFalse,
          reason: 'the tile actually in use must not be disposed out from '
              'under the painter');
      expect(second.disposed, isTrue,
          reason: 'a duplicate decode that lands after the spec is already '
              'held must be disposed, not silently overwrite it (a leaked '
              'ui.Image on the scroll path)');
    },
  );
}
