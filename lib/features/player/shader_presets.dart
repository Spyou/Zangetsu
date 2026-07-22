import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Anime4K — real-time GLSL upscaling (MIT-licensed, bloc97) applied through
/// mpv's `glsl-shaders` to sharpen low-res anime. The `.glsl` files are
/// DOWNLOADED on demand (not bundled) to keep the APK small, then fed to mpv by
/// absolute path. One user choice — a GPU tier:
///   • off  — no enhancement
///   • mid  — the light M-network Mode-A chain (smooth on most phones)
///   • high — the heavy VL Mode-A chain with auto-downscale (strong GPUs)
/// When on, playback is routed through mpv's gpu-next/Vulkan renderer (set at
/// player creation) so the shaders run efficiently instead of stuttering.
class ShaderPresets {
  ShaderPresets._();

  static const List<String> levels = ['off', 'mid', 'high'];

  static String levelLabel(String l) => switch (l) {
    'mid' => 'Mid-range GPU',
    'high' => 'High-end GPU',
    _ => 'Off',
  };

  static String levelDescription(String l) => switch (l) {
    'mid' => 'Light — smooth on most phones',
    'high' => 'Heavier — sharpest, needs a strong GPU',
    _ => 'No enhancement',
  };

  // Standard Anime4K "Mode A" (restore + upscale) per tier — the general-purpose
  // chain recommended for 1080p anime. Mid uses M networks; High uses VL + the
  // auto-downscale passes that keep later stages cheap.
  static const Map<String, List<String>> _chains = {
    'mid': [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
    ],
    'high': [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_VL.glsl',
      'Anime4K_Upscale_CNN_x2_VL.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
    ],
  };

  /// Every file the chains need — the download set (~0.6 MB).
  static const List<String> _allFiles = [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Restore_CNN_VL.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_Upscale_CNN_x2_VL.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
  ];

  /// Official Anime4K (bloc97, MIT) raw source; folder inferred from the name.
  static String _urlFor(String f) {
    const base =
        'https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl';
    final folder = (f.contains('Upscale') || f.contains('AutoDownscale'))
        ? 'Upscale'
        : 'Restore'; // Clamp_Highlights + Restore_CNN_*
    return '$base/$folder/$f';
  }

  static Directory? _cachedDir;
  static Future<Directory> _dir() async {
    return _cachedDir ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/shaders/anime4k',
    );
  }

  /// Cached "are the shaders on disk?" flag so sync UI (the in-player picker)
  /// can gate without an async check. Refreshed by [refreshDownloaded]/[download].
  static bool downloaded = false;

  /// Re-check disk and update [downloaded]. Call on player/settings open.
  static Future<bool> refreshDownloaded() async {
    final dir = await _dir();
    downloaded =
        dir.existsSync() &&
        _allFiles.every((f) => File('${dir.path}/$f').existsSync());
    return downloaded;
  }

  /// Download every shader file (skips ones already present). Reports 0..1
  /// progress. Returns true on full success; a failure leaves partial files and
  /// returns false so the UI can offer a retry.
  static Future<bool> download({void Function(double)? onProgress}) async {
    try {
      final dir = await _dir();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final dio = Dio();
      for (var i = 0; i < _allFiles.length; i++) {
        final f = _allFiles[i];
        final out = File('${dir.path}/$f');
        if (!out.existsSync() || out.lengthSync() == 0) {
          final resp = await dio.get<List<int>>(
            _urlFor(f),
            options: Options(responseType: ResponseType.bytes),
          );
          await out.writeAsBytes(resp.data ?? const [], flush: true);
        }
        onProgress?.call((i + 1) / _allFiles.length);
      }
      return refreshDownloaded();
    } catch (_) {
      await refreshDownloaded();
      return false;
    }
  }

  /// The mpv `glsl-shaders` value (colon-joined absolute paths) for [level], or
  /// '' when off / not downloaded.
  static Future<String> mpvValue(String level) async {
    final files = _chains[level];
    if (files == null || files.isEmpty) return '';
    final dir = await _dir();
    return files.map((f) => '${dir.path}/$f').join(':');
  }
}
