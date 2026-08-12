import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/di/injector.dart';
import '../../core/reading/reader_prefs.dart';

/// Shared "reading comfort" side effects for both readers — keep-awake,
/// brightness override, and orientation lock. All three are global OS
/// state, so every knob [applyReaderComfort] can set MUST be undone by
/// [restoreReaderComfort] (call from `dispose`), the same way
/// player_screen.dart resets brightness/wakelock/orientation on the way out
/// of the player — otherwise leaving the reader can leave the phone dimmed,
/// orientation-locked, or awake behind it.
///
/// Nothing in `main.dart` locks orientation at startup, so "restore to
/// default" here means all four orientations, not a single one.
mixin ReaderComfortMixin<T extends StatefulWidget> on State<T> {
  static const List<DeviceOrientation> _allOrientations =
      DeviceOrientation.values;

  /// Applies the current comfort prefs. Call once from `initState`, and
  /// again whenever a comfort pref changes from a settings sheet so the
  /// change takes effect immediately.
  void applyReaderComfort() {
    final prefs = sl<ReaderPrefs>();

    if (prefs.keepScreenOn) {
      WakelockPlus.enable().ignore();
    } else {
      WakelockPlus.disable().ignore();
    }

    final brightness = prefs.brightness;
    if (brightness >= 0) {
      ScreenBrightness.instance
          .setApplicationScreenBrightness(brightness)
          .catchError((_) {});
    } else {
      ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
        (_) {},
      );
    }

    SystemChrome.setPreferredOrientations(_orientationsFor(prefs.orientation));
  }

  /// Undoes every side effect [applyReaderComfort] can set — call from
  /// `dispose`.
  void restoreReaderComfort() {
    WakelockPlus.disable().ignore();
    ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
      (_) {},
    );
    SystemChrome.setPreferredOrientations(_allOrientations);
  }

  List<DeviceOrientation> _orientationsFor(String orientation) {
    switch (orientation) {
      case 'portrait':
        return const [DeviceOrientation.portraitUp];
      case 'landscape':
        return const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
      default: // 'system' — no lock
        return _allOrientations;
    }
  }
}
