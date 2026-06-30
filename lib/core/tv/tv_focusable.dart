import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 2.5,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
