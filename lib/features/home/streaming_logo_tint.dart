import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The background a provider logo carries, sampled from its own edges.
///
/// Every TMDB provider logo is a 332x332 image with the brand's background
/// baked in and NO alpha channel — verified across the Indian provider list:
/// Netflix is `#000000`, Prime Video `#FFFFFF`, Crunchyroll `#FF5E00`.
/// Reading those pixels lets a WIDE card be filled with the same colour, so
/// the square logo drawn on top blends in with no inner edge. Guessing it
/// (a blur, a tint, a hand-written table) always leaves that edge.
///
/// Sampled from all FOUR edge midpoints, because these logos grade in
/// different directions: Zee5 and JioHotstar run left-to-right, Jolt Film runs
/// top-to-bottom. Reading only one axis paints a flat card against a graded
/// logo, and the square's edges show — the "box inside the box".
///
/// [vertical] says which axis won, so the card's own gradient runs the same
/// way. A flat logo yields the same colour on every edge and the gradient is
/// flat, which is correct for Netflix, Prime Video and Crunchyroll.
class StreamingTint {
  const StreamingTint(
    this.start,
    this.end, {
    required this.vertical,
    this.contentScale = 1.0,
  });

  /// Left (or top, when [vertical]).
  final Color start;

  /// Right (or bottom, when [vertical]).
  final Color end;

  final bool vertical;

  /// How much to enlarge the logo so its MARK reads the same size as every
  /// other card's.
  ///
  /// The assets are all 332x332, but the mark inside varies: measured off the
  /// live images, Netflix fills 69% of its square, Prime Video 71%,
  /// Crunchyroll 60%, Apple TV 61%. Drawn at a fixed size, Apple's card looks
  /// emptier than Netflix's even though both cards are identical. Scaling by
  /// this brings every mark to the same share of the card.
  ///
  /// Enlarging pushes the square's edges past the card, but those edges are
  /// the logo's own background — the same colour the card is filled with — so
  /// nothing visible is cropped.
  final double contentScale;

  bool get isFlat => start == end;
}

/// Session cache of [StreamingTint] per logo url. A logo does not change under
/// us, and a rail rebuilds on every scroll.
class StreamingLogoTint {
  StreamingLogoTint._();

  static final Map<String, StreamingTint?> _cache = {};
  static final Map<String, Future<StreamingTint?>> _inFlight = {};

  /// Already-known tint, or null if not read yet. Synchronous so a service
  /// seen once paints correctly on its FIRST frame instead of flashing the
  /// neutral plate every time the rail scrolls it back into view.
  static StreamingTint? cached(String url) => _cache[url];

  static bool isKnown(String url) => _cache.containsKey(url);

  /// Null when the image cannot be read, or when its edges are transparent —
  /// the caller then keeps its neutral plate, which is the honest fallback.
  static Future<StreamingTint?> of(String url) {
    if (_cache.containsKey(url)) return Future.value(_cache[url]);
    return _inFlight[url] ??= _read(url).then((t) {
      _cache[url] = t;
      _inFlight.remove(url);
      return t;
    });
  }

  @visibleForTesting
  static void clearCacheForTest() {
    _cache.clear();
    _inFlight.clear();
  }

  /// Sample at [inset] from each side edge, vertically centred. Not the very
  /// edge (some assets antialias their outer row) and not a corner (a rounded
  /// mark can leave the corner off-brand).
  @visibleForTesting
  static StreamingTint? sample(
    Uint8List rgba,
    int width,
    int height, {
    int inset = 6,
  }) {
    if (width <= inset * 2 || height <= inset * 2) return null;
    Color? at(int x, int y) {
      final o = (y * width + x) * 4;
      if (o < 0 || o + 3 >= rgba.length) return null;
      final a = rgba[o + 3];
      // A transparent edge means the logo has no background of its own, so
      // there is nothing to match and the neutral plate is correct.
      if (a < 250) return null;
      return Color.fromARGB(a, rgba[o], rgba[o + 1], rgba[o + 2]);
    }

    final left = at(inset, height ~/ 2);
    final right = at(width - 1 - inset, height ~/ 2);
    final top = at(width ~/ 2, inset);
    final bottom = at(width ~/ 2, height - 1 - inset);
    if (left == null || right == null || top == null || bottom == null) {
      return null;
    }
    // Whichever axis varies more is the one the logo actually grades along.
    final vertical = _delta(top, bottom) > _delta(left, right);
    final scale = _contentScale(rgba, width, height, left);
    return vertical
        ? StreamingTint(top, bottom, vertical: true, contentScale: scale)
        : StreamingTint(left, right, vertical: false, contentScale: scale);
  }

  /// Target share of the card for a logo's mark.
  static const double _targetFill = 0.80;

  /// Never shrink, and never blow a mark up so far that a busy logo turns to
  /// mush — 1.35 covers the widest real gap (Crunchyroll at 60%).
  static const double _maxScale = 1.35;

  /// Measures the mark's bounding box against [background] and returns the
  /// scale that brings it to [_targetFill].
  ///
  /// A graded background (Jolt Film) differs from the sampled edge colour
  /// everywhere, so its box is the whole square and the scale comes out 1.0 —
  /// which is the right answer for a logo that already fills its frame.
  static double _contentScale(
    Uint8List rgba,
    int width,
    int height,
    Color background,
  ) {
    int ch(double v) => (v * 255).round();
    final br = ch(background.r), bg = ch(background.g), bb = ch(background.b);
    var x0 = width, y0 = height, x1 = 0, y1 = 0;
    // Every second pixel: this runs once per logo per session and a 1px
    // boundary error moves the scale by well under a percent.
    for (var y = 0; y < height; y += 2) {
      for (var x = 0; x < width; x += 2) {
        final o = (y * width + x) * 4;
        if (o + 3 >= rgba.length) continue;
        if (rgba[o + 3] < 250) continue;
        final d =
            (rgba[o] - br).abs() +
            (rgba[o + 1] - bg).abs() +
            (rgba[o + 2] - bb).abs();
        if (d <= 60) continue;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
    if (x1 <= x0 || y1 <= y0) return 1.0;
    final side = width > height ? width : height;
    final mark = (x1 - x0) > (y1 - y0) ? (x1 - x0) : (y1 - y0);
    final fill = mark / side;
    if (fill <= 0) return 1.0;
    return (_targetFill / fill).clamp(1.0, _maxScale);
  }

  /// Rough channel distance. Only ever compared against another delta, so an
  /// exact perceptual metric would buy nothing.
  static int _delta(Color a, Color b) {
    int ch(double x) => (x * 255).round();
    return (ch(a.r) - ch(b.r)).abs() +
        (ch(a.g) - ch(b.g)).abs() +
        (ch(a.b) - ch(b.b)).abs();
  }

  static Future<StreamingTint?> _read(String url) async {
    try {
      final image = await _resolve(NetworkImage(url));
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return sample(data.buffer.asUint8List(), image.width, image.height);
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image> _resolve(ImageProvider provider) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (error, stack) {
        if (!completer.isCompleted) completer.completeError(error);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }
}
