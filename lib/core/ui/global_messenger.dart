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
