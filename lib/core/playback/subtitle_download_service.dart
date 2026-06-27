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
  ///   3. When both are absent but [title] is non-empty, search TMDB by title
  ///      to obtain a tmdbId, then continue with step 2.
  ///   4. If no IMDb id can be resolved → return `[]`.
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
    String? title,
    int? year,
    required String iso2,
  }) async {
    try {
      // 1. Resolve the IMDb id.
      final resolvedImdb = await _resolveImdbId(
        imdbId: imdbId,
        tmdbId: tmdbId,
        isTv: isTv,
        title: title,
        year: year,
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
  /// external_ids lookup for [tmdbId]. When both are absent but [title] is
  /// non-empty, searches TMDB by title to obtain a tmdbId first, then
  /// continues with the external_ids lookup. Returns `null` when no usable
  /// id can be resolved.
  Future<String?> _resolveImdbId({
    String? imdbId,
    int? tmdbId,
    bool isTv = false,
    String? title,
    int? year,
  }) async {
    final trimmed = imdbId?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;

    // When no tmdbId is provided but we have a title, search TMDB to get one.
    int? resolvedTmdbId = tmdbId;
    if (resolvedTmdbId == null) {
      final t = title?.trim() ?? '';
      if (t.isEmpty) return null;
      resolvedTmdbId = await _searchTmdbId(t, isTv: isTv, year: year);
      if (resolvedTmdbId == null) return null;
    }

    try {
      // Reuse the shared Dio instance whose interceptor injects the TMDB
      // api_key query parameter for all requests to api.themoviedb.org.
      final tmdbDio = sl<Dio>();
      final path = isTv
          ? '${Tmdb.base}/tv/$resolvedTmdbId/external_ids'
          : '${Tmdb.base}/movie/$resolvedTmdbId/external_ids';
      final res = await tmdbDio.get<Map<String, dynamic>>(path);
      final id = res.data?['imdb_id'] as String?;
      return (id?.trim().isNotEmpty ?? false) ? id!.trim() : null;
    } catch (_) {
      return null;
    }
  }

  /// Searches TMDB for [title] and returns the first result's id, or null.
  /// Only called when no imdbId/tmdbId is available — never on the fast path.
  Future<int?> _searchTmdbId(String title, {bool isTv = false, int? year}) async {
    try {
      final tmdbDio = sl<Dio>();
      final kind = isTv ? 'tv' : 'movie';
      final params = <String, dynamic>{'query': title};
      if (year != null) {
        params[isTv ? 'first_air_date_year' : 'year'] = year;
      }
      final res = await tmdbDio.get<Map<String, dynamic>>(
        '${Tmdb.base}/search/$kind',
        queryParameters: params,
      );
      final results = res.data?['results'];
      if (results is! List || results.isEmpty) return null;
      final first = results.first;
      if (first is! Map) return null;
      return (first['id'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }
}
