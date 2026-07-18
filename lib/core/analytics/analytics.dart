import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

/// Thin wrapper over Firebase Analytics.
///
/// [enabled] is flipped on only after `Firebase.initializeApp()` succeeds, so
/// every call is a safe no-op when Firebase isn't configured (e.g. a build
/// without `google-services.json`). Nothing here can crash the app or block a
/// user action — analytics failures are swallowed.
class Analytics {
  Analytics._();

  static bool enabled = false;
  static final FirebaseAnalytics _fa = FirebaseAnalytics.instance;

  /// NavigatorObserver that auto-logs a `screen_view` on every route push,
  /// giving per-screen usage without touching each screen. Always wired in;
  /// it just no-ops until [enabled] is true.
  static final FirebaseAnalyticsObserver observer =
      FirebaseAnalyticsObserver(analytics: _fa);

  /// Log a custom event (e.g. `Analytics.log('video_play', {'source': 'anilist'})`).
  static Future<void> log(String name, [Map<String, Object>? params]) async {
    if (!enabled) return;
    try {
      await _fa.logEvent(name: name, parameters: params);
    } catch (e) {
      if (kDebugMode) debugPrint('[analytics] logEvent($name) failed: $e');
    }
  }
}
