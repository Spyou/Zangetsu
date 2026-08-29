import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Cached after [resolveAppleTv] runs at boot. Null until then.
bool? _appleTv;

/// Whether this isolate is running on Apple TV (tvOS).
///
/// Prefer [resolveAppleTv] at startup — Dart reports tvOS as iOS and the OS
/// version string often has no "tvos" token (especially on the simulator), so
/// the native `isTv` channel is the source of truth.
bool get isAppleTv => _appleTv ?? _guessAppleTv();

/// Asks the tvOS runner whether this is Apple TV, then caches the result for
/// [isAppleTv]. Safe to call on every platform (no-ops / false off Apple).
Future<bool> resolveAppleTv() async {
  if (_appleTv != null) return _appleTv!;
  if (!Platform.isIOS) {
    _appleTv = false;
    return false;
  }
  // tvOS AppDelegate answers this; iPhone has no handler → false.
  try {
    final v = await const MethodChannel('com.spyou.watch_app/device')
        .invokeMethod<bool>('isTv');
    if (v == true) {
      _appleTv = true;
      return true;
    }
  } catch (_) {
    // No native handler (iPhone) or channel not ready yet.
  }
  _appleTv = _guessAppleTv();
  return _appleTv!;
}

/// Best-effort without native help. Unreliable on the tvOS Simulator.
bool _guessAppleTv() {
  if (!Platform.isIOS) return false;
  final os = Platform.operatingSystem.toLowerCase();
  if (os == 'tvos') return true;
  final v = Platform.operatingSystemVersion.toLowerCase();
  return v.contains('tvos') || v.contains('apple tv');
}
