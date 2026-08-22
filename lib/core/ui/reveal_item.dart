import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import 'animation_prefs.dart';

/// Entrance animation for a list/grid item: a fade with a slide-up and a small
/// scale, fired the first time the card is actually ON SCREEN.
///
/// Visibility is the whole point. This used to start on BUILD, and a lazy list
/// builds roughly a screen ahead of the viewport — so every card finished
/// animating long before it was scrolled to and the reveal was invisible in
/// practice. `visibility_detector` was already a dependency (main.dart even
/// tunes its interval for "the list-reveal animations") but nothing used it.
///
/// Self-gating: on TV, or with [AnimationPrefs.listAnimations] off, the child
/// is returned untouched with no detector and no controller.
class RevealItem extends StatefulWidget {
  const RevealItem({super.key, required this.index, required this.child});

  /// Position in the list — drives the stagger so a screenful cascades in
  /// rather than snapping as one block.
  final int index;
  final Widget child;

  @override
  State<RevealItem> createState() => _RevealItemState();
}

class _RevealItemState extends State<RevealItem>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;
  bool _fired = false;

  /// Captured once, at build time for this card. A card that has already
  /// revealed keeps the style it revealed with; a change applies as you scroll
  /// on, which is the only thing that makes sense for a one-shot entrance.
  late final ListAnimStyle _style = AnimationPrefs.style;

  /// VisibilityDetector keys must be unique across the whole app, and stable
  /// for the life of this state — index alone would collide between two rows
  /// showing the same position, and a key rebuilt each frame would re-register
  /// the detector constantly.
  final Key _visKey = UniqueKey();

  /// How far the card travels up on the way in. Was 10 — too small to register
  /// as movement at all.
  static const double _travel = 28;

  @override
  void initState() {
    super.initState();
    if (!AnimationPrefs.listAnimations || sl<AppMode>().isTv) return;
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  void _onVisible(VisibilityInfo info) {
    if (_fired || !mounted || info.visibleFraction <= 0) return;
    _fired = true;
    // Cascade across a screenful. The old stagger was `index % 4`, which reset
    // every fourth card, so items 4, 8, 12… all started together and there was
    // no wave. Modulo 8 with a longer step reads as one continuous run, and
    // stays capped so a long list never accumulates a visible lag.
    final delay = Duration(milliseconds: 45 * (widget.index % 8));
    Future.delayed(delay, () {
      if (mounted) _c?.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return widget.child;
    return VisibilityDetector(
      key: _visKey,
      onVisibilityChanged: _onVisible,
      child: AnimatedBuilder(
        animation: c,
        child: widget.child,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(c.value);
          // Full opacity arrives a little before the movement settles, so the
          // card is readable while it's still easing into place.
          final fade = Curves.easeOut.transform((c.value * 1.4).clamp(0.0, 1.0));
          return switch (_style) {
            ListAnimStyle.fade => Opacity(opacity: fade, child: child),
            ListAnimStyle.zoom => Opacity(
              opacity: fade,
              child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
            ),
            ListAnimStyle.rise => Opacity(
              opacity: fade,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * _travel),
                // The lift, rather than just a drift upwards.
                child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
              ),
            ),
          };
        },
      ),
    );
  }
}
