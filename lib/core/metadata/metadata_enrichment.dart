import 'package:dio/dio.dart';

import '../anilist/anilist_api.dart';
import '../environment.dart';
import '../models/media_detail.dart';
import '../models/media_extras.dart';
import '../models/person.dart';
import '../models/provider_info.dart';
import '../zmode/metadata_provider_prefs.dart';

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
  /// [providerPrefs] reads the user's metadata choice. Passed in rather than
  /// looked up so this stays a plain object the tests can build; a null reader
  /// (or a null return) simply means "no preference", and the AniList/TMDB
  /// answer stands.
  MetadataEnrichment(
    Dio dio, [
    String? Function()? anilistToken,
    MetadataProviderPrefs? Function()? providerPrefs,
  ]) : _dio = dio,
       _prefs = providerPrefs,
       _anilist = AniListApi(dio, anilistToken ?? () => null);

  final Dio _dio;
  final AniListApi _anilist;
  final MetadataProviderPrefs? Function()? _prefs;

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

  /// Cast + Relations for [d].
  ///
  /// Cast always comes from AniList or TMDB: MyAnimeList's v2 API serves no
  /// characters at all (the field is accepted and ignored) and Simkl has no
  /// people data, so there is nothing to switch to. Relations DO follow the
  /// user's provider where that provider has them — see [_providerRelations].
  Future<({List<CastMember> cast, List<MediaRelation> relations})> fetch(
    MediaDetail d,
  ) async {
    // Both in flight at once: the overlay is a second network round trip and
    // there is no reason to pay for it in series.
    final baseCall = _base(d);
    final ownCall = _providerRelations(d);
    final base = await baseCall;
    final own = await ownCall;
    if (own == null || own.isEmpty) return base;
    return (cast: base.cast, relations: own);
  }

  Future<({List<CastMember> cast, List<MediaRelation> relations})> _base(
    MediaDetail d,
  ) async {
    try {
      // Reading kinds are decided FIRST, before any id branch. A manga's MAL
      // id is a MANGA id, and the id branch below reads the ANIME catalogue —
      // the numbers are unrelated, so sending one down there returns someone
      // else's show or nothing at all. Goes to AniList's MANGA side, never the
      // video databases: see readingExtras for why that distinction is the
      // whole point.
      if (d.type == ProviderType.manga || d.type == ProviderType.novel) {
        if (d.malId != null) {
          final byId = await _anilist.readingExtras(d.malId!);
          if (byId.cast.isNotEmpty || byId.relations.isNotEmpty) return byId;
          // An id AniList has never heard of still deserves the title search
          // rather than an empty tab.
        }
        if (d.title.trim().isNotEmpty) {
          return await _anilist.readingExtrasBySearch(d.title);
        }
        return (cast: <CastMember>[], relations: <MediaRelation>[]);
      }
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

  /// Relations from the provider the user actually picked, or null to leave
  /// the AniList/TMDB answer alone.
  ///
  /// Verified against the live APIs rather than assumed, because both of these
  /// accept fields they do not serve:
  ///  * MAL has `related_anime` / `related_manga` (with a relation label) and
  ///    `recommendations` — but no characters, so cast never moves.
  ///  * Simkl has real `relations` on ANIME only. Its movie and TV records
  ///    carry `users_recommendations` and nothing else, so that is what a
  ///    Simkl user gets there. Anime never reaches Simkl anyway: it answers
  ///    for movies and TV, and anime follows the AniList/MAL choice.
  Future<List<MediaRelation>?> _providerRelations(MediaDetail d) async {
    final prefs = _prefs?.call();
    if (prefs == null) return null;
    try {
      final reading =
          d.type == ProviderType.manga || d.type == ProviderType.novel;
      if (reading || d.type == ProviderType.anime) {
        if (prefs.anime != AnimeProvider.mal || d.malId == null) return null;
        return await _malRelations(d.malId!, reading: reading);
      }
      if (prefs.video != VideoProvider.simkl || d.tmdbId == null) return null;
      return await _simklRelations(d.tmdbId!, isTv: d.tmdbIsTv);
    } catch (_) {
      // Any miss falls through to what AniList/TMDB already returned, which is
      // strictly better than an empty Relations tab.
      return null;
    }
  }

  /// MAL keys manga relations by MANGA id and anime relations by ANIME id, and
  /// [MediaDetail.malId] already follows the title's own kind — so the kind
  /// picks the endpoint and no id can cross over.
  Future<List<MediaRelation>> _malRelations(
    int id, {
    required bool reading,
  }) async {
    final kind = reading ? 'manga' : 'anime';
    final relKey = reading ? 'related_manga' : 'related_anime';
    final data = await _get(
      'https://api.myanimelist.net/v2/$kind/$id',
      {'fields': '$relKey,recommendations'},
      const {'X-MAL-CLIENT-ID': Environment.malClientId},
    );
    if (data == null) return const [];

    final out = <MediaRelation>[];
    void take(String key, String? fallbackLabel) {
      final list = data[key];
      if (list is! List) return;
      for (final e in list.take(20)) {
        if (e is! Map) continue;
        final node = e['node'];
        if (node is! Map) continue;
        final title = (node['title'] as String?)?.trim();
        if (title == null || title.isEmpty) continue;
        final pic = node['main_picture'];
        out.add(
          MediaRelation(
            title: title,
            cover: pic is Map
                ? (pic['large'] ?? pic['medium']) as String?
                : null,
            relation:
                (e['relation_type_formatted'] as String?) ?? fallbackLabel,
            // Only for anime: a manga id here would be compared against the
            // anime ids sources report and match the wrong show.
            malId: reading ? null : (node['id'] as num?)?.toInt(),
          ),
        );
      }
    }

    take(relKey, null);
    take('recommendations', 'Recommended');
    return out;
  }

  /// Simkl is keyed by its own id, so a TMDB id costs one lookup hop first.
  /// Its entries carry no MAL or TMDB id of their own — only a Simkl id and a
  /// slug — so relations opened from here match on title alone, which is the
  /// same path an id-less source already takes.
  Future<List<MediaRelation>> _simklRelations(
    int tmdbId, {
    required bool isTv,
  }) async {
    const key = {'simkl-api-key': Environment.simklClientId};
    final found = await _dio.get<dynamic>(
      'https://api.simkl.com/search/id',
      queryParameters: {'tmdb': '$tmdbId', 'type': isTv ? 'show' : 'movie'},
      options: Options(
        headers: key,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final list = found.data;
    if (list is! List || list.isEmpty) return const [];
    final ids = (list.first as Map?)?['ids'];
    // `simkl_id` on search results, `simkl` on sync payloads — both appear.
    final simklId = ids is Map ? (ids['simkl'] ?? ids['simkl_id']) : null;
    if (simklId == null) return const [];

    final full = await _get(
      'https://api.simkl.com/${isTv ? 'tv' : 'movies'}/$simklId',
      {'extended': 'full'},
      key,
    );
    if (full == null) return const [];

    final out = <MediaRelation>[];
    // `relations` is the anime-only field; movies and TV only ever have the
    // recommendations. Reading both keeps one parser for either shape.
    for (final key in const ['relations', 'users_recommendations']) {
      final entries = full[key];
      if (entries is! List) continue;
      for (final e in entries.take(20)) {
        if (e is! Map) continue;
        final title = ((e['en_title'] ?? e['title']) as String?)?.trim();
        if (title == null || title.isEmpty) continue;
        final poster = e['poster'] as String?;
        out.add(
          MediaRelation(
            title: title,
            cover: (poster != null && poster.isNotEmpty)
                ? 'https://simkl.in/posters/${poster}_m.jpg'
                : null,
            relation: (e['relation_type'] as String?) ?? 'Recommended',
          ),
        );
      }
    }
    return out;
  }

  Future<({List<CastMember> cast, List<MediaRelation> relations})> _tmdb(
    int id,
    bool isTv,
  ) async {
    final kind = isTv ? 'tv' : 'movie';
    final cast = <CastMember>[];
    final relations = <MediaRelation>[];

    // Both in flight at once. Nothing in the credits answer feeds the
    // recommendations request, so asking for one only after the other landed
    // cost a whole round trip for nothing.
    //
    // Safe as a pair ONLY because _get answers null on any failure instead of
    // throwing: one dead request leaves the other's result untouched. Keep
    // that contract — the day _get throws, a single failure here takes both
    // tabs down instead of one.
    final answers = await Future.wait([
      _get('$_tmdbBase/$kind/$id/credits'),
      _get('$_tmdbBase/$kind/$id/recommendations'),
    ]);
    final credits = answers[0];
    final recs = answers[1];
    final castList = credits?['cast'];
    if (castList is List) {
      for (final c in castList.take(24)) {
        if (c is! Map) continue;
        final name = c['name'] as String?;
        if (name == null || name.isEmpty) continue;
        final pp = c['profile_path'] as String?;
        final personId = (c['id'] as num?)?.toInt();
        final photo = (pp != null && pp.isNotEmpty) ? '$_img/w185$pp' : null;
        cast.add(
          CastMember(
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
          ),
        );
      }
    }

    final results = recs?['results'];
    if (results is List) {
      for (final r in results.take(20)) {
        if (r is! Map) continue;
        final title = (r['title'] ?? r['name']) as String?;
        if (title == null || title.isEmpty) continue;
        final poster = r['poster_path'] as String?;
        relations.add(
          MediaRelation(
            title: title,
            cover: (poster != null && poster.isNotEmpty)
                ? '$_img/w342$poster'
                : null,
            relation: 'Recommended',
            tmdbId: (r['id'] as num?)?.toInt(),
            tmdbIsTv: isTv,
          ),
        );
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
    Map<String, String>? headers,
  ]) async {
    try {
      final res = await _dio.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(
          headers: headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {}
    return null;
  }
}
