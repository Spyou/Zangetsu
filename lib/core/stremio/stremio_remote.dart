import 'dart:convert';

import 'package:dio/dio.dart';

import 'stremio_backup_cipher.dart';

class StremioRemote {
  StremioRemote({
    required Uri endpoint,
    required String? Function() accessToken,
    required String? Function() currentUserId,
    Dio? client,
  }) : _endpoint = endpoint,
       _accessToken = accessToken,
       _currentUserId = currentUserId,
       _client = client ?? Dio() {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.userInfo.isNotEmpty) {
      throw ArgumentError('Addon sync requires an HTTPS endpoint');
    }
  }
  final Uri _endpoint;
  final String? Function() _accessToken;
  final String? Function() _currentUserId;
  final Dio _client;

  Future<Map<String, dynamic>> request(
    String owner,
    String action,
    Map<String, dynamic> body,
  ) async {
    final token = _accessToken();
    if (owner != _currentUserId() || token == null || token.isEmpty) {
      throw const StremioBackupException('Sign in to sync addons.');
    }
    if (!const ['configuration', 'seal', 'open'].contains(action)) {
      throw ArgumentError('Invalid addon action');
    }
    try {
      final response = await _client
          .postUri<String>(
            _endpoint.resolve('/stremio/v1/$action'),
            options: Options(
              headers: {'Authorization': 'Bearer $token'},
              contentType: Headers.jsonContentType,
              responseType: ResponseType.plain,
            ),
            data: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (owner != _currentUserId() ||
          response.statusCode != 200 ||
          utf8.encode(response.data ?? '').length > 2 * 1024 * 1024) {
        throw const FormatException();
      }
      return Map<String, dynamic>.from(jsonDecode(response.data ?? '') as Map);
    } catch (_) {
      throw const StremioBackupException(
        'Addon sync is unavailable. Your local addons are unchanged.',
      );
    }
  }

  void dispose() => _client.close();
}
