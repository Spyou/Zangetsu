import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Free device storage, for the download size guard. Null when unknowable
// (non-Android, channel missing) — callers skip the warning rather than
// false-alarming on a guess.
// ─────────────────────────────────────────────────────────────────────────────
class StorageInfo {
  static const MethodChannel _channel = MethodChannel('AniAura/storage');

  static Future<int?> freeBytes({
    String? destination,
    bool privateStorage = false,
  }) async {
    try {
      final v = await _channel.invokeMethod<int>('freeBytes', {
        'destination': destination,
        'privateStorage': privateStorage,
      });
      return (v != null && v >= 0) ? v : null;
    } catch (_) {
      return null;
    }
  }
}
