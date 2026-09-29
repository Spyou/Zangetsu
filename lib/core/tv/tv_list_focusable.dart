import 'package:flutter/material.dart';

import 'tv_focusable.dart';

/// Full-width list/menu row focus for TV — accent border + translucent accent
/// fill (same language as the Providers source-row halo), without scale-up
/// (dense rows sit inside cards where grow would collide with neighbours).
///
/// Prefer this (or a TV-aware [SettingsTile]) over bare [InkWell] / Material
/// focus, which paints behind opaque card fills and is invisible at 10 feet.
/// Keep text/icons light — do not invert to black (that was for the white pill).
///
/// Accent fill is painted as a *foreground* overlay so opaque child surfaces
/// (e.g. Providers hub cards) still show the wash.
class TvListFocusable extends StatelessWidget {
  const TvListFocusable({
    super.key,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
    this.child,
    this.builder,
    this.variant = TvFocusVariant.row,
  }) : assert(child != null || builder != null, 'TvListFocusable needs either child or builder');

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;
  final Widget? child;
  final Widget Function(bool focused)? builder;
  final TvFocusVariant variant;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      variant: variant,
      scale: 1.0,
      semanticLabel: semanticLabel,
      onTap: onTap,
      onLongPress: onLongPress,
      builder: builder,
      child: child,
    );
  }
}
