import 'dart:io';

import 'package:flutter/services.dart';

/// Opt-in in-app DNS-over-HTTPS for CloudStream (`.cs3`) sources. Routes the
/// CS OkHttp client's lookups through the chosen provider (bypasses ISP DNS
/// blocking). [off] = no change (default). Android-only; a no-op elsewhere.
class CsDns {
  CsDns._();

  static const MethodChannel _ch = MethodChannel('zangetsu/cloudstream');

  static const int off = 0;
  static const int cloudflare = 1;
  static const int google = 2;
  static const int adguard = 3;
  static const int quad9 = 4;

  /// Display labels, in menu order.
  static const Map<int, String> labels = {
    off: 'Off',
    cloudflare: 'Cloudflare',
    google: 'Google',
    adguard: 'AdGuard',
    quad9: 'Quad9',
  };

  static String labelFor(int choice) => labels[choice] ?? 'Off';

  /// The provider currently applied natively (persisted across launches).
  static Future<int> get() async {
    if (!Platform.isAndroid) return off;
    try {
      return await _ch.invokeMethod<int>('getDns') ?? off;
    } catch (_) {
      return off;
    }
  }

  /// Select a provider; applied immediately + persisted. Best-effort.
  static Future<void> set(int choice) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('setDns', {'choice': choice});
    } catch (_) {}
  }
}
