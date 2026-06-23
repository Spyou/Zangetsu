import 'package:dio/dio.dart';

/// Lightweight title autocomplete for the search field. Per debounced keystroke
/// it fires two fast metadata calls IN PARALLEL — AniList (anime) + TMDB
/// (movies/TV via the keyless proxy) — and interleaves a handful of matching
/// titles. Metadata-only autocomplete, NOT the heavy multi-source provider
/// search. Best-effort: a failing source just contributes nothing; never throws.
class TitleSuggestionService {
  TitleSuggestionService(this._dio);

  final Dio _dio;

  static const String _anilistEndpoint = 'https://graphql.anilist.co';
  // TMDB v3 — api_key attached by the Dio interceptor (initDependencies).
  static const String _tmdbBase = 'https://api.themoviedb.org/3';

  /// A small in-memory cache so re-typing a prefix doesn't re-hit the network.
  final Map<String, List<String>> _cache = {};

  /// Best-effort live title suggestions for [query] — a mix of anime + movie/TV
  /// titles, up to [limit] distinct entries. Never throws.
  Future<List<String>> suggest(String query, {int limit = 8}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final key = q.toLowerCase();
    final cached = _cache[key];
    if (cached != null) return cached;

    final results = await Future.wait([_anilist(q, limit), _tmdb(q, limit)]);
    final anime = results[0];
    final film = results[1];

    // Interleave film + anime so BOTH kinds surface (film first — movies were
    // the gap), dedup case-insensitively, cap at [limit].
    final out = <String>[];
    final seen = <String>{};
    for (
      var i = 0;
      out.length < limit && (i < film.length || i < anime.length);
      i++
    ) {
      for (final list in [film, anime]) {
        if (i < list.length) {
          final t = list[i];
          if (t.isNotEmpty && seen.add(t.toLowerCase())) out.add(t);
          if (out.length >= limit) break;
        }
      }
    }
    _cache[key] = out;
    return out;
  }

  Future<List<String>> _anilist(String q, int limit) async {
    try {
      final res = await _dio.post<dynamic>(
        _anilistEndpoint,
        data: {
          'query':
              'query(\$search:String,\$n:Int){ Page(perPage:\$n){ media('
              'search:\$search, type:ANIME, sort:SEARCH_MATCH){ '
              'title{ romaji english } } } }',
          'variables': {'search': q, 'n': limit},
        },
        options: Options(
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data;
      final media = (data is Map && data['data'] is Map)
          ? ((data['data'] as Map)['Page'] is Map
                ? ((data['data'] as Map)['Page'] as Map)['media']
                : null)
          : null;
      if (media is! List) return const [];
      final out = <String>[];
      for (final m in media) {
        if (m is! Map) continue;
        final t = m['title'];
        if (t is! Map) continue;
        final english = t['english'] as String?;
        final romaji = t['romaji'] as String?;
        final title = (english != null && english.isNotEmpty)
            ? english
            : (romaji ?? '');
        if (title.isNotEmpty) out.add(title);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _tmdb(String q, int limit) async {
    // TMDB/CloudFront occasionally RST-resets a connection under bursty load;
    // one retry after a short wait clears the transient case.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await _dio.get<dynamic>(
          '$_tmdbBase/search/multi',
          queryParameters: {'query': q, 'include_adult': 'false'},
          options: Options(
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 4),
            validateStatus: (s) => s != null && s < 500,
          ),
        );
        final data = res.data;
        final list = (data is Map) ? data['results'] : null;
        if (list is! List) return const [];
        final out = <String>[];
        for (final r in list) {
          if (r is! Map) continue;
          final mt = r['media_type'] as String?;
          if (mt != 'movie' && mt != 'tv') continue; // skip people
          final title =
              (r['title'] ?? r['name']) as String?; // movie=title, tv=name
          if (title != null && title.isNotEmpty) out.add(title);
          if (out.length >= limit) break;
        }
        return out;
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        }
      }
    }
    return const [];
  }
}
