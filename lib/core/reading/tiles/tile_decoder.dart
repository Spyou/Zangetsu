import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'tile_decoder_ffi.dart';
import 'tile_pyramid.dart';

/// A decoded tile, ready to paint.
class TileImage {
  TileImage(this.image, this.spec);

  final ui.Image image;
  final TileSpec spec;

  void dispose() => image.dispose();
}

/// Least-recently-used bookkeeping for open pages.
///
/// Separate from the isolate so the policy can be tested on its own — an LRU
/// that evicts the wrong entry is a slow leak, and a leak of open file
/// descriptors is one that ends in a crash rather than a slowdown.
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

/// Decodes tiles on a background isolate.
///
/// Every decode is off the UI isolate: a tile landing must never be able to
/// stutter a scroll, which is the whole reason this is worth doing rather than
/// decoding inline.
class TileDecoder {
  TileDecoder({this.openPages = 10});

  /// How many pages stay open at once. Scrolling back should not reopen files.
  final int openPages;

  SendPort? _toIsolate;
  Isolate? _isolate;
  final _pending = <int, Completer<_RawTile?>>{};
  var _nextId = 0;
  Completer<void>? _starting;
  Completer<void>? _shutdownAck;
  Future<void>? _disposing;

  Future<void> _ensureStarted() async {
    if (_toIsolate != null) return;
    if (_starting != null) return _starting!.future;
    final starting = Completer<void>();
    _starting = starting;

    final fromIsolate = ReceivePort();
    _isolate = await Isolate.spawn(_isolateMain, fromIsolate.sendPort);
    fromIsolate.listen((message) {
      if (message is SendPort) {
        _toIsolate = message;
        starting.complete();
        return;
      }
      if (message is _RawTile) {
        _pending.remove(message.id)?.complete(message);
      } else if (message is _TileFailed) {
        _pending.remove(message.id)?.complete(null);
      } else if (message is _TileShutdownAck) {
        final ack = _shutdownAck;
        if (ack != null && !ack.isCompleted) ack.complete();
      }
    });
    return starting.future;
  }

  /// Decodes one tile. Returns null when the device cannot tile, the file
  /// cannot be read, or the region is refused — every one of which means the
  /// caller should fall back to a whole-page decode.
  Future<TileImage?> decode(String path, TileSpec spec) async {
    if (!tileDecodingAvailable()) return null;
    if (_disposing != null) return null;
    await _ensureStarted();
    if (_toIsolate == null) return null;

    final id = _nextId++;
    final completer = Completer<_RawTile?>();
    _pending[id] = completer;
    _toIsolate!.send(
      _TileRequest(
        id: id,
        path: path,
        x: (spec.source.left / spec.sample).round(),
        y: (spec.source.top / spec.sample).round(),
        width: (spec.source.width / spec.sample).round(),
        height: (spec.source.height / spec.sample).round(),
        sample: spec.sample,
        openPages: openPages,
      ),
    );

    final raw = await completer.future;
    if (raw == null) return null;

    // Turn raw RGBA into a ui.Image on this isolate. decodeImageFromPixels is
    // the only step that must happen here.
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      raw.rgba,
      raw.width,
      raw.height,
      ui.PixelFormat.rgba8888,
      done.complete,
      rowBytes: raw.stride,
    );
    return TileImage(await done.future, spec);
  }

  /// Drops a page's open handle. Called when a page leaves the strip.
  void release(String path) {
    _toIsolate?.send(_TileRelease(path));
  }

  /// Safe to call more than once — later callers await the first shutdown
  /// rather than starting a second one and racing on the ack.
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    if (_toIsolate != null) {
      // kill(beforeNextEvent) does not guarantee a message sent moments
      // earlier has been handled yet — a normal message and a kill control
      // signal race independently. Without waiting for the isolate to
      // confirm it closed its native handles, dispose() could kill it first
      // and leak every open file. So: wait for the ack (bounded, in case the
      // isolate is already gone), then kill.
      final ack = Completer<void>();
      _shutdownAck = ack;
      _toIsolate!.send(const _TileShutdown());
      await ack.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _toIsolate = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
  }
}

// ---- messages across the isolate boundary ----

class _TileRequest {
  const _TileRequest({
    required this.id,
    required this.path,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.sample,
    required this.openPages,
  });

  final int id;
  final String path;
  final int x, y, width, height, sample, openPages;
}

class _TileRelease {
  const _TileRelease(this.path);
  final String path;
}

class _TileShutdown {
  const _TileShutdown();
}

/// Sent back once the isolate has closed every native handle, so `dispose()`
/// knows it is safe to kill the isolate.
class _TileShutdownAck {
  const _TileShutdownAck();
}

class _RawTile {
  const _RawTile(this.id, this.rgba, this.stride, this.width, this.height);
  final int id;
  final Uint8List rgba;
  final int stride;
  final int width;
  final int height;
}

class _TileFailed {
  const _TileFailed(this.id);
  final int id;
}

/// Runs on the background isolate. Native handles live here and never cross
/// back — a Pointer is meaningless in another isolate.
void _isolateMain(SendPort toMain) {
  final fromMain = ReceivePort();
  toMain.send(fromMain.sendPort);

  final handles = <String, TileHandle>{};
  late final TileLru lru;
  var lruReady = false;

  void closePage(String path) {
    final handle = handles.remove(path);
    if (handle != null) tileClose(handle);
  }

  fromMain.listen((message) {
    if (message is _TileShutdown) {
      for (final h in handles.values) {
        tileClose(h);
      }
      handles.clear();
      toMain.send(const _TileShutdownAck());
      fromMain.close();
      return;
    }

    if (message is _TileRelease) {
      if (lruReady) lru.remove(message.path);
      closePage(message.path);
      return;
    }

    if (message is! _TileRequest) return;

    if (!lruReady) {
      lru = TileLru(capacity: message.openPages, onEvict: closePage);
      lruReady = true;
    }

    try {
      var handle = handles[message.path];
      if (handle == null) {
        handle = tileOpen(message.path);
        if (handle == null) {
          toMain.send(_TileFailed(message.id));
          return;
        }
        handles[message.path] = handle;
      }
      lru.touch(message.path);

      final tile = tileDecode(
        handle,
        message.x,
        message.y,
        message.width,
        message.height,
        message.sample,
      );
      if (tile == null) {
        toMain.send(_TileFailed(message.id));
        return;
      }
      toMain.send(
        _RawTile(message.id, tile.rgba, tile.stride, tile.width, tile.height),
      );
    } catch (_) {
      // A decode that throws must not take the isolate down with it: the
      // handles here are native file descriptors and nothing else would close
      // them. Report the failure and let the caller fall back.
      closePage(message.path);
      toMain.send(_TileFailed(message.id));
    }
  });
}
