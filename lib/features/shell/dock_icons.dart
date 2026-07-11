import 'package:flutter/material.dart';

/// The custom navbar icon set — clean single-silhouette glyphs drawn on a
/// 24×24 grid (1.7px rounded stroke), each with a solid `filled` twin used
/// for the active tab (outline → fill is the whole active signal; nothing is
/// drawn around the icon).
enum DockGlyph { home, search, bookmark, calendar }

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

      case DockGlyph.search:
        const c = Offset(11, 11);
        if (filled) canvas.drawCircle(c, 6.6, fill);
        canvas.drawCircle(c, 6.6, stroke);
        canvas.drawLine(
          const Offset(16.2, 16.2),
          const Offset(20.2, 20.2),
          stroke..strokeWidth = filled ? 2.1 : 1.9,
        );

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
    }
  }

  @override
  bool shouldRepaint(_DockIconPainter old) =>
      old.glyph != glyph || old.color != color || old.filled != filled;
}
