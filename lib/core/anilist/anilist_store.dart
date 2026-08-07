import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../tracker/tracker.dart' show MediaKind, mediaKindFromName;

/// Local persistence for the AniList integration: the implicit-grant access
/// token + the signed-in viewer, the auto-sync preference, the MAL→AniList id
/// cache (so the scrobbler resolves a media id once), and the offline scrobble
/// queue (flushed on reconnect). A single untyped Hive box.
class AniListStore {
  static const String boxName = 'anilist';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
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

  Future<void> saveSession({
    required String token,
    required int expiresAt,
  }) async {
    await _box.put('accessToken', token);
    await _box.put('expiresAt', expiresAt);
  }

  Future<void> saveViewer({
    required int id,
    required String name,
    String? avatar,
  }) async {
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

  // ── Session export/import (TV relay) ────────────────────────────────────
  Map<String, dynamic>? exportSession() {
    final token = _box.get('accessToken') as String?;
    final viewerId = _box.get('viewerId') as int?;
    if (token == null || token.isEmpty || viewerId == null) return null;
    return {
      'accessToken': token,
      'expiresAt': _box.get('expiresAt'),
      'viewerId': viewerId,
      'viewerName': _box.get('viewerName'),
      'viewerAvatar': _box.get('viewerAvatar'),
    };
  }

  Future<void> importSession(Map<String, dynamic> s) async {
    await _box.put('accessToken', s['accessToken']);
    await _box.put('expiresAt', s['expiresAt']);
    await _box.put('viewerId', s['viewerId']);
    await _box.put('viewerName', s['viewerName']);
    await _box.put('viewerAvatar', s['viewerAvatar']);
  }

  // ── Preferences ──────────────────────────────────────────────────────────
  bool get autoSync => (_box.get('autoSync') as bool?) ?? true;
  set autoSync(bool v) => _box.put('autoSync', v);

  // ── Last sync diagnostic (shown in AniList settings) ───────────────────────
  String? get lastSyncInfo => _box.get('lastSync') as String?;
  Future<void> setLastSync(String info) async => _box.put('lastSync', info);

  // ── MAL → AniList media id cache ──────────────────────────────────────────
  // Namespaced by [MediaKind]: MAL's anime and manga id spaces overlap (the
  // same numeric malId can name an unrelated anime AND an unrelated manga),
  // so a shared cache could return a stale cross-kind AniList id. `anime`
  // keeps the ORIGINAL box key ('mal2al' etc.) so every entry cached before
  // this parameter existed keeps working unchanged — manga gets its own key,
  // nothing is migrated or dropped.
  String _malMapKey(MediaKind kind) =>
      kind == MediaKind.manga ? 'mal2al_manga' : 'mal2al';
  String _titleMapKey(MediaKind kind) =>
      kind == MediaKind.manga ? 'title2al_manga' : 'title2al';
  String _epsMapKey(MediaKind kind) =>
      kind == MediaKind.manga ? 'mediaEps_manga' : 'mediaEps';

  int? cachedMediaId(int malId, [MediaKind kind = MediaKind.anime]) {
    final m = _box.get(_malMapKey(kind)) as Map?;
    final v = m?['$malId'];
    return v is int ? v : null;
  }

  Future<void> cacheMediaId(
    int malId,
    int mediaId, [
    MediaKind kind = MediaKind.anime,
  ]) async {
    final key = _malMapKey(kind);
    final m = Map<String, dynamic>.from((_box.get(key) as Map?) ?? {});
    m['$malId'] = mediaId;
    await _box.put(key, m);
  }

  // ── Title → AniList media id cache (fallback when no MAL id) ────────────────
  int? cachedMediaIdByTitle(String key, [MediaKind kind = MediaKind.anime]) {
    final m = _box.get(_titleMapKey(kind)) as Map?;
    final v = m?[key];
    return v is int ? v : null;
  }

  Future<void> cacheMediaIdByTitle(
    String key,
    int mediaId, [
    MediaKind kind = MediaKind.anime,
  ]) async {
    final boxKey = _titleMapKey(kind);
    final m = Map<String, dynamic>.from((_box.get(boxKey) as Map?) ?? {});
    m[key] = mediaId;
    await _box.put(boxKey, m);
  }

  // ── Total episodes/chapters per AniList media id (to decide COMPLETED) ─────
  int? cachedEpisodes(int mediaId, [MediaKind kind = MediaKind.anime]) {
    final m = _box.get(_epsMapKey(kind)) as Map?;
    final v = m?['$mediaId'];
    return v is int ? v : null;
  }

  Future<void> cacheEpisodes(
    int mediaId,
    int episodes, [
    MediaKind kind = MediaKind.anime,
  ]) async {
    final key = _epsMapKey(kind);
    final m = Map<String, dynamic>.from((_box.get(key) as Map?) ?? {});
    m['$mediaId'] = episodes;
    await _box.put(key, m);
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
    // A growable list, not `const []` — `queueScrobble` calls `.add()` on
    // this when nothing's queued yet (the very first offline scrobble),
    // which throws against an unmodifiable literal.
    if (l == null) return <Map<String, dynamic>>[];
    return l.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _writePending(List<Map<String, dynamic>> list) async =>
      _box.put('pending', list);

  // Identity for a queued scrobble: the MAL id when known, else the title —
  // plus [kind], since MAL's anime/manga id spaces overlap (the same malId
  // can legitimately be queued for both at once). A row written before
  // [kind] existed has no 'kind' field; [mediaKindFromName] reads that as
  // anime, matching what it always implicitly meant.
  static String _pendingKey(int? malId, String? title, MediaKind kind) =>
      '${kind.name}:${malId != null ? 'mal:$malId' : 'title:${(title ?? '').toLowerCase()}'}';

  static MediaKind _rowKind(Map<String, dynamic> e) =>
      mediaKindFromName(e['kind'] as String?);

  /// Add or update a queued scrobble (keyed by malId/title/kind — newest ep
  /// wins).
  Future<void> queueScrobble({
    int? malId,
    String? title,
    required int episode,
    MediaKind kind = MediaKind.anime,
  }) async {
    final key = _pendingKey(malId, title, kind);
    final list = pendingScrobbles;
    final i = list.indexWhere(
      (e) =>
          _pendingKey(e['malId'] as int?, e['title'] as String?, _rowKind(e)) ==
          key,
    );
    final entry = {
      'malId': malId,
      'title': title,
      'episode': episode,
      'kind': kind.name,
    };
    if (i >= 0) {
      if ((list[i]['episode'] as int? ?? 0) >= episode) return;
      list[i] = entry;
    } else {
      list.add(entry);
    }
    await _writePending(list);
  }

  Future<void> removePending({
    int? malId,
    String? title,
    MediaKind kind = MediaKind.anime,
  }) async {
    final key = _pendingKey(malId, title, kind);
    final list = pendingScrobbles
      ..removeWhere(
        (e) =>
            _pendingKey(
              e['malId'] as int?,
              e['title'] as String?,
              _rowKind(e),
            ) ==
            key,
      );
    await _writePending(list);
  }
}
