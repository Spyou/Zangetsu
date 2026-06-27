import 'package:dio/dio.dart';

import '../di/injector.dart';
import '../metadata/tmdb.dart';

/// Online subtitle lookup for the auto-download feature, in two tiers:
///
///  1. **Stremio OpenSubtitles v3 addon** (https://opensubtitles-v3.strem.io) —
///     keyless, great for English/European languages. Tried first.
///  2. **SubDL** (https://api.subdl.com) — used as a fallback for languages the
///     Stremio addon omits (Hindi, Tamil, Telugu, Bengali, Urdu, Malayalam…).
///     Needs a free API key baked into [subDlApiKey]; when that's empty the
///     SubDL tier is skipped entirely and only the keyless Stremio tier runs.
///
/// Returns records with a direct SRT/VTT [url] and the source [lang] string.
/// Never throws — returns `[]` on no-match or any network/parse error.
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

  // ── SubDL ──────────────────────────────────────────────────────────────────
  // Free API key from subdl.com. Injected at build time (NOT committed — the
  // repo is public) via `--dart-define-from-file=secrets.json` (gitignored) or
  // `--dart-define=SUBDL_API_KEY=...`. Empty when unset → SubDL tier disabled
  // (keyless Stremio only). SubDL's free tier has no download cap (~2000
  // searches/day shared across installs).
  static const String subDlApiKey =
      String.fromEnvironment('SUBDL_API_KEY', defaultValue: '');
  static const String _subDlApi = 'https://api.subdl.com/api/v1';
  static const String _subDlCdn = 'https://dl.subdl.com';

  /// Finds subtitles for a title in the given language.
  ///
  /// [iso2] is the ISO-639-2 code (e.g. `'hin'`) used by the Stremio tier;
  /// [iso1] is the ISO-639-1 code (e.g. `'hi'`) used (uppercased) by SubDL.
  ///
  /// Resolution order for the id: [imdbId] → TMDB external_ids for [tmdbId] →
  /// TMDB title search for [title]. For series pass `isTv = true` with [season]
  /// and [episode]. Never throws — returns `[]` on any error.
  Future<List<({String lang, String url})>> find({
    String? imdbId,
    int? tmdbId,
    bool isTv = false,
    int? season,
    int? episode,
    String? title,
    int? year,
    required String iso2,
    String iso1 = '',
  }) async {
    final resolvedImdb = await _resolveImdbId(
      imdbId: imdbId,
      tmdbId: tmdbId,
      isTv: isTv,
      title: title,
      year: year,
    );

    // 1. Keyless Stremio tier (needs an IMDb id).
    if (resolvedImdb != null && resolvedImdb.isNotEmpty) {
      final stremio = await _findStremio(resolvedImdb, isTv, season, episode, iso2);
      if (stremio.isNotEmpty) return stremio;
    }

    // 2. SubDL fallback (covers languages Stremio omits). Only when keyed.
    if (subDlApiKey.isNotEmpty && iso1.trim().isNotEmpty) {
      return _findSubDl(
        imdbId: resolvedImdb,
        tmdbId: tmdbId,
        isTv: isTv,
        season: season,
        episode: episode,
        title: title,
        iso1Upper: iso1.trim().toUpperCase(),
      );
    }
    return const [];
  }

  /// Stremio OpenSubtitles v3 addon lookup. Filters by ISO-639-2 [iso2].
  Future<List<({String lang, String url})>> _findStremio(
    String imdb,
    bool isTv,
    int? season,
    int? episode,
    String iso2,
  ) async {
    try {
      final String resourcePath;
      if (isTv && season != null && episode != null) {
        resourcePath =
            '$_stremioBase/subtitles/series/$imdb:$season:$episode.json';
      } else {
        resourcePath = '$_stremioBase/subtitles/movie/$imdb.json';
      }
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
        if (lang.toLowerCase() == filter) out.add((lang: lang, url: url));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// SubDL lookup, filtered to [iso1Upper] (uppercase ISO-639-1, e.g. `'HI'`).
  /// Uses `unpack=1` so the response carries direct `.srt` file URLs (no ZIP
  /// extraction needed). Identifier preference: imdb_id → tmdb_id → film_name.
  Future<List<({String lang, String url})>> _findSubDl({
    String? imdbId,
    int? tmdbId,
    bool isTv = false,
    int? season,
    int? episode,
    String? title,
    required String iso1Upper,
  }) async {
    if (subDlApiKey.isEmpty) return const [];
    try {
      final params = <String, dynamic>{
        'api_key': subDlApiKey,
        'languages': iso1Upper,
        'type': isTv ? 'tv' : 'movie',
        'unpack': 1,
        'subs_per_page': 30,
      };
      final imdb = imdbId?.trim() ?? '';
      if (imdb.isNotEmpty) {
        params['imdb_id'] = imdb;
      } else if (tmdbId != null) {
        params['tmdb_id'] = tmdbId;
      } else if ((title?.trim() ?? '').isNotEmpty) {
        params['film_name'] = title!.trim();
      } else {
        return const [];
      }
      if (isTv && season != null) params['season_number'] = season;
      if (isTv && episode != null) params['episode_number'] = episode;

      final res = await _dio.get<Map<String, dynamic>>(
        '$_subDlApi/subtitles',
        queryParameters: params,
      );
      final subs = res.data?['subtitles'];
      if (subs is! List) return const [];

      final out = <({String lang, String url})>[];
      for (final item in subs) {
        if (item is! Map) continue;
        final lang =
            (item['language'] as String?)?.trim() ??
            (item['lang'] as String?)?.trim() ??
            iso1Upper;
        final unpack = item['unpack_files'];
        if (unpack is List) {
          for (final f in unpack) {
            if (f is! Map) continue;
            final url = _subDlUrl((f['url'] as String?)?.trim() ?? '');
            final fmt = (f['format'] as String?)?.toLowerCase() ?? '';
            if (url.isNotEmpty &&
                (fmt == 'srt' ||
                    fmt == 'vtt' ||
                    url.toLowerCase().endsWith('.srt') ||
                    url.toLowerCase().endsWith('.vtt'))) {
              out.add((lang: lang, url: url));
            }
          }
        } else {
          // No unpack list — only use the item URL if it's a direct sub file
          // (we don't unzip .zip archives here).
          final url = _subDlUrl((item['url'] as String?)?.trim() ?? '');
          if (url.toLowerCase().endsWith('.srt') ||
              url.toLowerCase().endsWith('.vtt')) {
            out.add((lang: lang, url: url));
          }
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Absolute SubDL download URL ([u] may be relative to the SubDL CDN).
  String _subDlUrl(String u) {
    if (u.isEmpty) return '';
    if (u.startsWith('http')) return u;
    return '$_subDlCdn${u.startsWith('/') ? '' : '/'}$u';
  }

  /// Resolves the IMDb id from [imdbId] (preferred) or via a TMDB external_ids
  /// lookup for [tmdbId]. When both are absent but [title] is non-empty,
  /// searches TMDB by title to obtain a tmdbId first, then continues with the
  /// external_ids lookup. Returns `null` when no usable id can be resolved.
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
