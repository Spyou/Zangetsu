import 'package:dio/dio.dart';

import '../anilist/anilist_api.dart';
import '../models/media_detail.dart';
import '../models/media_extras.dart';

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

  // Keyless TMDB proxy (mirrors api.themoviedb.org/3/* server-side).
  static const String _tmdbBase = 'https://jumpfreedom.com/3';
  static const String _img = 'https://image.tmdb.org/t/p';

  Future<({List<CastMember> cast, List<MediaRelation> relations})> fetch(
    MediaDetail d,
  ) async {
    try {
      if (d.malId != null) return await _anilist.mediaExtras(d.malId!);
      if (d.tmdbId != null) return await _tmdb(d.tmdbId!, d.tmdbIsTv);
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
        cast.add(CastMember(
          name: name,
          role: c['character'] as String?,
          photo: (pp != null && pp.isNotEmpty) ? '$_img/w185$pp' : null,
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

  Future<Map<String, dynamic>?> _get(String url) async {
    try {
      final res = await _dio.get<dynamic>(
        url,
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {}
    return null;
  }
}
