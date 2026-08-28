import 'package:dio/dio.dart';

import 'debrid_provider.dart';
import 'debrid_result.dart';
import 'magnet_hash.dart';

/// TorBox REST API (`https://api.torbox.app/v1/api`).
class TorBoxClient implements DebridClient {
  TorBoxClient({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: kBase,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
              ),
            );

  static const kBase = 'https://api.torbox.app/v1/api';
  static const _name = 'TorBox';

  final Dio _dio;

  @override
  DebridService get service => DebridService.torbox;

  Options _auth(String token) => Options(
        headers: {'Authorization': 'Bearer $token'},
      );

  @override
  Future<bool> validateToken(String token) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/user/me',
        options: _auth(token),
      );
      final data = r.data;
      if (data == null) return false;
      if (data['success'] == false) return false;
      return r.statusCode == 200;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        return false;
      }
      throw DebridException.fromDio(e, _name);
    }
  }

  @override
  Future<DebridResolved> resolve(
    String uri, {
    required String token,
    required Duration timeout,
    bool requireCached = false,
    void Function(String phase)? onPhase,
  }) async {
    onPhase?.call(service.phaseLabel);
    final hash = parseMagnetHash(uri);

    if (requireCached) {
      if (hash == null) {
        // .torrent URL — still create; cached items finish immediately.
      } else if (!await _isCached(hash, token)) {
        throw const DebridException(
          DebridFailure.notCached,
          'Not cached on TorBox.',
          serviceName: _name,
        );
      }
    }

    final torrentId = await _create(uri, token);
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final item = await _mylist(torrentId, token);
      if (item == null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      final finished = item['download_finished'] == true ||
          item['cached'] == true ||
          (item['download_state'] as String?) == 'cached';
      if (finished) {
        final files = _filesOf(item);
        final pick = pickLargestVideo(files);
        if (pick == null) {
          throw const DebridException(
            DebridFailure.unsupported,
            'No video file in this torrent.',
            serviceName: _name,
          );
        }
        return DebridResolved(
          url: _permalink(token, torrentId, pick.id),
          filename: pick.name,
          bytes: pick.bytes,
        );
      }
      final state = (item['download_state'] as String?) ?? '';
      if (state == 'stalled (no seeds)' && requireCached) {
        throw const DebridException(
          DebridFailure.notCached,
          'Not cached on TorBox.',
          serviceName: _name,
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    throw DebridException(
      requireCached ? DebridFailure.notCached : DebridFailure.timeout,
      requireCached
          ? 'Not cached on TorBox.'
          : 'TorBox timed out waiting for this torrent.',
      serviceName: _name,
    );
  }

  Future<bool> _isCached(String hash, String token) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/torrents/checkcached',
        queryParameters: {
          'hash': hash,
          'format': 'object',
          'list_files': 'false',
        },
        options: _auth(token),
      );
      final data = r.data?['data'];
      if (data is Map) {
        for (final key in data.keys) {
          if (key.toString().toLowerCase() == hash.toLowerCase()) {
            final v = data[key];
            if (v == true || v is Map) return true;
          }
        }
      }
      return false;
    } on DioException catch (e) {
      throw DebridException.fromDio(e, _name);
    }
  }

  Future<int> _create(String uri, String token) async {
    try {
      FormData form;
      if (looksLikeTorrentFileUrl(uri)) {
        final file = await _dio.get<List<int>>(
          uri,
          options: Options(responseType: ResponseType.bytes),
        );
        final bytes = file.data;
        if (bytes == null || bytes.isEmpty) {
          throw const DebridException(
            DebridFailure.unsupported,
            'Empty .torrent file.',
            serviceName: _name,
          );
        }
        form = FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: 'file.torrent'),
          'seed': '1',
          'allow_zip': 'false',
        });
      } else {
        form = FormData.fromMap({
          'magnet': uri,
          'seed': '1',
          'allow_zip': 'false',
        });
      }
      final r = await _dio.post<Map<String, dynamic>>(
        '/torrents/createtorrent',
        data: form,
        options: _auth(token),
      );
      if (r.data?['success'] == false) {
        final detail = r.data?['detail']?.toString() ?? 'create failed';
        throw DebridException(DebridFailure.error, 'TorBox: $detail',
            serviceName: _name);
      }
      final data = r.data?['data'];
      final id = data is Map ? data['torrent_id'] ?? data['id'] : data;
      final n = id is int ? id : int.tryParse('$id');
      if (n == null) {
        throw const DebridException(
          DebridFailure.error,
          'TorBox did not return a torrent id.',
          serviceName: _name,
        );
      }
      return n;
    } on DebridException {
      rethrow;
    } on DioException catch (e) {
      throw DebridException.fromDio(e, _name);
    }
  }

  Future<Map<String, dynamic>?> _mylist(int id, String token) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/torrents/mylist',
        queryParameters: {
          'id': id,
          'bypass_cache': 'true',
        },
        options: _auth(token),
      );
      final data = r.data?['data'];
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return null;
    } on DioException catch (e) {
      throw DebridException.fromDio(e, _name);
    }
  }

  List<DebridFile> _filesOf(Map<String, dynamic> item) {
    final raw = item['files'];
    if (raw is! List) return const [];
    final out = <DebridFile>[];
    for (final f in raw) {
      if (f is! Map) continue;
      final id = '${f['id'] ?? f['file_id'] ?? ''}';
      final path = (f['name'] ?? f['short_name'] ?? f['path'] ?? '') as String;
      final bytes = (f['size'] as num?)?.toInt() ?? 0;
      if (id.isEmpty) continue;
      out.add(DebridFile(id: id, path: path, bytes: bytes));
    }
    return out;
  }

  /// Permalink with `redirect=true` so the player follows to the CDN URL.
  String _permalink(String token, int torrentId, String fileId) =>
      'https://api.torbox.app/v1/api/torrents/requestdl'
      '?token=${Uri.encodeQueryComponent(token)}'
      '&torrent_id=$torrentId'
      '&file_id=$fileId'
      '&redirect=true';
}
