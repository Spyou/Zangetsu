import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../di/injector.dart';
import 'playback_prefs.dart';

/// One subtitle hit from an OpenSubtitles search. [fileId] is what the
/// `/download` endpoint needs to mint a one-time download link; [name] is a
/// human label for the list row (release / file name), [language] the 2-letter
/// code (e.g. `en`).
class SubtitleSearchResult {
  const SubtitleSearchResult({
    required this.id,
    required this.name,
    required this.language,
    required this.fileId,
    this.format,
  });

  /// The subtitle entry id (`data[].id`).
  final String id;

  /// Display name — release/movie name, falling back to the file name.
  final String name;

  /// 2-letter language code as returned by the API.
  final String language;

  /// `data[].attributes.files[0].file_id` — required to request a download.
  final int fileId;

  /// File extension reported by the API (`srt`/`vtt`), when known.
  final String? format;
}

/// Thrown for any user-actionable OpenSubtitles failure so the UI can surface a
/// readable message (missing key, quota exhausted, network error).
class SubtitleSearchException implements Exception {
  const SubtitleSearchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Online subtitle search + download via the OpenSubtitles REST API
/// (https://api.opensubtitles.com/api/v1). Requires a free API key, stored in
/// [PlaybackPrefs.subtitleApiKey] and entered by the user in Settings.
///
/// Flow: `GET /subtitles?query=&languages=` to search, then
/// `POST /download` with the chosen `file_id` to obtain a temporary link, then
/// fetch that link to a temp file and return its local path.
class SubtitleSearchService {
  SubtitleSearchService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );

  final Dio _dio;

  static const String _base = 'https://api.opensubtitles.com/api/v1';

  /// A descriptive User-Agent — OpenSubtitles requires (and rate-limits by) one.
  static const String _userAgent = 'Zangetsu v1.0.0';

  PlaybackPrefs get _prefs => sl<PlaybackPrefs>();

  String get _apiKey {
    final key = _prefs.subtitleApiKey.trim();
    if (key.isEmpty) {
      throw const SubtitleSearchException(
        'Add an OpenSubtitles API key in Settings',
      );
    }
    return key;
  }

  Map<String, String> _headers() => {
    'Api-Key': _apiKey,
    'User-Agent': _userAgent,
    'Accept': 'application/json',
  };

  /// Searches OpenSubtitles for [query]. [language] is a 2-letter code (default
  /// `en`); pass an empty string for all languages. Optional [imdbId] and
  /// [tmdbId] improve accuracy when available (the API accepts them alongside
  /// the title query). Returns the top results (already deduped by file id).
  Future<List<SubtitleSearchResult>> search(
    String query, {
    String language = 'en',
    String? imdbId,
    int? tmdbId,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final headers = _headers(); // throws early if no key
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '$_base/subtitles',
        queryParameters: {
          'query': q,
          if (language.trim().isNotEmpty) 'languages': language.trim(),
          if (imdbId != null && imdbId.trim().isNotEmpty) 'imdb_id': imdbId.trim(),
          // ignore: use_null_aware_elements
          if (tmdbId != null) 'tmdb_id': tmdbId,
        },
        options: Options(headers: headers),
      );
      final data = (res.data?['data'] as List?) ?? const [];
      final out = <SubtitleSearchResult>[];
      final seen = <int>{};
      for (final item in data) {
        if (item is! Map) continue;
        final attrs = item['attributes'];
        if (attrs is! Map) continue;
        final files = attrs['files'];
        if (files is! List || files.isEmpty) continue;
        final first = files.first;
        if (first is! Map) continue;
        final fileId = (first['file_id'] as num?)?.toInt();
        if (fileId == null || !seen.add(fileId)) continue;
        final fileName = (first['file_name'] as String?)?.trim();
        final release = (attrs['release'] as String?)?.trim();
        final name = (release?.isNotEmpty ?? false)
            ? release!
            : (fileName?.isNotEmpty ?? false)
            ? fileName!
            : 'Subtitle';
        out.add(
          SubtitleSearchResult(
            id: (item['id'] ?? fileId).toString(),
            name: name,
            language: (attrs['language'] as String?)?.trim() ?? language,
            fileId: fileId,
            format: (attrs['format'] as String?)?.trim(),
          ),
        );
      }
      return out;
    } on DioException catch (e) {
      throw SubtitleSearchException(_dioMessage(e, 'search'));
    } catch (e) {
      throw SubtitleSearchException('Subtitle search failed: $e');
    }
  }

  /// Resolves a temporary download link for [result] via `POST /download`, then
  /// fetches it into the app's temp directory and returns the local file path.
  /// The file is named after the subtitle id with the reported extension so
  /// media_kit detects the format.
  Future<String> download(SubtitleSearchResult result) async {
    final headers = _headers(); // throws early if no key
    String link;
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_base/download',
        data: {'file_id': result.fileId},
        options: Options(
          headers: {...headers, 'Content-Type': 'application/json'},
        ),
      );
      final url = res.data?['link'] as String?;
      if (url == null || url.isEmpty) {
        throw const SubtitleSearchException('No download link returned');
      }
      link = url;
    } on DioException catch (e) {
      throw SubtitleSearchException(_dioMessage(e, 'download'));
    }

    try {
      final ext = (result.format?.isNotEmpty ?? false) ? result.format! : 'srt';
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/os_sub_${result.fileId}.${ext.replaceAll('.', '')}';
      final bytes = await _dio.get<List<int>>(
        link,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'User-Agent': _userAgent},
        ),
      );
      final body = bytes.data;
      if (body == null || body.isEmpty) {
        throw const SubtitleSearchException('Downloaded subtitle was empty');
      }
      await File(path).writeAsBytes(body, flush: true);
      return path;
    } on SubtitleSearchException {
      rethrow;
    } on DioException catch (e) {
      throw SubtitleSearchException(_dioMessage(e, 'download'));
    } catch (e) {
      throw SubtitleSearchException('Could not save subtitle: $e');
    }
  }

  /// Turns a Dio error into a friendly, actionable message.
  String _dioMessage(DioException e, String phase) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) {
      return 'OpenSubtitles rejected the API key. Check it in Settings.';
    }
    if (code == 406 || code == 429) {
      return 'OpenSubtitles download limit reached — try again later.';
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError) {
      return 'Network error — check your connection and try again.';
    }
    return 'Subtitle $phase failed${code != null ? ' ($code)' : ''}.';
  }
}
