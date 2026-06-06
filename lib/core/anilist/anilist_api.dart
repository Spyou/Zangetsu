import 'package:dio/dio.dart';

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
