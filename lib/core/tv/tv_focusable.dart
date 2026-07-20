import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_keys.dart';

/// Wraps any tappable so it is D-pad focusable on TV: scales + outlines while
/// focused, scrolls itself into view, and invokes [onTap] on OK/Enter/center.
/// Use everywhere on TV layouts instead of bare GestureDetector/InkWell.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    required this.onTap,
    this.autofocus = false,
    this.scale = 1.08,
    this.focusLabel,
    this.foregroundHighlight = false,
  });
  final Widget child;
  final VoidCallback onTap;
  final bool autofocus;
  final double scale;

  /// Paint the focus box OVER the child instead of behind it. For full-width
  /// rows (e.g. detail episode rows) whose content is partly transparent, the
  /// default background paint reads as a strip behind the content; foreground
  /// draws a clean rounded frame on top. Opt-in — posters/tiles keep the
  /// background box so their art isn't tinted.
  final bool foregroundHighlight;

  /// Optional caption drawn BELOW the focusable (e.g. a poster title). When set,
  /// it shows as plain text normally and pops into a filled "chip" while
  /// focused — a Netflix-style label. Only the [child] (the thumbnail) gets the
  /// focus box/scale, so the highlight never wraps the text.
  final String? focusLabel;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && okKeys.contains(event.logicalKey)) {
      widget.onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // The child, optionally with a caption chip overlaid on its bottom edge.
    // Layout-neutral (a Stack, not an extra row), so it works identically in a
    // fixed-size hero card and in a GridView cell — no unbounded-height traps.
    Widget inner = widget.child;
    final label = widget.focusLabel;
    if (label != null) {
      inner = Stack(
        children: [
          Positioned.fill(child: widget.child),
          Positioned(
            left: 6,
            right: 6,
            bottom: 6,
            // Plain (readable over the poster's built-in scrim) normally; pops
            // into a white chip when focused — Netflix-style label.
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: _focused
                  ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
                  : EdgeInsets.zero,
              decoration: BoxDecoration(
                color: _focused ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: _focused ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w600,
                  shadows: _focused
                      ? null
                      : const [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),
          ),
        ],
      );
    }

    // The focus "box": scale + accent outline around the child only, so the
    // highlight is always a clean box around the thumbnail/tile.
    //
    // Draw the outline OVER the child (foreground) when the caller opted out of
    // the scale-up (scale == 1.0) — that's what full-width rows/buttons do, and
    // their opaque background would otherwise hide a background-drawn border,
    // leaving no focus feedback at all. Posters/tiles (scale > 1.0) keep the
    // background box so their art isn't framed, since the scale already reads.
    final bool useForeground = widget.foregroundHighlight || widget.scale == 1.0;
    final Widget box = AnimatedScale(
      scale: _focused ? widget.scale : 1.0,
      duration: const Duration(milliseconds: 120),
      child: DecoratedBox(
        position: useForeground
            ? DecorationPosition.foreground
            : DecorationPosition.background,
        decoration: BoxDecoration(
          color: _focused ? AppColors.accent.withValues(alpha: 0.16) : null,
          border: Border.all(
            color: _focused ? AppColors.accent : Colors.transparent,
            width: 3,
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.65),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.25),
                    blurRadius: 12,
                    spreadRadius: 0,
                  ),
                ]
              : null,
        ),
        child: inner,
      ),
    );

    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 200),
          );
        }
      },
      child: box,
    );
  }
}
