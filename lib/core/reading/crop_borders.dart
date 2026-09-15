import 'dart:math' as math;
import 'dart:typed_data';

/// The rectangle of a page that actually has artwork in it.
///
/// Manga and manhwa pages routinely arrive with flat margins — a white band
/// down a scan's edge, a black strip where a webtoon slicer padded a slice to
/// a uniform height. On a paged reader that is a thin border. On a continuous
/// strip it is far worse: every page's padding stacks with the next one's, so
/// the reader is full of black or white bands that are not part of the art.
///
/// So the edges are inspected and the flat ones trimmed, which is what the
/// reference Android reader's "crop borders" actually does. Ours used to be
/// `Transform.scale(1.06)` inside a `ClipRect` — a blind 3% shave off each
/// side that took artwork away when there was no margin and left most of the
/// margin when there was.
///
/// [rgba] is row-major RGBA, [tolerance] how far a pixel may stray from the
/// edge's own colour and still count as flat, and [maxFraction] the most of
/// any side that may be taken — a page that is genuinely a black panel must
/// not be cropped down to nothing.
///
/// Returns left, top, right, bottom in pixels: the content box.
({int left, int top, int right, int bottom}) findContentRect(
  Uint8List rgba,
  int width,
  int height, {
  int tolerance = 12,
  double maxFraction = 0.4,
}) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return (left: 0, top: 0, right: width, bottom: height);
  }

  int at(int x, int y) => (y * width + x) * 4;
  bool near(int i, int r, int g, int b) =>
      (rgba[i] - r).abs() <= tolerance &&
      (rgba[i + 1] - g).abs() <= tolerance &&
      (rgba[i + 2] - b).abs() <= tolerance;

  // Sample across a row/column rather than testing every pixel: a margin is
  // flat everywhere, so a stride is enough and keeps this cheap on a page that
  // can be several thousand pixels tall.
  final xStep = math.max(1, width ~/ 64);
  final yStep = math.max(1, height ~/ 64);

  // Each edge is judged against the colour of THAT edge, not against each
  // row's own first pixel — otherwise a row of flat artwork counts as margin
  // and the trim eats into the page.
  bool rowIs(int y, int r, int g, int b) {
    for (var x = 0; x < width; x += xStep) {
      if (!near(at(x, y), r, g, b)) return false;
    }
    return near(at(width - 1, y), r, g, b);
  }

  bool colIs(int x, int r, int g, int b) {
    for (var y = 0; y < height; y += yStep) {
      if (!near(at(x, y), r, g, b)) return false;
    }
    return near(at(x, height - 1), r, g, b);
  }

  final maxY = (height * maxFraction).floor();
  final maxX = (width * maxFraction).floor();

  final topRef = at(0, 0);
  final tr = rgba[topRef], tg = rgba[topRef + 1], tb = rgba[topRef + 2];
  var top = 0;
  while (top < maxY && rowIs(top, tr, tg, tb)) {
    top++;
  }

  final botRef = at(0, height - 1);
  final br = rgba[botRef], bg2 = rgba[botRef + 1], bb = rgba[botRef + 2];
  var bottom = height;
  while (bottom > height - maxY &&
      bottom > top + 1 &&
      rowIs(bottom - 1, br, bg2, bb)) {
    bottom--;
  }

  final leftRef = at(0, 0);
  final lr = rgba[leftRef], lg = rgba[leftRef + 1], lb = rgba[leftRef + 2];
  var left = 0;
  while (left < maxX && colIs(left, lr, lg, lb)) {
    left++;
  }

  final rightRef = at(width - 1, 0);
  final rr = rgba[rightRef], rg = rgba[rightRef + 1], rb = rgba[rightRef + 2];
  var right = width;
  while (right > width - maxX &&
      right > left + 1 &&
      colIs(right - 1, rr, rg, rb)) {
    right--;
  }

  // A page with nothing to trim must come back untouched, not off by a pixel.
  return (left: left, top: top, right: right, bottom: bottom);
}
