import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/brand/zangetsu_mark.dart';

/// The mark being cut into existence: the blade is thrown along its own axis,
/// the crescent is revealed in its wake burning red, then cools to white as the
/// red slash lands.
///
/// Drawn rather than played back from frames. The paths are already geometry
/// ([ZangetsuMark]) and the glow is a `MaskFilter.blur` on the same draw call,
/// so there is no sprite sheet in the APK and no `saveLayer` for the glow — the
/// blur rides along with the fill.
class BankaiSplash extends StatelessWidget {
  const BankaiSplash({super.key, required this.progress, this.size = 220});

  /// 0 → nothing drawn, 1 → the finished mark. Drive it with a controller.
  final double progress;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: BankaiPainter(progress)),
  );
}

double _ease(double t) => 1 - math.pow(1 - t, 3).toDouble();
double _seg(double t, double a, double b) =>
    ((t - a) / (b - a)).clamp(0.0, 1.0);

/// Public so it can be driven straight from a PictureRecorder in tests —
/// pumping this through a RepaintBoundary and calling toImage() hangs the test
/// binding.
class BankaiPainter extends CustomPainter {
  BankaiPainter(this.t);

  final double t;

  /// The energy colour. Deliberately the artwork's own red rather than a
  /// dimmer "ember" — the brighter burn is what reads at splash size.
  static const Color _energy = Color(0xFFF80C19);
  static const Color _slashRed = Color(0xFFF80C19);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / ZangetsuMark.side;
    canvas.save();
    canvas.scale(s);

    final cut = _ease(_seg(t, 0.05, 0.55));
    final heat = 1 - _ease(_seg(t, 0.52, 0.98));
    final rad = math.pi * ZangetsuMark.bladeAngleDeg / 180.0;
    final ux = math.cos(rad), uy = math.sin(rad);

    // ── the crescent, revealed behind the cut ──────────────────────────────
    if (cut > 0) {
      canvas.save();
      _clipWake(canvas, cut, rad);
      final body = Color.lerp(Colors.white, _energy, heat)!;
      if (heat > 0.02) {
        canvas.drawPath(
          ZangetsuMark.crescent,
          Paint()
            ..color = _energy.withValues(alpha: (0.35 + 0.5 * heat).clamp(0, 1))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + 26 * heat),
        );
      }
      canvas.drawPath(ZangetsuMark.crescent, Paint()..color = body);
      canvas.restore();
    }

    // ── the blade, thrown along its own axis with motion ghosts ────────────
    if (t < 0.60) {
      final travel = (_ease(_seg(t, 0.0, 0.55)) - 1.0) * 431;
      const ghosts = <({double back, double alpha})>[
        (back: 101, alpha: 0.10),
        (back: 64, alpha: 0.18),
        (back: 34, alpha: 0.30),
        (back: 0, alpha: 1.0),
      ];
      final fadeIn = (t / 0.10 + 0.15).clamp(0.0, 1.0);
      for (final g in ghosts) {
        final d = travel - g.back;
        canvas.save();
        canvas.translate(ux * d, uy * d);
        canvas.drawPath(
          ZangetsuMark.blade,
          Paint()..color = Colors.white.withValues(alpha: g.alpha * fadeIn),
        );
        canvas.restore();
      }
    } else {
      canvas.drawPath(ZangetsuMark.blade, Paint()..color = Colors.white);
    }

    // ── the red slash: last in, and the last thing still glowing ───────────
    final sp = _ease(_seg(t, 0.28, 0.66));
    if (sp > 0) {
      canvas.save();
      _clipWake(canvas, sp, rad);
      final flare = 1 - _ease(_seg(t, 0.5, 1.0));
      if (flare > 0.02) {
        canvas.drawPath(
          ZangetsuMark.slash,
          Paint()
            ..color = _slashRed.withValues(
              alpha: (0.4 + 0.5 * flare).clamp(0, 1),
            )
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + 20 * flare),
        );
      }
      canvas.drawPath(ZangetsuMark.slash, Paint()..color = _slashRed);
      canvas.restore();
    }

    // ── the impact: a glint along the cut, not a full-frame wash ───────────
    final f = 1 - (_seg(t, 0.45, 0.70) * 2 - 1).abs();
    if (f > 0.01) {
      canvas.save();
      canvas.translate(ZangetsuMark.side / 2, ZangetsuMark.side / 2);
      canvas.rotate(rad);
      canvas.drawRect(
        const Rect.fromLTRB(-700, -40, 700, 40),
        Paint()
          ..color = const Color(0xFFFFE6E6).withValues(alpha: 0.22 * f * f)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40),
      );
      canvas.restore();
    }

    canvas.restore();
  }

  /// Clip to everything the cut has already passed — a half-plane whose edge is
  /// perpendicular to the blade, sweeping along it.
  void _clipWake(Canvas canvas, double p, double rad) {
    canvas.translate(ZangetsuMark.side / 2, ZangetsuMark.side / 2);
    canvas.rotate(rad);
    // Starts fully behind the mark and ends fully past it, so p maps the whole
    // sweep rather than clipping early at the corners.
    final edge = -620 + 1240 * p;
    canvas.clipRect(Rect.fromLTRB(-700, -700, edge, 700));
    canvas.rotate(-rad);
    canvas.translate(-ZangetsuMark.side / 2, -ZangetsuMark.side / 2);
  }

  @override
  bool shouldRepaint(BankaiPainter old) => old.t != t;
}
