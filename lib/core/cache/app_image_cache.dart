import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../platform/app_paths.dart';
import '../platform/apple_tv.dart';

/// Image disk cache for [CachedNetworkImage].
///
/// On physical Apple TV, [DefaultCacheManager] uses sqflite under Application
/// Support (read-only on device) — poster art never loads and path_provider
/// logs errors. We store cache metadata in Caches via [JsonCacheInfoRepository].
class AppImageCache {
  AppImageCache._();

  static CacheManager? _tvManager;

  /// Call once during boot on Apple TV before any [CachedNetworkImage] mounts.
  static Future<void> init() async {
    if (!isAppleTv || _tvManager != null) return;
    final dir = await writableAppSubdir('image_cache');
    final index = File('${dir.path}/cache_index.json');
    _tvManager = CacheManager(
      Config(
        'zangetsuTvImageCache',
        stalePeriod: const Duration(days: 14),
        maxNrOfCacheObjects: 400,
        repo: JsonCacheInfoRepository.withFile(index),
      ),
    );
  }

  static CacheManager get manager {
    if (!isAppleTv) return DefaultCacheManager();
    final manager = _tvManager;
    if (manager == null) {
      throw StateError(
        'AppImageCache.init() must complete before TV UI mounts',
      );
    }
    return manager;
  }

  /// Pass to [CachedNetworkImage.cacheManager] / [CachedNetworkImageProvider].
  /// On Apple TV the default sqflite-backed cache is read-only — callers that
  /// omit this get empty/error images on device.
  static CacheManager? get cacheManagerOrDefault =>
      isAppleTv ? manager : null;

  /// [ImageProvider] for network covers when not using [CachedNetworkImage].
  static CachedNetworkImageProvider imageProvider(
    String url, {
    Map<String, String>? headers,
    int? maxWidth,
    int? maxHeight,
  }) {
    return CachedNetworkImageProvider(
      url,
      headers: headers,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      cacheManager: cacheManagerOrDefault,
    );
  }
}
