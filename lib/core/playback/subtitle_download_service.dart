import 'package:dio/dio.dart';

import '../di/injector.dart';
import '../metadata/tmdb.dart';

/// Keyless subtitle lookup via the Stremio OpenSubtitles v3 addon
/// (https://opensubtitles-v3.strem.io). No API key required — the addon is
/// publicly available and rate-limits by IP.
///
/// Usage:
/// ```dart
/// final subs = await SubtitleDownloadService().find(
///   imdbId: 'tt0111161',
///   iso2: 'eng',
/// );
/// ```
///
/// The returned records carry the direct SRT/VTT [url] and the ISO-639-2
/// [lang] code (e.g. `'eng'`). May be empty when nothing matches or on any
/// network/parse error.
class SubtitleDownloadService {
  SubtitleDownloadService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 12),
            ),
          );

  final Dio _dio;

  static const String _stremioBase = 'https://opensubtitles-v3.strem.io';

  /// Finds subtitles for a title in [iso2] (ISO-639-2, e.g. `'eng'`).
  ///
  /// Resolution order for the IMDb id:
  ///   1. Use [imdbId] directly when non-null/non-empty.
  ///   2. Otherwise call TMDB external_ids for [tmdbId] to get the IMDb id.
  ///   3. If no IMDb id can be resolved → return `[]`.
  ///
  /// For series pass `isTv = true` with [season] and [episode]; the addon
  /// builds the `series/<imdb>:<s>:<e>` resource path automatically.
  ///
  /// Never throws — returns `[]` on any error.
  Future<List<({String lang, String url})>> find({
    String? imdbId,
    int? tmdbId,
    bool isTv = false,
    int? season,
    int? episode,
    required String iso2,
  }) async {
    try {
      // 1. Resolve the IMDb id.
      final resolvedImdb = await _resolveImdbId(
        imdbId: imdbId,
        tmdbId: tmdbId,
        isTv: isTv,
      );
      if (resolvedImdb == null || resolvedImdb.isEmpty) return const [];

      // 2. Build the Stremio addon URL.
      final String resourcePath;
      if (isTv && season != null && episode != null) {
        resourcePath =
            '$_stremioBase/subtitles/series/$resolvedImdb:$season:$episode.json';
      } else {
        resourcePath = '$_stremioBase/subtitles/movie/$resolvedImdb.json';
      }

      // 3. Fetch and parse subtitles.
      final res = await _dio.get<Map<String, dynamic>>(resourcePath);
      final subtitlesList = res.data?['subtitles'];
      if (subtitlesList is! List) return const [];

      final filter = iso2.trim().toLowerCase();
      final out = <({String lang, String url})>[];
      for (final item in subtitlesList) {
        if (item is! Map) continue;
        final lang = (item['lang'] as String?)?.trim() ?? '';
        final url = (item['url'] as String?)?.trim() ?? '';
        if (url.isEmpty) continue;
        if (lang.toLowerCase() == filter) {
          out.add((lang: lang, url: url));
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Resolves the IMDb id from [imdbId] (preferred) or via a TMDB
  /// external_ids lookup for [tmdbId]. Returns `null` when neither source
  /// yields a usable id.
  Future<String?> _resolveImdbId({
    String? imdbId,
    int? tmdbId,
    bool isTv = false,
  }) async {
    final trimmed = imdbId?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    if (tmdbId == null) return null;

    try {
      // Reuse the shared Dio instance whose interceptor injects the TMDB
      // api_key query parameter for all requests to api.themoviedb.org.
      final tmdbDio = sl<Dio>();
      final path = isTv
          ? '${Tmdb.base}/tv/$tmdbId/external_ids'
          : '${Tmdb.base}/movie/$tmdbId/external_ids';
      final res = await tmdbDio.get<Map<String, dynamic>>(path);
      final id = res.data?['imdb_id'] as String?;
      return (id?.trim().isNotEmpty ?? false) ? id!.trim() : null;
    } catch (_) {
      return null;
    }
  }
}
