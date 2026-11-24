import 'package:flutter/material.dart';

import '../../core/playback/parental_guide_service.dart';

/// The short content-warnings card shown when playback starts: a thin bar grows
/// down the left, the rows fade in one by one, hold for about five seconds,
/// then fade out in reverse. [onDone] fires when it has finished.
class ParentalGuideCard extends StatefulWidget {
  const ParentalGuideCard({
    super.key,
    required this.warnings,
    required this.onDone,
  });

  final List<ParentalWarning> warnings;
  final VoidCallback onDone;

  @override
  State<ParentalGuideCard> createState() => _ParentalGuideCardState();
}

class _ParentalGuideCardState extends State<ParentalGuideCard>
    with SingleTickerProviderStateMixin {
  static const _rowHeight = 18.0;
  static const _rowGap = 2.0;

  late final int _n = widget.warnings.length;
  // Timeline in ms: card in (300) + bar grows (400) → rows in (80 apart) →
  // hold 5s → rows out (60 apart) → bar shrinks (300) → card out (200).
  late final double _holdEnd = 400.0 + 80 * _n + 200 + 5000;
  late final double _rowsOutEnd = _holdEnd + 60 * _n + 100;
  late final double _total = _rowsOutEnd + 300 + 200;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _total.round()),
  )..forward().whenComplete(() => widget.onDone());

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // 0→1 over [dur] starting at [from] (ms), clamped.
  static double _ramp(double ms, double from, double dur) =>
      ((ms - from) / dur).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final barHeight = _rowHeight * _n + _rowGap * (_n - 1);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final ms = _c.value * _total;
        final card =
            _ramp(ms, 0, 300) * (1 - _ramp(ms, _rowsOutEnd + 300, 200));
        final grow = Curves.easeInOut.transform(_ramp(ms, 0, 400));
        final shrink = Curves.easeInOut.transform(_ramp(ms, _rowsOutEnd, 300));
        return Opacity(
          opacity: card,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: barHeight * grow * (1 - shrink),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _n; i++) ...[
                    if (i > 0) const SizedBox(height: _rowGap),
                    Opacity(
                      opacity:
                          _ramp(ms, 400.0 + 80 * (i + 1), 200) *
                          (1 - _ramp(ms, _holdEnd + 60 * (_n - 1 - i), 150)),
                      child: SizedBox(
                        height: _rowHeight,
                        child: _row(widget.warnings[i]),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(ParentalWarning w) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: w.label,
          style: const TextStyle(
            color: Color(0xD9FFFFFF),
            fontWeight: FontWeight.w600,
          ),
        ),
        const TextSpan(
          text: ' · ',
          style: TextStyle(color: Color(0x66FFFFFF)),
        ),
        TextSpan(
          text: w.severity,
          style: const TextStyle(color: Color(0x80FFFFFF)),
        ),
      ],
    ),
    // Fixed row height beside the bar, so no font scaling here.
    textScaler: TextScaler.noScaling,
    style: const TextStyle(
      fontSize: 11,
      height: 1.0,
      shadows: [Shadow(blurRadius: 4, color: Color(0x99000000))],
    ),
  );
}
