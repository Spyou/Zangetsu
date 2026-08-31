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
  /// [anilistToken] supplies the signed-in user's AniList access token. AniList
  /// has disabled UNAUTHENTICATED API access, so anonymous searches (malId
  /// resolution, cast/relations by title) now 403 — pass the token so these
  /// calls authenticate like the tracker's do. Falls back to anonymous.
  MetadataEnrichment(Dio dio, [String? Function()? anilistToken])
      : _dio = dio,
        _anilist = AniListApi(dio, anilistToken ?? () => null);

  final Dio _dio;
  final AniListApi _anilist;

  // TMDB v3 — api_key attached by the Dio interceptor (initDependencies).
  static const String _tmdbBase = 'https://api.themoviedb.org/3';
  static const String _img = 'https://image.tmdb.org/t/p';

  /// Resolve a MAL id for an id-less ANIME from its title (AniList search).
  /// Best-effort, null on miss / non-anime.
  Future<int?> resolveMalId(MediaDetail d) async {
    if (d.malId != null) return d.malId;
    if (d.type != ProviderType.anime || d.title.trim().isEmpty) return null;
    try {
      return await _anilist.idMalByTitle(d.title);
    } catch (_) {
      return null;
    }
  }

  /// A movie-typed title from an anime-capable source may actually be anime the
  /// plugin mislabeled. Return its MAL id ONLY on a strict AniList match (exact
  /// normalized title + year within ±1); a known year is required — no year, no
  /// guess. Null otherwise. The caller gates on source anime-capability.
  Future<int?> promoteMovieToAnimeMalId(MediaDetail d) async {
    final year = int.tryParse(d.year ?? '');
    if (year == null || d.title.trim().isEmpty) return null;
    try {
      final candidates = await _anilist.searchMedia(d.title);
      return confidentAnimeMalId(d.title, year, candidates);
    } catch (_) {
      return null;
    }
  }

  /// Pure guard: the MAL id of the first AniList candidate whose normalized
  /// title (romaji OR english) EXACTLY equals [title] and whose seasonYear is
  /// within ±1 of [year]. Null if none. Kept pure + public so the promotion
  /// rule can be unit-tested without the network.
  static int? confidentAnimeMalId(
    String title,
    int year,
    List<Map<String, dynamic>> candidates,
  ) {
    final q = _normTitle(title);
    if (q.isEmpty) return null;
    for (final m in candidates) {
      final sy = (m['seasonYear'] as num?)?.toInt();
      if (sy == null || (sy - year).abs() > 1) continue;
      final t = m['title'];
      final romaji = t is Map ? _normTitle('${t['romaji'] ?? ''}') : '';
      final english = t is Map ? _normTitle('${t['english'] ?? ''}') : '';
      if (_titleMatches(q, romaji) || _titleMatches(q, english)) {
        final idMal = (m['idMal'] as num?)?.toInt();
        if (idMal != null) return idMal;
      }
    }
    return null;
  }

  /// True when the normalized query [q] identifies the AniList title [cand]:
  /// an exact match, OR [q] is the base title of a season/sequel entry (AniList
  /// appends a season marker — "Season 4", "2nd Season", "III", "Part 2", …).
  /// The season-marker requirement is what keeps a real film ("Monster") from
  /// grabbing an unrelated show ("Monster Musume") on a bare prefix.
  static bool _titleMatches(String q, String cand) {
    if (cand.isEmpty) return false;
    if (q == cand) return true;
    if (cand.startsWith(q)) {
      return _seasonSuffix.hasMatch(cand.substring(q.length));
    }
    return false;
  }

  /// A normalized title tail that marks a season/sequel (not a different show).
  static final RegExp _seasonSuffix = RegExp(
    r'^(season\d*|\d+(nd|rd|th|st)?season|\d+|ii|iii|iv|v|vi|part\d*|cour\d*|final(season)?)$',
  );

  /// Lowercase, keep only a–z 0–9 — so "Re:ZERO" and "Re Zero" compare equal.
  static String _normTitle(String s) =>
      s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

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
      // Manga/novel (Mihon, LNReader) expose no id either. Goes to AniList's
      // MANGA side, never the video databases — see readingExtrasBySearch for
      // why that distinction is the whole point.
      if ((d.type == ProviderType.manga || d.type == ProviderType.novel) &&
          d.title.trim().isNotEmpty) {
        return await _anilist.readingExtrasBySearch(d.title);
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
