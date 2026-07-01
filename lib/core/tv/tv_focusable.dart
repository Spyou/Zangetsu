import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
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
  });
  final Widget child;
  final VoidCallback onTap;
  final bool autofocus;
  final double scale;

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
      child: AnimatedScale(
        scale: _focused ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 120),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // Faint accent fill on focus — makes the highlight read clearly even
            // over video or busy artwork, not just from the border alone.
            color: _focused
                ? AppColors.accent.withValues(alpha: 0.16)
                : null,
            border: Border.all(
              color: _focused ? AppColors.accent : Colors.transparent,
              width: 3,
            ),
            borderRadius: BorderRadius.circular(10),
            // Dark drop-shadow + faint accent glow make the accent border
            // pop on ANY background — white Play button or dark poster card.
            // The shadow is TV-safe: subtle on dark surfaces, lifts on light.
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
          child: widget.child,
        ),
      ),
    );
  }
}
