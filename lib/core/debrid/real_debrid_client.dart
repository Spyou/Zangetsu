import 'package:dio/dio.dart';

import 'debrid_provider.dart';
import 'debrid_result.dart';
import 'magnet_hash.dart';

/// Real-Debrid REST API (`https://api.real-debrid.com/rest/1.0`).
class RealDebridClient implements DebridClient {
  RealDebridClient({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: kBase,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
              ),
            );

  static const kBase = 'https://api.real-debrid.com/rest/1.0';
  static const _name = 'Real-Debrid';

  final Dio _dio;

  @override
  DebridService get service => DebridService.realDebrid;

  Options _auth(String token) => Options(
        headers: {'Authorization': 'Bearer $token'},
        contentType: Headers.formUrlEncodedContentType,
      );

  @override
  Future<bool> validateToken(String token) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/user',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return r.statusCode == 200 && (r.data?['id'] != null);
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
    final deadline = DateTime.now().add(timeout);
    String torrentId;
    try {
      torrentId = await _add(uri, token);
    } on DioException catch (e) {
      throw DebridException.fromDio(e, _name);
    }

    var selected = false;
    while (DateTime.now().isBefore(deadline)) {
      Map<String, dynamic> info;
      try {
        info = await _info(torrentId, token);
      } on DioException catch (e) {
        throw DebridException.fromDio(e, _name);
      }

      final status = (info['status'] as String?) ?? '';
      if (status == 'magnet_error' ||
          status == 'error' ||
          status == 'virus' ||
          status == 'dead') {
        await _deleteQuietly(torrentId, token);
        throw DebridException(
          DebridFailure.error,
          'Real-Debrid could not process this torrent.',
          serviceName: _name,
        );
      }

      if (status == 'waiting_files_selection' && !selected) {
        final files = _filesOf(info);
        final pick = pickLargestVideo(files);
        if (pick == null) {
          await _deleteQuietly(torrentId, token);
          throw const DebridException(
            DebridFailure.unsupported,
            'No video file in this torrent.',
            serviceName: _name,
          );
        }
        try {
          await _dio.post<void>(
            '/torrents/selectFiles/$torrentId',
            data: {'files': pick.id},
            options: _auth(token),
          );
        } on DioException catch (e) {
          throw DebridException.fromDio(e, _name);
        }
        selected = true;
        continue;
      }

      if (status == 'downloaded') {
        final link = _hosterLink(info);
        if (link == null || link.isEmpty) {
          await _deleteQuietly(torrentId, token);
          throw const DebridException(
            DebridFailure.error,
            'Real-Debrid returned no downloadable link.',
            serviceName: _name,
          );
        }
        return _unrestrict(link, token);
      }

      if (requireCached && selected && status != 'downloaded') {
        // Uncached: Prefer should not sit on a remote download.
        await _deleteQuietly(torrentId, token);
        throw const DebridException(
          DebridFailure.notCached,
          'Not cached on Real-Debrid.',
          serviceName: _name,
        );
      }

      await Future<void>.delayed(const Duration(seconds: 2));
    }

    if (requireCached) {
      await _deleteQuietly(torrentId, token);
      throw const DebridException(
        DebridFailure.notCached,
        'Not cached on Real-Debrid.',
        serviceName: _name,
      );
    }
    throw const DebridException(
      DebridFailure.timeout,
      'Real-Debrid timed out waiting for this torrent.',
      serviceName: _name,
    );
  }

  Future<String> _add(String uri, String token) async {
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
      final r = await _dio.put<Map<String, dynamic>>(
        '/torrents/addTorrent',
        data: bytes,
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/x-bittorrent',
          },
        ),
      );
      final id = r.data?['id'] as String?;
      if (id == null || id.isEmpty) {
        throw const DebridException(
          DebridFailure.error,
          'Real-Debrid did not accept the torrent file.',
          serviceName: _name,
        );
      }
      return id;
    }

    final r = await _dio.post<Map<String, dynamic>>(
      '/torrents/addMagnet',
      data: {'magnet': uri},
      options: _auth(token),
    );
    final id = r.data?['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const DebridException(
        DebridFailure.error,
        'Real-Debrid did not accept the magnet.',
        serviceName: _name,
      );
    }
    return id;
  }

  Future<Map<String, dynamic>> _info(String id, String token) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/torrents/info/$id',
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    return r.data ?? const {};
  }

  Future<DebridResolved> _unrestrict(String link, String token) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/unrestrict/link',
        data: {'link': link},
        options: _auth(token),
      );
      final url = (r.data?['download'] ?? r.data?['link']) as String?;
      if (url == null || url.isEmpty) {
        throw const DebridException(
          DebridFailure.error,
          'Real-Debrid did not return a download URL.',
          serviceName: _name,
        );
      }
      return DebridResolved(
        url: url,
        filename: r.data?['filename'] as String?,
        bytes: (r.data?['filesize'] as num?)?.toInt(),
      );
    } on DioException catch (e) {
      throw DebridException.fromDio(e, _name);
    }
  }

  Future<void> _deleteQuietly(String id, String token) async {
    try {
      await _dio.delete<void>(
        '/torrents/delete/$id',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    } catch (_) {}
  }

  List<DebridFile> _filesOf(Map<String, dynamic> info) {
    final raw = info['files'];
    if (raw is! List) return const [];
    final out = <DebridFile>[];
    for (final f in raw) {
      if (f is! Map) continue;
      final id = '${f['id'] ?? ''}';
      final path = (f['path'] as String?) ?? '';
      final bytes = (f['bytes'] as num?)?.toInt() ?? 0;
      if (id.isEmpty) continue;
      out.add(DebridFile(id: id, path: path, bytes: bytes));
    }
    return out;
  }

  String? _hosterLink(Map<String, dynamic> info) {
    final links = info['links'];
    if (links is List && links.isNotEmpty) {
      return links.first.toString();
    }
    return null;
  }
}
