import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import 'animation_prefs.dart';

/// A subtle, professional entrance for a list/grid item: a clean fade + a small
/// slide-up. It fires the moment the item is BUILT — which lazy lists do a bit
/// ahead of the viewport — so cards are already settled by the time they scroll
/// into view (no blank/loading gaps).
///
/// Self-gating: on TV, or when [AnimationPrefs.listAnimations] is off, it returns
/// the child untouched, with zero overhead.
class RevealItem extends StatefulWidget {
  const RevealItem({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<RevealItem> createState() => _RevealItemState();
}

class _RevealItemState extends State<RevealItem>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void initState() {
    super.initState();
    if (!AnimationPrefs.listAnimations || sl<AppMode>().isTv) return;
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    // Small capped stagger so a screenful eases in together, not all at once.
    final delay = Duration(milliseconds: 20 * (widget.index % 4));
    Future.delayed(delay, () {
      if (mounted) _c?.forward();
    });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return widget.child;
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 10),
            child: child,
          ),
        );
      },
    );
  }
}
