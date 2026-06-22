import 'dart:io';

import 'package:flutter/services.dart';

import 'subscription_store.dart';

/// Mirrors CloudStream (`cs:`) subscriptions to the native side, which runs the
/// periodic background "new episode" worker (CloudStream's own design — a native
/// WorkManager job re-runs `PluginHost.load()`). JS sources can't run in that
/// native worker, so they're checked on app launch (Dart) instead.
/// Android-only; a no-op elsewhere.
class CsNotify {
  CsNotify._();

  static const MethodChannel _ch = MethodChannel('zangetsu/cloudstream');

  /// Push the current CS subscriptions to native (merged there so the worker's
  /// advanced counts survive) and (re)schedule / cancel the periodic worker.
  static Future<void> sync(List<Subscription> all) async {
    if (!Platform.isAndroid) return;
    final cs = all
        .where((s) => s.sourceId.startsWith('cs:'))
        .map(
          (s) => {
            'apiName': s.sourceId.substring(3),
            'url': s.url,
            'title': s.title,
            'lastCount': s.lastCount,
          },
        )
        .toList();
    try {
      await _ch.invokeMethod('syncSubscriptions', {'subs': cs});
    } catch (_) {}
  }

  /// Run the CS background check once, now (warm host if the app is alive).
  static Future<void> checkNow() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('checkSubscriptionsNow');
    } catch (_) {}
  }
}
