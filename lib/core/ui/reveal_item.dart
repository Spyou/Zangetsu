import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import 'animation_prefs.dart';

/// Dantotsu-style entrance for a list/grid item: fade + slide-up + scale, fired
/// the first time the item actually scrolls into view (so off-screen content
/// doesn't burn its animation invisibly). Staggered by [index] so a screenful
/// cascades. Runs once, then never again.
///
/// Self-gating: on TV, or when [AnimationPrefs.listAnimations] is off, it
/// returns the child untouched — safe to wrap anything, and zero overhead when
/// disabled (no VisibilityDetector at all).
class RevealItem extends StatefulWidget {
  const RevealItem({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<RevealItem> createState() => _RevealItemState();
}

class _RevealItemState extends State<RevealItem>
    with SingleTickerProviderStateMixin {
  late final bool _enabled =
      AnimationPrefs.listAnimations && !sl<AppMode>().isTv;
  final Key _vkey = UniqueKey();
  AnimationController? _c;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (_enabled) {
      _c = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 400),
      );
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  void _onVisibility(double fraction) {
    if (_started || !_enabled || !mounted) return;
    if (fraction > 0.06) {
      _started = true;
      final delay = Duration(milliseconds: 40 * (widget.index % 5));
      Future.delayed(delay, () {
        if (mounted) _c?.forward();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return widget.child;
    return VisibilityDetector(
      key: _vkey,
      onVisibilityChanged: (info) => _onVisibility(info.visibleFraction),
      child: AnimatedBuilder(
        animation: c,
        child: widget.child,
        builder: (context, child) {
          // Dantotsu (Dartotsu) card feel: a scale pop from 0.1 + a small slide,
          // easeInOut. A quick fade only guards the pre-trigger frame from
          // flashing a tiny card (the visibility trigger adds a beat of delay).
          final raw = c.value;
          final t = Curves.easeInOut.transform(raw);
          return Opacity(
            opacity: (raw / 0.3).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 24),
              child: Transform.scale(scale: 0.1 + 0.9 * t, child: child),
            ),
          );
        },
      ),
    );
  }
}
