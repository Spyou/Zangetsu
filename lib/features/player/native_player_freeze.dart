import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _lifecycle = state);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: phoneNativeInFront,
      child: widget.child,
      builder: (context, inFront, child) => TickerMode(
        enabled: !(inFront && _lifecycle != AppLifecycleState.resumed),
        child: child!,
      ),
    );
  }
}
