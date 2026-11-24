import 'package:flutter/widgets.dart';

/// App-wide route observer so a widget can tell when another screen is pushed
/// over it or popped back off. The detail hero uses it to pause its autoplaying
/// trailer while the player (or another title) is on top — so a muted trailer
/// isn't left decoding video behind whatever the user is actually looking at —
/// and resume it when they come back.
///
/// The home banner uses it the same way, to stop advancing while covered.
final RouteObserver<PageRoute<dynamic>> appRouteObserver = _AppRouteObserver();

class _AppRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  /// The player leaves the stack with `removeRoute` when it minimizes into the
  /// mini player. That uncovers the screen below exactly like a pop does, but
  /// the stock observer only reports pops, so the home banner stayed paused
  /// until the next real navigation.
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (route is PageRoute<dynamic> && previousRoute is PageRoute<dynamic>) {
      didPop(route, previousRoute);
    }
  }
}
