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
  static const int maxAvatarDimension = 768;
  static const int maxGifDimension = 512;
  static const int maxGifFrames = 60;

  final Dio _dio;

  static bool isAllowedGif(Uint8List bytes) {
    if (bytes.isEmpty || bytes.lengthInBytes > maxAvatarBytes) return false;
    try {
      final decoder = img.GifDecoder();
      final info = decoder.startDecode(bytes);
      return info != null &&
          info.width > 0 &&
          info.width <= maxGifDimension &&
          info.height > 0 &&
          info.height <= maxGifDimension &&
          info.numFrames > 0 &&
          info.numFrames <= maxGifFrames;
    } catch (_) {
      return false;
    }
  }

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
  if (img.findFormatForData(bytes) == img.ImageFormat.gif) {
    if (!ProfileAvatarUploader.isAllowedGif(bytes)) return null;
    final looping = _ensureGifLoops(bytes);
    return looping == null ? null : (bytes: looping, contentType: 'image/gif');
  }
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
      longestSide <= ProfileAvatarUploader.maxAvatarDimension &&
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
  for (final targetSize in [
    768,
    640,
    512,
    448,
    384,
    320,
    256,
    192,
    128,
    96,
    64,
    32,
  ]) {
    final size = targetSize < longestSide ? targetSize : longestSide;
    if (size == lastSize) continue;
    lastSize = size;
    final scale = size / longestSide;
    final width = (source.width * scale).round().clamp(
      1,
      ProfileAvatarUploader.maxAvatarDimension,
    );
    final height = (source.height * scale).round().clamp(
      1,
      ProfileAvatarUploader.maxAvatarDimension,
    );
    final resized = width == source.width && height == source.height
        ? source
        : img.copyResize(
            source,
            width: width,
            height: height,
            interpolation: img.Interpolation.average,
          );

    if (hasTransparency) {
      final compressed = img.encodePng(resized, level: 9);
      if (compressed.lengthInBytes <= ProfileAvatarUploader.maxAvatarBytes) {
        return (bytes: compressed, contentType: 'image/png');
      }
    } else {
      for (final quality in [95, 90, 85, 80, 75, 70, 65]) {
        final compressed = img.encodeJpg(resized, quality: quality);
        if (compressed.lengthInBytes <= ProfileAvatarUploader.maxAvatarBytes) {
          return (bytes: compressed, contentType: 'image/jpeg');
        }
      }
    }
  }
  return null;
}

const _infiniteGifLoopExtension = <int>[
  0x21,
  0xff,
  0x0b,
  0x4e,
  0x45,
  0x54,
  0x53,
  0x43,
  0x41,
  0x50,
  0x45,
  0x32,
  0x2e,
  0x30,
  0x03,
  0x01,
  0x00,
  0x00,
  0x00,
];

Uint8List? _ensureGifLoops(Uint8List bytes) {
  var offset = 13;
  final screenFlags = bytes[10];
  if (screenFlags & 0x80 != 0) {
    offset += 3 * (1 << ((screenFlags & 0x07) + 1));
  }
  final insertAt = offset;

  while (offset + 2 < bytes.length && bytes[offset] == 0x21) {
    final label = bytes[offset + 1];
    final blocksAt = offset + 2;
    if (label == 0xff &&
        blocksAt + 12 <= bytes.length &&
        bytes[blocksAt] == 11) {
      final application = String.fromCharCodes(
        bytes.sublist(blocksAt + 1, blocksAt + 12),
      );
      final loopDataAt = blocksAt + 12;
      if ((application == 'NETSCAPE2.0' || application == 'ANIMEXTS1.0') &&
          loopDataAt + 4 < bytes.length &&
          bytes[loopDataAt] == 3 &&
          bytes[loopDataAt + 1] == 1) {
        if (bytes[loopDataAt + 2] == 0 && bytes[loopDataAt + 3] == 0) {
          return bytes;
        }
        final looping = Uint8List.fromList(bytes);
        looping[loopDataAt + 2] = 0;
        looping[loopDataAt + 3] = 0;
        return looping;
      }
    }

    var next = blocksAt;
    while (next < bytes.length) {
      final length = bytes[next++];
      if (length == 0) break;
      next += length;
    }
    offset = next;
  }

  if (offset >= bytes.length || bytes[offset] != 0x2c) return null;
  if (bytes.length + _infiniteGifLoopExtension.length >
      ProfileAvatarUploader.maxAvatarBytes) {
    return null;
  }
  final looping = Uint8List(bytes.length + _infiniteGifLoopExtension.length);
  looping.setRange(0, insertAt, bytes);
  looping.setRange(
    insertAt,
    insertAt + _infiniteGifLoopExtension.length,
    _infiniteGifLoopExtension,
  );
  looping.setRange(
    insertAt + _infiniteGifLoopExtension.length,
    looping.length,
    bytes,
    insertAt,
  );
  return looping;
}
