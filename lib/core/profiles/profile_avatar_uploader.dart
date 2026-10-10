import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../app_config.dart';

/// Uploads a profile photo through the intake Worker (`cloudflare/log-intake/`,
/// `POST /v1/avatar-slot`), which stores the bytes in R2 and returns the
/// public URL. Never throws: any failure reads as null and the editor keeps
/// the icon, mirroring `LogReportService.send`.
class ProfileAvatarUploader {
  ProfileAvatarUploader(this._dio);

  static const int maxAvatarBytes = 512 * 1024;

  final Dio _dio;

  Future<String?> upload({
    required Uint8List bytes,
    required String token,
  }) async {
    try {
      final avatar = await compute<Uint8List, _AvatarUpload?>(
        _prepareAvatar,
        bytes,
        debugLabel: 'compress profile avatar',
      );
      if (avatar == null) return null;
      final res = await _dio.post<dynamic>(
        '$kLogIntakeUrl/v1/avatar-slot',
        data: Stream<List<int>>.fromIterable([avatar.bytes]),
        options: Options(
          headers: {
            Headers.contentTypeHeader: avatar.contentType,
            Headers.contentLengthHeader: avatar.bytes.length,
            'Authorization': 'Bearer $token',
          },
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      return urlOf(res.data);
    } catch (_) {
      return null;
    }
  }

  Future<bool> delete({required String url, required String token}) async {
    try {
      await _dio.delete<void>(
        '$kLogIntakeUrl/v1/avatar-slot',
        data: {'url': url},
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The public URL out of the Worker's reply, or null if it answered with
  /// anything else (a 401 JSON, a proxy login page, junk).
  @visibleForTesting
  static String? urlOf(dynamic data) {
    Map<dynamic, dynamic>? map;
    if (data is Map) {
      map = data;
    } else if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) map = decoded;
      } catch (_) {
        return null;
      }
    }
    final url = map?['url'];
    if (url is! String) return null;
    final trimmed = url.trim();
    return trimmed.startsWith('https://') ? trimmed : null;
  }
}

typedef _AvatarUpload = ({Uint8List bytes, String contentType});

_AvatarUpload? _prepareAvatar(Uint8List bytes) {
  final source = img.decodeImage(bytes);
  if (source == null || source.width < 1 || source.height < 1) return null;

  final type = switch (img.findFormatForData(bytes)) {
    img.ImageFormat.jpg => 'image/jpeg',
    img.ImageFormat.png => 'image/png',
    img.ImageFormat.webp => 'image/webp',
    _ => null,
  };
  final longestSide = source.width > source.height
      ? source.width
      : source.height;
  if (bytes.lengthInBytes <= ProfileAvatarUploader.maxAvatarBytes &&
      longestSide <= 512 &&
      type != null) {
    return (bytes: bytes, contentType: type);
  }

  var hasTransparency = false;
  if (source.hasAlpha) {
    for (var y = 0; y < source.height && !hasTransparency; y++) {
      for (var x = 0; x < source.width; x++) {
        if (source.getPixel(x, y).aNormalized < 1) {
          hasTransparency = true;
          break;
        }
      }
    }
  }

  var lastSize = 0;
  for (final targetSize in [512, 448, 384, 320, 256, 192, 128, 96, 64, 32]) {
    final size = targetSize < longestSide ? targetSize : longestSide;
    if (size == lastSize) continue;
    lastSize = size;
    final scale = size / longestSide;
    final width = (source.width * scale).round().clamp(1, 512);
    final height = (source.height * scale).round().clamp(1, 512);
    final resized = width == source.width && height == source.height
        ? source
        : img.copyResize(
            source,
            width: width,
            height: height,
            interpolation: img.Interpolation.linear,
          );

    if (hasTransparency) {
      final compressed = img.encodePng(resized, level: 9);
      if (compressed.lengthInBytes <= ProfileAvatarUploader.maxAvatarBytes) {
        return (bytes: compressed, contentType: 'image/png');
      }
    } else {
      for (final quality in [90, 85, 80, 75, 70, 65]) {
        final compressed = img.encodeJpg(resized, quality: quality);
        if (compressed.lengthInBytes <= ProfileAvatarUploader.maxAvatarBytes) {
          return (bytes: compressed, contentType: 'image/jpeg');
        }
      }
    }
  }
  return null;
}
