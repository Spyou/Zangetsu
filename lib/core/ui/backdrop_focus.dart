import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/widgets.dart';

import 'image_fade.dart';

/// Where the subject sits across a wide backdrop, so a tall hero that crops it
/// can keep that part in frame instead of always cutting from the middle.
///
/// [columns] is the normalised "interest" per sampled column (sums to 1).
class BackdropFocus {
  const BackdropFocus(this.columns, this.aspect);

  final List<double> columns;

  /// Width / height of the sampled image.
  final double aspect;

  /// Alignment x (-1..1) that frames the busiest stretch of columns when a box
  /// of [boxAspect] shows only part of the image's width. 0 when nothing is
  /// cropped, or when the middle is about as good as anywhere.
  double biasFor(double boxAspect) {
    if (aspect <= 0 || boxAspect <= 0 || aspect <= boxAspect) return 0;
    return horizontalBias(columns, boxAspect / aspect);
  }
}

const _minCropFraction = 0.97;
const _centerPreferenceRatio = 1.12;
const _biasDeadZone = 0.12;

/// The window of [visibleFraction] width with the most interest, as a -1..1
/// alignment. Stays centred unless another window is clearly better.
double horizontalBias(List<double> columns, double visibleFraction) {
  final count = columns.length;
  if (count == 0 || visibleFraction >= _minCropFraction) return 0;
  final window = (visibleFraction * count).round().clamp(1, count);
  final maxStart = count - window;
  if (maxStart <= 0) return 0;

  var sum = 0.0;
  for (var i = 0; i < window; i++) {
    sum += columns[i];
  }
  var bestSum = sum;
  var bestStart = 0;
  for (var start = 1; start <= maxStart; start++) {
    sum += columns[start + window - 1] - columns[start - 1];
    if (sum > bestSum) {
      bestSum = sum;
      bestStart = start;
    }
  }

  final centerStart = maxStart ~/ 2;
  var centerSum = 0.0;
  for (var i = centerStart; i < centerStart + window; i++) {
    centerSum += columns[i];
  }
  if (bestSum <= centerSum * _centerPreferenceRatio) return 0;

  final bias = 2 * bestStart / maxStart - 1;
  return bias.abs() < _biasDeadZone ? 0 : bias.clamp(-1.0, 1.0);
}

const _coarseEdgeWeight = 0.5;
const _skinWeight = 0.08;
const _skinCoverageCutoff = 0.2;
const _foregroundWeight = 0.15;

double _rowWeight(double rowFraction) {
  if (rowFraction > 0.78) return 0.35; // under the gradient, logo and buttons
  if (rowFraction < 0.08) return 0.6;
  return 1;
}

/// Saliency over [w]x[h] straight RGBA pixels, from three signals: coarse edges
/// (people and objects, not fine texture), foreground (what stands apart from the
/// top, left and right borders) and skin tones, which fade out when skin-coloured
/// pixels are everywhere (sepia, warm light) and so mean nothing.
List<double> analyzeColumns(Uint8List rgba, int w, int h) {
  if (w < 4 || h < 4 || rgba.length < w * h * 4) return const [];
  final luma = Float64List(w * h);
  final skin = List<bool>.filled(w * h, false);
  var skinCount = 0;
  for (var i = 0; i < w * h; i++) {
    final r = rgba[i * 4] / 255;
    final g = rgba[i * 4 + 1] / 255;
    final b = rgba[i * 4 + 2] / 255;
    luma[i] = 0.299 * r + 0.587 * g + 0.114 * b;
    final cb = 128 + (-0.168736 * r - 0.331264 * g + 0.5 * b) * 255;
    final cr = 128 + (0.5 * r - 0.418688 * g - 0.081312 * b) * 255;
    if (luma[i] > 0.08 && cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173) {
      skin[i] = true;
      skinCount++;
    }
  }
  final blurred = _boxBlur(luma, w, h, 2);

  final coarse = Float64List(w);
  final skinCols = Float64List(w);
  for (var y = 1; y < h - 1; y++) {
    final rowWeight = _rowWeight(y / (h - 1));
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      coarse[x] += math.min(1.0, _sobel(blurred, w, i) * 3) * rowWeight;
      if (skin[i]) skinCols[x] += rowWeight;
    }
  }

  final columns = Float64List(w);
  _accumulateNormalized(columns, coarse, _coarseEdgeWeight);
  final skinCoverage = skinCount / (w * h);
  final skinReliability = math.max(0.0, 1 - skinCoverage / _skinCoverageCutoff);
  _accumulateNormalized(
    columns,
    skinCols,
    _skinWeight * skinCoverage * skinReliability * w,
  );

  final foreground = _foregroundColumns(rgba, w, h);
  for (var x = 0; x < w; x++) {
    columns[x] += foreground[x] * _foregroundWeight;
  }

  // Light smoothing so one noisy column does not pull the window.
  final smoothed = List<double>.filled(w, 0);
  for (var x = 0; x < w; x++) {
    var acc = 0.0;
    var n = 0;
    for (var k = -2; k <= 2; k++) {
      final xx = x + k;
      if (xx >= 0 && xx < w) {
        acc += columns[xx];
        n++;
      }
    }
    smoothed[x] = acc / n;
  }
  final total = smoothed.fold<double>(0, (a, b) => a + b);
  if (total > 1e-9) {
    for (var x = 0; x < w; x++) {
      smoothed[x] /= total;
    }
  }
  return smoothed;
}

double _sobel(Float64List v, int w, int i) {
  final gx =
      (v[i - w + 1] + 2 * v[i + 1] + v[i + w + 1]) -
      (v[i - w - 1] + 2 * v[i - 1] + v[i + w - 1]);
  final gy =
      (v[i + w - 1] + 2 * v[i + w] + v[i + w + 1]) -
      (v[i - w - 1] + 2 * v[i - w] + v[i - w + 1]);
  return math.min(1.0, math.sqrt(gx * gx + gy * gy));
}

Float64List _boxBlur(Float64List v, int w, int h, int radius) {
  final out = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      var n = 0;
      for (
        var yy = math.max(0, y - radius);
        yy <= math.min(h - 1, y + radius);
        yy++
      ) {
        for (
          var xx = math.max(0, x - radius);
          xx <= math.min(w - 1, x + radius);
          xx++
        ) {
          acc += v[yy * w + xx];
          n++;
        }
      }
      out[y * w + x] = acc / n;
    }
  }
  return out;
}

/// Copies the border columns inward, normalises [source] to sum 1 and adds it
/// to [target] scaled by [weight].
void _accumulateNormalized(Float64List target, Float64List source, double w) {
  final n = source.length;
  source[0] = source[1];
  source[n - 1] = source[n - 2];
  final total = source.fold<double>(0, (a, b) => a + b);
  // Float noise on a flat image must not be blown up into a profile.
  if (total <= 1e-3) return;
  for (var x = 0; x < n; x++) {
    target[x] += source[x] / total * w;
  }
}

/// Background-connectivity ("geodesic") saliency. The image is split into 2x2 px
/// cells in CIELAB; each cell gets the cheapest path cost to the top, left or
/// right border, where stepping between neighbours costs their colour difference
/// minus the image's typical neighbour difference (so smooth gradients and fine
/// texture are free). The bottom border is not a seed because people and objects
/// usually stand on it. Returns the per-column sum of that cost, normalised to 1.
Float64List _foregroundColumns(Uint8List rgba, int w, int h) {
  final gw = w ~/ 2;
  final gh = h ~/ 2;
  final out = Float64List(w);
  if (gw < 3 || gh < 3) return out;
  final cells = gw * gh;

  final lab = Float64List(cells * 3);
  for (var gy = 0; gy < gh; gy++) {
    for (var gx = 0; gx < gw; gx++) {
      var l = 0.0, a = 0.0, b = 0.0;
      for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
          final i = ((gy * 2 + dy) * w + gx * 2 + dx) * 4;
          final c = _toLab(rgba[i], rgba[i + 1], rgba[i + 2]);
          l += c[0];
          a += c[1];
          b += c[2];
        }
      }
      final o = (gy * gw + gx) * 3;
      lab[o] = l / 4;
      lab[o + 1] = a / 4;
      lab[o + 2] = b / 4;
    }
  }

  double distance(int i, int j) {
    final dl = lab[i * 3] - lab[j * 3];
    final da = lab[i * 3 + 1] - lab[j * 3 + 1];
    final db = lab[i * 3 + 2] - lab[j * 3 + 2];
    return math.sqrt(dl * dl + da * da + db * db);
  }

  final neighbours = Int32List(4);
  int neighboursOf(int i) {
    final x = i % gw;
    final y = i ~/ gw;
    var n = 0;
    if (x > 0) neighbours[n++] = i - 1;
    if (x < gw - 1) neighbours[n++] = i + 1;
    if (y > 0) neighbours[n++] = i - gw;
    if (y < gh - 1) neighbours[n++] = i + gw;
    return n;
  }

  // The image's typical neighbour difference: each cell's closest neighbour.
  var clipSum = 0.0;
  for (var i = 0; i < cells; i++) {
    var best = double.maxFinite;
    final n = neighboursOf(i);
    for (var k = 0; k < n; k++) {
      best = math.min(best, distance(i, neighbours[k]));
    }
    clipSum += best;
  }
  final clip = clipSum / cells;

  // Edge costs between 4-connected neighbours: colour difference above typical.
  final adjacency = Int32List(cells * 4);
  final adjacencyCount = Int32List(cells);
  final edgeCost = Float64List(cells * 4);
  for (var i = 0; i < cells; i++) {
    final n = neighboursOf(i);
    adjacencyCount[i] = n;
    for (var k = 0; k < n; k++) {
      adjacency[i * 4 + k] = neighbours[k];
      edgeCost[i * 4 + k] = math.max(0.0, distance(i, neighbours[k]) - clip);
    }
  }

  final dist = Float64List(cells)..fillRange(0, cells, double.maxFinite);
  for (var i = 0; i < cells; i++) {
    final x = i % gw;
    final y = i ~/ gw;
    if (y == 0 || x == 0 || x == gw - 1) dist[i] = 0;
  }
  _dijkstra(dist, adjacency, adjacencyCount, edgeCost);

  for (var gy = 0; gy < gh; gy++) {
    final weight = _rowWeight((gy + 0.5) / gh);
    for (var gx = 0; gx < gw; gx++) {
      final value = dist[gy * gw + gx] * weight;
      out[gx * 2] += value;
      out[gx * 2 + 1] += value;
    }
  }
  final total = out.fold<double>(0, (a, b) => a + b);
  if (total > 1e-9) {
    for (var x = 0; x < w; x++) {
      out[x] /= total;
    }
  }
  return out;
}

/// Dijkstra with a binary min-heap (lazy deletion). [dist] holds the seeds (0)
/// and is filled in place.
void _dijkstra(
  Float64List dist,
  Int32List adjacency,
  Int32List adjacencyCount,
  Float64List edgeCost,
) {
  final cells = dist.length;
  final capacity = cells * 5;
  final heapNode = Int32List(capacity);
  final heapKey = Float64List(capacity);
  var size = 0;

  void push(int node, double key) {
    var i = size++;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (heapKey[parent] <= key) break;
      heapNode[i] = heapNode[parent];
      heapKey[i] = heapKey[parent];
      i = parent;
    }
    heapNode[i] = node;
    heapKey[i] = key;
  }

  for (var i = 0; i < cells; i++) {
    if (dist[i] == 0) push(i, 0);
  }
  final done = List<bool>.filled(cells, false);
  while (size > 0) {
    final current = heapNode[0];
    final currentDist = heapKey[0];
    // Pop: move the last element to the root and sift it down.
    size--;
    if (size > 0) {
      final node = heapNode[size];
      final key = heapKey[size];
      var i = 0;
      while (true) {
        final left = i * 2 + 1;
        if (left >= size) break;
        final right = left + 1;
        final child = (right < size && heapKey[right] < heapKey[left])
            ? right
            : left;
        if (heapKey[child] >= key) break;
        heapNode[i] = heapNode[child];
        heapKey[i] = heapKey[child];
        i = child;
      }
      heapNode[i] = node;
      heapKey[i] = key;
    }
    if (done[current] || currentDist > dist[current]) continue;
    done[current] = true;
    for (var k = 0; k < adjacencyCount[current]; k++) {
      final j = adjacency[current * 4 + k];
      if (done[j]) continue;
      final candidate = currentDist + edgeCost[current * 4 + k];
      if (candidate < dist[j]) {
        dist[j] = candidate;
        push(j, candidate);
      }
    }
  }
}

final List<double> _srgbToLinear = List<double>.generate(256, (v) {
  final c = v / 255.0;
  return c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4) as double;
});

double _labF(double t) =>
    t > 0.008856 ? math.pow(t, 1.0 / 3.0) as double : 7.787 * t + 16.0 / 116.0;

List<double> _toLab(int r8, int g8, int b8) {
  final r = _srgbToLinear[r8];
  final g = _srgbToLinear[g8];
  final b = _srgbToLinear[b8];
  final x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047;
  final y = r * 0.2126 + g * 0.7152 + b * 0.0722;
  final z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883;
  final fx = _labF(x);
  final fy = _labF(y);
  final fz = _labF(z);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

List<double> _analyzeOnce((Uint8List, int, int) sample) =>
    analyzeColumns(sample.$1, sample.$2, sample.$3);

const _sampleWidth = 96;
final _cache = <String, BackdropFocus?>{};
final _inflight = <String, Future<BackdropFocus?>>{};
final _failedAt = <String, DateTime>{};
const _retryAfter = Duration(minutes: 2);

/// The focus profile under [key] if it is already known, without waiting.
BackdropFocus? backdropFocusCached(String key) => _cache[key];

/// The focus profile of [provider]'s artwork, cached under [key]. Null when it
/// cannot be read — callers then keep the old centred crop.
Future<BackdropFocus?> backdropFocusFor(
  ImageProvider provider, {
  required String key,
}) {
  if (_cache.containsKey(key)) {
    final hit = _cache.remove(key);
    _cache[key] = hit; // most recently used
    return Future.value(hit);
  }
  // A picture that just failed is not asked for again on every rebuild.
  final failed = _failedAt[key];
  if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
    return Future.value(null);
  }
  return _inflight[key] ??= _compute(provider, key).whenComplete(() {
    _inflight.remove(key);
  });
}

Future<BackdropFocus?> _compute(ImageProvider provider, String key) async {
  BackdropFocus? result;
  try {
    // No timeout of its own: this fetches the very picture the hero is about to
    // show, so it cannot hold the hero up longer than the picture itself would.
    final image = await _loadImage(ResizeImage(provider, width: _sampleWidth));
    try {
      final bytes = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (bytes != null) {
        // Off the UI isolate: the analysis is about 13 ms of pure number crunching.
        final cols = await compute(_analyzeOnce, (
          bytes.buffer.asUint8List(),
          image.width,
          image.height,
        ));
        if (cols.isNotEmpty) {
          result = BackdropFocus(cols, image.width / image.height);
        }
      }
    } finally {
      image.dispose();
    }
  } catch (_) {
    // No focus data: the hero keeps the centred crop.
  }
  if (result != null) {
    _cache[key] = result;
    _failedAt.remove(key);
    if (_cache.length > 256) _cache.remove(_cache.keys.first);
  } else {
    // Remember the miss for a while, so a broken picture is not refetched on
    // every rebuild; it is tried again later in case it was a bad network.
    _failedAt[key] = DateTime.now();
    if (_failedAt.length > 256) _failedAt.remove(_failedAt.keys.first);
  }
  return result;
}

Future<ui.Image> _loadImage(ImageProvider provider) {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) completer.complete(info.image.clone());
      stream.removeListener(listener);
    },
    onError: (error, stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// The hero artwork. Cropped from the top so a poster's own printed title block
/// is pushed off the bottom and hidden by the gradient. A wide backdrop shown in
/// this tall card also gets framed on where its subject is, instead of always
/// the middle. It waits for that (a few ms once the art is cached) so the crop
/// never jumps after the image appears.
class FocusedHeroImage extends StatefulWidget {
  const FocusedHeroImage({
    super.key,
    required this.source,
    required this.image,
    required this.focusKey,
  });

  final ImageProvider source;
  final ImageProvider image;
  final String focusKey;

  @override
  State<FocusedHeroImage> createState() => FocusedHeroImageState();
}

class FocusedHeroImageState extends State<FocusedHeroImage> {
  late Future<BackdropFocus?> _focus = backdropFocusFor(
    widget.source,
    key: widget.focusKey,
  );

  @override
  void didUpdateWidget(FocusedHeroImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusKey != widget.focusKey) {
      _focus = backdropFocusFor(widget.source, key: widget.focusKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BackdropFocus?>(
      future: _focus,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox.expand();
        }
        return LayoutBuilder(
          builder: (context, c) {
            final box = c.maxHeight > 0 ? c.maxWidth / c.maxHeight : 0.0;
            final bias = snap.data?.biasFor(box) ?? 0.0;
            return Image(
              image: widget.image,
              fit: BoxFit.cover,
              frameBuilder: imageFadeIn,
              alignment: Alignment(bias, -1),
              gaplessPlayback: true,
              // A picture that fails to load shows the banner's own gradient
              // rather than an error.
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            );
          },
        );
      },
    );
  }
}
