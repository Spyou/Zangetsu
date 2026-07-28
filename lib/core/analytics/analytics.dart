import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Thin wrapper over Firebase Analytics.
///
/// [enabled] is flipped on only after `Firebase.initializeApp()` succeeds, so
/// every call is a safe no-op when Firebase isn't configured — a build without
/// `google-services.json`, or an iOS build without `GoogleService-Info.plist`.
/// Nothing here can crash the app or block a user action.
class Analytics {
  Analytics._();

  static bool enabled = false;

  static NavigatorObserver? _observer;

  /// NavigatorObserver that auto-logs a `screen_view` on every route push.
  ///
  /// Building the real observer touches `FirebaseAnalytics.instance`, which
  /// THROWS `[core/no-app]` when Firebase isn't initialized — so we fall back to
  /// a plain no-op observer instead of crashing during the MaterialApp build.
  static NavigatorObserver get observer {
    if (_observer != null) return _observer!;
    try {
      _observer = FirebaseAnalyticsObserver(
        analytics: FirebaseAnalytics.instance,
      );
    } catch (_) {
      _observer = NavigatorObserver();
    }
    return _observer!;
  }

  /// Log a custom event (e.g. `Analytics.log('video_play', {'source': 'anilist'})`).
  static Future<void> log(String name, [Map<String, Object>? params]) async {
    if (!enabled) return;
    try {
      await FirebaseAnalytics.instance.logEvent(name: name, parameters: params);
    } catch (e) {
      if (kDebugMode) debugPrint('[analytics] logEvent($name) failed: $e');
    }
  }
}
