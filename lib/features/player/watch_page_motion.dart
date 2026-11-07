import 'package:cue/cue.dart';
import 'package:flutter/material.dart';

bool watchPageMotionEnabled(BuildContext context) =>
    MediaQuery.orientationOf(context) == Orientation.portrait &&
    !MediaQuery.disableAnimationsOf(context);

/// Pointer feedback observes the existing gesture; it never delays its action.
class WatchPagePress extends StatefulWidget {
  const WatchPagePress({super.key, required this.child});
  final Widget child;

  @override
  State<WatchPagePress> createState() => _WatchPagePressState();
}

class _WatchPagePressState extends State<WatchPagePress> {
  bool _pressed = false;

  void _release(PointerEvent _) {
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = watchPageMotionEnabled(context);
    return Listener(
      onPointerDown: (_) {
        if (enabled && !_pressed) setState(() => _pressed = true);
      },
      onPointerUp: _release,
      onPointerCancel: _release,
      child: enabled
          ? Cue.onToggle(
              toggled: _pressed,
              motion: const CueMotion.easeOut(Duration(milliseconds: 80)),
              reverseMotion: const CueMotion.easeOut(
                Duration(milliseconds: 120),
              ),
              acts: const [Act.scale(from: 1, to: .97)],
              child: widget.child,
            )
          : widget.child,
    );
  }
}

class WatchPageChange extends StatelessWidget {
  const WatchPageChange({
    super.key,
    required this.value,
    required this.child,
    this.move = true,
  });
  final Object? value;
  final Widget child;
  final bool move;

  @override
  Widget build(BuildContext context) {
    if (!watchPageMotionEnabled(context)) return child;
    return Cue.onChange(
      value: value,
      fromCurrentValue: true,
      motion: const CueMotion.easeOut(Duration(milliseconds: 180)),
      acts: [
        const Act.fadeIn(from: .7),
        if (move) const Act.translateY(from: 3),
      ],
      child: child,
    );
  }
}

class WatchPageMenuEntrance extends StatelessWidget {
  const WatchPageMenuEntrance({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!watchPageMotionEnabled(context)) return child;
    return Cue.onMount(
      motion: const CueMotion.easeOut(Duration(milliseconds: 180)),
      acts: const [Act.fadeIn(from: .85), Act.translateY(from: 8)],
      child: child,
    );
  }
}
