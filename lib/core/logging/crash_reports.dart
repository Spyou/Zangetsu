import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';

/// Crash reporting, behind one switch.
///
/// Every call is safe to make before (or without) Firebase: a build with no
/// `google-services.json`, a device with no Play Services, or a debug run all
/// leave [_on] false and every method becomes a no-op. Nothing here may ever
/// be the reason the app fails to start.
///
/// Why it exists: a crash took the process with it, so the in-app log never
/// got to say what happened, and the only evidence was a screen recording of
/// the app disappearing. Crashlytics catches the ones the Dart logger cannot
/// see — native signals and uncaught platform exceptions included.
///
/// It pairs with [AppLogger] rather than replacing it: this says WHAT crashed,
/// the log says what the app was doing for the twenty minutes before.
class CrashReports {
  CrashReports._();

  static bool _on = false;

  /// True once reporting is live. Read by tests and by anything that wants to
  /// avoid building a report nobody will send.
  static bool get enabled => _on;

  /// Turns reporting on. Call after `Firebase.initializeApp()` succeeds.
  ///
  /// Off in debug: a crash while developing is already on the console, and
  /// filling the dashboard with them buries the real ones from real users.
  static Future<void> enable() async {
    if (kDebugMode) return;
    try {
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(true);
      _on = true;
    } catch (_) {
      _on = false;
    }
  }

  /// Stops reporting — for an opt-out, should one ever be added.
  static Future<void> disable() async {
    _on = false;
    try {
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(false);
    } catch (_) {
      /* nothing to turn off */
    }
  }

  /// Records [error]. [fatal] marks the ones that ended the app, which is what
  /// the crash-free-users figure counts.
  ///
  /// The message is redacted with the same rule the shared log uses. Error
  /// strings here routinely carry a source URL, and a token in a query string
  /// would otherwise be sitting in a third-party dashboard.
  static void record(Object error, StackTrace? stack, {bool fatal = false}) {
    if (!_on) return;
    try {
      FirebaseCrashlytics.instance.recordError(
        AppLogger.redact(error.toString()),
        stack,
        fatal: fatal,
      );
    } catch (_) {
      /* reporting a crash must never cause one */
    }
  }

  /// A short label for what the app was doing, attached to whatever crashes
  /// next. Crashlytics keeps the last 64; it is a breadcrumb trail, not a log.
  static void note(String message) {
    if (!_on) return;
    try {
      FirebaseCrashlytics.instance.log(AppLogger.redact(message));
    } catch (_) {
      /* best effort */
    }
  }

  /// Context that makes an issue list readable at a glance — which mode, which
  /// source, how many are installed. Keys are capped at 64 by Crashlytics, so
  /// use few and keep them stable.
  ///
  /// Never an account, an email or an id: an issue can sit in the dashboard
  /// for months, and nothing here should trace back to a person.
  static void setKey(String key, Object value) {
    if (!_on) return;
    try {
      FirebaseCrashlytics.instance.setCustomKey(
        key,
        AppLogger.redact(value.toString()),
      );
    } catch (_) {
      /* best effort */
    }
  }
}
