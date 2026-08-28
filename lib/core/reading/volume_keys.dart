import 'dart:io';

import 'package:flutter/services.dart';

/// Hardware volume keys as page-turn buttons.
///
/// Android routes the volume keys through the window, above the Flutter view,
/// so a Dart-side `Focus`/`onKeyEvent` handler never sees them — the app's own
/// Activity has to intercept them in `dispatchKeyEvent` and push them back
/// down this channel. (An earlier attempt did it purely in Flutter; the keys
/// simply changed the volume and the page never moved.)
///
/// Enabling this **takes the volume rocker away** from the rest of the system
/// for as long as it's on, so:
///  - it is off unless the reader turns it on,
///  - the reader turns it off again in `dispose`, and
///  - native forces it off in `onPause`, so backgrounding the app can never
///    strand a device with a dead volume rocker.
class VolumeKeys {
  VolumeKeys._();
  static const MethodChannel _ch = MethodChannel('zangetsu/volume_keys');

  /// Called with `true` for volume-up, `false` for volume-down. Null when
  /// nobody is listening.
  static void Function(bool up)? _onKey;

  static bool _bound = false;

  /// Starts routing the volume keys to [onKey]. Safe to call when already
  /// enabled — the last caller wins, which is what a reader re-entering
  /// (chapter change, orientation flip) wants.
  static Future<void> enable(void Function(bool up) onKey) async {
    if (!Platform.isAndroid) return;
    _onKey = onKey;
    if (!_bound) {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'volumeKey') {
          _onKey?.call(call.arguments == 'up');
        }
        return null;
      });
      _bound = true;
    }
    try {
      await _ch.invokeMethod<void>('setEnabled', {'enabled': true});
    } catch (_) {
      // An older native build without the channel: the keys just keep doing
      // what they always did. Nothing to report.
    }
  }

  /// Gives the volume keys back. Always call this when the reader closes.
  static Future<void> disable() async {
    if (!Platform.isAndroid) return;
    _onKey = null;
    try {
      await _ch.invokeMethod<void>('setEnabled', {'enabled': false});
    } catch (_) {}
  }
}
