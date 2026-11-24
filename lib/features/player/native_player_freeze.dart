import 'package:flutter/material.dart';

import 'in_app_mini_player.dart' show dockedPlayer;
import 'phone_playback_launch.dart';

/// Stops the app's animations while the native player sits in front of it.
///
/// On Android 10+ the player window is see-through (so the app shows while the
/// page is dragged into the mini player), which keeps the app behind it
/// drawing for as long as the video plays. Nothing there is visible or
/// touchable then, so its tickers and animated images are paused.
///
/// Picture-in-Picture leaves the app visible and resumed, so this only
/// freezes while the app is *not* resumed.
class NativePlayerFreeze extends StatefulWidget {
  const NativePlayerFreeze({super.key, required this.child});

  final Widget child;

  @override
  State<NativePlayerFreeze> createState() => _NativePlayerFreezeState();
}

class _NativePlayerFreezeState extends State<NativePlayerFreeze>
    with WidgetsBindingObserver {
  AppLifecycleState? _lifecycle = WidgetsBinding.instance.lifecycleState;

  /// A touch on the app means someone is using it (a PiP window leaves it
  /// visible), so it wakes up even if the player never said so.
  bool _touched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    phoneNativeInFront.addListener(_resetTouched);
  }

  void _resetTouched() => _touched = false;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    phoneNativeInFront.removeListener(_resetTouched);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _lifecycle = state);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_touched && phoneNativeInFront.value) {
          setState(() => _touched = true);
        }
      },
      child: ListenableBuilder(
        listenable: Listenable.merge([phoneNativeInFront, dockedPlayer]),
        child: widget.child,
        builder: (context, child) {
          // A docked mini player means the app is what is on screen, so it is
          // never frozen then, whatever order the player's events arrived in.
          final inFront =
              phoneNativeInFront.value && dockedPlayer.value == null;
          return TickerMode(
            enabled:
                !(inFront &&
                    !_touched &&
                    _lifecycle != AppLifecycleState.resumed),
            child: child!,
          );
        },
      ),
    );
  }
}
