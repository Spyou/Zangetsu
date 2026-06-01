import 'package:hive/hive.dart';

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
  final Duration position, duration;
  final int updatedAt;
  bool get finished =>
      duration.inMilliseconds > 0 &&
      position.inMilliseconds >= duration.inMilliseconds * 0.92;
  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}

class WatchHistory {
  static const String boxName = 'watch_history';
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  String _key(String sourceId, String showId) => '$sourceId::$showId';

  Future<void> save(HistoryEntry e) async {
    await _box.put(_key(e.sourceId, e.showId), {
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
    });
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
    );
  }

  /// Newest-first, excluding finished episodes (the Continue Watching feed).
  List<HistoryEntry> recent({int limit = 20}) {
    final all = _box.values.map(_fromMap).where((e) => !e.finished).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all.take(limit).toList();
  }
}
