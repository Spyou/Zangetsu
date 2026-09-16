import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'tile_pyramid.dart';

/// A decoded tile, ready to paint.
class TileImage {
  TileImage(this.image, this.spec) {
    liveBytes += image.width * image.height * 4;
  }

  /// Decoded tile bytes currently held, across every page. The point of this
  /// feature is that this number stays near a screenful instead of tracking
  /// page height, and `dumpsys meminfo` does NOT show it — its Graphics figure
  /// reads the same for one page as for twelve.
  static int liveBytes = 0;

  final ui.Image image;
  final TileSpec spec;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    liveBytes -= image.width * image.height * 4;
    image.dispose();
  }
}

/// Least-recently-used bookkeeping for open pages.
///
/// Kept as a standalone, independently-tested policy even though the tile
/// decoder itself no longer runs an LRU on the Dart side — the native side
/// (Kotlin `BitmapRegionDecoder`) owns that bookkeeping now, with the same
/// evict-oldest policy. An LRU that evicts the wrong entry is a slow leak, and
/// a leak of open file descriptors is one that ends in a crash rather than a
/// slowdown, so the policy stays covered on its own regardless of which side
/// implements it.
class TileLru {
  TileLru({required this.capacity, required this.onEvict})
      : assert(capacity > 0);

  final int capacity;
  final void Function(String key) onEvict;
  final _order = <String>[];

  void touch(String key) {
    _order.remove(key);
    _order.add(key);
    while (_order.length > capacity) {
      onEvict(_order.removeAt(0));
    }
  }

  void remove(String key) {
    if (_order.remove(key)) onEvict(key);
  }

  void clear() {
    while (_order.isNotEmpty) {
      onEvict(_order.removeAt(0));
    }
  }

  bool contains(String key) => _order.contains(key);
  int get length => _order.length;
}

/// What [TiledPageImage] needs from a decoder. A seam, not an abstraction for
/// its own sake: the widget's tile arithmetic is the part most likely to be
/// wrong, and a fake standing in here is the only way to test it without a
/// device.
abstract class TileSource {
  /// Whether this source can tile at all. Checked once when a page is built,
  /// so a device that cannot tile never paints an empty frame before falling
  /// back — asking per page, after a decode has already failed, is one black
  /// frame per page on exactly the old devices that take this path.
  bool get available;

  Future<TileImage?> decode(String path, TileSpec spec);
  void release(String path);
}

/// Decodes tiles via the native `zangetsu/tiles` MethodChannel
/// (`BitmapRegionDecoder`, API 10+).
///
/// A MethodChannel call is already asynchronous and the Kotlin side does the
/// actual decoding on its own background thread, so there is no isolate here
/// — that used to exist purely to keep FFI off the UI isolate, and taking it
/// out also removes the isolate startup/teardown race this file used to
/// guard against.
class TileDecoder implements TileSource {
  static const _channel = MethodChannel('zangetsu/tiles');

  /// The channel only exists on Android — iOS never registers it, so a call
  /// there would just throw [MissingPluginException]. Checked as a plain
  /// platform fact (no I/O) so [TiledPageImage] can decide before it ever
  /// asks for a tile, rather than after a decode has already failed.
  @override
  bool get available => Platform.isAndroid;

  /// Paths this decoder has told the native side to open, so a repeat
  /// `decode()` for the same page doesn't reopen it, and so `dispose()` knows
  /// what it still needs to close.
  final _openPaths = <String>{};
  bool _disposed = false;

  /// Decodes one tile. Returns null when the device cannot tile, the file
  /// cannot be read, or the region is refused — every one of which means the
  /// caller should fall back to a whole-page decode.
  ///
  /// Deliberately does not gate on [available] first: the try/catch below is
  /// what actually has to handle "no such channel" (iOS, or any platform
  /// where the plugin isn't there), so it has to run that path for real
  /// rather than being short-circuited before it's ever exercised.
  @override
  Future<TileImage?> decode(String path, TileSpec spec) async {
    if (_disposed) return null;
    try {
      if (!_openPaths.contains(path)) {
        final opened = await _channel.invokeMapMethod<String, dynamic>(
          'openPage',
          {'path': path},
        );
        if (opened == null) return null;
        _openPaths.add(path);
      }

      // spec.source is in FULL-image (original) pixels, same as `sample` is
      // separate from it — sent through exactly as-is. Dividing either of
      // these by the other here is the bug that made every tile fall back
      // last time: BitmapRegionDecoder.decodeRegion() wants the ORIGINAL
      // coordinates and downsamples itself via inSampleSize.
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'decodeTile',
        {
          'path': path,
          'x': spec.source.left.round(),
          'y': spec.source.top.round(),
          'w': spec.source.width.round(),
          'h': spec.source.height.round(),
          'sample': spec.sample,
        },
      );
      if (raw == null) return null;

      final bytes = raw['bytes'] as Uint8List;
      final width = raw['width'] as int;
      final height = raw['height'] as int;

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bytes,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return TileImage(await completer.future, spec);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Drops a page's open handle. Called when a page leaves the strip.
  @override
  void release(String path) {
    if (_disposed) return;
    if (!_openPaths.remove(path)) return;
    unawaited(
      _channel.invokeMethod<void>('closePage', {'path': path}).catchError(
        (Object _) {},
      ),
    );
  }

  /// Safe to call more than once — the first call closes whatever pages are
  /// still open and marks itself done; a later call is a no-op.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final paths = _openPaths.toList();
    _openPaths.clear();
    for (final path in paths) {
      try {
        await _channel.invokeMethod<void>('closePage', {'path': path});
      } on MissingPluginException {
        // already gone / never really open — nothing to clean up.
      } on PlatformException {
        // best-effort close; a failure here just means the native side
        // leaked one entry from its own LRU, which it will evict anyway.
      }
    }
  }
}
