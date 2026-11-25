import 'dart:typed_data';

/// Finds the black bars some trailers carry above and below the picture, and
/// says how far to zoom to push them out of view.
///
/// Works on a tiny copy of a frame: a row counts as black when almost none of
/// its pixels are bright, and the bars are the black rows at the top and the
/// bottom. Pure maths, no Flutter, so it can be tested on plain bytes.
class LetterboxDetector {
  LetterboxDetector._();

  /// How often to look while the trailer plays.
  static const int sampleIntervalMs = 400;

  /// Only the opening part of a trailer is measured; after that the answer is
  /// kept as it is.
  static const double sampleWindowFraction = 0.2;

  /// Width of the frame copy that is measured.
  static const int sampleWidth = 64;

  static const int _darkLuma = 40;
  static const double _brightTolerance = 0.03;
  static const double _minBar = 0.03;
  static const double _maxBar = 0.2;
  static const double _edgePadding = 0.01;

  /// The bar height as a fraction of the frame (0 = no bars), or null when the
  /// frame says nothing useful: all dark, or "bars" so tall it is more likely a
  /// dark scene. [rgba] is 4 bytes per pixel, row by row.
  static double? detectBar(Uint8List rgba, int width, int height) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return null;
    }
    int? top;
    for (var row = 0; row < height; row++) {
      if (!_isDarkRow(rgba, width, row)) {
        top = row;
        break;
      }
    }
    if (top == null) return null;
    var bottom = height - 1;
    while (bottom > 0 && _isDarkRow(rgba, width, bottom)) {
      bottom--;
    }
    final bar =
        (top < height - 1 - bottom ? top : height - 1 - bottom) / height;
    if (bar > _maxBar) return null;
    if (bar < _minBar) return 0;
    return bar + _edgePadding;
  }

  static bool isSampleWindowOver(int positionMs, int durationMs) =>
      durationMs > 0 && positionMs >= durationMs * sampleWindowFraction;

  /// 1 for no bars; otherwise the zoom that makes the picture reach the edges.
  static double zoomFor(double bar) => bar <= 0 ? 1 : 1 / (1 - 2 * bar);

  static bool _isDarkRow(Uint8List rgba, int width, int row) {
    final allowedBright = (width * _brightTolerance).toInt();
    var bright = 0;
    final start = row * width * 4;
    for (var x = 0; x < width; x++) {
      final i = start + x * 4;
      final luma =
          (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
      if (luma > _darkLuma && ++bright > allowedBright) return false;
    }
    return true;
  }
}

/// Waits until several readings in a row agree before trusting them, so one odd
/// frame (a fade to black, a title card) never zooms the trailer.
class LetterboxTracker {
  double? _streakBar;
  int _streak = 0;

  static const int _stableSamples = 4;
  static const double _stableTolerance = 0.015;

  /// The zoom to apply once the readings are stable, otherwise null. Stays null
  /// for a stable "no bars" answer, as there is nothing to zoom.
  double? onSample(double bar) {
    final current = _streakBar;
    final double stable;
    if (current != null && (bar - current).abs() <= _stableTolerance) {
      _streak++;
      stable = bar < current ? bar : current;
    } else {
      _streak = 1;
      stable = bar;
    }
    _streakBar = stable;
    if (_streak < _stableSamples || stable <= 0) return null;
    return LetterboxDetector.zoomFor(stable);
  }
}
