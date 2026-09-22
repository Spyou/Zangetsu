import 'dart:async';

import 'package:flutter/material.dart';

/// App-wide ScaffoldMessenger so non-widget code (e.g. the AniList scrobbler
/// running from the player controller) can surface a brief toast. Wired into
/// the root [MaterialApp] via `scaffoldMessengerKey`.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// App-wide Navigator so non-widget code (e.g. tapping a "new episode"
/// notification) can push a route. Wired into the root [MaterialApp] via
/// `navigatorKey`.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void showGlobalSnack(String message) {
  rootMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
}

/// Completes once the real shell route is on screen and startup has finished.
///
/// Two things happen before it that anything arriving from outside has to sit
/// through. A cold launch from a file manager delivers the link while the
/// splash is still up: [rootNavigatorKey] already has a state, so waiting on
/// that alone pushed a screen whose widgets read singletons registered later
/// in startup — the player reads `sl<CastController>()` and threw while
/// building. And once startup does finish, the splash route is swapped for the
/// shell with `pushReplacement`, which REPLACES whatever is on top, so a
/// screen pushed even a moment early is silently thrown away.
///
/// Both look identical to the user: the video flashes and they are back where
/// they started.
Future<void> get appShellReady => _appShellReady.future;
final Completer<void> _appShellReady = Completer<void>();

/// Called by the app once the shell route is up. Safe to call more than once.
void markAppShellReady() {
  if (!_appShellReady.isCompleted) _appShellReady.complete();
}
