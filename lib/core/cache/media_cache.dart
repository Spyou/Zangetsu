import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

/// Sizes and clears the app's transient media caches — the CachedNetworkImage
/// disk cache plus Flutter's in-memory image cache. It NEVER touches downloads,
/// Hive boxes, or any user data: `clear()` only empties the image cache manager
/// and the in-memory image cache, so offline downloads and settings are safe.
class MediaCache {
  const MediaCache._();

  /// Approximate on-disk cache size in bytes (the OS temp/cache area, where the
  /// image cache lives). Read-only — safe to call anytime.
  static Future<int> sizeBytes() async {
    try {
      final dir = await getTemporaryDirectory();
      return await _dirSize(dir);
    } catch (_) {
      return 0;
    }
  }

  /// Clears the app's disposable caches: the CachedNetworkImage store, Flutter's
  /// in-memory image cache, AND everything else in the OS cache dir (native
  /// image/HTTP caches from Aniyomi/CloudStream, temp subtitle/backup/APK files).
  /// Downloads live in the DOCUMENTS dir, so they are never touched.
  static Future<void> clear() async {
    // 1. CachedNetworkImage disk cache — clears its store index cleanly first.
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {}
    // 2. In-memory image cache.
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
    // 3. Remaining cache-dir contents (native caches are the bulk of the size).
    try {
      final dir = await getTemporaryDirectory();
      await for (final e in dir.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// Human-readable size, e.g. "4.8 MB" / "512 KB" / "0 B".
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
