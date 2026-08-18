import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_text.dart';
import 'tv_keys.dart';

/// Visual style of the D-pad focus highlight.
enum TvFocusVariant {
  /// White outline + faint tint box — the default focus for buttons, rows and
  /// tiles that don't opt into another variant. Premium, no accent glow.
  box,

  /// White rounded pill — nav items, action buttons, menu rows. Pair with
  /// [TvFocusable.builder] so the child recolours its icon/text to black
  /// while focused.
  pill,

  /// Poster "float" — scale up + lift + a deep drop shadow and a faint accent
  /// bloom, no ring. For posters, tiles and cards.
  float,
}

/// Wraps any tappable so it is D-pad focusable on TV: highlights while focused,
/// scrolls itself into view, and invokes [onTap] on OK/Enter/center. Use
/// everywhere on TV layouts instead of a bare GestureDetector/InkWell.
///
/// When [onLongPress] is set, OK is held to distinguish tap vs long-press
/// (remote KeyDown is no longer treated as an instant tap). Buttons without
/// a long-press handler stay immediate on KeyDown.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    this.child,
    this.builder,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.scale = 1.08,
    this.focusLabel,
    this.foregroundHighlight = false,
    this.variant = TvFocusVariant.box,
    this.focusNode,
    this.semanticLabel,
    this.isButton = true,
  }) : assert(
          child != null || builder != null,
          'TvFocusable needs either child or builder',
        );

  /// Optional external focus node, so a parent can programmatically move focus
  /// here (e.g. land on the current page's nav item when entering the rail).
  final FocusNode? focusNode;

  /// Static child. Ignored when [builder] is supplied.
  final Widget? child;

  /// Focus-aware child builder. Gets whether this is focused, so callers can
  /// recolour content for the white [TvFocusVariant.pill].
  final Widget Function(bool focused)? builder;

  final VoidCallback onTap;

  /// Optional long-press. On the remote this is a held OK/Select (same
  /// timeout as a touch long-press). Null keeps the snappy KeyDown tap.
  final VoidCallback? onLongPress;

  final bool autofocus;
  final double scale;

  /// Paint the focus box OVER the child instead of behind it (box variant only).
  final bool foregroundHighlight;

  /// Optional caption drawn BELOW the child that pops into a chip while focused
  /// (box variant). Prefer showing a real title now — kept for compatibility.
  final String? focusLabel;

  final TvFocusVariant variant;

  /// Accessible name for TalkBack. Null means no name yet (fine — call sites
  /// add these incrementally).
  final String? semanticLabel;

  /// Whether this reads as a "button" to TalkBack. Almost everything wrapped
  /// in TvFocusable is tap-to-activate, so this defaults on.
  final bool isButton;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;
  int _lastActivateMs = 0;
  Timer? _longPressTimer;
  bool _okHeld = false;
  bool _longPressFired = false;

  @override
  void dispose() {
    _cancelLongPressTimer();
    super.dispose();
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  // Single activation path for both the D-pad OK key and the accessibility
  // "click" (Semantics.onTap), deduped within a short window so a press that
  // arrives on both channels only fires onTap once.
  void _activate() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastActivateMs < 250) return;
    _lastActivateMs = now;
    widget.onTap();
  }

  void _fireLongPress() {
    final cb = widget.onLongPress;
    if (cb == null) return;
    cb();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Deliberately NOT gated on accessibleNavigation. Fire TV reports that flag
    // true after returning from the native player even with no screen reader
    // running, and the old gate dead-keyed OK on everything (nothing was left
    // to fire the Semantics.onTap fallback). _activate dedupes if a real screen
    // reader delivers the click on both channels.
    if (!okKeys.contains(event.logicalKey)) return KeyEventResult.ignored;

    final longPress = widget.onLongPress;

    if (event is KeyDownEvent) {
      if (longPress == null) {
        _activate();
        return KeyEventResult.handled;
      }
      // Wait for hold vs release — KeyDown used to fire tap immediately, so a
      // held OK never had a chance to become a long-press.
      _okHeld = true;
      _longPressFired = false;
      _cancelLongPressTimer();
      _longPressTimer = Timer(kLongPressTimeout, () {
        if (!mounted || !_okHeld) return;
        _longPressFired = true;
        _fireLongPress();
      });
      return KeyEventResult.handled;
    }

    if (longPress == null) return KeyEventResult.ignored;

    if (event is KeyRepeatEvent) {
      // Swallow repeats so they cannot be treated as extra taps.
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      _okHeld = false;
      _cancelLongPressTimer();
      if (!_longPressFired) _activate();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Widget _content() => widget.builder?.call(_focused) ?? widget.child!;

  @override
  Widget build(BuildContext context) {
    Widget inner = _content();

    // Optional caption chip (box variant, legacy).
    final label = widget.focusLabel;
    if (label != null) {
      inner = Stack(
        children: [
          Positioned.fill(child: inner),
          Positioned(
            left: 6,
            right: 6,
            bottom: 6,
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

    final Widget box;
    switch (widget.variant) {
      case TvFocusVariant.box:
        // Premium neutral focus: a clean WHITE outline + a faint white fill and
        // a soft black shadow (no accent tint) — consistent with the float
        // variant used by posters.
        final bool useForeground =
            widget.foregroundHighlight || widget.scale == 1.0;
        box = AnimatedScale(
          scale: _focused ? widget.scale : 1.0,
          duration: const Duration(milliseconds: 120),
          child: DecoratedBox(
            position: useForeground
                ? DecorationPosition.foreground
                : DecorationPosition.background,
            decoration: BoxDecoration(
              color: _focused ? Colors.white.withValues(alpha: 0.08) : null,
              border: Border.all(
                color: _focused ? Colors.white : Colors.transparent,
                width: 2.5,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: inner,
          ),
        );
      case TvFocusVariant.pill:
        box = AnimatedScale(
          scale: _focused ? 1.04 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: _focused ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: inner,
          ),
        );
      case TvFocusVariant.float:
        // Premium focus: scale up, a clean WHITE outline over the edge, and a
        // neutral (never accent-tinted) drop shadow for depth.
        box = AnimatedScale(
          scale: _focused ? widget.scale : 1.0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.6),
                        blurRadius: 22,
                        offset: const Offset(0, 12),
                      ),
                    ]
                  : null,
            ),
            foregroundDecoration: _focused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white, width: 3),
                  )
                : null,
            child: inner,
          ),
        );
    }

    // MergeSemantics collapses the whole focusable into ONE accessibility node
    // so the label, button role and tap action land together on the node that
    // actually receives D-pad/TalkBack focus. Without it, the inner Focus +
    // GestureDetector form a separate, unlabeled node — the one TalkBack lands
    // on — so every nav item/button announced as "unlabeled". The visible label
    // Text is ExcludeSemantics'd at the call sites, so only [semanticLabel]
    // (or, when it's null, the child's own text) names the merged node.
    return MergeSemantics(
      child: Semantics(
        container: true,
        label: widget.semanticLabel,
        button: widget.isButton,
        focused: _focused,
        onTap: _activate,
        onLongPress: widget.onLongPress,
        child: Focus(
          focusNode: widget.focusNode,
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
            } else {
              _okHeld = false;
              _cancelLongPressTimer();
            }
          },
          // Touch support: some Android TVs / TV boxes have a touchscreen. A
          // physical tap fires the same single, deduped action as the remote's
          // OK/Enter (via [_activate]). Remote-only TVs never emit touch events,
          // so this is completely inert there — the D-pad path is untouched. A
          // scroll drag beats the tap in the gesture arena, so lists still
          // scroll. excludeFromSemantics: the outer Semantics already exposes
          // the tap to TalkBack, so this must not add a second, unlabeled node.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: _activate,
            onLongPress: widget.onLongPress,
            child: box,
          ),
        ),
      ),
    );
  }
}
