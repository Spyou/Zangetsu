import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Anime4K — real-time GLSL upscaling (MIT-licensed, bloc97). Two dimensions:
///   • STYLE (the filter): off / a Sharpen / b De-blur / c Denoise
///   • TIER (GPU cost): mid (light M networks) / high (heavy VL + auto-downscale)
/// The `.glsl` files are downloaded on demand (not bundled) and fed to mpv via
/// `glsl-shaders`. When on, playback runs on the gpu-next/Vulkan renderer so the
/// shaders stay smooth.
class ShaderStyle {
  final String id; // 'off' | 'a' | 'b' | 'c'
  final String label;
  final String description;
  const ShaderStyle(this.id, this.label, this.description);
}

class ShaderPresets {
  ShaderPresets._();

  // ── Styles (the visible picker) ─────────────────────────────────────────────
  static const List<ShaderStyle> styles = [
    ShaderStyle('off', 'Off', 'No enhancement'),
    ShaderStyle('a', 'Sharpen', 'Restore detail — best for clean sources'),
    ShaderStyle('b', 'De-blur', 'Softer restore — for blurry / soft sources'),
    ShaderStyle('c', 'Denoise', 'Clean up grain — for compressed sources'),
  ];

  // ── GPU tiers ────────────────────────────────────────────────────────────────
  static const List<String> tiers = ['mid', 'high'];
  static String tierLabel(String t) =>
      t == 'high' ? 'High-end GPU' : 'Mid-range GPU';
  static String tierDescription(String t) => t == 'high'
      ? 'Heavier VL upscalers + HQ scaling — needs a strong GPU'
      : 'Light upscalers + deband — smooth on most phones';

  // ── Shader chains: tier → style → ordered .glsl filenames ───────────────────
  // Mid uses M networks (light); High uses VL + the auto-downscale passes.
  static const Map<String, Map<String, List<String>>> _chains = {
    'mid': {
      'a': [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ],
      'b': [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_Soft_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ],
      'c': [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
      ],
    },
    'high': {
      'a': [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_VL.glsl',
        'Anime4K_Upscale_CNN_x2_VL.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ],
      'b': [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_Soft_VL.glsl',
        'Anime4K_Upscale_CNN_x2_VL.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ],
      'c': [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ],
    },
  };

  /// Every file any chain needs — the download set (~0.8 MB).
  static const List<String> _allFiles = [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Restore_CNN_Soft_M.glsl',
    'Anime4K_Restore_CNN_VL.glsl',
    'Anime4K_Restore_CNN_Soft_VL.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_Upscale_CNN_x2_VL.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
  ];

  /// Official Anime4K (bloc97, MIT) raw source; folder inferred from the name.
  static String _urlFor(String f) {
    const base =
        'https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl';
    final folder = f.contains('Denoise')
        ? 'Upscale+Denoise'
        : (f.contains('Upscale') || f.contains('AutoDownscale'))
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

  static ShaderStyle styleById(String id) =>
      styles.firstWhere((s) => s.id == id, orElse: () => styles.first);

  /// The mpv `glsl-shaders` value (colon-joined absolute paths) for [tier] /
  /// [style], or '' when off / not downloaded.
  static Future<String> mpvValue(String tier, String style) async {
    final files = _chains[tier]?[style];
    if (files == null || files.isEmpty) return '';
    final dir = await _dir();
    return files.map((f) => '${dir.path}/$f').join(':');
  }
}
