import 'package:hive/hive.dart';

/// Local persistence for the AniList integration: the implicit-grant access
/// token + the signed-in viewer, the auto-sync preference, the MAL→AniList id
/// cache (so the scrobbler resolves a media id once), and the offline scrobble
/// queue (flushed on reconnect). A single untyped Hive box.
class AniListStore {
  static const String boxName = 'anilist';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
  }

  Box get _box => Hive.box(boxName);

  // ── Session ────────────────────────────────────────────────────────────────
  String? get token => _box.get('accessToken') as String?;
  int get expiresAt => (_box.get('expiresAt') as int?) ?? 0;

  bool get hasValidToken {
    final t = token;
    if (t == null || t.isEmpty) return false;
    final exp = expiresAt;
    return exp == 0 || DateTime.now().millisecondsSinceEpoch < exp;
  }

  int? get viewerId => _box.get('viewerId') as int?;
  String? get viewerName => _box.get('viewerName') as String?;
  String? get viewerAvatar => _box.get('viewerAvatar') as String?;

  Future<void> saveSession({required String token, required int expiresAt}) async {
    await _box.put('accessToken', token);
    await _box.put('expiresAt', expiresAt);
  }

  Future<void> saveViewer({required int id, required String name, String? avatar}) async {
    await _box.put('viewerId', id);
    await _box.put('viewerName', name);
    await _box.put('viewerAvatar', avatar);
  }

  /// Forget the session + viewer (on disconnect). Keeps the auto-sync
  /// preference and id cache so reconnecting doesn't re-resolve everything.
  Future<void> clearSession() async {
    for (final k in const [
      'accessToken',
      'expiresAt',
      'viewerId',
      'viewerName',
      'viewerAvatar',
    ]) {
      await _box.delete(k);
    }
  }

  // ── Preferences ──────────────────────────────────────────────────────────
  bool get autoSync => (_box.get('autoSync') as bool?) ?? true;
  set autoSync(bool v) => _box.put('autoSync', v);

  // ── Last sync diagnostic (shown in AniList settings) ───────────────────────
  String? get lastSyncInfo => _box.get('lastSync') as String?;
  Future<void> setLastSync(String info) async => _box.put('lastSync', info);

  // ── MAL → AniList media id cache ──────────────────────────────────────────
  int? cachedMediaId(int malId) {
    final m = _box.get('mal2al') as Map?;
    final v = m?['$malId'];
    return v is int ? v : null;
  }

  Future<void> cacheMediaId(int malId, int mediaId) async {
    final m = Map<String, dynamic>.from((_box.get('mal2al') as Map?) ?? {});
    m['$malId'] = mediaId;
    await _box.put('mal2al', m);
  }

  // ── Title → AniList media id cache (fallback when no MAL id) ────────────────
  int? cachedMediaIdByTitle(String key) {
    final m = _box.get('title2al') as Map?;
    final v = m?[key];
    return v is int ? v : null;
  }

  Future<void> cacheMediaIdByTitle(String key, int mediaId) async {
    final m = Map<String, dynamic>.from((_box.get('title2al') as Map?) ?? {});
    m[key] = mediaId;
    await _box.put('title2al', m);
  }

  // ── Total episodes per AniList media id (to decide COMPLETED) ──────────────
  int? cachedEpisodes(int mediaId) {
    final m = _box.get('mediaEps') as Map?;
    final v = m?['$mediaId'];
    return v is int ? v : null;
  }

  Future<void> cacheEpisodes(int mediaId, int episodes) async {
    final m = Map<String, dynamic>.from((_box.get('mediaEps') as Map?) ?? {});
    m['$mediaId'] = episodes;
    await _box.put('mediaEps', m);
  }

  // ── Scrobble high-water mark (never push progress backwards / twice) ───────
  int scrobbledProgress(int mediaId) {
    final m = _box.get('scrobbled') as Map?;
    final v = m?['$mediaId'];
    return v is int ? v : 0;
  }

  Future<void> setScrobbledProgress(int mediaId, int progress) async {
    final m = Map<String, dynamic>.from((_box.get('scrobbled') as Map?) ?? {});
    m['$mediaId'] = progress;
    await _box.put('scrobbled', m);
  }

  // ── Offline scrobble queue (failed pushes, retried on reconnect/launch) ────
  List<Map<String, dynamic>> get pendingScrobbles {
    final l = _box.get('pending') as List?;
    if (l == null) return const [];
    return l.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _writePending(List<Map<String, dynamic>> list) async =>
      _box.put('pending', list);

  // Identity for a queued scrobble: the MAL id when known, else the title.
  static String _pendingKey(int? malId, String? title) =>
      malId != null ? 'mal:$malId' : 'title:${(title ?? '').toLowerCase()}';

  /// Add or update a queued scrobble (keyed by malId/title — newest ep wins).
  Future<void> queueScrobble({
    int? malId,
    String? title,
    required int episode,
  }) async {
    final key = _pendingKey(malId, title);
    final list = pendingScrobbles;
    final i = list.indexWhere((e) => _pendingKey(e['malId'] as int?, e['title'] as String?) == key);
    final entry = {'malId': malId, 'title': title, 'episode': episode};
    if (i >= 0) {
      if ((list[i]['episode'] as int? ?? 0) >= episode) return;
      list[i] = entry;
    } else {
      list.add(entry);
    }
    await _writePending(list);
  }

  Future<void> removePending({int? malId, String? title}) async {
    final key = _pendingKey(malId, title);
    final list = pendingScrobbles
      ..removeWhere(
        (e) => _pendingKey(e['malId'] as int?, e['title'] as String?) == key,
      );
    await _writePending(list);
  }
}
