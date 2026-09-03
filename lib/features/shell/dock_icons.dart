import 'package:flutter/material.dart';

import '../../core/ui/nav_prefs.dart';

/// The custom navbar icon set — clean single-silhouette glyphs drawn on a
/// 24×24 grid (1.7px rounded stroke), each with a solid `filled` twin used
/// for the active tab (outline → fill is the whole active signal; nothing is
/// drawn around the icon). The header trio (search, download, bell) is
/// stroke-only — a header action has no active state to signal.
enum DockGlyph { home, bookmark, calendar, search, download, bell }

/// The hand-drawn glyph for a tab, or null when it uses a Material icon.
///
/// Shared by the dock and by the Settings preview so the two can't drift —
/// a preview that draws a different icon than the bar is worse than none.
/// The original four are custom paths; tabs added later reuse Material's
/// outlined/filled pair rather than having a glyph drawn for them.
DockGlyph? dockGlyphFor(DockTab t) => switch (t) {
  DockTab.home => DockGlyph.home,
  DockTab.myList => DockGlyph.bookmark,
  _ => null,
};

class DockIcon extends StatelessWidget {
  const DockIcon(
    this.glyph, {
    super.key,
    required this.color,
    this.filled = false,
    this.size = 23,
  });

  final DockGlyph glyph;
  final Color color;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _DockIconPainter(glyph: glyph, color: color, filled: filled),
    );
  }
}

class _DockIconPainter extends CustomPainter {
  const _DockIconPainter({
    required this.glyph,
    required this.color,
    required this.filled,
  });

  final DockGlyph glyph;
  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24; // scale from the 24-grid
    canvas.scale(s);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (glyph) {
      case DockGlyph.home:
        final p = Path()
          ..moveTo(4.5, 10.2)
          ..lineTo(12, 4)
          ..lineTo(19.5, 10.2)
          ..lineTo(19.5, 19)
          ..arcToPoint(const Offset(17.9, 20.6), radius: const Radius.circular(1.6))
          ..lineTo(6.1, 20.6)
          ..arcToPoint(const Offset(4.5, 19), radius: const Radius.circular(1.6))
          ..close();
        canvas.drawPath(p, filled ? fill : stroke);
        if (filled) canvas.drawPath(p, stroke..strokeWidth = 1.2);

      case DockGlyph.bookmark:
        final p = Path()
          ..moveTo(6.8, 4.2)
          ..lineTo(17.2, 4.2)
          ..lineTo(17.2, 19.6)
          ..lineTo(12, 16.3)
          ..lineTo(6.8, 19.6)
          ..close();
        canvas.drawPath(p, filled ? fill : stroke);
        if (filled) canvas.drawPath(p, stroke..strokeWidth = 1.2);

      case DockGlyph.calendar:
        final r = RRect.fromRectAndRadius(
          const Rect.fromLTWH(4, 5.6, 16, 14.8),
          const Radius.circular(3.2),
        );
        if (filled) {
          canvas.drawRRect(r, fill);
        } else {
          canvas.drawRRect(r, stroke);
          canvas.drawLine(
            const Offset(4, 10.4),
            const Offset(20, 10.4),
            stroke..strokeWidth = 1.5,
          );
        }
        // Binder rings.
        final tick = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = filled ? 1.9 : 1.7
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(const Offset(8.4, 3.6), const Offset(8.4, 6.8), tick);
        canvas.drawLine(const Offset(15.6, 3.6), const Offset(15.6, 6.8), tick);

      // ── Header actions (stroke-only, no filled twin) ──────────────────────
      case DockGlyph.search:
        canvas.drawCircle(const Offset(10.6, 10.6), 5.4, stroke);
        canvas.drawLine(const Offset(14.7, 14.7), const Offset(19.4, 19.4), stroke);

      case DockGlyph.download:
        // Arrow into a tray — same rounded-tray corners as the home glyph.
        canvas.drawLine(const Offset(12, 4.6), const Offset(12, 13.8), stroke);
        final chevron = Path()
          ..moveTo(7.6, 10.2)
          ..lineTo(12, 14.6)
          ..lineTo(16.4, 10.2);
        canvas.drawPath(chevron, stroke);
        final tray = Path()
          ..moveTo(4.8, 16.4)
          ..lineTo(4.8, 18.4)
          ..arcToPoint(const Offset(6.6, 20.2), radius: const Radius.circular(1.8))
          ..lineTo(17.4, 20.2)
          ..arcToPoint(const Offset(19.2, 18.4), radius: const Radius.circular(1.8))
          ..lineTo(19.2, 16.4);
        canvas.drawPath(tray, stroke);

      case DockGlyph.bell:
        final body = Path()
          ..moveTo(5.4, 16.6)
          ..lineTo(6.5, 9.4)
          ..cubicTo(6.9, 5.8, 8.9, 4.2, 12, 4.2)
          ..cubicTo(15.1, 4.2, 17.1, 5.8, 17.5, 9.4)
          ..lineTo(18.6, 16.6)
          ..close();
        canvas.drawPath(body, stroke);
        // Clapper: the bottom arc of a small circle under the lip.
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(12, 18.7), radius: 2),
          0.3,
          2.54,
          false,
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_DockIconPainter old) =>
      old.glyph != glyph || old.color != color || old.filled != filled;
}
