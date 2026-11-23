import 'package:cue/cue.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

const watchPageRotationSwipeDistance = 64.0;

/// Shows how much of the rotation swipe is left without moving its hit area.
class WatchPageRotationPreview extends StatelessWidget {
  const WatchPageRotationPreview({
    super.key,
    required this.pull,
    required this.child,
    this.minimizeOnDown = false,
  });

  final ValueListenable<double> pull;
  final Widget child;
  final bool minimizeOnDown;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ValueListenableBuilder<double>(
      valueListenable: pull,
      child: child,
      builder: (context, distance, child) {
        final minimizing = minimizeOnDown && distance > 0;
        final progress = (distance.abs() / watchPageRotationSwipeDistance)
            .clamp(0.0, 1.0);
        final color = progress == 1
            ? Theme.of(context).colorScheme.secondary
            : Colors.white;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(
                begin: 0,
                end: reduceMotion || minimizing
                    ? 0
                    : (distance * .5).clamp(-36.0, 36.0),
              ),
              duration: distance == 0 && !reduceMotion
                  ? const Duration(milliseconds: 160)
                  : Duration.zero,
              curve: Curves.easeOut,
              builder: (_, offset, child) => Transform.translate(
                offset: Offset(0, offset),
                transformHitTests: false,
                child: child,
              ),
              child: child,
            ),
            if (distance != 0)
              Positioned(
                top:
                    16 +
                    (minimizing && !reduceMotion
                        ? distance.clamp(0.0, watchPageRotationSwipeDistance)
                        : 0),
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              distance < 0
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              size: 16,
                              color: color,
                            ),
                            if (!minimizing) ...[
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 48,
                                child: LinearProgressIndicator(
                                  key: const ValueKey(
                                    'watch-rotation-pull-progress',
                                  ),
                                  value: progress,
                                  minHeight: 3,
                                  color: color,
                                  backgroundColor: Colors.white24,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

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
