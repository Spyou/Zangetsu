import 'package:flutter/widgets.dart';

/// App-wide route observer so a widget can tell when another screen is pushed
/// over it or popped back off. The detail hero uses it to pause its autoplaying
/// trailer while the player (or another title) is on top — so a muted trailer
/// isn't left decoding video behind whatever the user is actually looking at —
/// and resume it when they come back.
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
