import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';

/// Apple TV style touch surface: a swipe moves one D-pad step per [stepDistance],
/// resting after a swipe holds that direction (press, then release on lift), and
/// a tap without movement calls [onTap]. Only the first finger is tracked.
///
/// Used by the phone remote panel; the callbacks forward to the remote session,
/// which sends the matching key events to the TV.
class GlassPad extends StatefulWidget {
  /// [onStep], [onHold] and [onRelease] are required because a swipe can start
  /// a held press at any time while [navigation] is on.
  const GlassPad({
    super.key,
    required this.navigation,
    required this.onStep,
    required this.onHold,
    required this.onRelease,
    this.onTap,
    this.onLongPress,
    this.tapLabel = 'OK',
    this.caption,
    this.overlay,
    this.stepDistance = 44,
    // A held press makes the phone send one key at once before repeating, so
    // the rest has to be deliberate or a swipe-then-pause overshoots by one.
    this.holdDelay = const Duration(milliseconds: 500),
  });

  /// Swipes only send directions when true; taps still work without it.
  final bool navigation;

  /// One movement in `up`, `down`, `left` or `right`.
  final ValueChanged<String> onStep;

  /// The finger rested after a swipe: start the held press for this direction.
  final ValueChanged<String> onHold;

  /// Ends a press started by [onHold].
  final VoidCallback onRelease;
  /// Called for a tap that neither moved nor became a hold or long press
  /// (usually OK/select). When null and [navigation] is off, touch is ignored.
  final VoidCallback? onTap;

  /// Called once when a finger stays still for about 550 ms; the lift after it
  /// does not also fire [onTap]. Screen readers get it as the "OK" action.
  final VoidCallback? onLongPress;

  /// Screen reader hint describing what [onTap] does, e.g. `OK`.
  final String tapLabel;

  /// Muted line drawn near the bottom edge (status or hint).
  final Widget? caption;

  /// Drawn over the surface; its own buttons win over the pad's gestures.
  final Widget? overlay;

  /// Logical pixels of travel along one axis that count as one D-pad step.
  final double stepDistance;

  /// How long the finger must rest after a step before [onHold] fires.
  final Duration holdDelay;

  @override
  State<GlassPad> createState() => _GlassPadState();
}

/// Tracks one pointer and turns its movement into steps, holds, taps and long
/// presses; everything runs on the UI thread from pointer events and timers.
class _GlassPadState extends State<GlassPad> {
  /// Movement (logical px) below which a touch still counts as still.
  static const double _slop = 10;

  /// The tracked pointer id, or null when no finger is down.
  int? _pointer;

  /// Touch-down point, position of the last step, and where the finger rested.
  Offset _origin = Offset.zero, _anchor = Offset.zero, _rest = Offset.zero;

  /// Gesture flags: passed the slop, held press active, long press fired.
  bool _moved = false, _held = false, _longPressed = false;

  /// Direction of the latest step, used when arming the held press.
  String? _direction;

  /// Timers for the held press after resting and for the long press.
  Timer? _holdTimer, _longTimer;

  /// True while a finger is down; tints the surface as press feedback.
  bool _touching = false;

  /// Whether swipes may send directions right now.
  bool get _canMove => widget.navigation;

  /// Starts tracking the first finger and arms the long-press timer.
  void _down(PointerDownEvent e) {
    if (_pointer != null) return;
    if (!_canMove && widget.onTap == null) return;
    _pointer = e.pointer;
    _origin = _anchor = _rest = e.localPosition;
    _moved = _held = _longPressed = false;
    _direction = null;
    setState(() => _touching = true);
    if (widget.onLongPress != null) {
      _longTimer = Timer(const Duration(milliseconds: 550), () {
        // Read the current callback: the panel drops it when playback stops
        // or navigation while playing is switched off mid-press.
        final longPress = widget.onLongPress;
        if (_pointer != null && !_moved && longPress != null) {
          _longPressed = true;
          HapticFeedback.mediumImpact();
          longPress();
        }
      });
    }
  }

  /// Sends one step per [GlassPad.stepDistance] of travel on the dominant axis,
  /// ends a held press once the finger leaves its rest point, and re-arms the
  /// hold timer whenever the finger settles somewhere new.
  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final p = e.localPosition;
    if (!_moved && (p - _origin).distance > _slop) {
      _moved = true;
      _longTimer?.cancel();
    }
    if (!_canMove || _longPressed) return;
    if (_held) {
      // Leaving the resting point ends the held press and resumes stepping.
      if ((p - _rest).distance <= _slop) return;
      _endHold();
      _anchor = _rest = p;
      return;
    }
    var stepped = false;
    while (true) {
      final d = p - _anchor;
      final horizontal = d.dx.abs() >= d.dy.abs();
      final along = horizontal ? d.dx : d.dy;
      if (along.abs() < widget.stepDistance) break;
      final sign = along.sign;
      _direction = horizontal
          ? (sign < 0 ? 'left' : 'right')
          : (sign < 0 ? 'up' : 'down');
      _anchor = horizontal
          ? Offset(_anchor.dx + sign * widget.stepDistance, p.dy)
          : Offset(p.dx, _anchor.dy + sign * widget.stepDistance);
      HapticFeedback.selectionClick();
      widget.onStep(_direction!);
      stepped = true;
    }
    if (stepped || (p - _rest).distance > _slop / 2) {
      _rest = p;
      _armHold();
    }
  }

  /// Restarts the timer that turns a rest after a step into [GlassPad.onHold].
  void _armHold() {
    _holdTimer?.cancel();
    final direction = _direction;
    if (direction == null) return;
    _holdTimer = Timer(widget.holdDelay, () {
      if (_pointer != null && !_held && _canMove) {
        _held = true;
        widget.onHold(direction);
      }
    });
  }

  /// Sends [GlassPad.onRelease] if a held press is active.
  void _endHold() {
    if (_held) {
      _held = false;
      widget.onRelease();
    }
  }

  /// Handles lift or cancel; fires [GlassPad.onTap] only for a clean tap.
  void _up(PointerEvent e, {required bool cancelled}) {
    if (e.pointer != _pointer) return;
    final tap = !cancelled && !_moved && !_longPressed && !_held;
    _finish();
    if (tap && widget.onTap != null) {
      HapticFeedback.selectionClick();
      widget.onTap!();
    }
  }

  /// Cancels timers, releases any held press and stops tracking the pointer.
  void _finish() {
    _holdTimer?.cancel();
    _longTimer?.cancel();
    _endHold();
    _pointer = null;
    if (mounted) setState(() => _touching = false);
  }

  /// Releases a held press if the parent turns navigation off mid-hold.
  @override
  void didUpdateWidget(covariant GlassPad old) {
    super.didUpdateWidget(old);
    if (!widget.navigation && _held) _endHold();
  }

  /// Releases a held press so the TV never keeps a key down after the pad goes.
  @override
  void dispose() {
    _holdTimer?.cancel();
    _longTimer?.cancel();
    if (_held) widget.onRelease();
    super.dispose();
  }

  /// Screen readers get the same moves as named actions on the surface.
  Map<CustomSemanticsAction, VoidCallback> get _semanticMoves => {
    if (_canMove)
      for (final d in const ['up', 'down', 'left', 'right'])
        CustomSemanticsAction(label: d[0].toUpperCase() + d.substring(1)): () =>
            widget.onStep(d),
    if (widget.onLongPress != null)
      const CustomSemanticsAction(label: 'OK'): widget.onLongPress!,
  };

  /// Rounded surface with a full-size pointer listener underneath and the
  /// overlay and caption stacked on top.
  @override
  Widget build(BuildContext context) {
    final active = _canMove || widget.onTap != null;
    return Container(
      decoration: BoxDecoration(
        color: _touching
            ? Color.lerp(AppColors.surface, AppColors.surface2, .6)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Semantics(
            label: 'Touch pad',
            hint: _canMove ? 'Swipe to move' : null,
            enabled: active,
            onTap: widget.onTap,
            onTapHint: widget.onTap == null ? null : widget.tapLabel,
            customSemanticsActions: _semanticMoves,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: (e) => _up(e, cancelled: false),
              onPointerCancel: (e) => _up(e, cancelled: true),
              child: const SizedBox.expand(),
            ),
          ),
          // The caption gets its own strip so the overlay (play button, hint)
          // is laid out above it and the two never draw over each other.
          Column(
            children: [
              Expanded(child: widget.overlay ?? const SizedBox.shrink()),
              if (widget.caption != null)
                IgnorePointer(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: DefaultTextStyle.merge(
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textTertiary),
                      child: Center(child: widget.caption!),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
