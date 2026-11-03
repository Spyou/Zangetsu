import 'dart:math' as math;
import 'dart:ui';

/// One square of a page, at one level of detail.
///
/// [source] is in FULL-image pixels regardless of [sample], so a tile means
/// the same part of the page at every level and can be compared across them.
class TileSpec {
  const TileSpec({required this.sample, required this.source});

  /// 1 is full resolution; 2 is half; 4 is a quarter. Always a power of two.
  final int sample;
  final Rect source;

  @override
  bool operator ==(Object other) =>
      other is TileSpec && other.sample == sample && other.source == source;

  @override
  int get hashCode => Object.hash(sample, source);

  @override
  String toString() => 'TileSpec(1/$sample, $source)';
}

/// Decides which squares of a page are worth decoding right now.
///
/// Pure geometry: it never touches a file, a decoder or a widget, which is why
/// the part of this feature most likely to be wrong can be tested on a laptop.
class TilePyramid {
  TilePyramid({
    required this.imageWidth,
    required this.imageHeight,
    this.tileSize = 512,
  }) : assert(imageWidth > 0 && imageHeight > 0 && tileSize > 0);

  final int imageWidth;
  final int imageHeight;
  final int tileSize;

  /// The coarsest level — the first power of two at which the whole page fits
  /// in a single grid tile. The preview may use a finer level within its budget.
  int get maxSample {
    var sample = 1;
    while ((imageWidth / sample) > tileSize ||
        (imageHeight / sample) > tileSize) {
      sample *= 2;
    }
    return sample;
  }

  /// A clearer full-page preview, capped at 2 MiB and safe texture dimensions.
  TileSpec get baseTile {
    var sample = maxSample;
    while (sample > 1) {
      final next = sample ~/ 2;
      final width = (imageWidth / next).ceil();
      final height = (imageHeight / next).ceil();
      if (width > tileSize ||
          height > 4096 ||
          width * height * 4 > 2 * 1024 * 1024) {
        break;
      }
      sample = next;
    }
    return TileSpec(
      sample: sample,
      source: Rect.fromLTWH(
        0,
        0,
        imageWidth.toDouble(),
        imageHeight.toDouble(),
      ),
    );
  }

  /// The level to use when the page is drawn at [scale] of its full width.
  ///
  /// Rounds towards MORE detail than strictly needed: being one level too
  /// sharp costs memory, being one too coarse is visible.
  int sampleFor(double scale) {
    if (scale <= 0) return maxSample;
    var sample = 1;
    while (sample < maxSample && scale <= 1.0 / (sample * 2)) {
      sample *= 2;
    }
    return sample;
  }

  /// Every tile at [sample] that overlaps [visible] (full-image pixels).
  List<TileSpec> tilesFor(Rect visible, int sample) {
    if (visible.isEmpty) return const [];
    final page = Rect.fromLTWH(
      0,
      0,
      imageWidth.toDouble(),
      imageHeight.toDouble(),
    );
    final wanted = visible.intersect(page);
    if (wanted.isEmpty || wanted.width <= 0 || wanted.height <= 0) {
      return const [];
    }

    // A tile is tileSize on a side AT ITS OWN LEVEL, so it covers
    // tileSize * sample source pixels.
    final span = (tileSize * sample).toDouble();
    final firstCol = (wanted.left / span).floor();
    final lastCol = ((wanted.right - 0.0001) / span).floor();
    final firstRow = (wanted.top / span).floor();
    final lastRow = ((wanted.bottom - 0.0001) / span).floor();

    final tiles = <TileSpec>[];
    for (var row = firstRow; row <= lastRow; row++) {
      for (var col = firstCol; col <= lastCol; col++) {
        final left = col * span;
        final top = row * span;
        final right = math.min(left + span, imageWidth.toDouble());
        final bottom = math.min(top + span, imageHeight.toDouble());
        if (right <= left || bottom <= top) continue;
        tiles.add(
          TileSpec(
            sample: sample,
            source: Rect.fromLTRB(left, top, right, bottom),
          ),
        );
      }
    }
    return tiles;
  }
}
