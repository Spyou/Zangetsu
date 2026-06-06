// ignore_for_file: deprecated_member_use
import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';

import '../appwrite/appwrite_service.dart';
import '../environment.dart';

class HistoryEntry {
  HistoryEntry({
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    this.cover,
    this.coverHeaders,
    required this.showUrl,
    required this.category,
    required this.episodeId,
    required this.episodeNumber,
    required this.episodeUrl,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.malId,
  });
  final String sourceId,
      showId,
      showTitle,
      showUrl,
      category,
      episodeId,
      episodeUrl;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final double? episodeNumber;

  /// MyAnimeList id (anime), carried so a resume from Continue Watching can
  /// still auto-scrobble to AniList. Local-only — not synced to Appwrite.
  final int? malId;
  final Duration position, duration;
  final int updatedAt;
  bool get finished =>
      duration.inMilliseconds > 0 &&
      position.inMilliseconds >= duration.inMilliseconds * 0.92;
  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}

/// Continue Watching, backed by Hive for instant local reads and synced to
/// Appwrite when signed in. Cloud writes are throttled per show (the player
/// persists every ~5s) so we don't hammer the backend.
class WatchHistory {
  WatchHistory(this._aw, this._currentUserId);

  /// Null only in tests (logged-out paths never touch it).
  final AppwriteService? _aw;
  final String? Function() _currentUserId;

  static const String boxName = 'watch_history';
  static const int _cloudThrottleMs = 15000;

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  String _key(String sourceId, String showId) => '$sourceId::$showId';
  final Map<String, int> _lastCloudPush = {};
  String _docId(String uid, String key) =>
      sha256.convert(utf8.encode('$uid::$key')).toString().substring(0, 32);

  Future<void> save(HistoryEntry e) async {
    final key = _key(e.sourceId, e.showId);
    await _box.put(key, {
      'sourceId': e.sourceId,
      'showId': e.showId,
      'showTitle': e.showTitle,
      'cover': e.cover,
      'coverHeaders': e.coverHeaders,
      'showUrl': e.showUrl,
      'category': e.category,
      'episodeId': e.episodeId,
      'episodeNumber': e.episodeNumber,
      'episodeUrl': e.episodeUrl,
      'positionMs': e.position.inMilliseconds,
      'durationMs': e.duration.inMilliseconds,
      'updatedAt': e.updatedAt,
      'malId': e.malId,
    });
    _pushToCloud(key, e);
  }

  /// Throttled, best-effort cloud upsert (update-then-create on the
  /// deterministic per-show doc id).
  Future<void> _pushToCloud(String key, HistoryEntry e) async {
    final uid = _currentUserId();
    if (uid == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastCloudPush[key] ?? 0;
    if (now - last < _cloudThrottleMs) return;
    _lastCloudPush[key] = now;
    final docId = _docId(uid, key);
    final data = {
      'userId': uid,
      'sourceId': e.sourceId,
      'showId': e.showId,
      'showTitle': e.showTitle,
      'cover': e.cover,
      'coverHeaders': e.coverHeaders == null ? null : jsonEncode(e.coverHeaders),
      'showUrl': e.showUrl,
      'category': e.category,
      'episodeId': e.episodeId,
      'episodeNumber': e.episodeNumber,
      'episodeUrl': e.episodeUrl,
      'position': e.position.inMilliseconds,
      'duration': e.duration.inMilliseconds,
      'updatedAt': e.updatedAt,
    };
    try {
      await _aw!.databases.updateDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.historyCollectionId,
        documentId: docId,
        data: data,
      );
    } catch (_) {
      try {
        await _aw!.databases.createDocument(
          databaseId: Environment.databaseId,
          collectionId: Environment.historyCollectionId,
          documentId: docId,
          data: data,
          permissions: [
            Permission.read(Role.user(uid)),
            Permission.update(Role.user(uid)),
            Permission.delete(Role.user(uid)),
          ],
        );
      } catch (_) {/* best-effort */}
    }
  }

  HistoryEntry _fromMap(Map raw) {
    final m = Map<String, dynamic>.from(raw);
    return HistoryEntry(
      sourceId: m['sourceId'] as String,
      showId: m['showId'] as String,
      showTitle: m['showTitle'] as String? ?? '',
      cover: m['cover'] as String?,
      coverHeaders: (m['coverHeaders'] as Map?)?.map(
        (k, v) => MapEntry('$k', '$v'),
      ),
      showUrl: m['showUrl'] as String? ?? '',
      category: m['category'] as String? ?? 'sub',
      episodeId: m['episodeId'] as String? ?? '',
      episodeNumber: (m['episodeNumber'] as num?)?.toDouble(),
      episodeUrl: m['episodeUrl'] as String? ?? '',
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      malId: (m['malId'] as num?)?.toInt(),
    );
  }

  /// Newest-first, excluding finished episodes (the Continue Watching feed).
  List<HistoryEntry> recent({int limit = 20}) {
    final all = _box.values.map(_fromMap).where((e) => !e.finished).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all.take(limit).toList();
  }

  /// Replace the local cache with the signed-in user's cloud history. The
  /// cloud doc stores ms ints (`position`/`duration`); map them to the Hive
  /// shape used by [recent].
  Future<void> pullFromCloud() async {
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      final res = await _aw!.databases.listDocuments(
        databaseId: Environment.databaseId,
        collectionId: Environment.historyCollectionId,
        queries: [Query.equal('userId', uid), Query.limit(200)],
      );
      await _box.clear();
      for (final d in res.documents) {
        final m = d.data;
        final headers = m['coverHeaders'];
        await _box.put('${m['sourceId']}::${m['showId']}', {
          'sourceId': m['sourceId'],
          'showId': m['showId'],
          'showTitle': m['showTitle'],
          'cover': m['cover'],
          'coverHeaders': headers is String ? jsonDecode(headers) : null,
          'showUrl': m['showUrl'],
          'category': m['category'],
          'episodeId': m['episodeId'],
          'episodeNumber': m['episodeNumber'],
          'episodeUrl': m['episodeUrl'],
          'positionMs': m['position'],
          'durationMs': m['duration'],
          'updatedAt': m['updatedAt'],
        });
      }
    } catch (_) {/* keep local */}
  }

  /// Remove a single show from Continue Watching, locally and (when signed in)
  /// from the cloud so it doesn't sync back. Best-effort on the cloud side.
  Future<void> remove(String sourceId, String showId) async {
    final key = _key(sourceId, showId);
    await _box.delete(key);
    _lastCloudPush.remove(key);
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      await _aw!.databases.deleteDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.historyCollectionId,
        documentId: _docId(uid, key),
      );
    } catch (_) {/* best-effort */}
  }

  Future<void> clearLocal() async => _box.clear();
}