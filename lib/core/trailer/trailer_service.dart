import 'package:dio/dio.dart';

import '../models/provider_info.dart';

/// Resolves a YouTube trailer id for a title from a metadata provider.
///
/// Streaming sources (AllAnime / NetMirror) don't expose trailers, so we match
/// the title against a free/keyed metadata API and pull its YouTube trailer:
///   • Anime  → AniList GraphQL (free, no key).
///   • Movie/TV → TMDB (key-gated; gracefully disabled when [kTmdbApiKey] is
///     empty).
///
/// Best-effort and cheap: every lookup is wrapped so any network/parse failure
/// resolves to `null` rather than throwing — the caller just hides the button.
class TrailerService {
  TrailerService(this._dio);
  final Dio _dio;

  static const String _anilistEndpoint = 'https://graphql.anilist.co';
  // Keyless TMDB proxy (mirrors api.themoviedb.org/3/* server-side, no api_key).
  static const String _tmdbBase = 'https://jumpfreedom.com/3';

  static const String _anilistQuery =
      'query(\$search:String){ Media(search:\$search, type:ANIME){ '
      'id title{romaji english} trailer{ id site } } }';

  /// Returns a YouTube video id for the title, or null. Cheap + best-effort.
  Future<String?> youtubeId({
    required String title,
    String? englishTitle,
    required ProviderType type,
    String? year,
  }) async {
    switch (type) {
      case ProviderType.anime:
        return _anilistTrailer(title: title, englishTitle: englishTitle);
      case ProviderType.movie:
        return _tmdbTrailer(title: title, englishTitle: englishTitle, year: year);
    }
  }

  // ── Anime: AniList GraphQL ────────────────────────────────────────────────

  Future<String?> _anilistTrailer({
    required String title,
    String? englishTitle,
  }) async {
    final search = (englishTitle != null && englishTitle.isNotEmpty)
        ? englishTitle
        : title;
    try {
      final res = await _dio.post<dynamic>(
        _anilistEndpoint,
        data: {
          'query': _anilistQuery,
          'variables': {'search': search},
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );
      final data = _asMap(res.data);
      final media = _asMap(_asMap(data?['data'])?['Media']);
      final trailer = _asMap(media?['trailer']);
      if (trailer == null) return null;
      final site = trailer['site']?.toString().toLowerCase();
      final id = trailer['id']?.toString();
      if (site == 'youtube' && id != null && id.isNotEmpty) return id;
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Movie/TV: TMDB ────────────────────────────────────────────────────────

  Future<String?> _tmdbTrailer({
    required String title,
    String? englishTitle,
    String? year,
  }) async {
    final query = (englishTitle != null && englishTitle.isNotEmpty)
        ? englishTitle
        : title;
    try {
      final search = await _dio.get<dynamic>(
        '$_tmdbBase/search/multi',
        queryParameters: {'query': query},
      );
      final results = _asList(_asMap(search.data)?['results']);
      if (results == null || results.isEmpty) return null;

      // Keep only movie/tv results, then prefer one whose release year matches.
      final candidates = results
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .where((r) {
            final mt = r['media_type']?.toString();
            return mt == 'movie' || mt == 'tv';
          })
          .toList();
      if (candidates.isEmpty) return null;

      Map<String, dynamic> picked = candidates.first;
      if (year != null && year.isNotEmpty) {
        for (final r in candidates) {
          if (_tmdbYear(r) == year) {
            picked = r;
            break;
          }
        }
      }

      final mediaType = picked['media_type']?.toString();
      final id = picked['id']?.toString();
      if (id == null || id.isEmpty || mediaType == null) return null;

      final videos = await _dio.get<dynamic>(
        '$_tmdbBase/$mediaType/$id/videos',
      );
      final vids = _asList(_asMap(videos.data)?['results'])
          ?.map(_asMap)
          .whereType<Map<String, dynamic>>()
          .where((v) => v['site']?.toString() == 'YouTube')
          .toList();
      if (vids == null || vids.isEmpty) return null;

      // Prefer Trailer, then Teaser, then any YouTube video.
      Map<String, dynamic>? best;
      for (final v in vids) {
        if (v['type']?.toString() == 'Trailer') {
          best = v;
          break;
        }
      }
      best ??= vids.firstWhere(
        (v) => v['type']?.toString() == 'Teaser',
        orElse: () => vids.first,
      );
      final key = best['key']?.toString();
      if (key != null && key.isNotEmpty) return key;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Year from a TMDB result's release_date (movie) or first_air_date (tv).
  static String? _tmdbYear(Map<String, dynamic> r) {
    final date =
        (r['release_date'] ?? r['first_air_date'])?.toString() ?? '';
    if (date.length >= 4) return date.substring(0, 4);
    return null;
  }

  // ── tiny JSON helpers (defensive against dynamic shapes) ──────────────────

  static Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map<String, dynamic> ? v : (v is Map ? Map<String, dynamic>.from(v) : null);

  static List<dynamic>? _asList(dynamic v) => v is List ? v : null;
}
