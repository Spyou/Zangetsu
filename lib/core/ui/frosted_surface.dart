import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Apple-style vibrancy. [blur] true → real BackdropFilter (use ONLY on static
/// overlays: sheets, controls, nav — never inside scrolling content). [blur]
/// false → a translucent fill only (cheap; for scroll contexts). Always
/// RepaintBoundary-wrapped so it never repaints its neighbors.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({
    super.key,
    required this.child,
    this.blur = true,
    this.opacity = 0.6,
    this.borderRadius,
  });
  final Widget child;
  final bool blur;
  final double opacity;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final r = borderRadius ?? BorderRadius.zero;
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: opacity),
        borderRadius: r,
      ),
      child: child,
    );
    if (!blur) {
      return RepaintBoundary(child: ClipRRect(borderRadius: r, child: fill));
    }
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: fill,
        ),
      ),
    );
  }
}
