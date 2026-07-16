import 'package:dio/dio.dart';

import '../anilist/anilist_api.dart';
import '../models/media_detail.dart';
import '../models/media_extras.dart';
import '../models/person.dart';
import '../models/provider_info.dart';

/// Fetches Cast + Relations for a title from a metadata API — AniList for anime
/// (keyed by MAL id), TMDB for movies/series (keyed by TMDB id, via the same
/// keyless proxy the trailer service uses). Works for ALL sources because it
/// keys off ids the providers already expose. Best-effort: any miss/failure
/// yields empty lists, so the Detail tabs fall back to their empty state.
class MetadataEnrichment {
  MetadataEnrichment(Dio dio)
      : _dio = dio,
        _anilist = AniListApi(dio, () => null);

  final Dio _dio;
  final AniListApi _anilist;

  // TMDB v3 — api_key attached by the Dio interceptor (initDependencies).
  static const String _tmdbBase = 'https://api.themoviedb.org/3';
  static const String _img = 'https://image.tmdb.org/t/p';

  Future<({List<CastMember> cast, List<MediaRelation> relations})> fetch(
    MediaDetail d,
  ) async {
    try {
      if (d.malId != null) return await _anilist.mediaExtras(d.malId!);
      if (d.tmdbId != null) return await _tmdb(d.tmdbId!, d.tmdbIsTv);
      // Id-less anime (Aniyomi, most CloudStream): AniList exposes no id, so
      // resolve cast + relations by title search. Best-effort; a wrong title
      // match just yields slightly-off extras (never a crash).
      if (d.type == ProviderType.anime && d.title.trim().isNotEmpty) {
        return await _anilist.mediaExtrasBySearch(d.title);
      }
    } catch (_) {}
    return (cast: <CastMember>[], relations: <MediaRelation>[]);
  }

  Future<({List<CastMember> cast, List<MediaRelation> relations})> _tmdb(
    int id,
    bool isTv,
  ) async {
    final kind = isTv ? 'tv' : 'movie';
    final cast = <CastMember>[];
    final relations = <MediaRelation>[];

    final credits = await _get('$_tmdbBase/$kind/$id/credits');
    final castList = credits?['cast'];
    if (castList is List) {
      for (final c in castList.take(24)) {
        if (c is! Map) continue;
        final name = c['name'] as String?;
        if (name == null || name.isEmpty) continue;
        final pp = c['profile_path'] as String?;
        final personId = (c['id'] as num?)?.toInt();
        final photo = (pp != null && pp.isNotEmpty) ? '$_img/w185$pp' : null;
        cast.add(CastMember(
          name: name,
          role: c['character'] as String?,
          photo: photo,
          person: personId == null
              ? null
              : PersonRef(
                  id: personId,
                  source: PersonSource.tmdb,
                  name: name,
                  photo: photo,
                ),
        ));
      }
    }

    final recs = await _get('$_tmdbBase/$kind/$id/recommendations');
    final results = recs?['results'];
    if (results is List) {
      for (final r in results.take(20)) {
        if (r is! Map) continue;
        final title = (r['title'] ?? r['name']) as String?;
        if (title == null || title.isEmpty) continue;
        final poster = r['poster_path'] as String?;
        relations.add(MediaRelation(
          title: title,
          cover:
              (poster != null && poster.isNotEmpty) ? '$_img/w342$poster' : null,
          relation: 'Recommended',
          tmdbId: (r['id'] as num?)?.toInt(),
          tmdbIsTv: isTv,
        ));
      }
    }
    return (cast: cast, relations: relations);
  }

  /// Resolves a TMDB id for a title that exposes none, by searching TMDB by
  /// [title] (+ [year] when known). Used as a fallback so id-less movie/TV
  /// titles (e.g. some CloudStream sources) can still track on Simkl and pull
  /// rich Cast/Relations. Conservative: prefers a year-constrained, exact-title
  /// match; returns null when nothing reasonable is found. Best-effort.
  Future<int?> resolveTmdbId(String title, String? year, bool isTv) async {
    final q = _norm(title);
    if (q.isEmpty) return null;
    final kind = isTv ? 'tv' : 'movie';
    final yr = int.tryParse((year ?? '').trim());

    // Pass 1 (year-constrained, high confidence) then pass 2 (unconstrained).
    for (final useYear in [if (yr != null) true, false]) {
      final params = <String, dynamic>{'query': title.trim()};
      if (useYear && yr != null) {
        params[isTv ? 'first_air_date_year' : 'year'] = yr;
      }
      final res = await _get('$_tmdbBase/search/$kind', params);
      final results = res?['results'];
      if (results is! List || results.isEmpty) continue;

      // Prefer an exact normalized-title match; else the top (most relevant).
      Map<String, dynamic>? best;
      for (final r in results) {
        if (r is! Map) continue;
        final name = ((r['title'] ?? r['name']) as String?) ?? '';
        if (_norm(name) == q) {
          best = Map<String, dynamic>.from(r);
          break;
        }
      }
      best ??= (results.first is Map)
          ? Map<String, dynamic>.from(results.first as Map)
          : null;
      final id = (best?['id'] as num?)?.toInt();
      if (id != null) return id;
    }
    return null;
  }

  /// Lowercase, strip non-alphanumerics — for tolerant title comparison.
  String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  Future<Map<String, dynamic>?> _get(
    String url, [
    Map<String, dynamic>? query,
  ]) async {
    try {
      final res = await _dio.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {}
    return null;
  }
}
