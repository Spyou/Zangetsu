import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Thanos-style delete: the poster crumbles into ash tiles that rise, drift
/// and fade, and only then is the item actually removed.
///
/// Contract (same shape as Nuvio's DisintegratingContainer, reimplemented):
/// wrap the poster, flip [disintegrating] to true on delete, and do the real
/// store removal inside [onDisintegrated]. The child stays laid out (offstage)
/// the whole time so the grid slot never jumps.
///
/// If the snapshot can't be captured (backgrounded view, stalled GPU), the
/// animation is skipped and [onDisintegrated] fires immediately — a delete
/// must never get stranded behind a failed screenshot.
class DisintegratingPoster extends StatefulWidget {
  const DisintegratingPoster({
    super.key,
    required this.disintegrating,
    required this.onDisintegrated,
    required this.child,
    this.duration = const Duration(milliseconds: 1500),
    this.borderRadius = 12,
    @visibleForTesting this.debugCapture,
  });

  final bool disintegrating;
  final FutureOr<void> Function() onDisintegrated;
  final Widget child;
  final Duration duration;

  /// Corner radius of the card being dissolved — the ash must die inside the
  /// same rounded silhouette, otherwise the animation flashes a sharp box
  /// over a round card (Continue Watching cards are 14, posters 12).
  final double borderRadius;

  /// Test seam: skip the engine snapshot and animate this field instead
  /// (or `() async => null` to force the no-capture fallback).
  final Future<AshField?> Function()? debugCapture;

  @override
  State<DisintegratingPoster> createState() => _DisintegratingPosterState();
}

class _DisintegratingPosterState extends State<DisintegratingPoster>
    with SingleTickerProviderStateMixin {
  final _boundaryKey = GlobalKey();
  late final AnimationController _progress;
  AshField? _field;
  bool _fired = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _fire();
      });
    if (widget.disintegrating) {
      // Microtask, not post-frame: the poster was painted long ago (it was on
      // screen), and endOfFrame futures created inside a post-frame callback
      // never resolve — which would wedge the snapshot race in _snapshot.
      Future.microtask(_begin);
    }
  }

  @override
  void didUpdateWidget(DisintegratingPoster old) {
    super.didUpdateWidget(old);
    if (widget.disintegrating && !old.disintegrating && !_fired) {
      // Same microtask reasoning as initState.
      Future.microtask(_begin);
    }
    if (!widget.disintegrating && old.disintegrating) {
      // Delete aborted or failed upstream: arm again so a later remove
      // still animates and still commits.
      _fired = false;
    }
    if (widget.duration != old.duration) _progress.duration = widget.duration;
  }

  @override
  void dispose() {
    // Screen popped mid-animation: the delete was already confirmed, so
    // commit it instead of silently resurrecting the item. Scoped to a delete
    // actually in motion — a cell that never started must not fire: its
    // unmount-driven commit would run twice and its setState would crash the
    // unmount phase outright.
    _disposed = true;
    if (widget.disintegrating) _fire();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (!mounted || _fired) return;
    final debugCapture = widget.debugCapture;
    final field = debugCapture != null
        ? await debugCapture()
        : await _captureField();
    if (!mounted || _fired) return;
    if (field == null) {
      _fire();
      return;
    }
    setState(() => _field = field);
    _progress.forward(from: 0);
  }

  Future<AshField?> _captureField() async {
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return null;
      // Race the whole snapshot+convert against rendered frames: any single
      // engine step (toImage, toByteData) can pend forever where no frame
      // ever comes (widget tests) or the view is backgrounded — either way
      // the delete must not wait. The wall-time timeout stays as the backstop
      // for a live-but-stalled GPU.
      return await Future.any<AshField?>([
        _captureRgb(boundary),
        _afterFrames(8).then<AshField?>((_) => null),
      ]).timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  Future<AshField?> _captureRgb(RenderRepaintBoundary boundary) async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))?.buffer.asUint8List();
    if (bytes == null) return null;
    final w = image.width, h = image.height;
    if (w < 8 || h < 8) return null;
    return AshField.build(
      bytes,
      w,
      h,
      math.Random().nextDouble() * _tau,
      image: image,
    );
  }

  Future<void> _afterFrames(int n) async {
    final binding = SchedulerBinding.instance;
    for (var i = 0; i < n; i++) {
      await binding.endOfFrame;
    }
  }

  void _fire() {
    if (_fired) return;
    _fired = true;
    // The entry usually leaves the list on the next frame, but a
    // remote-backed list (tracker refresh) can lag seconds behind the commit.
    // Fall back to the plain poster instead of holding an empty slot — a
    // poster that overstays a beat reads as nothing, a hole reads as broken.
    // (mounted is still true inside dispose, hence the explicit flag.)
    if (!_disposed) {
      setState(() {
        _field = null;
        _progress.reset();
      });
    }
    widget.onDisintegrated();
  }

  @override
  Widget build(BuildContext context) {
    final field = _field;
    if (field == null) {
      return RepaintBoundary(key: _boundaryKey, child: widget.child);
    }
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Offstage(offstage: true, child: widget.child),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _progress,
              builder: (_, _) => CustomPaint(
                painter: AshPainter(
                  field,
                  _progress.value,
                  borderRadius: widget.borderRadius,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const double _tau = 6.2831855;
const double _tileLifespan = 0.5;

double _frontWave(double ny, double phase) =>
    math.sin(ny * _tau * 1.15 + phase) * 0.045 +
    math.sin(ny * _tau * 2.4 + phase * 1.7) * 0.02;

/// Diagonal dissolve front: bottom-right goes first, top-left holds longest.
@visibleForTesting
double ashFront(double nx, double ny, double phase) =>
    0.52 * (1 - ny) + 0.48 * nx + _frontWave(ny, phase);

/// One ash grain: its sampled color plus the random flight it takes.
class AshTile {
  AshTile({
    required this.color,
    required this.startDelay,
    required this.driftX,
    required this.speed,
    required this.swirlPhase,
    required this.swirlFreq,
    required this.swirlAmp,
  });

  final Color color;
  final double startDelay;
  final double driftX;
  final double speed;
  final double swirlPhase;
  final double swirlFreq;
  final double swirlAmp;
}

/// The particle field a poster dissolves into: a tile grid sampled from the
/// snapshot, each tile with a staggered start so a wavy front sweeps across.
/// [image] is the crisp snapshot itself — the intact remainder paints from it
/// directly, so only the flying ash is ever tile-shaped. Null in tests, where
/// the intact remainder falls back to dormant tiles.
class AshField {
  AshField({
    required this.cols,
    required this.rows,
    required this.tiles,
    required this.phase,
    this.image,
  });

  final int cols;
  final int rows;
  final List<AshTile> tiles;
  final double phase;
  final ui.Image? image;

  /// Dices [rgba] ([w]×[h] raw RGBA bytes) into tiles. Same shape as Nuvio's
  /// builder: 130 columns scaled by the budget, so grains stay fine instead
  /// of chunky. Total tiles capped low enough that a mid-range phone holds
  /// 60fps while thousands of grains are live at once — too many tiles and
  /// the ash visibly stutters mid-flight as frames get dropped.
  static AshField? build(
    Uint8List rgba,
    int w,
    int h,
    double phase, {
    ui.Image? image,
  }) {
    if (w < 2 || h < 2 || rgba.length < w * h * 4) return null;
    const maxTiles = 5000;
    const maxCols = 130;
    final aspect = h / w;
    var cols = maxCols;
    var rows = (cols * aspect).round().clamp(8, 1000);
    if (cols * rows > maxTiles) {
      cols = (math.sqrt(maxTiles / aspect)).toInt().clamp(12, maxCols);
      rows = (cols * aspect).round().clamp(8, 1000);
    }
    final rnd = math.Random();
    final tiles = <AshTile>[];
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
        final nx = (i + 0.5) / cols;
        final ny = (j + 0.5) / rows;
        final px = (nx * (w - 1)).toInt().clamp(0, w - 1);
        final py = (ny * (h - 1)).toInt().clamp(0, h - 1);
        final o = (py * w + px) * 4;
        final shade = 0.80 + rnd.nextDouble() * 0.34;
        tiles.add(
          AshTile(
            color: Color.fromARGB(
              rgba[o + 3],
              (rgba[o] * shade).round().clamp(0, 255),
              (rgba[o + 1] * shade).round().clamp(0, 255),
              (rgba[o + 2] * shade).round().clamp(0, 255),
            ),
            startDelay:
                ((1 - ashFront(nx, ny, phase)) * (1 - _tileLifespan) -
                        rnd.nextDouble() * 0.05)
                    .clamp(0, 1 - _tileLifespan)
                    .toDouble(),
            driftX: 0.55 + (rnd.nextDouble() - 0.4) * 1.3,
            speed: 0.7 + rnd.nextDouble() * 0.7,
            swirlPhase: rnd.nextDouble() * _tau,
            swirlFreq: 1.1 + rnd.nextDouble() * 1.8,
            swirlAmp: 0.6 + rnd.nextDouble() * 0.9,
          ),
        );
      }
    }
    return AshField(
      cols: cols,
      rows: rows,
      tiles: tiles,
      phase: phase,
      image: image,
    );
  }
}

/// Paints [AshField] at progress [p]: the crisp snapshot clipped by the
/// travelling front, plus every live grain as a rising, fading speck.
class AshPainter extends CustomPainter {
  AshPainter(this.field, this.p, {this.borderRadius = 12});

  final AshField field;
  final double p;
  final double borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;

    // Stay inside the card's silhouette the whole time — no sharp box over
    // round corners.
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(borderRadius),
      ),
    );

    // Intact remainder, clipped by the travelling wavy front. Painted from
    // the crisp snapshot — never from tiles — so the poster stays sharp
    // right up to the dissolve line. (Tests build fields without an image;
    // there the dormant tiles stand in.)
    final threshold = 1 - p / (1 - _tileLifespan);
    final paint = Paint();
    final snapshot = field.image;
    if (threshold > -0.1) {
      final intact = Path();
      for (var i = 0; i <= 28; i++) {
        final ny = i / 28;
        final bx =
            (threshold - 0.52 * (1 - ny) - _frontWave(ny, field.phase)) / 0.48;
        final x = (bx * w).clamp(0.0, w);
        if (i == 0) {
          intact.moveTo(x, 0);
        } else {
          intact.lineTo(x, ny * h);
        }
      }
      intact.lineTo(0, h);
      intact.lineTo(0, 0);
      intact.close();
      canvas.save();
      canvas.clipPath(intact);
      if (snapshot != null) {
        paintImage(
          canvas: canvas,
          rect: Offset.zero & size,
          image: snapshot,
          fit: BoxFit.fill,
        );
      } else {
        _paintTiles(canvas, paint, w, h, dormantOnly: true);
      }
      canvas.restore();
    }
    _paintTiles(canvas, paint, w, h, dormantOnly: false);
    canvas.restore();
  }

  void _paintTiles(
    Canvas canvas,
    Paint paint,
    double w,
    double h, {
    required bool dormantOnly,
  }) {
    final cols = field.cols, rows = field.rows;
    final cellW = w / cols, cellH = h / rows;
    for (var index = 0; index < field.tiles.length; index++) {
      final t = field.tiles[index];
      final local = (p - t.startDelay) / _tileLifespan;
      if (dormantOnly) {
        if (local > 0) continue;
      } else {
        if (local <= 0 || local >= 1) continue;
      }
      final nx = (index % cols + 0.5) / cols;
      final ny = (index ~/ cols + 0.5) / rows;
      double dx = nx * w, dy = ny * h, scale = 1, alpha = 1;
      if (!dormantOnly) {
        final fade = (local - 0.45) / 0.55;
        alpha = (1 - fade * fade).clamp(0.0, 1.0);
        if (alpha < 0.02) continue;
        final e = local * local;
        final soft = local * local * (3 - 2 * local);
        dy -= h * 1.2 * t.speed * (0.15 * soft + 0.85 * e * (1 + 0.4 * local));
        dx +=
            w * 0.6 * t.driftX * e +
            math.sin(nx * 14.4 + ny * 23.2 + p * _tau) * w * 0.05 * soft;
        scale = 1 - 0.4 * soft;
      }
      paint.color = t.color.withValues(alpha: alpha);
      final hw = cellW * scale * 0.5 + 0.3;
      final hh = cellH * scale * 0.5 + 0.3;
      canvas.drawRect(
        Rect.fromCenter(center: Offset(dx, dy), width: hw * 2, height: hh * 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(AshPainter old) =>
      old.p != p || old.field != field || old.borderRadius != borderRadius;
}
