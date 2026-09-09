import 'package:flutter/widgets.dart';

/// Suppresses stray [TvFocusable] activations right after a route is popped.
///
/// On Android TV the remote Back often pops on KeyDown while the KeyUp (or a
/// paired OK release) lands on the screen below and re-triggers the control
/// that pushed the route — e.g. detail closes then immediately re-opens.
class TvRoutePopGuard {
  TvRoutePopGuard._();

  static int _suppressActivateUntilMs = 0;

  /// True while [TvFocusable] should ignore OK/tap activations.
  static bool get suppressActivate {
    return DateTime.now().millisecondsSinceEpoch < _suppressActivateUntilMs;
  }

  /// Call when any route is popped so the screen underneath ignores ghost keys.
  static void markPopped({Duration window = const Duration(milliseconds: 400)}) {
    _suppressActivateUntilMs =
        DateTime.now().millisecondsSinceEpoch + window.inMilliseconds;
  }
}

/// Marks [TvRoutePopGuard] whenever a route is popped off the stack.
class TvRoutePopGuardObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    TvRoutePopGuard.markPopped();
  }
}
