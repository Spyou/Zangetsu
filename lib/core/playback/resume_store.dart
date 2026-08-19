import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../privacy/incognito_mode.dart';

/// A saved playback position for one episode.
class ResumeMark {
  ResumeMark({
    required this.position,
    required this.duration,
    this.markedWatched = false,
  });
  final Duration position;
  final Duration duration;

  /// Set by hand from the episode list rather than inferred from playback.
  /// Stored separately instead of faking a position: a made-up duration would
  /// report a bogus progress fraction, and there'd be no way to tell a manual
  /// mark from a genuinely finished episode when unmarking.
  final bool markedWatched;

  /// Treat as watched when within the last ~8% of the runtime.
  bool get finished =>
      markedWatched ||
      (duration.inMilliseconds > 0 &&
          position.inMilliseconds >= duration.inMilliseconds * 0.92);
}

/// Hive-backed per-(sourceId, episodeId) resume positions.
class ResumeStore {
  static const String boxName = 'resume_positions';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  // Key includes the SHOW because providers like 4khdhub reuse episode ids
  // ('S1E3', …) across every title — without it, one show's resume position
  // collides with another's.
  String _key(String sourceId, String showId, String episodeId) =>
      '$sourceId::$showId::$episodeId';

  Future<void> save(
    String sourceId,
    String showId,
    String episodeId,
    Duration position,
    Duration duration,
  ) async {
    if (IncognitoMode.on) return; // incognito: don't remember playback position
    await _box.put(_key(sourceId, showId, episodeId), {
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
    });
  }

  ResumeMark? get(String sourceId, String showId, String episodeId) {
    final raw = _box.get(_key(sourceId, showId, episodeId));
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw);
    return ResumeMark(
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      // Absent on every mark written before this existed, which is the whole
      // point of defaulting it: an old mark keeps being judged by position.
      markedWatched: m['markedWatched'] == true,
    );
  }

  /// Mark an episode watched (or not) by hand, from the episode list.
  ///
  /// Unmarking drops the row entirely rather than clearing the flag: "not
  /// watched" and "watched 4 minutes in" are different states, and keeping a
  /// stale position would leave the episode showing a progress bar it no
  /// longer deserves.
  Future<void> setWatched(
    String sourceId,
    String showId,
    String episodeId, {
    required bool watched,
  }) async {
    final key = _key(sourceId, showId, episodeId);
    if (!watched) {
      await _box.delete(key);
      return;
    }
    final raw = _box.get(key);
    final m = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);
    await _box.put(key, {
      // Position and duration are left as they were — a half-watched episode
      // marked watched keeps its real numbers, so unmarking it later doesn't
      // invent a position it never had.
      'positionMs': (m['positionMs'] as num?)?.toInt() ?? 0,
      'durationMs': (m['durationMs'] as num?)?.toInt() ?? 0,
      'markedWatched': true,
    });
  }
}
