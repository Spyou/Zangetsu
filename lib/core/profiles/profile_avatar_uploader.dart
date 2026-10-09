import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../app_config.dart';

/// Uploads a profile photo through the intake Worker (`cloudflare/log-intake/`,
/// `POST /v1/avatar-slot`), which stores the bytes in R2 and returns the
/// public URL. Never throws: any failure reads as null and the editor keeps
/// the icon, mirroring `LogReportService.send`.
class ProfileAvatarUploader {
  ProfileAvatarUploader(this._dio);

  static const int maxAvatarBytes = 256 * 1024;

  final Dio _dio;

  Future<String?> upload({
    required Uint8List bytes,
    required String contentType,
    required String token,
  }) async {
    if (bytes.isEmpty || bytes.lengthInBytes > maxAvatarBytes) return null;
    try {
      final res = await _dio.post<dynamic>(
        '$kLogIntakeUrl/v1/avatar-slot',
        data: Stream<List<int>>.fromIterable([bytes]),
        options: Options(
          headers: {
            Headers.contentTypeHeader: contentType,
            Headers.contentLengthHeader: bytes.length,
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
