import 'package:hive/hive.dart';

/// A saved playback position for one episode.
class ResumeMark {
  ResumeMark({required this.position, required this.duration});
  final Duration position;
  final Duration duration;

  /// Treat as watched when within the last ~8% of the runtime.
  bool get finished =>
      duration.inMilliseconds > 0 &&
      position.inMilliseconds >= duration.inMilliseconds * 0.92;
}

/// Hive-backed per-(sourceId, episodeId) resume positions.
class ResumeStore {
  static const String boxName = 'resume_positions';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(String sourceId, String episodeId) => '$sourceId::$episodeId';

  Future<void> save(
    String sourceId,
    String episodeId,
    Duration position,
    Duration duration,
  ) async {
    await _box.put(_key(sourceId, episodeId), {
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
    });
  }

  ResumeMark? get(String sourceId, String episodeId) {
    final raw = _box.get(_key(sourceId, episodeId));
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw);
    return ResumeMark(
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
    );
  }
}
