import 'package:dio/dio.dart';

import '../models/media_extras.dart';
import '../models/person.dart';

/// The signed-in AniList user.
class AniListViewer {
  const AniListViewer({required this.id, required this.name, this.avatar});
  final int id;
  final String name;
  final String? avatar;
}

/// Thin AniList GraphQL client (https://graphql.anilist.co). Read-only queries
/// (Media lookup) work unauthenticated; list reads + the SaveMediaListEntry
/// mutation require the bearer token, supplied lazily via [_token].
class AniListApi {
  AniListApi(this._dio, this._token);
  final Dio _dio;
  final String? Function() _token;

  static const String _endpoint = 'https://graphql.anilist.co';

  Future<Map<String, dynamic>?> _gql(
    String query,
    Map<String, dynamic> variables, {
    bool auth = false,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (auth) {
      final t = _token();
      if (t == null || t.isEmpty) return null;
      headers['Authorization'] = 'Bearer $t';
    }
    try {
      final res = await _dio.post<dynamic>(
        _endpoint,
        data: {'query': query, 'variables': variables},
        options: Options(
          headers: headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data;
      if (data is Map && data['data'] is Map) {
        return Map<String, dynamic>.from(data['data'] as Map);
      }
    } catch (_) {}
    return null;
  }

  /// The signed-in user, or null when the token is missing/invalid.
  Future<AniListViewer?> viewer() async {
    final d = await _gql(
      'query{ Viewer{ id name avatar{ medium large } } }',
      const {},
      auth: true,
    );
    final v = d?['Viewer'];
    if (v is! Map) return null;
    final av = v['avatar'];
    return AniListViewer(
      id: (v['id'] as num).toInt(),
      name: '${v['name']}',
      avatar: av is Map ? (av['large'] ?? av['medium']) as String? : null,
    );
  }

  /// Resolve an AniList media id (+ total episodes) from a MAL id. Returns
  /// `(id, episodes)` or null when unmatched.
  Future<({int id, int? episodes})?> mediaByMalId(int malId) async {
    final d = await _gql(
      'query(\$idMal:Int){ Media(idMal:\$idMal, type:ANIME){ id episodes } }',
      {'idMal': malId},
    );
    final m = d?['Media'];
    if (m is! Map || m['id'] == null) return null;
    return (id: (m['id'] as num).toInt(), episodes: (m['episodes'] as num?)?.toInt());
  }

  /// Resolve an AniList media id (+ total episodes) by anime title search.
  /// Fallback for when no MAL id is available. Null when unmatched.
  Future<({int id, int? episodes})?> mediaBySearch(String search) async {
    final d = await _gql(
      'query(\$search:String){ Media(search:\$search, type:ANIME){ id episodes } }',
      {'search': search},
    );
    final m = d?['Media'];
    if (m is! Map || m['id'] == null) return null;
    return (id: (m['id'] as num).toInt(), episodes: (m['episodes'] as num?)?.toInt());
  }

  /// The characters + relations selection, shared by the MAL-id and
  /// title-search enrichment queries.
  static const String _extrasSelection =
      'characters(sort:[ROLE,RELEVANCE],perPage:24){ edges{ role '
      'node{ id name{full} image{medium} } '
      'voiceActors(language:JAPANESE,sort:[RELEVANCE]){ name{full} } } } '
      'relations{ edges{ relationType '
      'node{ idMal type format title{romaji english} coverImage{medium} } } }';

  /// Cast (characters + their Japanese voice actors) and related anime titles
  /// for an anime, by MAL id. Unauthenticated; returns empty lists on miss.
  Future<({List<CastMember> cast, List<MediaRelation> relations})> mediaExtras(
    int idMal,
  ) async {
    final d = await _gql(
      'query(\$idMal:Int){ Media(idMal:\$idMal,type:ANIME){ $_extrasSelection } }',
      {'idMal': idMal},
    );
    final media = d?['Media'];
    if (media is! Map) {
      return (cast: <CastMember>[], relations: <MediaRelation>[]);
    }
    return _parseExtras(media);
  }

  /// Cast + relations for an anime resolved by TITLE search — the fallback for
  /// id-less sources (Aniyomi, most CloudStream) that expose no MAL id. Tries
  /// the raw title, then a cleaned variant (bracketed "(Dub)"/"(TV)"/
  /// "[Uncensored]" suffixes break AniList's search). Best-effort, empty on miss.
  Future<({List<CastMember> cast, List<MediaRelation> relations})>
      mediaExtrasBySearch(String search) async {
    var r = await _searchExtras(search);
    if (r.cast.isEmpty && r.relations.isEmpty) {
      final cleaned = _cleanSearchTitle(search);
      if (cleaned.isNotEmpty && cleaned != search) {
        r = await _searchExtras(cleaned);
      }
    }
    return r;
  }

  /// Resolve a MAL id from a TITLE (for id-less sources) — tries the raw then
  /// the cleaned title, like [mediaExtrasBySearch]. Best-effort, null on miss.
  Future<int?> idMalByTitle(String title) async {
    Future<int?> tryOne(String s) async {
      final d = await _gql(
        'query(\$search:String){ Media(search:\$search,type:ANIME){ idMal } }',
        {'search': s},
      );
      final media = d?['Media'];
      return media is Map ? (media['idMal'] as num?)?.toInt() : null;
    }

    var id = await tryOne(title);
    if (id == null) {
      final cleaned = _cleanSearchTitle(title);
      if (cleaned.isNotEmpty && cleaned != title) id = await tryOne(cleaned);
    }
    return id;
  }

  Future<({List<CastMember> cast, List<MediaRelation> relations})>
      _searchExtras(String search) async {
    final d = await _gql(
      'query(\$search:String){ Media(search:\$search,type:ANIME){ $_extrasSelection } }',
      {'search': search},
    );
    final media = d?['Media'];
    if (media is! Map) {
      return (cast: <CastMember>[], relations: <MediaRelation>[]);
    }
    return _parseExtras(media);
  }

  /// Strip bracketed/parenthetical qualifiers a source appends — "(Dub)",
  /// "(TV)", "[Uncensored]" — which break AniList's title search.
  static String _cleanSearchTitle(String t) => t
      .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  ({List<CastMember> cast, List<MediaRelation> relations}) _parseExtras(
    Map media,
  ) {
    final cast = <CastMember>[];
    final cEdges = media['characters'] is Map ? media['characters']['edges'] : null;
    if (cEdges is List) {
      for (final e in cEdges) {
        if (e is! Map) continue;
        final node = e['node'];
        final name = (node is Map && node['name'] is Map)
            ? node['name']['full'] as String?
            : null;
        if (name == null || name.isEmpty) continue;
        final img = (node is Map && node['image'] is Map)
            ? node['image']['medium'] as String?
            : null;
        final vas = e['voiceActors'];
        final va = (vas is List &&
                vas.isNotEmpty &&
                vas.first is Map &&
                (vas.first as Map)['name'] is Map)
            ? (vas.first as Map)['name']['full'] as String?
            : null;
        final charId = (node is Map) ? (node['id'] as num?)?.toInt() : null;
        cast.add(CastMember(
          name: name,
          role: va,
          photo: img,
          person: charId == null
              ? null
              : PersonRef(
                  id: charId,
                  source: PersonSource.anilistCharacter,
                  name: name,
                  photo: img,
                ),
        ));
      }
    }

    final relations = <MediaRelation>[];
    final rEdges = media['relations'] is Map ? media['relations']['edges'] : null;
    if (rEdges is List) {
      for (final e in rEdges) {
        if (e is! Map) continue;
        final node = e['node'];
        if (node is! Map || node['type'] != 'ANIME') continue; // video app only
        final t = node['title'];
        final romaji = (t is Map) ? t['romaji'] as String? : null;
        final title =
            (t is Map) ? (t['english'] ?? t['romaji']) as String? : null;
        if (title == null || title.isEmpty) continue;
        final cover = (node['coverImage'] is Map)
            ? node['coverImage']['medium'] as String?
            : null;
        relations.add(MediaRelation(
          title: title,
          romaji: romaji,
          cover: cover,
          relation: _relationLabel(
            e['relationType'] as String?,
            node['format'] as String?,
          ),
          malId: (node['idMal'] as num?)?.toInt(),
        ));
      }
    }
    return (cast: cast, relations: relations);
  }

  static String _relationLabel(String? type, String? format) {
    if (type == null || type.isEmpty) return format ?? 'Related';
    final t = type.replaceAll('_', ' ').toLowerCase();
    return t.isEmpty ? 'Related' : t[0].toUpperCase() + t.substring(1);
  }

  /// Push progress/status for [mediaId]. Returns true on success.
  Future<bool> saveProgress({
    required int mediaId,
    required int progress,
    required String status, // CURRENT / COMPLETED / ...
  }) async {
    final d = await _gql(
      'mutation(\$mediaId:Int,\$progress:Int,\$status:MediaListStatus){'
      ' SaveMediaListEntry(mediaId:\$mediaId, progress:\$progress, status:\$status){ id progress status } }',
      {'mediaId': mediaId, 'progress': progress, 'status': status},
      auth: true,
    );
    return d?['SaveMediaListEntry'] is Map;
  }

  /// Set only the list status for [mediaId] (no progress change). Returns true
  /// on success.
  Future<bool> saveStatus({
    required int mediaId,
    required String status,
  }) async {
    final d = await _gql(
      'mutation(\$mediaId:Int,\$status:MediaListStatus){'
      ' SaveMediaListEntry(mediaId:\$mediaId, status:\$status){ id status } }',
      {'mediaId': mediaId, 'status': status},
      auth: true,
    );
    return d?['SaveMediaListEntry'] is Map;
  }

  /// Remove [mediaId] from the user's list entirely. Best-effort.
  Future<bool> deleteEntry(int mediaId) async {
    // DeleteMediaListEntry needs the LIST entry id, not the media id — look it
    // up, then delete.
    final d = await _gql(
      'query(\$mediaId:Int){ Media(id:\$mediaId){ mediaListEntry{ id } } }',
      {'mediaId': mediaId},
      auth: true,
    );
    final entry = (d?['Media'] as Map?)?['mediaListEntry'];
    final id = (entry is Map) ? (entry['id'] as num?)?.toInt() : null;
    if (id == null) return true; // not on the list → nothing to delete
    final r = await _gql(
      'mutation(\$id:Int){ DeleteMediaListEntry(id:\$id){ deleted } }',
      {'id': id},
      auth: true,
    );
    return (r?['DeleteMediaListEntry'] as Map?)?['deleted'] == true;
  }
}
